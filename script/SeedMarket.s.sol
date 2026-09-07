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
import {VolatusOracle} from "../src/VolatusOracle.sol";
import {VarianceToken} from "../src/VarianceToken.sol";
import {MintableERC20} from "../src/mocks/MintableERC20.sol";

/// @notice Puts an actual market into the deployed epoch.
///
/// @dev Deploying the contracts is not the same as deploying a market. Without minted pairs and
///      seeded liquidity the vol pool holds the price someone typed at initialization and cannot
///      move, which makes the oracle report a *configured* number rather than a *discovered* one
///      — and the discovery is the entire point of the design.
///
///      This mints variance pairs against collateral and seeds the VAR-LONG/collateral pool so
///      the price can actually be traded.
contract SeedMarket is Script {
    /// @dev Range roughly covering VAR-LONG prices from 0.10 to 1.00, on the 60 tick spacing.
    int24 internal constant TICK_LOWER = -23040;
    int24 internal constant TICK_UPPER = 0;

    function run() external {
        VolatusVault vault = VolatusVault(vm.envAddress("VOLATUS_VAULT"));
        VolatusOracle oracle = VolatusOracle(vm.envAddress("VOLATUS_ORACLE"));
        PoolModifyLiquidityTest lpRouter = PoolModifyLiquidityTest(vm.envAddress("LP_ROUTER"));
        MintableERC20 usdc = MintableERC20(vm.envAddress("MOCK_USDC"));

        uint256 epochId = vm.envOr("EPOCH_ID", uint256(1));
        uint256 mintAmount = vm.envOr("MINT_AMOUNT", uint256(25_000e6));
        uint128 liquidity = uint128(vm.envOr("VOL_LIQUIDITY", uint256(2e10)));

        VolatusVault.Epoch memory e = vault.epoch(epochId);
        address longToken = address(e.longToken);

        vm.startBroadcast();

        // Mint pairs: this is what creates VAR-LONG supply to trade at all.
        usdc.mint(msg.sender, mintAmount * 2);
        usdc.approve(address(vault), type(uint256).max);
        vault.mintPair(epochId, mintAmount);

        // Seed the pool where implied volatility is discovered.
        PoolKey memory volPool = _key(longToken, address(usdc));
        VarianceToken(longToken).approve(address(lpRouter), type(uint256).max);
        usdc.approve(address(lpRouter), type(uint256).max);

        lpRouter.modifyLiquidity(
            volPool,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: int256(uint256(liquidity)), salt: 0
            }),
            ""
        );

        vm.stopBroadcast();

        PoolId measured = e.poolId;
        console2.log("epochId            ", epochId);
        console2.log("VAR-LONG           ", longToken);
        console2.log("pairs minted       ", mintAmount);
        console2.log("collateral held    ", vault.epoch(epochId).collateralHeld);
        console2.log("VAR-LONG supply    ", VarianceToken(longToken).totalSupply());
        console2.log("vol pool id        ", vm.toString(PoolId.unwrap(volPool.toId())));
        console2.log("implied vol (WAD)  ", oracle.impliedVol(measured));
        console2.log("normalized IV price", oracle.normalizedImpliedVariance(measured));
    }

    function _key(address a, address b) internal pure returns (PoolKey memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }
}
