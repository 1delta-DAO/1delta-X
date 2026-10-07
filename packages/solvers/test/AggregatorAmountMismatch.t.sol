// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Order, Item, ItemOp, LegIn, LegOut} from "@core/settlement/Settlement.sol";
import {ItemPolicy} from "@core/settlement/Structs.sol";
import {Base} from "@core/settlement/Base.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {AggregatorFillSolver, RoutePlan, NO_PATCH} from "@solvers/aggregator/AggregatorFillSolver.sol";

import {AggregatorItemFillTest, IAggregatorItemFill} from "./AggregatorItemFill.t.sol";

/// @title AggregatorAmountMismatchTest
/// @notice Review 2026-10-05 ("mismatching amounts"): the amount the solver ROUTES
///         is `balanceOf(tokens[0]) − before[0]`, which is NOT always the amount the
///         core resolved for the maker's anchor leg. Two shapes where the two differ,
///         pinned so the difference stays a documented revert and never a loss:
///
///           S1  an output leg in the anchor token — both entries now keep it back
///               (`executeItemFill`: PRESEND nets the pool's outstanding outputs;
///               `executeFill`: the typed callback subtracts the priced leg,
///               2026-10-06) — before, the pull path routed the whole input and a
///               patched route failed the leg's pull;
///           S2  a TAKE item that over-produces its leg — refunded to the maker on
///               both paths since core B-1 (2026-10-06); before, PRESEND handed the
///               excess to the route and the netted refund found an empty pool.
contract AggregatorAmountMismatchTest is AggregatorItemFillTest {
    address constant ORIGINATOR = address(0x0F1C);
    uint256 constant FEE = 1e18;
    uint256 constant EXTRA = 5e18;

    /// @dev legsIn = [tA 100], legsOut = [tB 90 → maker, tA 1 → originator]: an
    ///      output leg denominated in the INPUT token (a sourcing fee taken in-kind).
    function _feeInInputTokenOrder(uint256 nonce) internal view returns (Order memory o) {
        o = _order(nonce);
        LegOut[] memory lo = new LegOut[](2);
        lo[0] = LegOut(address(tB), AMOUNT_OUT, 0, address(0));
        lo[1] = LegOut(address(tA), FEE, 0, ORIGINATOR);
        o.legsOut = PackedEncode.legsOut(lo);
    }

    /// @dev `swap(amountIn, …)`'s amount word sits right after the selector.
    uint256 constant AMOUNT_WORD = 4;

    function _pull(Order memory o, RoutePlan memory plan) internal returns (bool ok, bytes memory ret) {
        bytes memory sig = _sign(o);
        (ok, ret) = address(aggSolver).call(abi.encodeCall(aggSolver.executeFill, (o, sig, AMOUNT_IN, plan, "")));
    }

    function _netted(Order memory o, RoutePlan memory plan) internal returns (bool ok, bytes memory ret) {
        bytes memory sig = _sign(o);
        (ok, ret) = address(aggSolver).call(
            abi.encodeCall(IAggregatorItemFill.executeItemFill, (o, sig, AMOUNT_IN, plan, bytes(""), 0))
        );
    }

    // ───────────── S1: output leg in the anchor token ─────────────

    /// S1 / pull path, patched, since the typed callback (2026-10-06): the solver
    /// keeps the 1 tA fee leg back and patches the route with 99, the core's pull of
    /// the leg finds it here, and the fill lands exactly like the netted path.
    /// (Before: the whole 100 was routed and the pull reverted `TransferFromFailed`
    /// — review 2026-10-05 S1.)
    function test_S1_pullPath_patchedRouteKeepsTheFeeBack() public {
        Order memory o = _feeInInputTokenOrder(11);
        (bool ok, bytes memory ret) = _pull(o, _planFor(1, address(aggSolver), AMOUNT_OUT, AMOUNT_WORD));
        assertTrue(ok, string(ret));
        assertEq(tA.balanceOf(ORIGINATOR), FEE, "fee paid from the kept-back input");
        assertEq(tB.balanceOf(maker), AMOUNT_OUT);
        assertEq(tA.balanceOf(address(router)), AMOUNT_IN - FEE, "route sold input - fee");
        assertEq(tB.balanceOf(address(this)), AMOUNT_IN - FEE - AMOUNT_OUT, "spread");
        assertEq(tA.balanceOf(address(aggSolver)), 0);
    }

    /// S1 / pull path, unpatched at `received − fee`: the fee is paid from the
    /// unrouted residue — the operator's quote has to carry the leg.
    function test_S1_pullPath_unpatchedQuoteMinusFeeFills() public {
        Order memory o = _feeInInputTokenOrder(12);
        (bool ok, bytes memory ret) = _pull(o, _planFor(AMOUNT_IN - FEE, address(aggSolver), AMOUNT_OUT, NO_PATCH));
        assertTrue(ok, string(ret));
        assertEq(tA.balanceOf(ORIGINATOR), FEE, "fee paid from the unrouted residue");
        assertEq(tB.balanceOf(maker), AMOUNT_OUT);
        assertEq(tA.balanceOf(address(router)), AMOUNT_IN - FEE, "route sold input - fee");
        assertEq(tB.balanceOf(address(this)), AMOUNT_IN - FEE - AMOUNT_OUT, "spread");
        assertEq(tA.balanceOf(address(aggSolver)), 0);
    }

    /// S1 / netted path, the SAME patched plan: PRESEND nets the 1 tA outstanding,
    /// so the route gets 99 tA and the pool delivers the fee.
    function test_S1_nettedPath_patchedRouteNetsTheFee() public {
        Order memory o = _feeInInputTokenOrder(13);
        (bool ok, bytes memory ret) = _netted(o, _planFor(1, address(aggSolver), AMOUNT_OUT, AMOUNT_WORD));
        assertTrue(ok, string(ret));
        assertEq(tA.balanceOf(ORIGINATOR), FEE, "fee delivered from the pool");
        assertEq(tB.balanceOf(maker), AMOUNT_OUT);
        assertEq(tA.balanceOf(address(router)), AMOUNT_IN - FEE, "route sold input - fee");
        assertEq(tB.balanceOf(address(this)), AMOUNT_IN - FEE - AMOUNT_OUT, "spread");
        assertEq(tA.balanceOf(address(settlement)), 0, "pool flat");
        assertEq(tA.balanceOf(address(aggSolver)), 0);
    }

    // ───────────── S3: minOut / maxPay keyed to the wrong token ─────────────

    /// @dev The in-kind fee leg listed FIRST: legsOut = [tA 1 → originator, tB 90 → maker].
    function _feeFirstOrder(uint256 nonce) internal view returns (Order memory o) {
        o = _order(nonce);
        LegOut[] memory lo = new LegOut[](2);
        lo[0] = LegOut(address(tA), FEE, 0, ORIGINATOR);
        lo[1] = LegOut(address(tB), AMOUNT_OUT, 0, address(0));
        o.legsOut = PackedEncode.legsOut(lo);
    }

    /// S3(i): with the fee leg first, `minOut` used to floor the tA INPUT RESIDUE
    /// (legsOut[0]'s token) and leave the tB proceeds unbounded. The anchor is now the
    /// first output token no input leg pays — tB — on both entries.
    function test_S3_feeLegFirst_minOutFloorsTheProceedsNotTheResidue() public {
        // Unpatched quote of input - fee (S1); the route yields 99 tB.
        uint256 yield = AMOUNT_IN - FEE;
        Order memory o = _feeFirstOrder(31);
        // A floor above the proceeds must bind on tB — under the old rule the compare
        // ran against the 1 tA residue and this would have reverted with (1e18, …)
        // or, with minOut = 1e18, passed with the proceeds unchecked.
        (bool ok, bytes memory ret) = _pull(o, _planFor(yield, address(aggSolver), yield + 1, NO_PATCH));
        assertFalse(ok);
        assertEq(ret, _wrapped(abi.encodeWithSelector(AggregatorFillSolver.InsufficientOutput.selector, yield, yield + 1)));

        (ok, ret) = _netted(o, _planFor(yield, address(aggSolver), yield + 1, NO_PATCH));
        assertFalse(ok);
        assertEq(ret, _wrapped(abi.encodeWithSelector(AggregatorFillSolver.InsufficientOutput.selector, yield, yield + 1)));

        // At the proceeds exactly, both fill and the fee leg is paid.
        (ok, ret) = _pull(o, _planFor(yield, address(aggSolver), yield, NO_PATCH));
        assertTrue(ok, string(ret));
        assertEq(tA.balanceOf(ORIGINATOR), FEE);
        assertEq(tB.balanceOf(maker), AMOUNT_OUT);
    }

    /// @dev legsIn = [tA 100, tB 5], legsOut = [tB 90]: the output token is also paid
    ///      by a second input leg.
    function _outputAlsoInputOrder(uint256 nonce, uint256 extraIn) internal returns (Order memory o) {
        o = _order(nonce);
        LegIn[] memory li = new LegIn[](2);
        li[0] = LegIn(address(tA), AMOUNT_IN, 0);
        li[1] = LegIn(address(tB), extraIn, 0);
        o.legsIn = PackedEncode.legsIn(li);
        tB.mint(maker, extraIn);
        _makerApprove(address(settlement), address(tB), type(uint160).max);
    }

    /// S3(ii): on the pull path the maker's own tB input leg lands here before the
    /// route and used to count as route proceeds — `minOut = 100` passed on a route
    /// that yielded 96 (96 + 5 ≥ 100) while the netted path (PRESEND keeps the 5 in
    /// the pool: 5 < outstanding 90) reverted. Both now floor the route's own yield.
    function test_S3_outputTokenAlsoInput_makerInflowDoesNotSatisfyMinOut() public {
        uint256 extraIn = 5e18;
        router.setRate(9_600); // 100 tA → 96 tB

        // Pull path: the whole-fill tB delta is 96 + 5 and the floor is lifted by the
        // 5 that landed before the route — reported as (101, 105), i.e. 96 < 100.
        Order memory o = _outputAlsoInputOrder(32, extraIn);
        (bool ok, bytes memory ret) = _pull(o, _planFor(AMOUNT_IN, address(aggSolver), 100e18, NO_PATCH));
        assertFalse(ok);
        assertEq(
            ret,
            _wrapped(abi.encodeWithSelector(AggregatorFillSolver.InsufficientOutput.selector, 101e18, 105e18)),
            "pull"
        );

        // Netted path: PRESEND keeps the 5 tB in the pool (5 < outstanding 90), so
        // nothing lands before the route and the compare is the plain (96, 100).
        o = _outputAlsoInputOrder(33, extraIn);
        (ok, ret) = _netted(o, _planFor(AMOUNT_IN, address(aggSolver), 100e18, NO_PATCH));
        assertFalse(ok);
        assertEq(
            ret,
            _wrapped(abi.encodeWithSelector(AggregatorFillSolver.InsufficientOutput.selector, 96e18, 100e18)),
            "netted"
        );

        // At the route's real yield both fill; the maker's 5 tB is residue (AGG-2),
        // split to the caller under the zero policy together with the 6 tB spread.
        o = _outputAlsoInputOrder(34, extraIn);
        uint256 makerB = tB.balanceOf(maker);
        (ok, ret) = _pull(o, _planFor(AMOUNT_IN, address(aggSolver), 96e18, NO_PATCH));
        assertTrue(ok, string(ret));
        assertEq(tB.balanceOf(maker), makerB - extraIn + AMOUNT_OUT, "paid the tB leg, received the output");
        assertEq(tB.balanceOf(address(this)), 96e18 + extraIn - AMOUNT_OUT);
        assertEq(tB.balanceOf(address(aggSolver)), 0);
    }

    /// S3(iii): `maxPay` is per TOKEN — two tB legs (maker 90 + fee 2) need `maxPay ≥ 92`.
    function test_S3_maxPayIsPerToken() public {
        uint256 feeB = 2e18;
        Order memory o = _order(35);
        LegOut[] memory lo = new LegOut[](2);
        lo[0] = LegOut(address(tB), AMOUNT_OUT, 0, address(0));
        lo[1] = LegOut(address(tB), feeB, 0, ORIGINATOR);
        o.legsOut = PackedEncode.legsOut(lo);

        RoutePlan memory plan = _planFor(AMOUNT_IN, address(aggSolver), 0, NO_PATCH);
        plan.maxPay = AMOUNT_OUT; // legsOut[0] only: the fee leg's pull then exceeds the cap
        (bool ok, bytes memory ret) = _pull(o, plan);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(SafeTransferLib.TransferFromFailed.selector));

        plan.maxPay = AMOUNT_OUT + feeB;
        (ok, ret) = _pull(o, plan);
        assertTrue(ok, string(ret));
        assertEq(tB.balanceOf(maker), AMOUNT_OUT);
        assertEq(tB.balanceOf(ORIGINATOR), feeB);
    }

    // ───────────── S2: a TAKE item that over-produces its input leg ─────────────

    /// @dev TAKE produces `AMOUNT_IN + EXTRA` of tA against a leg owing AMOUNT_IN.
    function _overProducingOrder(uint256 nonce) internal returns (Order memory o) {
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.TAKE,
            module: address(taker),
            amount: AMOUNT_IN,
            recipient: address(0),
            data: abi.encode(address(tA), AMOUNT_IN + EXTRA)
        });
        o = _order(nonce);
        o.items = PackedEncode.items(items);
        _authItems(o, items[0].data);
    }

    /// S2 / netted path, since core B-1 (2026-10-06): the crossing part of the TAKE's
    /// credit joins `outstanding`, PRESEND hands the route exactly `owed`, and the
    /// Phase-3 refund pays the maker the excess — the single-order path's outcome.
    /// (Before B-1 the excess reached the route and the refund reverted
    /// `TransferFailed`, patched or not — review 2026-10-05.)
    function test_S2_nettedPath_overProducingTakeRefundsMaker() public {
        Order memory o = _overProducingOrder(21);
        uint256 makerA = tA.balanceOf(maker);

        (bool ok, bytes memory ret) = _netted(o, _planFor(1, address(aggSolver), AMOUNT_OUT, AMOUNT_WORD));
        assertTrue(ok, string(ret));
        assertEq(tA.balanceOf(maker), makerA + EXTRA, "maker refunded the over-production");
        assertEq(tA.balanceOf(address(router)), AMOUNT_IN, "the route swapped exactly owed");
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "maker paid");
        assertEq(tA.balanceOf(address(settlement)), 0, "pool flat");
        assertEq(tA.balanceOf(address(aggSolver)), 0, "no input residue on the solver");
        assertEq(tB.balanceOf(address(this)), AMOUNT_IN - AMOUNT_OUT, "spread to the caller");
    }

    /// S2 / schedule: a TAKE that produces the INPUT-LEG token flagged LATE fills —
    /// PULL draws the whole leg from the wallet first, the late TAKE credits it again
    /// and Phase 3 refunds the duplicate — but the maker's finite Permit3 token
    /// allowance is spent for a leg the TAKE was going to fund. Tokens round-trip;
    /// the allowance does not.
    function test_S2_lateTakeOnInputToken_burnsTheMakerAllowance() public {
        _makerApprove(address(settlement), address(tA), AMOUNT_IN); // exact, finite
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.TAKE,
            module: address(taker),
            amount: AMOUNT_IN,
            recipient: address(0),
            data: abi.encode(address(tA), AMOUNT_IN)
        });
        Order memory o = _order(23);
        o.items = PackedEncode.items(items);
        _authItems(o, items[0].data);
        uint256 makerA = tA.balanceOf(maker);
        (uint160 allowBefore,) = permit3.tokenAllowance(maker, address(settlement), address(tA));
        assertEq(allowBefore, AMOUNT_IN);

        bytes memory sig = _sign(o);
        (bool ok, bytes memory ret) = address(aggSolver).call(
            abi.encodeCall(
                IAggregatorItemFill.executeItemFill,
                (o, sig, AMOUNT_IN, _planFor(1, address(aggSolver), AMOUNT_OUT, AMOUNT_WORD), bytes(""), 1 << 0)
            )
        );
        assertTrue(ok, string(ret));
        assertEq(tA.balanceOf(maker), makerA, "wallet net zero: pulled 100, refunded 100");
        assertEq(tA.balanceOf(address(taker)), 1_000e18 - AMOUNT_IN, "the position still funded the fill");
        assertEq(tA.balanceOf(address(router)), AMOUNT_IN, "routed once");
        (uint160 allowAfter,) = permit3.tokenAllowance(maker, address(settlement), address(tA));
        assertEq(allowAfter, 0, "the token allowance is gone although the wallet paid nothing");
    }

    /// S2 / schedule, the maker's fix (ACCEPTED-PATTERNS-REVIEW B8, 2026-10-06): the
    /// same late-TAKE schedule against ORDERED still burns the allowance — ORDERED only
    /// orders the items among themselves — while CANONICAL makes `_stepPull` refuse a
    /// PULL ahead of the item group, so the schedule reverts and spends nothing. This
    /// is why the SDK defaults such orders to CANONICAL and the lens flags anything less.
    function test_S2_lateTakeOnInputToken_canonicalRefusesTheSchedule() public {
        _makerApprove(address(settlement), address(tA), AMOUNT_IN * 2); // exact for two fills
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.TAKE,
            module: address(taker),
            amount: AMOUNT_IN,
            recipient: address(0),
            data: abi.encode(address(tA), AMOUNT_IN)
        });

        // ORDERED: the late TAKE is still admitted and the leg is pulled first.
        Order memory o = _order(24);
        o.items = PackedEncode.items(items);
        o.timing = ItemPolicy.pack(o.timing, ItemPolicy.ORDERED);
        _authItems(o, items[0].data);
        (bool ok, bytes memory ret) = address(aggSolver).call(
            abi.encodeCall(
                IAggregatorItemFill.executeItemFill,
                (o, _sign(o), AMOUNT_IN, _planFor(1, address(aggSolver), AMOUNT_OUT, AMOUNT_WORD), bytes(""), 1 << 0)
            )
        );
        assertTrue(ok, string(ret));
        (uint160 allow,) = permit3.tokenAllowance(maker, address(settlement), address(tA));
        assertEq(allow, AMOUNT_IN, "ORDERED: one leg's allowance spent on a TAKE-funded leg");

        // CANONICAL: the same schedule reverts.
        o = _order(25);
        o.items = PackedEncode.items(items);
        o.timing = ItemPolicy.pack(o.timing, ItemPolicy.CANONICAL);
        _authItems(o, items[0].data);
        (ok, ret) = address(aggSolver).call(
            abi.encodeCall(
                IAggregatorItemFill.executeItemFill,
                (o, _sign(o), AMOUNT_IN, _planFor(1, address(aggSolver), AMOUNT_OUT, AMOUNT_WORD), bytes(""), 1 << 0)
            )
        );
        assertFalse(ok, "CANONICAL refuses PULL before the TAKE");
        assertEq(bytes4(ret), Base.ItemPolicyViolated.selector, "refused by _stepPull's CANONICAL gate");
        (allow,) = permit3.tokenAllowance(maker, address(settlement), address(tA));
        assertEq(allow, AMOUNT_IN, "nothing spent");
    }

    /// S2 / reference: the same order on the single-order path (an inventory filler)
    /// pays the maker the excess — which is the behaviour the netted path cannot match.
    function test_S2_singleOrderPath_overProducingTakeRefundsMaker() public {
        Order memory o = _overProducingOrder(22);
        bytes memory sig = _sign(o);
        address inv = address(0x1A1A);
        tB.mint(inv, AMOUNT_OUT);
        vm.startPrank(inv);
        tB.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(tB), type(uint160).max, 0);
        uint256 makerA = tA.balanceOf(maker);
        settlement.fill(o, sig, AMOUNT_IN);
        vm.stopPrank();
        assertEq(tA.balanceOf(maker), makerA + EXTRA, "maker refunded the over-production");
        assertEq(tA.balanceOf(inv), AMOUNT_IN, "filler got exactly owed");
    }
}
