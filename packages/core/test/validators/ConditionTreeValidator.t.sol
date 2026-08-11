// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {ConditionTreeValidator} from "@core/validators/ConditionTreeValidator.sol";
import {IOrderValidator} from "@core/interfaces/IOrderValidator.sol";
import {Order} from "@core/settlement/Settlement.sol";
import {PackedEncode} from "../shared/PackedEncode.sol";
import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";
import {Item, Validator} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

// ── Leaf mocks ────────────────────────────────────────────────────────────────

contract AlwaysTrue is IOrderValidator {
    function validate(Order calldata, address, bytes calldata, bytes calldata) external pure returns (bool) {
        return true;
    }
}

contract AlwaysFalse is IOrderValidator {
    function validate(Order calldata, address, bytes calldata, bytes calldata) external pure returns (bool) {
        return false;
    }
}

contract AlwaysReverts is IOrderValidator {
    error Boom();

    function validate(Order calldata, address, bytes calldata, bytes calldata) external pure returns (bool) {
        revert Boom();
    }
}

/// @dev Returns fewer than 32 bytes — indistinguishable from a revert for our
///      purposes, and treated identically.
contract ReturnsShort is IOrderValidator {
    function validate(Order calldata, address, bytes calldata, bytes calldata) external pure returns (bool) {
        assembly {
            return(0x00, 0x08)
        }
    }
}

/// @dev Records that it was called, so a test can prove a leaf was NOT reached.
///      Uses a storage write, so it must be reached through a non-static path —
///      here it simply reverts if invoked, which is what the short-circuit tests
///      assert the absence of.
contract ExplodesIfCalled is IOrderValidator {
    error ShouldNotHaveBeenCalled();

    function validate(Order calldata, address, bytes calldata, bytes calldata) external pure returns (bool) {
        revert ShouldNotHaveBeenCalled();
    }
}

