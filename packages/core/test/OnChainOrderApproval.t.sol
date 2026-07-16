// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {UniversalSettlement, Order} from "@core/settlement/UniversalSettlement.sol";

import {MockSettlementBase} from "./shared/MockSettlementBase.t.sol";

/// @dev A "dumb" contract maker. Like any multisig it can execute arbitrary calls
///      (`exec`), but it implements NO signature scheme — no EIP-1271
///      `isValidSignature`, no fallback returning the magic value. So NEITHER the
///      ECDSA nor the 1271 branch of {SignatureVerification} can ever authorize it:
///      its only way to place an order is the on-chain {approveOrder} fallback.
contract SignatureLessMaker {
    function exec(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call(data);
        require(ok, "exec failed");
        return ret;
    }
}

/// @title OnChainOrderApprovalTest
/// @notice Coverage for the signature-less order path: a maker that cannot sign
///         (a non-EIP-1271 multisig, modelled by {SignatureLessMaker}) authorizes
///         an order on-chain via {approveOrder}, and a filler settles it with an
///         EMPTY `sig`. Verifies the happy path, the no-approval / wrong-maker /
///         revoked / nonce-cancelled rejections, that approval authorizes partial
///         fills (not a single use), and that it works through `batchFill`.
contract OnChainOrderApprovalTest is MockSettlementBase {
    uint256 constant AMOUNT_IN = 100e18; // tA maker gives
    uint256 constant AMOUNT_OUT = 300e18; // tB maker gets

    SignatureLessMaker cm; // the signature-less contract maker

    function setUp() public override {
        super.setUp();
        cm = new SignatureLessMaker();
        vm.label(address(cm), "sigless-maker");

        // Fund the contract maker with tokenIn and wire its Permit3 allowances —
        // all via ordinary on-chain calls it executes itself. NO signatures anywhere.
        tA.mint(address(cm), 1_000e18);
        cm.exec(address(tA), abi.encodeWithSignature("approve(address,uint256)", address(permit3), type(uint256).max));
        cm.exec(
            address(permit3),
            abi.encodeCall(IPermit3.approveToken, (address(settlement), address(tA), type(uint160).max, uint48(0)))
        );

        // Solver can deliver tokenOut.
        tB.mint(solver, 1_000e18);
        vm.startPrank(solver);
        tB.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(tB), type(uint160).max, 0);
        vm.stopPrank();
    }

    /// @dev A plain SELL order whose maker is the signature-less contract.
    function _order(uint256 nonce) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        o.maker = address(cm);
    }

    /// @dev The maker authorizes `o` on-chain (returns the order hash it recorded).
    function _approve(Order memory o) internal returns (bytes32) {
        bytes memory ret = cm.exec(address(settlement), abi.encodeCall(UniversalSettlement.approveOrder, (o)));
        return abi.decode(ret, (bytes32));
    }

    // ──────────────────── Happy path ────────────────────

    function test_approve_thenFill_emptySig() public {
        Order memory o = _order(1);
        bytes32 hash = _approve(o);

        assertTrue(settlement.orderApproved(address(cm), hash), "approval recorded");

        // Empty sig → the on-chain approval authorizes the fill.
        vm.prank(solver);
        settlement.fill(o, "", AMOUNT_IN);

        assertEq(tB.balanceOf(address(cm)), AMOUNT_OUT, "sigless maker got output");
        assertEq(tA.balanceOf(solver), AMOUNT_IN, "solver got input");
    }

    // ──────────────────── Rejections ────────────────────

    function test_fill_emptySig_withoutApproval_reverts() public {
        Order memory o = _order(1); // never approved
        vm.prank(solver);
        vm.expectRevert(UniversalSettlement.OrderNotApproved.selector);
        settlement.fill(o, "", AMOUNT_IN);
    }

    /// @dev A stranger cannot approve an order whose `maker` is someone else — the
    ///      `order.maker == msg.sender` guard rejects it, and even without the guard
    ///      the mapping is keyed by msg.sender so it would never be consulted.
    function test_approveOrder_wrongMaker_reverts() public {
        Order memory o = _order(1); // maker == cm
        vm.prank(solver);
        vm.expectRevert(UniversalSettlement.NotOrderMaker.selector);
        settlement.approveOrder(o);
    }

    function test_revokeOrderApproval_blocksFill() public {
        Order memory o = _order(1);
        bytes32 hash = _approve(o);

        cm.exec(address(settlement), abi.encodeCall(UniversalSettlement.revokeOrderApproval, (hash)));
        assertFalse(settlement.orderApproved(address(cm), hash), "approval cleared");

        vm.prank(solver);
        vm.expectRevert(UniversalSettlement.OrderNotApproved.selector);
        settlement.fill(o, "", AMOUNT_IN);
    }

    /// @dev Cancelling the order's nonce blocks an on-chain-approved order exactly
    ///      as it blocks a signed one — the nonce gate runs regardless of how the
    ///      order was authorized.
    function test_cancelNonce_blocksApprovedOrder() public {
        Order memory o = _order(1);
        _approve(o);

        uint256[] memory nonces = new uint256[](1);
        nonces[0] = 1;
        cm.exec(address(settlement), abi.encodeWithSignature("cancelOrders(uint256[])", nonces));

        vm.prank(solver);
        vm.expectRevert(UniversalSettlement.NonceCancelled.selector);
        settlement.fill(o, "", AMOUNT_IN);
    }

    // ──────────────────── Partial fills ────────────────────

    /// @dev One approval authorizes the order for partial fills up to its size, just
    ///      like a signature — it is not consumed per fill.
    function test_approval_authorizesPartialFills() public {
        Order memory o = _order(1);
        _approve(o);

        vm.prank(solver);
        settlement.fill(o, "", AMOUNT_IN / 4);
        vm.prank(solver);
        settlement.fill(o, "", (AMOUNT_IN * 3) / 4);

        assertEq(tB.balanceOf(address(cm)), AMOUNT_OUT, "both partials delivered full output");
        assertEq(tA.balanceOf(solver), AMOUNT_IN, "solver paid the full input");
    }

    // ──────────────────── batchFill ────────────────────

    function test_batchFill_approvedOrder_emptySig() public {
        Order memory o = _order(1);
        _approve(o);

        Order[] memory orders = new Order[](1);
        orders[0] = o;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = ""; // empty → approval path
        uint256[] memory amts = new uint256[](1);
        amts[0] = AMOUNT_IN;

        vm.prank(solver);
        (, bool[] memory ok) = settlement.batchFill(orders, sigs, amts, true);
        assertTrue(ok[0], "approved order settled in batch with empty sig");
        assertEq(tB.balanceOf(address(cm)), AMOUNT_OUT, "batch delivered output");
    }
}
