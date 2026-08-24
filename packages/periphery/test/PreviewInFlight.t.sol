// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Order, CallbackMode} from "@core/settlement/Settlement.sol";
import {Settlement} from "@core/settlement/Settlement.sol";
import {SettlementLens} from "@periphery/SettlementLens.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {Proportional} from "@core/settlement/Proportional.sol";

import {MockSettlementBase} from "@coretest/shared/MockSettlementBase.t.sol";

/// @dev A taker that learns the fill's numbers the EASY way: one lens call from
///      inside the callback. It carries no order in its callbackData, imports no
///      pricing library, and re-derives nothing.
contract LensTaker {
    Settlement public immutable SETTLEMENT;
    SettlementLens public immutable LENS;
    address public immutable EXECUTOR;

    uint256 private _active = 1;
    uint256 public quotedOut;

    error OnlyExecutor();
    error NotArmed();

    constructor(address settlement, address lens) {
        SETTLEMENT = Settlement(payable(settlement));
        LENS = SettlementLens(lens);
        EXECUTOR = address(Settlement(payable(settlement)).EXECUTOR());
    }

    function fill(Order calldata order, bytes calldata sig, uint256 fillAmount, address tokenOut) external {
        // Capture BEFORE the fill — `prevFilled` is destroyed by it, and a
        // proportional anchor moves with the maker's balance.
        (, uint256 prevFilled, uint256 anchor) = LENS.fillState(order);
        _active = 2;
        SETTLEMENT.fillWithCallback(
            order,
            sig,
            fillAmount,
            address(this),
            // NOTE what is NOT here: the fillAmount. The delta is discovered.
            abi.encodeCall(this.onFill, (order, prevFilled, anchor, tokenOut)),
            CallbackMode.PreDelivery
        );
    }

    function onFill(Order calldata order, uint256 prevFilled, uint256 anchor, address tokenOut) external {
        if (msg.sender != EXECUTOR) revert OnlyExecutor();
        if (_active != 2) revert NotArmed();
        _active = 1;

        (, uint256[] memory paid) = LENS.previewFillInFlight(order, prevFilled, anchor, address(this), "");
        quotedOut = paid[0];
        // Approve EXACTLY the quote: the fill can only settle if the lens told
        // the truth about what Pricing is about to demand.
        SafeTransferLib.forceApprove(tokenOut, address(SETTLEMENT), quotedOut);
    }
}

