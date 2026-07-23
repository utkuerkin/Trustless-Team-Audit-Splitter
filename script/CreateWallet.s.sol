// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {TTASv3} from "../src/v3/TTASv3.sol";
import {TTASFactoryV3} from "../src/v3/TTASFactoryV3.sol";

/// @notice Creates a team wallet through an already-deployed factory.
///
/// Configure via environment variables (comma-separated lists must line up):
///
///   FACTORY=0x...                          # TTASFactoryV3 address
///   MEMBERS=0xAlice,0xBob                  # 1..12 unique member addresses
///   SHARES=60000,40000                     # per-member shares, sum = 100000
///   TOKENS=0xUSDC,0xWETH                   # 1..10 unique payment tokens
///   THRESHOLD=66667                        # votes to pass: 50001..100000
///
///   forge script script/CreateWallet.s.sol \
///     --rpc-url $RPC_URL --account <keystore-account> --broadcast
contract CreateWallet is Script {
    function run() external returns (address wallet) {
        TTASFactoryV3 factory = TTASFactoryV3(vm.envAddress("FACTORY"));
        address[] memory members = vm.envAddress("MEMBERS", ",");
        uint256[] memory shares = vm.envUint("SHARES", ",");
        address[] memory tokens = vm.envAddress("TOKENS", ",");
        uint256 threshold = vm.envUint("THRESHOLD");

        vm.startBroadcast();
        wallet = factory.createWallet(members, shares, tokens, threshold);
        vm.stopBroadcast();

        console2.log("Team wallet deployed:", wallet);
        console2.log("Members:", members.length);
        console2.log("Approval threshold:", threshold);

        TTASv3 w = TTASv3(wallet);
        for (uint256 i = 0; i < members.length; i++) {
            console2.log(members[i], "->", w.shares(members[i]));
        }
    }
}
