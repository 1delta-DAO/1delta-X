// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {PackedArraysMem} from "@core/settlement/PackedArraysMem.sol";
import {Settlement, Order, CallbackMode} from "@core/settlement/Settlement.sol";

/// @title AggregatorFillSolver
/// @notice Zero-inventory fills against an off-chain aggregator route: take the
///         maker's `tokenIn`, swap it through whatever router the quote named,
///         deliver `tokenOut`. No flash loan, no held capital, and no bespoke
///         integration per venue — the route is opaque calldata.
///
///  WHY A CONTRACT IS REQUIRED HERE, and raw router calldata is not enough
///  ─────────────────────────────────────────────────────────────────────
///  `fillWithCallback` does NOT make the solver's `(target, data)` call itself.
///  It routes it through {SolverCallbackExecutor}, an allowance-less trampoline
///  that holds no funds and is an approved spender for nobody — deliberately, so
///  a filler cannot pass `target = Permit3` and drain every maker who ever
///  approved Settlement.
///
///  The consequence for aggregator injection: inside the callback the router
///  sees `msg.sender == EXECUTOR`. Aggregator routers pull their input with
///  `transferFrom(msg.sender, …)`, and the executor has neither the tokens nor
///  an approval — so passing the aggregator's own calldata straight through as
///  the callback target reverts every time. Something must hold `tokenIn`
///  mid-fill and approve the router from an identity that owns it. That is this
///  contract, and it is the whole reason it exists.
///
///  The flow (`CallbackMode.PostInputs` — Fusion's `takerInteraction` ordering)
///  ─────────────────────────────────────────────────────────────────────────
///    1. `executeFill` → `settlement.fillWithCallback(..., PostInputs)`.
///    2. Settlement pays the maker's `tokenIn` to `ctx.filler` — THIS contract,
///       because this contract is the `msg.sender` of the fill.
///    3. EXECUTOR calls `onFill` here: approve `router`, fire the aggregator's
///       calldata, check the proceeds against `minOut`.
///    4. Settlement pulls `tokenOut` from this contract (Permit3, falling back to
///       a direct `transferFrom`) and delivers it to the maker.
///
///  Step 4 is why `onFill` approves Settlement for the proceeds: the fallback
///  path is an ordinary ERC20 `transferFrom`, so a solver that never holds a
///  balance between fills needs no Permit3 allowance at all.
///
///  ⚠ THE PRICED AMOUNT IS RESOLVED AT FILL TIME, AND AGGREGATOR CALLDATA IS NOT.
///  An aggregator bakes `amountIn` into the bytes it returns, but what the maker
///  actually pays is decided during the fill — it rises with the clock on a BUY
///  order, is read from the maker's live balance on a {Proportional} leg, shrinks
///  on a partial fill the filler sizes later, and nets differently for a
///  fee-on-transfer token. Whenever the two disagree the router pulls the QUOTED
///  figure: too high and the swap reverts, too low and the surplus strands here.
///
///  `RoutePlan.amountInOffset` is the fix — the offset of the 32-byte amount
///  inside the route's calldata, which {onFill} overwrites with the balance
///  actually received before firing it. Set it and the route follows the fill;
///  leave it {NO_PATCH} for a fixed-input SELL order, where the quoted figure is
///  already exact and rewriting buys nothing.
///
///  ⚠ THE OFF-CHAIN QUOTE MUST NAME THIS CONTRACT. Aggregators bake the
///  recipient (and often the sender) into the calldata they return. A route
///  quoted for the solver's EOA sends the swap output to that EOA, and the fill
///  then reverts here with {InsufficientOutput} — the funds are not lost, but the
///  round is. Quote with `recipient = address(thisSolver)`.
///
///  Trust model: `executeFill` is callable by anyone — the security boundary is
///  the maker's signed order plus their Permit3 allowances, exactly as in a plain
///  `fill`. THREE things make that safe, and all three are load-bearing:
///
///    1. THE ROUTER IS ALLOWLISTED AT CONSTRUCTION. `onFill` issues a raw call
///       with caller-supplied calldata from THIS contract's identity, and
///       `executeFill` — the thing that arms it — is permissionless. So the
///       EXECUTOR check and the arming flag authenticate nothing on their own:
///       an attacker satisfies both by calling `executeFill` himself with an
///       order he signed as his own maker. Only an immutable set of routers
///       makes the target trustworthy. Without it this contract is a
///       "call anything as me" primitive that can mint durable authority for an
///       attacker (`PERMIT3.approveToken`, `SETTLEMENT.setOrderSigner`, …).
///
///    2. EVERY AMOUNT IS A DELTA OF THIS FILL, never a balance. The router
///       approval, the `minOut` test, the Settlement approval and the profit
///       sweep all measure `balance − balanceBefore`, snapshotted in
///       `executeFill` before Settlement moves anything. A balance-based figure
///       would let a self-signed 1-wei order approve, deliver or sweep whatever
///       an unrelated fill left parked here.
///
///    3. NO ALLOWANCE SURVIVES THE FILL. The router allowance is zeroed inside
///       `onFill`; Settlement's is zeroed in `executeFill` after the fill
///       returns, so a standing approval can never be paired with a later
///       balance.
///
///  The contract still aims to hold nothing between fills, but that is now a
///  PROPERTY OF THE HAPPY PATH rather than a security assumption: residue is
///  no longer reachable by the next caller.
/// @notice One aggregator route, as the solver received it off-chain.
/// @param router the venue's entrypoint, from the quote
/// @param minOut floor on the swap proceeds — SOLVER-side protection against a
///        stale route; the maker's own floor is the signed band Settlement enforces
/// @param maxPay ceiling on what Settlement may pull from this contract. `0` = no
///        cap, meaning "up to THIS FILL's proceeds" — never the contract's
///        balance. A `maxPay` above the proceeds is clamped down to them for the
///        same reason. Together with `minOut` this pins the spread: the fill can
///        only succeed if `proceeds >= minOut` and the maker takes at most
///        `maxPay`, so profit >= `minOut - maxPay` by construction
/// @param amountInOffset byte offset within `data` of the 32-byte input amount to
///        REWRITE with the amount actually received, or {NO_PATCH} to leave the
///        calldata exactly as the aggregator returned it. See the ⚠ note on
///        {AggregatorFillSolver} about resolved amounts.
/// @param profitRecipient where the spread goes once the maker is paid;
///        `address(0)` = `msg.sender`
/// @param data  the aggregator's own calldata, quoted with `recipient = the solver`
struct RoutePlan {
    address router;
    uint256 minOut;
    uint256 maxPay;
    uint256 amountInOffset;
    address profitRecipient;
    bytes data;
}

