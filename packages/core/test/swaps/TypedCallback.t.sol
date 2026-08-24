// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "../shared/PackedEncode.sol";

import {Order, CallbackMode, FillCtx, LegOut} from "@core/settlement/Settlement.sol";
import {Settlement} from "@core/settlement/Settlement.sol";
import {ISettlementCallback} from "@core/interfaces/ISettlementCallback.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {Pricing} from "@core/settlement/Pricing.sol";
import {Proportional} from "@core/settlement/Proportional.sol";

import {MockSettlementBase} from "../shared/MockSettlementBase.t.sol";

/// @dev A taker built on the TYPED callback. It carries only its own blob; the
///      settler supplies hash, progress, anchor and bump, so the taker performs
///      no capture, no lens call and no re-derivation.
contract TypedTaker is ISettlementCallback {
    Settlement public immutable SETTLEMENT;
    address public immutable EXECUTOR;

    uint256 private _active = 1;

    // Everything the settler handed over, kept for assertions.
    bytes32 public gotHash;
    uint256 public gotPrev;
    uint256 public gotNew;
    uint256 public gotAnchor;
    uint256 public owedOut;

    error OnlyExecutor();
    error NotArmed();

    constructor(address settlement) {
        SETTLEMENT = Settlement(payable(settlement));
        EXECUTOR = address(Settlement(payable(settlement)).EXECUTOR());
    }

    /// @notice Fill using ONLY what the callback hands over, for an order whose
    ///         output legs are `tokens`.
    function fillMulti(
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmount,
        address[] calldata tokens,
        CallbackMode mode
    ) external {
        _active = 2;
        SETTLEMENT.fillWithCallback(order, sig, fillAmount, address(this), abi.encode(tokens), mode);
    }

    function fill(Order calldata order, bytes calldata sig, uint256 fillAmount, address tokenOut, CallbackMode mode)
        external
    {
        _active = 2;
        // The blob is JUST the taker's own data — no order, no captured state.
        address[] memory one = new address[](1);
        one[0] = tokenOut;
        SETTLEMENT.fillWithCallback(order, sig, fillAmount, address(this), abi.encode(one), mode);
    }

    /// @inheritdoc ISettlementCallback
    function onSettlementFill(
        bytes32 orderHash,
        uint256 prevFilled,
        uint256 newFilled,
        uint256 anchor,
        uint256[] calldata pricedOut,
        bytes calldata userData
    ) external {
        if (msg.sender != EXECUTOR) revert OnlyExecutor();
        if (_active != 2) revert NotArmed();
        _active = 1;

        gotHash = orderHash;
        gotPrev = prevFilled;
        gotNew = newFilled;
        gotAnchor = anchor;

        // Approve EXACTLY what the settler said it will demand, PER LEG. No order,
        // no clock, no re-derivation — if any handed-over number is wrong or a leg
        // is missing, the fill reverts.
        address[] memory tokens = abi.decode(userData, (address[]));
        owedOut = 0;
        for (uint256 j; j < pricedOut.length; ++j) {
            owedOut += pricedOut[j];
            SafeTransferLib.forceApprove(tokens[j], address(SETTLEMENT), pricedOut[j]);
        }
        legCount = pricedOut.length;
    }

    uint256 public legCount;

}

