// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Order, FillCtx, CallbackMode} from "@core/settlement/Settlement.sol";
import {Proportional} from "@core/settlement/Proportional.sol";
import {Settlement} from "@core/settlement/Settlement.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {FillRecovery} from "@solvers/aggregator/FillRecovery.sol";

import {MockSettlementBase} from "@coretest/shared/MockSettlementBase.t.sol";

/// @dev A solver whose whole job is to RECOVER the in-flight fill's numbers from
///      inside the callback, then satisfy them. It is handed nothing by
///      Settlement: it passes itself the order and re-derives the rest.
contract RecoveringSolver {
    Settlement public immutable SETTLEMENT;
    address public immutable EXECUTOR;

    uint256 private _active = 1;
    /// @notice What the recovery computed for output leg 0, for assertions.
    uint256 public recoveredOut;
    uint256 public recoveredPrevFilled;
    uint256 public recoveredBump;

    error OnlyExecutor();
    error NotArmed();

    constructor(address settlement) {
        SETTLEMENT = Settlement(payable(settlement));
        EXECUTOR = address(Settlement(payable(settlement)).EXECUTOR());
    }

    /// @notice `PostInputs`, capturing the anchor BEFORE the fill — the pattern
    ///         that makes a proportional order recoverable. `anchorOf` and the
    ///         fill are in one transaction, so nothing can move between them.
    function fillPostInputs(Order calldata order, bytes calldata sig, uint256 fillAmount, address tokenOut) external {
        uint256 anchor = FillRecovery.anchorOf(order);
        _active = 2;
        SETTLEMENT.fillWithCallback(
            order,
            sig,
            fillAmount,
            address(this),
            abi.encodeCall(this.onFillPost, (order, fillAmount, tokenOut, anchor)),
            CallbackMode.PostInputs
        );
    }

    function onFillPost(Order calldata order, uint256 fillAmount, address tokenOut, uint256 anchor) external {
        if (msg.sender != EXECUTOR) revert OnlyExecutor();
        if (_active != 2) revert NotArmed();
        _active = 1;

        FillCtx memory ctx =
            FillRecovery.ctxOfWithAnchor(SETTLEMENT, order, fillAmount, address(this), "", anchor);
        recoveredPrevFilled = ctx.prevFilled;
        recoveredOut = FillRecovery.totalOutputOwed(order, ctx);
        SafeTransferLib.forceApprove(tokenOut, address(SETTLEMENT), recoveredOut);
    }

    /// @notice The same, WITHOUT capturing — must refuse rather than mis-price.
    function fillPostInputsNoCapture(Order calldata order, bytes calldata sig, uint256 fillAmount, address tokenOut)
        external
    {
        _active = 2;
        SETTLEMENT.fillWithCallback(
            order,
            sig,
            fillAmount,
            address(this),
            abi.encodeCall(this.onFillNoCapture, (order, fillAmount, tokenOut)),
            CallbackMode.PostInputs
        );
    }

    function onFillNoCapture(Order calldata order, uint256 fillAmount, address tokenOut) external {
        if (msg.sender != EXECUTOR) revert OnlyExecutor();
        if (_active != 2) revert NotArmed();
        _active = 1;
        FillCtx memory ctx = FillRecovery.ctxOf(SETTLEMENT, order, fillAmount, address(this), "", true);
        recoveredOut = FillRecovery.totalOutputOwed(order, ctx);
        SafeTransferLib.forceApprove(tokenOut, address(SETTLEMENT), recoveredOut);
    }

    /// @dev `PreDelivery`: nothing has moved when the callback runs, which is
    ///      exactly the case where a balance read tells the solver nothing.
    function fill(Order calldata order, bytes calldata sig, uint256 fillAmount, address tokenOut) external {
        _active = 2;
        SETTLEMENT.fillWithCallback(
            order,
            sig,
            fillAmount,
            address(this),
            abi.encodeCall(this.onFill, (order, fillAmount, tokenOut)),
            CallbackMode.PreDelivery
        );
    }

    function onFill(Order calldata order, uint256 fillAmount, address tokenOut) external {
        if (msg.sender != EXECUTOR) revert OnlyExecutor();
        if (_active != 2) revert NotArmed();
        _active = 1;

        FillCtx memory ctx = FillRecovery.ctxOf(SETTLEMENT, order, fillAmount, address(this), "", false);
        recoveredPrevFilled = ctx.prevFilled;
        recoveredBump = ctx.bump;
        recoveredOut = FillRecovery.totalOutputOwed(order, ctx);

        // Prove the number is USABLE, not just readable: approve exactly it, so
        // the fill can only settle if the recovery matched what Pricing demands.
        SafeTransferLib.forceApprove(tokenOut, address(SETTLEMENT), recoveredOut);
    }
}

