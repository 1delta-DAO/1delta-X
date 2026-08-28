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

## 8. Fused (composite) ops — one item, two legs

A leverage order carries `[MAKE deposit, TAKE borrow]`. Aave, Comet and Morpho all
check health *inside* the borrow, so the deposit must come first — which makes the
ordering a **scheduling obligation**: the solver has to keep the pair adjacent and
in sequence, and `matchSettle` can only enforce that if the maker opted into
[`ItemPolicy.ATOMIC`](deferred-match-settle.md). Fusing the pair into one module
call moves the ordering inside the module, where no schedule can reach it.

**Shape.** A fused op is always a **TAKE**, because the gated leg is always the
value-OUT one and Permit3's taker book is what authorises it. `amount` is
denominated in that leg; the value-IN leg is derived. This covers the four
pairs worth having:

| fused op | gated leg | replaces |
| --- | --- | --- |
| deposit + borrow | borrow | open a levered position |
| repay + withdraw | withdraw | close one |
| repay A + borrow B | borrow | debt swap |
| withdraw A + deposit B | withdraw | collateral swap / migrate |

**No core change.** `ITakerModule.takeOnBehalf(user, amount, receiver, data)` is
already sufficient — a fused module is a modules-package contract, nothing else.

**Deriving the second leg.** Settlement pro-rates `item.amount` but never tells a
module the fill fraction, so a fused item cannot carry two independent amounts. It
carries the maker's intended TOTALS and re-derives:
`collateral = ceil(amount · collateralTotal / borrowTotal)`. At a full fill
`amount == borrowTotal`, so the second leg is exact; across partial fills the
rounding is per-fill and rounds toward MORE collateral, never less.

**Measured** (`aave-v3/test/leverage/FusedLeverage.t.sol`, both runs from an
identical fork state via `snapshotState`/`revertToState`):

| | gas |
| --- | --- |
| `[MAKE deposit, TAKE borrow]` | 628,667 |
| fused item | **619,054** |
| saved | 9,613 (−1.5%) |

The saving is one `Settlement→module` CALL plus the item-loop and slice overhead —
the protocol calls underneath are identical. On the netted path it also costs one
fewer schedule step, one fewer completeness bit, and one fewer `ItemPolicy`
constraint to satisfy.

> **Measure fused vs. paired from the same state.** Run back-to-back, whichever
> goes second finds the reserve, the aToken balance and the debt token warm and
> non-zero — worth ~280k here, which swamps the ~10k being measured.

