// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";
import {Settlement} from "@core/settlement/Settlement.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {MockSettlementBase} from "../shared/MockSettlementBase.t.sol";

/// @dev The attacker's solver contract: it calls `matchSettle` (so it is the
///      `msg.sender` the final sweep pays), and pads the pool from its own
///      inventory in a `CALL` step so that no round can ever fail
///      {BatchNotWhole}. Whatever the pad does not cover comes straight back in
///      the sweep — so this contract's balance delta IS the attacker's realised
///      P&L on the solver side, with nothing hidden in a revert path.
contract GrindSolver {
    Settlement immutable settlement;

    constructor(Settlement s) {
        settlement = s;
    }

    function run(MatchPlan calldata p) external {
        settlement.matchSettle(p);
    }

    /// @dev Push a fixed pad of both tokens into the pool mid-schedule. Deliberately
    ///      generous: the unused remainder is swept back, so over-padding cannot
    ///      flatter the accounting.
    function pad(address t0, address t1, uint256 amt) external {
        IERC20(t0).transfer(address(settlement), amt);
        IERC20(t1).transfer(address(settlement), amt);
    }
}

/// @title MatchSettleRoundingAttack
/// @notice Can a CoW counterparty steal the rounding?
///
///  {Pricing} rounds every slice toward the MAKER — auctioned outputs `ceilDiv`
///  up, auctioned inputs floor down — and `docs/pricing-modes.md` argues the
///  filler absorbs that wei because the filler chooses the slice size. That
///  argument is written for the SINGLE-ORDER path, where "the filler" is the only
///  counterparty and `RoundingDirection.t.sol` pins the direction.
///
///  `matchSettle` changes the shape of the question. Two makers now clear against
///  a shared POOL, the wholeness check ({BatchNotWhole}) only asserts that the
///  pool ends level ACROSS all of them, and the filler both authors the schedule
///  and may sign one of the orders. So the natural attack is: sign a counterparty
///  order engineered to sit on the other side of a victim's, slice the match into
///  dust, and try to make the victim's own maker-favourable rounding pay OUT of
///  the victim rather than out of the filler.
///
///  It cannot work, and the reason is structural rather than numerical:
///  `outs[i]`/`owed[i]` are resolved in {Batch._matchOpenAll} from order `i`'s own
///  calldata and its own {FillCtx} — no term in {Pricing} reads another order.
///  Cross-order coupling exists only as CONSERVATION (`outstanding`, `beforeBal`,
///  `_sweepSurplus`), never as price. These tests pin both halves of that:
///
///    • {test_victimPricing_isIndependentOfCounterparty} — the victim's ledger
///      entry for a given fill amount is identical whether the fill happens via
///      `fill` or inside a `matchSettle` against a hostile counter-order.
///    • {testFuzz_grinding_cannotDrainTheVictim} — under ANY dust schedule the
///      attacker never takes more of the victim's input than the victim signed
///      away, and must pay at least the victim's signed output, strictly more the
///      finer they grind. The rounding is a TAX on grinding, not a leak.
contract MatchSettleRoundingAttackTest is MockSettlementBase {
    // Coprime-ish on purpose: a round pair divides evenly and the whole property
    // goes untested (`docs/edge-case-matrix.md`: "round numbers mask rounding").
    uint256 constant AMOUNT_IN = 1_000_000_000_000_000_007; // victim sells this much tA
    uint256 constant AMOUNT_OUT = 3_000_000_000_000_000_001; // …for at least this much tB

    uint256 malloryPk = 0x3A11_0F;
    address mallory = vm.addr(malloryPk);

    GrindSolver grinder;

    function setUp() public override {
        super.setUp();
        vm.label(mallory, "mallory");
        grinder = new GrindSolver(settlement);
        vm.label(address(grinder), "grindSolver");
    }

    // ──────────────────── helpers ────────────────────

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    function _approveFor(address who, address token, uint256 cap) internal {
        vm.startPrank(who);
        IERC20(token).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), token, uint160(cap), 0);
        vm.stopPrank();
    }

    function _orderFor(address who, uint256 nonce, address tokenIn, address tokenOut, uint256 amtIn, uint256 amtOut)
        internal
        view
        returns (Order memory o)
    {
        o = _plainOrder(nonce, tokenIn, tokenOut, amtIn, amtOut);
        o.maker = who; // `_blank` defaults to `maker`; the attacker signs their own
    }

    function _step(uint256 kind, uint256 a, uint256 b) internal pure returns (uint256) {
        return kind | (a << 8) | (b << 24);
    }

    /// @dev PULL both inputs → pad the pool from the attacker's inventory → deliver
    ///      both outputs. The pad makes every round succeed, so a failure to drain
    ///      can never be mistaken for a revert we simply did not fund.
    function _schedule() internal pure returns (uint256[] memory s) {
        s = new uint256[](5);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 1, 0);
        s[2] = _step(MatchStep.CALL, 0, 0);
        s[3] = _step(MatchStep.DELIVER, 0, 0);
        s[4] = _step(MatchStep.DELIVER, 1, 0);
    }

    function _plan(Order memory victim, Order memory attacker, uint256 fillV, uint256 fillA)
        internal
        view
        returns (MatchPlan memory p)
    {
        Order[] memory orders = new Order[](2);
        orders[0] = victim;
        orders[1] = attacker;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signWith(victim, makerPk);
        sigs[1] = _signWith(attacker, malloryPk);
        uint256[] memory fills = new uint256[](2);
        fills[0] = fillV;
        fills[1] = fillA;
        address[] memory targets = new address[](1);
        targets[0] = address(grinder);
        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodeCall(GrindSolver.pad, (address(tA), address(tB), 1e6));
        p = MatchPlan({
            orders: orders,
            sigs: sigs,
            fillAmounts: fills,
            takerDatas: new bytes[](0),
            schedule: _schedule(),
            callTargets: targets,
            callDatas: datas,
            profitRecipient: address(0)
        });
    }

    // ──────────────────── 1. the victim's price is not a function of the match ────────────────────

    /// @notice The counterparty cannot move the victim's numbers at all. The same
    ///         order and the same fill amount produce the same maker ledger entry
    ///         through `fill` and through `matchSettle` against an order authored
    ///         entirely by the attacker — including its price, its size and its
    ///         direction. This is the structural claim; the fuzz below is the
    ///         economic one.
    function test_victimPricing_isIndependentOfCounterparty() public {
        uint256 slice = AMOUNT_IN / 3; // a partial fill, so the slice math is live

        // ── (a) baseline: the plain single-order path, an ordinary solver. ──
        Order memory v1 = _plainOrder(1, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        bytes memory sigV1 = _sign(v1);
        tA.mint(maker, AMOUNT_IN);
        _makerApprove(address(settlement), address(tA), AMOUNT_IN);
        tB.mint(solver, AMOUNT_OUT);
        _solverApprove(address(settlement), address(tB), AMOUNT_OUT);
        vm.prank(solver);
        settlement.fill(v1, sigV1, slice);
        uint256 baseSpent = AMOUNT_IN - tA.balanceOf(maker);
        uint256 baseGot = tB.balanceOf(maker);

        // ── (b) the same fill, netted against a counter-order the ATTACKER wrote:
        //       different size, different rate, deliberately awkward numbers. ──
        Order memory v2 = _plainOrder(2, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        Order memory atk = _orderFor(mallory, 3, address(tB), address(tA), 7_777_777_777_777_777_777, 13);
        tA.mint(maker, AMOUNT_IN);
        _makerApprove(address(settlement), address(tA), AMOUNT_IN * 2);
        tB.mint(mallory, 7_777_777_777_777_777_777);
        _approveFor(mallory, address(tB), 7_777_777_777_777_777_777);
        tA.mint(address(grinder), 1e18);
        tB.mint(address(grinder), 1e18);

        uint256 beforeA = tA.balanceOf(maker);
        uint256 beforeB = tB.balanceOf(maker);
        // The attacker fills their own order by whatever amount they like.
        grinder.run(_plan(v2, atk, slice, 5_000_000_000_000_000_000));

        assertEq(beforeA - tA.balanceOf(maker), baseSpent, "victim paid the same input");
        assertEq(tB.balanceOf(maker) - beforeB, baseGot, "victim received the same output");
    }

    // ──────────────────── 2. grinding the match is a tax on the grinder ────────────────────

    /// @notice The drain attempt itself. The attacker owns BOTH the counter-order
    ///         (`mallory`) and the filler (`grinder`), so every wei either side of
    ///         the match reaches them; the pair is scored as one balance sheet.
    ///         They slice the victim's order into `rawSlices` dust fills, which is
    ///         the only lever the maker-favourable rounding gives them.
    ///
    ///         Two things must hold however fine the grind:
    ///           • the victim never pays more than the `AMOUNT_IN` they signed, and
    ///           • the attacker must hand over at least the `AMOUNT_OUT` they signed
    ///             — strictly MORE once the order is sliced, one wei per extra slice,
    ///             because the victim's output leg ceils per fill.
    ///
    ///         `minFillAnchor` is left at 0, i.e. the victim published the most
    ///         permissive order they can. If a drain existed, this is where it lives.
    function testFuzz_grinding_cannotDrainTheVictim(uint8 rawSlices) public {
        uint256 slices = uint256(rawSlices) % 24 + 1;

        Order memory victim = _plainOrder(1, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        // The attacker's own book, at double size so the grind never over-fills it,
        // priced as the exact mirror of the victim's — the most aggressive rate the
        // pool will carry, since anything better makes the attacker's own leg
        // unfundable rather than profitable.
        Order memory atk = _orderFor(mallory, 2, address(tB), address(tA), AMOUNT_OUT * 2, AMOUNT_IN * 2);

        tA.mint(maker, AMOUNT_IN);
        _makerApprove(address(settlement), address(tA), AMOUNT_IN);
        tB.mint(mallory, AMOUNT_OUT * 2);
        _approveFor(mallory, address(tB), AMOUNT_OUT * 2);
        // Working capital for the pad, plus the sweep destination.
        tA.mint(address(grinder), 1e18);
        tB.mint(address(grinder), 1e18);

        uint256 attackerA0 = tA.balanceOf(mallory) + tA.balanceOf(address(grinder));
        uint256 attackerB0 = tB.balanceOf(mallory) + tB.balanceOf(address(grinder));

        uint256 filled;
        for (uint256 k; k < slices; ++k) {
            uint256 d = k + 1 == slices ? AMOUNT_IN - filled : AMOUNT_IN / slices;
            if (d == 0) continue;
            // What the victim's order owes on this slice — the attacker must source
            // exactly this much tB, so it is also their own order's fill amount.
            uint256 need =
                _ceilDiv(AMOUNT_OUT * (filled + d), AMOUNT_IN) - _ceilDiv(AMOUNT_OUT * filled, AMOUNT_IN);
            grinder.run(_plan(victim, atk, d, need));
            filled += d;

            // Invariant at EVERY intermediate point, not just at the end: the victim
            // is never behind their own signed rate, however the grind is timed.
            assertGe(
                tB.balanceOf(maker), _ceilDiv((AMOUNT_IN - tA.balanceOf(maker)) * AMOUNT_OUT, AMOUNT_IN), "under limit"
            );
        }

        uint256 victimGot = tB.balanceOf(maker);
        assertEq(tA.balanceOf(maker), 0, "victim spent exactly the signed input, never more");
        assertGe(victimGot, AMOUNT_OUT, "victim received at least the signed output");

        // The attacker's combined book. They take exactly the input the victim
        // signed away — the rounding hands them nothing extra — and they pay the
        // victim's full output plus one wei of ceiling dust per extra slice.
        uint256 attackerAGain = tA.balanceOf(mallory) + tA.balanceOf(address(grinder)) - attackerA0;
        uint256 attackerBLoss = attackerB0 - (tB.balanceOf(mallory) + tB.balanceOf(address(grinder)));
        assertEq(attackerAGain, AMOUNT_IN, "attacker cannot take more input than the victim signed");
        assertEq(attackerBLoss, victimGot, "every wei the victim gained came out of the attacker");
        assertGe(attackerBLoss, AMOUNT_OUT, "attacker paid at least the signed price");

        // Nothing stranded, and no pre-existing pool balance was reachable.
        assertEq(tA.balanceOf(address(settlement)), 0, "no tA stranded");
        assertEq(tB.balanceOf(address(settlement)), 0, "no tB stranded");
    }

    /// @notice The same ledger, stated as a comparison rather than a bound: grinding
    ///         is strictly worse for the attacker than settling in one shot. One
    ///         victim is filled whole, an identical one is filled in 16 slices, and
    ///         the fine grind costs the attacker more tB for the same tA.
    function test_grinding_costsTheGrinder() public {
        uint256 oneShot = _runGrind(1, 1, 2);
        uint256 sliced = _runGrind(16, 3, 4);
        assertGt(sliced, oneShot, "the finer grind pays the victim more, not less");
    }

    // ──────────────────── 3. the one direction that DOES leak, quantified ────────────────────

    /// @notice The residual, stated rather than hidden: "rounds toward the maker" is
    ///         not merely a tie-break, and on a BUY order a dust slice can round the
    ///         maker's charge all the way to ZERO while still delivering a wei.
    ///
    ///         `inputOwed` prices a BUY input as `floor(delta · inTick / anchor)`
    ///         with `anchor = legsOut[0]`. When the output leg is numerically larger
    ///         than the input leg — any order buying a token with a smaller unit
    ///         value, which is most of them — a one-unit `delta` floors the charge to
    ///         nothing, while `outputAt`'s cumulative ceil still owes one unit out.
    ///         The filler funds it.
    ///
    ///  ⚠ WHY THIS IS NOT THE DRAIN THE FILE IS ABOUT. The leak points at the
    ///    FILLER, and on `matchSettle` the filler is `msg.sender`, who authored the
    ///    schedule and chose the slice — the loss is self-inflicted, which is
    ///    exactly the posture `docs/pricing-modes.md` claims. It is bounded at one
    ///    unit of the output token per fill against a whole transaction of gas, so
    ///    it is uneconomic wherever a unit is not itself valuable, and a maker's
    ///    signed `minFillAnchor` removes it outright. It is asserted here so that a
    ///    future change to the BUY-side rounding cannot quietly widen it.
    function test_buySideDustFill_chargesTheMakerNothing() public {
        // Buy 3e18+1 of tB for 1e18+7 of tA — output leg numerically the larger.
        Order memory o = _buyOrder(9, address(tA), address(tB), AMOUNT_IN, 0, AMOUNT_OUT);
        bytes memory sig = _sign(o);

        tA.mint(maker, AMOUNT_IN);
        _makerApprove(address(settlement), address(tA), AMOUNT_IN);
        tB.mint(solver, AMOUNT_OUT);
        _solverApprove(address(settlement), address(tB), AMOUNT_OUT);

        uint256 makerA0 = tA.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, 1); // one unit of the OUTPUT — a BUY fills in out units

        assertEq(makerA0 - tA.balanceOf(maker), 0, "the maker was charged nothing");
        assertEq(tB.balanceOf(maker), 1, "and still received a unit, funded by the filler");

        // The `minFillAnchor` the maker can sign is the switch that turns it off.
        Order memory guarded = _buyOrder(10, address(tA), address(tB), AMOUNT_IN, 0, AMOUNT_OUT);
        guarded.minFillAnchor = AMOUNT_OUT / 100;
        bytes memory sig2 = _sign(guarded);
        vm.prank(solver);
        vm.expectRevert(); // FillTooSmall
        settlement.fill(guarded, sig2, 1);
    }

    /// @dev Run a full grind of one victim order and return the tB the attacker had
    ///      to give up. Fresh nonces per invocation so the two runs never interact.
    function _runGrind(uint256 slices, uint256 nonceV, uint256 nonceA) internal returns (uint256 paid) {
        Order memory victim = _plainOrder(nonceV, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        Order memory atk = _orderFor(mallory, nonceA, address(tB), address(tA), AMOUNT_OUT * 2, AMOUNT_IN * 2);

        tA.mint(maker, AMOUNT_IN);
        _makerApprove(address(settlement), address(tA), AMOUNT_IN);
        tB.mint(mallory, AMOUNT_OUT * 2);
        _approveFor(mallory, address(tB), AMOUNT_OUT * 2);
        tA.mint(address(grinder), 1e18);
        tB.mint(address(grinder), 1e18);

        uint256 b0 = tB.balanceOf(mallory) + tB.balanceOf(address(grinder));
        uint256 filled;
        for (uint256 k; k < slices; ++k) {
            uint256 d = k + 1 == slices ? AMOUNT_IN - filled : AMOUNT_IN / slices;
            uint256 need =
                _ceilDiv(AMOUNT_OUT * (filled + d), AMOUNT_IN) - _ceilDiv(AMOUNT_OUT * filled, AMOUNT_IN);
            grinder.run(_plan(victim, atk, d, need));
            filled += d;
        }
        paid = b0 - (tB.balanceOf(mallory) + tB.balanceOf(address(grinder)));
    }
}
