// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {TTASv3} from "../src/v3/TTASv3.sol";
import {TTASFactoryV3} from "../src/v3/TTASFactoryV3.sol";

/// @notice Deploys the TTASv3 implementation and its factory.
///
///   forge script script/DeployV3.s.sol \
///     --rpc-url $RPC_URL --account <keystore-account> --broadcast --verify
///
/// The factory is ownerless and its implementation address is immutable, so this
/// is a one-shot deployment: a future wallet version means a new factory.
contract DeployV3 is Script {
    function run() external returns (TTASv3 implementation, TTASFactoryV3 factory) {
        vm.startBroadcast();

        implementation = new TTASv3();
        factory = new TTASFactoryV3(address(implementation));

        vm.stopBroadcast();

        console2.log("TTASv3 implementation:", address(implementation));
        console2.log("TTASFactoryV3:        ", address(factory));
    }
}
