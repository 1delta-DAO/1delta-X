// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Order, LegOut} from "@core/settlement/Settlement.sol";
import {ItemPolicy} from "@core/settlement/Structs.sol";
import {AggregatorFillSolver, RoutePlan, SurplusPolicy, NO_PATCH} from "@solvers/aggregator/AggregatorFillSolver.sol";

import {AggregatorItemFillTest} from "./AggregatorItemFill.t.sol";

/// @title AggregatorSelfSeedTest
/// @notice The SELF-SEEDING 1-wei balance floor (2026-10): a token the solver held
///         nothing of before a fill keeps one wei of it afterwards, so no deploy-time
///         `FLOOR_TOKENS` list is needed. Two mechanisms (see the contract):
///
///           • `_splitSurplus` — a zero snapshot keeps 1 wei of the FILLER'S share
///             (output spread, input residue, any token, every entry);
///           • `_seedIn` — a PULL / netted fill whose route follows the patched
///             `amountInOffset`, with no maker surplus share, routes `delta − 1`.
///
///  Every test is a TWIN: the same order filled by a COLD instance (holds nothing)
///  and a PRE-SEEDED one (1 wei of each token — what `FLOOR_TOKENS` gives). The
///  property pinned throughout: the maker, the fee legs and the core-reported
///  delivery are IDENTICAL between the twins; only the filler's take differs, by
///  the floor it paid for.
contract AggregatorSelfSeedTest is AggregatorItemFillTest {
    address constant FILLER = address(0xF00D);
    address constant ORIGINATOR = address(0x0F1C);
    address constant PROTOCOL = address(0x9807);
    uint256 constant FEE = 1e18;
    uint256 constant AMOUNT_WORD = 4; //  `swap(amountIn, …)` / `swapExactOut(amountOut, …)`
    uint256 constant MAX_IN_WORD = 36; // `swapExactOut(…, maxIn, …)`

    struct Take {
        uint256 makerA; // maker's tA spent
        uint256 makerB; // maker's tB received
        uint256 fillerA;
        uint256 fillerB;
        uint256 routed; // tA the router received
        uint256 out0; // the core's reported delivery of leg 0
    }

    function _instance(SurplusPolicy memory pol, bool seeded) internal returns (AggregatorFillSolver s) {
        s = new AggregatorFillSolver(address(settlement), _ops(), pol);
        if (seeded) {
            tA.mint(address(s), 1);
            tB.mint(address(s), 1);
        }
    }

    function _twins(SurplusPolicy memory pol) internal returns (AggregatorFillSolver cold, AggregatorFillSolver warm) {
        cold = _instance(pol, false);
        warm = _instance(pol, true);
    }

    function _plain(AggregatorFillSolver s, uint256 nonce, bool direct) internal view returns (Order memory o) {
        o = _order(nonce);
        if (direct) {
            o.timing |= uint256(1) << 104;
            o.exclusiveFiller = address(s);
        }
    }

    /// @dev Pull route quoted for `s`, patched or not.
    function _pullPlan(AggregatorFillSolver s, uint256 minOut, uint256 inOffset) internal view returns (RoutePlan memory p) {
        p = _planFor(AMOUNT_IN, address(s), minOut, inOffset);
        p.profitRecipient = FILLER;
    }

    function _fill(AggregatorFillSolver s, Order memory o, uint256 fillAmount, RoutePlan memory p)
        internal
        returns (Take memory t)
    {
        bytes memory sig = _sign(o);
        uint256 ma = tA.balanceOf(maker);
        uint256 mb = tB.balanceOf(maker);
        uint256 fa = tA.balanceOf(FILLER);
        uint256 fb = tB.balanceOf(FILLER);
        uint256 ra = tA.balanceOf(address(router));
        uint256[] memory outs = s.executeFill(o, sig, fillAmount, p, "");
        t = Take(
            ma - tA.balanceOf(maker),
            tB.balanceOf(maker) - mb,
            tA.balanceOf(FILLER) - fa,
            tB.balanceOf(FILLER) - fb,
            tA.balanceOf(address(router)) - ra,
            outs[0]
        );
    }

    function _assertMakerSame(Take memory a, Take memory b) internal pure {
        assertEq(a.makerA, b.makerA, "maker paid the same input");
        assertEq(a.makerB, b.makerB, "maker received the same output");
        assertEq(a.out0, b.out0, "the core verified / pulled the same delivery");
    }

    function _assertFloor(AggregatorFillSolver s, uint256 a, uint256 b) internal view {
        assertEq(tA.balanceOf(address(s)), a, "tA floor");
        assertEq(tB.balanceOf(address(s)), b, "tB floor");
    }

    // ═══════════════════════ executeFill — PULL ═══════════════════════

    /// The main shape (beta pull path: exact-input, `amountInOffset` set). The cold
    /// instance routes 99.999… tA and keeps 1 wei of each token; the maker is paid
    /// exactly as by the pre-seeded twin, and the floor then SUSTAINS ITSELF: the next
    /// fill on the now-seeded instance pays the filler the whole spread and leaves
    /// exactly the same 1 / 1.
    function test_seed_pull_patched_seedsBothAndIsSelfSustaining() public {
        (AggregatorFillSolver cold, AggregatorFillSolver warm) = _twins(_noSplit());
        Take memory c = _fill(cold, _plain(cold, 1, false), AMOUNT_IN, _pullPlan(cold, AMOUNT_OUT, AMOUNT_WORD));
        Take memory w = _fill(warm, _plain(warm, 2, false), AMOUNT_IN, _pullPlan(warm, AMOUNT_OUT, AMOUNT_WORD));

        _assertMakerSame(c, w);
        assertEq(c.makerB, AMOUNT_OUT, "maker: exactly its signed output");
        assertEq(c.routed, AMOUNT_IN - 1, "cold: one wei of tA withheld");
        assertEq(w.routed, AMOUNT_IN, "warm: the whole input routed");
        // 1:1 router: the withheld wei costs one wei of tB, and the tB split keeps one.
        assertEq(c.fillerB, w.fillerB - 2, "the filler paid both floors, nobody else");
        assertEq(c.fillerA, 0, "the 1-wei tA residue is the floor, not paid out");
        _assertFloor(cold, 1, 1);
        _assertFloor(warm, 1, 1);

        // Steady state: the self-seeded instance now behaves exactly like the warm one.
        Take memory c2 = _fill(cold, _plain(cold, 3, false), AMOUNT_IN, _pullPlan(cold, AMOUNT_OUT, AMOUNT_WORD));
        assertEq(c2.routed, AMOUNT_IN, "second fill: nothing withheld");
        assertEq(c2.fillerB, w.fillerB, "second fill: the whole spread to the filler");
        _assertFloor(cold, 1, 1);
    }

    /// `NO_PATCH`: the route pulls its QUOTED figure, so a sandbox one wei short would
    /// fail it — the input is not withheld. The output floor still seeds.
    function test_seed_pull_unpatched_onlyTheOutputSeeds() public {
        (AggregatorFillSolver cold, AggregatorFillSolver warm) = _twins(_noSplit());
        Take memory c = _fill(cold, _plain(cold, 1, false), AMOUNT_IN, _pullPlan(cold, AMOUNT_OUT, NO_PATCH));
        Take memory w = _fill(warm, _plain(warm, 2, false), AMOUNT_IN, _pullPlan(warm, AMOUNT_OUT, NO_PATCH));
        _assertMakerSame(c, w);
        assertEq(c.routed, AMOUNT_IN, "quoted figure routed in full");
        assertEq(c.fillerB, w.fillerB - 1, "only the tB floor");
        _assertFloor(cold, 0, 1);
    }

    /// The TYPED callback (an in-kind fee leg in the anchor token, `sameOut`) with a
    /// patched route: the fee is kept back FIRST, the floor wei after it, so the fee
    /// leg and the maker are paid exactly as by the seeded twin.
    function test_seed_pull_typedFeeLeg_feeAndMakerUnchanged() public {
        (AggregatorFillSolver cold, AggregatorFillSolver warm) = _twins(_noSplit());
        Order memory oc = _withFee(_plain(cold, 1, false));
        Order memory ow = _withFee(_plain(warm, 2, false));
        Take memory c = _fill(cold, oc, AMOUNT_IN, _pullPlan(cold, AMOUNT_OUT, AMOUNT_WORD));
        uint256 feeCold = tA.balanceOf(ORIGINATOR);
        Take memory w = _fill(warm, ow, AMOUNT_IN, _pullPlan(warm, AMOUNT_OUT, AMOUNT_WORD));
        _assertMakerSame(c, w);
        assertEq(feeCold, FEE, "cold: fee leg paid in full");
        assertEq(tA.balanceOf(ORIGINATOR), 2 * FEE, "warm: fee leg paid in full");
        assertEq(c.routed, AMOUNT_IN - FEE - 1, "input - fee - the floor");
        assertEq(w.routed, AMOUNT_IN - FEE, "input - fee");
        _assertFloor(cold, 1, 1);
        assertEq(tA.allowance(address(cold), address(settlement)), 0, "no allowance outlived the fill");
    }

    /// A maker surplus share: one wei less input is a smaller spread, a share of which
    /// is the maker's — so the input is NOT withheld; the output floor comes out of the
    /// filler's remainder, after the maker's and the protocol's shares.
    function test_seed_pull_makerShare_inputNotWithheld_sharesUnchanged() public {
        SurplusPolicy memory pol = SurplusPolicy({makerPpm: 500_000, protocolPpm: 100_000, protocolRecipient: PROTOCOL});
        (AggregatorFillSolver cold, AggregatorFillSolver warm) = _twins(pol);
        Take memory c = _fill(cold, _plain(cold, 1, false), AMOUNT_IN, _pullPlan(cold, AMOUNT_OUT, AMOUNT_WORD));
        uint256 protoCold = tB.balanceOf(PROTOCOL);
        Take memory w = _fill(warm, _plain(warm, 2, false), AMOUNT_IN, _pullPlan(warm, AMOUNT_OUT, AMOUNT_WORD));
        _assertMakerSame(c, w);
        assertEq(c.makerB, AMOUNT_OUT + 5e18, "maker: signed + 50% of the whole spread");
        assertEq(protoCold, 1e18, "protocol: 10% of the whole spread");
        assertEq(tB.balanceOf(PROTOCOL), 2e18, "protocol: same share on the twin");
        assertEq(c.routed, AMOUNT_IN, "nothing withheld under a maker share");
        assertEq(c.fillerB, w.fillerB - 1, "the floor out of the filler's 40%");
        _assertFloor(cold, 0, 1);
    }

    /// A PROTOCOL-only share stops the input withholding too: the protocol's cut of
    /// the spread is identical between the twins.
    function test_seed_pull_protocolShare_inputNotWithheld() public {
        SurplusPolicy memory pol = SurplusPolicy({makerPpm: 0, protocolPpm: 100_000, protocolRecipient: PROTOCOL});
        (AggregatorFillSolver cold, AggregatorFillSolver warm) = _twins(pol);
        Take memory c = _fill(cold, _plain(cold, 1, false), AMOUNT_IN, _pullPlan(cold, AMOUNT_OUT, AMOUNT_WORD));
        uint256 protoCold = tB.balanceOf(PROTOCOL);
        Take memory w = _fill(warm, _plain(warm, 2, false), AMOUNT_IN, _pullPlan(warm, AMOUNT_OUT, AMOUNT_WORD));
        _assertMakerSame(c, w);
        assertEq(protoCold, 1e18, "protocol: 10% of the whole spread");
        assertEq(tB.balanceOf(PROTOCOL), 2e18, "the same on the twin");
        assertEq(c.routed, AMOUNT_IN, "nothing withheld under a protocol share");
        assertEq(c.fillerB, w.fillerB - 1, "only the tB floor, out of the filler's 90%");
        _assertFloor(cold, 0, 1);
    }

    /// A policy that leaves the filler NOTHING (maker + protocol = 100%): there is no
    /// filler share to seed from, so nothing is retained and every share is exact.
    function test_seed_noFillerShare_noSeed() public {
        SurplusPolicy memory pol = SurplusPolicy({makerPpm: 600_000, protocolPpm: 400_000, protocolRecipient: PROTOCOL});
        AggregatorFillSolver cold = _instance(pol, false);
        Take memory c = _fill(cold, _plain(cold, 1, false), AMOUNT_IN, _pullPlan(cold, AMOUNT_OUT, AMOUNT_WORD));
        assertEq(c.makerB, AMOUNT_OUT + 6e18, "maker: 60% of the whole spread");
        assertEq(tB.balanceOf(PROTOCOL), 4e18, "protocol: 40% of the whole spread");
        _assertFloor(cold, 0, 0);
    }

    /// Retain mode keeps the whole filler share anyway — the seed rule is not
    /// applied twice and the event reports the full retained share.
    function test_seed_retainMode_unchanged() public {
        AggregatorFillSolver cold = _instance(_noSplit(), false);
        RoutePlan memory p = _pullPlan(cold, AMOUNT_OUT, NO_PATCH);
        p.profitRecipient = address(cold);
        Order memory o = _plain(cold, 1, false);
        bytes memory sig = _sign(o);
        vm.expectEmit(true, true, false, true, address(cold));
        emit AggregatorFillSolver.SurplusSplit(address(tB), maker, 0, 0, 0, AMOUNT_IN - AMOUNT_OUT);
        cold.executeFill(o, sig, AMOUNT_IN, p, "");
        _assertFloor(cold, 0, AMOUNT_IN - AMOUNT_OUT);
    }

    /// The accepted edge: a route quoted at ZERO margin over `minOut` cannot give up
    /// the wei — on the cold instance it reverts `InsufficientOutput`, the maker's
    /// funds untouched; the seeded twin fills. One wei of margin is enough.
    function test_seed_zeroMarginPatchedRoute_revertsOnlyCold() public {
        (AggregatorFillSolver cold, AggregatorFillSolver warm) = _twins(_noSplit());
        Order memory o = _plain(cold, 1, false);
        bytes memory sig = _sign(o);
        RoutePlan memory exact = _pullPlan(cold, AMOUNT_IN, AMOUNT_WORD); // 1:1, minOut = the whole output
        uint256 makerA = tA.balanceOf(maker);
        vm.expectRevert(
            _wrapped(abi.encodeWithSelector(AggregatorFillSolver.InsufficientOutput.selector, AMOUNT_IN - 1, AMOUNT_IN))
        );
        cold.executeFill(o, sig, AMOUNT_IN, exact, "");
        assertEq(tA.balanceOf(maker), makerA, "maker untouched");

        _fill(warm, _plain(warm, 2, false), AMOUNT_IN, _pullPlan(warm, AMOUNT_IN, AMOUNT_WORD));
        _fill(cold, _plain(cold, 3, false), AMOUNT_IN, _pullPlan(cold, AMOUNT_IN - 1, AMOUNT_WORD));
        _assertFloor(cold, 1, 1);
    }

    /// Partial fills, any rate above the maker's price: the maker's received amount
    /// never depends on whether the instance was seeded.
    function testFuzz_seed_pull_makerIndependentOfFloor(uint256 fillAmount, uint256 rateBps) public {
        fillAmount = bound(fillAmount, 1e6, AMOUNT_IN);
        rateBps = bound(rateBps, 9_001, 20_000);
        router.setRate(rateBps);
        (AggregatorFillSolver cold, AggregatorFillSolver warm) = _twins(_noSplit());
        Take memory c = _fill(cold, _plain(cold, 1, false), fillAmount, _pullPlan(cold, 0, AMOUNT_WORD));
        Take memory w = _fill(warm, _plain(warm, 2, false), fillAmount, _pullPlan(warm, 0, AMOUNT_WORD));
        _assertMakerSame(c, w);
        assertEq(c.routed + 1, w.routed, "exactly one wei withheld");
        assertEq(tA.balanceOf(address(cold)), 1, "tA floor");
        assertLe(c.fillerB, w.fillerB, "the filler, and only the filler, paid for it");
    }

    // ═══════════════════════ executeFill — DIRECT ═══════════════════════

    /// Direct exact-output, untyped and typed (`amountOutOffset`, the live price): the
    /// route is NOT shortened (it pays the maker); the input residue — the spread —
    /// seeds the tA floor out of the filler's share. tB never lands here.
    function test_seed_direct_exactOut_untyped() public {
        _directExactOut(NO_PATCH, NO_PATCH);
    }

    function test_seed_direct_exactOut_typedLiveAmountOut() public {
        _directExactOut(NO_PATCH, AMOUNT_WORD);
    }

    /// A patched `amountInMaximum` on a direct order is not withheld either.
    function test_seed_direct_exactOut_patchedMaxIn() public {
        _directExactOut(MAX_IN_WORD, NO_PATCH);
    }

    function _directExactOut(uint256 inOffset, uint256 outOffset) internal {
        (AggregatorFillSolver cold, AggregatorFillSolver warm) = _twins(_noSplit());
        RoutePlan memory pc = _exactOutPlan(AMOUNT_OUT, AMOUNT_IN, maker);
        (pc.amountInOffset, pc.amountOutOffset, pc.profitRecipient) = (inOffset, outOffset, FILLER);
        RoutePlan memory pw = _exactOutPlan(AMOUNT_OUT, AMOUNT_IN, maker);
        (pw.amountInOffset, pw.amountOutOffset, pw.profitRecipient) = (inOffset, outOffset, FILLER);
        Take memory c = _fill(cold, _plain(cold, 1, true), AMOUNT_IN, pc);
        Take memory w = _fill(warm, _plain(warm, 2, true), AMOUNT_IN, pw);
        _assertMakerSame(c, w);
        assertEq(c.makerB, AMOUNT_OUT, "maker: exactly the verified amount");
        assertEq(c.routed, w.routed, "the route was not shortened");
        assertEq(c.fillerA, w.fillerA - 1, "the tA floor out of the residue");
        _assertFloor(cold, 1, 0);
    }

    /// Direct EXACT-INPUT (the maker gets the whole swap): no residue, and withholding
    /// would short the MAKER — so nothing seeds and the maker gets every wei.
    function test_seed_direct_exactInput_noSeedMakerGetsAll() public {
        (AggregatorFillSolver cold, AggregatorFillSolver warm) = _twins(_noSplit());
        RoutePlan memory pc = _planFor(AMOUNT_IN, maker, 0, AMOUNT_WORD);
        RoutePlan memory pw = _planFor(AMOUNT_IN, maker, 0, AMOUNT_WORD);
        Take memory c = _fill(cold, _plain(cold, 1, true), AMOUNT_IN, pc);
        Take memory w = _fill(warm, _plain(warm, 2, true), AMOUNT_IN, pw);
        _assertMakerSame(c, w);
        assertEq(c.makerB, AMOUNT_IN, "the whole output to the maker");
        _assertFloor(cold, 0, 0);
    }

    // ═══════════════════════ executeItemFill — NETTED ═══════════════════════

    /// The netted path, item-bearing order, patched route: PRESEND's amount less one
    /// wei is routed, the swept spread seeds tB; the maker's position legs (the TAKE
    /// and the late deposit) are exactly the seeded twin's.
    function test_seed_netted_itemOrder_patched() public {
        (AggregatorFillSolver cold, AggregatorFillSolver warm) = _twins(_noSplit());
        uint256 r0 = tA.balanceOf(address(router));
        uint256 f0 = tB.balanceOf(FILLER);
        _itemFillOn(cold, 11);
        uint256 routedCold = tA.balanceOf(address(router)) - r0;
        uint256 fillerCold = tB.balanceOf(FILLER) - f0;
        uint256 depositedCold = tB.balanceOf(address(depositor));
        _itemFillOn(warm, 12);
        assertEq(depositedCold, AMOUNT_OUT, "cold: the deposit got the delivered output");
        assertEq(tB.balanceOf(address(depositor)), 2 * AMOUNT_OUT, "warm: the same");
        assertEq(routedCold, AMOUNT_IN - 1, "cold: one wei withheld");
        assertEq(tB.balanceOf(FILLER) - f0 - fillerCold, fillerCold + 2, "filler paid both floors");
        _assertFloor(cold, 1, 1);
        assertEq(tA.balanceOf(address(settlement)), 0, "pool flat");
        assertEq(tB.balanceOf(address(settlement)), 0, "pool flat");
    }

    /// An item-FREE order through the netted entry seeds the same way.
    function test_seed_netted_itemFree_patched() public {
        (AggregatorFillSolver cold, AggregatorFillSolver warm) = _twins(_noSplit());
        uint256 mb = tB.balanceOf(maker);
        _netted(cold, _plain(cold, 21, false));
        uint256 makerCold = tB.balanceOf(maker) - mb;
        _netted(warm, _plain(warm, 22, false));
        assertEq(makerCold, AMOUNT_OUT, "maker paid");
        assertEq(tB.balanceOf(maker) - mb - makerCold, makerCold, "the same on the twin");
        _assertFloor(cold, 1, 1);
    }

    // ───────────── helpers ─────────────

    function _withFee(Order memory o) internal view returns (Order memory) {
        LegOut[] memory lo = new LegOut[](2);
        lo[0] = LegOut(address(tB), AMOUNT_OUT, 0, address(0));
        lo[1] = LegOut(address(tA), FEE, 0, ORIGINATOR);
        o.legsOut = PackedEncode.legsOut(lo);
        return o;
    }

    function _itemFillOn(AggregatorFillSolver s, uint256 nonce) internal {
        Order memory o = _itemOrder(nonce, ItemPolicy.ANY);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _pullPlan(s, AMOUNT_OUT, AMOUNT_WORD);
        s.executeItemFill(o, sig, AMOUNT_IN, p, "", LATE_DEPOSIT);
    }

    function _netted(AggregatorFillSolver s, Order memory o) internal {
        bytes memory sig = _sign(o);
        s.executeItemFill(o, sig, AMOUNT_IN, _pullPlan(s, AMOUNT_OUT, AMOUNT_WORD), "", 0);
    }
}