/// @title PreviewInFlight
/// @notice {SettlementLens.previewFillInFlight} — the taker-side answer to a
///         callback that is handed no amounts. `previewFill` cannot serve this:
///         `_openFill` has already advanced `filled`, so the ordinary preview
///         prices the NEXT fill. These pin that the in-flight variant returns
///         exactly what the settler then demands, on the cases where guessing
///         would be wrong.
contract PreviewInFlightTest is MockSettlementBase {
    uint256 constant SELL_IN = 1_000e18;
    uint256 constant OUT_START = 2_000e18;
    uint256 constant OUT_END = 1_000e18;
    uint32 constant DURATION = 1_000;

    LensTaker taker;

    function setUp() public override {
        super.setUp();
        taker = new LensTaker(address(settlement), address(lens));
        tA.mint(maker, 10_000e18);
        _makerApprove(address(settlement), address(tA), type(uint160).max);
        tB.mint(address(taker), 10_000e18);
    }

    function _decaying(uint256 nonce) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), SELL_IN, OUT_START);
        o.legsOut = PackedEncode.oneLegOut(address(tB), OUT_START, OUT_END, address(0));
        _setDecayStart(o, block.timestamp);
        _setDecayDuration(o, DURATION);
    }

    function test_inFlight_matchesTheDecayedPrice() public {
        Order memory o = _decaying(1);
        bytes memory sig = _sign(o);
        vm.warp(block.timestamp + DURATION / 4);

        uint256 before_ = tB.balanceOf(maker);
        taker.fill(o, sig, SELL_IN, address(tB));

        uint256 delivered = tB.balanceOf(maker) - before_;
        assertEq(delivered, OUT_START - (OUT_START - OUT_END) / 4, "quarter-decayed price");
        assertEq(taker.quotedOut(), delivered, "lens quote == what Pricing demanded");
    }

    /// @dev The case that proves the subtraction: a partial fill landing on
    ///      progress someone else made.
    function test_inFlight_partialOntoExistingProgress() public {
        Order memory o = _decaying(2);
        bytes memory sig = _sign(o);

        tB.mint(solver, 10_000e18);
        _solverApprove(address(settlement), address(tB), type(uint160).max);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN / 4);

        vm.warp(block.timestamp + DURATION / 2);
        uint256 before_ = tB.balanceOf(maker);
        taker.fill(o, sig, SELL_IN / 4, address(tB));
        assertEq(taker.quotedOut(), tB.balanceOf(maker) - before_, "slice priced exactly");
    }

    /// @dev Soft exclusivity: the lens reruns the override against the FILLER it
    ///      was given, so an outsider sees the lift it will actually pay.
    function test_inFlight_seesSoftExclusivityOverride() public {
        Order memory o = _decaying(3);
        o.exclusiveFiller = address(0xE0E0);
        _setExclusivityEnd(o, block.timestamp + 1 hours);
        o.params = 100;
        bytes memory sig = _sign(o);

        uint256 before_ = tB.balanceOf(maker);
        taker.fill(o, sig, SELL_IN, address(tB));
        assertEq(taker.quotedOut(), tB.balanceOf(maker) - before_, "override included");
    }

    /// @dev THE DELTA IS DISCOVERED, NOT ASSUMED. The taker passes the progress it
    ///      captured, never the `fillAmount` it requested — so the recovery is
    ///      right even when the settler accepted a DIFFERENT delta than asked for,
    ///      which is exactly what a fill-module order does.
    function test_inFlight_deltaComesFromTheCounterNotTheRequest() public {
        Order memory o = _decaying(4);
        bytes memory sig = _sign(o);
        tB.mint(solver, 10_000e18);
        _solverApprove(address(settlement), address(tB), type(uint160).max);

        (, uint256 prevA,) = lens.fillState(o);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN / 2);
        (, uint256[] memory first) = lens.previewFillInFlight(o, prevA, 0, solver, "");

        // A second, smaller fill onto non-zero progress: its own slice, priced on
        // its own `prevFilled`.
        (, uint256 prevB,) = lens.fillState(o);
        assertEq(prevB, SELL_IN / 2, "progress captured after the first fill");
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN / 4);
        (, uint256[] memory second) = lens.previewFillInFlight(o, prevB, 0, solver, "");

        assertEq(second[0], first[0] / 2, "half the size, half the slice");
    }

    /// @dev The ordinary preview reads `filled` as it stands, so from inside a
    ///      callback it prices the NEXT fill — the hazard the in-flight variant
    ///      exists for.
    function test_inFlight_ordinaryPreviewPricesTheNextFill() public {
        Order memory o = _decaying(6);
        bytes memory sig = _sign(o);
        tB.mint(solver, 10_000e18);
        _solverApprove(address(settlement), address(tB), type(uint160).max);

        (, uint256 prev,) = lens.fillState(o);
        vm.prank(solver);
        settlement.fill(o, sig, (SELL_IN * 3) / 4);

        (, uint256[] memory inFlight) = lens.previewFillInFlight(o, prev, 0, solver, "");
        (,, uint256[] memory nextFill) = lens.previewFill(o, SELL_IN / 4, solver, "");
        assertTrue(inFlight[0] != nextFill[0], "the two price different fills");
    }

    /// @dev `fillState` captures the two values a fill destroys: the pre-fill
    ///      progress, and a proportional anchor tied to the maker's live balance.
    function test_inFlight_fillStateCapturesProgressAndAnchor() public view {
        Order memory o = _plainOrder(5, address(tA), address(tB), 1, OUT_START);
        o.legsIn = PackedEncode.setLegInStart(o.legsIn, 0, Proportional.encode(5_000));
        o.legsIn = PackedEncode.setLegInEnd(o.legsIn, 0, 10_000e18);

        (bytes32 hash_, uint256 prevFilled, uint256 anchor) = lens.fillState(o);
        assertEq(hash_, lens.hashOrder(o), "hash returned so the caller need not recompute");
        assertEq(prevFilled, 0, "untouched order");
        assertEq(anchor, tA.balanceOf(maker) / 2, "half the maker's live balance");
    }
}
