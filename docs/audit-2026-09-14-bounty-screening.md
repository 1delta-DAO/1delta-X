# Bounty-corpus screening — six lenses over B1…B14 (2026-09-14)

Scope: the full tree (121 Solidity files, 29,626 lines) **plus, for the first time,
the periphery the bounty corpus says incidents actually land in**:
`SettlementLens.sol` (read from disk by the periphery lens), `packages/sdk/src`,
`packages/orderbook/src`, `packages/orderbook-server/src` (8,616 lines of
TypeScript, bundled for three of the six lenses). Each lens was briefed with
[`reference-bounties.md`](reference-bounties.md) and assigned two or three of its
classes to hunt as *variants* — enumerate every site of the shape, prove it safe in
one line or emit. Deduplicated to **8 findings, 6 periphery defects, 22 leads**;
four findings carry executed PoCs.

**All eight findings and all six periphery defects fixed 2026-09-14** (same day,
second pass) — see the status lines on each below and the ledger in
[`reference-bounties.md`](reference-bounties.md).

**The corpus predicted the distribution.** The two hardest findings are a
fixed-point scale that truncates to zero (B1 — the 1inch `uint32 decayFactor`
failure, on the one validator whose job is the market limit) and a byte-map
header that disagrees with its reader (B3). The periphery, never read by a lens
run before, produced six defects in one pass, one of which means the orderbook
cannot admit any order against a real lens. And F28's own inbox fix is reopened:
it closed the theft and left the first-writer's ownership of the key (B12).

---

## Findings

### 1 — `ChainlinkTickFloorValidator`: the 1e18 `scale` is sub-integer for the common pair shape — **PoC · FIXED**

Confidence 90 · class B1 · [ChainlinkPriceValidators.sol](../packages/validators/src/ChainlinkPriceValidators.sol)

The NatSpec formula `scale = 1e18 · (10000 − tolBps)/10000 · 10^(dOut − dIn − dFeed)`
is the encoder spec (there is no SDK builder). For WETH(18) → USDC(6) against an
8-decimal ETH/USD feed the exponent is −20, so `scale = 0.0098` → **0**, and the
on-chain check `out0 * 1e18 >= in0 * ref * scale` is `>= 0`: the market limit never
gates. Exponent −18 (WBTC/DAI) → 0 too; −17 → `9.8` → 9, tolerance silently
loosened 8% against the maker. PoC (profile `validators`, passes): order sells 1e18
for 2500e6, feed 4000e8 — correct floor blocks (2500 < 3920), contract returns
`true`; still `true` at 1,000,000e8. Nothing on-chain rejects `scale == 0`.
**Fix:** revert on `scale == 0` (a revert folds to `false` in `gatePasses`,
fail-closed); re-base the encoding so the exponent cannot go sub-integer — carry
`(num, den)` and check `out0 * den * 1e18 >= in0 * ref * num`, or use a 1e36
base; lens rule rejecting a zero/absent scale; a test that asserts the gate BLOCKS
at a runaway price for the 18/6/8 shape.

### 2 — `ExactlyRepayModule`: header byte map puts the permit where the fixed branch reads `totalAmount` — **PoC · FIXED**

Confidence 85 · class B3 · [ExactlyModules.sol](../packages/modules/lending/exactly/src/ExactlyModules.sol)

