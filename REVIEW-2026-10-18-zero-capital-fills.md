# Design review: where filling still needs filler capital (2026-10-18)

Principle under review: **every order must be fillable by a filler with zero
inventory and no flash loan; holding inventory may only ever improve a fill, never be
required for one.** Task 31 (branch `zero-capital-item-fills`) fixed the first such
gap found: items on the single-order path ran only in the forward ordering, so every
module-based order needed capital or a flash. This review asks what else of that kind
remains.

Scope: the core entries (`packages/core/src/settlement`), the production solver and
flash family (`packages/solvers/src`), every module package (`packages/modules`), the
SDK classifier and the beta filler (`packages/beta-filler/src`), against
`docs/fill-ordering-capital-plan.md` as the baseline. Method: three independent
read-throughs (core / solver + filler / modules), each briefed with the baseline and
told to report only what it misses, then spot-verification of every structural claim
against the tree. Agent-run, not an external audit. No files were modified.

**Bottom line.** The core after task 31 is close to the principle: `PostInputs`
covers every item-free shape, and `matchSettle` fills every acyclic item shape with
zero capital, including a leverage open with LTV headroom (the literal TAKE_FOR form
is admitted). Four core gaps remain structural (§1). The larger distance from the
principle is **not in the core**: the production solver cannot use inventory at all,
cannot receive or sell a SETTLE receipt, routes only one input, has no flash wrapper
for the cycle class, and the filler refuses most of what the contract can already do
(§2, §4). Three venues ship no pre-funded sink, so their zero-capital fill needs a
maker approval no other venue needs (§3).

---

## 1. Core: structural gaps (need a Settlement change)

| # | Gap | Where | Why it forces capital | Fix idea |
| --- | --- | --- | --- | --- |
| C-1 | **First fill of a Permit3 single-signature order** (`PermitBatchWitness`) is forward-only | `Core.sol:258-263`: `_fillWithPermitCore` hard-codes `callbackTarget = 0, PreDelivery`. No other entry can run it: `_openSigned` / `_openGated` verify an *Order* signature, and a witness signature is not one | The "no standing approval" onboarding shape is exactly the one a zero-capital filler cannot start. The app sidesteps it with an ERC-2612 permit to Settlement (`sdk/src/erc2612.ts` header), which exists only for 2612 tokens and non-strict makers. The remainder after one partial fill IS callback-fillable (`_verifySignature` short-circuits on `prevFilled != 0`) | `(callbackTarget, callbackData, mode)` on `fillWithPermit`, or a `permits[]` relayed at `matchSettle` open |
| C-2 | **PermitTake-funded orders with any output leg** are forward-only | `Core.sol:645` hard-codes `_settleForward`; `MatchPlan` has no permit slot (`Structs.sol:356-365`), so a netted TAKE falls back to the standing `PERMIT3.take` the maker chose not to grant. `takerData` is `""` throughout (`:607, :609, :645`) | "One-shot borrow/withdraw, sell the proceeds" always needs fronted outputs; only output-free PermitTake shapes are zero-capital. Also no fill-module / attestation orders through this entry | A `permitTake` slot on `MatchPlan` set into `ctx` at open |
| C-3 | **DIRECT (delta-verify) + items** is unfillable without capital by anyone | `Batch.sol:107 DeltaVerifyNotBatchable`, `Core.sol:1199 ReverseModeRequiresNoItems`, solver `DirectNotMatchable :1196` | DIRECT is the app's **default** delivery mode, so item features and the default mode are mutually exclusive on the zero-capital path. Native-out with items inherits it. Known (plan §4.6: third callback mode, −78k gas, +470 B, not built) | Restated, not new. Decide: either the §4.6 mode, or the app signs pull for any item-bearing ticket (what it already does for `NativeUnwrapModule`) |
| C-4 | **One DELIVER per order, one spend per leg: no multi-round composite** | `Batch.sol:676-677, 688-729` (all legs paid in one step, `DELIVERED_BIT` once), `Base.sol:890-894` (`outs[j]` spent once) | A fused "deliver C1 → deposit → borrow more → deliver C2" cannot be expressed; iterated leverage must be unrolled into N orders or wrapped in a flash. Good news verified alongside: a **single-round** leverage open with headroom is already zero-capital (`ITEM(TAKE_FOR literal) → PRESEND → CALL → DELIVER → ITEM(pre-fund MAKE)`) | Per-leg `DELIVER(i, j)` using the free `b` word (`Batch.sol:561`) plus per-leg delivered bits |
| C-5 | **Fee-on-transfer inputs cost the filler the fee on the netted path only** | `Batch.sol:661-666` PULL credits nominal `owed` while the pool receives less → `BatchNotWhole` unless the solver's residual covers it. The forward path pulls nominal maker→filler at no filler cost (`Core.sol:1351`) | The one token class where `matchSettle` is strictly worse than `fill` for capital. Consistent with the FoT stance (core asset-general, solvers specialise), but the netted path is now the zero-capital path for items | Document as a solver rule: a FoT input leg needs an item-free order or a priced residual |

