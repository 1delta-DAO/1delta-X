// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";

import {IDeployFactory, DEPLOY_FACTORY} from "./IDeployFactory.sol";

import {Permit3} from "../src/permit3/Permit3.sol";
import {Settlement} from "../src/settlement/Settlement.sol";
import {SettlementLens} from "@periphery/SettlementLens.sol";

/// @title DeployCore
/// @notice Lands the three core singletons — {Permit3}, {Settlement},
///         {SettlementLens} — on IDENTICAL addresses on every chain in the matched
///         set, through the shared CREATE2 {IDeployFactory}.
///
///  ⚠ RUN WITH `FOUNDRY_PROFILE=core-deploy`. Legacy codegen puts Settlement over
///  the EIP-170 runtime limit; only the deploy profile's artifacts fit on-chain
///  (`make size-check` gates this). That profile also pins `bytecode_hash`,
///  `cbor_metadata`, `evm_version` and `optimizer_runs` — all four are inputs to
///  the address. Running this under any other profile produces a DIFFERENT and
///  WRONG address family, silently. Use the `deploy-core` / `predict-core` Makefile
///  targets, which set the profile for you — see {_reportProfileExpectation}.
///
///  Why the addresses have to match
///  ───────────────────────────────
///  Init code = creation bytecode ‖ ABI-encoded constructor args, so determinism
///  propagates down the dependency chain: every argument must ITSELF already be
///  deterministic. That is the whole reason these three deploy together and in
///  this order (`docs/deterministic-deployment.md` §2, §7 step 5):
///
///      Permit3        no constructor args      ← root of the chain
///        └─ Settlement    (permit3)            ← diverges if Permit3 diverged
///             └─ SettlementLens (settlement)
///
///  Settlement's constructor additionally deploys {SolverCallbackExecutor} by plain
///  CREATE, so the executor is a nonce-1 child of a deterministic parent and is
///  deterministic too — it needs no salt and no separate step.
///
///  Downstream packages depend on this having held: the bridge package's
///  `PositionFunnelFactory` takes `(permit3, settlement, lens, grantModule)` as
///  constructor args, and funnel addresses are predicted by OTHER chains before
///  they are deployed. A divergence in any of the three below silently moves every
///  funnel address, stranding tokens already bridged there. That is why this script
///  REVERTS on an address mismatch rather than logging and continuing (§7 step 6).
///
///  Usage
///  ─────
///      # predict only — no key, no broadcast, safe to run anywhere
///      FOUNDRY_PROFILE=core-deploy forge script \
///        packages/core/script/Deploy.s.sol:DeployCore --sig 'predict()' --rpc-url $RPC
///
///      # the real thing
///      FOUNDRY_PROFILE=core-deploy CORE_SALT=0x… forge script \
///        packages/core/script/Deploy.s.sol:DeployCore --rpc-url $RPC --broadcast --verify
///
///  Env: `CORE_SALT` (bytes32) — REQUIRED for a real rollout; see {SALT}.
contract DeployCore is Script {
    /// @dev PLACEHOLDER, and deliberately so. §1 asks that salts be derived from a
    ///      preimage that is NOT published until the rollout is complete: the salt
    ///      is public the moment the first deployment lands, but keeping it out of
    ///      the repo until then keeps predicted addresses out of reach of griefers
    ///      who would otherwise deploy our byte-identical contracts ahead of us and
    ///      make our own runs revert on collision.
    ///
    ///      Pass the real value via `CORE_SALT`. Once a rollout begins it must NEVER
    ///      change — it is an input to every address ever predicted for it.
    bytes32 internal constant PLACEHOLDER_SALT = keccak256("1delta.core.v1.PLACEHOLDER");

    // ──────────────────── Entrypoints ────────────────────

    /// @notice Predict every address WITHOUT deploying. No key, no broadcast — this
    ///         is the call that fills in the deployment registry ahead of a rollout,
    ///         and the one to diff across chains to prove the set still matches.
    function predict() public view {
        (bytes32 salt, bool placeholder) = _salt();

        (address permit3, bytes32 h1) = _predict(salt, _permit3InitCode());
        (address settlement, bytes32 h2) = _predict(salt, _settlementInitCode(permit3));
        (address lens, bytes32 h3) = _predict(salt, _lensInitCode(settlement));

        console.log("--- predicted (chain %s) ---", block.chainid);
        _reportProfileExpectation();
        _report("Permit3", permit3, h1);
        _report("Settlement", settlement, h2);
        _report("SettlementLens", lens, h3);
        _warnIfPlaceholder(placeholder);
    }

    /// @notice Deploy the three singletons, asserting each landed on its predicted
    ///         address. Idempotent: a contract already present at its predicted
    ///         address is left alone and reported, so re-running a partially
    ///         completed rollout finishes it instead of reverting on collision.
    function run() public {
        (bytes32 salt, bool placeholder) = _salt();
        _assertFactoryPresent();

        vm.startBroadcast();

        address permit3 = _deploy("Permit3", salt, _permit3InitCode());
        address settlement = _deploy("Settlement", salt, _settlementInitCode(permit3));
        address lens = _deploy("SettlementLens", salt, _lensInitCode(settlement));

        vm.stopBroadcast();

        // Wiring assertions. These cannot fail if the addresses above are right, and
        // that is exactly why they are worth running: they are a cheap, independent
        // check that the code at each address is the code we think it is, reading
        // the deployed contracts rather than trusting the init code we just sent.
        require(address(Settlement(payable(settlement)).PERMIT3()) == permit3, "Settlement: wrong Permit3");
        require(address(SettlementLens(lens).SETTLEMENT()) == settlement, "Lens: wrong Settlement");
        require(address(SettlementLens(lens).PERMIT3()) == permit3, "Lens: wrong Permit3");

        console.log("SolverCallbackExecutor", address(Settlement(payable(settlement)).EXECUTOR()));
        _warnIfPlaceholder(placeholder);
    }

    // ──────────────────── Init code ────────────────────
    //
    // Kept as three one-liners rather than inlined so the ARGUMENT LIST of each is
    // visible in one place — every one of these args is part of an address, and the
    // dependency order above is only correct because of what appears here.

    function _permit3InitCode() private pure returns (bytes memory) {
        return type(Permit3).creationCode; // no constructor args — root of the chain
    }

    function _settlementInitCode(address permit3) private pure returns (bytes memory) {
        return abi.encodePacked(type(Settlement).creationCode, abi.encode(permit3));
    }

    function _lensInitCode(address settlement) private pure returns (bytes memory) {
        return abi.encodePacked(type(SettlementLens).creationCode, abi.encode(settlement));
    }

    // ──────────────────── Machinery ────────────────────

    function _predict(bytes32 salt, bytes memory initCode) private view returns (address addr, bytes32 initCodeHash) {
        initCodeHash = keccak256(initCode);
        addr = IDeployFactory(DEPLOY_FACTORY).computeAddress(salt, initCodeHash);
    }

    /// @dev Deploy one contract and prove it landed where it was predicted.
    ///
    ///      The already-deployed branch is not a convenience. `deploy` has no access
    ///      control (see {IDeployFactory}), so anyone may deploy our byte-identical
    ///      contract at our address first — and our own run then reverts on the
    ///      CREATE2 collision. Treating "code is already there" as success is what
    ///      makes that harmless, and it is sound because the address BINDS the init
    ///      code: code at the predicted address can only have come from the exact
    ///      init code we just hashed.
    ///
    ///      That is also why this does not compare runtime bytecode against a
    ///      reference. It could not: {Permit3} reads `block.chainid` into an
    ///      immutable at construction, and immutables are written into the runtime
    ///      code, so the RUNTIME legitimately differs per chain while the INIT code
    ///      — the thing the address derives from — stays identical.
    function _deploy(string memory name, bytes32 salt, bytes memory initCode) private returns (address) {
        (address predicted, bytes32 initCodeHash) = _predict(salt, initCode);

        if (predicted.code.length != 0) {
            console.log("= %s already deployed", name);
            _report(name, predicted, initCodeHash);
            return predicted;
        }

        address deployed = IDeployFactory(DEPLOY_FACTORY).deploy(salt, initCode);

        // §7 step 6: assert, and REVERT on mismatch. A silent divergence here
        // strands funds downstream, so it must fail loudly rather than continue.
        require(deployed == predicted, string.concat(name, ": address mismatch"));
        require(deployed.code.length != 0, string.concat(name, ": no code at deployed address"));

        console.log("+ %s deployed", name);
        _report(name, deployed, initCodeHash);
        return deployed;
    }

    /// @dev Everything the deployment registry needs for this contract (§7 step 7).
    function _report(string memory name, address addr, bytes32 initCodeHash) private pure {
        console.log("  %s", name);
        console.log("    address      ", addr);
        console.log("    initCodeHash ");
        console.logBytes32(initCodeHash);
    }

    /// @dev Returns the salt AND whether it was the placeholder, rather than
    ///      recording that in storage: {predict} is `view` so a book or a CI job can
    ///      call it with no key and no broadcast, and a state write would forfeit
    ///      that for nothing.
    function _salt() private view returns (bytes32 salt, bool placeholder) {
        salt = vm.envOr("CORE_SALT", bytes32(0));
        if (salt == bytes32(0)) return (PLACEHOLDER_SALT, true);
        return (salt, false);
    }

    function _warnIfPlaceholder(bool placeholder) private pure {
        if (!placeholder) return;
        console.log("");
        console.log("!! CORE_SALT unset - used the committed PLACEHOLDER salt.");
        console.log("!! Addresses above are NOT the rollout addresses. Set CORE_SALT.");
    }

    /// @dev The factory is the one thing this script cannot deploy, and a chain
    ///      without it can never join the matched set (§7 step 3). Fail here rather
    ///      than let `deploy` return a success-shaped result from an empty address.
    function _assertFactoryPresent() private view {
        require(DEPLOY_FACTORY.code.length != 0, "DeployFactory absent on this chain - see docs sec 4");
    }

    /// @dev The wrong-profile guard is NOT here, deliberately. A script cannot see
    ///      its own compiler settings: `type(Settlement).runtimeCode` — the one
    ///      observable that would distinguish via-IR from legacy codegen — is
    ///      unavailable for any contract with immutables, and Settlement has them
    ///      (`PERMIT3`, `EXECUTOR`). Every other in-Solidity proxy is a magic
    ///      constant that goes stale on the next source edit.
    ///
    ///      So the guard lives at the layer that actually knows the profile: the
    ///      `deploy-core` / `predict-core` Makefile targets set
    ///      `FOUNDRY_PROFILE=core-deploy` themselves. Use those rather than invoking
    ///      `forge script` by hand — a hand-run under the default profile produces a
    ///      silently WRONG address family, and nothing downstream would catch it.
    function _reportProfileExpectation() private view {
        console.log("  (init code below is only correct under FOUNDRY_PROFILE=core-deploy)");
        console.log("  creationCode sizes: Permit3 %s / Settlement %s / Lens %s",
            type(Permit3).creationCode.length,
            type(Settlement).creationCode.length,
            type(SettlementLens).creationCode.length);
    }
}
