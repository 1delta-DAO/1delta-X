// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Order, CallbackMode} from "@core/settlement/Settlement.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {SolverCallbackExecutor} from "@core/settlement/SolverCallbackExecutor.sol";
import {OrderGates} from "@core/settlement/OrderGates.sol";
import {Base} from "@core/settlement/Base.sol";
import {Proportional} from "@core/settlement/Proportional.sol";
import {LegOut} from "@core/settlement/Structs.sol";
import {
    AggregatorFillSolver,
    RoutePlan,
    FillRoute,
    SurplusPolicy,
    NO_PATCH,
    PPM
} from "@solvers/aggregator/AggregatorFillSolver.sol";

import {MockSettlementBase, MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";

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

    /// @notice Exact-output: pull only the input `amountOut` costs at the current
    ///         rate, capped at `maxIn`, and pay `amountOut` to `recipient`. The
    ///         direct-delivery shape, where the unspent input is the spread.
    function swapExactOut(uint256 amountOut, uint256 maxIn, address recipient) external {
        uint256 amountIn = (amountOut * 10_000 + rateBps - 1) / rateBps;
        require(amountIn <= maxIn, "too much in");
        SafeTransferLib.safeTransferFrom(TOKEN_IN, msg.sender, address(this), amountIn);
        SafeTransferLib.safeTransfer(TOKEN_OUT, recipient, amountOut);
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
        aggSolver = new AggregatorFillSolver(address(settlement), _routers(address(router)), _open(), _noSplit(), false, _none());
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

    /// @dev The empty operator set: `executeFill` open to anyone, which is the
    ///      shape every test outside {AggregatorOperatorGateTest} assumes.
    function _open() internal pure returns (address[] memory) {
        return new address[](0);
    }

    /// @dev The operator set a STANDING instance is built with. Standing instances
    ///      must be gated ({AggregatorFillSolver.StandingNeedsOperators}, re-audit
    ///      F30), so the suites that drive one name every caller they use: this test
    ///      contract, the `0xD00D` bystander, and the `0xE7E` account the bound
    ///      suite plays as a careless operator.
    function _standingOps() internal view returns (address[] memory ops) {
        ops = new address[](3);
        ops[0] = address(this);
        ops[1] = address(0xD00D);
        ops[2] = vm.addr(0xE7E);
    }

    /// @dev No tokens to prime — the per-fill-approval instance every test but
    ///      {AggregatorStandingAllowanceTest} uses.
    function _none() internal pure returns (address[] memory) {
        return new address[](0);
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

    /// @dev The same order signed for DIRECT delivery (`timing` bit 104): the
    ///      core verifies the maker's balance delta instead of pulling from us.
    ///      Names `aggSolver` as the exclusive filler — the settler fills a
    ///      delta-verify order for its named filler ONLY (re-audit 2026-09-25).
    function _directOrder(uint256 nonce) internal view returns (Order memory o) {
        o = _order(nonce);
        o.timing |= uint256(1) << 104;
        o.exclusiveFiller = address(aggSolver);
    }

    /// @dev An exact-output route paying `amountOut` to `recipient` out of at most
    ///      `maxIn` — what a direct-delivery quote looks like.
    function _exactOutPlan(uint256 amountOut, uint256 maxIn, address recipient)
        internal
        view
        returns (RoutePlan memory p)
    {
        p = _planFor(AMOUNT_IN, recipient, 0, NO_PATCH);
        p.data = abi.encodeCall(MockRouter.swapExactOut, (amountOut, maxIn, recipient));
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

    /// @dev With an empty operator set anyone may call `executeFill` — the
    ///      security boundary is the maker's signature, not an operator list.
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
                direct: false,
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
                direct: false,
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
                direct: false,
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
        new AggregatorFillSolver(address(settlement), rs, _open(), _noSplit(), false, _none());

        rs[0] = address(permit3);
        vm.expectRevert(abi.encodeWithSelector(AggregatorFillSolver.RouterIsProtocol.selector, address(permit3)));
        new AggregatorFillSolver(address(settlement), rs, _open(), _noSplit(), false, _none());
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
            _open(),
            SurplusPolicy({makerPpm: MAKER_PPM, protocolPpm: PROTOCOL_PPM, protocolRecipient: PROTOCOL}),
            false,
            _none()
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

    /// @dev THE INPUT SIDE IS SPLIT TOO (F28, 2026-09-12). A route that consumes
    ///      only a quarter of the input — the exact-output shape a caller could
    ///      use to move the whole spread into unspent `tokenIn`, where the old
    ///      `_sweepDelta` handed it 100% to the filler — now splits the residue by
    ///      the same policy, in `tokenIn` units. Numbers: loose order 100 A → 20 B;
    ///      quoted 25 A → 25 B at 1:1. Output spread 5 B, input residue 75 A.
    function test_split_inputResidueIsSplitByTheSamePolicy() public {
        Order memory o = _plainOrder(55, address(tA), address(tB), AMOUNT_IN, 20e18);
        bytes memory sig = _sign(o);
        RoutePlan memory plan = _planFor(AMOUNT_IN / 4, address(splitSolver), 1, NO_PATCH);
        uint256 makerA = tA.balanceOf(maker);
        uint256 makerB = tB.balanceOf(maker);

        vm.prank(FILLER);
        splitSolver.executeFill(o, sig, AMOUNT_IN, plan, "");

        // output spread 5 B: 50% / 10% / 40%
        assertEq(tB.balanceOf(maker) - makerB, 20e18 + 2.5e18, "maker: signed + 50% of the B spread");
        assertEq(tB.balanceOf(PROTOCOL), 0.5e18, "protocol: 10% of the B spread");
        assertEq(tB.balanceOf(FILLER), 2e18, "filler: 40% of the B spread");
        // input residue 75 A: the same 50% / 10% / 40%, not 100% to the filler
        assertEq(makerA - tA.balanceOf(maker), AMOUNT_IN - 37.5e18, "maker: paid 100 A, 50% of the unspent 75 A back");
        assertEq(tA.balanceOf(PROTOCOL), 7.5e18, "protocol: 10% of the unspent input");
        assertEq(tA.balanceOf(FILLER), 30e18, "filler: 40% of the unspent input");
        assertEq(tA.balanceOf(address(splitSolver)), 0, "no A strands");
        assertEq(tB.balanceOf(address(splitSolver)), 0, "no B strands");
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
            address(settlement), rs, _open(), SurplusPolicy({makerPpm: 600_000, protocolPpm: 400_001, protocolRecipient: PROTOCOL}), false, _none()
        );
        vm.expectRevert(AggregatorFillSolver.BadSurplusSplit.selector);
        new AggregatorFillSolver(
            address(settlement), rs, _open(), SurplusPolicy({makerPpm: 0, protocolPpm: 1, protocolRecipient: address(0)}), false, _none()
        );
        // The boundary is allowed: 100% away from the filler.
        new AggregatorFillSolver(
            address(settlement), rs, _open(), SurplusPolicy({makerPpm: 600_000, protocolPpm: 400_000, protocolRecipient: PROTOCOL}), false, _none()
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

/// @title AggregatorOperatorGateTest
/// @notice The immutable operator set: a ring-fence on WHO may drive this
///         instance, and the reason it exists — an order that names the solver
///         contract as its exclusive filler is only exclusive to the operators
///         if the contract itself is gated.
contract AggregatorOperatorGateTest is AggregatorFillSolverTest {
    address constant OPERATOR = address(0x0Be7A);
    address constant STRANGER = address(0xD00D);

    AggregatorFillSolver gated;

    function setUp() public override {
        super.setUp();
        address[] memory ops = new address[](1);
        ops[0] = OPERATOR;
        gated = new AggregatorFillSolver(address(settlement), _routers(address(router)), ops, _noSplit(), false, _none());
        vm.label(address(gated), "gatedSolver");
    }

    function test_gate_flagsReflectConstructor() public view {
        assertTrue(gated.GATED(), "non-empty set gates");
        assertTrue(gated.isOperator(OPERATOR));
        assertFalse(gated.isOperator(STRANGER));
        assertFalse(aggSolver.GATED(), "empty set stays open");
    }

    /// @dev The gate runs before {_plan}, so a stranger is refused before any
    ///      balance is read or token moves.
    function test_gate_strangerReverts() public {
        Order memory o = _order(1);
        bytes memory sig = _sign(o);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(AggregatorFillSolver.NotOperator.selector, STRANGER));
        gated.executeFill(o, sig, AMOUNT_IN, _plan(address(gated), AMOUNT_OUT), "");
        assertEq(tB.balanceOf(maker), 0, "nothing settled");
    }

    /// @dev The operator's fill is the ordinary permissionless fill in every
    ///      other respect: same route, same delivery, same spread to the caller.
    function test_gate_operatorFills() public {
        Order memory o = _order(2);
        bytes memory sig = _sign(o);
        vm.prank(OPERATOR);
        gated.executeFill(o, sig, AMOUNT_IN, _plan(address(gated), AMOUNT_OUT), "");
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "maker paid");
        assertEq(tB.balanceOf(OPERATOR), AMOUNT_IN - AMOUNT_OUT, "operator keeps the spread");
        assertEq(tB.balanceOf(address(gated)), 0, "no output retained");
    }

    /// @dev THE POINT OF THE GATE. `exclusiveFiller` is compared to the fill's
    ///      `msg.sender`, which is the solver CONTRACT. On the open instance a
    ///      stranger routing through it therefore passes the maker's exclusivity
    ///      gate; on the gated instance the same stranger is stopped one call
    ///      earlier, so "exclusive to this solver" means "exclusive to its
    ///      operators".
    function test_gate_exclusiveFillerIsOnlyExclusiveWhenGated() public {
        // Open instance: the stranger fills an order exclusive to the contract.
        Order memory open = _order(3);
        open.exclusiveFiller = address(aggSolver);
        _setExclusivityEnd(open, block.timestamp + 1 hours);
        bytes memory sigOpen = _sign(open);
        vm.prank(STRANGER);
        aggSolver.executeFill(open, sigOpen, AMOUNT_IN, _plan(address(aggSolver), AMOUNT_OUT), "");
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "stranger filled through the open instance");

        // Gated instance: the same shape, same stranger, refused.
        Order memory g = _order(4);
        g.exclusiveFiller = address(gated);
        _setExclusivityEnd(g, block.timestamp + 1 hours);
        bytes memory sigG = _sign(g);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(AggregatorFillSolver.NotOperator.selector, STRANGER));
        gated.executeFill(g, sigG, AMOUNT_IN, _plan(address(gated), AMOUNT_OUT), "");

        // ...and the operator, being the contract's caller, passes both gates.
        vm.prank(OPERATOR);
        gated.executeFill(g, sigG, AMOUNT_IN, _plan(address(gated), AMOUNT_OUT), "");
        assertEq(tB.balanceOf(maker), 2 * AMOUNT_OUT, "operator filled the exclusive order");
    }

    /// @dev A direct fill by the operator EOA is still refused by the core's
    ///      exclusivity gate — the order names the contract, not the operator.
    ///      Documents that the gate composes with, rather than replaces, core.
    function test_gate_operatorCannotBypassContract() public {
        Order memory g = _order(5);
        g.exclusiveFiller = address(gated);
        _setExclusivityEnd(g, block.timestamp + 1 hours);
        bytes memory sig = _sign(g);
        vm.prank(OPERATOR);
        vm.expectRevert(OrderGates.NotExclusiveFiller.selector);
        settlement.fill(g, sig, AMOUNT_IN);
    }

    /// @dev The sets are immutables with {MAX_SET} slots: an empty router set and
    ///      an oversized set of either kind are refused at construction, and every
    ///      entry of a partially-filled set is a member.
    function test_gate_setSizes() public {
        address[] memory none = new address[](0);
        vm.expectRevert(AggregatorFillSolver.BadSetSize.selector);
        new AggregatorFillSolver(address(settlement), none, none, _noSplit(), false, _none());

        address[] memory five = new address[](5);
        for (uint256 i; i < 5; i++) five[i] = address(bytes20(keccak256(abi.encode("r", i))));
        vm.expectRevert(AggregatorFillSolver.BadSetSize.selector);
        new AggregatorFillSolver(address(settlement), five, none, _noSplit(), false, _none());
        vm.expectRevert(AggregatorFillSolver.BadSetSize.selector);
        new AggregatorFillSolver(address(settlement), _routers(address(router)), five, _noSplit(), false, _none());

        address[] memory two = new address[](2);
        two[0] = address(router);
        two[1] = address(0xBEEF);
        address[] memory four = new address[](4);
        for (uint256 i; i < 4; i++) four[i] = address(bytes20(keccak256(abi.encode("o", i))));
        AggregatorFillSolver s = new AggregatorFillSolver(address(settlement), two, four, _noSplit(), false, _none());
        assertTrue(s.isAllowedRouter(address(router)));
        assertTrue(s.isAllowedRouter(address(0xBEEF)));
        assertFalse(s.isAllowedRouter(address(0xCAFE)));
        assertFalse(s.isAllowedRouter(address(0)), "unused slots repeat entry 0, never zero");
        for (uint256 i; i < 4; i++) assertTrue(s.isOperator(four[i]));
        assertFalse(s.isOperator(address(0)));
        assertFalse(aggSolver.isOperator(address(this)), "open instance: nobody is an operator");
    }

    function test_gate_constructorRejectsZeroOperator() public {
        address[] memory ops = new address[](1);
        ops[0] = address(0);
        vm.expectRevert(AggregatorFillSolver.BadOperator.selector);
        new AggregatorFillSolver(address(settlement), _routers(address(router)), ops, _noSplit(), false, _none());
    }
}

/// @title AggregatorDirectDeliveryTest
/// @notice The direct-delivery path: on an order signed with `timing` bit 104
///         the route pays the maker itself, the core verifies the delta, and
///         this contract never approves Settlement nor touches `tokenOut`.
contract AggregatorDirectDeliveryTest is AggregatorFillSolverTest {
    /// @dev Direct (delta-verify) orders need a GATED instance since re-audit
    ///      2026-09-29 ({AggregatorFillSolver.DirectNeedsOperators}), so this suite
    ///      swaps the base's open `aggSolver` for one operated by this contract —
    ///      `_directOrder` names whatever `aggSolver` is.
    function setUp() public override {
        super.setUp();
        // `0xD00D` is the stranger the inherited `test_agg_fillIsPermissionless`
        // drives through; listed so that base test still exercises a fill here.
        address[] memory ops = new address[](2);
        ops[0] = address(this);
        ops[1] = address(0xD00D);
        aggSolver = new AggregatorFillSolver(address(settlement), _routers(address(router)), ops, _noSplit(), false, _none());
    }

    /// @dev The open instance refuses a direct order outright: naming it as the
    ///      filler would hand the delivery check to anyone who can call it.
    function test_direct_openInstanceIsRefused() public {
        AggregatorFillSolver open =
            new AggregatorFillSolver(address(settlement), _routers(address(router)), _open(), _noSplit(), false, _none());
        Order memory o = _directOrder(9);
        o.exclusiveFiller = address(open);
        bytes memory sig = _sign(o);
        vm.expectRevert(AggregatorFillSolver.DirectNeedsOperators.selector);
        open.executeFill(o, sig, AMOUNT_IN, _exactOutPlan(AMOUNT_OUT, AMOUNT_IN, maker), "");
    }

    /// @dev Exact-output route to the maker; the unspent input is the spread and
    ///      comes back to the caller in `tokenIn` units. No `tokenOut` ever lands
    ///      on the solver and no allowance to Settlement is ever set.
    function test_direct_exactOutputPaysMakerAndKeepsSpreadAsInput() public {
        Order memory o = _directOrder(1);
        bytes memory sig = _sign(o);
        uint256[] memory outs = aggSolver.executeFill(o, sig, AMOUNT_IN, _exactOutPlan(AMOUNT_OUT, AMOUNT_IN, maker), "");

        assertEq(outs[0], AMOUNT_OUT, "core reports the priced leg");
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "maker paid by the router directly");
        assertEq(tB.balanceOf(address(aggSolver)), 0, "no output ever here");
        assertEq(tA.balanceOf(address(this)), AMOUNT_IN - AMOUNT_OUT, "spread returned as unspent input");
        assertEq(tA.balanceOf(address(aggSolver)), 0, "no input left");
        assertEq(tB.allowance(address(aggSolver), address(settlement)), 0, "Settlement was never approved");
    }

    /// @dev A route quoted for the SOLVER (the pull-path habit) on a direct order
    ///      pays the wrong recipient: the core's delta check fails the whole fill,
    ///      and the tokens are back where they started.
    function test_direct_routeQuotedForSolver_failsDeltaCheck() public {
        Order memory o = _directOrder(2);
        bytes memory sig = _sign(o);
        vm.expectRevert(Base.DeltaTooLow.selector);
        aggSolver.executeFill(o, sig, AMOUNT_IN, _exactOutPlan(AMOUNT_OUT, AMOUNT_IN, address(aggSolver)), "");
        assertEq(tA.balanceOf(maker), 1_000e18, "maker untouched");
    }

    /// @dev Under-delivery is the core's revert, not this contract's: `minOut` is
    ///      not consulted on the direct path.
    function test_direct_underDelivery_isTheCoresRevert() public {
        Order memory o = _directOrder(3);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _exactOutPlan(AMOUNT_OUT - 1, AMOUNT_IN, maker);
        p.minOut = AMOUNT_OUT; // would be InsufficientOutput on the pull path
        vm.expectRevert(Base.DeltaTooLow.selector);
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "");
    }

    /// @dev Over-delivery is price improvement the maker keeps; the spread just
    ///      shrinks. An exact-input route works too, it merely gives up the spread.
    function test_direct_exactInputRoute_givesTheMakerEverything() public {
        Order memory o = _directOrder(4);
        bytes memory sig = _sign(o);
        aggSolver.executeFill(o, sig, AMOUNT_IN, _plan(maker, 0), "");
        assertEq(tB.balanceOf(maker), AMOUNT_IN, "the whole swap output went to the maker");
        assertEq(tA.balanceOf(address(this)), 0, "no spread left for the caller");
    }

    /// @dev The surplus policy still applies — in `tokenIn` units, on the residue.
    function test_direct_surplusPolicyAppliesToTheResidue() public {
        address[] memory ops = new address[](1);
        ops[0] = address(this); // direct orders need a gated instance
        AggregatorFillSolver split = new AggregatorFillSolver(
            address(settlement),
            _routers(address(router)),
            ops,
            SurplusPolicy({makerPpm: 500_000, protocolPpm: 0, protocolRecipient: address(0)}),
            false,
            _none()
        );
        Order memory o = _directOrder(5);
        o.exclusiveFiller = address(split);
        bytes memory sig = _sign(o);
        uint256 makerABefore = tA.balanceOf(maker);
        split.executeFill(o, sig, AMOUNT_IN, _exactOutPlan(AMOUNT_OUT, AMOUNT_IN, maker), "");
        uint256 spread = AMOUNT_IN - AMOUNT_OUT;
        // The maker paid AMOUNT_IN and got half the residue back, in the same token.
        assertEq(makerABefore - tA.balanceOf(maker), AMOUNT_IN - spread / 2, "maker's half of the residue, as price improvement");
        assertEq(tA.balanceOf(address(this)), spread - spread / 2, "caller's half");
    }

    /// @dev The order flag is what selects the path — the same route on an
    ///      unflagged order goes through the pull path and, quoted for the maker,
    ///      fails this contract's own output check as before.
    function test_direct_flagSelectsThePath() public {
        Order memory o = _order(6); // NOT flagged
        bytes memory sig = _sign(o);
        RoutePlan memory p = _exactOutPlan(AMOUNT_OUT, AMOUNT_IN, maker);
        p.minOut = AMOUNT_OUT;
        vm.expectRevert(
            _wrapped(abi.encodeWithSelector(AggregatorFillSolver.InsufficientOutput.selector, 0, AMOUNT_OUT))
        );
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "");
    }
}

