// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Order, CallbackMode} from "@core/settlement/Settlement.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {SolverCallbackExecutor} from "@core/settlement/SolverCallbackExecutor.sol";
import {
    AggregatorFillSolver,
    RoutePlan,
    FillRoute,
    SurplusPolicy,
    NO_PATCH,
    PPM
} from "@solvers/aggregator/AggregatorFillSolver.sol";

import {MockSettlementBase} from "@coretest/shared/MockSettlementBase.t.sol";

/// @dev A stand-in for an aggregator router. Behaves like the real thing in the
///      one way that matters here: it PULLS its input from `msg.sender`, which is
///      why the callback cannot be pointed at it directly.
contract MockRouter {
    address public immutable TOKEN_IN;
    address public immutable TOKEN_OUT;
    uint256 public rateBps = 10_000;

    constructor(address tokenIn, address tokenOut) {
        TOKEN_IN = tokenIn;
        TOKEN_OUT = tokenOut;
    }

    function setRate(uint256 bps) external {
        rateBps = bps;
    }

    /// @notice `swap(amountIn, recipient)` — the recipient is baked into the
    ///         calldata by the quote, exactly as a real aggregator does it.
    function swap(uint256 amountIn, address recipient) external {
        SafeTransferLib.safeTransferFrom(TOKEN_IN, msg.sender, address(this), amountIn);
        SafeTransferLib.safeTransfer(TOKEN_OUT, recipient, (amountIn * rateBps) / 10_000);
    }
}