/// @dev Boolean composition over other validators. The properties under test are
///      the ones a flat AND-list cannot have: disjunction, negation, and the fact
///      that a REVERTING leaf is an error rather than a silent `false`.
contract ConditionTreeValidatorTest is Test {
    ConditionTreeValidator tree;
    address T; // always true
    address F; // always false
    address R; // always reverts
    address S; // returns short
    address X; // must never be called

    uint8 constant NEGATE = 1;
    uint8 constant TRY = 2;

    function setUp() public {
        tree = new ConditionTreeValidator();
        T = address(new AlwaysTrue());
        F = address(new AlwaysFalse());
        R = address(new AlwaysReverts());
        S = address(new ReturnsShort());
        X = address(new ExplodesIfCalled());
    }

    // ── Encoding helpers (mirror of the on-chain layout) ──────────────────────

    function _leaf(address target, uint8 flags) internal pure returns (bytes memory) {
        return abi.encodePacked(flags, target, uint16(0));
    }

    function _grp(bytes[] memory leaves) internal pure returns (bytes memory out) {
        out = abi.encodePacked(uint8(leaves.length));
        for (uint256 i; i < leaves.length; i++) {
            out = abi.encodePacked(out, leaves[i]);
        }
    }

    function _dnf(bytes[] memory groups) internal pure returns (bytes memory out) {
        out = abi.encodePacked(uint8(groups.length));
        for (uint256 i; i < groups.length; i++) {
            out = abi.encodePacked(out, groups[i]);
        }
    }

    function _one(bytes memory a) internal pure returns (bytes[] memory r) {
        r = new bytes[](1);
        r[0] = a;
    }

    function _two(bytes memory a, bytes memory b) internal pure returns (bytes[] memory r) {
        r = new bytes[](2);
        r[0] = a;
        r[1] = b;
    }

    function _order() internal pure returns (Order memory o) {
        o.maker = address(0xA11CE);
        o.curve = PackedEncode.noCurve();
        o.items = PackedEncode.noItems();
        o.validators = PackedEncode.noValidators();
        o.invariants = PackedEncode.noValidators();
    }

    function _eval(bytes memory blob) internal view returns (bool) {
        return tree.validate(_order(), address(0xF111E4), blob, "");
    }

    // ──────────────────── Boolean semantics ────────────────────

    function test_singleLeaf() public view {
        assertTrue(_eval(_dnf(_one(_grp(_one(_leaf(T, 0)))))), "true leaf");
        assertFalse(_eval(_dnf(_one(_grp(_one(_leaf(F, 0)))))), "false leaf");
    }

    function test_and_requiresEveryLeaf() public view {
        assertTrue(_eval(_dnf(_one(_grp(_two(_leaf(T, 0), _leaf(T, 0)))))), "T AND T");
        assertFalse(_eval(_dnf(_one(_grp(_two(_leaf(T, 0), _leaf(F, 0)))))), "T AND F");
        assertFalse(_eval(_dnf(_one(_grp(_two(_leaf(F, 0), _leaf(T, 0)))))), "F AND T");
    }

    /// The whole point: a disjunction inside ONE order.
    function test_or_satisfiedByEitherGroup() public view {
        assertTrue(_eval(_dnf(_two(_grp(_one(_leaf(F, 0))), _grp(_one(_leaf(T, 0)))))), "F OR T");
        assertTrue(_eval(_dnf(_two(_grp(_one(_leaf(T, 0))), _grp(_one(_leaf(F, 0)))))), "T OR F");
        assertFalse(_eval(_dnf(_two(_grp(_one(_leaf(F, 0))), _grp(_one(_leaf(F, 0)))))), "F OR F");
    }

    function test_negate() public view {
        assertTrue(_eval(_dnf(_one(_grp(_one(_leaf(F, NEGATE)))))), "NOT false");
        assertFalse(_eval(_dnf(_one(_grp(_one(_leaf(T, NEGATE)))))), "NOT true");
    }

    /// `(A OR B) AND C` distributed to `(A AND C) OR (B AND C)` — the shape a
    /// caller writes when the disjunction is not already at the top.
    function test_distributedExpression() public view {
        bytes memory blob = _dnf(_two(_grp(_two(_leaf(F, 0), _leaf(T, 0))), _grp(_two(_leaf(T, 0), _leaf(T, 0)))));
        assertTrue(_eval(blob), "(F AND T) OR (T AND T)");
    }

    // ──────────────────── Short-circuiting ────────────────────
    //
    // Proven by placing a leaf that REVERTS IF CALLED in the position that must
    // be skipped: if evaluation reached it, the test would revert.

    function test_shortCircuit_falseLeafSkipsRestOfGroup() public view {
        assertFalse(_eval(_dnf(_one(_grp(_two(_leaf(F, 0), _leaf(X, 0)))))), "second leaf never called");
    }

    function test_shortCircuit_satisfiedGroupSkipsLaterGroups() public view {
        assertTrue(_eval(_dnf(_two(_grp(_one(_leaf(T, 0))), _grp(_one(_leaf(X, 0)))))), "second group never called");
    }

    /// A skipped subtree is still PARSED — the cursor has to reach the end for the
    /// exact-consumption check — so a malformed record inside a skipped group is
    /// still caught.
    function test_skippedGroupIsStillParsed() public {
        bytes memory good = _grp(_one(_leaf(T, 0)));
        bytes memory truncated = abi.encodePacked(uint8(1), uint8(0), address(0)); // leaf header cut short
        vm.expectRevert(ConditionTreeValidator.MalformedTree.selector);
        _eval(_dnf(_two(good, truncated)));
    }

    // ──────────────────── Revert is an ERROR, not `false` ────────────────────

    /// The footgun this contract exists to prevent: without this rule,
    /// `NOT(brokenOracle)` would read TRUE precisely when the feed is broken.
    function test_revertingLeaf_abortsRatherThanReadingFalse() public {
        vm.expectRevert(ConditionTreeValidator.ConditionErrored.selector);
        _eval(_dnf(_one(_grp(_one(_leaf(R, 0))))));
    }

    function test_shortReturnLeaf_alsoAborts() public {
        vm.expectRevert(ConditionTreeValidator.ConditionErrored.selector);
        _eval(_dnf(_one(_grp(_one(_leaf(S, 0))))));
    }

    /// ...and the negated form is the one that actually matters.
    function test_negatedRevertingLeaf_doesNotBecomeTrue() public {
        vm.expectRevert(ConditionTreeValidator.ConditionErrored.selector);
        _eval(_dnf(_one(_grp(_one(_leaf(R, NEGATE))))));
    }

    function test_try_convertsRevertToFalse() public view {
        assertFalse(_eval(_dnf(_one(_grp(_one(_leaf(R, TRY)))))), "TRY absorbs the revert");
    }

    /// The documented fallback shape: "price >= X, or if the feed is down, timeout".
    function test_try_enablesOracleFallback() public view {
        bytes memory blob = _dnf(_two(_grp(_one(_leaf(R, TRY))), _grp(_one(_leaf(T, 0)))));
        assertTrue(_eval(blob), "broken oracle falls through to the timeout branch");
    }

    function test_tryPlusNegate_isCoherent() public view {
        // "reverted or false" -> true. Documented as coherent but rarely intended.
        assertTrue(_eval(_dnf(_one(_grp(_one(_leaf(R, NEGATE | TRY)))))), "TRY then NEGATE");
    }

    // ──────────────────── Malformed blobs ────────────────────
    //
    // Every one of these must ABORT. The dangerous failure is not a revert, it is
    // a malformed condition that silently evaluates to an unconditional answer.

    function test_emptyBlob_reverts() public {
        vm.expectRevert(ConditionTreeValidator.MalformedTree.selector);
        _eval("");
    }

    function test_zeroGroups_reverts() public {
        // An empty disjunction is vacuously FALSE — rejected rather than honoured.
        vm.expectRevert(ConditionTreeValidator.MalformedTree.selector);
        _eval(abi.encodePacked(uint8(0)));
    }

    function test_emptyGroup_reverts() public {
        // An empty conjunction is vacuously TRUE — the dangerous direction.
        vm.expectRevert(ConditionTreeValidator.MalformedTree.selector);
        _eval(abi.encodePacked(uint8(1), uint8(0)));
    }

    function test_truncatedLeafHeader_reverts() public {
        vm.expectRevert(ConditionTreeValidator.MalformedTree.selector);
        _eval(abi.encodePacked(uint8(1), uint8(1), uint8(0), address(T)));
    }

    function test_leafDataRunningPastTheEnd_reverts() public {
        vm.expectRevert(ConditionTreeValidator.MalformedTree.selector);
        _eval(abi.encodePacked(uint8(1), uint8(1), uint8(0), address(T), uint16(64)));
    }

    function test_unknownFlagBit_reverts() public {
        vm.expectRevert(ConditionTreeValidator.MalformedTree.selector);
        _eval(_dnf(_one(_grp(_one(_leaf(T, 4))))));
    }

    function test_trailingBytes_reverts() public {
        vm.expectRevert(ConditionTreeValidator.TrailingBytes.selector);
        _eval(abi.encodePacked(_dnf(_one(_grp(_one(_leaf(T, 0))))), uint8(0xFF)));
    }

    /// A group count larger than the groups actually present must be caught by the
    /// bounds check, never read past the blob.
    function test_overstatedGroupCount_reverts() public {
        vm.expectRevert(ConditionTreeValidator.MalformedTree.selector);
        _eval(abi.encodePacked(uint8(2), _grp(_one(_leaf(T, 0)))));
    }

    /// Leaf `data` is forwarded verbatim, so a leaf that inspects it still works.
    function test_leafDataIsForwarded() public view {
        bytes memory payload = hex"deadbeef";
        bytes memory blob =
            abi.encodePacked(uint8(1), uint8(1), uint8(0), address(T), uint16(payload.length), payload);
        assertTrue(_eval(blob), "leaf with data");
    }
}