/// @title FillRecoveryTest
/// @notice The callback receives no amounts — but every field of the in-flight
///         {FillCtx} is recoverable from public state plus the arguments the
///         solver itself chose. These pin that the recovery is EXACT, on the
///         cases where guessing would be wrong: a decayed clock, a partial fill
///         onto existing progress, and soft exclusivity.
contract FillRecoveryTest is MockSettlementBase {
    uint256 constant SELL_IN = 1_000e18;
    uint256 constant OUT_START = 2_000e18;
    uint256 constant OUT_END = 1_000e18;
    uint32 constant DURATION = 1_000;

    RecoveringSolver rs;

    function setUp() public override {
        super.setUp();
        rs = new RecoveringSolver(address(settlement));
        vm.label(address(rs), "recoveringSolver");

        tA.mint(maker, 10_000e18);
        _makerApprove(address(settlement), address(tA), type(uint160).max);
        // PreDelivery: the solver must already hold the output.
        tB.mint(address(rs), 10_000e18);
    }

    /// @dev A decaying SELL — the shape whose required output is resolved at fill
    ///      time and cannot be known from the order alone.
    function _decaying(uint256 nonce) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), SELL_IN, OUT_START);
        o.legsOut = PackedEncode.oneLegOut(address(tB), OUT_START, OUT_END, address(0));
        _setDecayStart(o, block.timestamp);
        _setDecayDuration(o, DURATION);
    }

    function test_recovery_matchesTheDecayedPrice() public {
        Order memory o = _decaying(1);
        bytes memory sig = _sign(o);
        vm.warp(block.timestamp + DURATION / 4); // clock at 2500 bps

        uint256 makerBefore = tB.balanceOf(maker);
        rs.fill(o, sig, SELL_IN, address(tB));

        uint256 delivered = tB.balanceOf(maker) - makerBefore;
        assertEq(delivered, OUT_START - (OUT_START - OUT_END) / 4, "the quarter-decayed price");
        // THE PROPERTY: the callback computed exactly what the settler then took.
        assertEq(rs.recoveredOut(), delivered, "recovery == what Pricing demanded");
    }

    /// @dev Recovery on a partial fill landing on EXISTING progress — where
    ///      `prevFilled` is not zero and a naive solver would misprice the slice.
    function test_recovery_partialFillOntoExistingProgress() public {
        Order memory o = _decaying(2);
        bytes memory sig = _sign(o);

        // Someone else fills a quarter first.
        tB.mint(solver, 10_000e18);
        _solverApprove(address(settlement), address(tB), type(uint160).max);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN / 4);

        vm.warp(block.timestamp + DURATION / 2);
        uint256 makerBefore = tB.balanceOf(maker);
        rs.fill(o, sig, SELL_IN / 4, address(tB));

        assertEq(rs.recoveredPrevFilled(), SELL_IN / 4, "prevFilled recovered exactly");
        assertEq(rs.recoveredOut(), tB.balanceOf(maker) - makerBefore, "slice priced exactly");
    }

    /// @dev Soft exclusivity moves the price for a non-exclusive filler. The
    ///      recovery reruns {OrderGates.exclusivityOverride} with its own address,
    ///      so it sees the same lift the settler applied.
    function test_recovery_seesTheSoftExclusivityOverride() public {
        Order memory o = _decaying(3);
        o.exclusiveFiller = address(0xE0E0);
        _setExclusivityEnd(o, block.timestamp + 1 hours);
        o.params = 100; // 1% override for an outsider
        bytes memory sig = _sign(o);

        uint256 makerBefore = tB.balanceOf(maker);
        rs.fill(o, sig, SELL_IN, address(tB));

        uint256 delivered = tB.balanceOf(maker) - makerBefore;
        assertEq(delivered, (OUT_START * 10_100) / 10_000, "outsider paid the override");
        assertEq(rs.recoveredOut(), delivered, "recovery included the override");
    }

    /// @dev The recovery is exact enough to APPROVE against: `onFill` approves
    ///      precisely the recovered figure, so any mismatch would fail the pull.
    ///      A full-window fill (bump at BPS, the maker's floor) is the boundary.
    function test_recovery_exactAtTheFloor() public {
        Order memory o = _decaying(4);
        bytes memory sig = _sign(o);
        vm.warp(block.timestamp + DURATION * 2); // past the window ⇒ clamped to end

        uint256 makerBefore = tB.balanceOf(maker);
        rs.fill(o, sig, SELL_IN, address(tB));
        assertEq(tB.balanceOf(maker) - makerBefore, OUT_END, "the maker's floor");
        assertEq(rs.recoveredOut(), OUT_END, "recovered the floor exactly");
    }
}