/// @title AggregatorFillSolverTest
/// @notice The zero-inventory aggregator fill, and the two things about it that
///         are easy to get wrong:
///
///           1. raw router calldata CANNOT be the callback target — the executor
///              is allowance-less and holds nothing, so the router's
///              `transferFrom(msg.sender, …)` finds an empty account;
///           2. the route must be quoted for the SOLVER CONTRACT, because the
///              recipient is baked into the aggregator's calldata.
contract AggregatorFillSolverTest is MockSettlementBase {
    uint256 constant AMOUNT_IN = 100e18;
    uint256 constant AMOUNT_OUT = 90e18;

    AggregatorFillSolver aggSolver;
    MockRouter router;

    function setUp() public virtual override {
        super.setUp();
        router = new MockRouter(address(tA), address(tB));
        aggSolver = new AggregatorFillSolver(address(settlement), _routers(address(router)), _noSplit());
        vm.label(address(aggSolver), "aggregatorSolver");
        vm.label(address(router), "mockRouter");

        tA.mint(maker, 1_000e18);
        _makerApprove(address(settlement), address(tA), type(uint160).max);
        // The router is the venue's liquidity — it holds the output side.
        tB.mint(address(router), 1_000e18);
    }

    /// @dev The zero policy: the whole spread stays with the filler, which is the
    ///      shape every test outside {AggregatorSurplusSplitTest} assumes.
    function _noSplit() internal pure returns (SurplusPolicy memory) {
        return SurplusPolicy({makerPpm: 0, protocolPpm: 0, protocolRecipient: address(0)});
    }

    /// @dev The constructor's router allowlist. One venue is enough for the suite;
    ///      a real deployment names every aggregator it supports.
    function _routers(address one) internal pure returns (address[] memory rs) {
        rs = new address[](1);
        rs[0] = one;
    }

    function _order(uint256 nonce) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
    }

    /// @dev Solver-side reverts reach the caller WRAPPED: the callback runs inside
    ///      {SolverCallbackExecutor}, which bubbles the failure as
    ///      `CallbackFailed(ret)`. A filler classifying revert reasons has to
    ///      unwrap one layer to tell "my route went stale" from "the maker's order
    ///      is unfillable" — see docs/filler-strategy.md.
    function _wrapped(bytes memory inner) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(SolverCallbackExecutor.CallbackFailed.selector, inner);
    }

    /// @dev A route quoted FOR `recipient` — mirrors what an aggregator returns.
    function _plan(address recipient, uint256 minOut) internal view returns (RoutePlan memory) {
        return _planFor(AMOUNT_IN, recipient, minOut, NO_PATCH);
    }

    /// @dev A route quoted for `quotedIn`, optionally patchable. `swap`'s first
    ///      argument sits right after the 4-byte selector.
    function _planFor(uint256 quotedIn, address recipient, uint256 minOut, uint256 offset)
        internal
        view
        returns (RoutePlan memory)
    {
        return RoutePlan({
            router: address(router),
            minOut: minOut,
            maxPay: 0,
            amountInOffset: offset,
            profitRecipient: address(0),
            originator: address(0),
            originatorPpm: 0,
            data: abi.encodeCall(MockRouter.swap, (quotedIn, recipient))
        });
    }

    // ════════════════════════ the happy path ════════════════════════

    /// @dev Zero inventory: the solver starts and ends with nothing, and the maker
    ///      is paid entirely out of the swap the callback performed.
    function test_agg_zeroInventoryFill() public {
        assertEq(tB.balanceOf(address(aggSolver)), 0, "solver holds no output up front");

        uint256 makerBefore = tB.balanceOf(maker);
        Order memory o = _order(1);
        aggSolver.executeFill(o, _sign(o), AMOUNT_IN, _plan(address(aggSolver), AMOUNT_OUT), "");

        assertEq(tB.balanceOf(maker) - makerBefore, AMOUNT_OUT, "maker got its signed output");
        assertEq(tA.balanceOf(address(router)), AMOUNT_IN, "the router took the maker's input");
        // The spread is swept out; the contract keeps nothing between fills.
        assertEq(tB.balanceOf(address(this)), AMOUNT_IN - AMOUNT_OUT, "caller keeps the spread");
        assertEq(tB.balanceOf(address(aggSolver)), 0, "no output retained");
        assertEq(tA.balanceOf(address(aggSolver)), 0, "no input left stranded");
    }

    /// @dev Anyone may call `executeFill` — the security boundary is the maker's
    ///      signature, not an operator list.
    function test_agg_fillIsPermissionless() public {
        Order memory o = _order(2);
        // `_sign` is a cheatcode call and would consume the prank below if it were
        // evaluated as an argument — see the harness note on `_sign`.
        bytes memory sig = _sign(o);
        vm.prank(address(0xD00D));
        aggSolver.executeFill(o, sig, AMOUNT_IN, _plan(address(aggSolver), AMOUNT_OUT), "");
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "filled by a stranger");
    }

    // ═══════════ the two integration mistakes this contract exists for ═══════════

    /// @dev THE REASON THIS CONTRACT EXISTS. Point `fillWithCallback` straight at
    ///      the aggregator and the router pulls from {SolverCallbackExecutor} — an
    ///      allowance-less trampoline holding nothing — so the swap cannot fund
    ///      the fill.
    function test_agg_rawRouterCalldataAsCallback_cannotWork() public {
        Order memory o = _order(3);
        bytes memory sig = _sign(o);
        // The filler is an EOA holding the input; the callback targets the router
        // directly, the way a naive integration would.
        address eoa = address(0xBEEF);
        tB.mint(eoa, 1_000e18);
        vm.startPrank(eoa);
        tB.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(tB), type(uint160).max, 0);
        vm.expectRevert();
        settlement.fillWithCallback(
            o, sig, AMOUNT_IN, address(router), abi.encodeCall(MockRouter.swap, (AMOUNT_IN, eoa)), CallbackMode.PostInputs
        );
        vm.stopPrank();
    }

    /// @dev A route quoted for the solver's EOA sends the output THERE, so the
    ///      solver never receives it and the fill aborts on its own floor. Funds
    ///      are not lost; the round is.
    function test_agg_routeQuotedForWrongRecipient_reverts() public {
        address eoa = address(0xEEEE);
        Order memory o = _order(4);
        bytes memory sig = _sign(o);
        RoutePlan memory plan = _plan(eoa, AMOUNT_OUT);
        vm.expectRevert(
            _wrapped(abi.encodeWithSelector(AggregatorFillSolver.InsufficientOutput.selector, uint256(0), AMOUNT_OUT))
        );
        aggSolver.executeFill(o, sig, AMOUNT_IN, plan, "");
    }

    // ════════════════════════ solver-side protection ════════════════════════

    /// @dev `minOut` is the SOLVER's floor against a stale route — distinct from
    ///      the maker's signed band, which Settlement enforces regardless.
    function test_agg_staleRoute_revertsOnMinOut() public {
        router.setRate(8_000); // the route degraded since it was quoted
        Order memory o = _order(5);
        bytes memory sig = _sign(o);
        RoutePlan memory plan = _plan(address(aggSolver), 85e18);
        vm.expectRevert(
            _wrapped(abi.encodeWithSelector(AggregatorFillSolver.InsufficientOutput.selector, uint256(80e18), 85e18))
        );
        aggSolver.executeFill(o, sig, AMOUNT_IN, plan, "");
    }

    /// @dev Even with `minOut` satisfied, a route that cannot cover the maker's
    ///      signed output aborts in Settlement — the maker is never underpaid.
    function test_agg_routeBelowMakerPrice_revertsInSettlement() public {
        router.setRate(5_000); // 50e18 out, against a signed 90e18
        Order memory o = _order(6);
        bytes memory sig = _sign(o);
        RoutePlan memory plan = _plan(address(aggSolver), 1);
        vm.expectRevert();
        aggSolver.executeFill(o, sig, AMOUNT_IN, plan, "");
    }

    // ════════════════════════ the callback guards ════════════════════════

    /// @dev `onFill` approves an arbitrary router against this contract's balance.
    ///      A direct call must be impossible for anyone but the executor.
    function test_agg_onFill_rejectsDirectCaller() public {
        vm.expectRevert(AggregatorFillSolver.OnlyExecutor.selector);
        aggSolver.onFill(
            FillRoute({
                tokenIn: address(tA),
                tokenOut: address(tB),
                router: address(router),
                minOut: 0,
                maxPay: 0,
                amountInOffset: NO_PATCH,
                inBefore: 0,
                outBefore: 0,
                data: ""
            })
        );
    }

    /// @dev And even the executor cannot drive it outside a fill this contract
    ///      armed — otherwise ANOTHER solver's fill could target this one through
    ///      the same shared trampoline and spend whatever it holds.
    function test_agg_onFill_rejectsUnarmedExecutorCall() public {
        tA.mint(address(aggSolver), 10e18); // something worth stealing
        vm.prank(address(settlement.EXECUTOR()));
        vm.expectRevert(AggregatorFillSolver.NotArmed.selector);
        aggSolver.onFill(
            FillRoute({
                tokenIn: address(tA),
                tokenOut: address(tB),
                router: address(router),
                minOut: 0,
                maxPay: 0,
                amountInOffset: NO_PATCH,
                inBefore: 0,
                outBefore: 0,
                data: ""
            })
        );
    }

    /// @dev The arming flag is single-use: it is cleared by the callback, so a
    ///      second call within the same fill finds it closed.
    function test_agg_onFill_isNotReusableWithinAFill() public {
        Order memory o = _order(7);
        aggSolver.executeFill(o, _sign(o), AMOUNT_IN, _plan(address(aggSolver), AMOUNT_OUT), "");
        vm.prank(address(settlement.EXECUTOR()));
        vm.expectRevert(AggregatorFillSolver.NotArmed.selector);
        aggSolver.onFill(
            FillRoute({
                tokenIn: address(tA),
                tokenOut: address(tB),
                router: address(router),
                minOut: 0,
                maxPay: 0,
                amountInOffset: NO_PATCH,
                inBefore: 0,
                outBefore: 0,
                data: ""
            })
        );
    }

    /// @dev A failing router surfaces as a solver error rather than an opaque
    ///      settlement revert, so an off-chain filler can classify it.
    function test_agg_routerRevert_surfaces() public {
        Order memory o = _order(8);
        bytes memory sig = _sign(o);
        RoutePlan memory bad = RoutePlan({
            router: address(router),
            minOut: 1,
            maxPay: 0,
            amountInOffset: NO_PATCH,
            profitRecipient: address(0),
            originator: address(0),
            originatorPpm: 0,
            data: hex"deadbeef"
        });
        vm.expectRevert();
        aggSolver.executeFill(o, sig, AMOUNT_IN, bad, "");
    }
}