Incidental friction (no capital, but makes zero-capital filling harder):

- **`fillWithCallback` has no clamp, no `recipient`, no receipts** (`Core.sol:166-179`): a competing partial fill reverts `OverFill` (`OrderState.sol:485`); the core's `fillAmount = type(uint256).max` remainder sentinel (`OrderState.sol:453-464`) is the escape and nothing uses it. Proceeds are forced to `msg.sender`, so every input leg costs one extra hop (maker→solver→router). The 6-arg overload drops `takerData` (`Core.sol:122`), so a fill-module order needs the 8-arg one; no test combines `fillModule` with `PostInputs`.
- **No callback-capable batch with skip-on-failure.** `batchFill → fillSelf` is `PreDelivery, cb = 0` (`Core.sol:455, 513, 536-538`); `matchSettle` is all-or-nothing. A "fill what you can" over N quotes must live in the solver (its own loop over `fillWithCallback` works, since `_exit` releases the guard per call).
- **PRESEND pays `msg.sender` only** (`Batch.sol:936`): an EOA can never drive a zero-capital netted plan, and a contract pays one extra transfer to reach a router.
- **`ItemPolicy.CANONICAL` is a maker-signed capital requirement** (PULL waits for DELIVER, `Batch.sol:402, 656`). The SDK default moved to ORDERED in task 31; orders signed before that are forward-only for life.
- **Rounding**: SELL outputs ceil (`Pricing.sol:90`), inputs floor (`:168`), so an exactly balanced two-order CoW can be 1 wei short → `BatchNotWhole`. A matcher needs a wei of spread.

Verified **not** gaps: `PostInputs` supports multiple output legs, fee legs, DIRECT, exact-output BUY, rising and proportional inputs, Dutch/priority/price-module pricing, fill modules (`Core.sol:1204-1269`, `Pricing.sol:79-163`); the only `PostInputs`-only revert is `ReverseModeRequiresNoItems`. Residue never strands on the filler (`Core.sol:1341-1346`, `Batch.sol:871, 980`). `batchSettle` / `batchSettleItems` **no longer exist** (`Batch.sol:21-23, 276`); `docs/batch-settle.md` and `docs/item-aware-netted-settle.md` describe deleted entries.

## 2. Solver: where the principle's second half fails

