// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {VolatusVault} from "../src/VolatusVault.sol";
import {MintableERC20} from "../src/mocks/MintableERC20.sol";

/// @notice Opens a short-lived epoch on a *second* measured mWETH/mUSDC pool, so the full
///         settle -> reportPayoff -> claim loop can be proven end-to-end today.
///
/// @dev The live measured pool (fee 3000, tickSpacing 60) has an active epoch that does not end
///      for about a week, and `VolatusVault.openEpoch` reverts `PoolAlreadyHasAnActiveEpoch` until
///      it settles (`contracts/src/VolatusVault.sol:126-127`). `openEpoch` is permissionless and
///      keyed per `PoolId`, and `VolatusHook` has no pool allowlist -- any v4 pool initialized with
///      it becomes measured (`VolatusHook.getHookPermissions`/`_afterSwap` key on `key.toId()` with
///      no allowlist check). So a second pool over the *same* pair and hook, at a *different* fee
///      tier / tick spacing, has a different `PoolKey` (`PoolId.toId` is
///      `keccak256(abi.encode(poolKey))`, and `fee`/`tickSpacing` are fields of that struct) and
///      therefore a different, epoch-free `poolId`. `openEpoch` succeeds on it immediately.
///
///      This does not touch the live pool, its epoch 2, or any other deployed contract. It only
///      initializes a new v4 pool and opens an epoch on it.
///
///      **This is a second pool created to demonstrate settlement timing. It is not part of the
///      production market** -- see `script/README-demopool.md`.
contract DeployDemoPool is Script {
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    /// @dev Live measured pool is fee 3000 / tickSpacing 60 (see `BACKEND_HANDOFF.md` and
    ///      `script/DeployTestnet.s.sol`). Any different (fee, tickSpacing) pair yields a
    ///      different `PoolKey`, hence a different `poolId` with no active epoch. 500/10 is an
    ///      ordinary, otherwise-unused v4 tier -- nothing about the choice matters beyond "not
    ///      3000/60".
    uint24 internal constant DEMO_FEE = 500;
    int24 internal constant DEMO_TICK_SPACING = 10;

    /// @dev Same tick range `DeployTestnet.s.sol` used to seed the live measured pool -- already
    ///      proven, on this exact pair, to hold enough initialized range that swaps move price
    ///      without running off the edge of provided liquidity. Both bounds are multiples of 10,
    ///      so they are valid at this pool's tighter tick spacing too.
    int24 internal constant TICK_LOWER = -6000;
    int24 internal constant TICK_UPPER = 6000;

    /// @dev strikeWad = 0. `PayoffMath.payoff` (`contracts/src/libraries/PayoffMath.sol:36-42`)
    ///      returns 0 only when `varianceWad <= strikeWad`; with the strike at zero that means
    ///      the payoff is already nonzero the moment realized variance is nonzero at all, i.e.
    ///      after a single swap that moves the tick. Whether the payoff is nonzero does not
    ///      depend on `capWad`. What `capWad` controls is *how much* of a swap it takes to get
    ///      there, and how large the resulting payoff reads.
    uint256 internal constant STRIKE_WAD = 0;

    /// @dev Default cap, chosen so ordinary demo trading -- not a contrived edge case -- reliably
    ///      produces a payoff that is not just nonzero but visibly and fully realized (1.0 WAD),
    ///      the same way epoch 1 settled. Arithmetic, from `VarianceMath`/`VolatusHook`:
    ///
    ///        - `VolatusHook.MAX_TICK_DELTA = 1000` clamps a single block's tick move.
    ///        - `VarianceMath.realizedVariance(acc) = acc * 9_999_000_091_658_334_094 / 1e9`.
    ///        - One single fully-clamped observation (`dTick = 1000`, ~10.5% one-block move)
    ///          contributes `acc = 1_000_000`, i.e. `realizedVariance ~= 0.01e18` (~1%) on its
    ///          own -- 10x this cap.
    ///        - Reaching this cap from scratch needs `acc ~= 100_010`, i.e. one swap moving the
    ///          tick by only ~317 (`317^2 = 100_489`), a ~3.2% one-block price move -- well short
    ///          of the hook's clamp, and easy to produce against the liquidity this script adds.
    ///        - Compare: epoch 1 used `capWad = 0.02e18` (`script/DeployTestnet.s.sol`) over a
    ///          3600-second horizon and settled at `payoffWad = 1.0e18` (fully capped) -- see
    ///          `BACKEND_HANDOFF.md`. This default is 20x smaller, so the same demo trading
    ///          pattern (`script/DemoVolatility.s.sol`-style alternating swaps) that filled that
    ///          cap clears this one many times over, well inside the shorter ~600-second window
    ///          this script defaults to.
    uint256 internal constant DEFAULT_CAP_WAD = 0.001e18;

    /// @dev ~10 minutes of Unichain's ~1s blocks. Override both if you want a different window;
    ///      they are independent because `VolatusVault.Epoch.horizonSeconds` is declared, not
    ///      derived from `endBlock` (`contracts/src/VolatusVault.sol:52-55`).
    uint256 internal constant DEFAULT_DEMO_BLOCKS = 600;
    uint256 internal constant DEFAULT_HORIZON_SECONDS = 600;

    /// @dev Mirrors `DeployTestnet.s.sol`'s mint: far more than the ~1.3e19 units the seeded
    ///      position actually consumes, on a token with an open mint, so sizing precisely is not
    ///      worth doing.
    uint256 internal constant DEFAULT_MINT_AMOUNT = 1e24;

    /// @dev Same liquidity `DeployTestnet.s.sol` added to the live measured pool over the same
    ///      tick range -- already shown, on this pair, to be thin enough that deliberate demo
    ///      swaps move the tick.
    uint256 internal constant DEFAULT_LIQUIDITY = 50e18;

    function run() external {
        VolatusVault vault = VolatusVault(vm.envAddress("VOLATUS_VAULT"));
        IHooks hook = IHooks(vm.envAddress("VOLATUS_HOOK"));
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        PoolModifyLiquidityTest lpRouter = PoolModifyLiquidityTest(vm.envAddress("LP_ROUTER"));
        MintableERC20 weth = MintableERC20(vm.envAddress("MOCK_WETH"));
        MintableERC20 usdc = MintableERC20(vm.envAddress("MOCK_USDC"));

        // forge-lint: disable-next-line(unsafe-typecast)
        uint48 demoBlocks = uint48(vm.envOr("DEMO_BLOCKS", DEFAULT_DEMO_BLOCKS));
        uint32 horizonSeconds = uint32(vm.envOr("DEMO_HORIZON_SECONDS", DEFAULT_HORIZON_SECONDS));
        uint256 capWad = vm.envOr("DEMO_CAP_WAD", DEFAULT_CAP_WAD);
        uint128 liquidity = uint128(vm.envOr("DEMO_LIQUIDITY", DEFAULT_LIQUIDITY));
        uint256 mintAmount = vm.envOr("DEMO_MINT_AMOUNT", DEFAULT_MINT_AMOUNT);

        address me = msg.sender;
        PoolKey memory demoKey = _key(address(weth), address(usdc), hook);
        PoolId demoPoolId = demoKey.toId();

        vm.startBroadcast();

        // MintableERC20.mint is an open faucet (contracts/src/mocks/MintableERC20.sol) -- no
        // owner, no allowance check. Mint unconditionally rather than branching on current
        // balance; the extra supply costs nothing on a mock.
        weth.mint(me, mintAmount);
        usdc.mint(me, mintAmount);

        // The second measured pool. Same pair, same hook, different (fee, tickSpacing) ->
        // different poolId -> no PoolAlreadyHasAnActiveEpoch collision with the live pool.
        poolManager.initialize(demoKey, SQRT_PRICE_1_1);

        // Seed liquidity so a swap actually moves the tick instead of reverting for want of any.
        weth.approve(address(lpRouter), type(uint256).max);
        usdc.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            demoKey,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: int256(uint256(liquidity)),
                salt: 0
            }),
            ""
        );

        uint48 endBlock = uint48(block.number) + demoBlocks;
        uint256 epochId = vault.openEpoch(demoPoolId, endBlock, horizonSeconds, STRIKE_WAD, capWad);

        vm.stopBroadcast();

        VolatusVault.Epoch memory e = vault.epoch(epochId);

        // Mirrors the coverageEnd/coverageStart pairing VolatusStream epochs use on Arc -- see
        // BACKEND_HANDOFF.md and DeployStream.s.sol. Nothing here touches Arc; this is only the
        // number a follow-on step would pass to `stream.openEpoch` to keep the two in step.
        uint256 arcCoverageEndToMirror = block.timestamp + horizonSeconds;

        console2.log("== Demo measured pool (fee/tickSpacing distinct from the live pool) ==");
        console2.log("demo pool fee         ", uint256(DEMO_FEE));
        console2.log("demo pool tickSpacing ", int256(DEMO_TICK_SPACING));
        console2.log("demo poolId           ", vm.toString(PoolId.unwrap(demoPoolId)));
        console2.log("mWETH                 ", address(weth));
        console2.log("mUSDC                 ", address(usdc));
        console2.log("liquidity added       ", uint256(liquidity));
        console2.log("epochId               ", epochId);
        console2.log("startBlock            ", uint256(e.startBlock));
        console2.log("endBlock              ", uint256(endBlock));
        console2.log("horizonSeconds        ", uint256(horizonSeconds));
        console2.log("strikeWad             ", STRIKE_WAD);
        console2.log("capWad                ", capWad);
        console2.log("VAR-LONG              ", address(e.longToken));
        console2.log("VAR-SHORT             ", address(e.shortToken));
        console2.log("Arc coverageEnd to mirror (unix ts)", arcCoverageEndToMirror);
    }

    function _key(address a, address b, IHooks hooks) internal pure returns (PoolKey memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: DEMO_FEE,
            tickSpacing: DEMO_TICK_SPACING,
            hooks: hooks
        });
    }
}
