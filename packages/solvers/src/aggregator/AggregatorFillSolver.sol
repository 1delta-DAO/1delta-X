// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {PackedArraysMem} from "@core/settlement/PackedArraysMem.sol";
import {Settlement, Order, CallbackMode} from "@core/settlement/Settlement.sol";
import {DutchAuction} from "@core/settlement/DutchAuction.sol";

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
///  The flow (`CallbackMode.PostInputsDirect` — Fusion's `takerInteraction` ordering)
///  ─────────────────────────────────────────────────────────────────────────
///    1. `executeFill` → `settlement.fillWithCallback(..., PostInputs)`.
///    2. Settlement pays the maker's `tokenIn` to `ctx.filler` — THIS contract,
///       because this contract is the `msg.sender` of the fill.
///    3. EXECUTOR calls `onFill` here: approve `router`, fire the aggregator's
///       calldata, check the proceeds against `minOut`.
///    4. Settlement pulls `tokenOut` from this contract (Permit3, falling back to
///       a direct `transferFrom`) and delivers it to the maker.
///
///  Step 4 is why `onFill` approves Settlement for the proceeds, and why the
///  fill is started as {CallbackMode.PostInputsDirect}: this contract never
///  holds a Permit3 allowance, so the pull would probe Permit3, fail, read the
///  strict flag and only then fall back to the ERC20 `transferFrom` — 8.2k
///  gas per fill for nothing. The DIRECT bit tells the core to go straight to
///  the `transferFrom` for the FILLER'S legs (the maker's pull is untouched).
///
///  DIRECT DELIVERY — the cheap path, for orders that allow it
///  ─────────────────────────────────────────────────────────
///  An order signed with `timing` bit 104 ({DutchAuction.deltaVerifyOutputs})
///  asks the core to VERIFY each output recipient's balance increase instead
///  of pulling from the filler. For this contract that means step 3 can route
///  the swap output straight to the maker and steps 4 and its cleanup vanish:
///  no Settlement approval, no failed-Permit3 probe on the pull, no `tokenOut`
///  ever touching this contract. Measured −27k execution gas per fill against
///  the pull path on the two-token benchmark (see `test/AggregatorFillGas.t.sol`).
///  The route must then be quoted with `recipient = order.maker` and, to keep
///  the spread, as EXACT-OUTPUT for the priced amount: the input the router
///  does not consume stays here and is split in `tokenIn` units by the same
///  policy (the F28 residue path). Detected from the order, never chosen by the
///  caller — the maker signed the delivery mode, the core enforces it, and a
///  route that pays the wrong recipient simply fails the core's delta check.
///  `minOut` and `maxPay` are ignored on this path (nothing is measured or
///  pulled here); the route's own `amountInMaximum` is the solver's protection.
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
///  A {Proportional} ("sell my balance") order: pass `fillAmount =
///  type(uint256).max` and set `amountInOffset`. `fillWithCallback` then fills the
///  whole anchor as resolved at inclusion, and the patched route swaps exactly that.
///  It is safe for THIS contract because it never pays the maker's fixed output
///  from its own balance: a balance that shrank since the quote swaps less, cannot
///  cover the output, and the fill reverts (Settlement is approved for no more than
///  this swap produced); one that grew is a bigger swap, and every {SurplusPolicy}
///  share and originator carve-out is a fraction of that measured spread. See
///  docs/proportional-legs.md.
///
///  ⚠ THE OFF-CHAIN QUOTE MUST NAME THIS CONTRACT. Aggregators bake the
///  recipient (and often the sender) into the calldata they return. A route
///  quoted for the solver's EOA sends the swap output to that EOA, and the fill
///  then reverts here with {InsufficientOutput} — the funds are not lost, but the
///  round is. Quote with `recipient = address(thisSolver)`.
///
///  Trust model: `executeFill` is callable by anyone unless {GATED}. For an
///  ordinary PULL-delivery order on a per-fill-approval instance the security
///  boundary is the maker's signed order plus their Permit3 allowances, exactly as
///  in a plain `fill`, and the gate is not needed for it. The gate IS load-bearing
///  for everything that hands the caller's calldata more than this fill's deltas —
///  {STANDING_ALLOWANCE}, delta-verify orders, a non-zero {SurplusPolicy} and retain
///  mode all REQUIRE it (see the operator-set note below; corrected in audit
///  2026-09-30 AGG-5, this used to read "the gate is never relied on"). THREE things
///  make the open case safe, and all three are load-bearing:
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
///    3. NO ALLOWANCE SURVIVES THE FILL — on a per-fill-approval instance. The
///       router allowances are zeroed inside `onFill`; Settlement's are zeroed in
///       `executeFill` after the fill returns, so a standing approval can never be
///       paired with a later balance. A {STANDING_ALLOWANCE} instance gives this up
///       on the INPUT side by construction (the router approvals stay), which is
///       exactly why such an instance must be {GATED}; Settlement's approvals are
///       still cleared on every instance.
///
///  Holding nothing between fills is therefore NOT a security assumption —
///  residue is unreachable by the next caller — and the gas-optimal way to run
///  this contract deliberately holds some. Every inbound transfer to a ZERO
///  balance slot costs the token's 0→non-zero SSTORE (≈20k), twice per fill
///  (`tokenIn` arrives, `tokenOut` arrives), and the matching refunds are capped
///  per transaction. Keep a floor of each traded token here — one wei is enough
///  — and both writes become non-zero→non-zero (measured: 222.7k → 178.9k
///  execution gas on the two-token benchmark). `RoutePlan.profitRecipient ==
///  address(this)` (retain mode, {_splitSurplus}) maintains that floor by
///  itself, since the filler's share of the spread simply stays put — and is
///  therefore only allowed on a {GATED} instance, whose operators can take it out
///  again with {sweep}. Every amount `executeFill` moves is a delta of the current
///  fill, so on an open instance a retained balance could never leave; retain mode
///  is refused there ({RetainNeedsOperators}; audit 2026-09-30 AGG-1).
///
///  OPTIONAL OPERATOR SET — load-bearing for every mode beyond the plain one
///  ────────────────────────────────────────────────────────────────────────
///  `executeFill` may be restricted to an immutable set of operators, fixed at
///  construction exactly like the routers (no owner, no setter; an empty set
///  means permissionless). For an ordinary (pull-delivery) order on a per-fill
///  instance none of the three points above depends on it: the maker is protected
///  by the signed band and the router allowlist whoever calls. FOUR things DO
///  require it, and the constructor / `_plan` enforce each: standing allowances
///  ({StandingNeedsOperators}), delta-verify orders ({DirectNeedsOperators}), a
///  non-zero surplus policy ({PolicyNeedsOperators}) and retain mode
///  ({RetainNeedsOperators}). In all four the router calldata is the caller's, and
///  on an open instance that caller is anyone.
///
///  ⚠ THE TRUST BOUNDARY IS WHOEVER WRITES THE ROUTE, not only the operator key
///  (audit 2026-09-30 AGG-4). "Operator-tier trust" covers the calldata an operator
///  SUBMITS — and an off-chain executor that takes `tx.to` / `tx.data` verbatim from
///  a third-party route API (packages/auction's Sushi and Nordstern sources) puts
///  that API inside the boundary too. On a per-fill instance a hostile route can
///  spend only this fill's deltas or the fill reverts; on a STANDING instance it
///  can spend every primed token. Before submitting on a standing instance, decode
///  and validate API calldata (allowlisted selectors; tokens and recipients
///  against the order), or route third-party API quotes through a per-fill
///  instance.
///
///  SUPPORTED SHAPES (audit 2026-09-30 AGG-2 / AGG-6): any number of input and
///  output legs over at most {MAX_TOKENS} distinct tokens (each measured, approved
///  and split on its own delta — see {FillRoute}); one router call per fill, no
///  native value. NOT supported, by the core rather than by this contract: orders
///  with ITEMS (the core's `PostInputs` mode is item-free —
///  `ReverseModeRequiresNoItems`), and single-signature PermitBatchWitness orders
///  (`fillWithPermit` has no callback entry), which only an inventory filler can
///  serve. What it changes otherwise is WHO Settlement sees as the filler. The exclusivity
///  gate compares `order.exclusiveFiller` to `msg.sender` of the fill, which is
///  THIS contract — so an order that names this instance as its exclusive filler
///  is, on a permissionless instance, exclusive to anyone willing to route
///  through it. A gated instance makes "only these operators fill" literally
///  true for such orders, which is what a capped beta or a solver that wants
///  the whole remainder needs. Supporting a new operator means deploying
///  another instance, the same trade the router set makes.
/// @notice One aggregator route, as the solver received it off-chain.
/// @param router the venue's entrypoint, from the quote
/// @param minOut floor on the swap proceeds — SOLVER-side protection against a
///        stale route; the maker's own floor is the signed band Settlement enforces.
///        Ignored on a direct-delivery order (see the contract note)
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
/// @param profitRecipient where the FILLER'S share of the spread goes once the
///        maker is paid and the {SurplusPolicy} has taken the maker's and the
///        protocol's shares; `address(0)` = `msg.sender`; the solver contract
///        itself = keep it here (retain mode — no transfer, and the balance
///        floor that makes the next fill cheaper; see the note on holding
///        nothing between fills). Retain mode is accepted on a {GATED} instance
///        only, whose operators recover it with {AggregatorFillSolver.sweep}
///        ({AggregatorFillSolver.RetainNeedsOperators})
/// @param originator the party that sourced the order (frontend, wallet, API
///        integrator) — paid `originatorPpm` of the output surplus. `address(0)`
///        with `originatorPpm == 0` = no originator share
/// @param originatorPpm the originator's share of the output surplus, in parts
///        per million. Carved out of the FILLER'S remainder — the maker's and
///        the protocol's immutable shares come first — so a caller can only give
///        away what would otherwise be its own; the sum of the three must not
///        exceed {PPM}
/// @param data  the aggregator's own calldata, quoted with `recipient = the solver`
struct RoutePlan {
    address router;
    uint256 minOut;
    uint256 maxPay;
    uint256 amountInOffset;
    address profitRecipient;
    address originator;
    uint32 originatorPpm;
    bytes data;
}