/// @title AggregatorStandingAllowanceTest
/// @notice {AggregatorFillSolver.STANDING_ALLOWANCE}: fund routes from standing
///         approvals instead of writing an allowance slot twice per fill.
contract AggregatorStandingAllowanceTest is AggregatorFillSolverTest {
    AggregatorFillSolver internal standing;

    function _primeList() internal view returns (address[] memory t) {
        t = new address[](1);
        t[0] = address(tA);
    }

    function setUp() public override {
        super.setUp();
        standing =
            new AggregatorFillSolver(address(settlement), _routers(address(router)), _standingOps(), _noSplit(), true, _primeList());
        vm.label(address(standing), "standingSolver");
    }

    function test_standing_constructorPrimesTheGivenTokens() public view {
        assertTrue(standing.STANDING_ALLOWANCE(), "flag set");
        assertEq(tA.allowance(address(standing), address(router)), type(uint256).max, "primed at construction");
        assertFalse(aggSolver.STANDING_ALLOWANCE(), "the default instance approves per fill");
    }

    /// @dev The fill behaves identically and leaves the standing approval in
    ///      place — the whole point, and the property the default instance
    ///      deliberately does not have.
    function test_standing_fillsAndKeepsTheApproval() public {
        Order memory o = _order(1);
        bytes memory sig = _sign(o);
        standing.executeFill(o, sig, AMOUNT_IN, _plan(address(standing), AMOUNT_OUT), "");
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "maker paid as usual");
        assertEq(tA.allowance(address(standing), address(router)), type(uint256).max, "approval survives");
        assertEq(tA.balanceOf(address(standing)), 0, "no input stranded");
    }

    /// @dev DECLARED, NOT DISCOVERED: `onFill` never asks whether a token is
    ///      primed. An unprimed one fails at the router's own pull — the caller's
    ///      gas, nobody else's — and anyone may fix it permissionlessly.
    function test_standing_unprimedTokenFailsThenPrimeFixesIt() public {
        MockERC20 tC = new MockERC20("C");
        MockRouter r2 = new MockRouter(address(tC), address(tB));
        address[] memory rs = new address[](1);
        rs[0] = address(r2);
        AggregatorFillSolver s2 =
            new AggregatorFillSolver(address(settlement), rs, _standingOps(), _noSplit(), true, _none());

        tC.mint(maker, AMOUNT_IN);
        vm.startPrank(maker);
        tC.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(tC), uint160(AMOUNT_IN), 0);
        vm.stopPrank();
        tB.mint(address(r2), AMOUNT_OUT * 2);

        Order memory o = _plainOrder(2, address(tC), address(tB), AMOUNT_IN, AMOUNT_OUT);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _planFor(AMOUNT_IN, address(s2), AMOUNT_OUT, NO_PATCH);
        p.router = address(r2);
        p.data = abi.encodeCall(MockRouter.swap, (AMOUNT_IN, address(s2)));

        vm.expectRevert(); // the router cannot pull: nothing was ever approved
        s2.executeFill(o, sig, AMOUNT_IN, p, "");

        // Anyone repairs it, and the same fill then succeeds.
        vm.prank(address(0xD00D));
        s2.prime(address(tC));
        s2.executeFill(o, sig, AMOUNT_IN, p, "");
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "filled after priming");
    }

    /// @dev `prime` exists only on an instance that declared the trade-off, and a
    ///      deployment that names tokens without declaring it is refused rather
    ///      than silently downgraded.
    function test_standing_primeRefusedOnAPerFillInstance() public {
        vm.expectRevert(AggregatorFillSolver.NotStandingAllowance.selector);
        aggSolver.prime(address(tA));

        vm.expectRevert(AggregatorFillSolver.NotStandingAllowance.selector);
        new AggregatorFillSolver(address(settlement), _routers(address(router)), _open(), _noSplit(), false, _primeList());
    }

    /// @dev Priming covers EVERY router in the set, not just the first, and
    ///      tolerates a partially-filled set (whose unused slots repeat entry 0).
    function test_standing_primeCoversEveryRouter() public {
        MockRouter r2 = new MockRouter(address(tA), address(tB));
        address[] memory rs = new address[](2);
        rs[0] = address(router);
        rs[1] = address(r2);
        AggregatorFillSolver s2 =
            new AggregatorFillSolver(address(settlement), rs, _standingOps(), _noSplit(), true, _primeList());
        assertEq(tA.allowance(address(s2), address(router)), type(uint256).max);
        assertEq(tA.allowance(address(s2), address(r2)), type(uint256).max);
    }
}