Header: `abi.encode(market, asset, maturity, maxAssets[, DustAction[, deadline, v, r, s]])`
— "DustAction@128; permit@160". Reader on the fixed-maturity branch: `totalAmount`
at 160, permit at 192. An encoder following the header hands `deadline` (≈1.7e9) to
`ProratedBound.scale(maxAssets, slice, total)` as the total, so any 18-decimal slice
≥ 1.7e9 wei presents the **whole** `maxAssets` ceiling per slice (PoC: 1% slice →
100% ceiling; 6-dec 10% slice → 57%) — the F26 slice-dilution class this scaler
was added to close — and the permit is silently never replayed. Nothing caught it
because `check-module-shapes.py` checks pins, floors and reject branches, not
literal offsets against headers (the registry's B3 verdict overstated the tool).
**Fix:** correct the header (`totalAmount@160` mandatory when `maturity != 0`,
permit @192); add a shapes rule extracting every `readAction/readBalanceMode/
requireFullFillFromData/replay*(data, N)` literal and asserting it appears in the
header's byte map; harden `_scaledBound` to reject `total < amount` on a partial.

### 3 — `OcoGroupModule`: the claim nonce in item `data` is bound to `order.nonce` nowhere — **PoC · FIXED**

Confidence 90 · class B6 · [OcoGroupModule.sol](../packages/modules/oco/src/OcoGroupModule.sol), `sdk/amend.ts`

`settle` writes `claim[maker][G] = itemNonce + 1`; `validate` compares against the
real `order.nonce`. The only binding is the SDK convention `ocoGroupItem(…,
order.nonce, …)`, and `patchOrder` (cancel-and-replace) copies `items` verbatim.
PoC on real contracts: TP{nonce 1, item (G,1)}, SL{2, (G,2)}, TP' = amend(TP, nonce 3)
→ item still (G,1). Dust-fill TP' → claim = 2 → **the soft-cancelled TP fills in
full at the stale price**; TP' and SL both `ValidationFailed`. `docs/soft-cancel.md`
recommends OCO as the on-chain answer to "a filler still holds the old order" —
exactly the shape that breaks. **Fix:** on-chain, `validate` walks `order.items`
for the SETTLE record on this module and requires `(groupId', nonce') == (groupId,
order.nonce)`; SDK `patchOrder` re-derives OCO items (or throws), `ocoGroupItem`
takes the `Order`.

### 4 — `BridgedOrderInbox`: the first credit still owns `commits[H]` — F28 fix reopened · **FIXED**

Confidence 85 · class B12 / B14 · agents 2/6 · [BridgedOrderInbox.sol](../packages/modules/bridge/src/BridgedOrderInbox.sol)

F28 pinned the beneficiary to the first credit and made later mismatches fail;
that converts the theft into a permissionless, dust-cost, permanent DoS. Vector A:
attacker credits 1 wei for the victim's `H` with `beneficiary = attacker`,
`expiry = 0`, then calls `settle(H)` immediately → `settled = true` → every later
credit reverts (Across relay unwinds) or is orphaned behind owner `rescue()` (LZ);
`activate(H)` reverts forever. Vector B (predates F28): a 1-wei credit in a
*different* enabled token pins `k.token`, so the victim's real delivery hits
`TokenMismatch`/`Orphaned`. Vector C: copy the victim's beneficiary with
`expiry = 0` → anyone refunds the victim's funds to them before activation (the
NatSpec accepted this half). The existing regression test asserts "victim
principal never merged" as the desired outcome without evaluating the occupation.
**Fix:** key the escrow by `keccak256(orderHash, beneficiary, token)` so a
stranger's credit lands in its own row; one activated row per hash; make `settle`
non-terminal (refund what is unspent, allow re-credit) so a premature settle on a
copied-beneficiary row is a harmless early refund; restore `expiry = max` and add
`settleExpired(order, …)` that refunds once the ORDER's own deadline has passed,
which defuses the 2106 lock without an attacker-shortenable clock.

### 5 — Proportional-anchor donation grief reaches every entry except `fillUpTo` — **FIXED on the netted path; by design elsewhere**

Confidence 80 · class B14 · [OrderState.sol](../packages/core/src/settlement/OrderState.sol)

BB-9 recorded `Batch._openGated`; it is wider. `_openFill` sets `fullFill = prev == 0
&& newFilled == total` with `total` re-resolved from the maker's live balance, and
`Pricing.inputOwed` reverts `ProportionalNeedsFullFill` otherwise. A 1-wei
transfer to the maker in the same block as the fill reverts `fill`,
`fillWithCallback`, `fillWithPermit`, `fillWithPermitTake`, `batchFill` and the
whole `matchSettle` plan; only `fillUpTo` clamps. **Fix:** clamp `delta = total −
prevFilled` in `_openFill` for a proportional anchor (the rule `_clampToRemaining`
already applies), and have `_openGated` call it.

### 6 — `DolomiteOperatorModule._batch` close lacks the `WouldBorrow` read the Exact path got — **FIXED**

Confidence 85 · class B11 · the F28 finding-3 sibling

