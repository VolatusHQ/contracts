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

import {VolatusVault} from "../src/VolatusVault.sol";
import {VolatusOracle} from "../src/VolatusOracle.sol";
import {VarianceToken} from "../src/VarianceToken.sol";
import {MintableERC20} from "../src/mocks/MintableERC20.sol";

/// @notice Buys VAR-LONG in the variance pool, moving the market's price of volatility.
///
/// @dev This is the step the README calls the moment the project lands. Everything before it
///      produces a *measurement*; this produces a *price* — two parties with opposing views
///      trading, and the resulting number being what the market thinks volatility is worth.
contract TradeVol is Script {
    function run() external {
        VolatusVault vault = VolatusVault(vm.envAddress("VOLATUS_VAULT"));
        VolatusOracle oracle = VolatusOracle(vm.envAddress("VOLATUS_ORACLE"));
        PoolSwapTest router = PoolSwapTest(vm.envAddress("SWAP_ROUTER"));
        MintableERC20 usdc = MintableERC20(vm.envAddress("MOCK_USDC"));

        uint256 epochId = vm.envOr("EPOCH_ID", uint256(1));
        int256 size = int256(vm.envOr("BUY_SIZE", uint256(3_000e6)));

        VolatusVault.Epoch memory e = vault.epoch(epochId);
        address longToken = address(e.longToken);
        PoolId measured = e.poolId;

        bool longIsCurrency0 = longToken < address(usdc);
        (address c0, address c1) = longIsCurrency0 ? (longToken, address(usdc)) : (address(usdc), longToken);

        PoolKey memory volPool = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        console2.log("-- before --");
        console2.log("  VAR-LONG price (WAD)", oracle.normalizedImpliedVariance(measured));
        console2.log("  implied vol    (WAD)", oracle.impliedVol(measured));

        vm.startBroadcast();
        usdc.approve(address(router), type(uint256).max);
        VarianceToken(longToken).approve(address(router), type(uint256).max);

        // Spending collateral to acquire VAR-LONG pushes its price up, which *is* the market
        // revising volatility upward. If VAR-LONG is currency0 that is a oneForZero swap.
        bool zeroForOne = !longIsCurrency0;
        router.swap(
            volPool,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -size,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopBroadcast();

        console2.log("-- after --");
        console2.log("  VAR-LONG price (WAD)", oracle.normalizedImpliedVariance(measured));
        console2.log("  implied vol    (WAD)", oracle.impliedVol(measured));
    }
}