/// @title AggregatorStaleApprovalTest
/// @notice Why `executeFill` clears its Settlement approval, PoC'd.
///
///  The clear is not a hedge against a buggy settler. It defends against
///  Settlement doing EXACTLY what it is specified to do — delivering an order's
///  output legs by pulling them from the filler — while the filler is this
///  contract and the order was signed by the attacker.
///
///  `onFill` approves Settlement for ONE token: `legsOut[0]`, the route's own
///  product, capped at this fill's proceeds. Every OTHER output leg is delivered
///  from whatever standing approval already exists. So a leftover approval on any
///  token this contract has traded before is directly spendable by a self-signed
///  order that names that token in a later leg — paired with the balance floor
///  and the retained spread the contract deliberately holds.
contract AggregatorStaleApprovalTest is AggregatorFillSolverTest {
    uint256 internal constant EVE_PK = 0xE7E;
    uint256 internal constant STALE = 500e18;

    /// @dev The residue an un-cleared fill would leave: a balance in a token the
    ///      solver has traded, and Settlement still approved over it.
    function _leaveStaleApproval(MockERC20 token) internal {
        token.mint(address(aggSolver), STALE);
        vm.prank(address(aggSolver));
        token.approve(address(settlement), STALE);
    }

    function test_stale_settlementApprovalIsDrainableByASelfSignedOrder() public {
        address eve = vm.addr(EVE_PK);
        MockERC20 tC = new MockERC20("C");
        _leaveStaleApproval(tC);

        // Eve funds her own order's input — she is a legitimate maker of her own
        // order, which is all this contract's permissionless entry requires.
        tA.mint(eve, AMOUNT_IN);
        vm.startPrank(eve);
        tA.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(tA), uint160(AMOUNT_IN), 0);
        vm.stopPrank();

        // Leg 0 is the route's product, so `onFill` approves that one freshly.
        // Leg 1 is the stranded token, delivered from the stale approval.
        address[] memory outs = new address[](2);
        outs[0] = address(tB);
        outs[1] = address(tC);
        uint256[] memory amts = new uint256[](2);
        amts[0] = AMOUNT_OUT;
        amts[1] = STALE;

        Order memory o = _plainOrderMultiOut(99, address(tA), AMOUNT_IN, outs, amts);
        o.maker = eve;
        bytes memory sig = _signWith(o, EVE_PK);

        vm.prank(eve);
        aggSolver.executeFill(o, sig, AMOUNT_IN, _plan(address(aggSolver), AMOUNT_OUT), "");

        assertEq(tC.balanceOf(eve), STALE, "the stale approval paid a stranger out of the solver's balance");
        assertEq(tC.balanceOf(address(aggSolver)), 0, "and the solver was emptied of it");
    }

    /// @dev "It holds nothing, so an allowance is worthless" — except the balance
    ///      is NOT under any single party's control, which is what makes the clear
    ///      structural rather than belt-and-braces.
    ///
    ///      `executeFill` is permissionless and `RoutePlan.profitRecipient` is
    ///      CALLER-SUPPLIED. A caller that names the solver keeps its share of the
    ///      spread here (retain mode), so one caller's choice leaves value on a
    ///      SHARED contract for the next caller's stale approval to find. Nobody
    ///      operating this instance can enforce "holds nothing" on anyone else.
    function test_stale_anyCallerCanLeaveValueOnTheSharedContract() public {
        assertEq(tB.balanceOf(address(aggSolver)), 0, "starts empty");
        Order memory o = _order(50);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _plan(address(aggSolver), AMOUNT_OUT);
        p.profitRecipient = address(aggSolver); // retain — any caller may ask for it

        vm.prank(address(0xD00D));
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "");

        assertEq(
            tB.balanceOf(address(aggSolver)),
            AMOUNT_IN - AMOUNT_OUT,
            "a stranger's fill parked the spread on the shared contract"
        );
        // …and the approval that paid this fill is nonetheless gone, which is the
        // only reason that balance is not now a standing target.
        assertEq(tB.allowance(address(aggSolver), address(settlement)), 0, "no approval outlived the fill");
    }

    /// @dev Anyone can also simply SEND tokens here. There is no permission to
    ///      refuse an ERC20 transfer, so "holds nothing" can never be an invariant
    ///      the contract enforces — only one it hopes for.
    function test_stale_anyoneCanDonateABalance() public {
        MockERC20 tC = new MockERC20("C");
        tC.mint(address(this), 1_000e18);
        tC.transfer(address(aggSolver), 1_000e18);
        assertEq(tC.balanceOf(address(aggSolver)), 1_000e18, "unsolicited, unrefusable");
    }

    /// @dev The control: with the clear in place no such approval can exist, so
    ///      the identical order finds nothing to spend and the fill reverts.
    function test_stale_withoutTheResidueTheSameOrderFails() public {
        address eve = vm.addr(EVE_PK);
        MockERC20 tC = new MockERC20("C");
        tC.mint(address(aggSolver), STALE); // balance, but NO approval — the invariant

        tA.mint(eve, AMOUNT_IN);
        vm.startPrank(eve);
        tA.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(tA), uint160(AMOUNT_IN), 0);
        vm.stopPrank();

        address[] memory outs = new address[](2);
        outs[0] = address(tB);
        outs[1] = address(tC);
        uint256[] memory amts = new uint256[](2);
        amts[0] = AMOUNT_OUT;
        amts[1] = STALE;

        Order memory o = _plainOrderMultiOut(98, address(tA), AMOUNT_IN, outs, amts);
        o.maker = eve;
        bytes memory sig = _signWith(o, EVE_PK);

        vm.prank(eve);
        vm.expectRevert();
        aggSolver.executeFill(o, sig, AMOUNT_IN, _plan(address(aggSolver), AMOUNT_OUT), "");
        assertEq(tC.balanceOf(address(aggSolver)), STALE, "balance alone is not reachable");
    }
}