| # | Gap | Where | Why it matters |
| --- | --- | --- | --- |
| S-1 | **Inventory is structurally unusable inside `AggregatorFillSolver`.** Every approval and push is `balanceOf − before` (`:2510, :2537`); the callback's only funding source is the route's output. Retain mode only accumulates spread; the balance floor withholds one wei; `maxPay`/`minOut` bound the route. An empty route reverts | `AggregatorFillSolver.sol:1621-1636, 2425-2434, 2497-2545` | "Inventory only enhances" is unmet for the app's default shape: inventory exists only as a **different filler identity** (the EOA via `fillUpTo`, or `UsdrifInventorySolver`), and a DIRECT order naming the solver can never be served from it (`quote.ts:437-443` encodes inventory as pull-only). The one side door is a treasury contract as the route target through `RouteSandbox` (`:151-154`), which plants the standing approval the solver's own header (`:197-215`) warns against. Fix: an operator-only, delta-bounded `topUp` from the solver's own balance before `_approveOutputs` / `_pushOutputs` |
| S-2 | **SETTLE receipts in a foreign token are stranded, and the solver cannot receive an NFT at all.** No `onERC721Received` / `onERC1155Received` anywhere in `packages/solvers/src`; `NftSettlementModule :59` and `Erc1155SettlementModule :40` use `safeTransferFrom(maker, filler, …)`, so an NFT sale through `executeItemFill` reverts in the collection's receiver check. Fungible receipts in any token but `legsIn[0]` are retained, not routed (`:359-368`, `_route :2140`) | solver header `:289-300`; `nft/test/NettedNftSale.t.sol` passes only with a bespoke test solver that has the hook | Plan §3's "NFT sale: yes, if the solver can sell the asset" is **not** implemented: the filler fronts the payment and ends up holding the asset. Fix: receiver hooks + push the receipt to the sandbox before CALL (a multi-input route) |
| S-3 | **Multi-input orders are silently degenerate; multi-output has no producer.** Only `tokens[0]` is pushed to the route; every other input token is "split as residue" to the filler (`:2140`, header `:338-340`). Opaque routes may yield N output tokens (`:2531-2544`) but pool routes are single-output (`:2208`) and the filler refuses `legsOut.length != 1` (`policy.ts:105`) | | An order paying two tokens can only be filled if the anchor alone covers the output, and the maker's second token becomes filler profit. LP-mint and fee-in-third-token shapes are "yes" on paper only. Fix: route every input leg or refuse `nIn > 1`; a multicall route builder for the sandbox path |
| S-4 | **No flash wrapper around `matchSettle`, no Uniswap-v3 `flash()`, no flash source on Rootstock.** Every flash solver's inner call is single-order `fill` / `fillWithPermit` (`BaseFlashSolver.sol:380-386`); providers are Balancer, Aave, Euler, Morpho, Midnight. The SDK returns `needsFlash` for a path that does not exist (`itemFill.ts:139-183`) | | The cycle class (leverage open/close at the edge, fused composites, ORDERED TAKE_FOR) has **no filler at all** on the beta chain. Fix: a `MatchFlashSolver` taking a v3 pool `flash()` around `_callMatch` |
| S-5 | **Race handling is revert-and-strike.** `executeFill` passes `fillAmount` verbatim → `OverFill`; the filler sends the whole book `fillable` (`routeFiller.ts:595`) and on an on-chain revert strikes every strategy for the order (`guard.ts:297-315`). `executeItemFill` does not inherit `MatchRaceGuard`, so a lost race pays the full `matchSettle` approach (23.4k vs 3.7k, filler-strategy §1) | | Any competing partial fill costs a full reverted fill plus a backoff on an order that still has room. Fix: pass `type(uint256).max` on input-patched pull plans; `MatchRaceGuard` on `executeItemFill` |
| S-6 | **Item fills run with zero price protection.** `ItemFillUnsupported :1191` refuses `minBumpBps`; the filler sends 0 (`routeFiller.ts:687`); `MatchPlan` carries no bump floor | | A priority / gas-bump / descending-curve / price-module order via `executeItemFill` can move maker-ward between preview and inclusion; `maxPay = owed` does not cover a rising BUY input. Fix: a `minBump` on `MatchPlan` (core bytes), or refuse such orders on the item path |
| S-7 | **Shape caps beyond the core's.** `NativeLegShape :1784/:1796` refuses a WRBTC fee leg or WRBTC input next to a `NativeBalance` leg (the core pulls a WRBTC fee leg normally, so the obvious gasless relayer-fee native order has no zero-capital path); `NoLegs :1660` refuses zero-output orders, the one shape that needs no capital at all; `TooManyTokens :1749` caps at 8 | | Fix: net kept-back WRBTC legs from the unwrap amount; admit `nOut == 0` as a route-less fill |
| S-8 | **Solver redeploys orphan DIRECT and `NativeBalance` orders.** `Core.sol:1068` binds a DIRECT order to one `exclusiveFiller` for life; the app signs that address (`order.ts:345`); the book requires it for NativeBalance (`native.ts:137`). The filler's `AGGREGATOR_SOLVER_LEGACY` keeps old instances alive but strips native/item support (`config.ts:829-838`) | | Every solver version bump leaves a tail only the retired contract can fill, and the inventory EOA is an outsider to any single-solver window (`deploymentConfig.ts:58-62`). Fix: FILLER_SET-shaped exclusivity for DIRECT in the core (currently fails closed, `Core.sol:1057-1059`), or a forwarding shim |

