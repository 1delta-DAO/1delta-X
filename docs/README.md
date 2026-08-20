# Design notes

Topic-level design docs for the intent settlement system. The co-located
package READMEs are the API reference — [`settlement`](../packages/core/src/settlement/README.md)
(the fill flow, item ops, denominator, fees) and [`permit3`](../packages/core/src/permit3/README.md)
(the token/taker allowance hub). These notes go deeper on specific mechanisms.

## The order model, in one paragraph

A maker signs an intent: fungible legs it gives/receives (`legsIn`/`legsOut`,
the inline fast path), arbitrary actions on its own positions (`items` →
MAKE/TAKE modules), a generic solver↔maker exchange for anything the legs can't
express (`SETTLE` module), a fill denominator (`fillModule`/`fillTotal`), how the
price moves between its signed endpoints (the clock, a priority bid, or a
`pricingModule`), and pre/post predicates (`validators`/`invariants`). A
permissionless solver fills it
as `msg.sender` and keeps the surplus. Everything beyond the fungible fast path
is a maker-signed, pay-per-use module call — the fast path stays inline and free.

## Fees — who gets paid, and how

- **[originator-fees.md](originator-fees.md)** — the party that *sources* an order
  earns a fee as an ordinary **output leg** (a `LegOut` with its own `recipient`), or a
  `FeeTransferModule` **item** for outputless orders. bps-of-tick, absolute, and
  multi-recipient tiers; soft-exclusivity and settlement-burn caveats.
- **[relayer-fees.md](relayer-fees.md)** — the party that *fills* is paid the
  conversion spread; for orders with no spread (a gasless deposit), a **rising
  input leg** (flagless: a rising `LegIn`, `start < end`) is an auction-discovered,
  gas-indexed relayer fee requiring zero filler capital.

## Pricing

- **[pricing-modes.md](pricing-modes.md)** — how an order decides where between its
  signed endpoints a fill prices: the time clock, the **block clock** (`timing` bit
  102, for 250ms-block L2s), the **priority auction** (bit 103 — the bump is bid in
  priority fee, UniswapX `PriorityOrderReactor` parity), and **external price
  modules** (`pricingModule` → oracle-pegged, range/ladder, cosigner-quoted). Covers
  the reason a module returns a BUMP rather than an amount — the core clamps it, so
  no mode can price outside the maker's signed band — the once-per-fill resolution,
  the three shipped modules, and the measured per-mode gas. Also **delta-verify
  delivery** (bit 104), which is orthogonal to all of them: it changes how the priced
  amount is *delivered* (verified against the recipient's balance delta rather than
  pushed nominally), which is what makes a fee-on-transfer output safe.

## Generalizing beyond fungible swaps

- **[fill-modules.md](fill-modules.md)** — `fillModule`/`fillTotal` decouple the
  fill *denominator* from a fungible leg, so an indivisible/exotic order (an NFT,
  an auction lot) has a valid fill unit. The module picks the delta; the core
  keeps the cap + single-fraction scaling. Includes the zero-overhead-default gas
  model and the assessment of why *not* to bytes-ify the typed legs.
- **[settlement-modules.md](settlement-modules.md)** — the `SETTLE` op: a generic,
  **filler-aware** solver↔maker exchange (an NFT sale to an open solver set, no
  exclusivity), as the module fallback behind the inline fungible fast path. The
  three module kinds, the safety model, and the pay-per-use gas story.
- **[batch-settle.md](batch-settle.md)** *(superseded)* — `batchSettle`, the
  original coincidence-of-wants (CoW) path: N orders netted through the Settlement
  pool so two mirror makers clear against each other with **no AMM** and **zero
  solver inventory** — even for an *imbalanced* batch, via the surplus pre-send.
  Still the reference for the **netting invariant, the pre-send bound, and the
  whole-ness guard**, all of which `matchSettle` reuses unchanged; its five fixed
  phases are now simply a schedule.
- **[deferred-match-settle.md](deferred-match-settle.md)** — `matchSettle`, the
  **deferred-check** match path (supersedes `batchSettleItems`). The solver supplies
  a flat **step schedule** (pull / deliver / item / pre-send / call) instead of an
  order permutation, and every per-order check — input funding, invariants — runs
  ONCE at the end. Items may therefore interleave with deliveries, so
  **mutually-dependent orders match with no solver inventory, no flash, and no
  callback**: the composition a re-entrant callback would express becomes a
  schedule, so `nonReentrant` stays intact and the whole deferred context lives in
  **memory** (no storage, no transient storage). Covers the credit ledger, the
  exactly-once guards, and the EVC relationship.