/// @title AggregatorStandingAllowanceBoundTest
/// @notice What ELSE the per-fill approval was doing.
///
///  `forceApprove(tokenIn, router, amountIn)` was not only an approval, it was a
///  SECOND BOUND on the route: whatever figure the caller's calldata named, the
///  router could never pull more than the delta this fill actually delivered,
///  because the allowance was exactly that. `STANDING_ALLOWANCE` removes the
///  approval and therefore removes the bound, leaving only `_patched` — and the
///  caller chooses `amountInOffset`, so it can decline the patch ({NO_PATCH}) or
///  aim it at the wrong word.
contract AggregatorStandingAllowanceBoundTest is AggregatorFillSolverTest {
    AggregatorFillSolver internal standing;

    function setUp() public override {
        super.setUp();
        address[] memory prime = new address[](1);
        prime[0] = address(tA);
        standing =
            new AggregatorFillSolver(address(settlement), _routers(address(router)), _standingOps(), _noSplit(), true, prime);
        tB.mint(address(router), 10_000e18);
    }

    /// @dev Eve's own small order, a route quoting MORE input than it delivers,
    ///      and {NO_PATCH} so the quote is used verbatim. The excess can only come
    ///      out of what the solver was already holding. (Eve is an OPERATOR here —
    ///      a standing instance must be gated since F30, so this bound is now the
    ///      backstop against an operator's bad route, not a stranger's.)
    function test_bound_unpatchedRouteReachesTheSolversOwnBalance() public {
        uint256 parked = 400e18;
        tA.mint(address(standing), parked); // residue, floor, a donation - any of them

        address eve = vm.addr(0xE7E);
        uint256 evesInput = 10e18;
        tA.mint(eve, evesInput);
        vm.startPrank(eve);
        tA.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(tA), uint160(evesInput), 0);
        vm.stopPrank();

        Order memory o = _plainOrder(77, address(tA), address(tB), evesInput, 1);
        o.maker = eve;
        bytes memory sig = _signWith(o, 0xE7E);

        // The route claims to spend Eve's input PLUS everything parked here.
        RoutePlan memory p = _planFor(evesInput + parked, address(standing), 0, NO_PATCH);
        p.profitRecipient = eve;

        vm.prank(eve);
        vm.expectRevert(_wrapped(abi.encodeWithSelector(AggregatorFillSolver.RouteOverspent.selector)));
        standing.executeFill(o, sig, evesInput, p, "");

        assertEq(tA.balanceOf(address(standing)), parked, "the solver keeps what it was holding");
    }

    /// @dev The bound is a measurement, not a ban: a route that spends exactly
    ///      what the fill delivered passes, patched or not.
    function test_bound_routeThatSpendsOnlyTheFillPasses() public {
        tA.mint(address(standing), 400e18); // still parked, still untouchable

        address eve = vm.addr(0xE7E);
        uint256 evesInput = 10e18;
        tA.mint(eve, evesInput);
        vm.startPrank(eve);
        tA.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(tA), uint160(evesInput), 0);
        vm.stopPrank();

        Order memory o = _plainOrder(78, address(tA), address(tB), evesInput, 1);
        o.maker = eve;
        bytes memory sig = _signWith(o, 0xE7E);

        RoutePlan memory p = _planFor(evesInput, address(standing), 0, NO_PATCH);
        p.profitRecipient = eve;

        vm.prank(eve);
        standing.executeFill(o, sig, evesInput, p, "");
        assertEq(tA.balanceOf(address(standing)), 400e18, "only the fill's own input was spent");
    }
}

