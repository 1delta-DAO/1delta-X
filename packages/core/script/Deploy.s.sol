// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";

/// @dev Run with `FOUNDRY_PROFILE=core-deploy` — the via-IR deployment profile.
///      Legacy codegen puts Settlement over the EIP-170 runtime limit; only the
///      deploy profile's artifacts fit on-chain (`make size-check` gates this).
contract DeployScript is Script {
    function run() public {}
}