/// @dev `RoutePlan.amountInOffset` sentinel: use the aggregator's calldata verbatim.
uint256 constant NO_PATCH = type(uint256).max;

/// @notice The resolved route handed to {AggregatorFillSolver.onFill}.
/// @dev    A STRUCT rather than a parameter list, deliberately. The flat form hit
///         the stack limit at six arguments under the legacy profile this package
///         compiles with, and every future field would hit it again; a struct
///         costs one memory pointer and makes the shape extensible.
struct FillRoute {
    address tokenIn;
    address tokenOut;
    address router;
    uint256 minOut;
    uint256 maxPay;
    uint256 amountInOffset;
    /// @dev `tokenIn`/`tokenOut` balances taken in `executeFill` BEFORE Settlement
    ///      moved anything. Everything `onFill` spends is measured against these,
    ///      so the callback can only ever reach this fill's own proceeds.
    uint256 inBefore;
    uint256 outBefore;
    bytes data;
}

contract AggregatorFillSolver {
    Settlement public immutable SETTLEMENT;
    /// @dev The allowance-less trampoline that makes every callback. Read once at
    ///      construction: it is an immutable of Settlement and never changes.
    address public immutable EXECUTOR;

    /// @dev 1 = idle, 2 = inside a fill this contract initiated.
    uint256 private _active = 1;

    /// @notice The venues `onFill` may call. Written ONCE, in the constructor,
    ///         and there is deliberately no setter: the set is part of this
    ///         instance's identity, exactly as the cosigner is for
    ///         {CosignedQuotePriceModule}. Supporting a new aggregator means
    ///         deploying another instance, which keeps the contract ownerless.
    mapping(address => bool) public isAllowedRouter;

    error OnlyExecutor();
    error NotArmed();
    error InsufficientOutput(uint256 got, uint256 wanted);
    error RouterCallFailed(bytes ret);
    error CallbackDidNotRun();
    error PatchOutOfBounds(uint256 offset, uint256 length);
    /// @dev The route named a venue this instance was not constructed for.
    error RouterNotAllowed(address router);
    /// @dev A router that is one of the protocol's own contracts would turn the
    ///      route call back into the arbitrary-authority primitive the allowlist
    ///      exists to remove.
    error RouterIsProtocol(address router);
    /// @dev `legsIn[0]` / `legsOut[0]` must exist before their tokens can be read —
    ///      {PackedArraysMem} is an unchecked reader, and a blob declaring zero
    ///      legs with trailing bytes would otherwise name an arbitrary token.
    error NoLegs();

    constructor(address settlement, address[] memory routers) {
        SETTLEMENT = Settlement(payable(settlement));
        address executor = address(Settlement(payable(settlement)).EXECUTOR());
        EXECUTOR = executor;
        address permit3 = address(Settlement(payable(settlement)).PERMIT3());
        for (uint256 i; i < routers.length; i++) {
            address r = routers[i];
            if (r == settlement || r == executor || r == permit3 || r == address(this) || r == address(0)) {
                revert RouterIsProtocol(r);
            }
            isAllowedRouter[r] = true;
        }
    }

    /// @notice Fill `order` by routing the maker's input through `plan.router`.
    /// @param  plan the aggregator route — see {RoutePlan}. Bundled as a struct
    ///         rather than three parameters because the flat form pushes this
    ///         function past the stack limit under the legacy profile this
    ///         package compiles with.
    /// @param  takerData forwarded to the order's validators, invariants and
    ///         price module — carry the cosigned quote here for a
    ///         `ClockFlooredQuoteModule` order.
    /// @dev    The spread is swept to `plan.profitRecipient` AFTER the fill
    ///         returns, because the surplus is only knowable once Settlement has
    ///         taken its share. Whoever executes takes the risk and keeps the
    ///         profit — which is what lets this contract stay ownerless and hold
    ///         nothing between fills.
    function executeFill(
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmount,
        RoutePlan calldata plan,
        bytes calldata takerData
    ) external returns (uint256[] memory fillAmountsOut) {
        // Built BEFORE the fill, because two of its fields are balances that only
        // mean anything pre-fill — and reused afterwards for the sweep, so the
        // callback and the sweep can never disagree about what this fill created.
        FillRoute memory route = _plan(order, plan);
        _active = 2;
        fillAmountsOut = SETTLEMENT.fillWithCallback(
            order, sig, fillAmount, address(this), _callback(route), CallbackMode.PostInputs, takerData
        );
        // A callback that never ran means the swap never happened, and any
        // delivery that nonetheless succeeded came out of this contract's own
        // balance. Settlement cannot report that, so we check the flag only
        // `onFill` could have cleared.
        if (_active != 1) {
            _active = 1;
            revert CallbackDidNotRun();
        }

        // Settlement has taken its share; whatever allowance is left over must not
        // outlive the fill, or a later balance would be pullable against it.
        SafeTransferLib.forceApprove(route.tokenOut, address(SETTLEMENT), 0);

        // Sweep BOTH sides: the output surplus is the spread, and any input the
        // route did not consume (an unpatched under-quote) would otherwise sit
        // here unaccounted.
        //
        // ⚠ THE DELTA, NOT THE BALANCE, and this is a security boundary rather
        // than tidiness. `executeFill` is permissionless and `order` is the
        // caller's, so a whole-balance sweep is a signature-free "send me your
        // balance of any token I name" primitive — the same one
        // {BaseFlashSolver._requireCallbackRan} was written to close. Measuring
        // against the pre-fill snapshot means the caller can only ever take what
        // its own fill produced.
        address to = plan.profitRecipient == address(0) ? msg.sender : plan.profitRecipient;
        _sweepDelta(route.tokenOut, route.outBefore, to);
        _sweepDelta(route.tokenIn, route.inBefore, to);
    }

    /// @dev Move this fill's INCREASE in `token` to `to`. Silent when the balance
    ///      did not grow — a fill that left no surplus is the normal case, not an
    ///      error, and a balance that shrank (Settlement pulled the delivery out
    ///      of it) is the other normal case.
    function _sweepDelta(address token, uint256 before, address to) private {
        uint256 bal = SafeTransferLib.balanceOf(token, address(this));
        if (bal > before) SafeTransferLib.safeTransfer(token, to, bal - before);
    }

    /// @dev Resolve the route against the order, in its OWN frame: the two decoded
    ///      token addresses and the two snapshots push {executeFill} past the stack
    ///      limit under the legacy (non-via-IR) profile this package compiles with
    ///      — the same split the settlement makes in its own fill helpers.
    ///
    ///      ⚠ THE LEG COUNTS ARE CHECKED HERE and nowhere else on this path.
    ///      {PackedArraysMem} reads a leg without consulting the blob's count byte,
    ///      and {PackedArrays.validateFixed} tolerates trailing bytes — so a
    ///      `legsOut` of `0x00 ‖ <104 bytes>` settles as ZERO output legs (the
    ///      caller owes the maker nothing) while still naming a token here. Reject
    ///      the empty blob and that shape cannot be built.
    function _plan(Order calldata order, RoutePlan calldata plan) private view returns (FillRoute memory) {
        if (PackedArraysMem.count(order.legsIn) == 0 || PackedArraysMem.count(order.legsOut) == 0) revert NoLegs();
        address tokenIn = PackedArraysMem.legInToken(order.legsIn, 0);
        address tokenOut = PackedArraysMem.legOutToken(order.legsOut, 0);
        return FillRoute({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            router: plan.router,
            minOut: plan.minOut,
            maxPay: plan.maxPay,
            amountInOffset: plan.amountInOffset,
            inBefore: SafeTransferLib.balanceOf(tokenIn, address(this)),
            outBefore: SafeTransferLib.balanceOf(tokenOut, address(this)),
            data: plan.data
        });
    }

    /// @dev The callback payload. Its own frame for the same stack reason.
    function _callback(FillRoute memory route) private view returns (bytes memory) {
        return abi.encodeCall(this.onFill, (route));
    }

    /// @dev The route's calldata with the input amount rewritten to what the fill
    ///      actually delivered — see the ⚠ note on resolved amounts.
    ///
    ///      Rewriting a caller-supplied blob is only safe because BOTH halves are
    ///      the solver's own: it supplies the calldata and it owns the funds at
    ///      risk, so a wrong offset costs the solver its own gas and nothing else.
    ///      The maker is untouched either way — Settlement enforces the signed
    ///      band whatever this call does. The bounds check is still mandatory:
    ///      without it a short blob would let the write run past the copy.
    function _patched(bytes calldata data, uint256 offset, uint256 amountIn) private pure returns (bytes memory out) {
        out = data;
        if (offset == NO_PATCH) return out;
        if (offset + 32 > out.length) revert PatchOutOfBounds(offset, out.length);
        /// @solidity memory-safe-assembly
        assembly {
            mstore(add(add(out, 0x20), offset), amountIn)
        }
    }

    /// @notice The fill callback. Not public in effect: only the EXECUTOR may
    ///         call it, and only while `executeFill` has armed it.
    /// @dev    THREE gates, and the third is the one that actually authorises
    ///         anything. The EXECUTOR check and the arming flag bound WHEN this
    ///         runs, not WHO asked for it: `executeFill` is permissionless, so an
    ///         attacker satisfies both by starting a fill of an order he signed as
    ///         his own maker. `isAllowedRouter` is what stops the raw call below
    ///         from being an "invoke anything as this contract" primitive — it
    ///         pins the target to a venue this instance was constructed for.
    function onFill(FillRoute calldata r) external {
        if (msg.sender != EXECUTOR) revert OnlyExecutor();
        if (_active != 2) revert NotArmed();
        if (!isAllowedRouter[r.router]) revert RouterNotAllowed(r.router);
        _active = 1;

        // Swap what THIS FILL delivered. Balance-DELTA rather than an amount
        // passed in: what the maker paid is Settlement's business and a
        // fee-on-transfer `tokenIn` would make any figure passed here wrong — but
        // the raw balance is equally wrong, because it would also hand the router
        // (and, below, the maker) whatever an earlier fill left parked here.
        // Under-flowing is the correct failure: it means the input never arrived.
        uint256 amountIn = SafeTransferLib.balanceOf(r.tokenIn, address(this)) - r.inBefore;
        SafeTransferLib.forceApprove(r.tokenIn, r.router, amountIn);

        (bool ok, bytes memory ret) = r.router.call(_patched(r.data, r.amountInOffset, amountIn));
        if (!ok) revert RouterCallFailed(ret);

        // Leave no standing allowance on a router this contract does not control.
        SafeTransferLib.forceApprove(r.tokenIn, r.router, 0);

        uint256 out = SafeTransferLib.balanceOf(r.tokenOut, address(this)) - r.outBefore;
        if (out < r.minOut) revert InsufficientOutput(out, r.minOut);

        // Settlement pulls the maker's output next, through Permit3's
        // direct-approval fallback. Approve `maxPay` and NOT the whole proceeds:
        //   • it CAPS the pull — a fill that would take more reverts here rather
        //     than in the solver's P&L;
        //   • the surplus is never approved, so the spread stays this contract's
        //     and no allowance survives the fill over it.
        // `0` means "no cap", and the cap it then takes is THIS FILL's proceeds,
        // never the contract's balance — the maker's signed band is still the hard
        // bound, so the worst case is the price the solver evaluated when it bid.
        // A `maxPay` above the proceeds is clamped for the same reason: an
        // over-stated cap must not reach into residue.
        uint256 cap = r.maxPay == 0 || r.maxPay > out ? out : r.maxPay;
        SafeTransferLib.forceApprove(r.tokenOut, address(SETTLEMENT), cap);
    }
}
