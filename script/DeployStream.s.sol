// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {VolatusStream} from "../src/VolatusStream.sol";

/// @notice Deploys the streaming coverage rail on Arc and opens the first subscription.
///
/// @dev On Arc, USDC is simultaneously the native gas asset (18-decimal view) and an ERC-20 at
///      `0x3600…0000` (6-decimal view). They are the *same* pool of funds seen two ways, not two
///      assets. Everything here works in the 6-decimal ERC-20 view; only gas uses the native one.
///
///      **This script deliberately does not touch USDC.** Arc's USDC ERC-20 calls a blocklist
///      precompile at `0x1800…0001`, which exists on the chain but not in Foundry's local EVM —
///      and `forge script` executes the script body locally to collect transactions even with
///      `--skip-simulation`, so any script that transfers USDC dies with `StackUnderflow` before
///      a single transaction is sent. Deployment and epoch setup happen here; funding capacity
///      and opening a subscription are done with `cast send` against the live chain.
///
///          forge script script/DeployStream.s.sol --rpc-url $ARC_TESTNET_RPC --broadcast
contract DeployStream is Script {
    /// @dev USDC ERC-20 view on Arc. Same funds as the native balance.
    address internal constant ARC_USDC = 0x3600000000000000000000000000000000000000;

    function run() external {
        address me = msg.sender;

        // Mirrors the epoch already open in VolatusVault on Unichain.
        uint256 epochId = vm.envOr("EPOCH_ID", uint256(1));
        uint64 horizon = uint64(vm.envOr("HORIZON_SECONDS", uint256(3600)));

        vm.startBroadcast();

        VolatusStream stream = new VolatusStream(IERC20(ARC_USDC), me);

        uint64 coverageEnd = uint64(block.timestamp) + horizon;
        uint64 reportDeadline = coverageEnd + 1 days;
        stream.openEpoch(epochId, coverageEnd, reportDeadline);

        vm.stopBroadcast();

        console2.log("== VolatusStream on Arc Testnet ==");
        console2.log("VolatusStream       ", address(stream));
        console2.log("USDC (ERC-20 view)", ARC_USDC);
        console2.log("reporter          ", me);
        console2.log("epochId           ", epochId);
        console2.log("coverageEnd (ts)  ", coverageEnd);
        console2.log("reportDeadline    ", reportDeadline);
        console2.log("");
        console2.log("Next, with cast (the script cannot touch USDC -- see the note above):");
        console2.log("  approve, postCapacity, subscribe, fund");
    }
}
