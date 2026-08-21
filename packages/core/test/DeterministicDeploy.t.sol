// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {DeployCore} from "../script/Deploy.s.sol";
import {IDeployFactory, DEPLOY_FACTORY} from "../script/IDeployFactory.sol";

import {Permit3} from "../src/permit3/Permit3.sol";
import {Settlement} from "../src/settlement/Settlement.sol";
import {SettlementLens} from "../src/periphery/SettlementLens.sol";

/// @dev Stand-in for the external CREATE2 factory that really lives at
///      {DEPLOY_FACTORY} on every chain in the matched set. Reproduces the two
///      properties the rollout depends on and nothing else: the address is
///      `keccak256(0xff ‖ factory ‖ salt ‖ initCodeHash)`, and NOTHING is mixed in
///      from `msg.sender` — the real factory was verified behaviourally to have
///      that same property across all four of its runtime variants
///      (`docs/deterministic-deployment.md` §1.1).
contract MockDeployFactory {
    function deploy(bytes32 salt, bytes memory bytecode) external returns (address addr) {
        assembly {
            addr := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        require(addr != address(0), "create2 failed");
    }

    function computeAddress(bytes32 salt, bytes32 bytecodeHash) external view returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, bytecodeHash))))
        );
    }
}

/// @title DeterministicDeploy
/// @notice Exercises {DeployCore} — the script that has to put the core singletons
///         on identical addresses on every chain.
///
///  Why this is tested rather than eyeballed: the failure mode is silent. A deploy
///  that lands on the wrong address still produces a working settlement on that one
///  chain; what breaks is every OTHER chain's prediction of it, and the bridge
///  package turns that into stranded funds (§2). There is no runtime symptom to
///  notice later, so the guarantees have to be asserted up front.
contract DeterministicDeployTest is Test {
    DeployCore internal script;

    function setUp() public {
        // Put the mock factory at the real factory's address, so the script's
        // hardcoded {DEPLOY_FACTORY} constant is what actually gets called.
        vm.etch(DEPLOY_FACTORY, address(new MockDeployFactory()).code);
        script = new DeployCore();
    }

    /// @dev The whole point: a full run lands every contract exactly where
    ///      {DeployCore.predict} said it would. The script asserts this internally
    ///      too ({_deploy} reverts on mismatch); this proves the assertion is
    ///      reachable and passes on the happy path rather than being dead code.
    function test_deploy_landsOnPredictedAddresses() public {
        (address p1, address s1, address l1) = _predicted();

        script.run();

        assertEq(p1.code.length > 0, true, "Permit3 not deployed");
        assertEq(s1.code.length > 0, true, "Settlement not deployed");
        assertEq(l1.code.length > 0, true, "SettlementLens not deployed");

        // The wiring the script asserts, re-checked from the outside.
        assertEq(address(Settlement(payable(s1)).PERMIT3()), p1, "Settlement -> Permit3");
        assertEq(address(SettlementLens(l1).SETTLEMENT()), s1, "Lens -> Settlement");
    }

    /// @dev The dependency chain is real: Settlement's address is a function of
    ///      Permit3's, because `permit3` is a constructor arg and constructor args
    ///      are part of init code (§2). If Permit3 ever diverges, everything below
    ///      it diverges silently — this pins that the linkage exists rather than
    ///      the three being independently salted.
    function test_predict_settlementBindsPermit3Address() public view {
        (address permit3, address settlement,) = _predicted();

        bytes32 realHash = keccak256(abi.encodePacked(type(Settlement).creationCode, abi.encode(permit3)));
        bytes32 wrongHash = keccak256(abi.encodePacked(type(Settlement).creationCode, abi.encode(address(0xdead))));

        IDeployFactory f = IDeployFactory(DEPLOY_FACTORY);
        assertEq(f.computeAddress(_salt(), realHash), settlement, "predicted != derived");
        assertTrue(f.computeAddress(_salt(), wrongHash) != settlement, "a different Permit3 must move Settlement");
    }

    /// @dev Re-running a completed rollout must be a no-op, not a revert. The real
    ///      factory has no access control, so a stranger can deploy our
    ///      byte-identical contracts at our addresses first and make our own run
    ///      collide (§1); the script survives that by treating "code already there"
    ///      as success. Same reason a half-finished rollout can be resumed.
    function test_deploy_isIdempotent() public {
        script.run();
        (address p1, address s1, address l1) = _predicted();

        script.run(); // must not revert

        assertEq(address(Settlement(payable(s1)).PERMIT3()), p1, "Settlement rewired on rerun");
        assertEq(address(SettlementLens(l1).SETTLEMENT()), s1, "Lens rewired on rerun");
    }

    /// @dev The factory must not mix `msg.sender` into the address, or two operators
    ///      deploying the same rollout would land on different addresses and the
    ///      matched set would be impossible. Verified on the real factory's four
    ///      runtime variants (§1.1); asserted here so the mock cannot drift from
    ///      that assumption and quietly invalidate every test above.
    function test_factory_addressIsSenderIndependent() public {
        bytes32 h = keccak256(type(Permit3).creationCode);
        IDeployFactory f = IDeployFactory(DEPLOY_FACTORY);

        vm.prank(address(0xdead));
        address a = f.computeAddress(_salt(), h);
        vm.prank(address(0xBeefBeef));
        address b = f.computeAddress(_salt(), h);

        assertEq(a, b, "computeAddress depends on caller");
    }

    /// @dev A different salt is a different address family. Pinned because the salt
    ///      is the one input an operator supplies by hand (`CORE_SALT`), so getting
    ///      it wrong is the most reachable way to break the set.
    function test_saltChangesEveryAddress() public view {
        IDeployFactory f = IDeployFactory(DEPLOY_FACTORY);
        bytes32 h = keccak256(type(Permit3).creationCode);
        assertTrue(
            f.computeAddress(_salt(), h) != f.computeAddress(keccak256("other"), h), "salt must move the address"
        );
    }

    // ──────────────── helpers ────────────────

    /// @dev Mirrors the script's own placeholder-salt fallback; `CORE_SALT` is unset
    ///      under `forge test`.
    function _salt() internal view returns (bytes32) {
        return vm.envOr("CORE_SALT", keccak256("1delta.core.v1.PLACEHOLDER"));
    }

    function _predicted() internal view returns (address permit3, address settlement, address lens) {
        IDeployFactory f = IDeployFactory(DEPLOY_FACTORY);
        bytes32 salt = _salt();
        permit3 = f.computeAddress(salt, keccak256(type(Permit3).creationCode));
        settlement =
            f.computeAddress(salt, keccak256(abi.encodePacked(type(Settlement).creationCode, abi.encode(permit3))));
        lens = f.computeAddress(
            salt, keccak256(abi.encodePacked(type(SettlementLens).creationCode, abi.encode(settlement)))
        );
    }
}
