// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";

import {Permit3} from "@core/permit3/Permit3.sol";
import {Settlement} from "@core/settlement/Settlement.sol";
import {SettlementLens} from "@periphery/SettlementLens.sol";

/// @title DeployedBytecode
/// @notice The core test harness's opt-in switch from the TEST build of `Permit3` and
///         `Settlement` to the DEPLOYED one.
///
///  WHY (audit 2026-09-29, lens F L-1): production ships `Settlement` and `Permit3`
///  from `[profile.core-deploy]` — via-IR, `optimizer_runs = 100`, `cancun` — but the
///  test tree compiles under the legacy `[profile.core]`. Hand-written assembly whose
///  `memory-safe-assembly` promise only the via-IR optimizer relies on is therefore
///  never executed as shipped. Compiling the TEST tree via-IR takes 20+ minutes, so
///  instead the legacy-compiled tests deploy the via-IR ARTIFACT:
///
///      make test-deployed                                  # builds + runs
///      DEPLOYED_BYTECODE=1 DEPLOYED_ARTIFACTS=<dir> FOUNDRY_PROFILE=core forge test
///
///  ENV (read when the test contract is CONSTRUCTED)
///    `DEPLOYED_BYTECODE`   `1`/`true` turns the switch on. Unset (or anything else):
///                          plain `new`, exactly the historical harness.
///    `DEPLOYED_ARTIFACTS`  directory holding a `core-deploy`-profile build. Default
///                          `out/test-deployed`: the private dir `make test-deployed`
///                          rebuilds on every run — NOT `out/core-deploy`, which
///                          `size-check`/deploy builds share and a stale copy of which
///                          would be tested silently. Must lie under `./out` (see
///                          `fs_permissions` in foundry.toml).
///
///  SEMANTICS ARE THOSE OF `new`. {DeployedBytecodeHelper} is reached by DELEGATECALL,
///  so its CREATEs are executed BY the test contract: same deployer, same nonces, same
///  order — hence the SAME addresses in both modes, and the same Solidity types. Only
///  Permit3 and Settlement (and the executor Settlement's constructor creates) come
///  from the via-IR artifacts; the lens and everything else stay the test build. A
///  failed CREATE bubbles its revert data exactly as `new` does, which `expectRevert`
///  depends on (it reports "wrong error" and "did not revert" by failing the CREATE;
///  a raw `create` that ignored a zero address would turn both into silent passes).
///
///  TWO ENTRY POINTS
///    • `setUp` sites use this gas-neutral pattern (the DEFAULT run must not move):
///
///          if (DEPLOYED_BYTECODE) {
///              assembly ("memory-safe") {
///                  let plan := or(SHIP_ALL, or(shl(8, permit3.offset), shl(16, permit3.slot)))
///                  plan := or(plan, or(shl(80, settlement.offset), shl(88, settlement.slot)))
///                  plan := or(plan, or(shl(152, lens.offset), shl(160, lens.slot)))
///                  mstore(0x00, DEPLOY_PLAN_SELECTOR)
///                  mstore(0x04, plan)
///                  if iszero(delegatecall(gas(), DEPLOYED_BYTECODE_HELPER, 0x00, 0x24, 0x00, 0x00)) {
///                      returndatacopy(0x00, 0x00, returndatasize())
///                      revert(0x00, returndatasize())
///                  }
///              }
///          } else {
///              permit3 = new Permit3();            // the original lines, verbatim
///              settlement = new Settlement(address(permit3));
///              lens = new SettlementLens(address(settlement));
///          }
///
///      The plan word names each variable's storage `slot`/`offset` (NO_SLOT: don't
///      store); the helper — running as this contract — CREATEs in the same order as
///      the `else` branch and writes the addresses straight into those slots.
///    • test BODIES that must deploy under the switch use `_newPermit3()` /
///      `_newSettlement(p3)` — readable, but they move a metered body's gas, so only
///      where the default run skips the test anyway.
///
///  ⚠ WHY SO CONTORTED — MEASURED. `.gas-snapshot` meters test bodies, and test bodies
///  share one contract, and one legacy-optimizer pass, with `setUp`. That optimizer's
///  choices are contract-global: the ConstantOptimiser picks ONE encoding per large
///  constant from its occurrence count (`0xff…e0` is a PUSH32 up to 10 uses and
///  `PUSH1 0x1f NOT`, +3 gas, from 11 on; in `RoundingDirectionTest` the 160-bit address
///  mask sat at exactly 92 uses and a 93rd flipped it to `sub(shl(160, 1), 1)`, +9 gas
///  per use), the Inliner inlines a shared jump-out block or not from how many sites
///  push its tag, and block layout decides which `PUSH tag JUMP` pairs the peephole pass
///  can drop. So any extra `and(sload(slot), mask)`, any extra call/return, anywhere in
///  the contract, can move every test in it. Against the unmodified tree (804 non-fuzz):
///      JSON/string handling inline in the test contract            479 moved
///      `settlement = _newSettlement(address(permit3))` in setUp     357 moved
///      plan word + `_deployShippedInto(plan)` internal call,
///        joined BEFORE `lens = new SettlementLens(...)`             4 moved (−11..+6,396)
///        joined after it                                            1 moved (−11)
///      the pattern above (inline assembly, no internal call)       0 moved
///  (Fuzz μ/~ lines are no yardstick: re-running the UNMODIFIED tree with the pinned
///  `--fuzz-seed` already moves 32..48 of them.)
///  (Row 3: the original straight-line code handed the new Settlement to the lens from
///  the stack; after a join it must `sload` + mask it — the 93rd mask. Row 4: one fewer
///  tag-push reshuffled block layout and dropped a `PUSH2 JUMP` in CalldataSizeBench.)
///  Rules, then: everything touching bytes/strings lives in {DeployedBytecodeHelper};
///  the flag is an immutable (set by constructor code, optimized apart from the
///  runtime); the setUp glue is inline assembly whose only large constants are its
///  own; the `else` branch is the ORIGINAL statements verbatim, through the last one
///  that consumes their values. Do NOT add `external`/`public` functions here (they
///  reshuffle every inheriting test's dispatcher), and re-measure the default run
///  against a clean tree after any change to this file or to a site.
abstract contract DeployedBytecode {
    /// @dev Where {DeployedBytecodeHelper} is etched. Arbitrary but fixed:
    ///      `address(uint160(uint256(keccak256("1delta.test.DeployedBytecodeHelper"))))`.
    address internal constant DEPLOYED_BYTECODE_HELPER = 0x0539FeA6D55aC371E71B244845d9fAFC9caD4473;

    /// @dev Plan-word flags (bits 0..7) and the "do not store" offset. Layout:
    ///      [0..7] flags · [8..15] Permit3 offset · [16..79] Permit3 slot
    ///      · [80..87] Settlement offset · [88..151] Settlement slot
    ///      · [152..159] lens offset · [160..223] lens slot.
    ///      Without SHIP_PERMIT3, a Settlement is built over the Permit3 already stored
    ///      in the Permit3 slot. SHIP_LENS needs SHIP_SETTLEMENT.
    uint256 internal constant SHIP_PERMIT3 = 1;
    uint256 internal constant SHIP_SETTLEMENT = 2;
    uint256 internal constant SHIP_LENS = 4;
    uint256 internal constant SHIP_BOTH = 3;
    uint256 internal constant SHIP_ALL = 7;
    uint256 internal constant NO_SLOT = 0xff;
    /// @dev `DeployedBytecodeHelper.deploy(uint256)` selector, left-aligned (a literal so
    ///      inline assembly can use it).
    uint256 internal constant DEPLOY_PLAN_SELECTOR = 0xa5e3875100000000000000000000000000000000000000000000000000000000;

    /// @dev `DEPLOYED_BYTECODE` env switch, frozen when the test contract is deployed.
    bool internal immutable DEPLOYED_BYTECODE = _initDeployedBytecode();

    function _initDeployedBytecode() private returns (bool on) {
        Vm vm_ = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
        on = vm_.envOr("DEPLOYED_BYTECODE", false);
        if (on && DEPLOYED_BYTECODE_HELPER.code.length == 0) {
            vm_.etch(DEPLOYED_BYTECODE_HELPER, type(DeployedBytecodeHelper).runtimeCode);
            // Survives the `createSelectFork` in {CoreSettlementBase.setUp}.
            vm_.makePersistent(DEPLOYED_BYTECODE_HELPER);
        }
    }

    /// @dev `new Permit3()`, or the deployed artifact under the switch. For test BODIES.
    function _newPermit3() internal returns (Permit3) {
        if (!DEPLOYED_BYTECODE) return new Permit3();
        return Permit3(_deployShipped(0, address(0)));
    }

    /// @dev `new Settlement(permit3_)`, or the deployed artifact under the switch. For
    ///      test BODIES.
    function _newSettlement(address permit3_) internal returns (Settlement) {
        if (!DEPLOYED_BYTECODE) return new Settlement(permit3_);
        return Settlement(payable(_deployShipped(1, permit3_)));
    }

    function _deployShipped(uint256 kind, address arg) private returns (address deployed) {
        assembly ("memory-safe") {
            let p := mload(0x40) // scratch above the free pointer; never allocated
            mstore(p, shl(224, 0xdf02995d)) // deploy(uint256,address)
            mstore(add(p, 0x04), kind)
            mstore(add(p, 0x24), arg)
            if iszero(delegatecall(gas(), DEPLOYED_BYTECODE_HELPER, p, 0x44, 0x00, 0x20)) {
                returndatacopy(p, 0x00, returndatasize())
                revert(p, returndatasize())
            }
            deployed := mload(0x00)
        }
    }
}

