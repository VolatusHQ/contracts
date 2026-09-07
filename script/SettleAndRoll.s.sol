// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
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

/// @notice Settles the open epoch, redeems both legs, then opens and seeds the next one.
///
/// @dev The full lifecycle in one transaction batch: freeze the payoff from the pool's own
///      measurement, pay both legs their share of the collateral that minted them, and roll into
///      a fresh epoch with a longer horizon so the demo environment is not a one-hour window.
contract SettleAndRoll is Script {
    int24 internal constant TICK_LOWER = -23040;
    int24 internal constant TICK_UPPER = 0;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function run() external {
        VolatusVault vault = VolatusVault(vm.envAddress("VOLATUS_VAULT"));
        VolatusOracle oracle = VolatusOracle(vm.envAddress("VOLATUS_ORACLE"));
        PoolModifyLiquidityTest lpRouter = PoolModifyLiquidityTest(vm.envAddress("LP_ROUTER"));
        MintableERC20 usdc = MintableERC20(vm.envAddress("MOCK_USDC"));
        IPoolManager pm = IPoolManager(vm.envAddress("POOL_MANAGER"));

        uint256 oldEpoch = vm.envOr("EPOCH_ID", uint256(1));
        uint48 nextBlocks = uint48(vm.envOr("NEXT_EPOCH_BLOCKS", uint256(86_400))); // ~24h
        uint32 nextHorizon = uint32(vm.envOr("NEXT_HORIZON_SECONDS", uint256(86_400)));
        uint256 mintAmount = vm.envOr("MINT_AMOUNT", uint256(25_000e6));
        uint256 initialPrice = vm.envOr("INITIAL_VAR_PRICE", uint256(0.3e18));
        uint128 liquidity = uint128(vm.envOr("VOL_LIQUIDITY", uint256(2e10)));

        VolatusVault.Epoch memory e = vault.epoch(oldEpoch);
        PoolId measured = e.poolId;
        VarianceToken oldLong = e.longToken;
        VarianceToken oldShort = e.shortToken;

        vm.startBroadcast();

        // --- settle ---------------------------------------------------------
        uint256 payoffWad = vault.settle(oldEpoch);

        uint256 longBal = oldLong.balanceOf(msg.sender);
        uint256 shortBal = oldShort.balanceOf(msg.sender);
        uint256 longPaid = longBal == 0 ? 0 : vault.redeem(oldEpoch, true, longBal);
        uint256 shortPaid = shortBal == 0 ? 0 : vault.redeem(oldEpoch, false, shortBal);

        // --- roll -----------------------------------------------------------
        uint256 newEpoch =
            vault.openEpoch(measured, uint48(block.number) + nextBlocks, nextHorizon, e.strikeWad, e.capWad);
        address newLong = address(vault.epoch(newEpoch).longToken);

        usdc.mint(msg.sender, mintAmount * 2);
        usdc.approve(address(vault), type(uint256).max);
        vault.mintPair(newEpoch, mintAmount);

        PoolKey memory volPool = _key(newLong, address(usdc));
        pm.initialize(volPool, _sqrtPriceFor(newLong, address(usdc), initialPrice));
        oracle.registerVolPool(newEpoch, volPool);

        VarianceToken(newLong).approve(address(lpRouter), type(uint256).max);
        usdc.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            volPool,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: int256(uint256(liquidity)), salt: 0
            }),
            ""
        );

        vm.stopBroadcast();

        console2.log("== settled epoch", oldEpoch, "==");
        console2.log("  realized variance (WAD)", vault.realizedVariance(oldEpoch));
        console2.log("  payoff p (WAD)         ", payoffWad);
        console2.log("  VAR-LONG  redeemed     ", longPaid);
        console2.log("  VAR-SHORT redeemed     ", shortPaid);
        console2.log("  dust retained by vault ", vault.epoch(oldEpoch).collateralHeld);
        console2.log("== opened epoch", newEpoch, "==");
        console2.log("  VAR-LONG   ", newLong);
        console2.log("  VAR-SHORT  ", address(vault.epoch(newEpoch).shortToken));
        console2.log("  endBlock   ", vault.epoch(newEpoch).endBlock);
        console2.log("  vol pool id", vm.toString(PoolId.unwrap(volPool.toId())));
        console2.log("  implied vol", oracle.impliedVol(measured));
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

    function _sqrtPriceFor(address longToken, address collateral, uint256 priceWad) internal pure returns (uint160) {
        uint256 ratioWad = longToken < collateral ? priceWad : Math.mulDiv(1e18, 1e18, priceWad);
        return uint160(Math.sqrt(Math.mulDiv(ratioWad, 1 << 192, 1e18)));
    }
}