/// @title TypedCallback
/// @notice The opt-in typed callback ({CallbackMode.PreDeliveryTyped} /
///         {PostInputsTyped}): the settler hands the callback the fill's resolved
///         context, so a taker needs no pre-fill capture, no lens call and no
///         private copy of the pricing math.
///
///         The assertions are deliberately end-to-end: the taker approves ONLY
///         what the handed-over context prices, so every passing fill is proof
///         the context matched what {Pricing} then demanded.
contract TypedCallbackTest is MockSettlementBase {
    uint256 constant SELL_IN = 1_000e18;
    uint256 constant OUT_START = 2_000e18;
    uint256 constant OUT_END = 1_000e18;
    uint32 constant DURATION = 1_000;

    TypedTaker taker;

    function setUp() public override {
        super.setUp();
        taker = new TypedTaker(address(settlement));
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

    // ════════════════ the context is exact ════════════════

    function test_typed_contextMatchesTheFill() public {
        Order memory o = _decaying(1);
        bytes memory sig = _sign(o);
        vm.warp(block.timestamp + DURATION / 4);

        uint256 before_ = tB.balanceOf(maker);
        taker.fill(o, sig, SELL_IN, address(tB), CallbackMode.PreDeliveryTyped);

        assertEq(taker.gotHash(), lens.hashOrder(o), "orderHash handed over");
        assertEq(taker.gotPrev(), 0, "prevFilled");
        assertEq(taker.gotNew(), SELL_IN, "newFilled");
        assertEq(taker.gotAnchor(), SELL_IN, "anchor");
        // The taker approved only what the context priced, and the fill settled.
        assertEq(tB.balanceOf(maker) - before_, taker.owedOut(), "context priced the real delivery");
        assertEq(taker.owedOut(), OUT_START - (OUT_START - OUT_END) / 4, "quarter-decayed");
    }

    /// @dev `prevFilled` is the value a taker CANNOT get after the fill — the
    ///      counter has already moved. Handed over, it is simply correct.
    function test_typed_prevFilledOnExistingProgress() public {
        Order memory o = _decaying(2);
        bytes memory sig = _sign(o);

        tB.mint(solver, 10_000e18);
        _solverApprove(address(settlement), address(tB), type(uint160).max);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN / 4);

        vm.warp(block.timestamp + DURATION / 2);
        uint256 before_ = tB.balanceOf(maker);
        taker.fill(o, sig, SELL_IN / 4, address(tB), CallbackMode.PreDeliveryTyped);

        assertEq(taker.gotPrev(), SELL_IN / 4, "progress before this fill");
        assertEq(taker.gotNew(), SELL_IN / 2, "progress after");
        assertEq(tB.balanceOf(maker) - before_, taker.owedOut(), "slice priced from the context");
    }

    /// @dev A PROPORTIONAL anchor under `PostInputsTyped` — the case that forces a
    ///      pre-fill capture without the typed mode, because the maker's balance
    ///      has already moved by callback time. Handed over, it needs nothing.
    function test_typed_proportionalAnchorUnderPostInputs() public {
        Order memory o = _plainOrder(3, address(tA), address(tB), 1, OUT_START);
        o.legsIn = PackedEncode.setLegInStart(o.legsIn, 0, Proportional.encode(5_000));
        o.legsIn = PackedEncode.setLegInEnd(o.legsIn, 0, 10_000e18);
        o.legsOut = PackedEncode.oneLegOut(address(tB), OUT_START, 0, address(0));

        uint256 half = tA.balanceOf(maker) / 2;
        bytes memory sig = _sign(o);
        taker.fill(o, sig, half, address(tB), CallbackMode.PostInputsTyped);

        assertEq(taker.gotAnchor(), half, "live-balance anchor, handed over after the maker paid");
        assertEq(tA.balanceOf(address(taker)), half, "taker was paid the resolved input");
    }

    // ════════════════ the untyped path is untouched ════════════════

    /// @dev THE REASON THIS IS ADDITIVE. The untyped callback can still invoke an
    ///      arbitrary function on an arbitrary contract — the property the suite
    ///      relies on to prove the EXECUTOR is powerless. A typed-only design
    ///      could not express this call at all.
    function test_typed_untypedModeStillCallsArbitraryTargets() public {
        Order memory o = _decaying(5);
        bytes memory sig = _sign(o);
        tB.mint(solver, 10_000e18);
        _solverApprove(address(settlement), address(tB), type(uint160).max);

        // Point the callback at Permit3 with a drain attempt — harmless, and still
        // expressible.
        bytes memory drain = abi.encodeWithSignature(
            "transferFrom(address,address,address,uint160)", maker, solver, address(tA), uint160(1)
        );
        vm.prank(solver);
        vm.expectRevert();
        settlement.fillWithCallback(o, sig, SELL_IN, address(permit3), drain, CallbackMode.PreDelivery);
    }

    /// @dev And an ordinary untyped fill still settles unchanged.
    function test_typed_untypedModeStillFills() public {
        Order memory o = _decaying(6);
        bytes memory sig = _sign(o);
        tB.mint(solver, 10_000e18);
        _solverApprove(address(settlement), address(tB), type(uint160).max);

        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fillWithCallback(o, sig, SELL_IN, address(0), "", CallbackMode.PreDelivery);
        assertEq(tB.balanceOf(maker) - before_, OUT_START, "untyped path unchanged");
    }
}

/// @dev Callback targets that fail in each of the shapes a solver can produce.
contract RevertingTarget {
    error Custom(uint256 a, address b);

    function withRequireString() external pure {
        require(false, "solver: route went stale");
    }

    function withCustomError() external pure {
        revert Custom(42, address(0xBEEF));
    }

    function withBareRevert() external pure {
        // solhint-disable-next-line reason-string
        revert();
    }

    function withPanic() external pure returns (uint256) {
        uint256 z;
        return 1 / z; // Panic(0x12)
    }

    /// @dev The TYPED entrypoint — reached only by the `*Typed` modes, which call
    ///      this selector rather than whatever the taker encoded.
    function onSettlementFill(bytes32, uint256, uint256, uint256, uint256[] calldata, bytes calldata) external pure {
        revert Custom(42, address(0xBEEF));
    }
}

