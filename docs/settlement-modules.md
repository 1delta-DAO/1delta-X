# Settlement Modules — the `SETTLE` op

> **Status: implemented (core mechanism).** The `ItemOp.SETTLE` op, the
> `ISettlementModule` interface, the `_executeItems` dispatch, and
> `NftSettlementModule` are live; covered by
> `core/test/items/NftSettlement.t.sol`. The kernel *report-verify* extension
> (§5) is specified here but not yet built — today's safety comes from the
> mandatory `legsOut` delivery + invariants (§4), which is sufficient for the
> NFT-sale case.

## 1. Why

The settlement already has two value paths: the **typed fungible fast path**
(`legsIn`/`legsOut`, settled inline — zero dispatch) and the **item modules**
(MAKE/TAKE, which act on the *maker's* own assets/positions). Missing was a
generic settler for the **solver↔maker exchange** when the typed legs don't fit
(an NFT sale, a cross-type trade). Previously that had to be stitched from a
TAKE-to-filler item + a solver callback + an ownership invariant, and — because
items never learned the filler's identity — an NFT *sale* had to pin an
`exclusiveFiller` at signing.

`SETTLE` is that generic settler, as a third item op, with two properties that
matter:

- **Filler-aware.** `settle(maker, filler, amount, data)` receives `ctx.filler`,
  so the maker's asset can be routed to *whoever fills* — an NFT sale to an open
  solver set, no exclusivity.
- **Pay-per-use.** The fungible legs stay inline (no CALL); a `SETTLE` item pays
  one CALL only when the exchange is non-standard. This is the "fast-path +
  module fallback" shape — gas-optimal for the 99%, general for the rest.

## 2. The design (fast path + fallback, composable)

Settling the solver↔maker exchange is conceptually always "a settlement module."
The ERC-20 swap is the **built-in one, hardcoded inline**; anything else names a
`SETTLE` module and pays one CALL:

```
inline (0 CALL):   legsIn/legsOut typed legs        → the 99% fungible swap
SETTLE (1 CALL):   item.op == SETTLE                → the exotic exchange
```

They **compose** — an order can carry inline fungible legs *and* a `SETTLE` item
*and* MAKE/TAKE items *and* a fill module; each section self-skips at zero cost
when empty. A mixed NFT-plus-cash trade is exactly: an inline USDC `LegOut`
+ a `SETTLE` NFT item.

Dispatch ([`_executeItems`](../packages/core/src/settlement/Settlement.sol)):

```solidity
if      (op == MAKE) IMakerModule(module).makeOnBehalf(maker, slice, data);      // maker deposits/repays
else if (op == TAKE) PERMIT3.take(module, maker, slice, to, data);               // maker borrows/withdraws
else                 ISettlementModule(module).settle(maker, ctx.filler, slice, data); // solver↔maker
```

No new `Order` field, no typehash change: `SETTLE` is a new value of the existing
`uint8 op` enum, so the golden order hash is **unchanged** (verified).

## 3. The three module kinds

| Kind | Scope | Who it can move | Gets the filler? |
| --- | --- | --- | --- |
| **MAKE / TAKE** (items) | the maker's own assets/positions | maker's, capped by maker's approval | no |
| **Fill module** | the fill *denominator* (a scalar) | nothing (view) | no |
| **SETTLE** (this) | the solver↔maker *exchange* | maker's (to the filler) or filler's (to the maker) | **yes** |

## 4. Safety (today)

`SETTLE` inherits the item trust model and adds the filler:

- **`msg.sender == settlement`** in the module makes the maker's order signature
  the authority over `(module, amount, data)`.
- The module can only move what the relevant party **approved it for** — the
  maker's `setApprovalForAll` (its own NFTs), or the filler's own approval
  (assets the filler chose to put up by filling). Neither party's other assets
  are reachable.
- **The maker's receipt is guaranteed by the order, not the module.** For an NFT
  *sale*, the maker is paid via an inline `LegOut` — a **mandatory,
  reverting delivery that runs BEFORE items**, so the maker is paid first or the
  whole fill reverts, and only then does the module hand off the NFT. For an NFT
  *purchase* (maker's receipt is non-fungible), the maker attaches an ownership
  **invariant** (`ownerOf(id) == maker`), checked after items.

Atomicity worked example (from the test): an unpaid solver's `legsOut` delivery
reverts before the `SETTLE` item runs, so the maker never loses the NFT without
being paid.

### ⚠ Solver-side caveat (the one thing to get right)

SETTLE is the first flow where the **filler's** receipt is *not* a gated token
move — it is whatever a maker-signed module does, and there is **no on-chain
filler-receipt guarantee** (invariants are maker-signed; a filler can't attach
one). Orders are open (no filler whitelist, no module registry), so a maker
*could* sign an "NFT sale" whose module is a no-op or a hostile collection, take
the `legsOut` payment, and hand over nothing. This is **not** a protocol bug —
the maker is paid and the filler self-selected into the tx — but it means
**solvers MUST protect themselves**:

- Vet the immutable, maker-signed `(module, collection, tokenId)` triple before
  filling (all are inside the order hash — a filler cannot alter them).
- And/or wrap the fill in a solver contract that asserts the expected post-state
  (`require(IERC721(collection).ownerOf(tokenId) == address(this))`).

Same-block **simulation is insufficient** — a maker-controlled `collection` can
return one thing in sim and another in execution. This is the standard
"vet what you're buying" discipline of any NFT marketplace, made explicit here
because SETTLE has no built-in filler-receipt gate.

### Indivisibility (order config)

A `SETTLE` item is settled by the pro-rata slicer like any item
(`amount · newFilled/anchor − …`). For an indivisible NFT (amount `1`) the slice
floors to `0` on any partial fill and to `1` only on the fill that completes the
order — so the NFT never moves early, but a **partial-fillable** NFT order would
pay an early filler pro-rata and deliver the NFT only to the last one. Therefore
an NFT SETTLE order MUST be **full-fill** (`minFillAnchor == anchor`, or a
`FullFillModule`), and the item's `amount` must be a **non-zero sentinel** (`1`)
or the slice is `0` and the transfer is skipped. `validateOrder` enforces the
full-fill requirement (`"settle item requires full-fill"`).

## 5. Kernel report-verify (specified, not yet built)

For a module that must deliver **fungible** value to the maker (a cross-type
exchange, not an NFT sale where the fungible side is already an inline leg), the
kernel should verify the delivery generically instead of trusting the module:

- The `SETTLE` item's `data` declares expected claims `(token, to, minAmount)`.
- The kernel snapshots each recipient's `balanceOf`, calls `settle`, then asserts
  the delta ≥ `minAmount · fraction`.

This keeps anti-donation + mandatory-delivery in the *kernel*, over any module,
for ~one `balanceOf` per token (usually warm → ~100 gas). It does NOT cover
ERC-721 receipt (a count delta doesn't pin a tokenId) — that stays an invariant.
Deferred because the NFT-sale case (the immediate need) is fully covered by §4.

## 6. Gas

- **Standard swap: unchanged** — the fungible legs are inline; `SETTLE` is never
  reached (no items, or no SETTLE item). Parity with Fusion/UniswapX/CoW, which
  all settle swaps inline.
- **Exotic exchange: one CALL** to the module (~2.6k cold) + its own logic (the
  NFT transfer you'd pay for regardless) + report-verify `balanceOf` (§5, when
  used). This is the pay-per-use cost, borne only by orders that opt in — the
  correct place to spend it, since the exchange can't be inlined anyway.

This is the only "settle on modules" shape that doesn't regress the hot path: the
hot path never becomes a module call; it stays the built-in default.

## 7. What this replaces / unlocks

- **NFT sale to an open solver set** — previously needed `exclusiveFiller` (the
  maker's NFT recipient had to be signed); now the module routes to `ctx.filler`.
- **The item + callback + invariant stitch** for exotic exchanges collapses into
  one purpose-built module.
- **Mixed trades** (NFT + cash, token + NFT) compose from inline legs + a
  `SETTLE` item.

## 8. Open / next

- Build the §5 report-verify for fungible-delivering settle modules.
- An `NftBuySettlementModule` (filler's NFT → maker) + the ownership-invariant
  pattern, and the ERC-1155 variant (`safeTransferFrom` with `id`+`amount`).
- Consider whether the fill module + a `SETTLE` module should share the same
  `takerData`/`data` channel for a fully module-matched exotic order.