// ─────────── resolved amounts: the route must follow the fill ───────────

/// @dev The priced amount is decided DURING the fill; the aggregator baked its
///      figure in when it was quoted. These pin what happens when they disagree,
///      and what `amountInOffset` does about it.
contract AggregatorAmountPatchTest is AggregatorFillSolverTest {
    /// @dev The filler quoted a full fill and then sized it down. Without
    ///      patching, the router still tries to pull the QUOTED amount — more
    ///      than the solver was paid — and the swap reverts.
    function test_patch_partialFillWithStaleAmount_reverts() public {
        Order memory o = _order(20);
        bytes memory sig = _sign(o);
        RoutePlan memory stale = _planFor(AMOUNT_IN, address(aggSolver), 1, NO_PATCH);
        vm.expectRevert();
        aggSolver.executeFill(o, sig, AMOUNT_IN / 2, stale, "");
    }

    /// @dev With the offset set, `onFill` rewrites the amount to what actually
    ///      arrived and the same route fills cleanly.
    function test_patch_partialFillFollowsTheFill() public {
        Order memory o = _order(21);
        bytes memory sig = _sign(o);
        uint256 makerBefore = tB.balanceOf(maker);

        // 4 = the offset of `amountIn`, immediately after the selector.
        aggSolver.executeFill(o, sig, AMOUNT_IN / 2, _planFor(AMOUNT_IN, address(aggSolver), 1, 4), "");

        assertEq(tA.balanceOf(address(router)), AMOUNT_IN / 2, "router pulled what the fill delivered");
        assertEq(tB.balanceOf(maker) - makerBefore, AMOUNT_OUT / 2, "maker paid pro-rata");
        assertEq(tA.balanceOf(address(aggSolver)), 0, "no input stranded");
    }

    /// @dev Patching also sweeps a route quoted for LESS than arrived — otherwise
    ///      the surplus sits in the solver, unswapped and unaccounted.
    function test_patch_underQuotedRouteSweepsTheSurplus() public {
        Order memory o = _order(22);
        bytes memory sig = _sign(o);
        aggSolver.executeFill(o, sig, AMOUNT_IN, _planFor(AMOUNT_IN / 4, address(aggSolver), 1, 4), "");
        assertEq(tA.balanceOf(address(router)), AMOUNT_IN, "whole input routed, not just the quoted quarter");
        assertEq(tA.balanceOf(address(aggSolver)), 0, "nothing stranded");
    }

    /// @dev A route quoted for less, WITHOUT patching, strands the remainder —
    ///      the failure mode the offset exists to remove. Uses a LOOSE order
    ///      (small signed output) so the quarter-swap still covers the maker;
    ///      on a tight order the same mistake simply fails the fill instead,
    ///      which the next test pins.
    function test_patch_withoutOffsetTheSurplusStrands() public {
        Order memory o = _plainOrder(23, address(tA), address(tB), AMOUNT_IN, 20e18);
        bytes memory sig = _sign(o);
        aggSolver.executeFill(o, sig, AMOUNT_IN, _planFor(AMOUNT_IN / 4, address(aggSolver), 1, NO_PATCH), "");
        // Swept to the caller rather than stranded in the contract — but still
        // unswapped, which is the inefficiency `amountInOffset` removes.
        assertEq(tA.balanceOf(address(this)), (AMOUNT_IN * 3) / 4, "three quarters never routed");
    }

    /// @dev On a TIGHT order the under-quoted route cannot cover the maker's
    ///      signed output, so the fill reverts rather than short-paying them.
    ///      The maker is protected either way — the loss is the solver's.
    function test_patch_withoutOffsetOnTightOrder_failsTheFill() public {
        Order memory o = _order(26);
        bytes memory sig = _sign(o);
        RoutePlan memory under = _planFor(AMOUNT_IN / 4, address(aggSolver), 1, NO_PATCH);
        vm.expectRevert();
        aggSolver.executeFill(o, sig, AMOUNT_IN, under, "");
    }

    /// @dev An offset past the end of the blob is refused rather than written
    ///      out of bounds.
    function test_patch_offsetOutOfBounds_reverts() public {
        Order memory o = _order(24);
        bytes memory sig = _sign(o);
        RoutePlan memory bad = _planFor(AMOUNT_IN, address(aggSolver), 1, 9_999);
        vm.expectRevert();
        aggSolver.executeFill(o, sig, AMOUNT_IN, bad, "");
    }

    /// @dev NO_PATCH leaves the aggregator's bytes byte-for-byte intact, which is
    ///      the right default for a fixed-input SELL order.
    function test_patch_noPatchLeavesCalldataUntouched() public {
        Order memory o = _order(25);
        bytes memory sig = _sign(o);
        uint256 makerBefore = tB.balanceOf(maker);
        aggSolver.executeFill(o, sig, AMOUNT_IN, _planFor(AMOUNT_IN, address(aggSolver), AMOUNT_OUT, NO_PATCH), "");
        assertEq(tB.balanceOf(maker) - makerBefore, AMOUNT_OUT, "exact-quote route still fills");
    }
}

