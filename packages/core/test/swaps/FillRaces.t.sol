// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "@core/settlement/Base.sol";
import {OrderState} from "@core/settlement/OrderState.sol";
import {Proportional} from "@core/settlement/Proportional.sol";
import {Settlement, CallbackMode, Order} from "@core/settlement/Settlement.sol";
import {ISettlementCallback} from "@core/interfaces/ISettlementCallback.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

import {MockSettlementBase, MockERC20} from "../shared/MockSettlementBase.t.sol";
import {PackedEncode} from "../shared/PackedEncode.sol";

/// @dev A taker that fills through the TYPED callback and keeps a running ledger of
///      what the settler handed it on every fill. The point is the LEDGER: a single
///      fill proves the numbers are right once, a chain of partial fills proves they
///      compose — that nothing drifts, double-counts, or rounds away across a
///      sequence a racing filler could interleave.
contract LedgerTaker is ISettlementCallback {
    Settlement immutable SETTLEMENT;
    address immutable EXECUTOR;
    address immutable TOKEN_OUT;

    uint256[] public prevs;
    uint256[] public news;
    uint256[] public paidIn;
    uint256[] public owedOut;

    uint256 private _armed = 1;

    error OnlyExecutor();
    error NotArmed();

    constructor(Settlement s, address tokenOut) {
        SETTLEMENT = s;
        EXECUTOR = address(s.EXECUTOR());
        TOKEN_OUT = tokenOut;
    }

    function count() external view returns (uint256) {
        return prevs.length;
    }

    function fill(Order calldata o, bytes calldata sig, uint256 amount, CallbackMode mode) external {
        _armed = 2;
        SETTLEMENT.fillWithCallback(o, sig, amount, address(this), "", mode);
    }

    /// @inheritdoc ISettlementCallback
    function onSettlementFill(
        bytes32,
        uint256 prevFilled,
        uint256 newFilled,
        uint256,
        uint256[] calldata pricedIn,
        uint256[] calldata pricedOut,
        bytes calldata
    ) external {
        if (msg.sender != EXECUTOR) revert OnlyExecutor();
        if (_armed != 2) revert NotArmed();
        _armed = 1;

        prevs.push(prevFilled);
        news.push(newFilled);
        paidIn.push(pricedIn[0]);
        owedOut.push(pricedOut[0]);

        // Approve EXACTLY what was handed over — if any number is wrong the fill
        // cannot settle, so the ledger is checked by the chain, not by the test.
        SafeTransferLib.forceApprove(TOKEN_OUT, address(SETTLEMENT), pricedOut[0]);
    }
}

/// @dev Sends a token to an address from inside a callback — a stand-in for anything
///      that can credit an account while a fill is mid-flight (another filler's
///      settlement, an airdrop, a maker's own bot).
contract Crediter {
    function credit(address token, address to, uint256 amount) external {
        MockERC20(token).transfer(to, amount);
    }
}

