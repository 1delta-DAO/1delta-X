# Fill Modules — Generalizing the Fill Denominator

> **Status: implemented.** `Order.fillModule` + `Order.fillTotal`, the
> `IFillModule` interface, the `_openFill` delegation, `FullFillModule`, and the
> Lens shape-relaxations are live; the identity default (both fields zero) is
> byte-for-byte the classic fungible-anchor fill. Covered by
> `core/test/swaps/FillModule.t.sol` (identity, all-or-nothing, taker↔maker
> match, over-fill cap, the single-fraction invariant, and the Lens shapes) and
> the golden-hash cross-check. `fillData` is folded into the existing shared
> `takerData` channel — no new fill entry points. Not yet built: an
> `NftFillModule` + `NftTransferModule` for a real ERC-721 swap (the sentinel /
> filler-threading discussion), and an `ItemFillModule`.

## 1. Motivation

The settlement is already a generalized any↔any intent settler: the maker's side
is arbitrary (value legs + module items + a `GenericCallModule` escape hatch),
the required outcome is arbitrary (post-execution invariants), and the solver
supplies the counterparty side (delivery legs + callback) for the surplus. One
hardcoded coupling remains — **the fill is denominated in a fungible leg
amount**:

```
f = fillAmount / anchor          anchor = startAmountIn[0] (SELL) | startAmountOut[0] (BUY)
```

Every leg and every item slice scales by that single fraction `f`. This is fine
for fungible trades but has no natural home when neither side carries a fungible
unit (a pure NFT↔NFT swap, an RFQ settled 1:1, an auction that clears a single
lot). Those intents have to borrow a nominal fungible anchor — a tell that the
denominator, not the intent model, is the limitation.

A **fill module** removes that coupling: it lets the maker define *what a unit of
fill means* for this order, so the denominator can be a fungible amount, one
indivisible item, an ERC-1155 quantity, a signed quote, or anything else —
without giving up the property that makes the current design safe.

## 2. The invariant that must survive (non-negotiable)

The single scalar `f` is not incidental — it is a **security property**. Because
every leg and item scales by the *same* fraction, a solver **cannot size legs
independently**: it can't fill the leg that pays it in full while under-delivering
the leg it owes. Any generalization MUST preserve "one fraction scales
everything," or replace it with an equally strong guard. Losing it trades a
denominator limitation for a value-extraction hole.

The corollary that drives the whole design: **the fill module may choose the
*fraction*, but never the *per-leg amounts*, and never the *cap*.**

## 3. Design — the module parses & matches; the core scales & caps

Split the responsibilities so nothing money-critical leaves the core:

