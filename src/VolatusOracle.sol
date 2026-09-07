// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IVolatusOracle} from "./interfaces/IVolatusOracle.sol";
import {IVolatusHook} from "./interfaces/IVolatusHook.sol";
import {VolatusVault} from "./VolatusVault.sol";
import {PayoffMath} from "./libraries/PayoffMath.sol";
import {VarianceMath} from "./libraries/VarianceMath.sol";

/// @title VolatusOracle
/// @notice The first onchain implied-volatility feed for an arbitrary Uniswap pair.
///
/// @dev The chain of reasoning, end to end:
///
///      1. VAR-LONG redeems for `p` and VAR-SHORT for `1 - p`, so a pair is always worth one
///         unit of collateral. Arbitrage therefore pins VAR-LONG's market price into `(0, 1)`.
///      2. That price **is** the market's expectation of normalized variance for the epoch —
///         not a model's estimate of it, a price two sides with opposing views agreed on.
///      3. Run it back through the payoff to get implied variance, annualize, take the root.
///
///      Step 2 is the whole point. Every dynamic-fee hook in existence estimates volatility from
///      a trailing window because nothing else has existed to read; a trailing window is
///      backward-looking by construction and is exactly wrong at the moment it matters most.
///
///      This contract holds no funds, has no privileged action over the vault, and can only be
///      read. The one thing it must be told is *which* v4 pool prices a given epoch's VAR-LONG,
///      since that pool is created after the epoch's legs exist. See `registerVolPool`.
contract VolatusOracle is IVolatusOracle {
    using StateLibrary for IPoolManager;

    /// @notice Q128 scaling used when squaring sqrtPriceX96.
    uint256 internal constant Q128 = 1 << 128;
    uint256 internal constant Q64 = 1 << 64;
    uint256 internal constant WAD = 1e18;

    IPoolManager public immutable poolManager;
    VolatusVault public immutable vault;
    IVolatusHook public immutable hook;

    /// @notice May register vol pools. Fixed at construction, never transferable.
    address public immutable curator;

    struct VolPool {
        PoolId poolId;
        bool longIsCurrency0;
        bool registered;
    }

    /// @notice epochId -> the v4 pool where that epoch's VAR-LONG trades.
    mapping(uint256 => VolPool) internal _volPool;

    event VolPoolRegistered(uint256 indexed epochId, PoolId indexed volPoolId, bool longIsCurrency0);

    error ZeroAddress();
    error NotCurator();
    error AlreadyRegistered(uint256 epochId);
    error LegNotInPool(uint256 epochId);
    error NoActiveEpoch(PoolId id);
    error NoVolPool(uint256 epochId);
    error VolPoolNotInitialized(uint256 epochId);

    constructor(IPoolManager poolManager_, VolatusVault vault_, IVolatusHook hook_, address curator_) {
        if (
            address(poolManager_) == address(0) || address(vault_) == address(0) || address(hook_) == address(0)
                || curator_ == address(0)
        ) revert ZeroAddress();

        poolManager = poolManager_;
        vault = vault_;
        hook = hook_;
        curator = curator_;
    }

    // -------------------------------------------------------------------------
    // Registration
    // -------------------------------------------------------------------------

    /// @notice Points an epoch at the v4 pool that prices its VAR-LONG.
    /// @dev One-shot per epoch and curator-only. The vol pool cannot exist until the epoch's
    ///      legs do, so this cannot be folded into `openEpoch`.
    ///
    ///      The trust this concentrates is bounded and worth stating: a wrong registration makes
    ///      this oracle report a wrong number. It cannot move collateral, cannot change a
    ///      settlement — settlement reads the hook's accumulator and never this contract — and
    ///      cannot be changed once set. Integrators who need more than one curator's word should
    ///      read `realizedVariance`, which depends on nothing registered here.
    ///
    ///      Which side of the pool VAR-LONG sits on is derived from the key rather than supplied,
    ///      so a mismatched flag cannot silently invert every price this contract reports.
    function registerVolPool(uint256 epochId, PoolKey calldata volPoolKey) external {
        if (msg.sender != curator) revert NotCurator();
        if (_volPool[epochId].registered) revert AlreadyRegistered(epochId);

        address longToken = address(vault.epoch(epochId).longToken);
        bool longIsCurrency0 = Currency.unwrap(volPoolKey.currency0) == longToken;

        if (!longIsCurrency0 && Currency.unwrap(volPoolKey.currency1) != longToken) {
            revert LegNotInPool(epochId);
        }

        PoolId volPoolId = volPoolKey.toId();
        _volPool[epochId] = VolPool({poolId: volPoolId, longIsCurrency0: longIsCurrency0, registered: true});

        emit VolPoolRegistered(epochId, volPoolId, longIsCurrency0);
    }

    function volPool(uint256 epochId) external view returns (VolPool memory) {
        return _volPool[epochId];
    }

    // -------------------------------------------------------------------------
    // The feed
    // -------------------------------------------------------------------------

    /// @inheritdoc IVolatusOracle
    function normalizedImpliedVariance(PoolId id) public view returns (uint256) {
        uint256 epochId = _activeEpoch(id);
        VolPool memory vp = _volPool[epochId];
        if (!vp.registered) revert NoVolPool(epochId);

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(vp.poolId);
        if (sqrtPriceX96 == 0) revert VolPoolNotInitialized(epochId);

        uint256 priceWad = _priceWad(sqrtPriceX96, vp.longIsCurrency0);

        // A pair is worth exactly one unit of collateral, so arbitrage confines VAR-LONG to
        // [0, 1]. Clamping rather than reverting keeps a thin or briefly dislocated pool from
        // bricking every integrator reading this feed.
        return priceWad > WAD ? WAD : priceWad;
    }

    /// @inheritdoc IVolatusOracle
    function impliedVol(PoolId id) public view returns (uint256) {
        uint256 epochId = _activeEpoch(id);
        VolatusVault.Epoch memory e = vault.epoch(epochId);

        uint256 impliedVarianceWad = PayoffMath.impliedVariance(normalizedImpliedVariance(id), e.strikeWad, e.capWad);

        return VarianceMath.toVolatility(VarianceMath.annualize(impliedVarianceWad, e.horizonSeconds));
    }

    /// @inheritdoc IVolatusOracle
    function tryImpliedVol(PoolId id) external view returns (bool, uint256) {
        try this.impliedVol(id) returns (uint256 v) {
            return (true, v);
        } catch {
            return (false, 0);
        }
    }

    /// @inheritdoc IVolatusOracle
    /// @dev Depends on nothing registered by the curator — it reads the hook directly.
    function realizedVariance(PoolId id) public view returns (uint256) {
        return vault.realizedVariance(_activeEpoch(id));
    }

    /// @inheritdoc IVolatusOracle
    function realizedVol(PoolId id) external view returns (uint256) {
        VolatusVault.Epoch memory e = vault.epoch(_activeEpoch(id));
        return VarianceMath.toVolatility(VarianceMath.annualize(realizedVariance(id), e.horizonSeconds));
    }

    /// @inheritdoc IVolatusOracle
    function epoch(PoolId id) external view returns (uint64, uint256, uint256) {
        VolatusVault.Epoch memory e = vault.epoch(_activeEpoch(id));
        return (e.endBlock, e.strikeWad, e.capWad);
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    function _activeEpoch(PoolId id) internal view returns (uint256 epochId) {
        epochId = vault.activeEpoch(id);
        if (epochId == 0) revert NoActiveEpoch(id);
    }

    /// @dev sqrtPriceX96 -> price of VAR-LONG in collateral, WAD.
    ///      Both sides carry the collateral's decimals (a leg mirrors them at initialization),
    ///      so no decimal correction is needed. `Math.mulDiv` carries a 512-bit intermediate,
    ///      which is what keeps squaring a 160-bit value from overflowing.
    function _priceWad(uint160 sqrtPriceX96, bool longIsCurrency0) internal pure returns (uint256) {
        // (sqrtP^2 / 2^64) == price * 2^128
        uint256 priceX128 = Math.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), Q64);

        // currency1 per currency0. If VAR-LONG is currency0 that is already its price in
        // collateral; otherwise invert.
        return longIsCurrency0 ? Math.mulDiv(priceX128, WAD, Q128) : Math.mulDiv(Q128, WAD, priceX128);
    }
}
