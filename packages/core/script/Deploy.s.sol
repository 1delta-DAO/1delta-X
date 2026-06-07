// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {Counter} from "../src/Counter.sol";

contract DeployScript is Script {
    function run() public returns (Counter) {
        vm.startBroadcast();
        Counter counter = new Counter();
        vm.stopBroadcast();
        return counter;
    }
}
