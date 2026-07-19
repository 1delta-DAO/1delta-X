# Design notes

Topic-level design docs for the intent settlement system. The co-located
package READMEs are the API reference — [`settlement`](../packages/core/src/settlement/README.md)
(the fill flow, item ops, denominator, fees) and [`permit3`](../packages/core/src/permit3/README.md)
(the token/taker allowance hub). These notes go deeper on specific mechanisms.

## The order model, in one paragraph

A maker signs an intent: fungible legs it gives/receives (`tokenIn`/`tokenOut`,
the inline fast path), arbitrary actions on its own positions (`items` →
MAKE/TAKE modules), a generic solver↔maker exchange for anything the legs can't
express (`SETTLE` module), a fill denominator (`fillModule`/`fillTotal`), and
pre/post predicates (`validators`/`invariants`). A permissionless solver fills it
as `msg.sender` and keeps the surplus. Everything beyond the fungible fast path
is a maker-signed, pay-per-use module call — the fast path stays inline and free.

## Fees — who gets paid, and how

- **[originator-fees.md](originator-fees.md)** — the party that *sources* an order
  earns a fee as an ordinary **output leg** (per-leg `recipientOut`), or a
  `FeeTransferModule` **item** for outputless orders. bps-of-tick, absolute, and
  multi-recipient tiers; soft-exclusivity and settlement-burn caveats.
- **[relayer-fees.md](relayer-fees.md)** — the party that *fills* is paid the
  conversion spread; for orders with no spread (a gasless deposit), a **rising
  input leg** (flagless: `startAmountIn < endAmountIn`) is an auction-discovered,
  gas-indexed relayer fee requiring zero filler capital.

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
- **[batch-settle.md](batch-settle.md)** — `batchSettle`, the coincidence-of-wants
  (CoW) path: N orders netted through the Settlement pool so two mirror makers
  clear against each other with **no AMM** and **zero solver inventory** — even for
  an *imbalanced* batch, via the surplus pre-send (the solver swaps the surplus it
  is handed into the deficit it owes). A *dedicated* method — the single-order hot
  path is untouched. Covers the pull→pre-send→interact→deliver→sweep flow, the
  whole-ness guard, the `takerDatas[]` overload, and why uniform-price improvement
  stays an off-chain (batch-auction) concern.
- **[item-aware-netted-settle.md](item-aware-netted-settle.md)** — `batchSettleItems`,
  the item-aware generalization of `batchSettle`: admit MAKE/TAKE lending legs into
  the pool so a **spot order's liquidity funds a leverage order's conversion**
  inventory-free, callback-free, and flash-free (the pool bootstraps the collateral
  the borrow needs). Fixes the token-accounting invariant *with items* (whole-ness
  is invariant to items — a pure balance-delta) and the **solver-specified ordering
  (`pullMask` + `sequence`) + whole-ness safety model** (liveness is the solver's
  job; safety is the contract's). This is **leverage-native coincidence of wants** —
  nothing in the swap-only market can express it.

## Gasless UX

- **[gasless-permit-relay.md](gasless-permit-relay.md)** — EIP-712 signatures
  attached to module `data` so on-chain approvals aren't required beforehand;
  replayed atomically inside the module call.

## Reading order

New to the codebase: the [settlement README](../packages/core/src/settlement/README.md)
first (the fill flow + item-op taxonomy), then the fee notes (the common case),
then fill-modules → settlement-modules (the generalization toward any↔any
intents).
