// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IVolatusVault} from "./interfaces/IVolatusVault.sol";
import {IVolatusHook} from "./interfaces/IVolatusHook.sol";
import {VarianceToken} from "./VarianceToken.sol";
import {PayoffMath} from "./libraries/PayoffMath.sol";
import {VarianceMath} from "./libraries/VarianceMath.sol";

/// @title VolatusVault
/// @notice Collateral, issuance and settlement for capped variance pairs.
///
/// @dev One unit of collateral in mints one VAR-LONG and one VAR-SHORT. At settlement they
///      redeem for `p` and `1 - p` respectively, so a pair never redeems for more than the
///      collateral that created it. **That is the whole solvency argument** — there is no
///      insurance fund, no liquidation engine, no auto-deleveraging, and no path to bad debt,
///      because the liability is defined as a partition of an amount the vault already holds.
///
///      Both legs round *down* independently rather than the short leg being the complement of
///      the rounded long leg. The tidier version returns exactly one unit per pair but lets a
///      set of partial redemptions sum to more than the collateral held; flooring each means the
///      vault can only ever retain dust, never owe it. See `DECISIONS.md` §6.
///
///      Legs are ERC-20s, not ERC-6909 ids, because VAR-LONG has to be a Uniswap v4 pool
///      currency and a pool currency is `type Currency is address` — one address, one token,
///      nowhere to put an id. See `DECISIONS.md` §1. They are EIP-1167 clones created with
///      `cloneDeterministic`, so a leg's address is computable before its epoch opens and the
///      vol pool's `PoolKey` is known in advance.
///
///      **Reentrancy.** Every state-changing entry point is guarded. The collateral token is a
///      constructor argument, so the vault cannot assume it is well behaved, and `mintPair`
///      credits the *observed* balance delta rather than the requested amount. Those two facts
///      together are dangerous without a guard: a re-entrant collateral could let an inner
///      `mintPair` complete, and the outer call would then count the inner deposit a second time
///      and mint legs against collateral already claimed. USDC does not do this; nothing in the
///      code guarantees the collateral is USDC. Transient storage keeps the guard cheap.
contract VolatusVault is IVolatusVault, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    struct Epoch {
        PoolId poolId;
        uint48 startBlock;
        uint48 endBlock;
        /// @dev The epoch's horizon in seconds, declared rather than derived. Annualization
        ///      needs a duration, and inferring one from block numbers would hard-code an
        ///      assumption about block time that differs per chain and drifts on any of them.
        uint32 horizonSeconds;
        bool settled;
        uint256 startAccumulator;
        uint256 strikeWad;
        uint256 capWad;
        VarianceToken longToken;
        VarianceToken shortToken;
        uint256 collateralHeld;
        uint256 payoffWad;
    }

    /// @notice The collateral every epoch is denominated in. USDC in production.
    IERC20 public immutable collateral;

    /// @notice The measurement surface.
    IVolatusHook public immutable hook;

    /// @notice The VarianceToken implementation every leg is cloned from.
    address public immutable tokenImplementation;

    /// @dev Legs mirror the collateral's decimals, so one leg unit maps to one collateral unit.
    uint8 internal immutable _legDecimals;

    /// @notice Epoch ids start at 1, so zero can mean "none".
    uint256 public epochCount;

    mapping(uint256 => Epoch) internal _epochs;

    /// @notice The unsettled epoch for a pool, or zero. One at a time, because the hook holds a
    ///         single pending boundary per pool.
    mapping(PoolId => uint256) public activeEpoch;

    error InvalidRange(uint256 strikeWad, uint256 capWad);
    error ZeroHorizon();
    error ZeroAddress();
    error EndBlockInPast(uint48 endBlock, uint256 currentBlock);
    error PoolAlreadyHasAnActiveEpoch(uint256 epochId);
    error NoSuchEpoch(uint256 epochId);
    error EpochClosed(uint256 epochId);
    error EpochNotOver(uint48 endBlock, uint256 currentBlock);
    error AlreadySettled(uint256 epochId);
    error NotSettled(uint256 epochId);
    error SnapshotMissing(uint256 epochId, uint48 endBlock);

    constructor(IERC20 collateral_, IVolatusHook hook_, address tokenImplementation_) {
        if (address(collateral_) == address(0) || address(hook_) == address(0) || tokenImplementation_ == address(0)) {
            revert ZeroAddress();
        }

        collateral = collateral_;
        hook = hook_;
        tokenImplementation = tokenImplementation_;
        _legDecimals = IERC20Metadata(address(collateral_)).decimals();
    }

    // -------------------------------------------------------------------------
    // Epoch lifecycle
    // -------------------------------------------------------------------------

    /// @notice Opens an epoch on `poolId` measuring from now until `endBlock`.
    /// @dev Permissionless. Nothing here can harm an existing epoch: a pool may hold only one
    ///      unsettled epoch at a time, and the hook independently refuses a second pending
    ///      boundary.
    function openEpoch(PoolId poolId, uint48 endBlock, uint32 horizonSeconds, uint256 strikeWad, uint256 capWad)
        external
        returns (uint256 epochId)
    {
        if (capWad <= strikeWad) revert InvalidRange(strikeWad, capWad);
        if (endBlock <= block.number) revert EndBlockInPast(endBlock, block.number);
        if (horizonSeconds == 0) revert ZeroHorizon();

        uint256 active = activeEpoch[poolId];
        if (active != 0) revert PoolAlreadyHasAnActiveEpoch(active);

        epochId = ++epochCount;

        VarianceToken long_ = _createLeg(epochId, true);
        VarianceToken short_ = _createLeg(epochId, false);

        _epochs[epochId] = Epoch({
            poolId: poolId,
            // forge-lint: disable-next-line(unsafe-typecast)
            startBlock: uint48(block.number),
            endBlock: endBlock,
            horizonSeconds: horizonSeconds,
            settled: false,
            // The epoch's variance is the growth of the accumulator from here, so this reading
            // is the epoch's origin.
            startAccumulator: hook.accumulator(poolId),
            strikeWad: strikeWad,
            capWad: capWad,
            longToken: long_,
            shortToken: short_,
            collateralHeld: 0,
            payoffWad: 0
        });

        activeEpoch[poolId] = epochId;

        // Ask the pool's own next swap after `endBlock` to freeze the accumulator, so that
        // settling late cannot fold post-epoch volatility into the payoff.
        hook.requestSnapshot(poolId, endBlock);

        emit EpochOpened(epochId, poolId, endBlock, strikeWad, capWad, address(long_), address(short_));
    }

    function _createLeg(uint256 epochId, bool isLong) internal returns (VarianceToken leg) {
        leg = VarianceToken(Clones.cloneDeterministic(tokenImplementation, _legSalt(epochId, isLong)));

        string memory suffix = Strings.toString(epochId);
        leg.initialize(
            string.concat("Volatus ", isLong ? "VAR-LONG #" : "VAR-SHORT #", suffix),
            string.concat(isLong ? "vLONG-" : "vSHORT-", suffix),
            _legDecimals,
            address(this)
        );
    }

    function _legSalt(uint256 epochId, bool isLong) internal pure returns (bytes32) {
        return keccak256(abi.encode(epochId, isLong));
    }

    /// @notice The address a leg will have, computable before the epoch is opened.
    function predictLeg(uint256 epochId, bool isLong) external view returns (address) {
        return Clones.predictDeterministicAddress(tokenImplementation, _legSalt(epochId, isLong), address(this));
    }

    // -------------------------------------------------------------------------
    // Issuance
    // -------------------------------------------------------------------------

    /// @inheritdoc IVolatusVault
    function mintPair(uint256 epochId, uint256 amount) external nonReentrant {
        Epoch storage e = _open(epochId);
        if (block.number >= e.endBlock) revert EpochClosed(epochId);

        // Measure what actually arrived rather than trusting `amount`, so a fee-on-transfer or
        // otherwise non-standard collateral cannot mint claims the vault is not holding.
        uint256 before = collateral.balanceOf(address(this));
        collateral.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = collateral.balanceOf(address(this)) - before;

        e.collateralHeld += received;
        e.longToken.mint(msg.sender, received);
        e.shortToken.mint(msg.sender, received);

        emit PairMinted(epochId, msg.sender, received);
    }

    /// @inheritdoc IVolatusVault
    /// @dev Allowed right up to settlement. It is not an arbitrage even once the outcome is
    ///      obvious: a pair is worth `p + (1 - p)` = one unit whatever `p` turns out to be. This
    ///      is the trade that pins `p_long + p_short = 1` in the market.
    function burnPair(uint256 epochId, uint256 amount) external nonReentrant {
        Epoch storage e = _open(epochId);

        e.longToken.burn(msg.sender, amount);
        e.shortToken.burn(msg.sender, amount);
        e.collateralHeld -= amount;

        collateral.safeTransfer(msg.sender, amount);

        emit PairBurned(epochId, msg.sender, amount);
    }

    // -------------------------------------------------------------------------
    // Settlement
    // -------------------------------------------------------------------------

    /// @inheritdoc IVolatusVault
    /// @dev Permissionless, and the value it reads cannot be influenced by *when* it is called.
    function settle(uint256 epochId) external nonReentrant returns (uint256) {
        Epoch storage e = _open(epochId);
        if (block.number < e.endBlock) revert EpochNotOver(e.endBlock, block.number);

        uint256 varianceWad = VarianceMath.realizedVariance(_endAccumulator(epochId, e) - e.startAccumulator);
        uint256 payoffWad = PayoffMath.payoff(varianceWad, e.strikeWad, e.capWad);

        e.payoffWad = payoffWad;
        e.settled = true;
        activeEpoch[e.poolId] = 0;

        // Free the hook's pending boundary so the pool can host the next epoch. If the boundary
        // already fired this is a no-op; if it never did — an epoch that ended with no further
        // trading — the slot would otherwise stay occupied and block every future epoch on this
        // pool until somebody happened to swap.
        hook.releaseSnapshot(e.poolId);

        emit EpochSettled(epochId, varianceWad, payoffWad);
        return payoffWad;
    }

    /// @dev Two branches, and which one applies is decided by the chain, not by the caller.
    ///      If no observation has happened since the epoch closed, the live accumulator is
    ///      already exactly the closing value. Otherwise the pool's own first swap after
    ///      `endBlock` froze it, and that frozen value is the only one settlement will accept.
    function _endAccumulator(uint256 epochId, Epoch storage e) internal view returns (uint256) {
        if (hook.lastObservedBlock(e.poolId) < e.endBlock) {
            return hook.accumulator(e.poolId);
        }

        (bool taken, uint256 frozen) = hook.snapshotAt(e.poolId, e.endBlock);
        if (!taken) revert SnapshotMissing(epochId, e.endBlock);
        return frozen;
    }

    /// @inheritdoc IVolatusVault
    function redeem(uint256 epochId, bool isLong, uint256 amount) external nonReentrant returns (uint256 payout) {
        Epoch storage e = _epochs[epochId];
        if (e.endBlock == 0) revert NoSuchEpoch(epochId);
        if (!e.settled) revert NotSettled(epochId);

        (isLong ? e.longToken : e.shortToken).burn(msg.sender, amount);

        payout = PayoffMath.redemption(amount, e.payoffWad, isLong);
        e.collateralHeld -= payout;

        collateral.safeTransfer(msg.sender, payout);

        emit Redeemed(epochId, msg.sender, isLong, amount, payout);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function epoch(uint256 epochId) external view returns (Epoch memory) {
        return _epochs[epochId];
    }

    /// @notice Realized variance so far for an epoch, WAD. Frozen once settled.
    function realizedVariance(uint256 epochId) external view returns (uint256) {
        Epoch storage e = _epochs[epochId];
        if (e.endBlock == 0) revert NoSuchEpoch(epochId);

        uint256 endAccumulator =
            e.settled || block.number >= e.endBlock ? _endAccumulator(epochId, e) : hook.accumulator(e.poolId);
        return VarianceMath.realizedVariance(endAccumulator - e.startAccumulator);
    }

    function _open(uint256 epochId) internal view returns (Epoch storage e) {
        e = _epochs[epochId];
        if (e.endBlock == 0) revert NoSuchEpoch(epochId);
        if (e.settled) revert AlreadySettled(epochId);
    }
}