## 3. Modules

| # | Gap | Where | Why it matters |
| --- | --- | --- | --- |
| M-1 | **Euler v2, Dolomite, Fluid and Gearbox-credit ship no pre-funded MAKE** (deposit or repay). Census: 15 `*PreFundModules.sol` in the tree, none under `euler-v2/src`, `dolomite/src`, `fluid/src`; Gearbox credit is pull-only (`:298, :385`) | `EulerV2Modules.sol:82, 174`; `DolomiteOperatorModule.sol:244, 284`; `FluidModules.sol:307, 364` | The acyclic open (borrow TAKE early + supply late) and acyclic close (withdraw TAKE early + repay late) work zero-capital on 14 venues; on these four the late sink is a pull, so the maker needs a Permit3 allowance to the module for a token they never held, on top of Dolomite's operator grant. Exactly the "batch-native" venues the docs showcase. Fix: `Op.Deposit/Repay` pre-fund branches via `PreFundModuleBase._gatePreFundMake` |
| M-2 | **Gearbox credit accounts cannot be closed through modules at all.** The only value-out op is `increaseDebt + withdrawCollateral` (`GearboxCreditBorrowModule :417ff`); there is no withdraw-only TAKE | | Deleverage/close is impossible with any amount of capital. Also Teller is value-in only, and its pool deposit needs the module Hypernative-registered per chain (`TellerPreFundModules.sol:29-32`) |
| M-3 | **All composites are cycles by construction** (`AaveV3CreditModule :226-228`, Dolomite `Open/BatchOpen/BatchClose :430-553`, Euler `Open/Batch* :251-424`, `FluidTakeForModule :641-713`, `FluidOperateModule Open/Close :539-574`, `RiverOpenModule :324-381`): one item both consumes the DELIVER and funds the PULL. No module exposes a venue-native "borrow first against existing collateral, deposit after" inside one item; EVC `batch`, Morpho callbacks and Fluid `liquidityCallback` are used only to fuse or fund | | Fluid `Close` is the only repay-all path on Fluid, so a Fluid full close is flash-only. The filler's classifier must treat every fused composite as flash-or-skip |
| M-4 | **LayerZero bridge-out fee is a prepaid native float on the module.** `_send` quotes and pays `send{value: fee}` from `nativeCredit[feePayer]` (`LzOftBridgeOutModule.sol:180, 221-228, 300-313`); `makeOnBehalf` is non-payable, so the fee can never come from the fill's legs. Maker-paid needs a prior `topUpFor` tx; sponsored binds the filler (`FillerNotSponsor :125`) and forces the SETTLE seam | | On LZ the filler's "inventory" is a native float consumed per message and not priced by the auction. Across (fee from amount) and CCTP (fee withheld) front nothing. Fix: a pre-fund branch that unwraps a delivered WETH leg into `nativeCredit[maker]` in the same item |
| M-5 | **Pull-only sinks** (maker must approve the module for the delivered token): all three bridge-out modules, Dolomite/Euler/Fluid/Gearbox-credit deposit+repay, `CompoundV2Native*`, `ListaNative/SmartSupplyCollateral`, `MidnightLendModule`, `FeeTransferModule`, River's side leg | `BridgeOutBase._pull :108-111` | The bridge case is the sharpest: the plan already flags it, and the module header describes the deliver-then-pull-back round-trip as the design. Fix: a pre-fund branch in `BridgeOutBase` keyed on `PreFundGuard.requireLegRef` |
| M-6 | **Netted interleaving is tested on 1 of 15 lending venues.** Plan §4.1 says "must be tested on every pre-fund module"; only aave-v3 (`NettedPreFund.t.sol`), NativeUnwrap, ProportionalSweep, OCO and NFT have netted tests. The other 14 lending packages have zero files referencing `matchSettle` or `executeItemFill` | | Sound by library (`PreFundGuard.floorOf/sweepSurplus :220-251`), but Exactly's mandatory `totalAmount` and Midnight's dynamic decode have never run on the path that is now their zero-capital path |

