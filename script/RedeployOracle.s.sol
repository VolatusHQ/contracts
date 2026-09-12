// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {VolatusOracle} from "../src/VolatusOracle.sol";
import {VolatusVault} from "../src/VolatusVault.sol";
import {IVolatusHook} from "../src/interfaces/IVolatusHook.sol";

/// @notice Redeploys `VolatusOracle` against the *existing* pool manager/vault/hook, with a
///         `curator` the team actually holds the key to.
///
/// @dev The live oracle's `curator` is `0x364EDC06254874e62FF4AD8fA4d9a45238cb5609` — the same
///      lost deployer key `BACKEND_PROGRESS.md` already documents as unrecoverable (it is what
///      forced the `SigmaStream` `settlementReporter` redeploy earlier). `registerVolPool`
///      reverts `NotCurator` forever on that instance, so nothing can ever register a vol pool
///      for a new epoch. `VolatusOracle` holds no funds and its only state is `_volPool`
///      (per-epoch vol-pool registrations, `src/VolatusOracle.sol:57`), so this is a clean
///      redeploy, not a migration — no data to carry over. Epochs opened after this redeploy
///      register against the new oracle; whatever epoch was active under the old one keeps
///      working for settlement (which reads the hook directly, never the oracle) but never gets
///      a registered vol pool.
///
///      Usage:
///
///          POOL_MANAGER=0x00B036B58a818B1BC34d502D3fE730Db729e62AC \
///          VOLATUS_VAULT=<existing vault address> \
///          VOLATUS_HOOK=<existing hook address> \
///          CURATOR=<address the redeploy trusts, e.g. the roller service's own wallet> \
///          forge script script/RedeployOracle.s.sol --rpc-url $UNICHAIN_SEPOLIA_RPC --broadcast --verify
///
///      `CURATOR` is a required, explicit argument rather than defaulting to `msg.sender` —
///      deliberately, so the broadcasting key (whoever pays gas for this one-off deploy) and the
///      curator key (whoever calls `registerVolPool` on every future epoch, indefinitely) are not
///      silently forced to be the same key. Pass the same address for both if that is the intent.
contract RedeployOracle is Script {
    function run() external {
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        VolatusVault vault = VolatusVault(vm.envAddress("VOLATUS_VAULT"));
        IVolatusHook hook = IVolatusHook(vm.envAddress("VOLATUS_HOOK"));
        address curator = vm.envAddress("CURATOR");

        require(curator != address(0), "CURATOR must not be the zero address");

        vm.startBroadcast();
        VolatusOracle oracle = new VolatusOracle(poolManager, vault, hook, curator);
        vm.stopBroadcast();

        console2.log("VolatusOracle (new)", address(oracle));
        console2.log("curator            ", curator);
        console2.log("poolManager        ", address(poolManager));
        console2.log("vault              ", address(vault));
        console2.log("hook               ", address(hook));
        console2.log("");
        console2.log("Next steps: update SIGMA_ORACLE in backend/packages/onchain/src/addresses.ts");
        console2.log("and frontend/app/app/lib/onchain/addresses.ts to the address above, and the");
        console2.log("VolatusOracle row in contracts/README.md's deployment table.");
    }
}
