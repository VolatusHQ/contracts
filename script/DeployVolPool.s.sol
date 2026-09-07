// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {VolatusVault} from "../src/VolatusVault.sol";
import {VolatusOracle} from "../src/VolatusOracle.sol";

/// @notice Opens an epoch on a measured pool and creates the v4 pool where its VAR-LONG trades.
///
/// @dev This second pool is where implied volatility is discovered — the price of VAR-LONG in it
///      *is* the market's expectation of normalized variance. It is an ordinary v4 pool over two
///      ordinary ERC-20s, which is exactly why the variance legs had to be ERC-20 rather than
///      ERC-6909; see `DECISIONS.md` §1.
///
///      `INITIAL_PRICE_WAD` seeds the pool at a starting guess in (0, 1). It is a starting point
///      for price discovery, not a claim about fair value.
contract DeployVolPool is Script {
    function run() external {
        VolatusVault vault = VolatusVault(vm.envAddress("VOLATUS_VAULT"));
        VolatusOracle oracle = VolatusOracle(vm.envAddress("VOLATUS_ORACLE"));
        PoolId measuredPool = PoolId.wrap(vm.envBytes32("MEASURED_POOL_ID"));

        uint48 endBlock = uint48(vm.envUint("EPOCH_END_BLOCK"));
        uint32 horizonSeconds = uint32(vm.envUint("EPOCH_HORIZON_SECONDS"));
        uint256 strikeWad = vm.envUint("EPOCH_STRIKE_WAD");
        uint256 capWad = vm.envUint("EPOCH_CAP_WAD");
        uint256 initialPriceWad = vm.envUint("INITIAL_PRICE_WAD");

        address collateral = address(vault.collateral());

        vm.startBroadcast();

        uint256 epochId = vault.openEpoch(measuredPool, endBlock, horizonSeconds, strikeWad, capWad);
        address longToken = address(vault.epoch(epochId).longToken);

        bool longIsCurrency0 = longToken < collateral;
        (Currency c0, Currency c1) = longIsCurrency0
            ? (Currency.wrap(longToken), Currency.wrap(collateral))
            : (Currency.wrap(collateral), Currency.wrap(longToken));

        // slot0 stores currency1 per currency0, so invert when VAR-LONG is the second currency.
        uint256 ratioWad = longIsCurrency0 ? initialPriceWad : Math.mulDiv(1e18, 1e18, initialPriceWad);
        uint160 sqrtPriceX96 = uint160(Math.sqrt(Math.mulDiv(ratioWad, 1 << 192, 1e18)));

        PoolKey memory volPoolKey =
            PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: IHooks(address(0))});

        IPoolManager(address(oracle.poolManager())).initialize(volPoolKey, sqrtPriceX96);
        oracle.registerVolPool(epochId, volPoolKey);

        vm.stopBroadcast();

        console2.log("epochId      ", epochId);
        console2.log("VAR-LONG     ", longToken);
        console2.log("VAR-SHORT    ", address(vault.epoch(epochId).shortToken));
        console2.log("vol pool id  ", vm.toString(PoolId.unwrap(volPoolKey.toId())));
        console2.log("endBlock     ", endBlock);
    }
}