The fused close builds the identical negative-delta withdraw for `amount` of
`collMarketId` with no live-supply read; after a permissionless partial liquidation
the close repays the reduced debt and the withdraw crosses zero — a fresh borrow
if the sub-account holds other collateral, sold at the signed price. Same root
cause, one op over. **Fix:** read `getAccountWei` and revert `WouldBorrow` in
`_batch` as in `_withdraw`; fork test with a multi-asset sub-account.

### 7 — A stale nomination permit revokes a LIVE delegate — **FIXED**

Confidence 75 · class B14 · agents 2 · [Signatures.sol](../packages/core/src/settlement/Signatures.sol)

`setOrderSignerWithSig` normalises a lapsed `expiry` to 0 and writes
`orderSignerExpiry[maker][signer] = 0` plus burns the delegate's word — the
NatSpec frames it as "end gasless nomination", but it also clears a *current*
direct `setOrderSigner(d, T2)` the maker made after signing the stale permit. A
third party holding the unrelayed permit revokes a live desk key, permissionlessly.
Over-revoke direction, recoverable by re-nomination. **Fix:** reject a lapsed
`expiry` outright (`SignerPermitExpired`) instead of normalising, or skip the
write when a live direct nomination exists.

### 8 — `SettlementLens` disagrees with the settler on six gates — **FIXED**

Confidence 80 · class PERIPHERY (lens ≠ core) · agents 3 · [SettlementLens.sol](../packages/periphery/src/SettlementLens.sol)

The lens is the promise every "flagged off-chain" comment in the core makes, and
the orderbook admits on its word. It does not keep: (a) **fill-once** —
`previewFill`/`_orderState` quote partial fills the settler rejects
`FillOnceMustBeFull`; (b) **reserved nonce** — bit-255 nonces validate and read
`Fillable`, every fill reverts `OrderNonceReserved`; (c) **delta-verify** — no
read of bit 104: the same-token exit shape with items passes but reverts
`DeltaVerifySameToken`, and delta-verify orders preview `Fillable` on entries that
revert `DeltaTooLow`; (d) **strict mode** — `_makerFillableCap` counts the direct
ERC-20 allowance a strict payer's fill refuses (3 lenses); (e) **pre-fund
override** — a pre-fund leg with `overrideBps != 0` passes but reverts
`ForLegNotMakers` for any in-window outsider, and a pre-fund MAKE reports
`required = item.amount` (0); (f) `ForLegReused`, the `SettleSliceZero` threshold
(and TAKE_FOR), unknown op bytes, and a proportional anchor at zero balance
reading `Filled`. **Fix:** one mirror line each; and a test that runs every
core revert selector through `validateOrder`.

### What was done (2026-09-14, second pass)

1. `ChainlinkTickFloorValidator` takes `(feed, maxStaleness, num, den)` — a rational, both halves integral for every decimal shape; `ZeroRatio` reverts; the old 3-word blob decodes short (fails closed). SDK `tickFloorRatio` / `encodeTickFloorData` / `tickFloorValidator` added, with an encoding vector run through the real validator. **BREAKING** data shape.
2. `ExactlyRepayModule` header rewritten (branch-scoped tail: `totalAmount@160`, `permit@192` on the fixed branch); `check-module-shapes.py` rule 9b now fails any module that reads a `data` offset its header does not mention (21 headers documented to pass it); `ProratedBound.scale` refuses `amount > totalAmount` (`BoundSliceExceedsTotal`) so a timestamp can never be read as a total.
3. `OcoGroupModule.validate` walks `order.items` and requires the SETTLE record on this module to encode `(groupId, order.nonce)` — a validator-only leg is now unfillable; SDK `patchOrder` re-homes OCO items via `renonceOcoItems`.
4. `BridgedOrderInbox` rows keyed by `commitKey(orderHash, beneficiary, token)`; `activate(order, beneficiary)`, one active row per hash (`RowActive`); `settle(hash, beneficiary, token)` non-terminal with cumulative `refunded`; `settleExpired(order, beneficiary)` refunds on the ORDER's deadline; `expiry` = max. **BREAKING** interface.
5. `Batch._openGated` honours `fillAmounts[i] = type(uint256).max` = the whole remaining anchor. The plain-entry ceiling semantics stay as `docs/proportional-legs.md` documents them (+253 gas refused; `fillUpTo` is the documented route) — a core clamp was built, measured 79–124 bytes over EIP-170 and reverted.
6. `DolomiteOperatorModule._batch` close reads `getAccountWei` and reverts `WouldBorrow`, with fork tests for both ops.
7. `setOrderSignerWithSig` reverts `SignerPermitExpired` on `0 < expiry < now` instead of normalising to a revocation.
8. Lens: reserved-nonce, fill-once (preview + state), delta-verify same-token scan, strict-mode capacity, pre-fund+override, leg reuse, indivisible-item full-fill rule extended to TAKE_FOR, unknown op, proportional zero-balance state — `LensGates.t.sol`, 10 tests.