- **[filler-strategy.md](filler-strategy.md)** — **the recommended shape for a
  `matchSettle` filler.** Guard on the `filled` counters before touching the plan,
  so losing a contested match costs 3.9k gas instead of 34k (−88%, and the gap
  widens with plan size). Covers why the guard is an EXACT-equality check rather
  than "is there room left", the off-chain build order (Lens → hashes → schedule),
  and a revert-reason taxonomy that separates a routine race loss from a plan bug
  from a maker-side problem — so a searcher can classify failures without
  re-simulating.
- **[item-aware-netted-settle.md](item-aware-netted-settle.md)** *(superseded)* —
  `batchSettleItems`, the order-granular predecessor. Still the reference for the
  **token-accounting invariant with items** (whole-ness is invariant to items — a
  pure balance-delta) and the liveness-vs-safety split that `matchSettle` inherits.

## Authorization

- **[delegated-signers.md](delegated-signers.md)** — letting a key other than the
  maker's own authorize that maker's orders: session keys, a desk's hot wallet, a
  Safe or passkey account. The registry is keyed by `msg.sender` on write and by
  the **order's maker** on read, which is the whole security model — nobody
  nominates a signer for someone else, and a delegate can author nothing its
  nominator could not have authored itself. Covers the six-step verification
  order (and why the hot path is unchanged), the contract-delegate envelope and
  the two conditions that make it collision-proof, gasless nomination with no
  re-delegation, and the revocation caveat.
- **[bulk-signatures.md](bulk-signatures.md)** — one signature authorizing N orders
  via a Merkle root (`innerSig ‖ proof ‖ 0xB0` → `OrderRoot(root)`), for ladders,
  brackets and quote refreshes. Covers the collision argument, why the branch only
  swaps the digest rather than re-implementing the signer set (it cost 1,343 bytes
  the other way), and what it does NOT do — a root is not a bracket, see
  [oco.md](oco.md).

## Auctions

- **[quote-auctions.md](quote-auctions.md)** — the off-chain half of the cosigned
  quote channel: how to **measure clearing depth** (replay the bump from block
  context — it is deterministic for the clock and priority modes, and a genuine
  blind spot for module-priced fills), why **band width** outweighs auction format
  by an order of magnitude, and the first-price/second-price trade-off given that
  `end` is a cryptographically enforced reserve and
  `ClockFlooredQuoteModule` is a second, tighter one. Covers the collusion argument
  against second-price and the three things that blunt it.

## Conditions

- **[condition-trees.md](condition-trees.md)** — `OR` and `NOT` inside a single
  order. `order.validators` is a flat AND-list, so
  `ConditionTreeValidator` is one entry in it whose `data` is a whole expression
  in **disjunctive normal form**, evaluated by staticcalling other validators.
  Covers why DNF beats a node graph with child indices (no cycles, no recursion,
  exact well-formedness), the two-way short-circuit, and the rule that a
  **reverting leaf is an error rather than `false`** — without which
  `NOT(brokenOracle)` would pass precisely when the feed is broken.
- **[oco.md](oco.md)** — **brackets and one-cancels-other**: the one order type
  whose defining property is a relationship *between* orders, where every gate the
  settlement runs is scoped to the order being filled. Two expressions, neither
  touching the core: a **shared nonce** with the fill-once bit (free, zero
  contracts, whole-fill only), and `OcoGroupModule` (a `staticcall` validator that
  READS the group claim plus a SETTLE item that WRITES it — validators run before
  items, which is exactly the ordering OCO needs). Covers why the claim records
  the winner's nonce rather than a bare flag, and why the claim is a SETTLE item:
  SETTLE is the only op that **reverts** on a zero pro-rata slice instead of
  skipping it, so a misconfigured bracket fails loudly rather than silently
  becoming fillable on both legs.

## Order sizing

