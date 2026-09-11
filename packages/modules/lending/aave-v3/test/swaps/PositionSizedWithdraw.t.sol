// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {DustHandler} from "@lib/DustHandler.sol";

import {Order, Item, ItemOp, MatchPlan} from "@core/settlement/Settlement.sol";
import {PositionFillModule} from "@lib/PositionFillModule.sol";

import {AaveModulesBase} from "../shared/AaveModulesBase.t.sol";

/// @dev POSITION-SIZED EXIT — the fill delta is resolved from the maker's live
/// aToken balance, so the interest accrued since signing is SOLD at the signed
/// rate instead of coming back as unconverted dust.
///
/// Contrast with {WithdrawAndSwapTest}'s `BalanceMode.Full` case, which is the
/// mechanism this replaces: there the maker signs `wethIn`, the solver buys
/// exactly `wethIn`, and the excess is pushed back to the maker's wallet as raw
/// WETH. Here the maker signs a CAP, and everything under it is priced.
///
/// This is also the first test in the tree that combines a `fillModule` with
/// EXECUTING items — `FillModule.t.sol` only ever feeds an item to the lens.
contract PositionSizedWithdrawTest is AaveModulesBase {
    PositionFillModule internal fillModule;

    /// @dev The maker's ceiling on the exit, and — per {PositionFillBase} — the
    /// single number that must appear as `fillTotal`, `legsIn[0].start` and
    /// `items[0].amount` for the proration to be exact.
    uint256 internal constant CAP = 1.5 ether;
    /// @dev What the whole cap is worth. Anything below it is paid pro rata.
    uint256 internal constant QUOTE_AT_CAP = 3_000e6;

    function setUp() public override {
        super.setUp();
        fillModule = new PositionFillModule();
        vm.label(address(fillModule), "positionFillModule");
    }

    // ──────────────────── Order construction ────────────────────

    function _positionOrder(uint256 nonce) internal view returns (Order memory) {
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.TAKE,
            module: address(withdrawModule),
            amount: CAP,
            recipient: address(0), //           default = Settlement, for the tokenIn payout
            // No BalanceMode word: the slice the module receives already IS the
            // live position, so `Exact` withdraws it exactly.
            data: abi.encode(AAVE_POOL, WETH, aWETH)
        });
        return _positionOrderWith(nonce, address(fillModule), CAP, CAP, items);
    }

    /// @dev Every knob the shape guards police, in one place, so the negative
    /// tests can bend exactly one at a time.
    function _positionOrderWith(
        uint256 nonce,
        address fm,
        uint256 fillTotal,
        uint256 anchorIn,
        Item[] memory items
    )
        internal
        view
        returns (Order memory order)
    {
        order = _order(maker, nonce, WETH, USDC, anchorIn, QUOTE_AT_CAP, items);
        order.fillModule = fm;
        order.fillTotal = fillTotal;
    }

    function _approve(uint256 cap, bytes memory takerData) internal {
        _approveMakerWithdrawSide(cap, keccak256(takerData), takerData);
    }

    // ──────────────────── The property ────────────────────

    /// @dev The whole point: a position BELOW the cap is sold in full, and the
    /// maker is paid pro rata for it — including the part they could not have
    /// known about at signing time. Nothing is left in the position, and nothing
    /// comes back to the wallet unconverted.
    function test_positionSized_sellsTheAccruedInterestToo() public {
        uint256 position = 1.3 ether; // strictly between 0 and CAP
        _seedAWethPosition(position);
        deal(USDC, solver, QUOTE_AT_CAP);

        bytes memory takerData = abi.encode(AAVE_POOL, WETH, aWETH);
        _approve(CAP, takerData);
        _approveSolverSide(QUOTE_AT_CAP, USDC);

        // Resolve the position the way the module will, so the expectations are
        // computed from the same number the fill uses (aTokens accrue per block).
        uint256 live = IERC20(aWETH).balanceOf(maker);
        uint256 expectedQuote = (live * QUOTE_AT_CAP + CAP - 1) / CAP; // ceilDiv, as Pricing does

        Order memory order = _positionOrder(1);
        bytes memory sig = _sign(order);

        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);

        vm.prank(solver);
        // `fillAmount` is ignored by the module — the position sizes the fill.
        uint256 paid = settlement.fill(order, sig, CAP)[0];

        assertEq(paid, expectedQuote, "maker paid pro rata for the LIVE position");
        assertEq(IERC20(USDC).balanceOf(maker) - makerUsdcBefore, expectedQuote, "maker received it");
        assertEq(IERC20(WETH).balanceOf(solver), live, "solver bought the whole live position");

        // The accrued excess was SOLD, not returned: the maker ends with no loose
        // WETH at all. This is the assertion that fails under `BalanceMode.Full`.
        assertEq(IERC20(WETH).balanceOf(maker), 0, "no unconverted dust in the wallet");
        assertLe(IERC20(aWETH).balanceOf(maker), 1, "position fully exited");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(aWETH).balanceOf(address(withdrawModule)), 0, "module aWETH drained");
    }

    /// @dev The `BalanceMode.Full` baseline, asserted as the thing being fixed:
    /// the same economics signed the old way leave the excess sitting in the
    /// maker's wallet as raw WETH.
    function test_baseline_fullMode_leavesTheExcessUnconverted() public {
        // SAME position and SAME rate as the test above (3000 USDC per 1.5 WETH =
        // 2000/WETH), signed the old way: an absolute 1.0 WETH with `Full` mode to
        // close out the rest. The contrast is then purely mechanical.
        uint256 signedAmount = 1 ether;
        uint256 position = 1.3 ether;
        uint256 signedQuote = (signedAmount * QUOTE_AT_CAP) / CAP; // 2000 USDC — same rate

        _seedAWethPosition(position);
        deal(USDC, solver, signedQuote);

        bytes memory takerData = abi.encode(AAVE_POOL, WETH, aWETH, DustHandler.encodeMode(DustHandler.BalanceMode.Full), signedAmount);
        _approve(signedAmount, takerData);
        _approveSolverSide(signedQuote, USDC);

        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.TAKE,
            module: address(withdrawModule),
            amount: signedAmount,
            recipient: address(0),
            data: takerData
        });
        Order memory order = _order(maker, 2, WETH, USDC, signedAmount, signedQuote, items);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, signedAmount);

        // Position fully exited either way — but here the 0.3 WETH the maker could
        // not have known about at signing comes back as RAW WETH in the wallet,
        // and they are paid only for the 1.0 they signed. The test above sells the
        // same 0.3 for 600 more USDC at the same rate.
        assertApproxEqAbs(IERC20(WETH).balanceOf(maker), position - signedAmount, 1e12, "excess returned UNCONVERTED");
        assertEq(IERC20(USDC).balanceOf(maker), signedQuote, "maker paid only for the signed part");
        assertLe(IERC20(aWETH).balanceOf(maker), 1, "position fully exited (same as position-sized)");
    }

    /// @dev A position ABOVE the cap sells exactly the cap — identical to the
    /// absolute order the maker would otherwise have signed, never worse. This is
    /// the reason the cap is mandatory: on Aave anyone may `supply(..., onBehalfOf
    /// = maker)`, so an uncapped resolve would be a standing offer on a position
    /// a third party controls the size of.
    function test_positionAboveCap_clampsToTheCap() public {
        _seedAWethPosition(CAP + 2 ether);
        deal(USDC, solver, QUOTE_AT_CAP);

        bytes memory takerData = abi.encode(AAVE_POOL, WETH, aWETH);
        _approve(CAP, takerData);
        _approveSolverSide(QUOTE_AT_CAP, USDC);

        uint256 aBefore = IERC20(aWETH).balanceOf(maker);

        Order memory order = _positionOrder(3);
        bytes memory sig = _sign(order); // hoisted: `_sign` consumes a pending `vm.prank`
        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, CAP)[0];

        assertEq(paid, QUOTE_AT_CAP, "full output at the cap");
        assertEq(IERC20(WETH).balanceOf(solver), CAP, "solver bought exactly the cap");
        assertApproxEqAbs(aBefore - IERC20(aWETH).balanceOf(maker), CAP, 2, "the rest of the position is untouched");
    }

    // ──────────────────── Guards ────────────────────

    /// @dev One-shot. The first fill is a PARTIAL one whenever the position is
    /// below the cap, so without this the order would stay open at the signed
    /// rate and a later re-supply would be sellable at the old price.
    function test_secondFill_reverts_evenThoughTheOrderIsNotFull() public {
        _seedAWethPosition(0.5 ether);
        deal(USDC, solver, QUOTE_AT_CAP * 2);

        bytes memory takerData = abi.encode(AAVE_POOL, WETH, aWETH);
        _approve(CAP, takerData);
        _approveSolverSide(QUOTE_AT_CAP * 2, USDC);

        Order memory order = _positionOrder(4);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, CAP);

        // The order is only 1/3 filled, so the core would happily take more.
        _seedAWethPosition(0.5 ether);
        vm.prank(solver);
        vm.expectRevert(PositionFillModule.AlreadyFilled.selector);
        settlement.fill(order, sig, CAP);
    }

    /// @dev An exit order with nothing to exit fails closed rather than filling
    /// for zero: `delta == 0` is rejected by the core.
    function test_emptyPosition_reverts() public {
        deal(USDC, solver, QUOTE_AT_CAP);
        bytes memory takerData = abi.encode(AAVE_POOL, WETH, aWETH);
        _approve(CAP, takerData);
        _approveSolverSide(QUOTE_AT_CAP, USDC);

        Order memory order = _positionOrder(5);
        bytes memory sig = _sign(order);
        vm.prank(solver);
        vm.expectRevert(); // ZeroFill, raised by the settlement on delta == 0
        settlement.fill(order, sig, CAP);
    }

    /// @dev The "three amounts" rule. `item.amount != fillTotal` prorates
    /// inexactly, so the shape is refused at resolve time rather than producing a
    /// fill whose item slice and leg charge disagree.
    function test_itemAmountNotDenominator_reverts() public {
        _seedAWethPosition(1 ether);
        bytes memory takerData = abi.encode(AAVE_POOL, WETH, aWETH);
        _approve(CAP, takerData);
        _approveSolverSide(QUOTE_AT_CAP, USDC);

        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.TAKE,
            module: address(withdrawModule),
            amount: CAP - 1, //                 ← the one bent knob
            recipient: address(0),
            data: takerData
        });
        Order memory order = _positionOrderWith(6, address(fillModule), CAP, CAP, items);

        bytes memory sig = _sign(order);
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(PositionFillModule.DenominatorMismatch.selector, CAP - 1, CAP));
        settlement.fill(order, sig, CAP);
    }

    /// @dev Same rule on the other side: the input anchor must be the denominator.
    function test_anchorNotDenominator_reverts() public {
        _seedAWethPosition(1 ether);
        bytes memory takerData = abi.encode(AAVE_POOL, WETH, aWETH);
        _approve(CAP, takerData);
        _approveSolverSide(QUOTE_AT_CAP, USDC);

        Item[] memory items = new Item[](1);
        items[0] =
            Item({op: ItemOp.TAKE, module: address(withdrawModule), amount: CAP, recipient: address(0), data: takerData});
        Order memory order = _positionOrderWith(7, address(fillModule), CAP, CAP - 1, items);

        bytes memory sig = _sign(order);
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(PositionFillModule.DenominatorMismatch.selector, CAP - 1, CAP));
        settlement.fill(order, sig, CAP);
    }

    /// @dev The module asked IS the module that executes item 0, so there is no
    /// address to mis-configure. What still has to hold is that the position it
    /// reports is denominated in the token being sold — the borrow module reports
    /// no position at all, so the call fails closed.
    function test_wrongItemModule_reverts() public {
        _seedAWethPosition(1 ether);
        bytes memory takerData = abi.encode(AAVE_POOL, WETH, aWETH);
        _approve(CAP, takerData);
        _approveSolverSide(QUOTE_AT_CAP, USDC);

        Item[] memory items = new Item[](1);
        items[0] =
            Item({op: ItemOp.TAKE, module: address(creditModule), amount: CAP, recipient: address(0), data: takerData});
        Order memory order = _positionOrderWith(8, address(fillModule), CAP, CAP, items);

        bytes memory sig = _sign(order);
        vm.prank(solver);
        vm.expectRevert(); // borrow module implements no `positionOf` — STATICCALL reverts
        settlement.fill(order, sig, CAP);
    }

    /// @dev THE FILLER'S RECIPE, end to end, with no knowledge that this order is
    /// position-sized at all: probe the lens with `order.fillTotal` (a universal
    /// probe — it can never bind, since the core caps every module order at
    /// `filled + delta <= fillTotal`), then submit the `delta` it returns. That
    /// second step is also the staleness bound, for free.
    function test_fillerRecipe_probeWithFillTotal_thenSubmitTheDelta() public {
        _seedAWethPosition(1.3 ether);
        deal(USDC, solver, QUOTE_AT_CAP);

        bytes memory takerData = abi.encode(AAVE_POOL, WETH, aWETH);
        _approve(CAP, takerData);
        _approveSolverSide(QUOTE_AT_CAP, USDC);

        Order memory order = _positionOrder(13);
        bytes memory sig = _sign(order);

        // Step 1 — probe. The filler passes the signed denominator, not a guess.
        (uint256 delta, uint256[] memory received, uint256[] memory paid) =
            lens.previewFill(order, order.fillTotal, solver, "");
        assertEq(delta, IERC20(aWETH).balanceOf(maker), "probe resolves the live position");

        // Step 2 — submit the quoted size.
        vm.prank(solver);
        uint256 actuallyPaid = settlement.fill(order, sig, delta)[0];

        assertEq(actuallyPaid, paid[0], "preview priced the fill exactly");
        assertEq(IERC20(WETH).balanceOf(solver), received[0], "and sized it exactly");
        assertLe(IERC20(aWETH).balanceOf(maker), 1, "position fully exited");
    }

    /// @dev The optional classification seam, for fillers that want to render the
    /// order or decline one-shot shapes rather than just fill it.
    function test_describeFill_classifiesWithoutAnAddressList() public view {
        (bytes32 kind, bool dynamicSize, bool oneShot) = fillModule.describeFill();
        assertEq(kind, bytes32("POSITION_SIZED"), "self-describes");
        assertTrue(dynamicSize, "size moves with the live position");
        assertTrue(oneShot, "a fill closes the order even when it advanced less than the cap");
    }

    /// @dev THE SOLVER'S STALENESS BOUND. A fill-module order bypasses `fillUpTo`'s
    /// clamp, so without honouring `fillAmount` as a ceiling a solver who quoted
    /// against a smaller position would be silently made to buy whatever it grew to.
    /// It reverts rather than filling small: the order is one-shot, so a small fill
    /// would leave the maker partially exited with their exit order spent.
    function test_positionGrewPastTheQuote_reverts() public {
        uint256 quoted = 1.0 ether;
        _seedAWethPosition(1.3 ether); //   grew past what the solver priced
        deal(USDC, solver, QUOTE_AT_CAP);

        bytes memory takerData = abi.encode(AAVE_POOL, WETH, aWETH);
        _approve(CAP, takerData);
        _approveSolverSide(QUOTE_AT_CAP, USDC);

        Order memory order = _positionOrder(11);
        bytes memory sig = _sign(order);
        uint256 live = IERC20(aWETH).balanceOf(maker);

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(PositionFillModule.PositionExceedsQuote.selector, live, quoted));
        settlement.fill(order, sig, quoted);

        // ...and the same order fills cleanly once the solver offers the cap.
        vm.prank(solver);
        settlement.fill(order, sig, CAP);
        assertEq(IERC20(WETH).balanceOf(solver), live, "solver bought the position it re-quoted");
    }

    /// @dev The maker's matching FLOOR needs no machinery in the fill module —
    /// `minFillAnchor` is checked against the resolved delta by the core. Without
    /// it a filler could burn the maker's one-shot exit on a dust position.
    function test_minFillAnchor_floorsTheResolvedPosition() public {
        _seedAWethPosition(0.01 ether); //  well below the floor
        deal(USDC, solver, QUOTE_AT_CAP);

        bytes memory takerData = abi.encode(AAVE_POOL, WETH, aWETH);
        _approve(CAP, takerData);
        _approveSolverSide(QUOTE_AT_CAP, USDC);

        Order memory order = _positionOrder(12);
        order.minFillAnchor = 1 ether;
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(); // FillTooSmall, raised by the core on the resolved delta
        settlement.fill(order, sig, CAP);
    }

    // ──────────────────── The netted path ────────────────────

    /// @dev THE STALENESS BOUND ON `matchSettle`, which is where it matters most.
    ///
    /// A netted plan is balanced against a specific chain state, and a position-sized
    /// order is the one shape whose size can move WITHOUT `filled[hash]` moving — so
    /// a `MatchRaceGuard`-style equality check on `filled` is structurally blind to
    /// it. The per-order `fillAmounts[i]` is the only bound the solver has, and it
    /// must fire in PHASE 1, before any token moves: `_matchOpenAll` resolves every
    /// order's delta before the schedule runs.
    ///
    /// This is why the filler recipe's two calls take DIFFERENT numbers — probe with
    /// `fillTotal`, submit the quoted `delta`. Passing `fillTotal` here would let the
    /// plan proceed on a size the solver never simulated and fail late instead.
    function test_matchSettle_positionGrewPastTheQuote_revertsAtOpen() public {
        uint256 quoted = 1.0 ether;
        _seedAWethPosition(1.3 ether); //  drifted past what the solver priced
        deal(USDC, solver, QUOTE_AT_CAP);

        bytes memory takerData = abi.encode(AAVE_POOL, WETH, aWETH);
        _approve(CAP, takerData);
        _approveSolverSide(QUOTE_AT_CAP, USDC);

        Order memory order = _positionOrder(20);
        uint256 live = IERC20(aWETH).balanceOf(maker);

        Order[] memory orders = new Order[](1);
        orders[0] = order;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(order);
        uint256[] memory fills = new uint256[](1);
        fills[0] = quoted; //              the solver's own bound
        MatchPlan memory plan = MatchPlan({
            orders: orders,
            sigs: sigs,
            fillAmounts: fills,
            takerDatas: new bytes[](1),
            schedule: new uint256[](0), //  never reached — open reverts first
            callTargets: new address[](0),
            callDatas: new bytes[](0),
            profitRecipient: solver
        });

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(PositionFillModule.PositionExceedsQuote.selector, live, quoted));
        settlement.matchSettle(plan);

        // Nothing moved: the failure is at open, not mid-plan.
        assertEq(IERC20(aWETH).balanceOf(maker), live, "position untouched");
        assertEq(IERC20(USDC).balanceOf(solver), QUOTE_AT_CAP, "solver kept its inventory");
        assertEq(settlement.filled(_hashOrder(order)), 0, "order unfilled");
    }

    /// @dev TWO ORDERS, ONE POSITION — the case a per-order preview cannot model.
    /// `matchSettle` resolves EVERY order's delta in phase 1, before any withdraw
    /// runs, so both orders resolve against the same live balance and the plan tries
    /// to withdraw it twice. The one-shot guard does not help: it keys on the order
    /// hash, and these are two different orders.
    ///
    /// It must fail closed. It does — but only because the venue's own aToken
    /// transfer reverts on a drained balance, not because the settler noticed. That
    /// is worth pinning precisely so the reason stays visible.
    function test_matchSettle_twoOrdersOneposition_failsClosed() public {
        _seedAWethPosition(1.3 ether);
        deal(USDC, solver, QUOTE_AT_CAP * 2);

        bytes memory takerData = abi.encode(AAVE_POOL, WETH, aWETH);
        _approve(CAP, takerData);
        _approveSolverSide(QUOTE_AT_CAP * 2, USDC);

        Order memory a = _positionOrder(21);
        Order memory b = _positionOrder(22); // same maker, same position, new nonce
        uint256 live = IERC20(aWETH).balanceOf(maker);

        Order[] memory orders = new Order[](2);
        (orders[0], orders[1]) = (a, b);
        bytes[] memory sigs = new bytes[](2);
        (sigs[0], sigs[1]) = (_sign(a), _sign(b));
        uint256[] memory fills = new uint256[](2);
        (fills[0], fills[1]) = (live, live);
        MatchPlan memory plan = MatchPlan({
            orders: orders,
            sigs: sigs,
            fillAmounts: fills,
            takerDatas: new bytes[](2),
            schedule: new uint256[](0),
            callTargets: new address[](0),
            callDatas: new bytes[](0),
            profitRecipient: solver
        });

        vm.prank(solver);
        vm.expectRevert(); // both resolve to `live`; the plan cannot fund both
        settlement.matchSettle(plan);

        assertEq(IERC20(aWETH).balanceOf(maker), live, "position untouched");
    }

    /// @dev AUDIT REGRESSION — the anchor leg must be FIXED. `_positionFor` asserts
    /// `legsIn[0].start == fillTotal` to make the pro-rate exact, but that argument
    /// only describes {Pricing.inputOwed}'s FIXED branch. With `end != 0` the
    /// auctioned branch charges `delta · inTick(start,end,bump) / anchor`, which
    /// EXCEEDS the position the item withdrew — and the core pulls the difference
    /// from the maker's wallet, in an amount the FILLER picks by choosing the
    /// inclusion block. Refused now.
    function test_risingAnchorLeg_reverts() public {
        _seedAWethPosition(1.3 ether);
        bytes memory takerData = abi.encode(AAVE_POOL, WETH, aWETH);
        _approve(CAP, takerData);
        _approveSolverSide(QUOTE_AT_CAP, USDC);

        Item[] memory items = new Item[](1);
        items[0] =
            Item({op: ItemOp.TAKE, module: address(withdrawModule), amount: CAP, recipient: address(0), data: takerData});
        Order memory order = _positionOrderWith(30, address(fillModule), CAP, CAP, items);
        // A RISING input leg: legally signable on a SELL, and it breaks exactness.
        order.legsIn = _legsIn1Rising(WETH, CAP, CAP + 0.1 ether);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(PositionFillModule.DenominatorMismatch.selector, uint256(0.1 ether + CAP), 0)
        );
        settlement.fill(order, sig, CAP);
    }

    /// @dev AUDIT REGRESSION — a CODE-LESS item module must be SKIPPED, not revert
    /// the resolve. try/catch cannot catch this: a STATICCALL to a code-less address
    /// SUCCEEDS with empty returndata and solc decodes the tuple in the caller's
    /// frame, so the decode failure escapes `catch`. With an explicit
    /// `code.length == 0` skip, the order fails with the honest `NoPositionItem`.
    function test_codelessItemModule_skipsRatherThanBricking() public {
        _seedAWethPosition(1.3 ether);
        _approveSolverSide(QUOTE_AT_CAP, USDC);

        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.TAKE,
            module: address(0xDEAD), //          no code
            amount: CAP,
            recipient: address(0),
            data: abi.encode(AAVE_POOL, WETH, aWETH)
        });
        Order memory order = _positionOrderWith(31, address(fillModule), CAP, CAP, items);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(PositionFillModule.NoPositionItem.selector);
        settlement.fill(order, sig, CAP);
    }

    /// @dev THE UNITS CHECK. The module reports what token its position is
    /// denominated in, and it must be the token being sold — otherwise the fill
    /// numerator and the leg it scales are denominated differently, and the maker
    /// would be paid a WETH-sized fraction for a USDC-sized position. Signing the
    /// anchor leg in the wrong token is the way that happens by accident.
    function test_positionAssetMismatch_reverts() public {
        _seedAWethPosition(1 ether);
        bytes memory takerData = abi.encode(AAVE_POOL, WETH, aWETH);
        _approve(CAP, takerData);
        _approveSolverSide(QUOTE_AT_CAP, USDC);

        Item[] memory items = new Item[](1);
        items[0] =
            Item({op: ItemOp.TAKE, module: address(withdrawModule), amount: CAP, recipient: address(0), data: takerData});
        // Everything is consistent EXCEPT the anchor leg's token: USDC, while the
        // module reports its position in WETH.
        Order memory order = _order(maker, 10, USDC, USDC, CAP, QUOTE_AT_CAP, items);
        order.fillModule = address(fillModule);
        order.fillTotal = CAP;
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(PositionFillModule.PositionAssetMismatch.selector, WETH, USDC));
        settlement.fill(order, sig, CAP);
    }

    /// @dev `fillTotal == 0` is the unset field, so it must not mean "uncapped".
    function test_noDenominator_reverts() public {
        _seedAWethPosition(1 ether);
        bytes memory takerData = abi.encode(AAVE_POOL, WETH, aWETH);
        _approve(CAP, takerData);
        _approveSolverSide(QUOTE_AT_CAP, USDC);

        Item[] memory items = new Item[](1);
        items[0] =
            Item({op: ItemOp.TAKE, module: address(withdrawModule), amount: CAP, recipient: address(0), data: takerData});
        Order memory order = _positionOrderWith(9, address(fillModule), 0, CAP, items);

        bytes memory sig = _sign(order);
        vm.prank(solver);
        vm.expectRevert(PositionFillModule.NoDenominator.selector);
        settlement.fill(order, sig, CAP);
    }
}