/// @notice How this instance splits the OUTPUT SURPLUS of a fill — the `tokenOut`
///         the route produced beyond what Settlement delivered against the
///         maker's signed price. Fixed at construction, like the router set.
///
///  WHY THIS IS THE PLACE, and not the settler
///  ──────────────────────────────────────────
///  Settlement never sees a conversion's surplus: a solver holds the maker's
///  input, swaps it wherever it likes and delivers exactly the priced amount, so
///  anything above the auction tick stays in the solver's own contract and no
///  settler-side rule can reach it. A split is only ENFORCEABLE where the swap
///  itself runs in observable custody — which is precisely what this contract
///  is (the same reason 0x Settler can run `POSITIVE_SLIPPAGE`: it IS the
///  swapper). So the mechanic lives here, and a filler that would rather keep
///  100% of the spread is free to run its own contract and compete in the auction.
///
///  ⚠ IT BINDS THE SPREAD THAT REACHES THIS CONTRACT, i.e. ROUTES THE OPERATORS
///  WRITE (audit 2026-09-30 AGG-3; this note used to say "applies to every fill
///  routed through this instance whoever calls it"). The route calldata is the
///  caller's and opaque here: a multicall recipient split, `pull` + `sweepToken`,
///  or a caller-chosen executor can send part of the input or output elsewhere so
///  the spread never lands here and every share reads zero. No on-chain check can
///  tell that apart from a worse quote. So a non-zero policy is only meaningful
///  where the callers are trusted to write honest routes — the constructor refuses
///  one on an open instance ({PolicyNeedsOperators}) — and the originator
///  carve-out "out of the filler's own remainder" is a rule for those routes, not a
///  bound on a hostile caller.
///
///  The split is by construction the ANALOGUE of what non-conversion orders
///  already have: on a deposit the relayer earns a rising fee leg and the
///  originator a fee leg, both maker-signed (docs/originator-fees.md,
///  docs/relayer-fees.md). On a conversion the maker-signed pieces are the
///  auction band (the filler's spread) and any fee leg (the originator's
///  floor); the surplus split adds the VARIABLE part on top — price improvement
///  back to the maker, a protocol share for whoever provides the route, and an
///  originator share out of the filler's remainder.
///
/// @param makerPpm share of the output surplus returned to `order.maker` as
///        price improvement, in parts per million
/// @param protocolPpm share of the output surplus paid to `protocolRecipient` —
///        the API / route provider — in parts per million
/// @param protocolRecipient where the protocol share goes; must be non-zero when
///        `protocolPpm` is
struct SurplusPolicy {
    uint32 makerPpm;
    uint32 protocolPpm;
    address protocolRecipient;
}