/// @dev End-to-end: a disjunction actually gating a real fill through Settlement.
///      The unit tests above pin the evaluator; this pins that the evaluator is
///      reached the ordinary way — one entry in `order.validators`, no core change.
contract ConditionTreeSettlementTest is CoreSettlementBase {
    ConditionTreeValidator tree;
    address T;
    address F;

    uint256 constant USDC_IN = 2_000e6;
    uint256 constant WETH_OUT = 1 ether;

    function setUp() public override {
        super.setUp();
        tree = new ConditionTreeValidator();
        T = address(new AlwaysTrue());
        F = address(new AlwaysFalse());

        deal(USDC, maker, USDC_IN);
        deal(WETH, solver, WETH_OUT);
        vm.prank(maker);
        permit3.approveToken(address(settlement), USDC, uint160(USDC_IN), 0);
        _approveSolverSide(WETH_OUT, WETH);
    }

    function _dnfTwoGroups(address a, address b) internal pure returns (bytes memory) {
        // (a) OR (b) — one leaf each, no flags.
        return abi.encodePacked(
            uint8(2), uint8(1), uint8(0), a, uint16(0), uint8(1), uint8(0), b, uint16(0)
        );
    }

    function _orderWithTree(uint256 nonce, bytes memory blob) internal view returns (Order memory) {
        Validator[] memory vs = new Validator[](1);
        vs[0] = Validator({target: address(tree), data: blob});
        return _orderWithValidators(nonce, USDC, WETH, USDC_IN, WETH_OUT, new Item[](0), vs);
    }

    /// The failing branch does not block the fill — which a flat AND-list could
    /// never express.
    function test_e2e_orSatisfiedBySecondBranch_fills() public {
        Order memory order = _orderWithTree(0, _dnfTwoGroups(F, T));
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, USDC_IN);
        assertEq(IERC20(USDC).balanceOf(solver), USDC_IN, "filled on the second branch");
    }

    /// ...and when neither branch holds, the fill is blocked exactly as any other
    /// failing validator blocks it.
    function test_e2e_neitherBranch_blocksFill() public {
        Order memory order = _orderWithTree(1, _dnfTwoGroups(F, F));
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.ValidationFailed.selector, uint256(0)));
        settlement.fill(order, sig, USDC_IN);
    }
}