**Cost to weigh:** four shapes × ~20 protocols is a lot of module code, and each
fused module relaxes the one-operation rule (see
[SECURITY.md](../SECURITY.md#architecture--trust-model) for why the allowance key
recovers the granularity). Ship fused variants for the venues where leverage volume
justifies them, behind a shared per-shape base — not blanket.

## 8.1 `TAKE_FOR` — the second amount comes from the CORE

The ratio above is decimal-safe (the borrow decimals cancel), but it has a defect
the arithmetic hides: `collateralTotal` is a **second copy of a number the order
already signs**. A leverage order's collateral IS `legsOut[0]` — delivered to the
maker moments earlier in the same fill — and the module restates it inside a blob
the core deliberately never decodes and nothing cross-checks. Mis-scale that copy
and the failure is silent: too large and the supply leg pulls up to the maker's
standing Permit3 token allowance; too small and the position is under-collateralised
or the borrow reverts at fill time. The per-fill `ceil` is a second, smaller tax.

`ItemOp.TAKE_FOR` (op byte 3) removes the duplicate. The item head is unchanged —
`op` was already a full byte and `op >= 3` used to revert — so there is **no record
layout change, no EIP-712 typehash change and no golden-hash break**; existing
signed orders keep meaning exactly what they were signed to mean.

The maker signs a **funding descriptor** as the first word of `data`, and the core
resolves it in [`Base._forSlice`](../packages/core/src/settlement/Base.sol):

| descriptor | meaning | `forAmount` |
| --- | --- | --- |
| `(1 << 255) \| j` | fund from `legsOut[j]` | `Pricing.outputAt(order, ctx, j)` — the SAME call `_deliverOutputs` just made |
| `(3 << 254) \| token` | fund with what the maker holds | `min(balanceOf(token, maker), cap)`, cap = `data` word 1, **full-fill only** |
| any smaller value | a literal total (wallet-funded leg, no matching output) | sliced by the same differencing as `item.amount` |

Settlement then calls `PERMIT3.takeFor(module, maker, amount, forAmount, receiver,
data)`, which gates `amount` against the **identical** taker-book bucket a plain
`TAKE` uses and dispatches
[`ITakerForModule.takeForOnBehalf`](../packages/core/src/interfaces/ITakerForModule.sol).
`data` is forwarded whole, so `ref = keccak256(data)` still covers the descriptor
and a filler cannot repoint the funding leg.

**What the leg reference buys.** The amount, its token and its decimals live in one
typed leg the maker already signed, so a mis-scaled second copy cannot exist. And
because it is the same pricing call that decided the delivery, the maker's net
balance in the funding token over a fill is **zero** — what the solver delivered is
exactly what goes back into the position, on partial fills too. A decaying
collateral leg carries its auction price into the funding side, which a fixed ratio
structurally cannot do.

**Measured** (`aave-v3/test/leverage/{FusedLeverage,TakeForLeverage}.t.sol`, each
against the two-item pair from an identical snapshot, same tree):

| | gas | vs pair |
| --- | --- | --- |
| `[MAKE deposit, TAKE borrow]` | 607,824 | — |
| fused item (ratio in `data`) | 603,867 | −3,957 |
| `TAKE_FOR` item (leg reference) | 606,096 | −1,727 |

`TAKE_FOR` costs ~2.2k more than the ratio module — `_forSlice` re-prices the leg
and the dispatch carries one more word — and buys the duplicated-number class of
bug being unrepresentable. Both beat the pair.

### The no-conversion shape (deposit + borrow, nothing swaps)

The leg reference is for the *levered* order, where the solver delivers collateral
the maker immediately supplies. The other half is the plain one: **the maker funds
the collateral from their own wallet and keeps the borrow** — no swap, no
conversion, no solver capital. There is no output leg to reference, so the funding
amount comes from the other two forms:

- **fixed** — a literal descriptor. The core slices it pro-rata, so this shape
  partial-fills normally.
- **balance-relative** — `(3 << 254) | token`, resolving to
  `min(balanceOf(token, maker), cap)` read at item time. For the amount a maker
  cannot know at signing: accrued interest, an in-flight transfer, a wallet sweep.

The **cap is mandatory** (`data` word 1; `0` reverts `ForBalanceNeedsCap`) for the
reason [`Proportional`](../packages/core/src/settlement/Proportional.sol) spells
out: a maker's balance is not under their sole control — anyone can raise it by
transferring tokens to them — so an uncapped "fund with everything I hold" is a
standing offer to lock the maker's whole holding into a position sized for much
less. And it is **full-fill only** (`ForBalanceNeedsFullFill`): a live balance
cannot pro-rate, so each slice would fund the whole remaining balance again. The
core enforces both, because the core is the only party that knows the fill fraction.

The order itself is the outputless SELL of [relayer-fees.md](relayer-fees.md) — the
settlement types already express it, with no new machinery:

```
side    = SELL
items   = [ TAKE_FOR borrow, recipient = maker, funding = balance(WETH, cap) ]
legsIn  = [ LegIn{ USDC, start: F0, end: FMAX } ]   rising relayer fee
legsOut = [ ]                                       EMPTY — nothing converts
```

The fee **self-funds**: items run before `_payInputsToSolver`, so the borrow lands
in the maker's wallet first and the fee is pulled out of it. The maker can start
with an empty USDC wallet and the relayer fronts nothing — one signature opens a
complete position. Proven on a live Aave fork in
`aave-v3/test/leverage/TakeForLeverage.t.sol::test_noConversion_depositBalance_andBorrow_withRisingFee`.

The anchor is the fee leg (`legsIn[0].start`), per the outputless-SELL rule; pin
`minFillAnchor = legsIn[0].start` to make it full-fill-only, which the balance form
requires anyway.

### Verified against Fluid, the hardest case

Fluid is where the constant-`sideAmount` shape hurt most, so it is the useful
check. `operate(nftId, newCol, newDebt, to)` applies both legs under ONE health
check — the reason to fuse at all — but because
[`FluidOperateModule`](../packages/modules/lending/fluid/src/FluidModules.sol)'s
collateral amount lives in `data` and cannot pro-rate, it had to reject *every*
sliced fill, even on an existing position that Fluid is perfectly happy to be added
to repeatedly. `FluidTakeForModule` takes the amount from the core instead.
Fork-tested on the mainnet wstETH-USDC T1 vault
(`fluid/test/leverage/TakeForOpen.t.sol`, 5/5):

| | |
| --- | --- |
| existing position, two slices | **works** — one `operate` per slice, NFT round-trips each time, maker nets zero in wstETH, one position grown by both |
| the same slice on `FluidOperateModule` | reverts `PartialFillUnsupported` — asserted side by side |
| fresh open (`nftId == 0`), sliced | still reverts, **correctly** |
| fresh open, full fill | exactly one position minted to the maker |
| no-conversion wallet-funded open | maker's whole wstETH balance becomes collateral, borrow to their wallet, rising fee self-funds |

The third row is the point worth keeping: `FullFillGuard` is **not** obsoleted by
`TAKE_FOR`, it is *scoped*. A fresh `operate` MINTS a position, so N slices make N
positions rather than one partially-opened one — that is position IDENTITY, which no
amount encoding can fix, and is exactly the case the guard was written for. What
`TAKE_FOR` removes is the guard's collateral damage: the existing-position path that
was only full-fill because the arithmetic could not be expressed.

### Euler V2 and Dolomite: the guard comes off entirely

Both are batch-native like Fluid — `EVC.batch` and `operate(accounts, actions)` each
run ONE status/solvency check per call, which is the reason to fuse — but neither
has a position identity object. An Euler position is just the balances of an EVC
account; a Dolomite position is the balance set of the maker-signed
`(owner, accountNumber)` sub-account. Both can be deposited into and borrowed
against any number of times.

So on these two venues `FullFillGuard` was **never** protecting a protocol
constraint. It existed only because a constant `sideAmount` in `data` cannot
pro-rate. `EulerV2TakeForModule` and `DolomiteTakeForModule` carry **no guard at
all** — there is no fresh-open carve-out to make, unlike Fluid — and every slice is
its own two-leg batch under one check. Fork-tested 4/4 each
(`euler-v2/test/leverage/TakeForOpen.t.sol`,
`dolomite/test/leverage/TakeForOpen.t.sol`): thirds-then-remainder partial fills
land the whole signed collateral and debt, the maker nets zero in the funding token
at every slice, and the identical slice on the old module reverts
`PartialFillUnsupported` — asserted side by side.

**Measured**, each pair from an identical fork snapshot:

| venue | composite module (old) | `TAKE_FOR` | delta |
| --- | --- | --- | --- |
| Euler V2 | 613,921 | 615,494 | +1,573 |
| Dolomite | 809,879 | 811,355 | +1,476 |
| Aave v3 | 603,867 | 606,096 | +2,229 |

~1.5–2.2k per fill, consistently: `_forSlice` re-prices the leg and the dispatch
carries one more word. That is the price of the funding amount being a signed leg
the core computes rather than a second number in a blob — and on Euler/Dolomite it
also buys partial fills that were previously impossible. All three still beat the
two-item `[MAKE, TAKE]` pair they replace.

**Limits, deliberate.**

- **Single-order path only.** `matchSettle` refuses `TAKE_FOR` at
  `_assertMatchShape`: the funding leg is usually value the maker must already have
  RECEIVED, and the netted path schedules deliveries and items independently.
- **No one-shot permit.** A `PermitTake` witnesses `(module, amount)` and nothing
  about the funding leg, so it cannot authorise this shape; a fill carrying one that
  reaches only `TAKE_FOR` items fails closed with `PermitTakeNotConsumed`.
- **Balance form: mind what the read sees.** Items run after output delivery and
  before the input legs are paid, so a 100%-of-balance funding leg sweeps anything
  the solver just delivered but does NOT reserve the relayer fee. If the funding
  token and the fee leg's token are the same, size the cap to leave the fee behind
  — or fund and pay in different tokens, which is the natural shape (wallet
  collateral funds the deposit, borrow proceeds pay the fee).
- **Allow ceil margin on the token allowance.** A SELL output leg is priced per fill
  with a `ceil`, so N slices can deliver marginally more than the leg total (in the
  maker's favour, pre-existing). The funding leg pulls exactly that, so the maker's
  token allowance to the module wants a few units of headroom. BUY legs and the
  literal form sum exactly.

## 9. Open / next

- Build the §5 report-verify for fungible-delivering settle modules.
- An `NftBuySettlementModule` (filler's NFT → maker) + the ownership-invariant
  pattern, and the ERC-1155 variant (`safeTransferFrom` with `id`+`amount`).
- Consider whether the fill module + a `SETTLE` module should share the same
  `takerData`/`data` channel for a fully module-matched exotic order.