/// @title CallbackRevertBubbling
/// @notice The callback call is hand-encoded in assembly ({Core._execute}), so the
///         revert path is hand-written too. These pin that EVERY revert shape
///         still reaches the caller intact — a solver's failure taxonomy
///         (docs/filler-strategy.md) depends on telling a stale route from an
///         unfillable order, and a swallowed reason destroys that.
///
///         Note the reason arrives WRAPPED: {SolverCallbackExecutor} bubbles the
///         target's failure as `CallbackFailed(ret)`, and Settlement forwards that
///         verbatim. Callers unwrap one layer.
contract CallbackRevertBubblingTest is MockSettlementBase {
    uint256 constant SELL_IN = 1_000e18;
    uint256 constant OUT_START = 2_000e18;

    RevertingTarget target;

    function setUp() public override {
        super.setUp();
        target = new RevertingTarget();
        tA.mint(maker, 10_000e18);
        _makerApprove(address(settlement), address(tA), type(uint160).max);
        tB.mint(solver, 10_000e18);
        _solverApprove(address(settlement), address(tB), type(uint160).max);
    }

    function _order(uint256 nonce) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), SELL_IN, OUT_START);
    }

    function _expectWrapped(bytes memory inner) internal {
        vm.expectRevert(abi.encodeWithSignature("CallbackFailed(bytes)", inner));
    }

    /// @dev `require(false, "…")` → `Error(string)`, reason text preserved.
    function test_bubble_requireString() public {
        Order memory o = _order(1);
        bytes memory sig = _sign(o);
        bytes memory cb = abi.encodeCall(RevertingTarget.withRequireString, ());
        _expectWrapped(abi.encodeWithSignature("Error(string)", "solver: route went stale"));
        vm.prank(solver);
        settlement.fillWithCallback(o, sig, SELL_IN, address(target), cb, CallbackMode.PreDelivery);
    }

    /// @dev A custom error keeps its selector AND its arguments.
    function test_bubble_customErrorWithArgs() public {
        Order memory o = _order(2);
        bytes memory sig = _sign(o);
        bytes memory cb = abi.encodeCall(RevertingTarget.withCustomError, ());
        _expectWrapped(abi.encodeWithSelector(RevertingTarget.Custom.selector, uint256(42), address(0xBEEF)));
        vm.prank(solver);
        settlement.fillWithCallback(o, sig, SELL_IN, address(target), cb, CallbackMode.PreDelivery);
    }

    /// @dev `revert()` returns NO data — returndatasize 0. The bubble must not
    ///      fabricate a reason, and must still abort the fill.
    function test_bubble_bareRevertCarriesNoData() public {
        Order memory o = _order(3);
        bytes memory sig = _sign(o);
        bytes memory cb = abi.encodeCall(RevertingTarget.withBareRevert, ());
        _expectWrapped("");
        vm.prank(solver);
        settlement.fillWithCallback(o, sig, SELL_IN, address(target), cb, CallbackMode.PreDelivery);
    }

    /// @dev A typed-mode target that does NOT implement {ISettlementCallback} is
    ///      called with a selector it has no function for, so it reverts with empty
    ///      returndata. The bubble reports that faithfully rather than inventing a
    ///      reason — the honest signal for "wrong callback shape".
    function test_bubble_typedModeAgainstNonImplementer() public {
        Order memory o = _order(6);
        bytes memory sig = _sign(o);
        _expectWrapped("");
        vm.prank(solver);
        settlement.fillWithCallback(o, sig, SELL_IN, address(tA), "", CallbackMode.PreDeliveryTyped);
    }

    /// @dev A compiler-generated `Panic(uint256)` survives too — division by zero
    ///      in the target reads as 0x12, not as an opaque failure.
    function test_bubble_panic() public {
        Order memory o = _order(4);
        bytes memory sig = _sign(o);
        bytes memory cb = abi.encodeCall(RevertingTarget.withPanic, ());
        _expectWrapped(abi.encodeWithSignature("Panic(uint256)", uint256(0x12)));
        vm.prank(solver);
        settlement.fillWithCallback(o, sig, SELL_IN, address(target), cb, CallbackMode.PreDelivery);
    }

    /// @dev And the same through the TYPED mode, which builds a different payload
    ///      but shares the hand-encoded call. Note the taker's blob is now just
    ///      `userData`: the settler prepends the `onSettlementFill` selector, so a
    ///      typed-mode target must implement the interface — a target that does not
    ///      reverts with NO data, which is itself worth knowing.
    function test_bubble_throughTypedMode() public {
        Order memory o = _order(5);
        bytes memory sig = _sign(o);
        bytes memory cb = "";
        _expectWrapped(abi.encodeWithSelector(RevertingTarget.Custom.selector, uint256(42), address(0xBEEF)));
        vm.prank(solver);
        settlement.fillWithCallback(o, sig, SELL_IN, address(target), cb, CallbackMode.PreDeliveryTyped);
    }
}