Settlement runtime after all of it: 24,533 / 24,576.

## Periphery defects (functional; the book cannot be trusted with them open) — **ALL FIXED**

P1 `packOrder` at both lens call sites + a Verifier test that runs the real ABI encoder; P2 Layer-2 cache keyed by `(hash, keccak(sig), sigless)`; P3 maker bucket charged after Layer-1 proof (or on success for deferred sigs), regression test; P4 `known` earned from the live predecessor; P5 `filled` read at the log's block, sentinel and zero reported as `null`; P6 a dedicated `replaces` topic subscribed by the book and published by the client. Also: the server suite had been running against a **months-old `dist/`** of the SDK and orderbook (which is how P1 stayed green) — `make test-ts` now builds both dists first; the stale `deadline`/`baselinePriorityFeeWei` fixtures were repaired.

Leads closed alongside: `Verifier` defers delegate-signed orders to Layer 2 instead of rejecting; `packOrder` throws on `side ∉ {0,1}` and on an `expiry` above uint48; `feeSplitLegs` refuses a fee leg that would emit the `end == 0` sentinel; the server binary cross-checks `LENS.SETTLEMENT()` / `PERMIT3()` at boot; five README `approveTaker` arities corrected.


| # | Where | Defect | Fix |
| --- | --- | --- | --- |
| P1 | `orderbook/src/verify.ts` `verifyLayer2`, `orderbook-server` `GET /quote` | passes the **unpacked** authoring `Order` to the lens ABI (`orderComponents` = packed `bytes` + `params`); viem throws → every `POST /orders` 500s, the book never self-cleans, `/quote` 422s. Only stubbed tests exist. Two packed-order migrations behind — the `sdk-packed-order-sync` class | `packOrder(...)` at both sites; one test through viem's encoder against the real ABI |
| P2 | `Book.admit` + `Verifier.layer2Cached` | re-announce dedup overwrites the stored signature unconditionally and the ≤15 s Layer-2 cache is keyed by hash only, so an unauthenticated client poisons any live order's served sig and gets it evicted on the next sweep | key the cache by `(hash, keccak(sig), sigless)`; keep the first verified announce |
| P3 | `orderbook-server` `gateMaker` | the per-maker bucket is charged on the **claimed** maker before verification; one IP zeroes one maker's write/cancel budget forever at 1 req/10 s | charge after Layer-1 recovery, or on success |
| P4 | `orderbook-server` `POST /replaces` | `checkAdmission(known: true)` hard-coded; naming a never-seen predecessor bypasses `maxOrders`/per-maker caps unboundedly | `known = book.get(replaces)?.maker === maker`, else normal admission |
| P5 | `orderbook/src/fills.ts` `FillIndex.resolveAmount` | differences `filled(H)` at HEAD instead of the log's block: same-block fills → (both, 0); cancel sentinel → ≈2^256; fill-once → 0 | read at `log.blockNumber`, null the sentinel |
| P6 | `Book.start` / `OrderbookClient.replaceOrder` | replaces are published on the order topic and the book subscribes the order topic to announces only — over any real transport every replace is dropped; only REST `/replaces` works | subscribe `ingestReplaceBytes`; separate topic |

## Leads (22)