/// @dev Parts per million — the unit every surplus share is expressed in.
uint256 constant PPM = 1_000_000;

/// @dev `RoutePlan.amountInOffset` sentinel: use the aggregator's calldata verbatim.
uint256 constant NO_PATCH = type(uint256).max;

/// @notice The resolved route handed to {AggregatorFillSolver.onFill}.
/// @dev    A STRUCT rather than a parameter list, deliberately. The flat form hit
///         the stack limit at six arguments under the legacy profile this package
///         compiles with, and every future field would hit it again; a struct
///         costs one memory pointer and makes the shape extensible.
///
///         THE TOKEN SET (audit 2026-09-30 AGG-2 / AGG-6). Every DISTINCT token the
///         order's legs name, input legs first — so `tokens[0]` is always
///         `legsIn[0]`'s token, the anchor the route swaps. `inMask` / `outMask`
///         flag which of them an input / output leg pays (a token can be both: a
///         same-token order, a fee leg in the input token). Each is measured
///         against its own pre-fill snapshot in `before`, so a second input leg in a
///         third token is routed (its delta is approved to the router) and its
///         residue split — it used to be paid here and never looked at again — and
///         every output token is approved to Settlement at ITS OWN measured
///         proceeds, so the pull path is no longer limited to one output token.
struct FillRoute {
    address router;
    uint256 minOut;
    uint256 maxPay;
    uint256 amountInOffset;
    /// @dev The order's distinct leg tokens; `tokens[0]` = `legsIn[0]`'s token.
    address[] tokens;
    /// @dev Each token's balance, taken in `executeFill` BEFORE Settlement moved
    ///      anything. Everything `onFill` spends is measured against these, so the
    ///      callback can only ever reach this fill's own proceeds. `0` (unread) for
    ///      an output-only token on the direct path, which never lands here.
    uint256[] before;
    /// @dev Bit `k` set = `tokens[k]` is paid to this contract by an input leg.
    uint256 inMask;
    /// @dev Bit `k` set = `tokens[k]` is owed by an output leg.
    uint256 outMask;
    /// @dev Index in `tokens` of `legsOut[0]`'s token — the one `minOut` and
    ///      `maxPay` apply to.
    uint256 outAnchor;
    /// @dev The order carries {DutchAuction.deltaVerifyOutputs}: the route pays
    ///      the maker itself and this contract never approves Settlement.
    bool direct;
    bytes data;
}

