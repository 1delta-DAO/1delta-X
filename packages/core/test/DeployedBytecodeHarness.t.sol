// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "@core/settlement/Base.sol";
import {Settlement} from "@core/settlement/Settlement.sol";

import {MockSettlementBase} from "./shared/MockSettlementBase.t.sol";

/// @title DeployedBytecodeHarness
/// @notice The two checks that only mean something under `make test-deployed`
///         (`DEPLOYED_BYTECODE=1`, see {DeployedBytecode}). Both SKIP otherwise, so
///         the default suite — and its committed gas baseline — is untouched.
///
///  1. The harness really runs the shipped bytecode. A switch that silently fell back
///     to the legacy build would turn the whole deployed-bytecode run into a second,
///     green copy of the ordinary one. The legacy `[profile.core]` Settlement is far
///     over EIP-170 (~36 KB), so "it fits" alone separates the two builds; the length
///     match pins it to the artifact actually on disk.
///  2. The constructor's `InvalidPermit3` guard in the DEPLOYED initcode. It is the one
///     place the core suite `new`s a Settlement in a test BODY
///     ({ErrorSurfaceTest.test_invalidPermit3_codelessHubRejectedAtConstruction}).
///     That test stays on plain `new` on purpose: routing it through the switch would
///     change a metered test body and move its committed gas in the DEFAULT run. Its
///     deployed-bytecode twin lives here instead, in a contract of its own, so the
///     twin does not reshuffle ErrorSurfaceTest's dispatcher either.
contract DeployedBytecodeHarnessTest is MockSettlementBase {
    uint256 internal constant EIP170_RUNTIME_LIMIT = 24_576;

    function test_harness_runsTheShippedBytecode() public {
        vm.skip(!DEPLOYED_BYTECODE);

        assertLe(address(settlement).code.length, EIP170_RUNTIME_LIMIT, "Settlement is not the deployable build");
        assertEq(
            address(settlement).code.length,
            _artifactRuntimeLength("Settlement.sol/Settlement.json"),
            "Settlement != the core-deploy artifact"
        );
        assertEq(
            address(permit3).code.length,
            _artifactRuntimeLength("Permit3.sol/Permit3.json"),
            "Permit3 != the core-deploy artifact"
        );
        // Created by Settlement's own constructor, so it comes from the same initcode.
        assertEq(
            address(settlement.EXECUTOR()).code.length,
            _artifactRuntimeLength("SolverCallbackExecutor.sol/SolverCallbackExecutor.json"),
            "executor != the core-deploy artifact"
        );
    }

    /// @dev Twin of {ErrorSurfaceTest.test_invalidPermit3_codelessHubRejectedAtConstruction}
    ///      against the deployed initcode. {DeployedBytecode} bubbles a failed CREATE
    ///      exactly like `new`, which is what lets `expectRevert` see the selector —
    ///      and makes a wrong selector or a non-revert FAIL rather than pass.
    function test_invalidPermit3_deployedConstructorRejectsCodelessHub() public {
        vm.skip(!DEPLOYED_BYTECODE);

        vm.expectRevert(Base.InvalidPermit3.selector);
        _newSettlement(address(0));

        vm.expectRevert(Base.InvalidPermit3.selector);
        _newSettlement(maker); // an EOA is just as codeless

        Settlement fresh = _newSettlement(address(permit3));
        assertEq(address(fresh.PERMIT3()), address(permit3), "a real hub is accepted");
        assertLe(address(fresh).code.length, EIP170_RUNTIME_LIMIT, "fresh instance is the deployable build");
    }

    function _artifactRuntimeLength(string memory artifact) internal view returns (uint256) {
        string memory dir = vm.envOr("DEPLOYED_ARTIFACTS", string("out/test-deployed"));
        return vm.parseJsonBytes(vm.readFile(string.concat(dir, "/", artifact)), ".deployedBytecode.object").length;
    }
}