- **B14** `PositionFillModule.resolveFill` — 1-wei supply-on-behalf reverts a filler who quoted `position` rather than `fillTotal` (2 lenses; documented mitigation).
- **B12** `ERC4626WithdrawModule` — a `REQUEST_ID_0` (ERC-7540) vault lets the first requester hold id 0 and block every other maker's Phase 1.
- **B8** `PositionFunnelFactory.deploy(owner = 0)` — a zero-owner funnel's 65-byte `isValidSignature` branch accepts any signature (bare `ecrecover` → 0); no victim today.
- **B14** `Signatures._verifySignature` — bulk-root branch selected by shape (`(n−66) % 32 == 0 && sig[n−1] == 0xB0`); a native 1271 blob of that shape is misread (≈1/256 per matching length).
- **B2** `ExactlyPreFundModule._scaledFace` — delivered/total as fill fraction; numbers: full fill at bump 10000 retires 95% of the face, or presents the whole face on a 96% partial (BB-6).
- **B2** `MidnightRepayModule` — units vs tokens with no residual sweep (its pre-fund twin sweeps).
- **B1** `packOrder` — `BigInt.asUintN(48, expiry)` wraps silently where every sibling throws.
- **B2** `PermitHelper`/`DelegationHelper` callers — replayed permit `value = slice`; on any partial fill the gasless path silently degrades to "needs a standing grant" (Exactly alone has `replayValueIfPresent`).
- **B4** `Verifier.verifyLayer1` — rejects delegate-signed orders the settler, lens and the book's own cancel verifier accept.
- **B4** `packFillerSet` — no wire path (`packOrder` always packs `curve`); `OriginSettler7683` previews with `exclusiveFiller = address(1)` so a FILLER_SET order can never `open()`.
- **B4** `packOrder` — `side` unchecked; `side = 2` sets bit 102 (BLOCK clock) and reads back SELL (2 lenses).
- **B4** `feeSplitLegs` — `endFee` floors to 0 → the fee leg is emitted as `end == 0` = FIXED (2 lenses; dust magnitude).
- **B13** `sdk/permit3.ts readFundingPosture` — reads the global strict flag, not `isStrict(user, token)`.
- **B13** `orderbook-server/env.ts` — `SETTLEMENT`/`PERMIT3`/`LENS` are three unpinned env addresses; the on-chain 7683 adapters refuse that mismatch, the server does not.
- **B13** five lending READMEs document a 3-arg `approveTaker(settlement, ref, cap)` the contract no longer has.
- **B5** `orderbook/query.ts summarize` — `filledAmount = anchor − fillableAmount` with a capacity-capped `fillableAmount`.
- **PERIPHERY** `proto/codec.ts` — unbounded `bytesToU256`/`bytesToAddr`, unchecked `side`; `POST /orders` has no try/catch around `verifyAnnounce` → 500 not 422.
- **B14** `GuardedMatchSolver` — PRESEND lands on the wrapper (seen in F28).
- Doc/tool: the registry's B3 sentence "byte maps checked by `check-module-shapes.py`" overstated the tool; `DelegationHelper`'s Comet example predates the op-word layout.

## Clean (recorded so it is not re-derived)

Every `timing`/`params`/`CurvePoint`/Permit3 packed field and every `uint160` pull
(B1); `Pricing` telescoping on both sides, `_prorate`/`_forSlice`, TWAP, priority,
gas bump, `AggregatorFillSolver` deltas, `BridgedOrderInbox` anchor units (B2);
every module byte map except Exactly's fixed branch, all core hand-rolled calldata
(`_callWithTail`, `_takeByPermit`, `OrderHash`, funnel init code, cross-root
envelope) (B3); every SDK encoder except the four leads, pinned by the golden hash
and the encoding vectors (B4); all cumulative ledgers incl. `matchSettle` and
`sync` (B5); every value-carried-twice except OCO (B6); every bps/ppm/count bound
(B7); every signature consumer and hash-keyed map (B8); every callback, receiver
and hook — 100 module entrypoints, 4 `takeForOnBehalf` pins, 16 pre-fund MAKE
gates, 72 pull sites paying `onBehalfOf` (B9); all 60 venue approvals paired with
a clear, the full allowance table (B10); every venue read clamped by a signed cap
or converted to a revert (B11); every keyed mapping except the inbox (B12); every
SDK approval target explicit and consistent with the consumers (B13).