// ───────── pinning the output: capped pay, and the spread as profit ─────────

/// @dev `maxPay` closes the loop the resolved-amount problem opens on the output
///      side: the solver bounds what Settlement may take, and everything above it
///      is profit that was never approved away.
contract AggregatorPayCapTest is AggregatorFillSolverTest {
    function _capped(uint256 maxPay, address profitTo) internal view returns (RoutePlan memory p) {
        p = _planFor(AMOUNT_IN, address(aggSolver), 1, NO_PATCH);
        p.maxPay = maxPay;
        p.profitRecipient = profitTo;
    }

    /// @dev A cap at exactly the signed output fills, and approves nothing more.
    function test_cap_exactPayFills() public {
        Order memory o = _order(30);
        uint256 makerBefore = tB.balanceOf(maker);
        aggSolver.executeFill(o, _sign(o), AMOUNT_IN, _capped(AMOUNT_OUT, address(this)), "");
        assertEq(tB.balanceOf(maker) - makerBefore, AMOUNT_OUT, "maker paid exactly its price");
    }

    /// @dev A cap BELOW what the order prices reverts — the solver refuses the
    ///      fill rather than discovering the overpay in its P&L afterwards.
    function test_cap_belowPrice_revertsTheFill() public {
        Order memory o = _order(31);
        bytes memory sig = _sign(o);
        RoutePlan memory tight = _capped(AMOUNT_OUT - 1, address(this));
        vm.expectRevert();
        aggSolver.executeFill(o, sig, AMOUNT_IN, tight, "");
    }

    /// @dev THE ALLOWANCE PROPERTY. With a cap, Settlement is never approved over
    ///      the spread — so no allowance survives the fill against the solver's
    ///      own profit, which an approve-everything callback would leave behind.
    function test_cap_leavesNoResidualAllowance() public {
        Order memory o = _order(32);
        aggSolver.executeFill(o, _sign(o), AMOUNT_IN, _capped(AMOUNT_OUT, address(this)), "");
        assertEq(tB.allowance(address(aggSolver), address(settlement)), 0, "no allowance over the spread");
    }

    /// @dev The spread lands where the plan said, not in the contract.
    function test_cap_profitGoesToTheNamedRecipient() public {
        address treasury = address(0x7EA5);
        Order memory o = _order(33);
        aggSolver.executeFill(o, _sign(o), AMOUNT_IN, _capped(AMOUNT_OUT, treasury), "");
        assertEq(tB.balanceOf(treasury), AMOUNT_IN - AMOUNT_OUT, "treasury got the spread");
        assertEq(tB.balanceOf(address(aggSolver)), 0, "contract holds nothing after");
    }

    /// @dev `address(0)` pays the caller — whoever executed and carried the risk.
    function test_cap_zeroRecipientPaysTheCaller() public {
        address filler = address(0xF111E5);
        Order memory o = _order(34);
        bytes memory sig = _sign(o);
        RoutePlan memory plan = _capped(AMOUNT_OUT, address(0));
        vm.prank(filler);
        aggSolver.executeFill(o, sig, AMOUNT_IN, plan, "");
        assertEq(tB.balanceOf(filler), AMOUNT_IN - AMOUNT_OUT, "caller keeps the spread");
    }

    /// @dev `maxPay = 0` keeps the old approve-everything behaviour. It is safe
    ///      only because the maker's signed band is the hard bound either way —
    ///      the cap is a tighter solver-side guard, not the thing preventing an
    ///      overpay.
    function test_cap_zeroMeansNoCap() public {
        Order memory o = _order(35);
        uint256 makerBefore = tB.balanceOf(maker);
        aggSolver.executeFill(o, _sign(o), AMOUNT_IN, _capped(0, address(this)), "");
        assertEq(tB.balanceOf(maker) - makerBefore, AMOUNT_OUT, "maker still capped by its own band");
    }
}

