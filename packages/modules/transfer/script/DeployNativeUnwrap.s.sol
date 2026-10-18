// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {NativeUnwrapModule} from "../src/NativeUnwrapModule.sol";

/// @title DeployNativeUnwrap
/// @notice Deploys the {NativeUnwrapModule} singleton (in-fill native-out: a wrapped-native
///         output leg is unwrapped and pushed to the maker as raw native coin, inside the
///         fill) and asserts its immutables. Task 28 — RBTC receipts on Rootstock.
///
///  ⚠ RUN WITH `FOUNDRY_PROFILE=modules-transfer-deploy` (the `deploy-native-unwrap`
///  make target sets it): that profile pins `evm_version = "cancun"` — Rootstock does
///  not run Prague, and the repo default targets it.
///
///  Plain CREATE, no salt: the module's identity is its three constructor arguments
///  (wrapped native, Settlement, send gas), all chain-specific. Stateless: nothing to configure
///  after deployment, no owner, no admin.
///
///  The signer comes from the CLI (`--account`/`--sender`, `--ledger`, `--private-key`);
///  `vm.startBroadcast()` is called with no key. Without `--broadcast` the run is a
///  simulation against the live chain (addresses, gas, the assertions below).
///
///  Env
///  ───
///    SETTLEMENT   required — the deployed Settlement (must have code)
///    WRAPPED      the chain's wrapped native coin; default on chain 30 = WRBTC
///                 0x542fDA317318eBF1d3DEAf76E0b632741A7e677d (must have code)
///    SEND_GAS     gas the native send gives the recipient before the module pays it in
///                 WETH instead (batch safety, 2026-10-15); default 100,000 — room for
///                 a smart-account `receive()`, a bounded cost per recipient in a batch
contract DeployNativeUnwrap is Script {
    address constant ROOTSTOCK_WRBTC = 0x542fDA317318eBF1d3DEAf76E0b632741A7e677d;
    uint256 constant DEFAULT_SEND_GAS = 100_000;

    error NoCode(string what, address at);
    error ImmutableMismatch(string what);

    function run() external returns (NativeUnwrapModule module) {
        address settlement = vm.envAddress("SETTLEMENT");
        address wrapped = vm.envOr("WRAPPED", block.chainid == 30 ? ROOTSTOCK_WRBTC : address(0));
        if (settlement.code.length == 0) revert NoCode("SETTLEMENT", settlement);
        if (wrapped.code.length == 0) revert NoCode("WRAPPED", wrapped);
        uint256 sendGas = vm.envOr("SEND_GAS", DEFAULT_SEND_GAS);
        console.log("chain      ", block.chainid);
        console.log("settlement ", settlement);
        console.log("wrapped    ", wrapped);
        console.log("send gas   ", sendGas);

        vm.startBroadcast();
        module = new NativeUnwrapModule(wrapped, settlement, sendGas);
        vm.stopBroadcast();

        if (address(module.WETH()) != wrapped) revert ImmutableMismatch("WETH");
        if (module.SETTLEMENT() != settlement) revert ImmutableMismatch("SETTLEMENT");
        if (module.SEND_GAS() != sendGas) revert ImmutableMismatch("SEND_GAS");
        console.log("NativeUnwrapModule");
        console.log(address(module));
        console.log("runtime size", address(module).code.length);
    }
}