/// @notice Re-audit F30: the standing-allowance drain, and the constructor rule that
///         closes it.
///
///  On a standing instance every primed token carries a max approval to every
///  allowlisted router, and `onFill` forwards the CALLER's calldata to that router
///  as this contract. A route of `exactInputSingle(tokenIn = some primed token,
///  recipient = attacker)` therefore spends the standing approval on a token the
///  fill never touched — `RouteOverspent` watches only `tokenIn`, and a direct fill
///  skips the `tokenOut` measurement. The only fix that holds for arbitrary router
///  calldata is to make the calldata an operator's: standing ⇒ gated.
contract AggregatorStandingNeedsOperatorsTest is AggregatorFillSolverTest {
    function test_standing_openInstanceIsRefused() public {
        address[] memory prime = new address[](1);
        prime[0] = address(tA);
        vm.expectRevert(AggregatorFillSolver.StandingNeedsOperators.selector);
        new AggregatorFillSolver(address(settlement), _routers(address(router)), _open(), _noSplit(), true, prime);
    }

    /// @dev The per-fill-approval instance stays permissionless — its allowance IS
    ///      the bound, so an open instance there is fine.
    function test_standing_perFillInstanceMayStayOpen() public {
        AggregatorFillSolver open =
            new AggregatorFillSolver(address(settlement), _routers(address(router)), _open(), _noSplit(), false, _none());
        assertFalse(open.GATED(), "per-fill instance is open");
    }

    /// @dev On the gated standing instance a stranger cannot reach `onFill` at all,
    ///      so their calldata never runs with the standing approvals.
    function test_standing_strangerCannotDriveARoute() public {
        address[] memory prime = new address[](1);
        prime[0] = address(tA);
        AggregatorFillSolver st =
            new AggregatorFillSolver(address(settlement), _routers(address(router)), _standingOps(), _noSplit(), true, prime);
        tA.mint(address(st), 400e18); // the float a drain route would target

        Order memory o = _order(77);
        bytes memory sig = _sign(o);
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AggregatorFillSolver.NotOperator.selector, stranger));
        st.executeFill(o, sig, AMOUNT_IN, _plan(address(st), AMOUNT_OUT), "");
        assertEq(tA.balanceOf(address(st)), 400e18, "float untouched");
    }
}