// ───────────────── the permissionless-entrypoint boundary ─────────────────

/// @title AggregatorSolverHostileCallerTest
/// @notice `executeFill` is permissionless BY DESIGN, so every gate that guards
///         `onFill` must survive an attacker who simply calls it himself with an
///         order he signed as his own maker. Each test here is a PoC that landed
///         before the fix and is now the regression that pins it.
///
///         The shape of the attack is always the same and costs one wei of a
///         token the attacker minted: arm the callback with a throwaway order,
///         then use the armed frame to reach something that is not this fill's.
contract AggregatorSolverHostileCallerTest is AggregatorFillSolverTest {
    uint256 evePk = 0xE5E;
    address eve = vm.addr(evePk);

    /// @dev A throwaway 1-wei order with `eve` as maker AND filler. The cheapest
    ///      way to arm `onFill`, and the reason the arming flag authorises nothing.
    function _eveOrder(uint256 nonce, address tokenIn, address tokenOut, uint256 amtIn, uint256 amtOut)
        internal
        returns (Order memory o, bytes memory sig)
    {
        tA.mint(eve, 1);
        vm.startPrank(eve);
        tA.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(tA), type(uint160).max, 0);
        vm.stopPrank();
        o = _plainOrder(nonce, tokenIn, tokenOut, amtIn, amtOut);
        o.maker = eve;
        sig = _signWith(o, evePk);
    }

    function _evePlan(address to, bytes memory data) internal view returns (RoutePlan memory) {
        return RoutePlan({
            router: address(router),
            minOut: 0,
            maxPay: 0,
            amountInOffset: NO_PATCH,
            profitRecipient: to,
            originator: address(0),
            originatorPpm: 0,
            data: data
        });
    }

    /// @dev THE SWEEP IS A DELTA. Residue parked here by an unrelated fill is not
    ///      this caller's, and a whole-balance sweep would have made it a
    ///      signature-free withdrawal for whoever asks first.
    function test_agg_residueIsNotSweepableByAStranger() public {
        tC.mint(address(aggSolver), 50_000e18); // left by some earlier fill
        (Order memory o, bytes memory sig) = _eveOrder(41, address(tA), address(tC), 1, 0);

        // A route that genuinely SUCCEEDS, so the sweep is reached: swap eve's one
        // wei of tA. The residue is tC, which this route never touches.
        bytes memory route = abi.encodeCall(MockRouter.swap, (1, address(aggSolver)));

        vm.prank(eve);
        aggSolver.executeFill(o, sig, 1, _evePlan(eve, route), "");

        assertEq(tC.balanceOf(eve), 0, "eve took nothing");
        assertEq(tC.balanceOf(address(aggSolver)), 50_000e18, "residue untouched");
    }

    /// @dev And it cannot be taken through the FRONT door either: `maxPay == 0`
    ///      approves this fill's proceeds, not the balance, so an order demanding
    ///      the residue as its output finds no allowance behind it.
    function test_agg_residueIsNotDeliverableAsOutput() public {
        tC.mint(address(aggSolver), 50_000e18);
        (Order memory o, bytes memory sig) = _eveOrder(42, address(tA), address(tC), 1, 50_000e18);

        vm.prank(eve);
        vm.expectRevert();
        aggSolver.executeFill(o, sig, 1, _evePlan(eve, ""), "");

        assertEq(tC.balanceOf(address(aggSolver)), 50_000e18, "residue untouched");
    }

    /// @dev THE ROUTER ALLOWLIST is the gate that authorises the raw call. Without
    ///      it, an armed frame is an "invoke anything as this contract" primitive:
    ///      `transferFrom` against anyone who approved the solver,
    ///      `PERMIT3.approveToken`, `SETTLEMENT.setOrderSigner`, …
    function test_agg_arbitraryRouterIsRejected() public {
        Puppet puppet = new Puppet();
        (Order memory o, bytes memory sig) = _eveOrder(43, address(tA), address(tB), 1, 0);
        RoutePlan memory p = _evePlan(eve, abi.encodeWithSignature("anything()"));
        p.router = address(puppet);

        vm.prank(eve);
        vm.expectRevert();
        aggSolver.executeFill(o, sig, 1, p, "");

        assertEq(puppet.calls(), 0, "the solver's identity was never lent out");
    }

    /// @dev A `legsOut` blob declaring ZERO legs still has readable bytes behind it
    ///      — {PackedArraysMem} does not consult the count and
    ///      {PackedArrays.validateFixed} tolerates the trailing bytes, so the fill
    ///      itself delivers nothing while the token read here is whatever the
    ///      attacker wrote. Rejecting the empty blob is what closes that seam.
    function test_agg_zeroLegBlobIsRejected() public {
        (Order memory o, bytes memory sig) = _eveOrder(44, address(tA), address(tB), 1, 0);
        // count byte 0, then a well-formed element naming tC.
        bytes memory legs = o.legsOut;
        legs[0] = 0x00;
        o.legsOut = legs;
        sig = _signWith(o, evePk);

        vm.prank(eve);
        vm.expectRevert(AggregatorFillSolver.NoLegs.selector);
        aggSolver.executeFill(o, sig, 1, _evePlan(eve, ""), "");
    }

    /// @dev The allowlist may not name a protocol contract — that would hand back
    ///      exactly the authority it exists to remove.
    function test_agg_constructorRejectsProtocolRouters() public {
        address[] memory rs = new address[](1);
        rs[0] = address(settlement);
        vm.expectRevert(abi.encodeWithSelector(AggregatorFillSolver.RouterIsProtocol.selector, address(settlement)));
        new AggregatorFillSolver(address(settlement), rs, _noSplit());

        rs[0] = address(permit3);
        vm.expectRevert(abi.encodeWithSelector(AggregatorFillSolver.RouterIsProtocol.selector, address(permit3)));
        new AggregatorFillSolver(address(settlement), rs, _noSplit());
    }
}

