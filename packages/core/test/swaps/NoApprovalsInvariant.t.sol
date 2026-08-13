// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order} from "@core/settlement/Settlement.sol";

import {MockSettlementBase} from "../shared/MockSettlementBase.t.sol";

/// @dev An ERC20 that records every `approve` it ever sees, keyed by caller. The
///      recording is the point: asserting a zero ALLOWANCE at the end would also
///      pass if Settlement granted an approval and then cleared it, and a
///      transient approval inside a fill is still an approval an interaction
///      could exploit while it is live.
///
///      Standalone rather than a `MockERC20` subclass — the shared mock's
///      `approve` is non-virtual, and the invariant does not warrant reshaping
///      infrastructure every other core suite depends on.
contract ApprovalRecordingToken {
    string public name;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    mapping(address => uint256) public approveCalls;
    address[] public approvers;

    constructor(string memory _name) {
        name = _name;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (approveCalls[msg.sender] == 0) approvers.push(msg.sender);
        approveCalls[msg.sender] += 1;
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approverCount() external view returns (uint256) {
        return approvers.length;
    }
}

/// @title NoApprovalsInvariantTest
/// @notice Pins the "Settlement never grants an ERC20 approval" invariant (F4).
///
///  This was an INFO-level item from the item-aware netted-settle review, carried
///  as an unenforced assumption rather than a bug. It matters because the batch
///  paths' completeness argument leans on it: the whole-check reasons over
///  "item tokens ⊆ the order's leg universe", and that containment only holds
///  because Settlement cannot move a token that is not part of a leg. The instant
///  Settlement holds an allowance to some third party — or grants one — a token
///  outside the leg universe becomes reachable and the completeness proof stops
///  being a proof.
///
///  It is also the reason Settlement can safely hold transient balances mid-fill:
///  with no approvals outstanding, the only way funds leave is a transfer that
///  Settlement itself makes, bounded by the per-fill balance deltas.
///
///  The review noted this was "a cheap future guard". This is that guard.
contract NoApprovalsInvariantTest is MockSettlementBase {
    uint256 constant IN_ = 1_000e18;
    uint256 constant OUT_ = 900e18;

    ApprovalRecordingToken rA;
    ApprovalRecordingToken rB;

    function setUp() public override {
        super.setUp();
        rA = new ApprovalRecordingToken("rA");
        rB = new ApprovalRecordingToken("rB");
    }

    function _fund(uint256 amountIn, uint256 amountOut) internal {
        rA.mint(maker, amountIn);
        rB.mint(solver, amountOut);

        vm.startPrank(maker);
        rA.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(rA), uint160(amountIn), 0);
        vm.stopPrank();

        vm.startPrank(solver);
        rB.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(rB), uint160(amountOut), 0);
        vm.stopPrank();
    }

    /// @dev The maker and solver each legitimately approve Permit3 in `_fund`, so
    ///      a bare "nobody approved" assertion would be wrong. What must hold is
    ///      that SETTLEMENT is never among the approvers.
    function _assertSettlementNeverApproved() internal view {
        assertEq(rA.approveCalls(address(settlement)), 0, "settlement approved rA");
        assertEq(rB.approveCalls(address(settlement)), 0, "settlement approved rB");
        assertEq(rA.allowance(address(settlement), address(permit3)), 0, "settlement holds a standing rA allowance");
        assertEq(rB.allowance(address(settlement), address(permit3)), 0, "settlement holds a standing rB allowance");
    }

    /// A full single fill grants no approval.
    function test_fill_grantsNoApproval() public {
        _fund(IN_, OUT_);
        Order memory order = _plainOrder(1, address(rA), address(rB), IN_, OUT_);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, IN_);

        assertEq(rB.balanceOf(maker), OUT_, "the fill actually happened");
        _assertSettlementNeverApproved();
    }

    /// Partial fills — the path that leaves the order live across calls — grant no
    /// approval either, at any point in the sequence.
    function test_partialFills_grantNoApproval() public {
        _fund(IN_, OUT_);
        Order memory order = _plainOrder(2, address(rA), address(rB), IN_, OUT_);
        bytes memory sig = _sign(order);

        vm.startPrank(solver);
        settlement.fill(order, sig, IN_ / 4);
        _assertSettlementNeverApproved();
        settlement.fill(order, sig, IN_ / 4);
        _assertSettlementNeverApproved();
        settlement.fill(order, sig, IN_ / 2);
        vm.stopPrank();

        assertEq(rA.balanceOf(maker), 0, "order fully consumed");
        _assertSettlementNeverApproved();
    }

    /// `fillUpTo` — the clamping entry point — is on the same footing.
    function test_fillUpTo_grantsNoApproval() public {
        _fund(IN_, OUT_);
        Order memory order = _plainOrder(3, address(rA), address(rB), IN_, OUT_);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fillUpTo(order, sig, type(uint256).max, address(0), 0, "");

        _assertSettlementNeverApproved();
    }

    /// The invariant stated as the property the batch completeness argument needs:
    /// Settlement holds no allowance to ANY spender, so no token outside an
    /// order's leg universe is reachable through it.
    function testFuzz_settlementHoldsNoAllowanceToAnySpender(address spender) public {
        _fund(IN_, OUT_);
        Order memory order = _plainOrder(4, address(rA), address(rB), IN_, OUT_);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, IN_);

        assertEq(rA.allowance(address(settlement), spender), 0, "no rA allowance to any spender");
        assertEq(rB.allowance(address(settlement), spender), 0, "no rB allowance to any spender");
    }

    /// Settlement is never even an APPROVER of anything, for any token it touched.
    /// Stronger than a per-spender check: it pins the call, not the residue.
    function test_settlementIsNeverAnApprover() public {
        _fund(IN_, OUT_);
        Order memory order = _plainOrder(5, address(rA), address(rB), IN_, OUT_);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, IN_);

        for (uint256 i; i < rA.approverCount(); i++) {
            assertTrue(rA.approvers(i) != address(settlement), "settlement appeared as an rA approver");
        }
        for (uint256 i; i < rB.approverCount(); i++) {
            assertTrue(rB.approvers(i) != address(settlement), "settlement appeared as an rB approver");
        }
    }
}
