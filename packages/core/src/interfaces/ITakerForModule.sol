// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ITakerForModule
/// @notice A COMPOSITE adapter: one call that draws value out of a user's position
///         and funds the value-in side of the same position operation — "take
///         `amount`, FOR `forAmount`". Deposit + borrow, repay + withdraw, repay A
///         + borrow B, withdraw A + deposit B.
///
///  Why the pair belongs in one call
///  ────────────────────────────────
///  Most lenders check health INSIDE the value-out call (Aave, Comet, Morpho), and
///  the batch-native ones (Euler's `EVC.batch`, Fluid/Dolomite `operate`) run ONE
///  status check per batch. Expressed as two items — `MAKE` then `TAKE` — the
///  ordering is a SCHEDULING obligation the filler has to honour, and on the
///  batch-native venues the two legs pay two checks instead of one. Several
///  protocols cannot express the split at all: a Liquity-style `openTrove` needs
///  both amounts, and Fluid's `operate(nftId = 0, …)` mints the new position to
///  `msg.sender`, so a one-leg open strands the collateral in the module.
///
///  Why the second amount comes from the CORE, not from `data`
///  ──────────────────────────────────────────────────────────
///  The obvious shape — put the funding amount in `data` and let the module
///  pro-rate it — was tried and it has two defects. It DUPLICATES a number the
///  order usually already signs (a leverage order's collateral is `legsOut[j]`,
///  delivered to the maker moments earlier), so a mis-scaled copy silently
///  desyncs from the leg: too large pulls up to the maker's standing Permit3
///  token allowance, too small under-collateralises or reverts at fill time.
///  And a constant `data` amount does not pro-rate, so every partial fill
///  re-executes it in FULL — the defect {FullFillGuard} exists to reject.
///
///  So `forAmount` is computed by {Base._forSlice} from a DESCRIPTOR the maker
///  signs as the FIRST WORD of `data`:
///
///    • top bit SET  → LEG REFERENCE. The low 16 bits index `legsOut`, and
///      `forAmount` is that leg's priced amount for this fill ({Pricing.outputAt})
///      — the SAME call that decided what the solver just delivered, so the two
///      cannot disagree and the maker's net balance in that token over the fill is
///      zero. Nothing is duplicated: the amount, its token and its decimals live in
///      the typed leg the maker already signed, and a decaying leg carries its
///      auction price straight into the funding side, which a static ratio cannot do.
///    • top bit CLEAR → LITERAL TOTAL, for a funding leg with no matching output
///      (the maker funds it from their own wallet — a fresh Fluid position, a new
///      trove). The core slices it with the SAME differencing it applies to
///      `amount`, so N partial fills sum EXACTLY to the signed total: no ceil
///      drift, no over-pull.
///    • top TWO bits SET → BALANCE-RELATIVE, `min(balanceOf(token, maker), cap)`,
///      bounded BOTH ways. The token is the descriptor's low 160 bits, the cap is
///      `data`'s SECOND word and is MANDATORY, and bits [160:176) carry a FLOOR in
///      bps of that cap — below it the fill reverts ({Base.ForBalanceBelowFloor})
///      rather than funding a fraction of the position while the value-out leg
///      draws in full. The cap is there because anyone can RAISE a maker's balance;
///      the floor is there because whoever sequences fills can LOWER it — filling
///      another of the maker's live orders in the same token shrinks this leg
///      without touching this fill. The form is for the no-conversion shape, where
///      the maker cannot know the amount at signing time (accrued interest, an
///      in-flight transfer, a wallet sweep). FULL-FILL ONLY: a live balance cannot
///      pro-rate, so the core rejects a sliced fill outright
///      ({Base.ForBalanceNeedsFullFill}).
///
///  With the balance form the blob is `abi.encode(forDesc, cap, …)` — the cap is
///  field 1, so a module's own decode shifts by one word relative to the other two
///  forms.
///
///  `data` is passed through WHOLE, descriptor word included, so the taker
///  allowance `ref = keccak256(data)` still covers it and a filler cannot alter
///  which leg funds the op. Lay the blob out as
///  `abi.encode(uint256 forDesc, …)` and the descriptor is simply the first
///  field of an ordinary `abi.decode`.
///
///  Trust model
///  ───────────
///  Both legs stay bounded by something the maker signed, and by DIFFERENT books:
///    • the value-OUT leg by the Permit3 TAKER allowance
///      `(user, Settlement, module, keccak256(data))`, decremented by
///      {TakerAllowance.takeFor} before this function is entered;
///    • the value-IN leg by the maker's Permit3 TOKEN allowance to this module —
///      and, above that, by the signed leg or literal the descriptor names.
///
///  ⚠ ONE GRANT, ONE DISPATCH. The taker book does NOT distinguish `take` from
///  `takeFor`: both consume the same `(user, spender, module, keccak256(data))`
///  bucket. A contract implementing BOTH {ITakerModule} and this interface would
///  therefore let a single `approveTaker` grant authorise either shape — the plain
///  take or the composite one with a funding leg attached. Settlement picks the
///  entrypoint from the maker-signed `op` byte, so a filler cannot switch it, but a
///  maker reading their grant could not tell which they authorised.
///
///  ⚠ THE RULE IS THE DATA-SPACE SPLIT, NOT "ONE MODULE, ONE SHAPE" — and this
///  header said otherwise, which is itself the §F23 failure mode it invokes below.
///  It claimed `make modules-check` "fails the build on any contract declaring both
///  `takeOnBehalf` and `takeForOnBehalf`". It does not, and has not since the merge
///  was allowed: the checker's own header states "a contract MAY now implement both,
///  but ONLY with both guards present", and one shipped contract
///  (`AaveV3CreditModule`) does exactly that.
///
///  What is actually enforced is the weaker property that suffices: NO `data` blob is
///  accepted by both entrypoints, so no `ref` can ever be valid for both and the grant
///  is unambiguous again. A merged contract asserts its own half in each —
///  {PreFundGuard.requireLegRef} or {PreFundGuard.requireFundingDescriptor} in
///  `takeForOnBehalf`, {PreFundGuard.requirePlainTake} in `takeOnBehalf` — and
///  `tools/check-module-shapes.py` fails the build if a dual-shape contract is missing
///  either guard. Implement one shape per contract, or both WITH both guards; never
///  both without them. See `docs/reference-audits.md` F23 for why a rule that holds
///  only because every current integrator follows it is not a rule — which applies to
///  a rule the docs assert and the checker does not, too.
///
///  Pull-funded vs PRE-FUNDED — the approval surface
///  ──────────────────────────────────────────────────
///  A composite module comes in one of two funding shapes, and a maker signs the
///  leg recipient to match:
///    • PULL (classic): the funding leg is delivered to the MAKER and the module
///      pulls it back with `permit3.transferFrom` — which needs the maker's Permit3
///      token allowance to the module AND, beneath it, an on-chain ERC20 approval
///      of the funding token to Permit3 (a token the maker may never have held:
///      the delivered collateral on a cross-asset open, the debt token on every
///      deleverage).
///    • PRE-FUND: the maker signs `legsOut[j].recipient = module` — {Base._forSlice}
///      admits the item's own module as the referenced leg's recipient — and the
///      module supplies the instructed `forAmount` from its OWN balance. No pull,
///      no token allowance, no ERC20 approval: the maker's only grant is the taker
///      allowance, and the fill makes one less transfer. Pooled balances cannot be
///      consumed across orders ONLY while both halves below hold — F27/C-1 broke
///      each of them independently, and this prose asserted the conclusion without
///      either premise being enforced:
///        (1) `forAmount` is core-sized. TRUE only when `spender == SETTLEMENT`;
///            `Permit3.approveTaker` lets any caller name itself spender, so a
///            direct `takeFor` supplies an arbitrary `forAmount`. Modules MUST
///            check the forwarded `spender`.
///        (2) the delivery landed HERE. NOT implied by (1): {Base._forSlice} binds
///            neither the referenced leg's recipient nor its token. Modules MUST
///            take the balance floor below.
///      This accounting is exactly why pre-fund-funding exists ONLY on the TAKE_FOR
///      seam: a module funding from balance against a number the core did NOT size
///      to an enforced delivery (a maker-signed MAKE total, a module-invented
///      amount) lets one order's item consume another order's delivery.
///  One CONTRACT implements one shape (a pre-fund module simply never calls
///  `transferFrom`). Mis-pairing fails closed ONLY through an explicit floor:
///  `uint256 floor = IERC20(asset).balanceOf(address(this)) - forAmount;` as the
///  first act of the funded body. The underflow IS the check — a leg not addressed
///  to this module leaves `entry < forAmount`. It is a real mis-pairing detector
///  only because (1) above pins `forAmount` to the core; with an attacker-chosen
///  `forAmount` the same subtraction proves nothing (F27/C-4), which is how the one
///  module that had it was still drained. Sweeps clamp to `bal - floor`, never the
///  whole balance.
///
///  Pre-funding also carries the ONE-SIDED ops (deposit-only, repay-only —
///  "supply/retire whatever the conversion delivered"): a composite whose
///  value-OUT side moves NOTHING. `amount` is then a pacing figure (sign the
///  order's anchor total) and the taker allowance is read as the maker's
///  execution authorization for `(module, keccak256(data))` rather than as an
///  asset bound — still granted by signature, so the shape costs zero on-chain
///  approvals end to end. See the `AaveV3PreFundDepositModule` /
///  `AaveV3PreFundRepayModule` headers for why these ride this seam and not MAKE.
///
///  Modules MUST enforce `msg.sender == permit3` as their first statement, for
///  exactly the reason {ITakerModule} gives, and a PRE-FUND module MUST follow it with
///  `spender == SETTLEMENT`: `msg.sender == permit3` alone authorises nothing,
///  because `Permit3.takeFor` is a permissionless entrypoint (F27/C-1). `Permit3.takeFor` is `nonReentrant`
///  alongside `take`, so a module still cannot nest a second take: a composite op
///  spanning TWO protocols is two items, not one. `Permit3.transferFrom` is not
///  locked, which is how the funding leg is pulled.
interface ITakerForModule {
    /// @param spender    the `Permit3.takeFor` caller, forwarded verbatim. A PUSH
    ///                   module MUST require this to equal its pinned Settlement:
    ///                   `forAmount` is core-derived ONLY on that path, and
    ///                   `approveTaker` lets any caller name itself spender (F27/C-1).
    ///
    ///  WHY A THIRD ADDRESS, WHEN WE ALREADY HAD TWO
    ///  ────────────────────────────────────────────
    ///  The question is not whether the values differ — on the composite path
    ///  `spender` and `receiver` are both Settlement — but where each COMES FROM:
    ///
    ///    spender     `Permit3.takeFor`'s own `msg.sender`. Asserted by the EVM.
    ///                The caller cannot choose it.
    ///    receiver    an ARGUMENT of `takeFor`. Caller-chosen on a direct call.
    ///    onBehalfOf  an ARGUMENT of `takeFor` (`user`). Caller-chosen likewise.
    ///
    ///  A gate written against either of the two that already existed is therefore
    ///  worthless — the attacker just passes the value the gate wants. Both cases
    ///  are pinned by tests (`PreFundSpenderAuth`).
    ///
    ///  `spender == onBehalfOf` is NOT the invariant. On every honest fill the
    ///  maker grants SETTLEMENT (`approveTaker(settlement, module, ref, …)` writes
    ///  `_takerAllowance[maker][settlement][module][ref]`), so the two are
    ///  necessarily different: requiring equality would mean only a maker could
    ///  ever trigger their own fill, and no solver-driven fill could exist.
    ///
    ///  What the taker book DOES guarantee is that `spender` holds a grant from
    ///  `onBehalfOf` — the pair is the key. That is exactly enough for a PULL
    ///  module, where the value moved comes out of `onBehalfOf`'s wallet and a
    ///  self-granting caller can only rob themselves. It is not enough for a PUSH
    ///  module, where the value comes out of the MODULE's balance: the book proves
    ///  the user's consent, never the caller's identity, and only the latter
    ///  distinguishes Settlement from anyone.
    ///
    ///  Why it must be a parameter. The comparison needs two facts that live on
    ///  opposite sides of the Permit3 boundary: Permit3 knows `msg.sender` but not
    ///  which Settlement a module trusts, and the module knows its Settlement but
    ///  not who called Permit3. One must cross. Permit3 holding a canonical
    ///  Settlement would invert the dependency — Settlement pins Permit3, not the
    ///  reverse, and Permit3 is the shared Permit2-style hub deployed at an
    ///  identical address on every chain. A `currentSpender()` view would need
    ///  storage (or transient, which some target EVMs lack). One forwarded word is
    ///  the floor. It costs Settlement nothing: `takeFor`'s own ABI is unchanged.
    ///
    ///  ⚠ "SPENDER" IS THE TAKER-BOOK SENSE, NOT THE `transferFrom` SENSE. On the
    ///  pre-fund shape nobody pulls anything: the module is PRE-FUNDED by the fill's
    ///  own delivery and never calls `transferFrom`, so in token terms there is no
    ///  spender at all — which invites the reading that this should therefore be
    ///  `address(0)`. It should not, for two reasons.
    ///
    ///  First, something IS spent on every pre-funded fill: `Permit3.takeFor` debits
    ///  `_takerAllowance[user][spender][module][ref]` by `amount` BEFORE dispatching.
    ///  The pre-fund headers call that `amount` "vestigial" because no asset leaves the
    ///  position — but the grant is real, it is metered, and Settlement is the party
    ///  the maker authorised to consume it. `spender` names the key of the book
    ///  actually being debited, and matches `IPermit3.approveTaker(spender, …)`.
    ///
    ///  Second, `address(0)` would delete the only authenticated value the module
    ///  receives, and with it the only thing distinguishing a Settlement fill from
    ///  a direct `takeFor` by anyone — i.e. it reinstates F27/C-1 exactly.
    ///
    ///  ⚠ IT IS AN IDENTITY TO COMPARE, NEVER AN ADDRESS TO PULL FROM OR SEND TO.
    ///  No shipped module reads it for anything but the equality check. Misuse is
    ///  bounded anyway — `Permit3.transferFrom` gates on
    ///  `_tokenAllowance[from][module]`, so naming any address as a source without
    ///  its grant reverts — but the name is Permit3's book terminology
    ///  (`_takerAllowance[user][spender]`), not an instruction.
    /// @param onBehalfOf the order's maker — whose position is opened/closed.
    /// @param amount     this fill's slice of the value-OUT leg, already gated by
    ///                   the taker allowance.
    /// @param forAmount  the value-IN amount for this fill, computed by the core
    ///                   from the signed descriptor. MAY be zero on a dust slice
    ///                   whose funding leg floors out; a module whose protocol
    ///                   rejects a zero leg should revert rather than half-execute.
    /// @param receiver   where the value-out proceeds land — Settlement on the
    ///                   classic flow, so they fund the order's input legs.
    /// @param data       the maker-signed blob, descriptor word FIRST.
    function takeForOnBehalf(
        address spender,
        address onBehalfOf,
        uint256 amount,
        uint256 forAmount,
        address receiver,
        bytes calldata data
    ) external;

    // The funding-leg PREFLIGHT — "what asset does this module draw, and may it?" —
    // is deliberately NOT declared here. It lives in {IFundingSource}, and a
    // composite module implements both; only modules and {SettlementLens} import the
    // preflight one.
    //
    // The split is a SIZE PRECAUTION. This interface is imported by
    // {TakerAllowance}, so it rides into `Settlement`'s compilation unit;
    // {IFundingSource} is reachable from nothing the settler compiles. `Settlement`
    // runs at 24,456 of the 24,576-byte EIP-170 limit — a margin at which nobody
    // should have to re-measure to find out whether a view declaration was free, so
    // the declaration is kept where it provably cannot matter rather than where it
    // probably does not.
}