/// @dev Records that it was called at all — the assertion an arbitrary-call PoC
///      needs is "the solver never spoke to me".
contract Puppet {
    uint256 public calls;

    fallback() external payable {
        calls++;
    }
}

// ───────────── surplus capture: maker, protocol, originator, filler ─────────────

/// @title AggregatorSurplusSplitTest
/// @notice The {SurplusPolicy}: everything the route produced ABOVE the maker's
///         signed price is split — price improvement back to the maker, a share
///         to the protocol / route provider, an optional originator share out of
///         the filler's remainder, and the rest to the filler. The maker's signed
///         delivery is untouched by any of it: the split only ever moves the
///         spread.
///
///         Numbers: the order sells 100 A for 90 B; the router pays 1:1, so the
///         spread is 10 B. Policy: 50% maker, 10% protocol.
contract AggregatorSurplusSplitTest is AggregatorFillSolverTest {
    address constant PROTOCOL = address(0x9407);
    address constant ORIGINATOR = address(0x0816);
    address constant FILLER = address(0xF111E5);

    uint32 constant MAKER_PPM = 500_000; // 50%
    uint32 constant PROTOCOL_PPM = 100_000; // 10%
    uint256 constant SPREAD = AMOUNT_IN - AMOUNT_OUT; // 10e18

    AggregatorFillSolver splitSolver;

    function setUp() public override {
        super.setUp();
        splitSolver = new AggregatorFillSolver(
            address(settlement),
            _routers(address(router)),
            SurplusPolicy({makerPpm: MAKER_PPM, protocolPpm: PROTOCOL_PPM, protocolRecipient: PROTOCOL})
        );
        vm.label(address(splitSolver), "splitSolver");
    }

    function _splitPlan(address originator, uint32 originatorPpm) internal view returns (RoutePlan memory p) {
        p = _planFor(AMOUNT_IN, address(splitSolver), AMOUNT_OUT, NO_PATCH);
        p.originator = originator;
        p.originatorPpm = originatorPpm;
    }

    /// @dev The policy is a property of the deployment, readable on chain.
    function test_split_policyIsImmutableAndReadable() public view {
        assertEq(splitSolver.MAKER_SURPLUS_PPM(), MAKER_PPM);
        assertEq(splitSolver.PROTOCOL_SURPLUS_PPM(), PROTOCOL_PPM);
        assertEq(splitSolver.PROTOCOL_RECIPIENT(), PROTOCOL);
    }

    /// @dev THE MECHANIC. The maker gets its signed 90 B PLUS 50% of the 10 B
    ///      spread; the protocol 10%; the filler the remaining 40%. Nothing stays
    ///      in the contract.
    function test_split_makerProtocolFiller() public {
        Order memory o = _order(50);
        bytes memory sig = _sign(o);
        RoutePlan memory plan = _splitPlan(address(0), 0);
        uint256 makerBefore = tB.balanceOf(maker);

        vm.expectEmit(true, true, false, true, address(splitSolver));
        emit AggregatorFillSolver.SurplusSplit(address(tB), maker, 5e18, 1e18, 0, 4e18);
        vm.prank(FILLER);
        splitSolver.executeFill(o, sig, AMOUNT_IN, plan, "");

        assertEq(tB.balanceOf(maker) - makerBefore, AMOUNT_OUT + 5e18, "maker: signed price + 50% improvement");
        assertEq(tB.balanceOf(PROTOCOL), 1e18, "protocol: 10% of the spread");
        assertEq(tB.balanceOf(FILLER), 4e18, "filler: the remainder");
        assertEq(tB.balanceOf(address(splitSolver)), 0, "nothing strands");
    }

    /// @dev The originator's share comes OUT OF THE FILLER'S remainder: maker and
    ///      protocol are unchanged by it.
    function test_split_originatorIsCarvedFromTheFiller() public {
        Order memory o = _order(51);
        bytes memory sig = _sign(o);
        RoutePlan memory plan = _splitPlan(ORIGINATOR, 200_000); // 20%
        uint256 makerBefore = tB.balanceOf(maker);

        vm.prank(FILLER);
        splitSolver.executeFill(o, sig, AMOUNT_IN, plan, "");

        assertEq(tB.balanceOf(maker) - makerBefore, AMOUNT_OUT + 5e18, "maker unchanged by the originator share");
        assertEq(tB.balanceOf(PROTOCOL), 1e18, "protocol unchanged by the originator share");
        assertEq(tB.balanceOf(ORIGINATOR), 2e18, "originator: 20%");
        assertEq(tB.balanceOf(FILLER), 2e18, "filler: 40% - 20%");
    }

    /// @dev A caller can give away exactly its remainder and no more. Checked
    ///      BEFORE the fill, so the round fails without moving the maker's funds.
    function test_split_originatorCannotExceedTheRemainder() public {
        Order memory o = _order(52);
        bytes memory sig = _sign(o);
        RoutePlan memory ok = _splitPlan(ORIGINATOR, uint32(PPM) - MAKER_PPM - PROTOCOL_PPM); // exactly the remainder
        RoutePlan memory over = _splitPlan(ORIGINATOR, uint32(PPM) - MAKER_PPM - PROTOCOL_PPM + 1);

        uint256 makerBefore = tA.balanceOf(maker);
        vm.expectRevert(AggregatorFillSolver.BadSurplusSplit.selector);
        splitSolver.executeFill(o, sig, AMOUNT_IN, over, "");
        assertEq(tA.balanceOf(maker), makerBefore, "nothing moved");

        vm.prank(FILLER);
        splitSolver.executeFill(o, sig, AMOUNT_IN, ok, "");
        assertEq(tB.balanceOf(ORIGINATOR), 4e18, "originator took the whole remainder");
        assertEq(tB.balanceOf(FILLER), 0, "filler gave it all away");
    }

    /// @dev A non-zero share must have somewhere to go.
    function test_split_originatorShareNeedsARecipient() public {
        Order memory o = _order(53);
        bytes memory sig = _sign(o);
        RoutePlan memory plan = _splitPlan(address(0), 1);
        vm.expectRevert(AggregatorFillSolver.BadSurplusSplit.selector);
        splitSolver.executeFill(o, sig, AMOUNT_IN, plan, "");
    }

    /// @dev No surplus, no split: a route quoted exactly at the maker's price
    ///      pays the maker its signed amount and nobody else anything.
    function test_split_noSurplusNothingMoves() public {
        router.setRate(9_000); // 100 A → 90 B: exactly the signed price
        Order memory o = _order(54);
        bytes memory sig = _sign(o);
        uint256 makerBefore = tB.balanceOf(maker);
        vm.prank(FILLER);
        splitSolver.executeFill(o, sig, AMOUNT_IN, _splitPlan(ORIGINATOR, 100_000), "");
        assertEq(tB.balanceOf(maker) - makerBefore, AMOUNT_OUT, "maker: signed price only");
        assertEq(tB.balanceOf(PROTOCOL), 0);
        assertEq(tB.balanceOf(ORIGINATOR), 0);
        assertEq(tB.balanceOf(FILLER), 0);
    }

    /// @dev `maxPay` and the split compose: the cap bounds what Settlement pulls,
    ///      the split governs what is left. The filler's `profitRecipient` is where
    ///      ITS share goes — not the whole spread.
    function test_split_respectsProfitRecipient() public {
        address treasury = address(0x7EA5);
        Order memory o = _order(55);
        bytes memory sig = _sign(o);
        RoutePlan memory plan = _splitPlan(address(0), 0);
        plan.maxPay = AMOUNT_OUT;
        plan.profitRecipient = treasury;
        vm.prank(FILLER);
        splitSolver.executeFill(o, sig, AMOUNT_IN, plan, "");
        assertEq(tB.balanceOf(treasury), 4e18, "filler share to the named recipient");
        assertEq(tB.balanceOf(FILLER), 0, "caller got nothing directly");
        assertEq(tB.balanceOf(PROTOCOL), 1e18);
    }

    /// @dev Rounding dust goes to the filler with its remainder — never strands.
    function test_split_roundingDustGoesToTheFiller() public {
        // 100 A → 90 B + 7 wei: a spread of 10e18 + 7 whose 50%/10% shares floor.
        router.setRate(10_000);
        tB.mint(address(router), 7);
        Order memory o = _plainOrder(56, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT - 7);
        bytes memory sig = _sign(o);
        uint256 makerBefore = tB.balanceOf(maker);
        vm.prank(FILLER);
        splitSolver.executeFill(o, sig, AMOUNT_IN, _splitPlan(address(0), 0), "");
        uint256 spread = SPREAD + 7;
        uint256 toMaker = (spread * MAKER_PPM) / PPM;
        uint256 toProtocol = (spread * PROTOCOL_PPM) / PPM;
        assertEq(tB.balanceOf(maker) - makerBefore, AMOUNT_OUT - 7 + toMaker);
        assertEq(tB.balanceOf(PROTOCOL), toProtocol);
        assertEq(tB.balanceOf(FILLER), spread - toMaker - toProtocol, "filler absorbs the rounding");
        assertEq(tB.balanceOf(address(splitSolver)), 0, "nothing strands");
    }

    /// @dev Policy validation at construction.
    function test_split_constructorRejectsBadPolicy() public {
        address[] memory rs = _routers(address(router));
        vm.expectRevert(AggregatorFillSolver.BadSurplusSplit.selector);
        new AggregatorFillSolver(
            address(settlement), rs, SurplusPolicy({makerPpm: 600_000, protocolPpm: 400_001, protocolRecipient: PROTOCOL})
        );
        vm.expectRevert(AggregatorFillSolver.BadSurplusSplit.selector);
        new AggregatorFillSolver(
            address(settlement), rs, SurplusPolicy({makerPpm: 0, protocolPpm: 1, protocolRecipient: address(0)})
        );
        // The boundary is allowed: 100% away from the filler.
        new AggregatorFillSolver(
            address(settlement), rs, SurplusPolicy({makerPpm: 600_000, protocolPpm: 400_000, protocolRecipient: PROTOCOL})
        );
    }

    /// @dev The zero policy is the pre-existing behaviour: the whole spread to the
    ///      filler, no event-visible shares elsewhere.
    function test_split_zeroPolicyIsTheOldBehaviour() public {
        Order memory o = _order(57);
        bytes memory sig = _sign(o);
        RoutePlan memory plan = _plan(address(aggSolver), AMOUNT_OUT);
        vm.expectEmit(true, true, false, true, address(aggSolver));
        emit AggregatorFillSolver.SurplusSplit(address(tB), maker, 0, 0, 0, SPREAD);
        vm.prank(FILLER);
        aggSolver.executeFill(o, sig, AMOUNT_IN, plan, "");
        assertEq(tB.balanceOf(FILLER), SPREAD);
    }
}
