// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {VolatusHook} from "../src/VolatusHook.sol";

/// @notice Finds the CREATE2 salt that lands VolatusHook on an address encoding its permissions.
///
/// @dev A v4 hook advertises what it does in the low bits of its own address, and PoolManager
///      refuses to deploy against a hook whose bits disagree with `getHookPermissions`. So the
///      address is not chosen, it is mined: brute-force salts through the deterministic CREATE2
///      deployer until one lands on the right bits.
///
///      Run before `DeployVolatus.s.sol` and pass the salt through:
///
///          forge script script/MineSalt.s.sol --rpc-url $UNICHAIN_SEPOLIA_RPC
contract MineSalt is Script {
    /// @dev The canonical deterministic CREATE2 factory, present on every OP-stack chain.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external view {
        address poolManager = vm.envAddress("POOL_MANAGER");

        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);

        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(VolatusHook).creationCode,
            abi.encode(IPoolManager(poolManager), vm.envAddress("VAULT_SETTER"))
        );

        console2.log("PoolManager  ", poolManager);
        console2.log("Flags        ", uint256(flags));
        console2.log("Hook address ", hookAddress);
        console2.log("Salt         ", vm.toString(salt));
    }
}