- **[proportional-legs.md](proportional-legs.md)** — signing "sell 100% of
  whatever I hold" without knowing the amount, by overloading the top of the
  existing `start` word — **no typehash change, no re-signing**. Covers why such
  orders are whole-fill only, why `end` becomes a **mandatory cap** (a maker's
  balance is not under their sole control, so an uncapped sweep is a standing
  offer to buy their whole holding at a small order's price), why `fillUpTo` is
  the entry point, and why multi-token sweeps are a module rather than a leg.

## Gasless UX

- **[gasless-permit-relay.md](gasless-permit-relay.md)** — EIP-712 signatures
  attached to module `data` so on-chain approvals aren't required beforehand;
  replayed atomically inside the module call.
- **[account-onboarding.md](account-onboarding.md)** — the two grants a fresh
  account needs before it can be filled, which of them a signature can create,
  and which route applies to which kind of account. Includes the EIP-7702 /
  ERC-7579 approver that was built and deleted, and why.

## Cancellation

- **[soft-cancel.md](soft-cancel.md)** — the five cancellation granularities and
  when each is the right one: `cancelOrder` (one order, **by hash** — nonce
  siblings survive), `cancelOrders` / `invalidateNonceWord` / `rollbackNonces`
  (bulk, by nonce), and the **free, off-chain signed `SoftCancel`**. Covers why
  the soft cancel moved from `personal_sign`-over-a-hash to **EIP-712 in the
  Settlement domain** (deployment binding, a readable prompt, the full
  EOA/1271/delegate signer set, batching + freshness), the two independent checks
  a node must run — *who signed* vs. *what may they retract* — and
  **cancel-and-replace**: why the replacement takes a fresh nonce, why the
  retraction is applied only after the replacement verifies, and what an amend
  honestly does not guarantee.

## Order distribution

- **[waku-orderbook.md](waku-orderbook.md)** — *design note.* A decentralized
  transport for signed orders over [Waku](https://waku.org) P2P messaging,
  targeted first at Rootstock. There is no on-chain orderbook — orders are
  **self-authenticating** `(Order, sig)` tuples any node can verify against
  `DOMAIN_SEPARATOR()`, so the mesh needs no trust, only the signature does.
  Covers the Relay / Light Push / Filter / Store roles, content-topic design,
  and — the crux — the **spam / unbacked-order defense**: RLN rate-limiting, a
  cheap→expensive verification pipeline, and a per-maker negative cache that
  keeps rejecting funds-less / no-approval orders **O(1) amortized**, with the
  on-chain fill revert as the capital backstop.

## Deployment

- **[deterministic-deployment.md](deterministic-deployment.md)** — landing
  Permit3, the core, and the bridge package on **identical addresses on every
  chain** via the shared CREATE2 `DeployFactory`. Covers the constructor-arg
  dependency chain (and the two contracts that necessarily diverge), the
  measured fact that our source has only **three** distinct bytecodes across all
  EVM versions — so portability reduces to **PUSH0 + MCOPY** — and why the
  `evm_version` is therefore a **global** choice, not a per-chain one. Verdict:
  compile at **`cancun`**, which puts 38 of the 43 surveyed chains in one
  address family; only Metis/Taiko/PulseChain/Telos sit a tier below.
  Includes the dated survey, the compiler settings that must be pinned before
  the first deploy, the three non-identical factory bytecodes (verified
  address-equivalent), and an RPC probe that works where the obvious
  state-override approach silently lies.

## Security

- **[SECURITY.md](../SECURITY.md)** — the authoritative security document: trust
  model, the invariants each layer upholds, the caveats integrators get wrong
  (revoking Permit3 is **not** a kill switch; a contract that fills on its own
  behalf must hold no balance; position-ID modules must bind the position to
  `onBehalfOf`), and the audit history with findings and fixes.

  **Read the "Breaking change for integrators" section before touching an
  encoder** — the 2026-07 audit changed the signing format for Gearbox, Liquity,
  ERC4626 claims, composite items, and every `BalanceMode.Full` taker leg. Two of
  those fail *silently* if missed.

## The 2026-08 parity work

- **[lop-parity.md](lop-parity.md)** — the 2026-08 feature diff against
  1inch LOP v4 / Fusion+, UniswapX (V2 / V3 / Priority), ComposableCoW and
  ERC-7683, and what closed it: external **pricing modules** (bounded by
  the maker's signed band, unlike 1inch's amount getters), a **block-number
  clock**, a **priority-fee auction** and **delta-verify delivery** in free
  `timing` bits, **Merkle bulk signing** in the signature envelope, and a
  permissionless **7683 adapter**. The **rationale and cost record**: why each
  feature has the shape it has, the byte budget that forced it, and the measured
  gas — read it before adding anything to the settler.
  Covers the one-time order-shape change all of it rides on (new typehash — see
  [SECURITY.md](../SECURITY.md)) and, in §4, the byte budget: why Settlement needs
  via-IR to be deployable at all, the restructurings that returned ~3.3KB, and why
  the `optimizer_runs` curve is not an escape hatch from a size regression.

## Reading order

New to the codebase: the [settlement README](../packages/core/src/settlement/README.md)
first (the fill flow + item-op taxonomy), then the fee notes (the common case),
then fill-modules → settlement-modules (the generalization toward any↔any
intents). Before writing or changing an encoder, read
[SECURITY.md](../SECURITY.md)'s breaking-change section.
