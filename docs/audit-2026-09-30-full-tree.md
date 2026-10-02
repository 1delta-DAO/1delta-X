# Whole-tree audit and remediation status (2026-09-30)

Scope: the whole tree at **HEAD `56d1405`** (2026-09-30): Permit3, Settlement and
`SolverCallbackExecutor`, the solvers, the validators, every module package
(lending, bridge, pricing, OCO, fill, transfer, NFT, maker, redeem, ERC-4626), the
periphery (`SettlementLens`, the ERC-7683 settlers, `NativeSettler`) and the
off-chain tooling that ships with them (SDK, orderbook, orderbook-server, auction,
app). Every one of the 179 files under `packages/**/src` sits in at least one lens
scope. Findings ledger entry: [F32](reference-audits/findings-ledger.md#f32--whole-tree-audit-nine-goals-48-lenses-2026-09-30).
Run register: [audit-runs.md](audit-runs.md#f32--2026-09-30--whole-tree-48-lenses).

**This is not an external audit.** It was planned and run by AI agents (174 spawned
in the run) against the tree's own code, docs and tests, and the remediation was
also done by agents. The raw report, cluster and triage data, PoC sources and the
fixer reports live in `docs/local/audit-2026-09-30/`, which is gitignored. This page
is the permanent record.

**Status (2026-10-02, branch `audit-fixes-2026-09-30`): fixes and docs merged;
independent verification and the final gate pending.** Core, lib and twelve
component groups are fixed and merged; the cross-component pass (`7569f87`), the
partials lane (`5389bf1`, `55cbfcc`, `7889c02`, `d49cc63`) and the documentation /
CI group ("docs: 2026-09-30 audit doc leftovers") are committed. The independent
verification of each fix, the fix-up round and the final gate have not run. See
[Remediation status](#remediation-status).

---

## Method

- **48 lenses.** 42 planned lenses (core fill paths, items, matching, signatures,
  Permit3, every lending venue family, bridge, pricing, validators, solvers,
  periphery, arithmetic, assembly, reentrancy, tokens, spec drift, differential
  reads of the recent diffs, test coverage and mutation) plus 6 gap lenses added
  by a completeness round (`G-BYTE_MAP`, `G-LENS_PARITY`, `G-TS_FILLER`,
  `G-TS_SIGN`, `G-VENUE_A`, `G-VENUE_B`). Each lens had a critic pass.
- **Independent triage** of every candidate, then a **refuter** that tried to
  knock each one down.
- **Foundry PoCs in a worktree** for every high and medium: 27 attempted, **27
  reproduced** against unmodified source.
- **Variant hunts** for the 19 base medium-and-above findings: 42 variant
  candidates.
- **Mutation testing**: guard-removal mutants on the core (59 of 62 killed) and a
  pre-screened sample of 14 on the periphery (7 survived, including the mutants
  covering the F27 pre-fund drain fix and H-5).

## Totals

313 candidates, 304 kept, 9 rejected, merged into **223 issues**:

| Severity | Issues | Evidence |
|---|---:|---|
| Critical | 0 | |
| High | 1 | PoC-reproduced |
| Medium | 19 | PoC-reproduced (27/27 PoCs) |
| Low | 94 | 93 confirmed by static tracing and triage, 1 plausible (MISC-MOD-3) |
| Info | 109 | confirmed by static tracing and triage |

The run's own executive summary counts 218; five info findings dropped by a
per-check limit were reviewed on 2026-10-01 and added (G-TS_SIGN-11..15, one of
them raised to low), giving 223.

**The immutable core held.** Settlement, Permit3 and the executor have no
critical, high or medium finding; the grant model survived every hypothesis the
lenses tested. Every high and medium sits outside the core and needed 0 Settlement
bytes. The recurring cause, again, is a guarantee or earlier fix that reached one
sibling and missed its neighbours (the F19 / F27 / F28 pattern).

## Verdicts by goal

| # | Goal | Verdict at `56d1405` | Why |
|---|---|---|---|
| 1 | Overall code safety | NOT MET | 1 high and 19 mediums, all PoC-reproduced, all outside Settlement and Permit3; several need no privilege. |
| 2 | Filler flexibility | MET WITH CAVEATS | More fill tools than UniswapX, CoW, 1inch, 0x or Pendle, but each feature lives on one entry point, and the 7683, `/quote`, auction and SDK layers published quotes they did not bind. |
| 3 | User funds and standing grants | NOT MET | The core grant model held; PERIPH-1 and 11 mediums still drained a solver approval, module residue, other users' bridge escrow or maker wallets. |
| 4 | Lending modules and auth modes | NOT MET | Auth held across all 65 `makeOnBehalf` and 34 take entrypoints; six PoC mediums remained (2 residue drains, 4 venue clamps billed to the maker's wallet or overpaying a lender). Felix and Midnight paths could not run on the real venue. |
| 5 | RIF solver and Rootstock rail | NOT MET | Safe against unprivileged parties, but RIF-1/RIF-2 broke the SECURITY.md M-8 limit on a stolen operator key (PoC: 15,196.28 RIF drained, 0 charged to the budget); the beta app could not produce a fillable order. |
| 6 | Validators | NOT MET | The core gate is one fail-closed STATICCALL, but VAL-1 (payment without delivery) and PRICE-2 (1-wei OCO kill) were open to any filler. |
| 7 | Matching with hostile modules and tokens | MET WITH CAVEATS | No high or medium; honest makers and Settlement's own balance are protected. The matcher's residual is exposed (X-DIFF-CORE-1.v1, X-TOKENS-2, X-SPEC-6). Static evidence only. |
| 8 | Test coverage | NOT MET | Core strong (59/62 mutants killed, 64/66 errors asserted by selector); outside it CI gated nothing, branch coverage was 66.3%, and 7/14 periphery mutants survived. |
| 9 | Architecture, immutability, efficiency | MET WITH CAVEATS | No admin functions, one-way layering, fail-closed extension points, ~52.9k gas for a warm plain fill. Caveats: 251 B of EIP-170 headroom, CI checking only the core, no incident runbook or migration plan. |

These are the verdicts **at the audited HEAD**. No goal has been re-assessed after
remediation; that is part of the verification phase that has not run.

## High and medium findings

All twenty were reproduced by a PoC; all twenty have a fix merged on
`audit-fixes-2026-09-30`, each with a regression test the fixer reports as failing
on the original source. Solidity test names
below are checked by `make docs-check`; TypeScript (vitest) names are written
without backticks because the gate only indexes Solidity, and were confirmed by
grep.

| ID | Component | Root cause | Impact | Fix | Pinned by |
|---|---|---|---|---|---|
| **PERIPH-1** (high) | `DestinationSettler7683` | `resolve` published the current tick as `maxSpent`, `fill` enforced no cap. | A maker-controlled bump (price module, priority fee, decay) charged a 7683 solver up to `legsOut.start` from its approval. | `originData` is `FillPayload{payload, FillBounds}`; per-unit bounds enforced against `fillUpTo`'s return (`BoundExceeded`); `FillerData` can carry the filler's own bounds and `minBumpBps`. **BREAKING** originData. | `Audit20260930Erc7683.t.sol`: `test_audit_PERIPH_1_priorityAuction_fillAboveQuote_reverts`, `test_audit_PERIPH_1_simulationAwareModule_reverts`, `test_audit_PERIPH_1_fillerDataBoundsAndFloorEnforced` |
| PERIPH-2 | `OriginSettler7683` | Quoted exclusivity orders for the named filler; the destination always fills as itself. | Soft window charged up to 2x `maxSpent`; hard window was a dead broadcast. | Every quote priced for `DESTINATION_SETTLER`; soft windows quoted with the outsider premium, hard windows refused. | `test_audit_PERIPH_2_sellSoftMaxOverride_chargeNeverExceedsQuote`, `test_audit_PERIPH_2_hardWindow_notBroadcast`, `test_hardFillerSet_inWindow_refusedNotBroadcast` |
| PERIPH-3 | `DestinationSettler7683` | Forwarded a maker-published `type(uint256).max` into `fillUpTo` on Proportional orders. | An inventory relayer paid full outputs for a drained balance (the F31 dust fill, reopened). | Closed by the PERIPH-1 per-unit bounds; the sentinel is now the safe size. | `test_audit_PERIPH_3_sentinelFrontRun_reverts`, `test_audit_PERIPH_3_sentinelDonation_stillFills` |
| PERIPH-4 | `DestinationSettler7683` | SETTLE items pay `ctx.filler` = the adapter, whose sweep covers leg tokens only. | Multi-token sweep proceeds stranded in the adapter. | `Order7683.requireNoSettleItem` on every resolve/open and on `fill`. | `test_audit_PERIPH_4_settleItem_refusedNothingStranded` |
| PERIPH-1.v1 | orderbook-server `/quote` | "Ready-to-send" `fillUpTo` calldata with `minBumpBps = 0` and the raw sentinel. | The calldata was not the quote: senders charged up to `start`. | Previews at the sender's gas price, quoted bump as `minBumpBps`, resolved delta instead of the sentinel. | `packages/orderbook-server/test/audit20260930.test.ts`: test_audit_PERIPH_1_v1_calldata_carries_the_quoted_bump_as_its_floor, test_audit_PERIPH_3_v1_proportional_sentinel_is_replaced_by_the_resolved_size |
| G-TS_FILLER-1 | auction `round.ts` | Bid cap without ranking; unsigned `commitment` tie-break. | Two sybil keys could fill a round and win at the maker's floor. | One standing bid per filler, a full round displaces its worst bid, only signed fields scored. | `packages/auction/test/audit20260930.test.ts`: test_audit_G_TS_FILLER_1_two_keys_cannot_crowd_out_honest_solvers, test_audit_G_TS_FILLER_1_unsigned_commitment_cannot_win_a_tie |
| PRICE-1.v1 | auction `QuoteSolver` | SELL routes sized by `fillTotal` instead of the input. | Overbid (solver loss) or no bid on `fillTotal` orders. | Sized by `legsIn[0].start`; Proportional resolves via maker balance or returns null. | same file: test_audit_PRICE_1_v1_fillTotal_does_not_size_the_route, test_audit_PRICE_1_v1_fullfill_order_gets_a_real_bid |
| RIF-1 | `UsdrifInventorySolver.sell` | Balance-delta window not guarded against the solver's own MoC queue deliveries; `guard.execute()` is permissionless. | A stolen operator key bypassed the rate floor and budget (PoC 15,196.28 RIF). | Venue call bracketed by `MocQueue.firstOperId()`; `QueueMovedDuringMeasurement`. | `test_audit_RIF_1_sellOffsetByInWindowQueueDelivery_reverts`, `test_audit_RIF_1_v1_sellTokenOutInflatedByQueueDelivery_reverts`, `test_audit_RIF_1_honestSellWithQueuedOpStillWorks` |
| RIF-2 | `UsdrifInventorySolver._fillCapped` | A maker-signed item could trigger a MoC failed-op refund inside the measured fill. | Hourly USDT0 budget spent for ~0. | Item-bearing orders refused; fill bracketed by the queue head. | `test_audit_RIF_2_itemOrderCannotTriggerQueueRefundInsideFill`, `test_audit_RIF_2_fillRefusedWhenQueueMovesInsideIt` |
| PRICE-1 | `ChainlinkPeggedPriceModule` | Fair price computed against the fill denominator. | Every `fillTotal` order (e.g. `FullFillModule`, `fillTotal = 1`) cleared at the maker's floor. | Anchors on the counterpart leg's whole-order amount. Needs redeployment. | `test_audit_PRICE_1_fullFillModuleFillTotal1_clearsAtPeg`, `test_audit_X_ARITH_1_bpsFillTotal_halfFillAtPeg`, `test_audit_PRICE_1_buyLargeFillTotal_paysPegNotCap` |
| PRICE-2 | `OcoGroupModule` | The first fill of any size claims the group. | Anyone retired a stop-loss by filling 1 wei of a sibling. | Claim blob `(groupId, nonce, minClaim)`; claims below `minClaim` revert; missing floor fails closed. **BREAKING** (SDK and golden updated). | `test_audit_PRICE_2_dustFillCannotRetireStopLoss`, `test_audit_PRICE_2_missingOrUnreachableFloor_failsClosed` |
| VAL-1 | ownership invariants | Invariants prove an end state, not a delivery (F30's delta-verify sibling). | A filler collected a purchase payment without delivering. | Core rule for ANY invariant (`Base._runInvariants`, +88 B): an order with invariants and an empty `legsOut` is fillable only by its named `exclusiveFiller`, for its whole life (`NotExclusiveFiller`; position items do not lift it). `InvariantReceiptGuard` in the shipped invariants (defence in depth); lens and SDK refuse the shape. **BREAKING behaviour.** | `test_audit_VAL_1_core_thirdPartyInvariant_openOrder_noFreePayout`, `test_audit_VAL_1_core_namedFiller_only_forWholeLife`, `test_audit_VAL_1_erc721_twoBids_oneDelivery_cannotDoubleDip`, `test_audit_VAL_1_minBalance_floorMetElsewhere_noFreeFill` |
| MISC-MOD-1 | `ProportionalSweepModule` | bps re-applied to the post-sweep balance on every partial fill. | A split fill swept up to the cap. | Fractional bps needs the 3-word blob and is full-fill only. **BREAKING** for bps < 100%. | `test_audit_MISC_MOD_1_fractionalSweep_cannotBeSplit`, `test_audit_MISC_MOD_1_fractionalTwoWord_failsClosed` |
| BRIDGE-A-1 | `BridgedOrderInbox.rescue` | `rescue()` could not tell an uncredited LZ compose from stray balance; sources removable instantly. | A later compose was paid from other users' escrow. | `orphaned[token]` ledger bounds `rescue`; unannounced balance only via a delayed stray rescue. | `test_audit_BRIDGE_A_1_orphanRefundCannotSweepQueuedCompose`, `test_audit_BRIDGE_A_1_sourceRemovalParksButRescueCannotTake`, `test_audit_BRIDGE_A_1_fork_realEndpointV2_queuedComposeNotRescuable` |
| L-LIB-1 | `MorphoBlueRepayModule` | Recycle repaid by shares under a standing max approval. | Any maker retired own debt from module residue. | Shares only when `amount >= liveDebt`; exact scoped approvals; `FloorBreached`. | `test_audit_L_LIB_1_recycleRepayCannotDrawModuleResidue`, `test_audit_L_LIB_1_ownMarketCannotDrainResidue` |
| X-STATIC-1 | `CompoundV2RepayModule` | Recycle fall-through paid a residual measured before the venue consumed it. | Module's pre-existing balance paid out (F19 floor broken). | Re-reads balance after a failed mint, sweeps only above the floor. | `test_audit_X_STATIC_1_recycleErrorCode_preservesFloor`, `test_audit_X_STATIC_1_partialConsumption_refundsOnlyRemainder` |
| L-CMT-1 | Teller repay | Relied on a clamp TellerV2 does not apply. | The maker's surplus went to the lender. | `TellerRepayLib`: `repayLoanFull` at or above owed, surplus swept; mock fixed. | `test_audit_L_CMT_1_preFundPartial_overDelivery_sweptToMaker`, `test_audit_L_CMT_1_venuePremise_repayLoanDoesNotClamp` (mainnet fork) |
| L-CV2-1 | `AaveV4WithdrawModule` | The v4 spoke clamps withdraws; the Exact branch trusted it to fail. | Short delivery billed to the maker's wallet. | `requireDelivered` on the Exact branch; shapes rule 9 extended to clamping venues. | `test_audit_L_CV2_1_exactWithdraw_shortPosition_reverts`, `test_withdraw_underDelivery_reverts` |
| L-CV2-1.v1 | `ExactlyTakerModule` | `withdrawAtMaturity` clamps to the position. | Same as L-CV2-1. | Position pre-check, `ShortFixedPosition`. | `test_audit_L_CV2_1_v1_shortFixedPosition_settlementFillReverts_walletUntouched` (Optimism fork) |
| G-VENUE_B-1 | `LiquityV2TakerModule` | The trove's remove-manager receiver survives NFT transfer. | Venue paid a third party; core billed the maker's wallet. | `requireDelivered` after the measured delta (`ShortWithdraw`). | `test_audit_G_VENUE_B_1_staleReceiver_withdrawColl_failsClosed`, `test_audit_G_VENUE_B_1_receiverIsModule_fills` (mainnet fork) |

Full test lists are in the [F32 ledger entry](reference-audits/findings-ledger.md#f32--whole-tree-audit-nine-goals-48-lenses-2026-09-30).

## Lows and infos by component

Counts are by the file each issue is anchored to. "Notable" names the items the
report's remediation plan put in P0/P1 or that change behaviour.

| Component | Low | Info | Notable |
|---|---:|---:|---|
| Settlement (core) | 9 | 17 | The six P0 core lows: **CORE-FILL-1** (zero-amount placeholder legs kept a soft window soft), **PERIPH-1.v3** (price floor only on `fillUpTo`), **CORE-FILLER-2** (fill module could upsize the filler's request), **X-DIFF-CORE-3** (direct `setOrderSigner` left relayed nominations alive), **X-TOKENS-2** (double-entry tokens double-credited on `matchSettle`, accepted). Also X-SPEC-1 (SETTLE modules must not pull from the filler, now shapes rule 10). |
| Permit3 | 1 | 1 | **CENSUS-A-3** (revoke/lockdown do not kill unapplied signed batches; accepted, Permit2 parity); P3-4 (expired-but-spent permit could not continue a partial fill; fixed). |
| Periphery (lens, 7683, NativeSettler) | 7 | 11 | Lens parity G-LENS_PARITY-1..6 (lens looser or stricter than the settler), PERIPH-5 (reserved-nonce orders read Fillable), VAL-1.v2, PERIPH-2.v2/.v3. The lens split into `SettlementLensChecks` to make room. |
| Solvers | 11 | 9 | AGG-1..3 (retain mode lock, stranded non-anchor inputs, SurplusPolicy bypass on open instances), FLASH-1/2/3/5, CORE-MATCH-1 (GuardedMatchSolver stranded PRESEND proceeds), PERIPH-1.v2 (inventory solver had no operator price bound), PERIPH-4.v1. |
| Validators | 3 | 2 | PRICE-8 (no L2 sequencer check), VAL-2 (NEGATE over a laundered failure / forced out-of-gas), X-ARITH-1.v1 (tick floor never passes Proportional orders). |
| Pricing modules | 4 | 2 | PRICE-1.v3, PRICE-3 (descending range ladder), PRICE-6, PRICE-9. |
| Other modules (transfer, NFT, ERC-4626, maker, redeem, TWAP) | 5 | 3 | L-LIB-2, MISC-MOD-3 (plausible), PRICE-7 (TWAP compression), **RIF-3** (MocPriceBandValidator could not pass on Rootstock mainnet). |
| Bridge | 10 | 5 | BRIDGE-A-2 (1-wei row lock until 2106), BRIDGE-B-2 (OFT burn of module balance), X-TOKENS-1 and BRIDGE-B-5 (accepted), **BRIDGE-B-6** (CCTP V1 sunset 2026-10-31 / 2026-12-01; moved to V2). |
| Lending modules | 16 | 30 | L-FSE-1 (Fluid NFT custody), L-ML-1/L-ML-3 (Midnight paths that cannot run), G-VENUE_B-2 (Felix), L-AAVE-1, L-CV2-4 (unbound underlying), L-LRG-1, plus venue-fidelity test gaps. |
| Lib | 4 | 5 | L-ED-1 / L-LIB-3 (EVC permit sender and idempotence; **BREAKING** tail), L-LIB-4 (replays set rather than raise grants), L-CMT-3 (venue revokes not durable). |
| SDK | 8 | 3 | CORE-FILLER-1.v2, G-BYTE_MAP-2, G-TS_FILLER-5, PRICE-5 (same-nonce replacement). |
| App (Rootstock beta) | 9 | 1 | The beta blockers: **A-IMMUT-1** (no Permit3 book grant, so no order could fill), G-TS_SIGN-1 (unauthenticated token metadata), G-TS_SIGN-3 (bit-255 nonces), G-TS_SIGN-4/-5 (false cancel / allowance statements), G-TS_SIGN-15 (simulated fills shown as settled during the raffle). |
| Orderbook and server | 5 | 4 | A-FLEX-2 (permitBatch path dead end-to-end), G-TS_FILLER-2/3/4/6 (soft cancels that do not stick, rate-limit drain). |
| Auction | 1 | 0 | CORE-FILLER-1.v3 (quotes bound to the bidding EOA, not the executor). |
| Docs | 0 | 15 | SECURITY.md, FEATURES.md, approval-surface, module-security-model, gasless-permit-relay drift (fixed in the docs group). |
| Tools / Makefile | 1 | 1 | MISC-MOD-6 (`modules-erc4626` in no make target; fixed, plus a CI matrix over every package), L-CENSUS-7 (no shapes rule for the lending-low classes; rules 14-16 added). |
| **Total** | **94** | **109** | |

---

## Remediation status

### Phases

| Phase | State | Evidence |
|---|---|---|
| A: core + lib fixes | **Done, merged** (`7e35e9c`, `fc0baa3`, integration `3e90bd7`) | core 912 passed / 2 skipped, `test-deployed` 914/914, invariants 26/26, lib 47/47; clean `size-check`: Settlement 24,223 / 24,576 (was 24,325 at the audited HEAD; collapsing `fillWithPermit` to one entry paid for the new floors), then **24,311 / 24,576** after the VAL-1 core rule (+88 B). |
| B: 12 component groups (sdk, app, validators, offchain, lend1-4, bridge, modules, solvers, periphery) | **Done, merged** (`a90ea18`..`3034d23`, integration `1949cc2`, `f1287da`) | Merge report: every profile in `ALL_PACKAGES` green, `modules-erc4626` 16/16, `test-ts` (sdk 268, orderbook 127, server 53, auction 101, app 42), `test-deployed` 914/914, `size-check` and `modules-check` pass. |
| Cross-component pass | **Committed** (`7569f87`, "fix: internal audit") | No structured per-item report. See [below](#cross-component-pass-7569f87). |
| Partials lane (the 23 `fixed_partial` + L-LIB-8) | **Done, merged** (`5389bf1`, `55cbfcc`, `7889c02`, `d49cc63`) | VAL-1 core rule, AGG-6 (`executeItemFill`, flash `PERMIT_ENVELOPE`), AGG-4, X-DIFF-REST-3 closed (sponsorship bound to the filler), L-CENSUS-8 (Teller/Fluid owner binding), X-ASM-3 (d), L-LIB-8 (Aave v2). |
| Docs group (SECURITY.md, FEATURES.md, docs/, tools, CI) | **Done** ("docs: 2026-09-30 audit doc leftovers") | The 17 docs issues fixed (MISC-MOD-6 Settlement-routed transfer/ERC-4626 flows, L-CENSUS-7 shapes rules 14–16 + comment stripping, docs-check layout offsets, CI matrix); the fixers' doc-update requests applied (skipped ones listed below). |
| Independent verification of every fix | **Not run** | Fixer statuses below are self-reported. |
| Fix-up round | **Not run** | |
| Final gate (full suite, clean size-check, gas baseline) | **Not run** | `.gas-snapshot` not regenerated; the last full-suite figures are the merge-B report's. `7569f87` changed core comments only. |

### Fixer statuses

The fixer reports contain 209 entries: **177 `fixed`, 23 `fixed_partial`, 8
`accepted`, 1 `cross_component`**. Three entries are not audit issues (VAL-4 is a
merged member of PRICE-8, `LENS-SIZE` is the enabling lens split, and one
`accepted` entry is a placeholder), so per issue: **175 fixed, 23 fixed_partial, 7
accepted, 1 cross_component, 17 with no fixer report** = 223.

"Fixed" means fixed in the paths the fixer owned. Fixers could not edit
`SECURITY.md`, `FEATURES.md`, `docs/` or the docs-site, and filed **129
doc-update requests** against them instead; apart from the four docs `7569f87`
touched (`position-sized-fills.md`, `quote-auctions.md`, `findings-ledger.md`,
`permit2-forked-source.md`) those requests are **unapplied**. They include two of
the report's P0 doc items: SECURITY.md M-8 must state that `MocMultiCollateralGuard.execute()`
is permissionless (RIF-1/RIF-2), and the SECURITY.md half of VAL-1.v4.

### `fixed_partial` (23)

| ID | Sev | Done | Remaining, and why |
|---|---|---|---|
| VAL-1 | med | On-chain guard in the three shipped invariants; lens (merge B) and SDK (`7569f87`) refuse the shape. | **Now fixed** (`7889c02`): the generic core rule landed (+88 B, Settlement 24,311 / 24,576). |
| PRICE-8 | low | `ChainlinkRead.checkSequencer`, optional uptime pair on the Chainlink validators. | Pegged-module sibling and SDK encoders were cross-component; both landed in `7569f87`. |
| VAL-2 | low | Predicate and tree leaves revert or propagate out-of-gas instead of reading false. | `MocPriceBandValidator` sibling and SDK doc were cross-component; landed in `7569f87`. |
| X-DIFF-REST-3 | low | LZ sponsored sends are whole-item only, per-send cap, increase/decrease API (**BREAKING** 3-arg approve). | **Now CLOSED** (`55cbfcc`): a sponsored spec must be a SETTLE item (`ISettlementModule.settle` receives the filler), and the filler must be `feePayer` or a `setSponsorFiller` agent; a sponsored MAKE item reverts `SponsoredSendNeedsSettle` (**BREAKING**). No core interface change was needed. |
| G-LENS_PARITY-1 | low | Lens funding cap reads the ERC-20 approval to Permit3. | `FundingPreflight.pullable` landed in `7569f87`. The Lista test `test_audit_L_ML_5_pullRepayReportsPermit3Book` was adjusted for it: a Permit3 book entry without an ERC-20 approval to Permit3 now reports 0. |
| L-CMT-3 | low | NatSpec: cancel/expiry/revoke do not consume a venue nonce; durable revokes named. | Venues offer no sender binding, so no contract fix. SDK nonce-burning revokes landed in `7569f87`; SECURITY.md text now written. |
| L-CENSUS-4 | low | Exactly and Silo README layouts rewritten. | aave-v3 / liquity-v2 README rows were cross-component; both READMEs changed later (`7569f87`, `de8df99`), not verified. |
| L-CV2-1.v3 | info | `FullFillGuard.requireDelivered` NatSpec corrected. | Comment sites in Comet/Dolomite/AaveV2/AaveV3Credit and shapes rule 9: landed in `7569f87`. |
| X-ASM-3 | info | Seed-sized blobs, dirty-address fuzz, batch-witness reference digest. | Sub-item (d) **now done** (`7889c02`): `Audit20260930PermitTakeDirty.t.sol` fuzzes dirty high bits in the raw-copied PermitTake words, and the fill settles exactly like the clean permit. |
| VAL-5 | info | NatSpec/README: the gated identity is Settlement's immediate `msg.sender`. | SDK warning landed in `7569f87`; FEATURES.md text now written. |
| L-CMT-4 | info | Teller Hypernative firewall registration documented. | **Accepted**: no pool-deposit fork test is added because no verified live V2/V3 pool is available and Hypernative registration is a deploy step; the functional mock test covers the module. |
| L-CMT-5 | info | Teller mock corrected, unit and mainnet-fork tests. | Comet/Morpho signature fork tests and Morpho negatives landed in `7569f87`; approval-surface.md citation fixed. |
| PRICE-10 | info | Quote typehash binds `prevFilled` (**BREAKING**). | Fill size and settlement address cannot be bound (no size in `IPriceModule`; staticcall sender differs between fill and preview): accepted. |
| G-BYTE_MAP-4 | info | `Full` documented as the tagged `0xB0DE0001` in owned headers. | MorphoBlue header, silo/lista/gearbox READMEs and SDK `encodeMode` landed in `7569f87`. |
| G-BYTE_MAP-8 | info | AaveV2 pre-fund and Comet byte maps. | River, Midnight pre-fund, DelegationHelper maps landed in `7569f87`; `docs/settlement-modules.md` descriptor text fixed: `(5 << 253) \| op << 244 \| token << 16 \| j`. |
| L-ML-9 | info | Durable Moolah/Morpho revokes documented. | SDK nonce burn landed in `7569f87`; SECURITY.md kill-switch text written. |
| L-CMT-7 | info | Morpho Blue doc drift fixed. | Comet/Teller headers landed in `7569f87`; approval-surface.md fixed (Teller deposit firewalled, Comet `allowBySig` wired, pre-fund needs no taker allowance). |
| L-CENSUS-8 | info | Midnight strict `balanceMode`; pull MorphoBlue partial repay. | Gearbox pre-fund `BadOp` landed in `7569f87`. **Now fixed** (`55cbfcc`): Teller repay binds `getLoanBorrower == maker` (`NotBorrower`), Fluid deposit/repay bind the factory `ownerOf == maker` (`NotPositionOwner`), `FluidRepayModule` tagged `Full` live-debt clamp (full-fill only), `FluidTakerModule` `_locked`. |
| AGG-4 | info | Route source placed inside the standing trust boundary. | Auction-side calldata guard landed in `7569f87`; word-aligned matching in `packages/auction/src/sources/guard.ts` (`5389bf1`). **Fixed**; stated limit: a presence check, bounded by the selector allowlist. |
| AGG-6 | info | Pull path funds every output token. | **Now fixed** (`5389bf1`): item orders via `AggregatorFillSolver.executeItemFill` / `onMatchRoute`; zero-inventory permit-witness first fills via every flash solver's `PERMIT_ENVELOPE`. Residual: `AggregatorFillSolver` cannot take a permit order's FIRST fill (a `fillWithPermit` callback overload would cost about 565 B of Settlement). Bytecode changed for `AggregatorFillSolver` and every flash solver: regenerate any pre-audit beta deployment record or address prediction. |
| PERIPH-9 | info | NativeSettler accepts fee-split and multi-output legs. | Binding the order to NativeSettler is a maker/SDK choice; SDK `nativeInOrder` landed in `7569f87`. |
| CORE-FILLER-5 | info | Lens `pinnedBump` / `previewFillInFlightPinned`. | `FillRecovery` landed in `7569f87`. |
| G-VENUE_B-9 | info | Silo/Exactly/Fluid NatSpec corrected. | Gearbox NatSpec landed in `7569f87`; the F19 ledger row and `module-security-model.md` I-10 now say `previewRedeem(balanceOf(user))` (the RAW position, not `maxWithdraw`). |

### `accepted` (7, plus one placeholder)

| ID | Sev | Reason |
|---|---|---|
| X-TOKENS-2 | low | Double-entry-point tokens on `matchSettle` / delta-verify: a dedup costs EIP-170 bytes; the loss is bounded to the matcher's own residual. Documented out of scope; SDK flags twin pairs (`7569f87`). |
| CENSUS-A-3 | low | Revoke/lockdown do not kill unapplied signed batches: Permit2 parity; an on-chain fix needs a per-owner epoch in the Permit3 typehash. SDK `buildRevokeAll` now requires and burns outstanding nonces (`7569f87`). |
| X-TOKENS-1 | low | Inbox credits the bridge-reported amount: arrival cannot be measured per delivery without breaking liveness. Admission rule documented (exact-transfer, non-rebasing tokens only). |
| BRIDGE-B-5 | low | Across WETH to an undeployed funnel arrives as ETH: no sound on-chain fix without breaking counterfactual addressing; no loss (owner can withdraw). Documented. |
| L-LIB-9 | info | `PreFundGuard.floorOf` assumes exact receipt; FoT funding tops up from residue or fails closed. Core stays asset-general. |
| PRICE-12 | info | OCO bracket legs cannot be CoW-matched or PostInputs-filled; the item-free shared-nonce bracket is the matchable form. |
| L-AAVE-3 | info | Isolated collateral not auto-enabled on Aave v3 < 3.7: needs a venue role the module cannot hold. SDK warning added (`7569f87`). |
| G-TS_FILLER-5_dup_guard | n/a | Placeholder entry in the SDK fixer report, not an issue. |

### `cross_component` (1)

L-LIB-8 (info), `positionOf` missing on venues with `Full` withdraws: landed in
`7569f87` for Aave v4, Lista (+native), Dolomite and Midnight, and in `7889c02` for
Aave v2 (`test_audit_L_LIB_8_aaveV2PositionOfAndPositionSizedFill`), pinned by
`test_audit_L_LIB_8_aaveV4PositionOfAndPositionSizedFill`,
`test_audit_L_LIB_8_dolomitePositionOfAndPositionSizedFill`,
`test_audit_L_LIB_8_listaTakerPositionOfAndPositionSizedFill`,
`test_audit_L_LIB_8_midnightCollateralPosition`. Compound v2 / Venus are excluded
on purpose (no accrual-aware view) and ERC-4626 is accepted (no per-request view).

### Cross-component pass (`7569f87`)

The fixers filed 73 cross-component requests. `7569f87` carries the pass that
answered them (130 files, +4,686/−284), with no per-item report, so the mapping
below is from the diff and its new tests, **not verified item by item**:

- **Lens** (`Audit20260930CrossLens.t.sol`): amount-aware carrier mirror
  (`test_audit_CORE_FILL_1_lensFlagsZeroPlaceholderBuyInput`), `previewFill`
  resolves the max sentinel and refuses a module delta above the request
  (`test_audit_CORE_FILL_4_previewResolvesMaxBeforeTheModule`,
  `test_audit_CORE_FILLER_2_previewRefusesModuleDeltaAboveRequest`), items to the
  EXECUTOR flagged (`test_audit_CORE_MATCH_4_itemToExecutorFlagged`), new
  `bumpFloorAdvised` (`test_audit_PERIPH_1_v3_bumpFloorAdvised`).
- **SDK, BREAKING**: `encodeFillUpTo` requires `minBumpBps`; `buildRevokeAll`
  requires outstanding permit nonces; `PriceQuote` gains `prevFilled` (fixture
  regenerated; `test_audit_QUOTE_TOOLING_sdkTypehashBindsPrevFilled`); block-clocked
  orders need `opts.headBlock`; `packOrder` refuses invariant-only consideration
  without a lifelong hard filler; `commitment` no longer tie-breaks. New
  `venueAuth.ts`, `lending.ts`, `native.ts`. Vitest: `packages/sdk/test/audit-2026-09-30-cross.test.ts`.
- **Modules**: `positionOf` (above); Gearbox pre-fund `BadOp`
  (`test_audit_L_CENSUS_8_unknownPreFundOpRefused`); `MorphoBlueTakerModule.proceedsAsset`
  (`test_audit_L_CMT_6_proceedsAssetPerOp`); `MocPriceBandValidator` reverts on a
  zero price or reversed band (`test_audit_VAL_2_zeroPriceRevertsNotFalse`);
  `ChainlinkPeggedPriceModule` sequencer feed and grace (+2 constructor args;
  `test_audit_PRICE_8_sequencerDownReverts`); real Comet and Morpho signature
  replays on forks (`test_audit_L_CMT_5_realCometAllowBySigLandedInFill`,
  `test_audit_L_CMT_5_realMorphoSigAuthLandedInFill`).
- **Solvers**: `FillRecovery` pinned recovery and sentinel refusal
  (`test_audit_CORE_FILLER_5_pinnedRecoveryExactForPriceModuleOrders`);
  GuardedMatchSolver swept floor and drained-anchor check
  (`test_audit_X_DIFF_CORE_1_v1_sweptFloorEnforced`).
- **Tooling**: `check-module-shapes.py` rules 9 (extended), 10-13 with a
  self-test (`tools/test-module-shapes.py`) in `make modules-check`; `test-ts` now
  runs auction and app; `size-check` gates `SettlementLensChecks` and
  `NativeSettler`; `modules-erc4626` added to `PACKAGES`.

Requests with **no evidence** in the tree at `7569f87` were later closed or
accepted: VAL-1's core rule (landed, `7889c02`), X-DIFF-REST-3 (closed without a core
interface change, `55cbfcc`), L-CENSUS-8 sub-items 3-5 (landed, `55cbfcc`) and the
doc halves of G-VENUE_B-9 (docs group). Still not done, by choice:
CORE-FILLER-1.v3's optional move of `executor` into the signed bid payload (the
`BidExecutor` declaration covers it), L-ED-5's optional per-seam test census rule,
and OPS-USDRIF-MAXSPENT (the operator tooling lives outside this repo; the SDK
encoders now require `maxSpent`).

### Open items

1. ~~Docs group, 17 issues~~ — **done**, see the phase table. MISC-MOD-6
   (`PermitTransferSettlementFlowTest`, `Erc4626SettlementFlowTest`), L-CENSUS-7
   (shapes rules 14–16, comment stripping, rule 13 keyed on shape; self-tests in
   `tools/test-module-shapes.py`), L-CENSUS-6 (HEAD census in
   [audit-2026-09-push-family.md](audit-2026-09-push-family.md)), L-LIB-6
   ([gasless-permit-relay.md](gasless-permit-relay.md) rewritten; `docs-check` now
   holds its `@N` offsets and the module READMEs' to the code), G-VENUE_B-8 (fork
   tests via L-LRG-5 / L-FSE-6 / L-AAVE-5, approval-surface "proven" row corrected),
   and the 14 doc-only items.
2. ~~The 129 doc-update requests~~ — applied against the current code (skipped
   requests are listed in the docs-group report).
3. **Independent verification** of every fix, including that each regression fails
   on the original source (today that claim is the fixer's own).
4. **Fix-up round** for whatever verification rejects.
5. **Final gate**: `make test-all`, `make test-ts`, `make test-deployed`,
   `make test-invariant`, a clean `size-check`, `modules-check`, `docs-check`, and a
   regenerated gas baseline (`make gas`). CI now runs all of these except the gas
   regeneration on every PR.
6. **Re-assess the nine goals** against the fixed tree; the verdicts above are for
   `56d1405`.

### Breaking changes landed

Order typehash and order wire format are unchanged; the golden order hash stands.
The full list, per surface, is SECURITY.md's
[2026-09-30 breaking-change section](../SECURITY.md#2026-09-30--whole-tree-audit-remediation).
Added by the partials lane: a no-output-leg invariant order needs a named
`exclusiveFiller` (VAL-1 core rule); a sponsored LZ send must be a SETTLE item
(`SponsoredSendNeedsSettle`, `FillerNotSponsor`, new `setSponsorFiller`); Teller
repay `NotBorrower` and Fluid deposit/repay `NotPositionOwner`; `FluidRepayModule`
mode word at 96 (tagged `Full`, untagged non-zero reverts `InvalidModeWord`) and
`totalAmount` at 128.
Breaking surfaces: Settlement ABI (`fillWithPermit` is one 6-arg entry,
`fillWithPermitTake` and the `takerDatas` `batchFill` gain `minBumpBps`, `FillCtx`
gains `minBump`; a fill module may not upsize the request); EVC permit tail and
sender; OCO claim blob; quote typehash (`prevFilled`); ProportionalSweep,
ERC20PermitTransfer, NFT, MocPriceBand, Lista broker borrow, Midnight, Exactly
fixed repay, Across/LZ/CCTP specs; `BridgedOrderInbox.rescue`; 7683 `originData`;
`UsdrifInventorySolver.executeFill*` (`maxSpent`); `AggregatorFillSolver` route
struct; `GuardedMatchSolver` constructor; SDK and orderbook APIs listed above.
Every changed module needs a new deployment.

---

## Limits of this audit

- **Uneven PoC evidence.** Only the 20 high and medium issues have PoCs. All lows
  and infos rest on static tracing plus one independent review; MISC-MOD-3 is only
  plausible. Goal 7 (matching) has no PoC at all.
- **Narrow mutation evidence.** The core 59/62 covers guard-removal mutants only,
  and 48 of those results were reused from an interrupted earlier attempt (14 were
  run fresh). The periphery figure is a pre-screened sample of 14, and the lens was
  rated weak. Neither mutation lens had a critic pass.
- **Completeness.** One completeness round (six gap lenses) ran of the two
  allowed. Variant hunts did not run for the two gap-lens mediums (G-TS_FILLER-1,
  G-VENUE_B-1) or for variants of variants; given how often siblings were missed,
  the 42 variants may not exhaust them.
- **Venue fidelity.** Several modules have no real-venue test and some mocks
  diverge from the venue; L-ML-1, L-ML-3 and L-CMT-1 were found exactly there. None
  of the 24 vendored venue and bridge interfaces was diffed against a deployed ABI.
  The external protocols (MoC, LayerZero, Across, CCTP, the lending venues) were
  not audited, only how the modules use them.
- **Off-chain and lens coverage.** The planned lenses excluded the ~17k lines of
  TypeScript; the gap lenses `G-TS_SIGN` and `G-TS_FILLER` read it afterwards.
  `SettlementLens` (1,881 lines, used on-chain by the 7683 settlers and
  `PositionFunnel`) was spot-checked plus the `G-LENS_PARITY` lens; no full
  revert-to-mirror table was built.
- **Not read**: deploy scripts beyond A-IMMUT's immutability review, the via-IR
  shipped bytecode of the periphery, and the RSKj gas schedule.
- **Five late findings.** A per-check limit dropped five info findings from
  `G-TS_SIGN`; they were reviewed by one reviewer on 2026-10-01 with no PoC.
- **Judgement calls.** Severities are reviewer judgements (AGG-1 reported medium,
  kept low; the A-FLEX lens and its critic disagreed). The 9 rejected candidates
  are listed in the raw report only.
- **Point in time and provenance.** A snapshot of `56d1405`. The raw report was
  rebuilt on 2026-10-01 from the workflow journals after the scratchpad copy was
  cleared; the goal sections and PoC sources are the original agent output.
- **Not independent.** Agents reviewed the tree's own code, docs and tests, and
  agents fixed it. Treat it as preparation for an external audit, not a substitute.
