// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item} from "@core/settlement/Settlement.sol";
import {OrderState} from "@core/settlement/OrderState.sol";
import {SignatureVerification} from "@core/permit3/SignatureVerification.sol";
import {Signatures} from "@core/settlement/Signatures.sol";
import {MockMakerWallet} from "./PlainSwap.t.sol";

/// @dev Maker-nominated order signers ({OrderState.setOrderSigner}) — the session
///      key / trading-desk primitive.
///
///      The property under test throughout is the BOUND, not the capability: a
///      delegate may author exactly the orders its nominating maker could have
///      authored itself, and nothing else. That bound is what separates this from
///      a protocol-level "operator", where an admin-nominated key signs the order
///      and the user signs only a constant.
contract DelegatedOrderSignerTest is CoreSettlementBase {
    uint256 constant DELEGATE_PK = 0xD11E6A7E;
    uint256 constant OUTSIDER_PK = 0x0157DE12;

    address delegate = vm.addr(DELEGATE_PK);
    address outsider = vm.addr(OUTSIDER_PK);

    uint256 constant USDC_IN = 2_000e6;
    uint256 constant WETH_OUT = 1 ether;

    function _stage() internal {
        deal(USDC, maker, USDC_IN);
        deal(WETH, solver, WETH_OUT);
        vm.prank(maker);
        permit3.approveToken(address(settlement), USDC, uint160(USDC_IN), 0);
        _approveSolverSide(WETH_OUT, WETH);
    }

    function _order0() internal view returns (Order memory) {
        return _order(maker, 0, USDC, WETH, USDC_IN, WETH_OUT, new Item[](0));
    }

    /// @dev Sign an order digest with an arbitrary key (the base helper only signs
    ///      with the maker's).
    function _signAs(uint256 pk, Order memory o) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), _hashOrder(o)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _nominate(uint256 expiry) internal {
        vm.prank(maker);
        settlement.setOrderSigner(delegate, expiry);
    }

    bytes32 constant SIGNER_TH =
        keccak256("OrderSignerPermit(address maker,address signer,uint256 expiry,uint256 nonce,uint256 deadline)");

    /// @dev Sign an `OrderSignerPermit` with `pk`.
    function _signPermit(uint256 pk, address maker_, address signer_, uint256 expiry, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(SIGNER_TH, maker_, signer_, expiry, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    // ──────────────────── Gasless nomination ────────────────────

    /// The point of the relayed variant: a maker with no gas is exactly the maker
    /// the gasless-order flow exists for, and they cannot send `setOrderSigner`.
    function test_permit_nominatesGaslessly() public {
        _stage();
        uint256 dl = block.timestamp + 1 hours;
        bytes memory permit = _signPermit(makerPk, maker, delegate, type(uint256).max, 7, dl);

        vm.prank(solver); // ANY relayer may submit it
        settlement.setOrderSignerWithSig(maker, delegate, type(uint256).max, 7, dl, permit);
        assertEq(settlement.orderSignerExpiry(maker, delegate), type(uint256).max, "nominated");

        Order memory order = _order0();
        bytes memory sig = _signAs(DELEGATE_PK, order);
        vm.prank(solver);
        settlement.fill(order, sig, USDC_IN);
        assertEq(IERC20(USDC).balanceOf(solver), USDC_IN, "delegate can now sign orders");
    }

    /// THE security test for this path. A delegate must not be able to appoint
    /// further delegates — the permit is verified against `maker` through the shared
    /// verifier, never through the delegated branch, so the nomination graph stays
    /// exactly one level deep.
    function test_permit_delegateCannotReDelegate() public {
        _stage();
        _nominate(type(uint256).max); // maker -> delegate

        uint256 dl = block.timestamp + 1 hours;
        // The delegate tries to name `outsider` as a signer FOR THE MAKER.
        bytes memory forged = _signPermit(DELEGATE_PK, maker, outsider, type(uint256).max, 9, dl);

        vm.prank(solver);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        settlement.setOrderSignerWithSig(maker, outsider, type(uint256).max, 9, dl, forged);

        assertEq(settlement.orderSignerExpiry(maker, outsider), 0, "no second-level delegate");
    }

    function test_permit_replayRejected() public {
        _stage();
        uint256 dl = block.timestamp + 1 hours;
        bytes memory permit = _signPermit(makerPk, maker, delegate, type(uint256).max, 7, dl);

        vm.prank(solver);
        settlement.setOrderSignerWithSig(maker, delegate, type(uint256).max, 7, dl, permit);

        // Revoke directly, then try to replay the old nomination permit.
        vm.prank(maker);
        settlement.setOrderSigner(delegate, 0);

        vm.prank(solver);
        vm.expectRevert(OrderState.NonceCancelled.selector);
        settlement.setOrderSignerWithSig(maker, delegate, type(uint256).max, 7, dl, permit);
        assertEq(settlement.orderSignerExpiry(maker, delegate), 0, "revocation stands");
    }

    /// The permit rides the maker's ORDER nonce space, so the cancellation
    /// primitives they already have kill an outstanding nomination they never
    /// wanted relayed.
    function test_permit_preCancelledNonceRejected() public {
        _stage();
        uint256 dl = block.timestamp + 1 hours;
        bytes memory permit = _signPermit(makerPk, maker, delegate, type(uint256).max, 7, dl);

        uint256[] memory kill = new uint256[](1);
        kill[0] = 7;
        vm.prank(maker);
        settlement.cancelOrders(kill);

        vm.prank(solver);
        vm.expectRevert(OrderState.NonceCancelled.selector);
        settlement.setOrderSignerWithSig(maker, delegate, type(uint256).max, 7, dl, permit);
    }

    function test_permit_deadlineEnforced() public {
        _stage();
        uint256 dl = block.timestamp + 1 hours;
        bytes memory permit = _signPermit(makerPk, maker, delegate, type(uint256).max, 7, dl);

        vm.warp(dl + 1);
        vm.prank(solver);
        vm.expectRevert(Signatures.SignerPermitExpired.selector);
        settlement.setOrderSignerWithSig(maker, delegate, type(uint256).max, 7, dl, permit);
    }

    // ──────────────────── EIP-7702 makers ────────────────────

    /// A 7702 account signing with its OWN key returns early on
    /// `signer == expected` and never reaches the delegated branch or the
    /// `code.length` test — carrying delegate code changes nothing.
    function test_7702RawKeyMaker_unaffectedByDelegation() public {
        address acct = address(0x77020D);
        MockMakerWallet impl = new MockMakerWallet(maker);
        vm.etch(acct, address(impl).code);

        deal(USDC, acct, USDC_IN);
        deal(WETH, solver, WETH_OUT);
        vm.startPrank(acct);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDC, uint160(USDC_IN), 0);
        settlement.setOrderSigner(delegate, type(uint256).max); // 7702 account nominates
        vm.stopPrank();

        // The delegate signs for the 7702 account — the account has CODE, so this
        // exercises the delegated branch on a non-zero-code maker.
        Order memory order = _order(acct, 0, USDC, WETH, USDC_IN, WETH_OUT, new Item[](0));
        bytes memory sig = _signAs(DELEGATE_PK, order);

        vm.prank(solver);
        settlement.fill(order, sig, USDC_IN);
        assertEq(IERC20(USDC).balanceOf(solver), USDC_IN, "delegate signed for a 7702 maker");
    }

    /// A 7702 account delegated to a 1271 wallet still verifies through
    /// `isValidSignature` — the delegated branch probes the registry, misses, and
    /// falls through exactly as before. This is the path that NEEDS
    /// `code.length != 0`, so it is the one to pin.
    function test_7702Delegated1271Maker_stillFallsThroughTo1271() public {
        address acct = address(0x77020D);
        MockMakerWallet impl = new MockMakerWallet(maker); // validates makerPk sigs
        vm.etch(acct, address(impl).code);

        deal(USDC, acct, USDC_IN);
        deal(WETH, solver, WETH_OUT);
        vm.startPrank(acct);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDC, uint160(USDC_IN), 0);
        vm.stopPrank();

        // Signed by makerPk, which the wallet's 1271 accepts but ecrecover maps to
        // `maker`, NOT `acct` — so the registry probe runs and must not swallow it.
        Order memory order = _order(acct, 0, USDC, WETH, USDC_IN, WETH_OUT, new Item[](0));
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, USDC_IN);
        assertEq(IERC20(USDC).balanceOf(solver), USDC_IN, "1271 fallback intact");
    }

    // ──────────────────── The capability ────────────────────

    function test_delegate_canSignForTheMaker() public {
        _stage();
        _nominate(type(uint256).max);

        Order memory order = _order0();
        bytes memory sig = _signAs(DELEGATE_PK, order);

        vm.prank(solver);
        settlement.fill(order, sig, USDC_IN);

        assertEq(IERC20(USDC).balanceOf(solver), USDC_IN, "delegated order settled");
        assertEq(IERC20(WETH).balanceOf(maker), WETH_OUT, "maker received the output");
    }

    /// The maker's own signature is unaffected — delegation is additive.
    function test_maker_stillSignsForThemselves() public {
        _stage();
        _nominate(type(uint256).max);

        Order memory order = _order0();
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, USDC_IN);
        assertEq(IERC20(USDC).balanceOf(solver), USDC_IN, "self-signed still works");
    }

    // ──────────────────── The bound ────────────────────

    /// THE test. A delegate is nominated BY a maker FOR that maker. It cannot sign
    /// an order naming anyone else — the registry is read at `order.maker`, and the
    /// order hash commits to `maker`, so there is no order the delegate can author
    /// that its nominator could not have authored itself.
    function test_delegate_cannotSignForADifferentMaker() public {
        _stage();
        _nominate(type(uint256).max); // `maker` nominates `delegate`

        // A DIFFERENT maker, who nominated nobody. Deliberately unfunded: the
        // signature gate runs before any balance is touched, so funding it would
        // only obscure which check did the rejecting.
        address other = solver;
        Order memory order = _order(other, 0, USDC, WETH, USDC_IN, WETH_OUT, new Item[](0));
        bytes memory sig = _signAs(DELEGATE_PK, order);

        vm.prank(solver);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        settlement.fill(order, sig, USDC_IN);
    }

    function test_unnominatedKey_cannotSign() public {
        _stage();

        Order memory order = _order0();
        bytes memory sig = _signAs(OUTSIDER_PK, order);

        vm.prank(solver);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        settlement.fill(order, sig, USDC_IN);
    }

    /// Nobody can nominate a signer for someone else. The mapping is keyed by
    /// `msg.sender` on write and by `order.maker` on read, so an attacker
    /// nominating a key they DO control writes only to their own row and buys
    /// nothing against a victim's orders.
    function test_nominationIsKeyedByCaller_notByOrderMaker() public {
        _stage();

        vm.prank(solver); // the attacker, nominating a key they hold
        settlement.setOrderSigner(delegate, type(uint256).max);

        assertEq(settlement.orderSignerExpiry(solver, delegate), type(uint256).max, "attacker's own row set");
        assertEq(settlement.orderSignerExpiry(maker, delegate), 0, "victim's row untouched");

        Order memory order = _order0(); // maker = the victim, who nominated nobody
        bytes memory sig = _signAs(DELEGATE_PK, order);

        vm.prank(solver);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        settlement.fill(order, sig, USDC_IN);
    }

    // ──────────────────── Lifecycle ────────────────────

    function test_revocation_bindsOnAnUnfilledOrder() public {
        _stage();
        _nominate(type(uint256).max);

        Order memory order = _order0();
        bytes memory sig = _signAs(DELEGATE_PK, order);

        vm.prank(maker);
        settlement.setOrderSigner(delegate, 0); // revoke

        vm.prank(solver);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        settlement.fill(order, sig, USDC_IN);
    }

    function test_expiry_lapsesOnItsOwn() public {
        _stage();
        uint256 expiry = block.timestamp + 1 hours;
        _nominate(expiry);

        Order memory order = _order0();
        bytes memory sig = _signAs(DELEGATE_PK, order);

        // Exactly at the expiry the delegation is still live (`<=`).
        vm.warp(expiry);
        vm.prank(solver);
        settlement.fill(order, sig, USDC_IN);
        assertEq(IERC20(USDC).balanceOf(solver), USDC_IN, "valid at the boundary");

        // One second later a fresh order no longer authorizes.
        vm.warp(expiry + 1);
        Order memory later = _order(maker, 1, USDC, WETH, USDC_IN, WETH_OUT, new Item[](0));
        bytes memory laterSig = _signAs(DELEGATE_PK, later);
        vm.prank(solver);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        settlement.fill(later, laterSig, USDC_IN);
    }

    /// `ecrecover` returns `address(0)` for any malformed signature, so an
    /// authorized zero address would promote every unrecoverable signature to a
    /// valid delegated one. Rejected at the setter.
    function test_zeroAddressCannotBeNominated() public {
        vm.prank(maker);
        vm.expectRevert(OrderState.InvalidOrderSigner.selector);
        settlement.setOrderSigner(address(0), type(uint256).max);
    }

    function test_setOrderSigner_emitsAndStores() public {
        vm.prank(maker);
        vm.expectEmit(true, true, false, true);
        emit OrderState.OrderSignerSet(maker, delegate, 12345);
        settlement.setOrderSigner(delegate, 12345);

        assertEq(settlement.orderSignerExpiry(maker, delegate), 12345, "stored");
        assertEq(settlement.orderSignerExpiry(maker, outsider), 0, "unrelated key unset");
    }

    // ──────────────────── Preflight agreement ────────────────────

    /// A lens that is stricter than the settler silently drops fillable orders from
    /// an orderbook — the failure mode {OrderGates} exists to prevent.
    function test_lensAgreesWithTheSettlerOnDelegatedOrders() public {
        _stage();
        _nominate(type(uint256).max);

        Order memory order = _order0();
        bytes memory sig = _signAs(DELEGATE_PK, order);

        (,, bool sigValid,) = lens.getOrderRelevantState(order, sig, solver, "");
        assertTrue(sigValid, "lens accepts the delegated signature");

        vm.prank(maker);
        settlement.setOrderSigner(delegate, 0);
        (,, bool afterRevoke,) = lens.getOrderRelevantState(order, sig, solver, "");
        assertFalse(afterRevoke, "lens tracks revocation too");
    }
}