/// @title TypedCallbackClamped
/// @notice THE PROPERTY THAT MAKES THE TYPED MODE USABLE: `pricedOut[]` is the
///         settled amount for every output leg — already sliced for a partial
///         fill, already lifted by a soft-exclusivity override, already
///         ceil-rounded, and covering fee legs paid to third parties.
///
///         Every test here fills through a taker that approves ONLY `pricedOut[j]`
///         per leg and knows nothing else about the order. A fill that settles is
///         therefore proof the handed-over amounts were sufficient AND exact — too
///         low and the pull reverts; a missing leg reverts; a leg the taker was not
///         told about reverts.
contract TypedCallbackClampedTest is MockSettlementBase {
    uint256 constant SELL_IN = 1_000e18;
    uint256 constant OUT_START = 2_000e18;
    uint256 constant OUT_END = 1_000e18;
    uint32 constant DURATION = 1_000;

    address constant FEE_TO = address(0xFEE0);

    TypedTaker taker;

    function setUp() public override {
        super.setUp();
        taker = new TypedTaker(address(settlement));
        tA.mint(maker, 10_000e18);
        _makerApprove(address(settlement), address(tA), type(uint160).max);
        tB.mint(address(taker), 10_000e18);
        tC.mint(address(taker), 10_000e18);
    }

    function _two() internal view returns (address[] memory t) {
        t = new address[](2);
        t[0] = address(tB);
        t[1] = address(tC);
    }

    function _one() internal view returns (address[] memory t) {
        t = new address[](1);
        t[0] = address(tB);
    }

    function _decaying(uint256 nonce) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), SELL_IN, OUT_START);
        o.legsOut = PackedEncode.oneLegOut(address(tB), OUT_START, OUT_END, address(0));
        _setDecayStart(o, block.timestamp);
        _setDecayDuration(o, DURATION);
    }

    // ════════════ partial fills: the pro-rata slice, not the leg total ════════════

    /// @dev A quarter fill must deliver a quarter of the priced tick — NOT the
    ///      leg's full `start`. The taker approves only what it was handed, so a
    ///      leg-total would over-approve and a stale figure would under-approve.
    function test_clamped_partialFillSlice() public {
        Order memory o = _decaying(1);
        bytes memory sig = _sign(o);
        vm.warp(block.timestamp + DURATION / 2); // clock at 5000 bps

        uint256 before_ = tB.balanceOf(maker);
        taker.fillMulti(o, sig, SELL_IN / 4, _one(), CallbackMode.PreDeliveryTyped);

        uint256 delivered = tB.balanceOf(maker) - before_;
        assertEq(taker.owedOut(), delivered, "pricedOut == the settled slice");
        // A quarter of the midpoint tick, ceil-rounded.
        assertEq(delivered, ((OUT_START + OUT_END) / 2) / 4, "quarter of the midpoint");
    }

    /// @dev The slice is relative to EXISTING progress, so a second partial fill
    ///      prices its own quarter rather than the cumulative half.
    function test_clamped_partialOntoProgress() public {
        Order memory o = _decaying(2);
        bytes memory sig = _sign(o);

        tB.mint(solver, 10_000e18);
        _solverApprove(address(settlement), address(tB), type(uint160).max);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN / 2);

        vm.warp(block.timestamp + DURATION / 2);
        uint256 before_ = tB.balanceOf(maker);
        taker.fillMulti(o, sig, SELL_IN / 4, _one(), CallbackMode.PreDeliveryTyped);
        assertEq(taker.owedOut(), tB.balanceOf(maker) - before_, "own slice, not the cumulative");
    }

    // ════════════ soft exclusivity: the override is already applied ════════════

    /// @dev An outsider filling in-window owes the maker MORE. `pricedOut` carries
    ///      the lifted number, so a taker that trusts it succeeds — one that priced
    ///      the plain tick would under-approve and revert.
    function test_clamped_softExclusivityOverrideIncluded() public {
        Order memory o = _decaying(3);
        o.exclusiveFiller = address(0xE0E0);
        _setExclusivityEnd(o, block.timestamp + 1 hours);
        o.params = 100; // 1% improvement owed by a non-exclusive filler
        bytes memory sig = _sign(o);

        uint256 before_ = tB.balanceOf(maker);
        taker.fillMulti(o, sig, SELL_IN, _one(), CallbackMode.PreDeliveryTyped);

        uint256 delivered = tB.balanceOf(maker) - before_;
        assertEq(taker.owedOut(), delivered, "pricedOut includes the override");
        assertEq(delivered, (OUT_START * 10_100) / 10_000, "1% above the plain tick");
    }

    // ════════════ multi-leg: fee legs are legs ════════════

    /// @dev Two output legs — the maker's and a third-party fee. `pricedOut` is
    ///      indexed 1:1 with `legsOut`, so a taker can satisfy both without knowing
    ///      what either is for.
    function test_clamped_multiLegIncludesFeeLeg() public {
        Order memory o = _plainOrder(4, address(tA), address(tB), SELL_IN, OUT_START);
        LegOut[] memory legs = new LegOut[](2);
        legs[0] = LegOut({token: address(tB), start: OUT_START, end: 0, recipient: address(0)});
        legs[1] = LegOut({token: address(tC), start: 25e18, end: 0, recipient: FEE_TO});
        o.legsOut = PackedEncode.legsOut(legs);
        bytes memory sig = _sign(o);

        uint256 makerBefore = tB.balanceOf(maker);
        taker.fillMulti(o, sig, SELL_IN, _two(), CallbackMode.PreDeliveryTyped);

        assertEq(taker.legCount(), 2, "one entry per output leg");
        assertEq(tB.balanceOf(maker) - makerBefore, OUT_START, "maker leg settled");
        assertEq(tC.balanceOf(FEE_TO), 25e18, "fee leg settled");
        assertEq(taker.owedOut(), OUT_START + 25e18, "pricedOut totals both legs");
    }

    /// @dev And the fee leg slices pro-rata on a partial fill too.
    function test_clamped_multiLegPartial() public {
        Order memory o = _plainOrder(5, address(tA), address(tB), SELL_IN, OUT_START);
        LegOut[] memory legs = new LegOut[](2);
        legs[0] = LegOut({token: address(tB), start: OUT_START, end: 0, recipient: address(0)});
        legs[1] = LegOut({token: address(tC), start: 25e18, end: 0, recipient: FEE_TO});
        o.legsOut = PackedEncode.legsOut(legs);
        bytes memory sig = _sign(o);

        taker.fillMulti(o, sig, SELL_IN / 2, _two(), CallbackMode.PreDeliveryTyped);
        assertEq(tC.balanceOf(FEE_TO), 25e18 / 2, "fee leg sliced too");
    }

    // ════════════ the negative: the numbers are EXACT, not a floor ════════════

    /// @dev A taker that shaves one wei off what it was handed cannot settle. This
    ///      is what makes the passing tests above meaningful rather than vacuous:
    ///      approving `pricedOut` is necessary, not merely sufficient.
    function test_clamped_underApprovingByOneWeiReverts() public {
        ShavingTaker bad = new ShavingTaker(address(settlement));
        tB.mint(address(bad), 10_000e18);
        Order memory o = _decaying(6);
        bytes memory sig = _sign(o);
        vm.expectRevert();
        bad.fill(o, sig, SELL_IN, address(tB));
    }
}

/// @dev Identical to {TypedTaker} except it approves one wei less than handed.
contract ShavingTaker {
    Settlement public immutable SETTLEMENT;
    address public immutable EXECUTOR;
    uint256 private _active = 1;

    constructor(address settlement) {
        SETTLEMENT = Settlement(payable(settlement));
        EXECUTOR = address(Settlement(payable(settlement)).EXECUTOR());
    }

    function fill(Order calldata order, bytes calldata sig, uint256 fillAmount, address tokenOut) external {
        _active = 2;
        SETTLEMENT.fillWithCallback(
            order, sig, fillAmount, address(this), abi.encode(tokenOut), CallbackMode.PreDeliveryTyped
        );
    }

    function onSettlementFill(bytes32, uint256, uint256, uint256, uint256[] calldata p, bytes calldata d) external {
        require(msg.sender == EXECUTOR && _active == 2);
        _active = 1;
        SafeTransferLib.forceApprove(abi.decode(d, (address)), address(SETTLEMENT), p[0] - 1);
    }
}
