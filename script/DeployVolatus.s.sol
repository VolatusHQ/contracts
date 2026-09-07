// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {VolatusHook} from "../src/VolatusHook.sol";
import {VolatusVault} from "../src/VolatusVault.sol";
import {VolatusOracle} from "../src/VolatusOracle.sol";
import {VarianceToken} from "../src/VarianceToken.sol";
import {IVolatusHook} from "../src/interfaces/IVolatusHook.sol";

/// @notice Deploys the whole protocol and wires it together.
///
/// @dev Order matters and is forced by two constraints. The hook's address must encode its
///      permissions, so it is mined and deployed through the deterministic CREATE2 factory. And
///      the hook and the vault each need the other's address, which no constructor ordering can
///      satisfy — hence `setVault`, a one-shot deployer-only call made here and never again.
///
///          POOL_MANAGER=0x00B036B58a818B1BC34d502D3fE730Db729e62AC \
///          COLLATERAL=<usdc> \
///          forge script script/DeployVolatus.s.sol --rpc-url $UNICHAIN_SEPOLIA_RPC --broadcast --verify
contract DeployVolatus is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        IERC20 collateral = IERC20(vm.envAddress("COLLATERAL"));

        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(VolatusHook).creationCode, abi.encode(poolManager, msg.sender));

        vm.startBroadcast();

        (bool ok,) = CREATE2_DEPLOYER.call(
            abi.encodePacked(salt, type(VolatusHook).creationCode, abi.encode(poolManager, msg.sender))
        );
        require(ok && hookAddress.code.length > 0, "hook deploy failed");
        VolatusHook hook = VolatusHook(hookAddress);
        require(hook.vaultSetter() == msg.sender, "vaultSetter must survive factory deployment");

        VarianceToken tokenImplementation = new VarianceToken();
        VolatusVault vault = new VolatusVault(collateral, IVolatusHook(address(hook)), address(tokenImplementation));

        // The single trusted-setup step. After this the hook has no administrator at all.
        hook.setVault(address(vault));

        VolatusOracle oracle = new VolatusOracle(poolManager, vault, IVolatusHook(address(hook)), msg.sender);

        vm.stopBroadcast();

        console2.log("VolatusHook          ", address(hook));
        console2.log("VarianceToken impl ", address(tokenImplementation));
        console2.log("VolatusVault         ", address(vault));
        console2.log("VolatusOracle        ", address(oracle));
        console2.log("collateral         ", address(collateral));
        console2.log("PoolManager        ", address(poolManager));
    }
}