contract AggregatorFillSolver {
    Settlement public immutable SETTLEMENT;
    /// @dev The allowance-less trampoline that makes every callback. Read once at
    ///      construction: it is an immutable of Settlement and never changes.
    address public immutable EXECUTOR;

    /// @dev 1 = idle; 2 = inside a fill this contract started, callback armed;
    ///      3 = inside that fill, callback consumed (the route ran). Held at 3
    ///      through the surplus split, so neither a reentrant `executeFill` (from a
    ///      router, or a hook token paid out by the split) nor {sweep} can run
    ///      mid-fill (audit 2026-09-30 AGG-1 / AGG-8).
    uint256 private _active = 1;

    /// @notice Most distinct leg tokens one order may name — see {FillRoute}.
    uint256 public constant MAX_TOKENS = 8;

    /// @dev The venues `onFill` may call, and the callers `executeFill` admits.
    ///      Both sets are IMMUTABLES rather than mappings: a mapping membership
    ///      test is a cold SLOAD (2,100 gas) on every fill, an immutable compare is
    ///      bytecode (measured −2,090 per fill for the router set alone). The
    ///      price is a hard cap of {MAX_SET} entries per set, which is the size
    ///      these sets actually have — one or two venues a route can name, one or
    ///      two bots that drive a gated instance. Unused slots repeat entry 0 so
    ///      the membership test needs no count. Fixed at construction, no setter:
    ///      the sets are part of this instance's identity, exactly as the
    ///      cosigner is for {CosignedQuotePriceModule}; supporting a new venue or
    ///      operator means deploying another instance, which keeps the contract
    ///      ownerless.
    uint256 public constant MAX_SET = 4;
    address private immutable ROUTER0;
    address private immutable ROUTER1;
    address private immutable ROUTER2;
    address private immutable ROUTER3;
    address private immutable OPERATOR0;
    address private immutable OPERATOR1;
    address private immutable OPERATOR2;
    address private immutable OPERATOR3;

    /// @notice Whether `executeFill` is restricted to {isOperator}. Immutable:
    ///         `true` iff the constructor was given a non-empty operator set.
    bool public immutable GATED;

    /// @notice Whether this instance funds its routes from STANDING approvals
    ///         instead of approving and clearing on every fill.
    ///
    ///  Measured on a live Rootstock pool: approving per fill and clearing after
    ///  costs 132,740 gas against 98,545 with a standing approval — 34,195, or
    ///  13% of a whole DEX-routed fill, spent writing an allowance slot to a value
    ///  it will hold again next time. On a chain where a fill has to be worth
    ///  racing for, that is the single largest avoidable item.
    ///
    ///  ⚠ WHAT IT GIVES UP, AND THE CHECK THAT MUST PRECEDE IT. With this on, the
    ///  contract's "no allowance survives the fill" property no longer holds for
    ///  the INPUT side, and the routers can reach whatever sits here between fills
    ///  — the balance floor and the retained spread. That is acceptable ONLY for a
    ///  router that pulls exclusively from its own `msg.sender`. Uniswap's
    ///  SwapRouter02 does: it encodes `payer = msg.sender` into the callback data
    ///  of its own swap, and its `uniswapV3SwapCallback` runs
    ///  `CallbackValidation.verifyCallback`, which recomputes the pool address and
    ///  rejects any caller that is not that pool. So a stranger cannot make it pull
    ///  from here DIRECTLY; only this contract's own calls can.
    ///  Both halves were exercised against the live router, not reasoned about.
    ///
    ///  ⚠ BUT "THIS CONTRACT'S OWN CALLS" CARRY THE CALLER'S CALLDATA (re-audit F30,
    ///  the multicall-router lesson one hop out). `onFill` forwards `plan.data`
    ///  verbatim, and inside it the router's `msg.sender` IS this contract — so a
    ///  caller who writes `exactInputSingle(tokenIn = any primed token, recipient =
    ///  self)`, or `pull` + `sweepToken`, spends the standing approval on a token
    ///  this fill never touched. `RouteOverspent` bounds only `tokenIn`, and a
    ///  direct-delivery fill skips the `tokenOut` measurement entirely. The router
    ///  allowlist pins WHERE the call goes, not WHAT it says. So a standing instance
    ///  must be {GATED}: the constructor refuses `standing` with no operators
    ///  ({StandingNeedsOperators}), which makes the approvals spendable only by
    ///  calldata an operator wrote — operator-tier trust, the same tier that already
    ///  decides every route.
    ///
    ///  MANY AGGREGATORS DO NOT HAVE THAT PROPERTY — an API that takes a `payer`,
    ///  `from` or permit-forwarding parameter lets any caller name this contract
    ///  as the payer, and a standing approval then IS a standing drain. Verify it
    ///  per router before deploying an instance with this on. An instance that
    ///  cannot make that claim about every one of its routers must deploy with it
    ///  off; the flag is immutable precisely so the choice is made once, in public,
    ///  and is visible in the deployment record.
    bool public immutable STANDING_ALLOWANCE;

    /// @notice Whether `onFill` may call `r` — see the note on the immutable sets.
    function isAllowedRouter(address r) public view returns (bool) {
        return r == ROUTER0 || r == ROUTER1 || r == ROUTER2 || r == ROUTER3;
    }

    /// @notice Whether `who` may call `executeFill` on a {GATED} instance. Always
    ///         `false` on an open one, where the question does not arise.
    function isOperator(address who) public view returns (bool) {
        return GATED && (who == OPERATOR0 || who == OPERATOR1 || who == OPERATOR2 || who == OPERATOR3);
    }

    /// @notice Grant every allowlisted router a maximal standing approval over
    ///         `token`. PERMISSIONLESS, and safe to be: it can only ever create an
    ///         approval this instance already declared by construction — to a
    ///         router in its immutable set, on an instance whose
    ///         {STANDING_ALLOWANCE} is on. It adds no authority anyone could not
    ///         already cause by sending one fill.
    ///
    /// @dev    DECLARED, NOT DISCOVERED. `onFill` does NOT check whether a token
    ///         is primed — that check is a storage read on every fill forever, to
    ///         answer a question the operator knows once. A fill in an unprimed
    ///         token instead fails at the router's own pull, which costs the caller
    ///         its own gas and nothing else, and is fixed by anyone calling this.
    ///         Prime each traded token at deployment; the constructor does it for
    ///         the tokens it is given.
    function prime(address token) public {
        if (!STANDING_ALLOWANCE) revert NotStandingAllowance();
        SafeTransferLib.forceApprove(token, ROUTER0, type(uint256).max);
        if (ROUTER1 != ROUTER0) SafeTransferLib.forceApprove(token, ROUTER1, type(uint256).max);
        if (ROUTER2 != ROUTER0 && ROUTER2 != ROUTER1) SafeTransferLib.forceApprove(token, ROUTER2, type(uint256).max);
        if (ROUTER3 != ROUTER0 && ROUTER3 != ROUTER1 && ROUTER3 != ROUTER2) {
            SafeTransferLib.forceApprove(token, ROUTER3, type(uint256).max);
        }
        emit Primed(token);
    }

    /// @notice The surplus split — see {SurplusPolicy}. Immutable for the same
    ///         reason the router set is: `executeFill` is permissionless, so a
    ///         mutable policy would be one more thing a caller could turn on
    ///         itself.
    uint32 public immutable MAKER_SURPLUS_PPM;
    uint32 public immutable PROTOCOL_SURPLUS_PPM;
    address public immutable PROTOCOL_RECIPIENT;

    /// @notice One fill's output-surplus split. `toFiller` is what reached
    ///         `RoutePlan.profitRecipient`; the input-side residue (an
    ///         under-consumed route) is NOT surplus and goes there unlogged.
    event SurplusSplit(
        address indexed token,
        address indexed maker,
        uint256 toMaker,
        uint256 toProtocol,
        uint256 toOriginator,
        uint256 toFiller
    );

    /// @notice A token was given standing approvals to this instance's routers.
    event Primed(address indexed token);

    /// @notice An operator took retained value out — see {sweep}.
    event Swept(address indexed token, address indexed to, uint256 amount);

    error OnlyExecutor();
    /// @dev `makerPpm + protocolPpm + originatorPpm` exceeded {PPM}, or a
    ///      non-zero share named `address(0)` as its recipient.
    error BadSurplusSplit();
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
    /// @dev {GATED} and the caller is not in {isOperator}.
    error NotOperator(address caller);
    /// @dev The route spent more `tokenIn` than this fill delivered, i.e. it
    ///      reached into what the contract was already holding. Only reachable on
    ///      a {STANDING_ALLOWANCE} instance, where the allowance no longer caps it.
    error RouteOverspent();
    /// @dev An operator set may not contain `address(0)` — it could never call,
    ///      so its only effect would be to flip {GATED} on by accident.
    error BadOperator();
    /// @dev A set is empty where it may not be (routers) or larger than {MAX_SET}.
    error BadSetSize();
    /// @dev {prime} on an instance that approves per fill — there is nothing to
    ///      prime, and creating a standing approval anyway would silently give the
    ///      instance the very property it was deployed without.
    error NotStandingAllowance();
    /// @dev A {STANDING_ALLOWANCE} instance with no operator set. See the note on
    ///      {STANDING_ALLOWANCE}: the route calldata is the CALLER's, so an open
    ///      standing instance hands every stranger its approvals.
    error StandingNeedsOperators();
    /// @dev A delta-verify (direct-delivery) order on an instance with no operator
    ///      set. See {_plan}: naming this contract as the order's filler hands the
    ///      delivery check to its access control, so it must have some.
    error DirectNeedsOperators();
    /// @dev A non-zero {SurplusPolicy} on an instance with no operator set — see the
    ///      ⚠ on {SurplusPolicy}: an open caller writes the route and can keep the
    ///      spread from ever reaching the split.
    error PolicyNeedsOperators();
    /// @dev `RoutePlan.profitRecipient == address(this)` (retain mode) on an open
    ///      instance, where nothing could ever move the retained value out again.
    error RetainNeedsOperators();
    /// @dev `executeFill` or {sweep} entered while a fill is in flight.
    error Reentrancy();
    /// @dev The order names more than {MAX_TOKENS} distinct leg tokens.
    error TooManyTokens();
    /// @dev `legsIn[0]` / `legsOut[0]` must exist before their tokens can be read —
    ///      {PackedArraysMem} is an unchecked reader, and a blob declaring zero
    ///      legs with trailing bytes would otherwise name an arbitrary token.
    error NoLegs();

    /// @param routers     the venues `onFill` may call — see {isAllowedRouter}
    /// @param operators   who may call `executeFill`; empty = anyone — see {GATED}
    /// @param standing    fund routes from standing approvals — see {STANDING_ALLOWANCE}
    /// @param primeTokens tokens to {prime} now; only with `standing`
    constructor(
        address settlement,
        address[] memory routers,
        address[] memory operators,
        SurplusPolicy memory policy,
        bool standing,
        address[] memory primeTokens
    ) {
        if (uint256(policy.makerPpm) + policy.protocolPpm > PPM) revert BadSurplusSplit();
        if (policy.protocolPpm != 0 && policy.protocolRecipient == address(0)) revert BadSurplusSplit();
        if ((policy.makerPpm != 0 || policy.protocolPpm != 0) && operators.length == 0) {
            revert PolicyNeedsOperators();
        }
        MAKER_SURPLUS_PPM = policy.makerPpm;
        PROTOCOL_SURPLUS_PPM = policy.protocolPpm;
        PROTOCOL_RECIPIENT = policy.protocolRecipient;
        SETTLEMENT = Settlement(payable(settlement));
        address executor = address(Settlement(payable(settlement)).EXECUTOR());
        EXECUTOR = executor;
        address permit3 = address(Settlement(payable(settlement)).PERMIT3());
        if (routers.length == 0 || routers.length > MAX_SET || operators.length > MAX_SET) revert BadSetSize();
        for (uint256 i; i < routers.length; i++) {
            address r = routers[i];
            if (r == settlement || r == executor || r == permit3 || r == address(this) || r == address(0)) {
                revert RouterIsProtocol(r);
            }
        }
        for (uint256 i; i < operators.length; i++) {
            if (operators[i] == address(0)) revert BadOperator();
        }
        (ROUTER0, ROUTER1, ROUTER2, ROUTER3) = _four(routers);
        GATED = operators.length != 0;
        (OPERATOR0, OPERATOR1, OPERATOR2, OPERATOR3) = _four(operators);
        // Rejected rather than ignored: a deployment that names tokens to prime has
        // stated an intent the `standing = false` instance cannot carry out, and
        // silently deploying the per-fill-approval variant under that name is the
        // kind of divergence nobody notices until the gas bill.
        if (!standing && primeTokens.length != 0) revert NotStandingAllowance();
        if (standing && operators.length == 0) revert StandingNeedsOperators();
        STANDING_ALLOWANCE = standing;
        for (uint256 i; i < primeTokens.length; i++) prime(primeTokens[i]);
    }

    /// @dev Spread a set of 1..{MAX_SET} entries over four slots, repeating entry
    ///      0 into the unused ones. An empty set yields four zero slots, which
    ///      {isOperator} never consults because {GATED} is false.
    function _four(address[] memory set) private pure returns (address a, address b, address c, address d) {
        uint256 n = set.length;
        if (n == 0) return (address(0), address(0), address(0), address(0));
        a = set[0];
        b = n > 1 ? set[1] : a;
        c = n > 2 ? set[2] : a;
        d = n > 3 ? set[3] : a;
    }

    /// @notice Fill `order` by routing the maker's input through `plan.router`.
    /// @param  plan the aggregator route — see {RoutePlan}. Bundled as a struct
    ///         rather than three parameters because the flat form pushes this
    ///         function past the stack limit under the legacy profile this
    ///         package compiles with.
    /// @param  takerData forwarded to the order's validators, invariants and
    ///         price module — carry the cosigned quote here for a
    ///         `ClockFlooredQuoteModule` order.
    /// @dev    The spread is split AFTER the fill returns, because the surplus is
    ///         only knowable once Settlement has taken its share: the maker's and
    ///         the protocol's {SurplusPolicy} shares first, the originator's out
    ///         of what is left, and the remainder to `plan.profitRecipient`.
    ///         Whoever executes takes the risk and keeps that remainder — which is
    ///         what lets this contract stay ownerless and hold nothing between
    ///         fills. On a {GATED} instance "whoever" is one of the constructor's
    ///         operators; everyone else reverts {NotOperator} before any token moves.
    function executeFill(
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmount,
        RoutePlan calldata plan,
        bytes calldata takerData
    ) external returns (uint256[] memory fillAmountsOut) {
        if (GATED && !isOperator(msg.sender)) revert NotOperator(msg.sender);
        if (_active != 1) revert Reentrancy();
        // Built BEFORE the fill, because its snapshots are balances that only mean
        // anything pre-fill — and reused afterwards for the sweep, so the callback
        // and the sweep can never disagree about what this fill created.
        FillRoute memory route = _plan(order, plan);
        _active = 2;
        fillAmountsOut = SETTLEMENT.fillWithCallback(
            order, sig, fillAmount, address(this), _callback(route), CallbackMode.PostInputsDirect, takerData
        );
        // A callback that never ran means the swap never happened, and any
        // delivery that nonetheless succeeded came out of this contract's own
        // balance. Settlement cannot report that, so we check the state only
        // `onFill` could have advanced.
        if (_active != 3) {
            _active = 1;
            revert CallbackDidNotRun();
        }

        // Settlement has taken its share; whatever allowance is left over must not
        // outlive the fill. (Not on the direct path: nothing was approved, and
        // nothing arrived here.)
        //
        // ⚠ THIS IS NOT A HEDGE AGAINST A BUGGY SETTLER, and "Settlement is
        // audited" is not an argument for dropping it. The drain uses Settlement
        // behaving exactly as specified: `_deliverOutputs` pays an order's output
        // legs BY PULLING THEM FROM THE FILLER, and the filler here is this
        // contract, for an order the attacker signed as their own maker. An
        // approval left on a token traded earlier would be directly spendable by a
        // later self-signed order naming that token in an output leg, against the
        // balance floor and the retained spread. PoC'd in
        // {AggregatorStaleApprovalTest} — it drains, and with this loop it cannot.
        uint256 n = route.tokens.length;
        if (!route.direct) {
            for (uint256 k; k < n; ++k) {
                if (route.outMask & (1 << k) != 0) {
                    SafeTransferLib.forceApprove(route.tokens[k], address(SETTLEMENT), 0);
                }
            }
        }

        // Split EVERY token's increase by the same policy. The output surplus is
        // the spread; the input residue — what the route did not consume — is the
        // SAME spread in the other denomination (F28, 2026-09-12); a non-anchor
        // input leg's token is split the same way rather than stranded (audit
        // 2026-09-30 AGG-2).
        //
        // ⚠ THE DELTA, NOT THE BALANCE, and this is a security boundary rather
        // than tidiness. `executeFill` is permissionless and `order` is the
        // caller's, so a whole-balance sweep is a signature-free "send me your
        // balance of any token I name" primitive — the same one
        // {BaseFlashSolver._requireCallbackRan} was written to close. Measuring
        // against the pre-fill snapshot means the caller can only ever take what
        // its own fill produced. Output tokens first, then inputs (reverse order).
        address to = plan.profitRecipient == address(0) ? msg.sender : plan.profitRecipient;
        for (uint256 k = n; k != 0;) {
            unchecked {
                --k;
            }
            // On the direct path an output-only token never lands here.
            if (route.direct && route.inMask & (1 << k) == 0) continue;
            _splitSurplus(route.tokens[k], route.before[k], order.maker, plan, to);
        }
        _active = 1;
    }

    /// @notice Take value this contract holds between fills — the retained spread
    ///         and the balance floor — out. GATED instances only, operators only,
    ///         never mid-fill. Retain mode exists only where this does (audit
    ///         2026-09-30 AGG-1): on an open instance every amount the contract moves
    ///         is a delta of the current fill, so a retained balance could never
    ///         leave, and retain mode is refused there instead.
    /// @dev    Safe for the same reason the operator tier already writes every
    ///         route: nothing held here between fills belongs to anyone else — makers
    ///         are paid and every share is split inside the fill.
    function sweep(address token, address to, uint256 amount) external {
        if (!isOperator(msg.sender)) revert NotOperator(msg.sender);
        if (_active != 1) revert Reentrancy();
        SafeTransferLib.safeTransfer(token, to, amount);
        emit Swept(token, to, amount);
    }

    /// @dev Split this fill's INCREASE in `token` — the spread, in whichever
    ///      denomination it landed — per the {SurplusPolicy} and the plan's
    ///      originator share. Silent when nothing was left over, which is the
    ///      normal case for a route quoted at the maker's price. Shares floor;
    ///      the filler takes the rounding dust along with its remainder, so
    ///      nothing strands here.
    ///
    ///      `plan.originatorPpm` was bounded in {_plan}, BEFORE the fill, so a
    ///      mis-set share fails the round rather than reverting after the maker
    ///      has already been paid.
    function _splitSurplus(address token, uint256 before, address maker, RoutePlan calldata plan, address filler)
        private
    {
        uint256 bal = SafeTransferLib.balanceOf(token, address(this));
        if (bal <= before) return;
        uint256 surplus = bal - before;

        uint256 toMaker = (surplus * MAKER_SURPLUS_PPM) / PPM;
        uint256 toProtocol = (surplus * PROTOCOL_SURPLUS_PPM) / PPM;
        uint256 toOriginator = (surplus * plan.originatorPpm) / PPM;
        // The sum of the three ppm values is ≤ PPM (checked in `_plan`), so the
        // three floors sum to ≤ surplus and this cannot underflow.
        uint256 toFiller = surplus - toMaker - toProtocol - toOriginator;

        if (toMaker != 0) SafeTransferLib.safeTransfer(token, maker, toMaker);
        if (toProtocol != 0) SafeTransferLib.safeTransfer(token, PROTOCOL_RECIPIENT, toProtocol);
        if (toOriginator != 0) SafeTransferLib.safeTransfer(token, plan.originator, toOriginator);
        // RETAIN MODE: a `profitRecipient` of this contract keeps the filler's
        // share here instead of paying it out every fill. Safe because every
        // amount above is a delta — a retained balance is never re-split, never
        // approved and never swept by a later caller — and it is what keeps the
        // contract's balance slots NON-ZERO between fills, so the next fill's
        // inbound transfers rewrite a live slot instead of paying to create one
        // (measured: ~44k execution gas per fill on a two-token route). Only on a
        // GATED instance ({RetainNeedsOperators}), whose operators take it out with
        // {sweep}; see the README on the balance floor.
        if (toFiller != 0 && filler != address(this)) SafeTransferLib.safeTransfer(token, filler, toFiller);
        emit SurplusSplit(token, maker, toMaker, toProtocol, toOriginator, toFiller);
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
    function _plan(Order calldata order, RoutePlan calldata plan) private view returns (FillRoute memory r) {
        bytes memory legsIn = order.legsIn;
        bytes memory legsOut = order.legsOut;
        uint256 nIn = PackedArraysMem.validateLegsIn(legsIn);
        uint256 nOut = PackedArraysMem.validateLegsOut(legsOut);
        if (nIn == 0 || nOut == 0) revert NoLegs();
        // The originator's share is the caller's to give, but only out of its own
        // remainder: the maker's and the protocol's shares are fixed, so the three
        // together may not exceed the whole. Checked here so a bad plan fails
        // before any token moves.
        if (uint256(plan.originatorPpm) + MAKER_SURPLUS_PPM + PROTOCOL_SURPLUS_PPM > PPM) revert BadSurplusSplit();
        if (plan.originatorPpm != 0 && plan.originator == address(0)) revert BadSurplusSplit();
        // RETAIN MODE NEEDS A WAY OUT (audit 2026-09-30 AGG-1): only {sweep} moves a
        // retained balance, and only operators may call it.
        if (plan.profitRecipient == address(this) && !GATED) revert RetainNeedsOperators();
        r.direct = DutchAuction.deltaVerifyOutputs(order);
        // ⚠ A DIRECT (delta-verify) ORDER NEEDS A GATED INSTANCE (re-audit 2026-09-29).
        // The core fills such an order only for its named `exclusiveFiller` — THIS
        // contract — because a balance delta cannot tell the maker's delivery from
        // another inflow the maker paid for elsewhere, so the maker is trusting whoever
        // runs the callback. On an open instance that is anyone: through an allowlisted
        // router that takes a caller-chosen executor (1inch-, 0x-, Odos-style), a
        // stranger could divert this fill's input and settle the maker's OTHER intent
        // inside the callback, and the delta would pass. Only operators may drive one.
        if (r.direct && !GATED) revert DirectNeedsOperators();

        // The distinct token set, inputs first (so tokens[0] is the anchor).
        address[] memory toks = new address[](MAX_TOKENS);
        uint256 n;
        for (uint256 i; i < nIn; ++i) {
            uint256 k;
            (k, n) = _slot(toks, n, PackedArraysMem.legInToken(legsIn, i));
            r.inMask |= 1 << k;
        }
        for (uint256 j; j < nOut; ++j) {
            uint256 k;
            (k, n) = _slot(toks, n, PackedArraysMem.legOutToken(legsOut, j));
            r.outMask |= 1 << k;
            if (j == 0) r.outAnchor = k;
        }
        /// @solidity memory-safe-assembly
        assembly {
            mstore(toks, n) // shrink to the n slots actually used
        }
        r.tokens = toks;
        r.before = new uint256[](n);
        for (uint256 k; k < n; ++k) {
            // Nothing lands here for an output-only token on the direct path, so
            // nothing to measure against.
            if (r.direct && r.inMask & (1 << k) == 0) continue;
            r.before[k] = SafeTransferLib.balanceOf(toks[k], address(this));
        }
        r.router = plan.router;
        r.minOut = plan.minOut;
        r.maxPay = plan.maxPay;
        r.amountInOffset = plan.amountInOffset;
        r.data = plan.data;
    }

    /// @dev Index of `t` in the first `n` entries of `toks`, appending it if new.
    function _slot(address[] memory toks, uint256 n, address t) private pure returns (uint256 k, uint256 newN) {
        for (k = 0; k < n; ++k) {
            if (toks[k] == t) return (k, n);
        }
        if (n == MAX_TOKENS) revert TooManyTokens();
        toks[n] = t;
        return (n, n + 1);
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
        if (!isAllowedRouter(r.router)) revert RouterNotAllowed(r.router);
        _active = 3;

        // Approve (per-fill instances) what THIS FILL delivered of every input
        // token. Balance-DELTA rather than an amount passed in: what the maker paid
        // is Settlement's business and a fee-on-transfer `tokenIn` would make any
        // figure passed here wrong — but the raw balance is equally wrong, because
        // it would also hand the router (and, below, the maker) whatever an earlier
        // fill left parked here. Under-flowing is the correct failure: it means the
        // input never arrived. `tokens[0]` is the anchor whose delta the route's
        // calldata is patched with.
        uint256 amountIn = _approveInputs(r.tokens, r.before, r.inMask, r.router, true);

        (bool ok, bytes memory ret) = r.router.call(_patched(r.data, r.amountInOffset, amountIn));
        if (!ok) revert RouterCallFailed(ret);

        // ⚠ THE PER-FILL APPROVAL WAS ALSO A BOUND, and {STANDING_ALLOWANCE}
        // removes it. `forceApprove(token, router, delta)` capped the route at the
        // delta this fill delivered no matter what the calldata said; a standing
        // approval caps it at this contract's whole balance instead, and the caller
        // picks `amountInOffset` — so it can decline the patch ({NO_PATCH}) or aim
        // it at the wrong word and have the router pull the quoted figure. The
        // balance is then the only thing left, which is the "reach into residue"
        // primitive the delta discipline exists to remove (F28). Restored as a
        // measurement instead of an allowance, for EVERY input token: the route may
        // consume what this fill brought and not one wei more. On a per-fill
        // instance this pass clears the router allowances instead.
        _approveInputs(r.tokens, r.before, r.inMask, r.router, false);

        // Direct delivery: the route paid the maker, the core verifies the delta,
        // and this contract has nothing to measure and nothing to approve.
        if (r.direct) return;

        // Settlement pulls every output leg next, through the direct-approval path.
        // Approve each output token at ITS OWN proceeds of this fill — never the
        // contract's balance — and, for `legsOut[0]`'s token, at most `maxPay`:
        //   • it CAPS the pull — a fill that would take more reverts here rather
        //     than in the solver's P&L;
        //   • the surplus is never approved, so the spread stays this contract's
        //     and no allowance survives the fill over it.
        // `maxPay == 0` means "no cap", and the cap it then takes is THIS FILL's
        // proceeds — the maker's signed band is still the hard bound, so the worst
        // case is the price the solver evaluated when it bid. A `maxPay` above the
        // proceeds is clamped for the same reason: an over-stated cap must not
        // reach into residue.
        _approveOutputs(r.tokens, r.before, r.outMask, r.outAnchor, r.minOut, r.maxPay);
    }

    /// @dev The output pass of {onFill}, over the route's calldata arrays resolved
    ///      ONCE (re-resolving `r.tokens[k]` through the struct on every access is
    ///      measurable on the hot path).
    function _approveOutputs(
        address[] calldata toks,
        uint256[] calldata bef,
        uint256 outMask,
        uint256 outAnchor,
        uint256 minOut,
        uint256 maxPay
    ) private {
        uint256 n = toks.length;
        for (uint256 k; k < n; ++k) {
            if (outMask & (1 << k) == 0) continue;
            address t = toks[k];
            uint256 out = SafeTransferLib.balanceOf(t, address(this)) - bef[k];
            uint256 cap = out;
            if (k == outAnchor) {
                if (out < minOut) revert InsufficientOutput(out, minOut);
                if (maxPay != 0 && maxPay < out) cap = maxPay;
            }
            SafeTransferLib.forceApprove(t, address(SETTLEMENT), cap);
        }
    }

    /// @dev The two input passes around the route call. `pre`: approve each input
    ///      token's delta to the router (per-fill instances) and return the anchor's
    ///      delta. `!pre`: per-fill instances clear those allowances; standing ones
    ///      check no input token dropped below its snapshot ({RouteOverspent}).
    function _approveInputs(
        address[] calldata toks,
        uint256[] calldata bef,
        uint256 inMask,
        address router,
        bool pre
    ) private returns (uint256 amountIn) {
        uint256 n = toks.length;
        for (uint256 k; k < n; ++k) {
            if (inMask & (1 << k) == 0) continue;
            address t = toks[k];
            if (pre) {
                uint256 d = SafeTransferLib.balanceOf(t, address(this)) - bef[k];
                if (k == 0) amountIn = d;
                // The approval is per-fill unless this instance runs on standing
                // ones — see {STANDING_ALLOWANCE} for what that trades away.
                if (!STANDING_ALLOWANCE) SafeTransferLib.forceApprove(t, router, d);
            } else if (STANDING_ALLOWANCE) {
                if (SafeTransferLib.balanceOf(t, address(this)) < bef[k]) revert RouteOverspent();
            } else {
                // Leave no standing allowance on a router this contract does not control.
                SafeTransferLib.forceApprove(t, router, 0);
            }
        }
    }
}