| Responsibility | Owner | Why |
| --- | --- | --- |
| The denominator `fillTotal` (the maker's unit) | **Core** (maker-signed field) | A module-supplied total could be inflated to over-extract |
| Over-fill cap `prevFilled + delta ≤ fillTotal` | **Core** | The one guard that bounds total extraction |
| Uniform pro-rata scaling of every leg/item by `delta / fillTotal` | **Core** (unchanged) | Preserves the single-fraction invariant |
| Turning the solver's proposed fill into a scalar `delta`, and **rejecting a mismatched counterparty** | **Fill module** (pluggable) | This is the only order-specific part |

The module is a pure matcher:

```solidity
interface IFillModule {
    /// @notice Validate the solver's proposed fill against the order + prior
    ///         state; return how much of `fillTotal` this fill advances.
    ///         MUST revert if the solver's supplied side does not match the
    ///         maker's demand. View — no side effects, no fund movement.
    function resolveFill(Order calldata order, uint256 prevFilled, uint256 fillAmount, bytes calldata takerData)
        external view returns (uint256 delta);
}
```

The proposal is carried in the shared filler-supplied `takerData` (the same
adversarial blob the validators/invariants see — no new fill argument), plus the
requested `fillAmount`. `resolveFill` inspects them against the maker's committed
legs/items and returns `delta` — or reverts. That single hook *is* the "match
taker/maker" idea: the module quantifies (and gates) the match; the core does the
money.

### Two new `Order` fields

- `address fillModule` — `address(0)` = **identity** (the current fungible-anchor
  behavior; no module call).
- `uint256 fillTotal` — `0` = **derive from the leg anchor** (`_anchorTotal`,
  current behavior); non-zero = the explicit denominator in the module's unit.

When both are zero the order behaves **exactly as today** (see §5 on why this
matters for gas). The maker signs both, so the matching rule and the denominator
are inside the signature — a filler cannot substitute either.

### The core change (sketch)

```solidity
// _openFill, generalized:
uint256 total = order.fillTotal != 0 ? order.fillTotal : _anchorTotal(order);
uint256 delta;
if (order.fillModule == address(0)) delta = fillAmount;      // identity — zero overhead
else { delta = IFillModule(order.fillModule).resolveFill(order, prevFilled, fillAmount, takerData);
       if (delta == 0) revert ZeroFill(); }                  // a module can return 0
if (delta < order.minFillAnchor) revert FillTooSmall();      // floor on the ACTUAL progress
uint256 newFilled = prevFilled + delta;
if (newFilled > total) revert OverFill();                    // cap stays in core
filled[orderHash] = newFilled;
// downstream scaling is UNCHANGED: every leg/item uses delta/total
```

Even a buggy or malicious `fillModule` can only misreport `delta`, which scales
*both* sides proportionally (the maker still gives and gets the same fraction);
the only extraction risk — advancing past 100% — is caught by the core cap.

## 4. What it buys you (every fill semantics becomes a leaf)

| Order kind | `fillTotal` | `resolveFill` |
| --- | --- | --- |
| Fungible swap (today) | leg anchor | *no module* — `delta = fillAmount` (identity) |
| NFT (indivisible) | `1` | return `1` **iff** `fillData` names the maker's exact token; else revert (full-fill by construction) |
| ERC-1155 batch | `qty` | `delta = requestedQty`, bounded by remaining |
| RFQ / signed quote | `1` | verify the quote's signature/params, return `1` |
| Sealed/English auction settle | `1` | verify `fillData` is the winning bid ≥ reserve |
| **TWAP / DCA / iceberg** (shipped: `TwapFillModule`) | total | release `partsOpen·partSize − prevFilled` — one signed order, time-sliced into equal parts; no fill runs ahead of schedule, catch-up allowed, core caps at total |

The fungible case is literally the identity module, so this **subsumes** today's
behavior rather than replacing it; the earlier "anchor on an item" idea is a
~10-line `ItemFillModule`.

**Shipped example — `TwapFillModule`** (`core/src/modules/TwapFillModule.sol`,
tested in `core/test/swaps/TwapFillModule.t.sol`). A CoW-style TWAP with **no
watchtower and no generated sub-orders**: one signed order is released in N equal
time-sliced parts, the schedule riding existing signed fields (`fillTotal` =
total, `minFillAnchor` = part size, `decayStartTime`/`decayDuration` = window).
`resolveFill` admits only the parts whose window has opened, so a fill can't run
ahead of schedule, one part per window is steady state, a skipped-window solver
can catch up, and the core's cap bounds total at `fillTotal`. Pricing stays
orthogonal (fixed limit per part today; a market-tracking limit layers on with an
oracle validator over the `takerData` seam — the same split maps DCA, iceberg,
stop-loss, and oracle-limit orders). Zero-inventory still works per window (the
solver flash-sources each part's output in the callback).

## 5. Gas — the design is built around a zero-overhead default

Gas efficiency is a hard requirement, so the design is shaped so the common
(fungible) path pays **nothing** for a feature it doesn't use:

- **No module ⇒ no external call.** `fillModule == address(0)` short-circuits to
  `delta = fillAmount` — a single `address` comparison against a calldata word,
  no `STATICCALL`, no branch mispredict cost of note. This is the 99% path and it
  stays on today's code.
- **No `fillTotal` ⇒ no recompute.** `fillTotal == 0` reuses the existing
  `_anchorTotal` read. The maker never has to compute or sign a redundant total
  for a fungible order.
- **Only two extra hashed words.** `OrderHash` grows from 24 to 26 words: ~2
  extra `mstore` + a larger single `keccak256` (a handful of gas per fill). No
  extra `abi.encode`/`bytes.concat` — it slots into the existing raw-buffer hash.
- **No new storage.** Progress still lives in the one `filled[orderHash]` slot;
  `delta`/`total` are memory-only. No SLOAD/SSTORE added to the hot path.
- **The `STATICCALL` is paid only by orders that need it.** An NFT/RFQ/auction
  order pays ~one cold `STATICCALL` (~2600 gas) + the module's own (deliberately
  tiny, `view`) logic — and those are exactly the orders that have no cheaper way
  to express themselves. The maker opts into that cost by choosing a module.
- **Keep `resolveFill` `view` and single-purpose.** It reads calldata + at most
  the `filled` slot the core already loaded; it must not do its own storage
  writes or token moves. Treat it like a validator's gas profile, not a module's.

Net: a plain fungible swap is within a few tens of gas of today (the hashing of
two zero words); everything heavier is pay-per-use and opt-in.

## 6. Implications

- **Breaking wire change.** Two new fields ⇒ new `ORDER_TYPEHASH`, new witness
  typestring, new golden order hash, SDK type/ABI/hash updates, and every test
  `Order` literal. Same break-class as the `recipientOut`/`feeConfig` reworks —
  fine pre-mainnet, but it is a typehash bump, not a silent addition.
- **Trust model.** `fillModule` is **consensus-critical**: it gates every fill's
  progress. It is maker-signed (chosen per order), must be `view`, and must be
  audited like a validator — small, single-purpose, no side effects. The core
  never trusts it for the cap or for per-leg amounts. A registry/allowlist is
  *not* needed (the maker's signature is the authority, mirroring the no-module
  -whitelist stance), but shipped fill modules should be reviewed and documented.
- **`minFillAnchor` re-denominates.** It becomes "minimum `delta` per fill" in the
  module's unit. For an indivisible order set `minFillAnchor == fillTotal` to
  force full-fill; the existing stranded-tail caveat carries over unchanged.
- **The auction is orthogonal.** Dutch decay (`amountOutAt`/`amountInAt`, gas
  bump, curve) prices each leg; the fill module only sets the fraction that
  scales it. They compose without interaction — an NFT order can still carry a
  decaying fungible boot leg.
- **Lens.** `validateOrder` learns the module-anchored shapes: when `fillModule`
  is set it should not require a fungible anchor leg, and it should surface
  `fillTotal == 0 && fillModule != 0` (module without a denominator) and the
  reverse. Advisory only — the fill is the truth.
- **Partial fills only where the unit is divisible.** An indivisible module
  returns the full `delta` or reverts; the core's pro-rata math is unchanged, but
  such orders are full-fill by construction.
- **Reentrancy surface is unchanged.** `resolveFill` is a `view` staticcall
  before any funds move, under the existing `nonReentrant` guard — no new
  mutable-call vector.

## 7. The fuller version, and why not to start there

The maximal reading is a **symmetric two-sided matcher**: the solver commits its
side through first-class *taker modules* (not just delivery legs + callback), and
the fill module matches maker-module *outputs* to taker-module *inputs*
structurally. That is the theoretical endpoint — the solver's obligations become
maker-constrainable by construction rather than by post-hoc invariant.

It is also a redesign, and it duplicates something already present: **invariants
already do declarative matching.** "I end up owning NFT #5678" is a post-condition
the solver must satisfy however it likes — that *is* the match, verified, without
the maker modelling the solver's mechanism. The `resolveFill` fill module gives
~95% of the generality (anchor-agnostic fills + solver-supply matching) for ~5%
of the redesign; invariants cover the rest. Reserve the symmetric-taker-module
version for a class of intents invariants provably cannot express.

## 8. Rollout

1. Add `fillModule` / `fillTotal` to `Order` (identity/`0` defaults) — the
   typehash/golden-hash/SDK sweep.
2. `_openFill` delegation with the zero-overhead short-circuit (§3, §5).
3. Ship the identity default (no behavior change) + an `NftFillModule` and an
   `ItemFillModule` as the first real modules, each with a focused test.
4. A core test that pins **"one fraction still scales every leg/item"** under a
   non-identity module (the §2 invariant), plus an over-fill test proving the
   core cap holds against a module that returns `delta > remaining`.
5. Lens shape-relaxations for module-anchored orders.

## 9. Resolved / open questions

- **`fillData` vs a new argument — RESOLVED: folded into `takerData`.** The
  module reads the same shared filler-supplied blob the validators/invariants
  see (`resolveFill(order, prevFilled, fillAmount, takerData)`), so no fill
  entry point changed. An order that uses both a fill module and a
  takerData-consuming validator must agree on the blob's encoding — an accepted
  coupling.
- Should `fillTotal`'s unit be documented per-module (bps? count? 1?) via a
  convention, or self-describing in `fillData`? (Still open — convention today.)
- Do we want a `resolveFill` return of `(delta, priceHint)` so a module can also
  influence auction pricing, or keep pricing strictly in `DutchAuction`?
  **Kept orthogonal** — `resolveFill` returns only `delta`; pricing stays in
  `DutchAuction`.
