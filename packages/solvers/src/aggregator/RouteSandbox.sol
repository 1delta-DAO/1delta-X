// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

/// @title RouteSandbox
/// @notice The identity {AggregatorFillSolver} lends to an aggregator route. The
///         solver PUSHES one fill's input here, the sandbox approves the route's
///         target and calls it, then hands everything it holds back. Because the
///         sandbox owns nothing and is trusted by nobody, the target may be ANY
///         contract the solver's OPERATORS choose: there is no router allowlist,
///         but there is no permissionless caller either (see the ⚠ below).
///
///  WHY IT EXISTS
///  ─────────────
///  A route's calldata is opaque, and the solver used to make the call ITSELF.
///  That identity holds value (the dust floor, the retained spread, anything a
///  stranger sends) and Settlement allowances, so the call target had to be
///  pinned to an immutable router set, and adding a venue meant redeploying the
///  solver. The sandbox applies {SolverCallbackExecutor}'s argument to the
///  solver's own side: move the arbitrary call into an address with no authority
///  and "call anything" stops endangering the SOLVER'S value. Two structural rules
///  make that true, and the code below is written to keep both (they do not, on
///  their own, protect a fill's in-flight spread from an earlier route — the ⚠
///  below):
///
///    1. PUSH-FUNDED. The sandbox never calls `transferFrom` on anyone, so nobody
///       ever has a reason to approve it. The solver funds it with a plain
///       `transfer` of the fill's measured input, and must NEVER approve it: the
///       target is arbitrary and may be a token, so a solver→sandbox allowance
///       would let `target = token, data = transferFrom(solver, attacker, …)`
///       drain the solver.
///    2. IT ENDS EMPTY. Every call ends by sweeping `tokenIn` and every
///       `sweepTokens` entry back to the owner — unconditionally, whatever the
///       route did ({FLOOR} is 0: a dust floor was measured and bought nothing).
///
///  ⚠ THE SANDBOX'S OWN STANDING MAX APPROVALS ARE NOT WORTHLESS (corrected
///  2026-10 quick audit; this note used to say "an approval over an empty account
///  grants nothing"). Every target it has ever called keeps a max approval on that
///  call's `tokenIn`, and a route target that is a token can be made to `approve`
///  anyone. The account is empty BETWEEN calls, but not DURING one: inside a later
///  fill it holds that fill's in-flight input, any output the route paid here and
///  the input residue of an exact-output route — and the spread above `minOut` is
///  exactly what the route's own checks do not protect. A holder of a planted
///  approval who gets control inside that window (a hook token in the order's
///  sweep list, a hooked router, a callback the route makes) can pull that spread
///  before the sweep, and the fill still passes. Two PoCs, both in
///  `test/RouteSandbox.t.sol`. So:
///
///    • WHO MAY DRIVE THE SANDBOX IS LOAD-BEARING. Its owner is gated-only (the
///      solver's constructor refuses an empty operator set), so strangers cannot
///      plant an approval: the set of targets holding one is exactly the set of
///      targets the operators' routes have named. An operator (or a route API
///      whose calldata an operator forwards) must never name a target it would
///      not trust with the in-flight balance of a later fill.
///    • OUTPUTS ARE SWEPT FIRST (defence in depth). The owner orders
///      `sweepTokens` output tokens first, then `tokenIn`, then the other inputs,
///      so a hook in a non-output sweep token runs after the spread has already
///      left. It cannot help against control taken DURING the route call.
///
///  STRANDED TOKENS. The sweep covers `tokenIn` and `sweepTokens` — the order's
///  own token set — and nothing else. A token outside it that a route leaves here
///  (an intermediate hop's refund) stays until an operator recovers it with a
///  route of `target = token, data = transfer(owner, balance)`, after which the
///  owner's `sweep` moves it on.
///
///  WHAT THE SANDBOX'S IDENTITY CAN DO, AND WHY IT IS NOTHING
///  ─────────────────────────────────────────────────────────
///  Anything the target asks of it: approve, transfer what it holds, call any
///  contract that does not take `msg.sender == sandbox` as authority. It holds no
///  Permit3 grant (nobody gives it one), is no Settlement filler or signer anyone
///  relies on, and is no operator of the solver. The owner, Settlement, Permit3
///  and Settlement's callback executor are refused as targets anyway
///  ({ForbiddenTarget}) — defence in depth, so a route can never make the sandbox
///  speak to the protocol or re-enter its owner.
///
///  Tokens are NOT refused as targets. A route whose target is a token can make
///  the sandbox `transfer` what it holds (this fill's in-flight input, which then
///  fails the fill's output check and reverts it — unless only the spread above
///  `minOut` is taken) or `approve` someone (a standing grant over every later
///  fill's in-flight balance; see the ⚠ above). Refusing them would need the full
///  token list of the fill and would still leave the hooked-router variant, so the
///  defence is the gate on who writes routes, not a target filter.
///
///  NO NATIVE VALUE. `exec` is not payable, the sandbox has no `receive` or
///  `fallback`, and the target is called with zero value, so a route that pays
///  native coin here (an unwrap-to-recipient leg) reverts. Native coin forced in by
///  SELFDESTRUCT or a coinbase reward is stranded, never spent: nothing here ever
///  forwards value.
contract RouteSandbox {
    /// @notice The only caller of {exec} — the {AggregatorFillSolver} that deployed
    ///         this sandbox, and the only address its sweeps ever pay.
    address public immutable OWNER;
    /// @dev Protocol addresses the target may never be. See {ForbiddenTarget}.
    address public immutable SETTLEMENT;
    address public immutable PERMIT3;
    address public immutable EXECUTOR;

    /// @notice The balance the sandbox may keep of each token between calls: a
    ///         sweep returns `balance - FLOOR` once the balance exceeds it.
    /// @dev    ZERO, BY MEASUREMENT (Rootstock fork, fresh tx, 2026-10-04). A 1-wei
    ///         floor here cut EXECUTION gas by exactly 17,100 per fill (the
    ///         sandbox's `tokenIn` slot written non-zero→non-zero instead of
    ///         0→non-zero) — and cut the end-of-transaction REFUND by the same
    ///         17,100, because the slot is written and restored inside one
    ///         transaction and EIP-2200/3529 refund the restore. Net transaction gas
    ///         was identical to the unit (direct 242,605 both ways; pull 277,601
    ///         both ways). It only pays once a transaction's refunds hit the
    ///         gasUsed / 5 cap, which a single fill does not (pull: 60.6k refunded
    ///         against a ~67.8k cap). Not worth a wei per token of exposure to every
    ///         later target, so the sandbox ends EVERY call holding nothing.
    ///         Measurement: `SandboxGasBench.test_sandbox_gas_{direct,pull}`
    ///         (test/RouteSandboxFork.t.sol), FOUNDRY_PROFILE=solvers, Rootstock
    ///         fork block 8,920,000, 2026-10-04 (before tasks 06/08), this
    ///         constant patched to 1 for the floored run; "net" = execution +
    ///         calldata + the 21k intrinsic − refund (capped at gasUsed / 5);
    ///         SOLVER floor seeded in setUp in both runs. Not re-run (needs the
    ///         constant edited). The same tests at FLOOR = 0 re-measured
    ///         2026-10-06: direct 252,567 execution / 247,907 net (refund 37,900),
    ///         pull 310,502 / 282,890 (refund 60,600, cap ~68.7k).
    uint256 public constant FLOOR = 0;

    error OnlyOwner();
    /// @dev `target` is the owner, Settlement, Permit3, Settlement's callback
    ///      executor or this sandbox.
    error ForbiddenTarget(address target);
    /// @dev The target reverted; its return data, verbatim.
    error RouteFailed(bytes ret);

    constructor(address settlement, address permit3, address executor) {
        OWNER = msg.sender;
        SETTLEMENT = settlement;
        PERMIT3 = permit3;
        EXECUTOR = executor;
    }

    /// @notice Run one route from this empty, authority-less identity.
    /// @param  tokenIn     the token the owner pushed here for this route
    /// @param  target      ANY contract except the ones {ForbiddenTarget} names
    /// @param  data        the route's calldata, already patched by the owner
    /// @param  sweepTokens the tokens to sweep back, IN THE ORDER GIVEN — the owner
    ///         lists output tokens first, then `tokenIn`, then the other inputs, so
    ///         the spread leaves before any other token's `transfer` hook runs.
    ///         `tokenIn` is always swept: last, if the list does not name it.
    /// @dev    In order: (1) approve `target` for max on `tokenIn` when the standing
    ///         allowance does not cover what is held; (2) call it, bubbling a revert;
    ///         (3) sweep every `sweepTokens` entry, then `tokenIn` if not listed,
    ///         back to the owner.
    function exec(address tokenIn, address target, bytes calldata data, address[] calldata sweepTokens) external {
        if (msg.sender != OWNER) revert OnlyOwner();
        if (
            target == OWNER || target == SETTLEMENT || target == PERMIT3 || target == EXECUTOR
                || target == address(this)
        ) revert ForbiddenTarget(target);

        // (1) A standing max approval, set once per (token, target). It saves the
        // router-approval write the solver used to pay on every fill; it is NOT
        // harmless in general — see the ⚠ in the contract note — and is acceptable
        // only because the owner admits operator-written routes alone.
        SafeTransferLib.ensureApproval(tokenIn, target, SafeTransferLib.balanceOf(tokenIn, address(this)));

        // (2) The route.
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) revert RouteFailed(ret);

        // (3) Unconditional sweep, in the caller's order (outputs first). Never
        // skipped: "ends empty" is what keeps the standing approvals from reaching
        // value between fills.
        bool inSwept;
        for (uint256 i; i < sweepTokens.length; ++i) {
            address t = sweepTokens[i];
            _sweep(t);
            if (t == tokenIn) inSwept = true;
        }
        if (!inSwept) _sweep(tokenIn);
    }

    function _sweep(address token) private {
        uint256 bal = SafeTransferLib.balanceOf(token, address(this));
        if (bal > FLOOR) SafeTransferLib.safeTransfer(token, OWNER, bal - FLOOR);
    }
}
