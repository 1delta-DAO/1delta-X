// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Order, LegIn} from "@core/settlement/Settlement.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {Base} from "@core/settlement/Base.sol";
import {AggregatorFillSolver, RoutePlan, SurplusPolicy, NO_PATCH} from "@solvers/aggregator/AggregatorFillSolver.sol";
import {RouteSandbox} from "@solvers/aggregator/RouteSandbox.sol";

import {MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";
import {AggregatorFillSolverTest, MockRouter} from "./AggregatorFillSolver.t.sol";
import {IFill3} from "./RawSwapComparison.t.sol";

/// @dev A target that pulls whatever it is told to, from whomever it is told to —
///      the "route that tries to take more than it was given" class.
contract GreedyTarget {
    function pull(address token, address from, uint256 amount, address to) external {
        SafeTransferLib.safeTransferFrom(token, from, to, amount);
    }
}

/// @dev Takes the input and pays nothing — the thief route.
contract ThiefTarget {
    function steal(address token, uint256 amount, address to) external {
        SafeTransferLib.safeTransferFrom(token, msg.sender, to, amount);
    }
}

/// @dev Consumes only `consume` of the input and pays `out` of the output token to
///      `recipient` — used with `recipient = sandbox` to leave residue there.
contract PartialTarget {
    address public immutable TOKEN_IN;
    address public immutable TOKEN_OUT;

    constructor(address tokenIn, address tokenOut) {
        (TOKEN_IN, TOKEN_OUT) = (tokenIn, tokenOut);
    }

    function swapPart(uint256 consume, uint256 out, address recipient) external {
        SafeTransferLib.safeTransferFrom(TOKEN_IN, msg.sender, address(this), consume);
        SafeTransferLib.safeTransfer(TOKEN_OUT, recipient, out);
    }
}

/// @dev A swapping target that, mid-route, tries to re-enter the solver, the
///      sandbox and Settlement, records each outcome, then completes the swap.
contract ReentrantTarget {
    address public immutable TOKEN_IN;
    address public immutable TOKEN_OUT;
    address[3] public targets;
    bytes[3] public calls;
    bool[3] public ok;
    bytes4[3] public err;

    constructor(address tokenIn, address tokenOut) {
        (TOKEN_IN, TOKEN_OUT) = (tokenIn, tokenOut);
    }

    function arm(uint256 i, address target, bytes calldata data) external {
        targets[i] = target;
        calls[i] = data;
    }

    function swap(uint256 amountIn, address recipient) external {
        SafeTransferLib.safeTransferFrom(TOKEN_IN, msg.sender, address(this), amountIn);
        for (uint256 i; i < 3; i++) {
            if (targets[i] == address(0)) continue;
            (bool s, bytes memory ret) = targets[i].call(calls[i]);
            ok[i] = s;
            if (ret.length >= 4) err[i] = bytes4(ret);
        }
        SafeTransferLib.safeTransfer(TOKEN_OUT, recipient, amountIn);
    }
}

/// @dev Collects a standing approval FROM the sandbox (any target gets one, by
///      design) and later tries to spend it. Never reverts: a failed harvest must
///      not fail the honest fill it runs inside, or the attack would be loud.
contract ApprovalHarvester {
    function noop() external {}

    function harvest(address token, address from, uint256 amount) public returns (bool) {
        (bool s, bytes memory r) =
            token.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", from, address(this), amount));
        return s && (r.length == 0 || abi.decode(r, (bool)));
    }

    /// @dev PoC 2's hook: called by a hooked router mid-route; takes everything
    ///      `from` (the sandbox) still holds of `token` — the exact-output residue.
    function afterSwap(address token, address from) external {
        harvest(token, from, MockERC20(token).balanceOf(from));
    }
}

/// @dev PoC 1's bait token: an ERC20 whose `transfer` FROM `hookFrom` (the sandbox,
///      during its sweep) calls the harvester for `take` of `loot` first.
contract SweepHookToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public hookFrom;
    ApprovalHarvester public harvester;
    address public loot;
    uint256 public take;
    bool public hookRan;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function setHook(address from, ApprovalHarvester h, address token, uint256 amount) external {
        (hookFrom, harvester, loot, take) = (from, h, token, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (msg.sender == hookFrom && address(harvester) != address(0)) {
            hookRan = true;
            harvester.harvest(loot, hookFrom, take);
        }
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev PoC 2's router: an exact-output swap that, once paid, calls a hook with
///      its payer — the shape of a hooked venue (v4-style hooks, callback routers).
contract HookedExactOutRouter is MockRouter {
    ApprovalHarvester public immutable HOOK;

    constructor(address tokenIn, address tokenOut, ApprovalHarvester hook) MockRouter(tokenIn, tokenOut) {
        HOOK = hook;
    }

    function swapExactOutHooked(uint256 amountOut, uint256 maxIn, address recipient) external {
        uint256 amountIn = amountOut; // 1:1
        require(amountIn <= maxIn, "too much in");
        SafeTransferLib.safeTransferFrom(TOKEN_IN, msg.sender, address(this), amountIn);
        SafeTransferLib.safeTransfer(TOKEN_OUT, recipient, amountOut);
        HOOK.afterSwap(TOKEN_IN, msg.sender);
    }
}

/// @dev Asserts, AT CALL TIME, that its payer holds exactly `expected` of the input
///      — pins that the solver pushes the fill's DELTA, never its balance.
contract ProbeRouter is MockRouter {
    constructor(address tokenIn, address tokenOut) MockRouter(tokenIn, tokenOut) {}

    function swapProbed(uint256 amountIn, address recipient, uint256 expected) external {
        require(MockERC20(TOKEN_IN).balanceOf(msg.sender) == expected, "probe: payer holds more than the delta");
        this.swapFor(msg.sender, amountIn, recipient);
    }

    function swapFor(address payer, uint256 amountIn, address recipient) external {
        require(msg.sender == address(this));
        SafeTransferLib.safeTransferFrom(TOKEN_IN, payer, address(this), amountIn);
        SafeTransferLib.safeTransfer(TOKEN_OUT, recipient, (amountIn * rateBps) / 10_000);
    }
}

/// @dev A multi-hop venue that refunds an INTERMEDIATE token to its payer — a
///      token outside the order, which the sandbox's sweep does not cover.
contract RefundingRouter is MockRouter {
    address public immutable MID;
    uint256 public immutable REFUND;

    constructor(address tokenIn, address tokenOut, address mid, uint256 refund) MockRouter(tokenIn, tokenOut) {
        (MID, REFUND) = (mid, refund);
    }

    function swapWithRefund(uint256 amountIn, address recipient) external {
        SafeTransferLib.safeTransferFrom(TOKEN_IN, msg.sender, address(this), amountIn);
        SafeTransferLib.safeTransfer(TOKEN_OUT, recipient, amountIn);
        SafeTransferLib.safeTransfer(MID, msg.sender, REFUND);
    }
}

/// @dev An input token whose holder's balance can be SEIZED by anyone (a stand-in
///      for an admin clawback / blacklist-seize token) — the one way a route can
///      lower the solver's balance without any approval, and therefore the case
///      {AggregatorFillSolver.RouteOverspent} measures.
contract SeizableToken is MockERC20 {
    constructor() MockERC20("seizable") {}

    function seize(address from, address to, uint256 amount) external {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @title RouteSandboxTest
/// @notice Adversarial suite for the sandboxed route ({RouteSandbox}): arbitrary
///         targets run from an identity that owns nothing, is approved by nobody,
///         and ends every call empty.
///
///         Every instance is operator-GATED since 2026-10 (an open one let a
///         stranger plant a standing sandbox approval — PoCs 1 and 2 below). So
///         `eve` is an OPERATOR of this suite's instance: she stands in for a
///         hostile ROUTE an operator forwards (third-party API calldata, audit
///         2026-09-30 AGG-4), which is who still writes arbitrary calldata.
///         `mallory` is the stranger, and is refused before anything runs.
contract RouteSandboxTest is AggregatorFillSolverTest {
    uint256 internal constant EVE_PK = 0xE7E;
    address internal eve = vm.addr(EVE_PK);
    address internal mallory = address(0xBAD);
    uint256 internal constant PARKED = 400e18;

    RouteSandbox internal sandbox;

    function setUp() public override {
        super.setUp();
        address[] memory ops = new address[](3);
        (ops[0], ops[1], ops[2]) = (address(this), eve, OP2);
        aggSolver = new AggregatorFillSolver(address(settlement), ops, _noSplit());
        sandbox = aggSolver.SANDBOX();
        vm.label(address(sandbox), "routeSandbox");
    }

    /// @dev The exact revert of a route whose pull exceeds what the sandbox holds:
    ///      the token's `transferFrom` fails INSIDE the route (RouteFailed), never
    ///      later at the solver's {RouteOverspent} measurement — which is where a
    ///      solver that pushed its BALANCE instead of the delta would fail.
    function _routePullFailed() internal pure returns (bytes memory) {
        return _wrapped(
            abi.encodeWithSelector(
                RouteSandbox.RouteFailed.selector, abi.encodeWithSelector(SafeTransferLib.TransferFromFailed.selector)
            )
        );
    }

    /// @dev Eve's own order: `amtIn` of tA in, `amtOut` of tB out, signed by her.
    function _eveOrder(uint256 nonce, uint256 amtIn, uint256 amtOut) internal returns (Order memory o, bytes memory sig) {
        tA.mint(eve, amtIn);
        vm.startPrank(eve);
        tA.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(tA), type(uint160).max, 0);
        vm.stopPrank();
        o = _plainOrder(nonce, address(tA), address(tB), amtIn, amtOut);
        o.maker = eve;
        sig = _signWith(o, EVE_PK);
    }

    function _route(address target, bytes memory data, address to) internal pure returns (RoutePlan memory) {
        return RoutePlan({
            router: target,
            minOut: 0,
            maxPay: 0,
            amountInOffset: NO_PATCH,
            amountOutOffset: NO_PATCH,
            minBumpBps: 0,
            profitRecipient: to,
            originator: address(0),
            originatorPpm: 0,
            data: data
        });
    }

    function _assertSandboxEmpty() internal view {
        assertEq(tA.balanceOf(address(sandbox)), 0, "sandbox holds no tA");
        assertEq(tB.balanceOf(address(sandbox)), 0, "sandbox holds no tB");
    }

    // ═══════════════════ identity and wiring ═══════════════════

    function test_sandbox_isWiredToItsSolver() public view {
        assertEq(sandbox.OWNER(), address(aggSolver), "owned by the deploying solver");
        assertEq(sandbox.SETTLEMENT(), address(settlement));
        assertEq(sandbox.PERMIT3(), address(permit3));
        assertEq(sandbox.EXECUTOR(), address(settlement.EXECUTOR()));
        assertEq(sandbox.FLOOR(), 0, "ends every call empty");
    }

    /// @dev Only the owning solver may drive the sandbox.
    function test_sandbox_nonOwnerCannotExec() public {
        address[] memory none = new address[](0);
        vm.prank(eve);
        vm.expectRevert(RouteSandbox.OnlyOwner.selector);
        sandbox.exec(address(tA), address(router), "", none);

        // Not even another solver instance (a different owner).
        AggregatorFillSolver other = new AggregatorFillSolver(address(settlement), _ops(), _noSplit());
        vm.prank(address(other));
        vm.expectRevert(RouteSandbox.OnlyOwner.selector);
        sandbox.exec(address(tA), address(router), "", none);
    }

    /// @dev Settlement / Permit3 / the solver / the EXECUTOR / the sandbox itself are
    ///      refused as targets even for the owner.
    function test_sandbox_forbiddenTargetsRefusedAtTheSandbox() public {
        address[] memory none = new address[](0);
        address[5] memory bad = [
            address(settlement),
            address(permit3),
            address(aggSolver),
            address(settlement.EXECUTOR()),
            address(sandbox)
        ];
        for (uint256 i; i < bad.length; i++) {
            vm.prank(address(aggSolver));
            vm.expectRevert(abi.encodeWithSelector(RouteSandbox.ForbiddenTarget.selector, bad[i]));
            sandbox.exec(address(tA), bad[i], "", none);
        }
    }

    /// @dev NO NATIVE VALUE: the sandbox refuses a plain ETH transfer.
    function test_sandbox_refusesNativeValue() public {
        vm.deal(eve, 1 ether);
        vm.prank(eve);
        (bool ok,) = address(sandbox).call{value: 1}("");
        assertFalse(ok, "no receive / fallback");
        assertEq(address(sandbox).balance, 0);
    }

    // ═══════════════════ funding is PUSH-only ═══════════════════

    /// @dev The solver never approves the sandbox (or any target) — before, during
    ///      or after a fill. Its only allowance is Settlement's, cleared after.
    function test_sandbox_solverGrantsNoAllowanceEver() public {
        Order memory o = _order(1);
        aggSolver.executeFill(o, _sign(o), AMOUNT_IN, _plan(address(aggSolver), AMOUNT_OUT), "");
        assertEq(tA.allowance(address(aggSolver), address(sandbox)), 0, "no solver-to-sandbox allowance");
        assertEq(tB.allowance(address(aggSolver), address(sandbox)), 0, "no solver-to-sandbox allowance");
        assertEq(tA.allowance(address(aggSolver), address(router)), 0, "no solver-to-router allowance");
        assertEq(tB.allowance(address(aggSolver), address(settlement)), 0, "Settlement's cleared");
        assertEq(tA.allowance(address(sandbox), address(router)), type(uint256).max, "the sandbox's own standing one");
        _assertSandboxEmpty();
    }

    /// @dev THE COORDINATOR'S CLASS: `target = token, data = transferFrom(solver,
    ///      attacker, balance)`. The call comes from the SANDBOX, which the solver
    ///      never approved — so it reverts, and the solver's parked balance is safe.
    function test_sandbox_tokenTargetCannotPullFromTheSolver() public {
        tA.mint(address(aggSolver), PARKED); // floor / retained spread / a donation
        (Order memory o, bytes memory sig) = _eveOrder(2, 1e18, 0);
        bytes memory data = abi.encodeWithSignature(
            "transferFrom(address,address,uint256)", address(aggSolver), eve, PARKED
        );
        RoutePlan memory p = _route(address(tA), data, eve);
        vm.prank(eve);
        vm.expectRevert(); // RouteFailed(insufficient allowance), wrapped
        aggSolver.executeFill(o, sig, 1e18, p, "");
        assertEq(tA.balanceOf(address(aggSolver)), PARKED, "solver untouched");
        assertEq(tA.balanceOf(eve), 1e18, "eve's own input returned with the revert");
    }

    /// @dev A target that pulls MORE than was pushed, from the sandbox. The sandbox
    ///      holds exactly this fill's input, so the over-pull reverts the fill —
    ///      the solver's parked balance is out of reach (this is the
    ///      unpatched-route bound the per-fill approval used to provide).
    function test_sandbox_targetCannotPullMoreThanPushed() public {
        tA.mint(address(aggSolver), PARKED);
        GreedyTarget g = new GreedyTarget();
        uint256 evesInput = 10e18;
        (Order memory o, bytes memory sig) = _eveOrder(3, evesInput, 0);
        RoutePlan memory p = _route(
            address(g), abi.encodeCall(GreedyTarget.pull, (address(tA), address(sandbox), evesInput + PARKED, eve)), eve
        );
        vm.prank(eve);
        vm.expectRevert(_routePullFailed());
        aggSolver.executeFill(o, sig, evesInput, p, "");
        assertEq(tA.balanceOf(address(aggSolver)), PARKED, "parked balance untouched");
    }

    /// @dev …and from the SOLVER directly: nobody holds an allowance over it.
    function test_sandbox_targetCannotPullFromTheSolver() public {
        tA.mint(address(aggSolver), PARKED);
        GreedyTarget g = new GreedyTarget();
        (Order memory o, bytes memory sig) = _eveOrder(4, 1e18, 0);
        RoutePlan memory p =
            _route(address(g), abi.encodeCall(GreedyTarget.pull, (address(tA), address(aggSolver), PARKED, eve)), eve);
        vm.prank(eve);
        vm.expectRevert(_routePullFailed());
        aggSolver.executeFill(o, sig, 1e18, p, "");
        assertEq(tA.balanceOf(address(aggSolver)), PARKED, "parked balance untouched");
    }

    /// @dev An unpatched route quoting MORE input than the fill delivered (the
    ///      `NO_PATCH` / wrong-offset case that drained the old standing instance)
    ///      reverts at the router's own pull — the sandbox holds only the delta.
    function test_sandbox_unpatchedOverQuoteCannotReachTheSolver() public {
        tA.mint(address(aggSolver), PARKED);
        (Order memory o, bytes memory sig) = _eveOrder(5, 10e18, 1);
        RoutePlan memory p = _route(
            address(router), abi.encodeCall(MockRouter.swap, (10e18 + PARKED, address(aggSolver))), eve
        );
        vm.prank(eve);
        vm.expectRevert(_routePullFailed());
        aggSolver.executeFill(o, sig, 10e18, p, "");
        assertEq(tA.balanceOf(address(aggSolver)), PARKED, "parked balance untouched");
    }

    // ═══════════════════ the thief route ═══════════════════

    /// @dev A target that STEALS the in-flight input. On the pull path the fill
    ///      reverts (nothing to deliver), so the maker is untouched and the solver
    ///      loses nothing — the stolen input was the maker's, and the revert
    ///      returns it.
    function test_sandbox_thiefTarget_pullFillReverts() public {
        tA.mint(address(aggSolver), PARKED);
        ThiefTarget t = new ThiefTarget();
        Order memory o = _order(6);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _route(address(t), abi.encodeCall(ThiefTarget.steal, (address(tA), AMOUNT_IN, eve)), eve);
        p.minOut = 1;
        uint256 makerA = tA.balanceOf(maker);
        vm.prank(eve);
        vm.expectRevert(_wrapped(abi.encodeWithSelector(AggregatorFillSolver.InsufficientOutput.selector, 0, 1)));
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "");
        assertEq(tA.balanceOf(maker), makerA, "maker untouched");
        assertEq(tB.balanceOf(maker), 0, "maker got nothing because nothing settled");
        assertEq(tA.balanceOf(eve), 0, "thief kept nothing");
        assertEq(tA.balanceOf(address(aggSolver)), PARKED, "solver untouched");
    }

    /// @dev Even with `minOut = 0` the thief route fails: Settlement pulls the
    ///      maker's output against an allowance capped at THIS FILL's proceeds
    ///      (zero), so the solver's own tB is never paid out in its place.
    function test_sandbox_thiefTarget_minOutZero_solverOutputSafe() public {
        tB.mint(address(aggSolver), PARKED);
        ThiefTarget t = new ThiefTarget();
        Order memory o = _order(7);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _route(address(t), abi.encodeCall(ThiefTarget.steal, (address(tA), AMOUNT_IN, eve)), eve);
        vm.prank(eve);
        vm.expectRevert();
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "");
        assertEq(tB.balanceOf(address(aggSolver)), PARKED, "solver's tB never covered the maker");
        assertEq(tA.balanceOf(eve), 0, "thief kept nothing");
    }

    /// @dev On the DIRECT path (gated instance) the core's delta check catches a
    ///      route that does not pay the maker.
    function test_sandbox_thiefTarget_directFillReverts() public {
        ThiefTarget t = new ThiefTarget();
        Order memory o = _directOrder(8);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _route(address(t), abi.encodeCall(ThiefTarget.steal, (address(tA), AMOUNT_IN, eve)), eve);
        vm.expectRevert(Base.DeltaTooLow.selector);
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "");
        assertEq(tA.balanceOf(maker), 1_000e18, "maker untouched");
    }

    // ═══════════════════ residue is swept ═══════════════════

    /// @dev A target that consumes half the input and pays the output TO THE
    ///      SANDBOX: the sweep returns both the unconsumed input and the output to
    ///      the solver, which delivers and splits as usual; the sandbox ends empty.
    function test_sandbox_residueAndSandboxPaidOutputAreSwept() public {
        PartialTarget pt = new PartialTarget(address(tA), address(tB));
        tB.mint(address(pt), 1_000e18);
        Order memory o = _plainOrder(9, address(tA), address(tB), AMOUNT_IN, 40e18);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _route(
            address(pt), abi.encodeCall(PartialTarget.swapPart, (AMOUNT_IN / 2, 50e18, address(sandbox))), address(0)
        );
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "");
        assertEq(tB.balanceOf(maker), 40e18, "maker paid from the swept output");
        assertEq(tB.balanceOf(address(this)), 10e18, "output spread to the caller");
        assertEq(tA.balanceOf(address(this)), AMOUNT_IN / 2, "unconsumed input to the caller");
        _assertSandboxEmpty();
        assertEq(tA.balanceOf(address(aggSolver)), 0, "solver keeps nothing");
        assertEq(tB.balanceOf(address(aggSolver)), 0, "solver keeps nothing");
    }

    /// @dev A donation sitting on the sandbox is not anyone's: the next call sweeps
    ///      it to the solver, where it is measured as that fill's delta.
    function test_sandbox_donationIsSweptByTheNextCall() public {
        tA.mint(address(sandbox), 5e18);
        Order memory o = _order(10);
        aggSolver.executeFill(o, _sign(o), AMOUNT_IN, _plan(address(aggSolver), AMOUNT_OUT), "");
        _assertSandboxEmpty();
    }

    // ═══════════════════ re-entrancy ═══════════════════

    /// @dev Mid-route, the target tries the solver's entry, the sandbox and
    ///      Settlement. All three are refused; the outer fill completes. The target
    ///      is made an OPERATOR (a contract operator — a Safe or an EIP-7702
    ///      delegated EOA whose code a route can reach), so its solver re-entry
    ///      passes the operator gate and is refused by the reentrancy guard itself;
    ///      a non-operator target is refused one check earlier ({NotOperator}).
    function test_sandbox_targetCannotReenter() public {
        ReentrantTarget rt = new ReentrantTarget(address(tA), address(tB));
        tB.mint(address(rt), 1_000e18);
        address[] memory ops = new address[](2);
        (ops[0], ops[1]) = (address(this), address(rt));
        aggSolver = new AggregatorFillSolver(address(settlement), ops, _noSplit());
        sandbox = aggSolver.SANDBOX();

        Order memory inner = _order(11);
        bytes memory innerSig = _sign(inner);
        rt.arm(
            0,
            address(aggSolver),
            abi.encodeCall(
                AggregatorFillSolver.executeFill, (inner, innerSig, AMOUNT_IN, _plan(address(aggSolver), 0), "")
            )
        );
        rt.arm(1, address(sandbox), abi.encodeCall(RouteSandbox.exec, (address(tA), address(rt), "", new address[](0))));
        rt.arm(2, address(settlement), abi.encodeCall(IFill3.fill, (inner, innerSig, AMOUNT_IN)));

        Order memory o = _order(12);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _route(address(rt), abi.encodeCall(ReentrantTarget.swap, (AMOUNT_IN, address(aggSolver))), address(0));
        p.minOut = AMOUNT_OUT;
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "");

        assertFalse(rt.ok(0), "solver re-entry refused");
        assertEq(rt.err(0), AggregatorFillSolver.Reentrancy.selector, "by the solver's guard");
        assertFalse(rt.ok(1), "sandbox re-entry refused");
        assertEq(rt.err(1), RouteSandbox.OnlyOwner.selector, "by the owner check");
        assertFalse(rt.ok(2), "Settlement re-entry refused");
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "outer fill completed, inner never settled");
        _assertSandboxEmpty();
    }

    // ═══════════════════ standing sandbox approvals ═══════════════════

    /// @dev Any target gets a standing max approval FROM THE SANDBOX — by design —
    ///      and that approval is NOT worthless (CORRECTED 2026-10; this test used to
    ///      be `…IsWorthlessToALaterAttacker` and claimed it was). What this test
    ///      shows is narrower: BETWEEN fills the sandbox is empty, and inside a later
    ///      fill that gives the holder NO control flow, the approval reaches nothing.
    ///      With control inside the fill (PoCs 1 and 2 below) it reaches the
    ///      in-flight spread — which is why only operators may name targets.
    function test_sandbox_plantedApprovalNeedsControlInsideALaterFill() public {
        ApprovalHarvester h = new ApprovalHarvester();
        (Order memory o, bytes memory sig) = _eveOrder(13, 1e18, 0);
        vm.prank(eve); // an operator forwarding a route that names `h`
        aggSolver.executeFill(o, sig, 1e18, _route(address(h), abi.encodeCall(ApprovalHarvester.noop, ()), eve), "");
        assertEq(tA.allowance(address(sandbox), address(h)), type(uint256).max, "the planted approval exists");

        // Between fills: nothing to take.
        assertFalse(h.harvest(address(tA), address(sandbox), 1), "the sandbox is empty");

        // An honest fill through a router that never hands `h` control: still nothing.
        Order memory ok = _order(14);
        aggSolver.executeFill(ok, _sign(ok), AMOUNT_IN, _plan(address(aggSolver), AMOUNT_OUT), "");
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "honest fill unaffected");
        assertFalse(h.harvest(address(tA), address(sandbox), 1), "still empty");
        _assertSandboxEmpty();
    }

    /// @dev The standing approval to an HONEST router (pulls from its own
    ///      `msg.sender` only): a stranger calling the router pays with his own
    ///      tokens, never the sandbox's.
    function test_sandbox_standingRouterApprovalIsNotUsableByAStranger() public {
        Order memory o = _order(15);
        aggSolver.executeFill(o, _sign(o), AMOUNT_IN, _plan(address(aggSolver), AMOUNT_OUT), "");
        assertEq(tA.allowance(address(sandbox), address(router)), type(uint256).max);
        tA.mint(address(sandbox), 1e18); // even with a donation sitting there
        vm.prank(eve);
        vm.expectRevert();
        router.swap(1e18, eve); // pulls from eve, who holds nothing
        assertEq(tA.balanceOf(address(sandbox)), 1e18, "the router cannot be pointed at the sandbox");
    }

    // ═══════════ PoC 1 / PoC 2 — planted approvals (2026-10 quick audit) ═══════════

    /// @dev PoC 1, step 1 — now impossible. A stranger's self-signed fill with
    ///      `target = tB, data = approve(harvester, max)` used to plant a standing
    ///      grant over the sandbox's tB. The instance is gated, so it is refused
    ///      before anything runs and no approval exists.
    function test_poc1_strangerCannotPlantATokenApproval() public {
        ApprovalHarvester h = new ApprovalHarvester();
        (Order memory o, bytes memory sig) = _eveOrder(60, 1e18, 0); // any order
        RoutePlan memory p =
            _route(address(tB), abi.encodeWithSignature("approve(address,uint256)", address(h), type(uint256).max), mallory);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(AggregatorFillSolver.NotOperator.selector, mallory));
        aggSolver.executeFill(o, sig, 1e18, p, "");
        assertEq(tB.allowance(address(sandbox), address(h)), 0, "nothing planted");
        // …and the item entry is gated the same way.
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(AggregatorFillSolver.NotOperator.selector, mallory));
        aggSolver.executeItemFill(o, sig, 1e18, p, "", 0);
    }

    /// @dev PoC 2, step 1 — now impossible: `target = harvester` (any call) used to
    ///      hand the harvester the sandbox's standing max approval on `tokenIn`.
    function test_poc2_strangerCannotPlantViaANoopTarget() public {
        ApprovalHarvester h = new ApprovalHarvester();
        (Order memory o, bytes memory sig) = _eveOrder(61, 1e18, 0);
        RoutePlan memory p = _route(address(h), abi.encodeCall(ApprovalHarvester.noop, ()), mallory);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(AggregatorFillSolver.NotOperator.selector, mallory));
        aggSolver.executeFill(o, sig, 1e18, p, "");
        assertEq(tA.allowance(address(sandbox), address(h)), 0, "nothing planted");
    }

    /// @dev The bait order of PoC 1: legsIn = [100 tA, 1 wei EVIL], legsOut = [90 tB],
    ///      signed by eve and submitted by an honest operator, with 1 wei of EVIL
    ///      donated to the sandbox so its sweep calls EVIL.transfer.
    function _poc1Bait(SweepHookToken evil, uint256 nonce) internal returns (Order memory o, bytes memory sig) {
        tA.mint(eve, AMOUNT_IN);
        evil.mint(eve, 1);
        vm.startPrank(eve);
        tA.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(tA), type(uint160).max, 0);
        evil.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(evil), type(uint160).max, 0);
        vm.stopPrank();
        LegIn[] memory legsIn = new LegIn[](2);
        legsIn[0] = LegIn(address(tA), AMOUNT_IN, 0);
        legsIn[1] = LegIn(address(evil), 1, 0);
        o = _plainOrder(nonce, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        o.legsIn = PackedEncode.legsIn(legsIn);
        o.maker = eve;
        sig = _signWith(o, EVE_PK);
        evil.mint(address(sandbox), 1);
    }

    /// @dev PoC 1, the theft step, against an approval PLANTED BY CHEATCODE (no
    ///      stranger can plant one any more): the honest route pays the sandbox
    ///      100 tB, `minOut` 95; EVIL's transfer hook, run by the sweep, tries to pull
    ///      the 5 tB above `minOut`. OUTPUT-FIRST SWEEP ORDER: tB has already left
    ///      when EVIL is swept, so the hook finds nothing and the filler keeps the
    ///      whole 10 tB spread. (Against the old tokenIn-first order the hook took
    ///      5 tB and the fill still passed.)
    function test_poc1_outputFirstSweepProtectsTheSpreadFromAHookToken() public {
        ApprovalHarvester h = new ApprovalHarvester();
        vm.prank(address(sandbox));
        tB.approve(address(h), type(uint256).max); // the planted approval, simulated

        SweepHookToken evil = new SweepHookToken();
        evil.setHook(address(sandbox), h, address(tB), 5e18);
        (Order memory o, bytes memory sig) = _poc1Bait(evil, 62);

        RoutePlan memory p = _plan(address(sandbox), 95e18); // honest route, pays the sandbox
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "");

        assertTrue(evil.hookRan(), "the hook ran during the sweep");
        assertEq(tB.balanceOf(address(h)), 0, "the harvester got nothing");
        assertEq(tB.balanceOf(eve), AMOUNT_OUT, "maker paid");
        assertEq(tB.balanceOf(address(this)), AMOUNT_IN - AMOUNT_OUT, "filler kept the whole spread");
        _assertSandboxEmpty();
    }

    /// @dev PoC 2, the theft step, with NO planted approval (a stranger can no longer
    ///      plant one): the hooked exact-output router hands the harvester control
    ///      while the input residue sits in the sandbox, and it reaches nothing.
    function test_poc2_hookedRouterFindsNoApprovalToSpend() public {
        ApprovalHarvester h = new ApprovalHarvester();
        HookedExactOutRouter hr = new HookedExactOutRouter(address(tA), address(tB), h);
        tB.mint(address(hr), 1_000e18);
        Order memory o = _order(63);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _route(
            address(hr), abi.encodeCall(HookedExactOutRouter.swapExactOutHooked, (AMOUNT_OUT, AMOUNT_IN, address(aggSolver))), address(0)
        );
        p.minOut = AMOUNT_OUT;
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "");
        assertEq(tA.balanceOf(address(h)), 0, "the harvester got nothing");
        assertEq(tA.balanceOf(address(this)), AMOUNT_IN - AMOUNT_OUT, "the filler kept the input residue");
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "maker paid");
    }

    /// @dev PoC 2's RESIDUAL, pinned so it is not forgotten: a target an OPERATOR's
    ///      route once named keeps its standing approval, and if it later gains
    ///      control inside a fill it takes that fill's residue. Sweep ordering
    ///      cannot help (the theft is DURING the route). This is operator trust —
    ///      never name a target you would not trust with a later fill's in-flight
    ///      balance — and the reason strangers may not name targets at all.
    function test_poc2_residual_operatorNamedTargetKeepsItsApproval() public {
        ApprovalHarvester h = new ApprovalHarvester();
        HookedExactOutRouter hr = new HookedExactOutRouter(address(tA), address(tB), h);
        tB.mint(address(hr), 1_000e18);
        // An operator route that names `h` once (a mistake, or a hostile API route).
        (Order memory o1, bytes memory sig1) = _eveOrder(64, 1e18, 0);
        vm.prank(eve);
        aggSolver.executeFill(o1, sig1, 1e18, _route(address(h), abi.encodeCall(ApprovalHarvester.noop, ()), eve), "");

        Order memory o = _order(65);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _route(
            address(hr), abi.encodeCall(HookedExactOutRouter.swapExactOutHooked, (AMOUNT_OUT, AMOUNT_IN, address(aggSolver))), address(0)
        );
        p.minOut = AMOUNT_OUT;
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "");
        assertEq(tA.balanceOf(address(h)), AMOUNT_IN - AMOUNT_OUT, "the operator-named target took the residue");
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "the fill itself still passed");
    }

    // ═══════════ stranded tokens outside the order (2026-10 quick audit) ═══════════

    /// @dev The sweep covers the ORDER'S tokens only, so an intermediate-hop refund
    ///      in a third token strands on the sandbox. The documented recovery: an
    ///      operator routes `target = token, data = transfer(solver, balance)` (any
    ///      order will do as the carrier), then `sweep`s it on.
    function test_sandbox_strandedTokenIsRecoverableByAnOperator() public {
        uint256 refund = 3e18;
        RefundingRouter rr = new RefundingRouter(address(tA), address(tB), address(tC), refund);
        tB.mint(address(rr), 1_000e18);
        tC.mint(address(rr), 1_000e18);
        Order memory o = _order(70);
        bytes memory sig = _sign(o);
        RoutePlan memory p =
            _route(address(rr), abi.encodeCall(RefundingRouter.swapWithRefund, (AMOUNT_IN, address(aggSolver))), address(0));
        p.minOut = AMOUNT_OUT;
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "");
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "fill settled");
        assertEq(tC.balanceOf(address(sandbox)), refund, "the out-of-order token stranded on the sandbox");

        // Recovery: a 1-wei carrier order, the route moves tC to the solver.
        Order memory carrier = _plainOrder(71, address(tA), address(tB), 1, 0);
        bytes memory csig = _sign(carrier);
        RoutePlan memory rec = _route(
            address(tC), abi.encodeWithSignature("transfer(address,uint256)", address(aggSolver), refund), address(0)
        );
        aggSolver.executeFill(carrier, csig, 1, rec, "");
        assertEq(tC.balanceOf(address(sandbox)), 0, "sandbox emptied");
        assertEq(tC.balanceOf(address(aggSolver)), refund, "on the solver, outside any fill's split");

        address treasury = address(0x7EA5);
        aggSolver.sweep(address(tC), treasury, refund);
        assertEq(tC.balanceOf(treasury), refund, "recovered");
    }

    // ═══════════ mutation-testing gaps (2026-10 quick audit, M2) ═══════════

    /// @dev M2: the solver must push this fill's DELTA to the sandbox, never its
    ///      balance. The probe router checks the sandbox's holding AT CALL TIME,
    ///      with a parked balance on the solver that a balance-push would include.
    function test_sandbox_pushesExactlyTheDelta() public {
        ProbeRouter pr = new ProbeRouter(address(tA), address(tB));
        tB.mint(address(pr), 1_000e18);
        tA.mint(address(aggSolver), PARKED);
        Order memory o = _order(80);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _route(
            address(pr), abi.encodeCall(ProbeRouter.swapProbed, (AMOUNT_IN, address(aggSolver), AMOUNT_IN)), address(0)
        );
        p.minOut = AMOUNT_OUT;
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "");
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "filled");
        assertEq(tA.balanceOf(address(aggSolver)), PARKED, "parked balance untouched");
    }

    /// @dev Where {RouteOverspent} IS the expected revert: a route that lowers the
    ///      solver's own balance of an input token without any approval (a seizable
    ///      token). Nothing else can reach it; the measurement catches this one.
    function test_sandbox_routeOverspentCatchesASeizedInput() public {
        SeizableToken sz = new SeizableToken();
        sz.mint(maker, AMOUNT_IN);
        _makerApprove(address(settlement), address(sz), type(uint160).max);
        sz.mint(address(aggSolver), PARKED);
        Order memory o = _plainOrder(81, address(sz), address(tB), AMOUNT_IN, 0);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _route(
            address(sz), abi.encodeCall(SeizableToken.seize, (address(aggSolver), eve, PARKED)), address(0)
        );
        vm.expectRevert(_wrapped(abi.encodeWithSelector(AggregatorFillSolver.RouteOverspent.selector)));
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "");
        assertEq(sz.balanceOf(address(aggSolver)), PARKED, "reverted whole");
    }
}