/// @title FillRaces
/// @notice Racing fillers, and what a loser is owed.
///
///         An order is public and every filler sees the same one, so between the
///         moment a filler prices a fill and the moment it lands, the order's state
///         can have moved: someone else took it, took PART of it, or the maker's own
///         balance changed under a balance-relative leg. None of that may produce a
///         partially-settled fill, a double-charged maker, or an amount that drifts
///         from what was signed.
///
///         The single-fill correctness of each mechanism lives in its own file
///         ({FillUpTo}, {FillOnceNonce}, {ProportionalLeg}, {RoundingDirection}).
///         What is asserted here is COMPOSITION under contention: two fillers on one
///         order, a chain of partials that must sum to the signature, and a callback
///         that moves the very state the surrounding fill is pricing against.
contract FillRacesTest is MockSettlementBase {
    uint256 constant IN_ = 1_000e18;
    uint256 constant OUT_ = 2_000e18;

    address rival;
    uint256 rivalPk = 0xB1DDE2;

    function setUp() public override {
        super.setUp();
        rival = vm.addr(rivalPk);
        vm.label(rival, "rival");
    }

    /// @dev Fund and approve an arbitrary filler for `tB` output delivery.
    function _fundFiller(address who, uint256 amount) internal {
        tB.mint(who, amount);
        vm.startPrank(who);
        tB.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(tB), uint160(amount), 0);
        vm.stopPrank();
    }

    function _fundMaker(uint256 amount) internal {
        tA.mint(maker, amount);
        _makerApprove(address(settlement), address(tA), amount);
    }

    function _order(uint256 nonce) internal view returns (Order memory) {
        return _plainOrder(nonce, address(tA), address(tB), IN_, OUT_);
    }

    // ════════════════ Two fillers, one order ════════════════

    /// @dev The classic lost race: the order is gone by the time the second filler
    ///      lands. `fill` has no clamp — it is an exact request — so the loser gets a
    ///      clean {OverFill} and pays for nothing. ({FillUpTo} is the entry point that
    ///      clamps instead; `test_fillUpTo_clampsOnRace` is its half of this story.)
    function test_race_loserOnAnExhaustedOrder_revertsOverFill() public {
        _fundMaker(IN_);
        _fundFiller(solver, OUT_);
        _fundFiller(rival, OUT_);

        Order memory o = _order(1);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        settlement.fill(o, sig, IN_);

        vm.prank(rival);
        vm.expectRevert(OrderState.OverFill.selector);
        settlement.fill(o, sig, 1);

        assertEq(tB.balanceOf(rival), OUT_, "the loser spent nothing");
        assertEq(tA.balanceOf(rival), 0, "and received nothing");
    }

    /// @dev The subtler loss: the order is only PARTLY gone, and the loser asks for
    ///      more than is left. An exact-request `fill` must refuse rather than
    ///      silently settle the remainder at the price quoted for a bigger slice.
    function test_race_loserOverRequestingTheRemainder_revertsOverFill() public {
        _fundMaker(IN_);
        _fundFiller(solver, OUT_);
        _fundFiller(rival, OUT_);

        Order memory o = _order(1);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        settlement.fill(o, sig, (IN_ * 60) / 100);

        vm.prank(rival);
        vm.expectRevert(OrderState.OverFill.selector);
        settlement.fill(o, sig, (IN_ * 60) / 100);

        assertEq(lens.remaining(o), (IN_ * 40) / 100, "the remainder is untouched and still fillable");
    }

    /// @dev And when both fillers size correctly, the order closes EXACTLY. The two
    ///      slices must reconstruct the signature — the maker pays its signed input
    ///      once and receives its signed output once — with nothing left behind in
    ///      Settlement for anyone to sweep.
    function test_race_twoPartialsReconstructTheSignedAmounts() public {
        _fundMaker(IN_);
        _fundFiller(solver, OUT_);
        _fundFiller(rival, OUT_);

        Order memory o = _order(1);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        settlement.fill(o, sig, (IN_ * 60) / 100);
        vm.prank(rival);
        settlement.fill(o, sig, (IN_ * 40) / 100);

        assertEq(tA.balanceOf(maker), 0, "maker paid its input exactly once");
        assertEq(tB.balanceOf(maker), OUT_, "and received its output exactly once");
        assertEq(tA.balanceOf(solver), (IN_ * 60) / 100, "winner's share");
        assertEq(tA.balanceOf(rival), (IN_ * 40) / 100, "runner-up's share");
        assertEq(tA.balanceOf(address(settlement)), 0, "nothing stranded in the settlement");
        assertEq(tB.balanceOf(address(settlement)), 0, "on either side");
        assertEq(lens.remaining(o), 0, "order exhausted");
    }

    // ════════════════ A chain of partials, through the typed callback ════════════════

    /// @dev THE COMPOSITION TEST for `pricedIn`/`pricedOut`. Three partial fills, each
    ///      priced by the settler and handed to the taker, which approves EXACTLY what
    ///      it was told. The splits are deliberately indivisible (333/333/334 of
    ///      1,000) so every slice rounds, and the assertions are on the SUMS:
    ///
    ///        • the counters chain with no gap and no overlap — one filler's `newFilled`
    ///          is the next one's `prevFilled`, which is what a racing filler relies on
    ///          to price its own slice;
    ///        • the input slices sum to EXACTLY the signed input. Inputs are cumulative
    ///          floor slices, so this is the exact-input guarantee holding across a
    ///          sequence, not just one fill;
    ///        • the output slices sum to AT LEAST the signed output. Outputs round per
    ///          fill in the maker's favour, so repeated partials may overpay by dust —
    ///          never underpay. Asserting `>=` rather than `==` is the honest bound.
    function test_race_sequentialPartials_chainAndSumToTheSignature() public {
        _fundMaker(IN_);
        LedgerTaker taker = new LedgerTaker(settlement, address(tB));
        tB.mint(address(taker), OUT_ * 2);
        vm.prank(address(taker));
        tB.approve(address(permit3), type(uint256).max);

        Order memory o = _order(1);
        bytes memory sig = _sign(o);

        uint256[3] memory slices = [IN_ / 3, IN_ / 3, IN_ - 2 * (IN_ / 3)];
        for (uint256 i; i < 3; ++i) {
            taker.fill(o, sig, slices[i], CallbackMode.PostInputsTyped);
        }

        assertEq(taker.count(), 3, "three fills, three handovers");

        uint256 runningIn;
        uint256 runningOut;
        uint256 expectedPrev;
        for (uint256 i; i < 3; ++i) {
            assertEq(taker.prevs(i), expectedPrev, "prevFilled continues where the last fill stopped");
            assertEq(taker.news(i), expectedPrev + slices[i], "and advances by exactly this slice");
            expectedPrev = taker.news(i);
            runningIn += taker.paidIn(i);
            runningOut += taker.owedOut(i);
        }

        assertEq(expectedPrev, IN_, "the chain closes the order");
        assertEq(runningIn, IN_, "input slices sum to EXACTLY the signed input");
        assertGe(runningOut, OUT_, "output slices never sum below the signed output");

        // And the ledger is not a story the taker told itself — it matches the chain.
        assertEq(tA.balanceOf(address(taker)), runningIn, "taker was paid what it was promised");
        assertEq(tB.balanceOf(maker), runningOut, "maker received what the taker was charged");
        assertEq(tA.balanceOf(maker), 0, "maker's input fully spent");
    }

    // ════════════════ A callback racing the fill's own pricing ════════════════

    /// @dev THE PINNED-ANCHOR RACE. A balance-relative ("sell 100% of my balance")
    ///      leg resolves against the maker's LIVE balance — but only once, at open,
    ///      before any funds move. Here the callback credits the maker mid-fill,
    ///      exactly the window {Pricing.inputOwed} refuses to re-read in:
    ///      `PreDelivery` runs the callback BEFORE the input is pulled, so a settler
    ///      that re-read the balance would charge the maker for tokens that arrived
    ///      after it agreed the price.
    ///
    ///      The maker must be charged the anchor pinned at open, and must KEEP the
    ///      windfall.
    function test_race_callbackCreditsTheMakerMidFill_chargesThePinnedAnchor() public {
        uint256 held = 500e18;
        uint256 windfall = 250e18;
        // The maker holds EXACTLY the anchor at open — the windfall arrives later,
        // from the callback. The allowance is deliberately generous, so nothing but
        // the pinned anchor is what bounds the pull.
        tA.mint(maker, held);
        _makerApprove(address(settlement), address(tA), held * 10);
        _fundFiller(solver, OUT_);

        Crediter crediter = new Crediter();
        tA.mint(address(crediter), windfall);

        Order memory o = _plainOrder(1, address(tA), address(tB), 1, OUT_);
        o.legsIn = PackedEncode.setLegInStart(o.legsIn, 0, Proportional.encode(10_000)); // 100% of balance
        o.legsIn = PackedEncode.setLegInEnd(o.legsIn, 0, held * 10); // solver's ceiling
        bytes memory sig = _sign(o);

        bytes memory cb = abi.encodeCall(Crediter.credit, (address(tA), maker, windfall));

        vm.prank(solver);
        settlement.fillWithCallback(o, sig, held, address(crediter), cb, CallbackMode.PreDelivery);

        assertEq(tA.balanceOf(solver), held, "solver was paid the anchor resolved at OPEN, not the live balance");
        assertEq(tA.balanceOf(maker), windfall, "the maker keeps what arrived mid-fill");
        assertEq(tB.balanceOf(maker), OUT_, "and is paid for the anchor it actually sold");
    }

    /// @dev A shared-allowance race across two DIFFERENT orders from one maker. The
    ///      maker signed both but approved only enough for one, so whichever fill
    ///      lands first consumes the authority and the other is refused outright —
    ///      no partial settlement, and the loser's inventory is untouched.
    function test_race_sharedAllowanceExhaustedByTheFirstFill() public {
        tA.mint(maker, IN_ * 2);
        _makerApprove(address(settlement), address(tA), IN_); // enough for ONE order
        _fundFiller(solver, OUT_);
        _fundFiller(rival, OUT_);

        Order memory first = _order(1);
        Order memory second = _order(2);
        bytes memory sigA = _sign(first);
        bytes memory sigB = _sign(second);

        vm.prank(solver);
        settlement.fill(first, sigA, IN_);

        vm.prank(rival);
        vm.expectRevert();
        settlement.fill(second, sigB, IN_);

        assertEq(tB.balanceOf(rival), OUT_, "the loser delivered nothing");
        assertEq(tA.balanceOf(rival), 0, "and was paid nothing");
        assertEq(tB.balanceOf(maker), OUT_, "the maker was paid for exactly one order");
        assertEq(lens.remaining(second), IN_, "and the second order is still open, not half-consumed");
    }
}
