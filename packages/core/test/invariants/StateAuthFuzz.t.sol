// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MockSettlementBase} from "../shared/MockSettlementBase.t.sol";
import {Order} from "@core/settlement/Settlement.sol";
import {OrderState} from "@core/settlement/OrderState.sol";
import {NonceManager} from "@core/settlement/NonceManager.sol";

/// @title StateAuthFuzz
/// @notice STATELESS property fuzzing over the same four state families
///         {CoreStateInvariants} walks, aimed at the input dimensions a stateful walk
///         cannot cover: the FULL 256-bit nonce space, arbitrary callers, arbitrary
///         expiries, arbitrary hashes.
///
///         The stateful suite asks "over any sequence of actions, did a write ever
///         land where it shouldn't?". This one asks the complementary question — "for
///         any input, does one action do exactly what it claims and nothing more?" —
///         and it is where the bit-arithmetic lives: the bitmap's word/bit split, the
///         rollback floor's ordering, the reserved nonce namespace.
contract StateAuthFuzz is MockSettlementBase {
    uint256 internal constant NS = 1 << 255; // mirrors {NonceManager.SIGNER_NONCE_NS}
    uint256 internal constant CANCELLED = type(uint256).max;

    uint256 constant DELEGATE_PK = 0xD11E6A7E;
    uint256 constant STRANGER_PK = 0x5713A6E4;
    address delegate = vm.addr(DELEGATE_PK);
    address stranger = vm.addr(STRANGER_PK);

    bytes32 constant SIGNER_TH =
        keccak256("OrderSignerPermit(address maker,address signer,uint256 expiry,uint256 nonce,uint256 deadline)");

    function setUp() public override {
        super.setUp();
        _makerApprove(address(settlement), address(tA), type(uint160).max);
        _solverApprove(address(settlement), address(tB), type(uint160).max);
        tA.mint(maker, 1e30);
        tB.mint(solver, 1e30);
    }

    /// @dev A long-dated order so a `vm.warp` in a delegation test can never be
    ///      mistaken for an expiry failure.
    function _liveOrder(uint256 nonce, uint256 amtIn, uint256 amtOut) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), amtIn, amtOut);
        _setExpiry(o, block.timestamp + 3650 days);
    }

    function _signPermit(uint256 pk, address signer_, uint256 expiry, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                settlement.DOMAIN_SEPARATOR(),
                keccak256(abi.encode(SIGNER_TH, maker, signer_, expiry, nonce, deadline))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    // ═══════════════ 1. FILL STATE ═══════════════

    /// @notice A cancelled order is dead for EVERY fill size, including the exact size
    ///         that was outstanding when it died. The sentinel is checked before any
    ///         arithmetic, so no amount can slip past it.
    function testFuzz_cancelledOrderNeverFills(uint256 amtIn, uint256 amtOut, uint256 fillAmt) public {
        amtIn = bound(amtIn, 2, 1e24);
        amtOut = bound(amtOut, 1, 1e24);
        fillAmt = bound(fillAmt, 1, amtIn);

        Order memory o = _liveOrder(1, amtIn, amtOut);
        bytes memory sig = _sign(o);
        vm.prank(maker);
        settlement.cancelOrder(o);

        vm.prank(solver);
        vm.expectRevert(OrderState.OrderCancelled.selector);
        settlement.fill(o, sig, fillAmt);
        assertEq(settlement.filled(_hashOrder(o)), CANCELLED, "the sentinel moved");
    }

    /// @notice Cancellation is terminal even MID-ORDER: a part-filled order stops at
    ///         the progress it had, and the remaining size becomes unreachable.
    function testFuzz_cancelBindsOnAPartiallyFilledOrder(uint256 amtIn, uint256 first) public {
        amtIn = bound(amtIn, 2, 1e24);
        first = bound(first, 1, amtIn - 1);

        Order memory o = _liveOrder(1, amtIn, amtIn);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        settlement.fill(o, sig, first);
        assertEq(settlement.filled(_hashOrder(o)), first, "partial fill did not record");

        vm.prank(maker);
        settlement.cancelOrder(o);
        vm.prank(solver);
        vm.expectRevert(OrderState.OrderCancelled.selector);
        settlement.fill(o, sig, amtIn - first);
    }

    /// @notice Only the order's own maker can park the sentinel — for ANY other caller
    ///         `cancelOrder` reverts and the counter is untouched. `maker` is a signed
    ///         field of the hash, so this bound is hash-wide, not caller-wide.
    function testFuzz_cancelOrder_onlyMaker(address who, uint256 nonce) public {
        vm.assume(who != maker);
        Order memory o = _liveOrder(nonce, 1e18, 1e18);

        vm.prank(who);
        vm.expectRevert(OrderState.NotOrderMaker.selector);
        settlement.cancelOrder(o);
        assertEq(settlement.filled(_hashOrder(o)), 0, "a stranger moved the counter");
    }

    // ═══════════════ 2. CANCELLATION STATE ═══════════════

    /// @notice The bitmap's word/bit split is exact over the WHOLE 256-bit space:
    ///         cancelling `n` marks `n` and leaves every other coordinate — including
    ///         its neighbours in the same word and the same bit in the next word —
    ///         alone, and it is scoped to the caller.
    function testFuzz_nonceCancellationIsExactAndSelfScoped(uint256 n, uint256 other, address who) public {
        vm.assume(other != n);
        vm.assume(who != maker);

        uint256[] memory one = new uint256[](1);
        one[0] = n;
        vm.prank(maker);
        settlement.cancelOrders(one);

        assertTrue(settlement.isNonceCancelled(maker, n), "the target nonce is not cancelled");
        // `minValidNonce` is still 0, so `other` can only read cancelled if the bit
        // arithmetic bled into a neighbouring coordinate.
        assertFalse(settlement.isNonceCancelled(maker, other), "cancellation bled into another nonce");
        assertFalse(settlement.isNonceCancelled(who, n), "cancellation crossed into another maker");
    }

    /// @notice Cancelling the same nonce twice is a no-op — no counter to corrupt, no
    ///         way for a relayer to grief by re-submitting.
    function testFuzz_nonceCancellationIsIdempotent(uint256 n) public {
        uint256[] memory one = new uint256[](1);
        one[0] = n;
        vm.startPrank(maker);
        settlement.cancelOrders(one);
        uint256 word = settlement.nonceBitmap(maker, n >> 8);
        settlement.cancelOrders(one);
        vm.stopPrank();
        assertEq(settlement.nonceBitmap(maker, n >> 8), word, "a second cancel changed the word");
    }

    /// @notice The rollback floor means EXACTLY "everything below me is cancelled" —
    ///         no off-by-one at the boundary, for any floor and any probe.
    function testFuzz_rollbackCancelsExactlyBelowTheFloor(uint256 floor_, uint256 probe) public {
        vm.prank(maker);
        settlement.rollbackNonces(floor_);
        assertEq(settlement.minValidNonce(maker), floor_, "the floor did not take");
        assertEq(settlement.isNonceCancelled(maker, probe), probe < floor_, "floor boundary is wrong");
    }

    /// @notice The floor is monotonic. A maker can never un-cancel a retired ladder by
    ///         rolling back down, so an orderbook can treat the floor as final.
    function testFuzz_rollbackNeverRetreats(uint256 high, uint256 low) public {
        high = bound(high, 1, type(uint256).max);
        low = bound(low, 0, high - 1);

        vm.startPrank(maker);
        settlement.rollbackNonces(high);
        vm.expectRevert(NonceManager.RollbackTooLow.selector);
        settlement.rollbackNonces(low);
        vm.stopPrank();
        assertEq(settlement.minValidNonce(maker), high, "the floor retreated");
    }

    /// @notice Word invalidation cancels exactly its own 256 coordinates. A probe in
    ///         any other word must stay live — the mass kill switch must not be able
    ///         to reach past the word the maker named.
    function testFuzz_invalidateWordHitsOnlyThatWord(uint256 word, uint256 probe) public {
        // A word index above `2^248-1` addresses no reachable nonce (`word << 8` would
        // overflow the coordinate space), so bound it to the range a maker can name.
        word = bound(word, 0, type(uint256).max >> 8);
        vm.assume(probe >> 8 != word);

        vm.prank(maker);
        settlement.invalidateNonceWord(word);

        assertTrue(settlement.isNonceCancelled(maker, (word << 8) | 0xff), "the word was not invalidated");
        assertFalse(settlement.isNonceCancelled(maker, probe), "invalidation reached another word");
    }

    // ═══════════════ 3. APPROVAL STATE ═══════════════

    /// @notice `approveOrder` is self-keyed: a caller can only ever authorize an order
    ///         that names itself as maker, so no record can be planted on a maker's row
    ///         by anyone else.
    function testFuzz_approveOrder_onlySelfKeyed(address who, uint256 nonce) public {
        vm.assume(who != maker);
        Order memory o = _liveOrder(nonce, 1e18, 1e18);

        vm.prank(who);
        vm.expectRevert(OrderState.NotOrderMaker.selector);
        settlement.approveOrder(o);
        assertFalse(settlement.orderApproved(maker, _hashOrder(o)), "a stranger approved for the maker");
    }

    /// @notice `revokeOrderApproval` takes a BARE HASH, and on a touched order it parks
    ///         the cancellation sentinel — so if the `wasApproved` guard were ever
    ///         dropped, any caller could cancel any part-filled order in the book. This
    ///         is that exact attack, fuzzed over the fill size: a stranger's revoke must
    ///         change nothing, and the order must still fill afterwards.
    function testFuzz_strangerRevokeCannotCancelAnyOrder(uint256 amtIn, uint256 first, address who) public {
        vm.assume(who != maker);
        amtIn = bound(amtIn, 2, 1e24);
        first = bound(first, 1, amtIn - 1);

        Order memory o = _liveOrder(3, amtIn, amtIn);
        bytes32 h = _hashOrder(o);
        vm.prank(maker);
        settlement.approveOrder(o);

        vm.prank(solver);
        settlement.fill(o, "", first); // sigless, authorized by the on-chain record

        vm.prank(who);
        settlement.revokeOrderApproval(h); // no revert — it is a no-op for a stranger

        assertEq(settlement.filled(h), first, "a stranger parked the cancellation sentinel");
        assertTrue(settlement.orderApproved(maker, h), "a stranger cleared the maker's record");
        vm.prank(solver);
        settlement.fill(o, "", amtIn - first); // still fillable — the order survived
        assertEq(settlement.filled(h), amtIn, "the remainder did not settle");
    }

    /// @notice The maker's OWN revoke on a touched order escalates to a full cancel,
    ///         for any fill size. It has to: {Signatures._verifySignature} skips
    ///         re-verification once `filled != 0` and that skip is reached by ANY
    ///         non-empty `sig`, so clearing the flag alone would leave the remainder
    ///         of a withdrawn order settleable with 65 arbitrary bytes.
    function testFuzz_makerRevokeOnATouchedOrderIsAFullCancel(uint256 amtIn, uint256 first) public {
        amtIn = bound(amtIn, 2, 1e24);
        first = bound(first, 1, amtIn - 1);

        Order memory o = _liveOrder(4, amtIn, amtIn);
        bytes32 h = _hashOrder(o);
        vm.prank(maker);
        settlement.approveOrder(o);
        vm.prank(solver);
        settlement.fill(o, "", first);

        vm.prank(maker);
        settlement.revokeOrderApproval(h);

        assertEq(settlement.filled(h), CANCELLED, "revocation did not escalate to a cancel");
        // And the hole it closes: a garbage 65-byte signature must not settle the rest.
        bytes memory junk = _signWith(o, STRANGER_PK);
        vm.prank(solver);
        vm.expectRevert(OrderState.OrderCancelled.selector);
        settlement.fill(o, junk, amtIn - first);
    }

    // ═══════════════ 4. DELEGATION STATE ═══════════════

    /// @notice The registry is keyed by `msg.sender` on write. Whatever any caller
    ///         writes, it lands on that caller's own row and never on the maker's —
    ///         which is the entire difference between this and a protocol operator.
    function testFuzz_setOrderSigner_writesOnlyTheCallersRow(address who, address signer_, uint256 expiry) public {
        vm.assume(who != maker && signer_ != address(0));

        vm.prank(who);
        settlement.setOrderSigner(signer_, expiry);

        assertEq(settlement.orderSignerExpiry(who, signer_), expiry, "the caller's own row did not take");
        assertEq(settlement.orderSignerExpiry(maker, signer_), 0, "a stranger wrote the maker's row");
    }

    /// @notice `address(0)` is rejected for every expiry. `ecrecover` yields it for any
    ///         malformed signature, so one authorized zero entry would promote every
    ///         unrecoverable signature in the system to a valid delegated one.
    function testFuzz_zeroAddressIsNeverASigner(uint256 expiry, address who) public {
        vm.prank(who);
        vm.expectRevert(OrderState.InvalidOrderSigner.selector);
        settlement.setOrderSigner(address(0), expiry);
        assertEq(settlement.orderSignerExpiry(who, address(0)), 0, "address(0) became a signer");
    }

    /// @notice A relayed nomination consumes `nonce | SIGNER_NONCE_NS` and NEVER the
    ///         bare coordinate — for every nonce a builder could pick. Sharing the
    ///         coordinate made an unrelayed permit a latent, third-party-triggerable
    ///         cancel on every order the maker later signed with the same nonce; this
    ///         is the property that closed it.
    function testFuzz_relayedNominationNeverBurnsAnOrderNonce(uint256 nonce, uint256 expiry) public {
        nonce = bound(nonce, 0, type(uint256).max >> 1); // an ORDER-space coordinate
        expiry = bound(expiry, 1, type(uint256).max);

        bytes memory sig = _signPermit(makerPk, delegate, expiry, nonce, block.timestamp + 1 days);
        vm.prank(stranger); // anyone may relay; the permit carries its own authority
        settlement.setOrderSignerWithSig(maker, delegate, expiry, nonce, block.timestamp + 1 days, sig);

        assertEq(settlement.orderSignerExpiry(maker, delegate), expiry, "the nomination did not take");
        assertTrue(settlement.isNonceCancelled(maker, nonce | NS), "the reserved coordinate was not consumed");
        assertFalse(settlement.isNonceCancelled(maker, nonce), "a relayed permit burned an ORDER nonce");
    }

    /// @notice The nomination graph is exactly one level deep. A live delegate signing
    ///         an `OrderSignerPermit` for its own maker is rejected — the permit is
    ///         verified against the maker through the shared verifier, never through
    ///         the delegated branch — so a session key can never mint further session
    ///         keys for the desk that issued it.
    function testFuzz_delegateCannotRedelegate(address target, uint256 expiry, uint256 nonce) public {
        vm.assume(target != address(0));
        nonce = bound(nonce, 0, type(uint256).max >> 1);

        vm.prank(maker);
        settlement.setOrderSigner(delegate, block.timestamp + 30 days);

        // Signed by the DELEGATE, naming the maker as delegator.
        bytes memory sig = _signPermit(DELEGATE_PK, target, expiry, nonce, block.timestamp + 1 days);
        vm.prank(stranger);
        vm.expectRevert();
        settlement.setOrderSignerWithSig(maker, target, expiry, nonce, block.timestamp + 1 days, sig);
        assertEq(settlement.orderSignerExpiry(maker, target), 0, "a delegate re-delegated");
    }

    /// @notice A delegation lapses on its own clock, at the second it names, and a
    ///         lapsed delegate cannot OPEN an order. (It is the remainder of an order
    ///         it already part-filled that the first-fill skip leaves reachable — a
    ///         different, documented caveat; opening a fresh one is what must fail.)
    function testFuzz_expiredDelegateCannotOpenAnOrder(uint256 window, uint256 overshoot) public {
        window = bound(window, 1, 3000 days);
        overshoot = bound(overshoot, 1, 3000 days);
        uint256 expiry = block.timestamp + window;

        vm.prank(maker);
        settlement.setOrderSigner(delegate, expiry);

        Order memory o = _liveOrder(9, 1e18, 1e18);
        bytes memory sig = _signWith(o, DELEGATE_PK);

        // At the boundary second the delegation is still live (`<=` expiry).
        vm.warp(expiry);
        vm.prank(solver);
        settlement.fill(o, sig, 1e17);

        // One second past it, a FRESH order from the same delegate is refused.
        vm.warp(expiry + overshoot);
        Order memory fresh = _liveOrder(10, 1e18, 1e18);
        bytes memory freshSig = _signWith(fresh, DELEGATE_PK);
        vm.prank(solver);
        vm.expectRevert();
        settlement.fill(fresh, freshSig, 1e17);
        assertEq(settlement.filled(_hashOrder(fresh)), 0, "a lapsed delegate opened an order");
    }
}