/// @notice Reads a `core-deploy` artifact and CREATEs it. Runs ONLY by DELEGATECALL
///         from a {DeployedBytecode} test contract, so the CREATEs, the storage writes
///         and every cheatcode call are that test contract's own. Holds no state.
contract DeployedBytecodeHelper {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev setUp form; see {DeployedBytecode} for the plan-word layout.
    function deploy(uint256 plan) external {
        address p3;
        if (plan & 1 != 0) {
            p3 = _create(0, address(0));
            _store(plan >> 16, plan >> 8, p3);
        } else {
            uint256 off = (plan >> 8) & 0xff;
            require(off < 32, "DeployedBytecode: no Permit3 slot to build over");
            p3 = address(uint160(uint256(_sload(uint64(plan >> 16))) >> (off * 8)));
        }
        if (plan & 2 == 0) return;
        address s = _create(1, p3);
        _store(plan >> 88, plan >> 80, s);
        if (plan & 4 == 0) return;
        // The lens is NOT a shipped-bytecode subject here; it is the test build, created
        // in the same slot of the nonce sequence as `new SettlementLens(...)`.
        address lens = address(new SettlementLens(s));
        _store(plan >> 160, plan >> 152, lens);
    }

    /// @dev Test-body form: 0 = Permit3, 1 = Settlement(`arg`).
    function deploy(uint256 kind, address arg) external returns (address) {
        return _create(kind, arg);
    }

    function _create(uint256 kind, address arg) private returns (address deployed) {
        string memory dir = VM.envOr("DEPLOYED_ARTIFACTS", string("out/test-deployed"));
        string memory path =
            string.concat(dir, kind == 0 ? "/Permit3.sol/Permit3.json" : "/Settlement.sol/Settlement.json");
        string memory json = VM.readFile(path);
        // Guard: pointed at a legacy build, the whole run would silently re-test the
        // ordinary bytecode under a green "deployed bytecode" label.
        // (A legacy artifact has no `viaIR` key at all, hence the existence check.)
        require(
            VM.keyExistsJson(json, ".metadata.settings.viaIR") && VM.parseJsonBool(json, ".metadata.settings.viaIR"),
            string.concat("DeployedBytecode: ", path, " was not compiled via-IR (run `make test-deployed`)")
        );
        bytes memory initcode = VM.parseJsonBytes(json, ".bytecode.object");
        if (kind != 0) initcode = abi.encodePacked(initcode, abi.encode(arg));
        /// @solidity memory-safe-assembly
        assembly {
            deployed := create(0, add(initcode, 0x20), mload(initcode))
            // Bubble exactly like `new` (see {DeployedBytecode}).
            if iszero(deployed) {
                let p := mload(0x40)
                returndatacopy(p, 0x00, returndatasize())
                revert(p, returndatasize())
            }
        }
    }

    /// @dev Write `a` into this frame's (= the test contract's) storage at `slotWord`'s
    ///      low 64 bits, byte offset `offWord`'s low 8 bits, preserving packed
    ///      neighbours. Offset NO_SLOT (0xff) = don't store.
    function _store(uint256 slotWord, uint256 offWord, address a) private {
        uint256 off = offWord & 0xff;
        if (off == 0xff) return;
        require(off <= 12, "DeployedBytecode: bad slot offset");
        uint256 slot = uint64(slotWord);
        uint256 shift = off * 8;
        uint256 mask = uint256(type(uint160).max) << shift;
        uint256 w = (uint256(_sload(slot)) & ~mask) | (uint256(uint160(a)) << shift);
        assembly {
            sstore(slot, w)
        }
    }

    function _sload(uint256 slot) private view returns (bytes32 w) {
        assembly {
            w := sload(slot)
        }
    }
}