Verified not gaps: no module pulls from or needs an approval from the filler (shapes rule 10); Fluid's just-in-time custody needs nothing from the filler; `ProportionalSweep` never over-sweeps the cap or reverts under interleaving; balance-form TAKE_FOR is correctly refused and loses nothing.

## 4. Off-chain: the cheap half of the distance

The beta filler's `plainShape` (`policy.ts:104-146`) refuses six shapes the solver already fills zero-capital: fee legs (same-token and in-kind), proportional inputs, validators/invariants, fill/pricing modules, third-party recipients, sigless (on-chain-approved) orders. `ITEM_FILLS` and `NETTED_DELIVERY_FUNDED_ITEMS` default to off (`config.ts:720-721`), and nothing off-chain ever calls `sweep`, so any retained receipt (S-2) sits until an operator does it by hand. On the live Rootstock Settlement item fills are refused by the deployed shape guard anyway, so the flags are correct until the task-31 Settlement ships.

## 5. Doc drift found on the way

- `docs/batch-settle.md`, `docs/item-aware-netted-settle.md`: describe `batchSettle` / `batchSettleItems`, which no longer exist.
- `docs/fill-ordering-capital-plan.md` §3: NFT sale "yes, if the solver can sell the asset" (it cannot receive it, S-2); §4.3 "multi-output routes" (contract-only, S-3); §4.5 "one flash around the plan" (no such solver, S-4).
- `AggregatorFillSolver.sol:369-374`: the permit first fill is "taken by the flash family", true only where a flash provider exists.
- `docs/filler-strategy.md`: no section on `executeFill` / `executeItemFill` races; the page is `matchSettle`-shaped throughout.

## 6. Suggested order of work

1. **S-1** (inventory as a first-class, delta-bounded top-up in the solver): the only item that contradicts the principle's second half, and it needs no Settlement bytes.
2. **S-4** (flash around `matchSettle`, with a v3 pool `flash()` source): gives the cycle class its first filler on Rootstock; solver-only.
3. **S-2 + S-3** (receiver hooks, multi-input route): makes SETTLE orders and multi-leg orders real; solver-only.
4. **M-1** (pre-fund deposit/repay for Euler, Dolomite, Fluid, Gearbox credit): module-only, closes the receive-side approval on the showcase venues.
5. **C-1, C-2** with the next Settlement version (the audited rollout already changes the address): callback args on `fillWithPermit`, a permit slot on `MatchPlan`. C-4 and S-6 (`minBump` on `MatchPlan`) compete for the same bytes; measure before choosing.
6. §4 filler policy and §5 docs: whenever convenient.