/// @notice "Sell 100% of my balance" orders through the aggregator solver, with the
///         `type(uint256).max` any-size sentinel `fillWithCallback` honours since
///         2026-09-29 — and the fees an aggregator-routed fill takes along the way.
///
///  Why the sentinel is SAFE here and not for an inventory filler: a proportional
///  fill pays the maker's full signed output whatever the anchor resolves to, and
///  this solver never pays that output out of its own pocket. It swaps exactly the
///  input it MEASURED arriving (the route's amount patched from the balance delta)
///  and approves Settlement for no more than that swap produced. A balance that
///  shrank before inclusion therefore fails its own route — gas, not inventory —
///  while a balance that grew (up to the maker's cap) is a larger swap and a larger
///  spread, and every fee below is a share of THAT measured spread.
contract AggregatorProportionalSentinelTest is AggregatorSurplusSplitTest {
    uint256 constant CAP = 200e18;
    uint256 constant ANY = type(uint256).max;

    /// @dev "Sell 100% of my tA, at most CAP, for AMOUNT_OUT tB".
    function _propOrder(uint256 nonce) internal view returns (Order memory o) {
        o = _order(nonce);
        o.legsIn = PackedEncode.setLegInStart(o.legsIn, 0, Proportional.encode(10_000));
        o.legsIn = PackedEncode.setLegInEnd(o.legsIn, 0, CAP);
    }

    /// @dev Set the maker's live tA balance (setUp minted 1,000).
    function _makerHolds(uint256 amount) internal {
        uint256 bal = tA.balanceOf(maker);
        vm.prank(maker);
        tA.transfer(address(0xdead), bal - amount);
    }

    /// @dev A PATCHED route: `swap(amountIn, recipient)`'s amount is overwritten
    ///      with what the fill actually delivered (offset 4 = right after the
    ///      selector), so the route follows the resolved anchor.
    function _followingPlan(uint256 minOut) internal view returns (RoutePlan memory p) {
        p = _planFor(AMOUNT_IN, address(splitSolver), minOut, 4);
    }

    /// The balance GREW after the quote (100 → 150, under the 200 cap). The sentinel
    /// fills the whole 150; the route swaps 150; the spread is 60, and every fee —
    /// maker improvement, protocol share, originator carve-out — scales with it.
    function test_sentinel_grownBalance_fillsAndFeesScaleWithTheRealSize() public {
        _makerHolds(150e18);
        Order memory o = _propOrder(60);
        bytes memory sig = _sign(o);
        RoutePlan memory plan = _followingPlan(AMOUNT_OUT);
        plan.originator = ORIGINATOR;
        plan.originatorPpm = 200_000; // 20% of the spread, carved from the filler's share
        uint256 makerBefore = tB.balanceOf(maker);

        vm.prank(FILLER);
        splitSolver.executeFill(o, sig, ANY, plan, "");

        uint256 spread = 150e18 - AMOUNT_OUT; // 60
        assertEq(tA.balanceOf(maker), 0, "the whole live balance was sold");
        assertEq(tB.balanceOf(maker) - makerBefore, AMOUNT_OUT + spread / 2, "signed output + 50% improvement");
        assertEq(tB.balanceOf(PROTOCOL), spread / 10, "protocol fee: 10% of the REAL spread");
        assertEq(tB.balanceOf(ORIGINATOR), spread / 5, "originator: 20% of the REAL spread");
        assertEq(tB.balanceOf(FILLER), spread * 2 / 10, "filler: 40% - 20%");
        assertEq(tB.balanceOf(address(splitSolver)), 0, "nothing strands");
    }

    /// The balance SHRANK below the signed output (a maker front-running the fill,
    /// or an honest second order draining it). The route swaps what arrived (50),
    /// which cannot pay 90: the fill reverts and the solver loses nothing — even
    /// with `minOut = 0`, because Settlement is approved for no more than this
    /// swap produced. This is what makes the sentinel an ok opt-in for THIS filler.
    function test_sentinel_shrunkBalance_revertsAndTheSolverLosesNothing() public {
        tB.mint(address(splitSolver), 500e18); // retained inventory a naive filler would spend
        _makerHolds(50e18);
        Order memory o = _propOrder(61);
        bytes memory sig = _sign(o);

        vm.prank(FILLER);
        vm.expectRevert();
        splitSolver.executeFill(o, sig, ANY, _followingPlan(0), "");

        assertEq(tB.balanceOf(address(splitSolver)), 500e18, "the solver's own tB was never touched");
        assertEq(tA.balanceOf(maker), 50e18, "nothing moved");
    }

    /// The grief the sentinel removes: a stranger's 1-wei transfer to the maker
    /// after the quote. An exact-size fill of the quoted balance now reverts (the
    /// request is below the resolved anchor — a partial a proportional order
    /// refuses); the sentinel fills the drifted balance.
    function test_sentinel_oneWeiDonation_noLongerRevertsTheFill() public {
        _makerHolds(AMOUNT_IN);
        Order memory o = _propOrder(62);
        bytes memory sig = _sign(o);
        tA.mint(maker, 1); // the stranger

        vm.prank(FILLER);
        vm.expectRevert(Proportional.ProportionalNeedsFullFill.selector);
        splitSolver.executeFill(o, sig, AMOUNT_IN, _followingPlan(AMOUNT_OUT), "");

        vm.prank(FILLER);
        splitSolver.executeFill(o, sig, ANY, _followingPlan(AMOUNT_OUT), "");
        assertEq(tA.balanceOf(maker), 0, "the drifted balance was swept");
    }

    /// A MAKER-SIGNED fee — an originator fee output leg — is paid out of the same
    /// route as the maker's output. The sentinel does not change who pays it.
    function test_sentinel_makerSignedFeeLegIsPaid() public {
        _makerHolds(150e18);
        Order memory o = _propOrder(63);
        LegOut[] memory outs = new LegOut[](2);
        outs[0] = LegOut({token: address(tB), start: AMOUNT_OUT, end: 0, recipient: address(0)});
        outs[1] = LegOut({token: address(tB), start: 2e18, end: 0, recipient: address(0xFEE)});
        o.legsOut = PackedEncode.legsOut(outs);
        bytes memory sig = _sign(o);

        vm.prank(FILLER);
        splitSolver.executeFill(o, sig, ANY, _followingPlan(AMOUNT_OUT + 2e18), "");

        assertEq(tB.balanceOf(address(0xFEE)), 2e18, "the signed fee leg is paid in full");
        assertEq(tB.balanceOf(PROTOCOL), (150e18 - AMOUNT_OUT - 2e18) / 10, "protocol fee on what is left");
    }
}
