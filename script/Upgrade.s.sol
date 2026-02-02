// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {SmartAccountWrapper} from "../src/SmartAccountWrapper.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

contract Upgrade is Script {
    function run() public {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("OWNER");
        address beacon = vm.envAddress("BEACON_ADDRESS");
        address wrapper = vm.envAddress("WRAPPER_ADDRESS");

        vm.startBroadcast(privateKey);
        UpgradeableBeacon(beacon).upgradeTo(address(new SmartAccountWrapper()));
        SmartAccountWrapper(wrapper).reinitialize(owner);
        vm.stopBroadcast();
    }
}