/// @dev The one input that must be CAPTURED rather than derived: a
///      {Proportional} anchor under `PostInputs`, where the maker's balance has
///      already moved by the time the callback runs.
contract FillRecoveryProportionalTest is MockSettlementBase {
    uint256 constant OUT_START = 500e18;
    uint256 constant MAKER_BAL = 1_000e18;

    RecoveringSolver rs;

    function setUp() public override {
        super.setUp();
        rs = new RecoveringSolver(address(settlement));
        tA.mint(maker, MAKER_BAL);
        _makerApprove(address(settlement), address(tA), type(uint160).max);
        tB.mint(address(rs), 10_000e18);
    }

    /// @dev "Sell 50% of my balance" — the anchor is the maker's live balance at
    ///      fill time, not a signed constant.
    function _propOrder(uint256 nonce) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), 1, OUT_START);
        o.legsIn = PackedEncode.setLegInStart(o.legsIn, 0, Proportional.encode(5_000));
        // `end` is the maker's absolute CAP on a proportional leg, and it is not
        // optional — an uncapped sweep is rejected as a footgun.
        o.legsIn = PackedEncode.setLegInEnd(o.legsIn, 0, MAKER_BAL);
    }

    function test_prop_capturedAnchorRecoversExactly() public {
        Order memory o = _propOrder(1);
        bytes memory sig = _sign(o);

        uint256 makerBefore = tB.balanceOf(maker);
        rs.fillPostInputs(o, sig, MAKER_BAL / 2, address(tB));

        assertEq(tA.balanceOf(address(rs)), MAKER_BAL / 2, "solver was paid half the maker's balance");
        assertEq(rs.recoveredOut(), tB.balanceOf(maker) - makerBefore, "recovery == what Pricing demanded");
    }

    /// @dev Without the capture the library REFUSES — the maker has already paid,
    ///      so re-deriving the anchor off a shrunken balance would silently
    ///      mis-price. Failing beats a plausible wrong number.
    function test_prop_withoutCapture_refuses() public {
        Order memory o = _propOrder(2);
        bytes memory sig = _sign(o);
        vm.expectRevert();
        rs.fillPostInputsNoCapture(o, sig, MAKER_BAL / 2, address(tB));
    }

    /// @dev And the refusal is specific to the shape: an ordinary absolute-amount
    ///      order recovers under `PostInputs` with no capture at all.
    function test_prop_absoluteOrderNeedsNoCapture() public {
        Order memory o = _plainOrder(3, address(tA), address(tB), 100e18, OUT_START);
        bytes memory sig = _sign(o);
        rs.fillPostInputsNoCapture(o, sig, 100e18, address(tB));
        assertEq(tA.balanceOf(address(rs)), 100e18, "plain order recovered without a hint");
    }
}

// ───────────── the two shapes whose delta is not `fillAmount` ─────────────

/// @title FillRecoveryUnsupportedShapesTest
/// @notice {FillRecovery} recovers `prevFilled` by SUBTRACTING the caller's
///         `fillAmount` from the live counter. That identity holds for an
///         identity order and for nothing else, so the two shapes that break it
///         must refuse rather than answer — a wrong `prevFilled` silently
///         mis-prices every amount the solver then derives from it.
contract FillRecoveryUnsupportedShapesTest is MockSettlementBase {
    uint256 constant FILL_ONCE_BIT = 1 << 100;

    RecoveringSolver rs;

    function setUp() public override {
        super.setUp();
        rs = new RecoveringSolver(address(settlement));
        tA.mint(maker, 1_000e18);
        tB.mint(address(rs), 1_000e18);
        _makerApprove(address(settlement), address(tA), type(uint160).max);
    }

    /// @dev A fill-module order's delta is whatever {IFillModule.resolveFill}
    ///      returned — a number the caller never chose, so subtraction cannot
    ///      recover it. The module address alone is enough to refuse; no module
    ///      needs to exist for the guard to be the right answer.
    function test_unsupported_fillModuleOrderRefuses() public {
        Order memory o = _plainOrder(1, address(tA), address(tB), 100e18, 90e18);
        o.fillModule = address(0xBEEF);
        bytes memory sig = _sign(o);
        vm.expectRevert();
        rs.fillPostInputs(o, sig, 100e18, address(tB));
    }

    /// @dev A fill-once order burns its nonce and never writes `filled`, so the
    ///      counter reads zero forever and the subtraction underflows.
    function test_unsupported_fillOnceOrderRefuses() public {
        Order memory o = _plainOrder(2, address(tA), address(tB), 100e18, 90e18);
        o.timing |= FILL_ONCE_BIT;
        bytes memory sig = _sign(o);
        vm.expectRevert();
        rs.fillPostInputs(o, sig, 100e18, address(tB));
    }
}
