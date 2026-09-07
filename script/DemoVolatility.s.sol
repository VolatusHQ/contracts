// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {VolatusHook} from "../src/VolatusHook.sol";
import {VolatusOracle} from "../src/VolatusOracle.sol";

/// @notice Drives a scripted price episode so the accumulator visibly climbs.
///
/// @dev Each swap lands in its own block, because the hook samples at most once per block — so a
///      batch of swaps in one transaction would contribute exactly one observation, which is the
///      manipulation defense working as designed and also the reason this script is `--slow`.
contract DemoVolatility is Script {
    function run() external {
        VolatusHook hook = VolatusHook(vm.envAddress("VOLATUS_HOOK"));
        VolatusOracle oracle = VolatusOracle(vm.envAddress("VOLATUS_ORACLE"));
        PoolSwapTest router = PoolSwapTest(vm.envAddress("SWAP_ROUTER"));

        address weth = vm.envAddress("MOCK_WETH");
        address usdc = vm.envAddress("MOCK_USDC");
        uint256 rounds = vm.envOr("ROUNDS", uint256(4));
        int256 size = int256(vm.envOr("SWAP_SIZE", uint256(2e18)));

        // The pool this drives is selected by fee/tickSpacing, because that is
        // all that distinguishes two pools over the same pair and hook. It
        // defaults to the live measured pool (3000/60) so every existing
        // invocation is unchanged; `DeployDemoPool.s.sol` creates a second
        // measured pool at 500/10, and driving that one is the only reason
        // these are overridable.
        uint24 fee = uint24(vm.envOr("POOL_FEE", uint256(3000)));
        int24 tickSpacing = int24(int256(vm.envOr("POOL_TICK_SPACING", uint256(60))));

        (address c0, address c1) = weth < usdc ? (weth, usdc) : (usdc, weth);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(hook))
        });
        PoolId id = key.toId();

        console2.log("accumulator before", hook.accumulator(id));
        console2.log("observations before", hook.observations(id));

        vm.startBroadcast();
        for (uint256 i = 0; i < rounds; i++) {
            bool zeroForOne = i % 2 == 0;
            router.swap(
                key,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -size,
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
        }
        vm.stopBroadcast();

        console2.log("accumulator after ", hook.accumulator(id));
        console2.log("observations after", hook.observations(id));
        console2.log("realized variance ", oracle.realizedVariance(id));
        console2.log("realized vol (WAD)", oracle.realizedVol(id));
        console2.log("implied vol  (WAD)", oracle.impliedVol(id));
    }
}
