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
    /// @dev Mirrors {NonceManager.SIGNER_NONCE_NS} — the reserved half of the nonce
    ///      bitmap that relayed nominations consume. Spelled out rather than
    ///      imported so the test pins the CONSTANT, not the contract's opinion of it.
    uint256 constant SIGNER_NS = 1 << 255;

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

    /// The permit rides a RESERVED HALF of the maker's order-nonce space, so the
    /// cancellation primitives they already have still kill an outstanding
    /// nomination they never wanted relayed — but they must name the NAMESPACED
    /// coordinate, `nonce | SIGNER_NONCE_NS`. See {NonceManager.SIGNER_NONCE_NS}.
    function test_permit_preCancelledNonceRejected() public {
        _stage();
        uint256 dl = block.timestamp + 1 hours;
        bytes memory permit = _signPermit(makerPk, maker, delegate, type(uint256).max, 7, dl);

        uint256[] memory kill = new uint256[](1);
        kill[0] = 7 | SIGNER_NS;
        vm.prank(maker);
        settlement.cancelOrders(kill);

        vm.prank(solver);
        vm.expectRevert(OrderState.NonceCancelled.selector);
        settlement.setOrderSignerWithSig(maker, delegate, type(uint256).max, 7, dl, permit);
    }

    /// Cancelling the BARE nonce does NOT reach the permit — the two live in
    /// disjoint halves of the bitmap, which is the whole point of the namespace.
    /// The counterpart of `test_signerPermit_cannotCancelALiveOrder` below.
    function test_permit_bareNonceCancellationDoesNotReachIt() public {
        _stage();
        uint256 dl = block.timestamp + 1 hours;
        bytes memory permit = _signPermit(makerPk, maker, delegate, type(uint256).max, 7, dl);

        uint256[] memory kill = new uint256[](1);
        kill[0] = 7; // the ORDER coordinate, not the permit's
        vm.prank(maker);
        settlement.cancelOrders(kill);

        vm.prank(solver);
        settlement.setOrderSignerWithSig(maker, delegate, type(uint256).max, 7, dl, permit);
        assertEq(settlement.orderSignerExpiry(maker, delegate), type(uint256).max, "namespaces are disjoint");
    }

    // ──────────────────── The namespace, from the order side ────────────────────

    /// ⚠ THE REGRESSION THIS NAMESPACE EXISTS FOR.
    ///
    /// Before the reservation, an UNRELAYED nomination permit was a latent,
    /// third-party-triggerable cancel on every order the maker later signed with the
    /// same nonce. The sequence needs no privilege and no maker mistake beyond nonce
    /// reuse — which is not exotic, since a shared nonce is exactly how an OCO
    /// bracket is built:
    ///
    ///   T0  maker signs a nomination permit on nonce N; nobody relays it
    ///   T1  `isNonceCancelled(maker, N)` reads FALSE — an allocator sees N as free
    ///   T2  maker signs and publishes an ordinary order on nonce N
    ///   T3  ANYONE relays the stale permit, at any time before its deadline
    ///   T4  the order is dead, with no action by the maker
    ///
    /// The permit now consumes `N | SIGNER_NONCE_NS`, so T3 cannot reach T2's order.
    function test_signerPermit_cannotCancelALiveOrder() public {
        _stage();
        uint256 N = 42;
        uint256 dl = block.timestamp + 365 days;

        // T0 — signed, never relayed.
        bytes memory permit = _signPermit(makerPk, maker, delegate, type(uint256).max, N, dl);
        // T1 — the allocator's view: free.
        assertFalse(settlement.isNonceCancelled(maker, N), "order nonce reads free");

        // T2 — a live order on the same nonce.
        Order memory order = _order(maker, N, USDC, WETH, USDC_IN, WETH_OUT, new Item[](0));
        bytes memory sig = _sign(order);

        // T3 — anyone relays the stale permit.
        vm.prank(address(0xDEAD));
        settlement.setOrderSignerWithSig(maker, delegate, type(uint256).max, N, dl, permit);

        // T4 — the order is UNTOUCHED, and the permit landed in its own half.
        assertFalse(settlement.isNonceCancelled(maker, N), "order nonce survives");
        assertTrue(settlement.isNonceCancelled(maker, N | SIGNER_NS), "permit burned its own coordinate");

        vm.prank(solver);
        settlement.fill(order, sig, USDC_IN);
        assertEq(IERC20(USDC).balanceOf(solver), USDC_IN, "order still fills");
    }

    /// And the converse: filling the order does not consume the nomination permit.
    /// Only relevant for a fill-once order, which is the shape that writes the
    /// bitmap rather than the per-hash counter.
    function test_orderNonceCancellation_doesNotConsumeTheSignerPermit() public {
        _stage();
        uint256 N = 42;
        uint256 dl = block.timestamp + 365 days;
        bytes memory permit = _signPermit(makerPk, maker, delegate, type(uint256).max, N, dl);

        uint256[] memory kill = new uint256[](1);
        kill[0] = N;
        vm.prank(maker);
        settlement.cancelOrders(kill); // retire the ORDER ladder

        vm.prank(solver);
        settlement.setOrderSignerWithSig(maker, delegate, type(uint256).max, N, dl, permit);
        assertEq(settlement.orderSignerExpiry(maker, delegate), type(uint256).max, "nomination unaffected");
    }

    /// `rollbackNonces` deliberately does NOT reach nominations: a floor would have
    /// to exceed 2^255. Retiring a ladder of orders must not revoke a desk's signing
    /// key as a side effect.
    function test_rollbackNonces_doesNotRevokeANomination() public {
        _stage();
        uint256 dl = block.timestamp + 1 hours;
        bytes memory permit = _signPermit(makerPk, maker, delegate, type(uint256).max, 7, dl);

        vm.prank(maker);
        settlement.rollbackNonces(1_000_000); // far above any order nonce in use

        vm.prank(solver);
        settlement.setOrderSignerWithSig(maker, delegate, type(uint256).max, 7, dl, permit);
        assertEq(settlement.orderSignerExpiry(maker, delegate), type(uint256).max, "rollback does not reach it");
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

    // ──────────────────── Contract delegates (Safe / passkey wallets) ────────────────────

    /// A CONTRACT delegate cannot be reached by the registry probe — that keys on
    /// the address `ecrecover` produced, and a contract signature has none. The
    /// filler names it instead, in an envelope: `delegate ‖ innerSig`.
    function _envelope(address d, bytes memory inner) internal pure returns (bytes memory) {
        return abi.encodePacked(d, inner);
    }

    function test_contractDelegate_signsViaEnvelope() public {
        _stage();
        MockMakerWallet wallet = new MockMakerWallet(delegate); // a smart account the delegate key controls
        vm.prank(maker);
        settlement.setOrderSigner(address(wallet), type(uint256).max);

        Order memory order = _order0();
        bytes memory sig = _envelope(address(wallet), _signAs(DELEGATE_PK, order));
        assertTrue(sig.length != 64 && sig.length != 65, "envelope must not look like plain ECDSA");

        vm.prank(solver);
        settlement.fill(order, sig, USDC_IN);
        assertEq(IERC20(USDC).balanceOf(solver), USDC_IN, "contract delegate authorized the order");
    }

    /// The filler picks the address in the envelope, so the registry lookup is the
    /// only thing standing between it and a forged authorization. It is keyed by
    /// the ORDER'S maker, so naming an un-nominated contract is just a failed
    /// lookup — it falls through and dies on the maker's own (absent) 1271.
    function test_contractDelegate_unnominatedRejected() public {
        _stage();
        MockMakerWallet wallet = new MockMakerWallet(delegate); // nominated by NOBODY

        Order memory order = _order0();
        bytes memory sig = _envelope(address(wallet), _signAs(DELEGATE_PK, order));

        vm.prank(solver);
        vm.expectRevert(SignatureVerification.InvalidSignatureLength.selector);
        settlement.fill(order, sig, USDC_IN);
    }

    function test_contractDelegate_revoked() public {
        _stage();
        MockMakerWallet wallet = new MockMakerWallet(delegate);
        vm.prank(maker);
        settlement.setOrderSigner(address(wallet), type(uint256).max);
        vm.prank(maker);
        settlement.setOrderSigner(address(wallet), 0);

        Order memory order = _order0();
        bytes memory sig = _envelope(address(wallet), _signAs(DELEGATE_PK, order));

        vm.prank(solver);
        vm.expectRevert(SignatureVerification.InvalidSignatureLength.selector);
        settlement.fill(order, sig, USDC_IN);
    }

    /// THE collision test. A CONTRACT maker with a long (non-ECDSA) signature is
    /// the one payload shape that could in principle be mistaken for an envelope.
    /// It must not be: the branch additionally requires the maker to have NO code,
    /// so a contract maker falls straight through to its own `isValidSignature`.
    function test_contractMakerWithLongSig_notReadAsAnEnvelope() public {
        MockMakerWallet makerWallet = new MockMakerWallet(maker);
        Order memory order = _order(address(makerWallet), 0, USDC, WETH, USDC_IN, WETH_OUT, new Item[](0));
        bytes32 h = _hashOrder(order);

        // 65-byte 1271 payload the wallet accepts. Verified through the LENS so the
        // assertion is about the signature gate alone, with no funding in the way.
        bytes memory sig = _sign(order);
        lens.checkSignature(h, sig, address(makerWallet)); // must not revert

        // And an 85-byte payload — exactly an envelope's shape — must still be
        // handed to the MAKER'S `isValidSignature`, never re-read as
        // `delegate ‖ inner`. The proof is the revert: it is the wallet's OWN
        // length check ("len"), i.e. the payload reached the 1271 branch.
        bytes memory envelopeShaped = abi.encodePacked(address(makerWallet), _signAs(OUTSIDER_PK, order));
        assertEq(envelopeShaped.length, 85, "same shape an envelope would have");
        vm.expectRevert(bytes("len"));
        lens.checkSignature(h, envelopeShaped, address(makerWallet));
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

    // ════════ Revocation vs. the first-fill skip — the M2/E6 row ════════
    //
    //  THE PROPERTY, stated plainly because it is a promise the protocol does NOT
    //  make: revoking a delegate does not stop the REMAINDER of an order that
    //  delegate has already part-filled. {Signatures._verifySignature} skips
    //  re-verification once `filled[orderHash] != 0`, and a delegation is checked on
    //  the signature path, so once the counter is non-zero the registry is never read
    //  again for that hash.
    //
    //  That is deliberate. Reading `orderSignerExpiry` on every fill would put a cold
    //  SLOAD on every fill of EVERY order — including the overwhelming majority that
    //  never delegate anything — to protect the rare touched-and-then-revoked one.
    //  The trade is the same one EIP-1271 makers live with, and it is documented in
    //  {OrderState.orderSignerExpiry} and in `docs/delegated-signers.md`.
    //
    //  Until now it was documented and nothing more. `test_revocation_bindsOnAnUnfilledOrder`
    //  covers only the half that DOES bind, so a change that silently made revocation
    //  bind mid-order — or, far worse, one that made an UNTOUCHED order stop binding —
    //  would have broken no test. These are the negative twins.
    //
    //  Each one ends by asserting the kill switch that DOES bind, because the
    //  documented advice ("use {cancelOrder}") is only worth writing down if it is
    //  true, and a maker reading it is entitled to a test.

    /// @dev EOA delegate. Nominate → partial fill → revoke → the remainder still
    ///      settles on the delegate's original signature. Then {cancelOrder} stops it.
    function test_revocation_doesNotBindAfterAPartialFill() public {
        _stage();
        _nominate(type(uint256).max);

        Order memory order = _order0();
        bytes memory sig = _signAs(DELEGATE_PK, order);

        vm.prank(solver);
        settlement.fill(order, sig, USDC_IN / 2);
        assertEq(IERC20(USDC).balanceOf(solver), USDC_IN / 2, "delegate opened the order");

        vm.prank(maker);
        settlement.setOrderSigner(delegate, 0); // revoke
        assertEq(settlement.orderSignerExpiry(maker, delegate), 0, "the registry entry is gone");

        // ...and the remainder settles anyway. The counter is the authorisation.
        vm.prank(solver);
        settlement.fill(order, sig, USDC_IN / 2);
        assertEq(IERC20(USDC).balanceOf(solver), USDC_IN, "revocation did not bind mid-order");
    }

    /// @dev The kill switch that DOES bind on a touched order, asserted on the same
    ///      shape so the pair reads as one statement: revocation is not the tool,
    ///      {OrderState.cancelOrder} is.
    function test_revocation_cancelOrderBindsWhereRevocationDoesNot() public {
        _stage();
        _nominate(type(uint256).max);

        Order memory order = _order0();
        bytes memory sig = _signAs(DELEGATE_PK, order);

        vm.prank(solver);
        settlement.fill(order, sig, USDC_IN / 2);

        vm.startPrank(maker);
        settlement.setOrderSigner(delegate, 0); // does nothing to this order
        settlement.cancelOrder(order); //          this is the one that binds
        vm.stopPrank();

        vm.prank(solver);
        vm.expectRevert(OrderState.OrderCancelled.selector);
        settlement.fill(order, sig, USDC_IN / 2);
        assertEq(IERC20(USDC).balanceOf(solver), USDC_IN / 2, "the remainder never moved");
    }

    /// @dev A lapsing nomination is a withdrawable credential too, and lapses the
    ///      same way: the expiry is compared against `block.timestamp` on the
    ///      signature path, which a touched order no longer reaches. Warping a year
    ///      past a finite expiry changes nothing about the remainder.
    function test_expiry_doesNotLapseMidOrderOnceTouched() public {
        _stage();
        _nominate(block.timestamp + 1 days);

        Order memory order = _order0();
        _setExpiry(order, block.timestamp + 400 days); // outlive the warp below
        bytes memory sig = _signAs(DELEGATE_PK, order);

        vm.prank(solver);
        settlement.fill(order, sig, USDC_IN / 2);

        vm.warp(block.timestamp + 365 days); // the delegation is long gone
        assertLt(settlement.orderSignerExpiry(maker, delegate), block.timestamp, "nomination has lapsed");

        vm.prank(solver);
        settlement.fill(order, sig, USDC_IN / 2);
        assertEq(IERC20(USDC).balanceOf(solver), USDC_IN, "a lapsed delegation did not bind mid-order either");
    }

    /// @dev The CONTRACT-delegate envelope carries its own registry lookup on its own
    ///      branch, so it needs its own case — the two branches could drift.
    function test_contractDelegate_revocationDoesNotBindAfterAPartialFill() public {
        _stage();
        MockMakerWallet wallet = new MockMakerWallet(delegate);
        vm.prank(maker);
        settlement.setOrderSigner(address(wallet), type(uint256).max);

        Order memory order = _order0();
        bytes memory sig = _envelope(address(wallet), _signAs(DELEGATE_PK, order));

        vm.prank(solver);
        settlement.fill(order, sig, USDC_IN / 2);

        vm.prank(maker);
        settlement.setOrderSigner(address(wallet), 0);

        vm.prank(solver);
        settlement.fill(order, sig, USDC_IN / 2);
        assertEq(IERC20(USDC).balanceOf(solver), USDC_IN, "the contract-delegate branch behaves identically");
    }

    // ════════════════ 2026-08-31 audit regressions ════════════════

    /// @dev AUDIT M-1. A permit consumes its bitmap coordinate only WHEN RELAYED.
    ///      So a maker who signs a gasless nomination, never has it relayed, and
    ///      then revokes with {OrderState.setOrderSigner} is NOT safe: whoever holds
    ///      the message can relay it later and the delegate is live again, up to the
    ///      permit's `deadline` — which nothing caps.
    ///
    ///      `test_permit_replayRejected` covers the RELAY-then-revoke-then-replay
    ///      ordering, where the nonce is already burned. This is the other ordering,
    ///      and it is the realistic one: a relayer goes offline, the maker revokes,
    ///      and considers the matter closed.
    ///
    ///      Pinned as CURRENT BEHAVIOUR, not as desired behaviour. The fix is
    ///      procedural and lives in the SDK (`encodeRevokeOrderSigner` emits the
    ///      burn alongside the clear); the counterpart test below is the correct
    ///      sequence.
    function test_permit_staleUnrelayedPermitResurrectsARevokedDelegate() public {
        _stage();
        uint256 N = 7;
        uint256 dl = block.timestamp + 365 days;

        // Signed once, handed to a relayer, never landed.
        bytes memory permit = _signPermit(makerPk, maker, delegate, type(uint256).max, N, dl);

        // The maker nominates directly, then revokes directly. From their side the
        // delegate is gone: the registry says so and an order signed now would fail.
        _nominate(type(uint256).max);
        vm.prank(maker);
        settlement.setOrderSigner(delegate, 0);
        assertEq(settlement.orderSignerExpiry(maker, delegate), 0, "registry cleared");

        // The permit's coordinate was never burned, so anyone may still relay it.
        vm.prank(outsider);
        settlement.setOrderSignerWithSig(maker, delegate, type(uint256).max, N, dl, permit);
        assertEq(settlement.orderSignerExpiry(maker, delegate), type(uint256).max, "delegate resurrected");

        // And it is a real resurrection, not just a storage write: the delegate's
        // signature settles an order the maker never signed.
        Order memory order = _order0();
        // Signed on its own line: `vm.sign` inside a call argument consumes the
        // pending `vm.prank`, so the fill would run as the test contract.
        bytes memory delegateSig = _signAs(DELEGATE_PK, order);
        vm.prank(solver);
        settlement.fill(order, delegateSig, USDC_IN);
        assertEq(IERC20(USDC).balanceOf(solver), USDC_IN, "a revoked delegate authorized a fill");
    }

    /// @dev AUDIT M-1, the correct sequence — exactly what the SDK's
    ///      `encodeRevokeOrderSigner` emits: clear the registry AND burn the permit
    ///      coordinate. The coordinate is recomputable from the delegate address
    ///      alone (`signerPermitNonce`), which is what makes this possible with no
    ///      bookkeeping on the maker's side.
    function test_permit_burningTheCoordinateMakesRevocationFinal() public {
        _stage();
        uint256 N = 7;
        uint256 dl = block.timestamp + 365 days;
        bytes memory permit = _signPermit(makerPk, maker, delegate, type(uint256).max, N, dl);

        _nominate(type(uint256).max);
        vm.startPrank(maker);
        settlement.setOrderSigner(delegate, 0); // call 1 — clear
        uint256[] memory kill = new uint256[](1);
        kill[0] = N | SIGNER_NS; // ⚠ the NAMESPACED coordinate, not the bare nonce
        settlement.cancelOrders(kill); // call 2 — burn
        vm.stopPrank();

        vm.prank(outsider);
        vm.expectRevert(OrderState.NonceCancelled.selector);
        settlement.setOrderSignerWithSig(maker, delegate, type(uint256).max, N, dl, permit);
        assertEq(settlement.orderSignerExpiry(maker, delegate), 0, "revocation is final");

        Order memory order = _order0();
        bytes memory delegateSig = _signAs(DELEGATE_PK, order);
        vm.prank(solver);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        settlement.fill(order, delegateSig, USDC_IN);
    }

    /// @dev AUDIT M-3. `rollbackNonces` is documented as a kill switch, and for a
    ///      LADDER it is one — but it is not containment for a compromised delegate.
    ///      It sets a FLOOR, and a delegate simply signs above it. Worth pinning
    ///      because "roll the nonces forward" is the instinctive panic response, and
    ///      it does not work here.
    ///
    ///      The only containment is per-address revocation (there is no on-chain
    ///      bulk revoke — see `liveDelegates` in the SDK for rebuilding the list) or
    ///      revoking the Permit3 allowances that fund the fills, which also stops the
    ///      maker trading.
    function test_rollbackNonces_doesNotContainACompromisedDelegate() public {
        _stage();
        _nominate(type(uint256).max);

        vm.prank(maker);
        settlement.rollbackNonces(1_000_000); // "retire everything outstanding"

        // The delegate mints a fresh order ABOVE the floor and it settles.
        Order memory order = _order(maker, 1_000_001, USDC, WETH, USDC_IN, WETH_OUT, new Item[](0));
        bytes memory delegateSig = _signAs(DELEGATE_PK, order);
        vm.prank(solver);
        settlement.fill(order, delegateSig, USDC_IN);
        assertEq(IERC20(USDC).balanceOf(solver), USDC_IN, "a nonce floor is not containment");
    }

    /// @dev AUDIT M-3, the counterpart: naming the delegate DOES contain it, on any
    ///      nonce. This is the pair that shows the difference is the axis, not the
    ///      magnitude.
    function test_perAddressRevocation_isTheOnlyContainment() public {
        _stage();
        _nominate(type(uint256).max);
        vm.prank(maker);
        settlement.setOrderSigner(delegate, 0);

        Order memory order = _order(maker, 1_000_001, USDC, WETH, USDC_IN, WETH_OUT, new Item[](0));
        bytes memory delegateSig = _signAs(DELEGATE_PK, order);
        vm.prank(solver);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        settlement.fill(order, delegateSig, USDC_IN);
    }

    /// @dev AUDIT M-4. The contract-delegate envelope is reachable only when the
    ///      maker has NO CODE — that condition is what keeps the branch from
    ///      shadowing a 1271 payload meant for a contract maker. The consequence is
    ///      unobvious and unstated anywhere: an EOA maker who later adopts EIP-7702
    ///      SILENTLY loses the envelope path, and every unfilled order its contract
    ///      delegate signed becomes unauthorized.
    ///
    ///      Liveness only — no order is stuck (the maker can `cancelOrder` or
    ///      re-sign) and nothing becomes authorizable that was not before. But a desk
    ///      whose Safe-based signer stops working the day the principal upgrades
    ///      their wallet deserves to find this in a test rather than in production.
    ///
    ///      `vm.etch` stands in for the delegation: the branch keys on
    ///      `expected.code.length`, and a 7702 designator is code like any other.
    function test_makerAdopting7702_disablesTheContractDelegateEnvelope() public {
        _stage();
        MockMakerWallet wallet = new MockMakerWallet(delegate);
        vm.prank(maker);
        settlement.setOrderSigner(address(wallet), type(uint256).max);

        Order memory order = _order0();
        bytes memory sig = _envelope(address(wallet), _signAs(DELEGATE_PK, order));

        // Before: the envelope authorizes.
        uint256 snap = vm.snapshotState();
        vm.prank(solver);
        settlement.fill(order, sig, USDC_IN);
        assertEq(IERC20(USDC).balanceOf(solver), USDC_IN, "envelope works while the maker is codeless");
        vm.revertToState(snap);

        // After: the maker has code, so `!standardLength && expected.code.length == 0`
        // fails and the SAME signature falls through to the maker's own 1271.
        MockMakerWallet impl = new MockMakerWallet(maker);
        vm.etch(maker, address(impl).code);
        assertGt(maker.code.length, 0, "maker now carries code");

        vm.prank(solver);
        vm.expectRevert(); // the envelope is now read as a 1271 payload for the maker
        settlement.fill(order, sig, USDC_IN);
    }

    /// @dev AUDIT L-5. Every authoritative cancel is keyed by `msg.sender`, so a
    ///      delegate cannot hard-cancel its nominator's orders. `cancelOrder` says so
    ///      loudly ({NotOrderMaker}); the NONCE cancels do not — they succeed, write
    ///      the DELEGATE's own bitmap row, and emit `OrdersCancelled(delegate, …)`.
    ///
    ///      To an operator or a bot watching events that is indistinguishable from a
    ///      cancel that worked, while the maker's order stays fillable. The SDK's
    ///      `assertCanCancelOnChain` is the guard; this pins the on-chain behaviour
    ///      the guard exists for.
    function test_delegateCannotCancelForItsMaker() public {
        _stage();
        _nominate(type(uint256).max);
        Order memory order = _order0(); // nonce 0

        // The loud half.
        vm.prank(delegate);
        vm.expectRevert(OrderState.NotOrderMaker.selector);
        settlement.cancelOrder(order);

        // The silent half — no revert.
        uint256[] memory kill = new uint256[](1);
        kill[0] = 0;
        vm.prank(delegate);
        settlement.cancelOrders(kill);

        assertFalse(settlement.isNonceCancelled(maker, 0), "the maker's nonce is untouched");
        assertTrue(settlement.isNonceCancelled(delegate, 0), "the delegate cancelled its OWN nonce");

        // Proof it was a no-op where it mattered: the order the delegate "cancelled"
        // still settles, on the delegate's own signature.
        bytes memory delegateSig = _signAs(DELEGATE_PK, order);
        vm.prank(solver);
        settlement.fill(order, delegateSig, USDC_IN);
        assertEq(IERC20(USDC).balanceOf(solver), USDC_IN, "order the delegate tried to cancel still filled");
    }
}
