# Reference bug bounties and live incidents — the post-deployment corpus

[`reference-audits.md`](reference-audits.md) is what auditors found *before*
deployment in this class of protocol. This note is the other distribution: what
whitehats and attackers found *after* deployment — paid bug-bounty disclosures and
live incidents — at the intent-settlement protocols we compare against and at the
lending venues our modules drive. The two corpora disagree about what matters, and
that disagreement is the reason to keep both:

- Audits skew toward design classes (C1 arbitrary calls, C5 maker-supplied price
  functions, C6 overfill). Bounties skew toward **mechanical** classes: a declared
  type that truncates a scaled number, a comparison across two denominations, a
  storage slot written and read at different offsets, an encoder and an
  interpreter that disagree about a flag, a value carried twice and bound once.
- Bounties are also where **periphery** shows up. Four of the incidents below are
  in a router, a resolver, a bundler front-end or an off-chain relayer — code the
  core audit never read — and one is a venue our modules sit on top of.

Same shape as the audit note: each entry is a **class**, with the source it comes
from, a verdict against this codebase with the file that carries it, and a ledger
of what we changed. Class keys are `B1…B14` so "that's a B6" is a complete review
comment alongside "that's a C4". The registry table at the end is the
de-duplication ledger: a program listed there has been searched; one listed as
"no public disclosures" has been searched and found closed.

**How this was built (2026-09-14).** Starting from the
[1inch Aqua H1 2026 report](https://hackenproof.com/blog/1inch-bug-bounty-report-h1-2026),
then every comparable and every venue we integrate: HackenProof and Immunefi
program pages and bug-fix reviews, Cantina bounty pages, protocol forums and
post-mortems, and the 0x Settler changelog (which cites its Immunefi report
numbers inline — the most useful single source after the 1inch report). Most
programs publish **nothing** per finding; the table records that too. Where a
vendor page blocks automated fetch, the entry says so and cites secondary coverage.

---

## The fourteen classes

### B1 — Declared type narrower than the scaled value it carries

**Source.** 1inch Aqua H1 2026, findings 2 & 3 (Low ×2, researchers Bz and
Xmanuel): `decayFactor` was declared `uint32` while the formula expected a 1e18
fixed-point number. The truncation was silent and total — every Dutch decay curve
was a flat line, and both `_dutchAuctionBalanceIn1D`/`Out1D` were non-functional.
Makers who thought they had posted time-weighted orders had posted static limit
orders "exposed to adverse selection for the order's entire lifetime". Fix:
[swap-vm#25](https://github.com/1inch/swap-vm/pull/25).

**Why it lives.** Nobody tests that a decay *moves*; unit tests assert the
end-points and both end-points were right.

**Verdict — REOPENED BY F29 (2026-09-14).** The original verdict ("there is no 1e18
quantity to truncate") was wrong: `ChainlinkTickFloorValidator.scale` is a
1e18-based fixed-point value that must also carry `10^(dOut − dIn − dFeed)`, which
is `0.0098` → **0** for WETH→USDC against an 8-decimal feed, so the validator
passes unconditionally (screening finding 1, PoC). The core auction is clean for
the reason below; the validator is the exception the class predicted.
Original core verdict: our clocks are also `uint32`
(`Order.timing` packs `decayStartTime | decayDuration | exclusivityEndTime`,
[DutchAuction.sol:25](../packages/core/src/settlement/DutchAuction.sol#L25)) but the
*price* is never a scaled factor: `resolveBump` returns a `bumpBps ∈ [0, 10000]`
and every leg maps it through its own signed `start`/`end` (`Pricing.outputAt`).
There is no 1e18 quantity to truncate. The decay itself is asserted to move —
`modules-transfer`'s `test_nativeOut_dutchLeg_unwrapsExactlyTheDelivery` fills
halfway through a decay and requires `end < received < start`, and the core auction
suite does the same. **Rule:** any new time- or size-dependent price path gets a
test that fills at *two* points and asserts the two results differ.

### B2 — A comparison across two denominations

**Source.** 1inch Aqua H1 2026, finding 6 (Low, dantehrani, out of scope but
paid): the TWAP cap compared `amountIn` against available `amountOut` — two tokens
— so a taker could drain the entire TWAP stream in one transaction. Finding 8
(Low, Jugger63): `BaseFeeAdjuster`'s ExactIn gas compensation mixed gas units
against token amounts, "orders of magnitude off", dead code in production. Fixes:
[swap-vm#105](https://github.com/1inch/swap-vm/pull/105),
[swap-vm#70](https://github.com/1inch/swap-vm/pull/70).

**Verdict — CLOSED for the TWAP; one open axis in the gas path.** Our TWAP is a
fill *module* that gates the fill delta in anchor units only:
`fillTotal / minFillAnchor` parts, released by `decayDuration / parts`
([TwapFillModule.sol:21](../packages/modules/fill/src/TwapFillModule.sol#L21)); it
never sees an output amount, so the two denominations cannot meet. The priority
auction's `baselinePriorityFeeWei` is wei and the bump it produces is bps
([DutchAuction.sol:218](../packages/core/src/settlement/DutchAuction.sol#L218)) —
the conversion is one expression, documented. **Where the class still bites us:**
F28's own finding 2 was exactly a B2 — `NativeUnwrapModule` compared a pro-rated
signed constant against an auction-priced delivery of the same token (same unit,
different *denominator*). The `ExactlyPreFundModule._scaledFace` lead (delivered
amount over signed total used as a fill fraction) is the same shape and is still
open. **Rule:** every `min(a, b)`, `a < b` or `a * x / y` between two quantities
names both units in a comment; `docs/edge-case-matrix.md` gets a row per new one.

### B3 — Storage written at one offset and read at another

**Source.** 1inch Aqua H1 2026, finding 7 (Low, Jugger63): `Decay._decayXD` had an
offset-direction bug — decay state was written to one storage slot and read from a
different one, so every calculation ran on stale or zero data, "nearly invisible
in unit tests". Fix: [swap-vm#70](https://github.com/1inch/swap-vm/pull/70).

**Verdict — CLOSED by construction, pinned by tests.** The settlement keeps one
storage word per order (`filled[orderHash]`) and one packed `timing` word; every
other offset in the system is a *calldata* layout (`PackedArrays`: LegIn
20|32|32, LegOut +20, Item 1|20|32|20|2) whose masks are pinned by the
`PackedArrays` unit suite, by the SDK's shape-pinning tests against
`GOLDEN_ORDER_HASH` ([canonicalOrder.ts:74](../packages/sdk/test/canonicalOrder.ts#L74)),
and — for the bit-fields inside `timing`/`params` and the descriptor words — by
the shared encoding vectors (`EncodingGolden.t.sol`, see B4).
A hand-rolled read at the wrong offset changes the golden hash. The module data
blobs are the exposed surface — every `readBalanceMode(data, N)` /
`requireFullFillFromData(data, N)` offset is a literal — and the 2026-09 audits
found two wrong ones (F26/A-2). ⚠ The earlier version of this row said those were
"checked by `check-module-shapes.py`"; the tool checks pins, floors and reject
branches, NOT literal offsets against the header byte map, and F29 found
`ExactlyRepayModule`'s header placing the permit at the offset the fixed branch
reads as `totalAmount` (screening finding 2, PoC). **Rule:** a new trailing-word
offset in a module blob is added to the module's byte map comment in the same
commit — and the shapes tool needs the rule that extracts every `(data, N)`
literal and asserts it appears in that map.

### B4 — Encoder and interpreter disagree about a flag

**Source.** 1inch Aqua H1 2026, finding 5 — the only High of the half (Z3rco): the
SDK encoded `MakerTraits` hook flags one way and SwapVM interpreted them another,
so a taker could craft a hook encoding that "redirected or outright stole maker
funds during an otherwise normal-looking swap", with a PoC of real loss. Fix was in
the **SDK**: [sdks#32](https://github.com/1inch/sdks/pull/32). "In a programmable
swap engine, the boundary between configuration and code is thin — every
serialization boundary is a potential attack surface."

**Verdict — CLOSED, and we have been bitten by the mild form.** The SDK was found
two migrations behind the contract encoding in 2026-08 (wrong hash *and* wrong
selector; see `sdk-packed-order-sync`), which is this class without the theft.
Two pins now. The golden hash: the SDK's `packOrder` output must hash to the
contract's `OrderHash` for the canonical order. And, since 2026-09-14, the
**encoding vectors**: `packages/sdk/test/fixtures/encoding-vectors.json` is
produced by the SDK's encoders (`encodingGolden.test.ts` fails if they drift)
and consumed by `packages/core/test/EncodingGolden.t.sol`, which hands each word
to the code that interprets it in production — the three funding-descriptor
shapes through `PreFundGuard`, proportional markers through `Proportional`,
every `timing` flag and `params` field through the `DutchAuction` accessors, the
DNF blob through a deployed `ConditionTreeValidator`, the OCO item/validator
blobs through `OcoGroupModule`, the quote takerData head through
`CosignedQuotePriceModule.bump`. One fixture, two consumers, so there is no
constant to update on two schedules; flipping one bit fails both suites
(`test_timing_clocksAndFlags`). **What is not pinned:** the SDK ships no
builders for module `data` blobs (a `BalanceMode`, a `DustAction`, an `Op`
word), so those are interpreted by the module alone against its byte-map
comment and `check-module-shapes.py`. The day a builder is added, it gets a
vector here first.

### B5 — Sign error in a stateful update, invisible in a single step

**Source.** 1inch Aqua H1 2026, finding 1 (Medium, nathan47): the concentrated-
liquidity scale update was inverted — after a swap the range moved the wrong way,
"steadily breaking the AMM's core invariant with every trade" and opening a
systematic arbitrage against maker positions. Fix rewrote the strategy in a
stateless model ([swap-vm#82](https://github.com/1inch/swap-vm/pull/82)).

**Verdict — NOT APPLICABLE as stated, one analogue open.** We hold no per-order
strategy state that a fill updates: pricing is a pure function of
`(order, filled, now, bump)`. The nearest analogue is `RangePriceModule`, which
prices on `prevFilled` rather than integrating over the slice — not a sign error
but a *point sample* of a monotone ladder, so a START>END band clears a whole
order at the floor in one fill (F28 lead, open, bounded by the signed `end`).
1inch's remedy — make the thing stateless — is already our shape.

### B6 — One value carried in two places and bound in one

**Source.** 0x Settler, Immunefi report 88903 (fixed 2026-09-03): the
`UNISWAPV3_VIP` actions carried the sell token both as `path[0]` and inside the
Permit2 `permit`; only one was authorised. Fix removed the sell token from `path`
— "this token is now read from `permit`"
([CHANGELOG](https://github.com/0xProject/0x-settler/blob/master/CHANGELOG.md)).
Same family: the Exactly `DebtManager` exploit of 2023-08-18 (~$7.3M), where
`leverage()` took a caller-supplied `market` and called `market.safePermit()` on it
— a fake market satisfied the permit check and re-entered
([Halborn](https://www.halborn.com/blog/post/explained-the-exactly-protocol-hack-august-2023)).

**Verdict — CLOSED on the core seam, and it is our most-repeated finding.** F27/H-1
bound the funding leg's token to the descriptor (`Base._forSlice` checks
`legToken == desc[16:176)` and `PreFundGuard.floorOf` checks the module's own
decoded asset against the same word); `TAKE_FOR` sizes the funding leg from the
signed `legsOut` reference so the amount exists once. F28 closed two more: the
Liquity/River repay legs measured a `data`-named token while the venue burned the
real one (now pinned to `registry.boldToken()` / `tm.debtToken()`), and the
Dolomite `Withdraw`/`Borrow` ops built the same venue action from two refs. **Still
open:** the PULL and BALANCE funding shapes carry the token in `data` and in the
leg without a cross-check (self-harm only; F28 lead). **Rule:** if a quantity or
address appears in the order *and* in a module blob, one of them is derived from
the other or the module reverts on mismatch — never both trusted.

### B7 — A proportional argument with no upper bound

**Source.** 0x Settler, Immunefi report 89191 (fixed 2026-09-03): the BalancerV3
actions accepted `bps > 10_000` (now `ppm > 1_000_000`). Related design note from
the same changelog: `POSITIVE_SLIPPAGE` gained a `surplusPpm` argument controlling
"the proportion of surplus transferred" — the same mechanic as our
`SurplusPolicy`, arriving in the same month.

**Verdict — CLOSED.** `overrideBps > BPS` reverts in `OrderGates`
([OrderGates.sol:121](../packages/core/src/settlement/OrderGates.sol#L121)) and the
lens repeats it; `makerPpm + protocolPpm + originatorPpm ≤ PPM` is checked before
any token moves in `AggregatorFillSolver._plan`; `Proportional` markers are
`bps ≤ BPS` by construction of the marker word; `FeeTransferModule` and the
relayer-fee legs are absolute amounts. **Rule:** a new bps/ppm field gets its
upper-bound revert in the same function that decodes it, and a lens rule.

### B8 — Signature malleability on a meta-transaction path

**Source.** 0x Settler, Immunefi report 78645 (unreleased fix): a `metaTx`
malleability bug in `CrossChainReceiverFactory` (contract not yet deployed, no
funds at risk). Also Threshold tBTC (Immunefi bug-fix review, $50k, 2023): Bitcoin
transaction malleability combined with an SPV verifier.

**Verdict — PRESENT BY CONSTRUCTION, BENIGN, PINNED.** `reference-audits.md` S1:
`SignatureVerification.tryRecoverSigner` accepts both 65- and 64-byte encodings
and applies no lower-`s` check, so one authorisation has four byte forms; harmless
because replay is bound by `filled[orderHash]` and the book is keyed by hash,
never by signature (`test_malleability_fourEncodings_stillOneFill`). The 0x entry
is the reminder of where this *would* become a bug: any consumer that treats a
signature as an identity — a meta-tx dedup cache, a relayer "seen" set. The
orderbook server keys by `orderHash`; keep it so.

### B9 — A callback with no caller check

**Source.** Velora/ParaSwap Augustus v6, 2024-03-20: `uniswapV3SwapCallback()`
"didn't implement a proper caller check in some cases", so an attacker deployed a
fake pool and called it on behalf of any user who had approved Augustus v6 — 386
addresses affected, ~$24k–$123k drained by MEV bots before a white-hat rescue
([post-mortem](https://veloradex.medium.com/post-mortem-augustus-v6-vulnerability-of-march-20th-2024-5df663a4bf01)).
Also Uniswap Universal Router (Dedaub, $40k, 2022-12): a recipient callback
(`onERC721Received`) re-entered the router and swept balances the router held
mid-transaction ([disclosure](https://dedaub.com/blog/uniswap-reentrancy/)).

**Verdict — CLOSED, and it is a shapes-checker rule.** Every callback in the tree
pins its caller *and* something the caller cannot forge: `AggregatorFillSolver.onFill`
requires `msg.sender == EXECUTOR`, the arming flag, and the router allowlist (the
allowlist is the one that authorises — `permissionless-arming-antipattern`);
`BaseFlashSolver` requires `msg.sender == _armedProvider`
([BaseFlashSolver.sol:129](../packages/solvers/src/base/BaseFlashSolver.sol#L129));
`MorphoBlue*.onMorphoRepay` requires `msg.sender == morpho` and is reachable only
from the module's own `repay`; `MidnightLoopCallback` pins its receiver. On the
settlement side the callback runs through `SolverCallbackExecutor`, a trampoline
with no allowances (C1). The Universal Router lesson — "the router should not
hold any balances between transactions, or these can be emptied by anyone" — is
our F19 floor discipline: every module pays out `balance − floor`, never a raw
balance (`check-module-shapes.py` rule 8).

### B10 — Stale approvals to a superseded contract

**Source.** Dolomite, 2024-03-20 (~$1.8M, 187 victims): a 2019 contract, spun down
in 2020, still held user approvals; its `callFunction` arbitrary-call path was
guarded by `noEntry`, which was bypassed via `SoloMargin.call`
([post-mortem](https://medium.com/dolomite-official/legacy-smart-contract-vulnerability-post-mortem-analysis-931d7b555269),
[Cointelegraph](https://cointelegraph.com/news/old-dolomite-exchange-contract-suffers-1-8-million-loss-from-approval-exploit)).
Also 1inch Fusion v1, 2025-03-05 (~$5M): resolvers that never removed the obsolete
v1 settlement path were drained through it
([1inch](https://blog.1inch.com/vulnerability-discovered-in-resolver-contract/);
mechanism in `reference-audits.md` C2).

**Verdict — MITIGATED; the residual risk is ours to operate.** Makers approve one
hub (Permit3) and grant it per-`(spender, module, keccak(data))`; `lockdownAll`,
`lockdown` and `lockdownTakers` exist for the maker's side
([SignedPermits.sol:134](../packages/core/src/permit3/SignedPermits.sol#L134)).
Module singletons hold no standing approvals to venues (every `forceApprove` is
scoped and cleared — A-3, seventh site closed in F28). What we cannot close in
code: a *redeployed* Settlement or module is a new spender, and the old one keeps
whatever grants it had until makers revoke. **Rule:** a deployment migration
ships with a lens/SDK `lockdown` prompt for the superseded spender, and the
deterministic-deployment doc records superseded addresses.

### B11 — Donation-inflated venue accounting

**Source.** Silo Finance (Immunefi bug-fix review, $100k USDC, 2023-04-28): a
market with zero deposits could have its utilisation pushed past 100% by a
donation, inflating the interest rate and the attacker's deposit value; ~$3M at
risk ([review](https://immunefi.com/blog/bug-fix-reviews/silo-finance-logic-error/)).
Venus vTHE, 2026-03 (~$5M): `getCashPrior()` reads live `balanceOf`, so a direct
transfer to the vToken inflated the exchange rate 3.81× without passing the
supply-cap check in `mint()` ([QuillAudits](https://www.quillaudits.com/blog/hack-analysis/venus-5m-exploit)).
Euler v1, 2023-03-13 (~$197M): `donateToReserves` had no debt check, so a
self-created underwater position was self-liquidated at the bonus
([Swivel post-mortem](https://swivel.substack.com/p/post-mortem-euler-liquidation-vulnerability)).

**Verdict — VENUE-SIDE; our exposure is the read, and it is bounded.** We never
price by a venue's exchange rate: input legs are sized by the signed order and
position-sized fills read the *user's* position (`IPositionSource`), clamp to the
signed cap and refuse above the filler's ceiling. The Compound-v2/Venus modules
use the exchange rate only to size a cToken pull for an Exact withdraw, and
`redeemUnderlying` reverts if the rate lied in the venue's favour; a rate inflated
in the *maker's* favour delivers more, which the `min(received, amount)` cap
returns to the maker. The exposure we *do* carry is the maker's: a maker-chosen
venue that is drainable drains the maker's position through no path of ours.
That is the `module-security-model.md` trust boundary [A1], restated here so it
is not mistaken for a gap.

### B12 — A ledger keyed too loosely across a trust boundary

**Source.** Across (iosiro, $90k, 2022-08): off-chain relayer and dataworker
clients indexed the same deposits by *different* keys, so a deposit could be
filled twice ([disclosure](https://www.iosiro.com/blog/high-risk-bug-disclosure-across-bridge-double-spend)).
Across Solana relayer, 2026-07-17 (~$4.5M relayer capital, no user loss): the
off-chain client did not check the 8-byte Anchor event discriminator, so a
wrapper program's forged `FundsDeposited` payloads were relayed — 1,627 forged
deposits across 18 chains, 581 filled before the origin was disabled
([coverage](https://en.cryptonomist.ch/2026/07/24/across-solana-relayer-attack/)).

**Verdict — WE HAD ONE; CLOSED IN F28.** `BridgedOrderInbox` keyed its refund
beneficiary and fallback expiry to whichever bridge delivery for an order hash
landed *first* — a 1-wei front-credit made its author the refund recipient of the
victim's escrow (PoC). Every later credit must now carry the pinned beneficiary and
expiry is the minimum. The on-chain half was always right (`fillRelay`-style:
`credited ≥ anchor` and Settlement's own `filled ≤ anchor` cap); the identity of
the record was the gap, exactly as Across's on-chain hash was right and its
off-chain index was not. The Solana incident is the reminder for
`orderbook-server` and the lens: an event is data until its emitter is verified.

### B13 — The front-end approves the wrong contract

**Source.** Morpho App, 2025-04-10 (~$2.6M intercepted by c0ffeebabe.eth,
returned): an SDK update sent token approvals to `Bundler3` itself instead of to
its adapters; adapters restrict calls by the bundle's initiator, the bundler does
not ([Morpho](https://morpho.org/blog/morpho-app-incident-april-10-2025/)).

**Verdict — CLOSED BY THE SPENDER-KEYED BOOK, with a documented footgun.** Permit3's
taker book is keyed by `(user, spender, module, keccak(data))` and every pre-fund
module pins `spender == settlement`, so an approval granted to the wrong spender
authorises nothing (F27/C-1). The remaining B13 surface is the *token* allowance:
`approveToken(settlement, token, …)` is the one approval a maker must make, and
the SDK is the thing that names `settlement`. `PositionFunnel.enableToken`
granting `uint160.max` to Settlement permissionlessly (F28 lead) is the same
class one layer down — safe only because every Settlement pull is signature- or
fill-gated. **Rule:** the SDK's approval targets are constants imported from the
deployment manifest, never derived; the funnel grant stays scoped.

### B14 — Under-priced or gas-bounded findings are still findings

**Source.** Compound Comet Base WETH, 2023-11 (brrito): a vulnerability in
`withdraw`/`transfer` that would have cost $5–10B in gas to steal $1M; patched,
disclosed on the forum, bounty at the top of the $150k scale
([forum](https://www.comp.xyz/t/comet-vulnerability-disclosure-patched/4854)).
1inch's hash-collision global-lock DoS (Aqua finding 4, Low): two makers' strategy
hashes colliding would trip the global reentrancy lock and halt atomic routing —
"no funds stolen, just a hard stop". LayerZero's `lzCompose` brick (Medium after
downgrade: a manual force-through existed).

**Verdict — OUR TRIAGE MATCHES.** The F28 report demoted two raw findings for the
same reasons (ERC4626 dust-fill unwind: grief, no profit; RangePriceModule:
bounded by the signed floor) and **fixed both anyway** — a class that lives only
in a "not profitable today" note is the next sibling-miss. The global
`_locked` flag is not hash-keyed, so the 1inch collision has no analogue; the
`Batch._openGated` proportional-anchor grief (a 1-wei transfer reverts a whole
netted plan) is our open B14.

---

## What the bounty corpus says that the audit corpus does not

1. **The High was in the SDK.** 1inch's only High of the half was an encoder /
   interpreter mismatch fixed in TypeScript. Our golden-hash pin and the
   descriptor-bit mirror in `types.ts` are the controls; a module-blob builder
   is the gap.
2. **Three of nine 1inch findings were units or offsets** (B1–B3). None of the
   fifteen audit classes is about units. F28's finding 2 was a B2. The
   dimensional-analysis pass has not been run over the module tree.
3. **Four incidents were periphery** (router, resolver, bundler front-end,
   relayer). Our periphery — `SettlementLens`, `orderbook-server`, the SDK — has
   never been through a lens run (`audit-runs.md`).
4. **Disclosure is rare.** Of the programs searched, only 1inch (HackenProof
   report), 0x (changelog citations), Compound (forum), Silo and Threshold
   (Immunefi bug-fix reviews) and Uniswap (researcher write-up) publish per-finding
   detail. Aave, Morpho, Euler, Pendle, CoW, Bebop, Lista, Gearbox, Fluid, Teller
   publish scope and payout ceilings only. A future round should re-check the
   0x changelog and the HackenProof blog first — they are the two sources that
   accrete.

---

## Registry

The de-duplication ledger. **Check before starting a research round.** "No
public disclosures" means the program page, the platform's bug-fix reviews and a
web search were checked on the date given and nothing per-finding was published.

| Protocol · component | Platform · scope | Disclosed findings (date · severity · payout) | Class | Verdict here | Checked |
| --- | --- | --- | --- | --- | --- |
| **1inch Aqua / SwapVM** | HackenProof, up to $100k; audited by OZ, Hexens, Decurity | [H1 2026 report](https://hackenproof.com/blog/1inch-bug-bounty-report-h1-2026): 472 reports / 217 researchers / 9 paid (1 High, 1 Medium, 7 Low). F1 inverted CL scale (M); F2–3 `uint32` decayFactor + dead Dutch balance ops (L×2); F4 strategy-hash collision → global lock (L); F5 MakerTraits hook-flag mismatch, fund redirection, PoC (H, SDK fix); F6 TWAP `amountIn` vs `amountOut` (L, out of scope, paid); F7 `_decayXD` slot offset (L); F8 gas-vs-token units in fee adjuster (L) | B5, B1, B14, B4, B2, B3, B2 | see classes | 2026-09-14 |
| 1inch Smart Contract / Wallet / Web / Business / Infra | HackenProof | H1 2026: 267/85/68/111/52 reports, 3/6/1/9/4 paid — counts only, no per-finding detail ([1inch blog](https://1inch.com/blog/post/1inch-releases-a-biannual-bug-bounty-report)) | — | — | 2026-09-14 |
| 1inch Fusion v1 resolver (incident) | — | 2025-03-05, ~$5M: obsolete v1 settlement path in resolver contracts, Yul calldata corruption ([1inch](https://blog.1inch.com/vulnerability-discovered-in-resolver-contract/); Decurity/Halborn in `reference-audits.md`) | C2, B10 | C2 closed (bounds proofs); B10 operational | 2026-09-14 |
| **0x Settler** | Immunefi, up to $1M (min $100k critical) | [CHANGELOG](https://github.com/0xProject/0x-settler/blob/master/CHANGELOG.md): #88903 sell token in `path[0]` AND `permit` → read from permit only (2026-09-03, breaking); #89191 BalancerV3 `bps > 10_000` accepted (2026-09-03); #78645 `metaTx` malleability in undeployed `CrossChainReceiverFactory`; Nethermind-reported short-actions revert + slippage checks; design: `POSITIVE_SLIPPAGE` gains `surplusPpm` | B6, B7, B8 | B6 closed on core seam, PULL/BALANCE shapes open; B7 closed; B8 benign-pinned | 2026-09-14 |
| Uniswap Universal Router / Permit2 | Uniswap Labs (boosted $3M, 2022); now Cantina up to $15.5M (v4) | Dedaub 2022-12: recipient-callback reentrancy sweeps router balance (High impact / low likelihood, $40k, CVE-2022-48216) — "the only report Uniswap acted upon" ([Dedaub](https://dedaub.com/blog/uniswap-reentrancy/)). v4 competition + bounty: no criticals ([Uniswap](https://blog.uniswap.org/v4-bug-bounty)). UniswapX: no public per-finding disclosures | B9, C15 | closed (floor discipline, trampoline) | 2026-09-14 |
| CoW Protocol | Immunefi, up to $1M | No public per-finding disclosures; the 2023-02 SwapGuard incident is in `reference-audits.md` (C1) | — | — | 2026-09-14 |
| Velora / ParaSwap Augustus v6 (incident) | — | 2024-03-20: `uniswapV3SwapCallback` without caller check in some paths; fake pool drains approvers; 386 addresses, ~$24k–$123k, white-hat rescue ([post-mortem](https://veloradex.medium.com/post-mortem-augustus-v6-vulnerability-of-march-20th-2024-5df663a4bf01)) | B9 | closed | 2026-09-14 |
| Bebop | (see audits index) | No public bounty disclosures | — | — | 2026-09-14 |
| **Across** (bridge module dependency) | Immunefi | iosiro 2022-08, $90k: off-chain deposit/fill index mismatch → double fill ([iosiro](https://www.iosiro.com/blog/high-risk-bug-disclosure-across-bridge-double-spend)); `speedUpDeposit` extra-relay issue (remediated client-side); 2026-07-17 Solana relayer: missing Anchor discriminator check, 1,627 forged deposits, ~$4.5M relayer capital, no user loss | B12 | our B12 closed in F28 (`BridgedOrderInbox` beneficiary pin) | 2026-09-14 |
| **LayerZero** (bridge module dependency) | Immunefi, up to $15M; ~$1M paid to date | `lzCompose` brick downgraded to Medium (manual force-through exists); a rejected report by Sujith Somraaj; no per-finding technical write-ups from the program ([docs](https://docs.layerzero.network/community/bug-bounty-support)) | B14 | our `lzCompose` never reverts on business logic (orphan + rescue) | 2026-09-14 |
| **Aave** v2/v3/v4 | Immunefi, $1M → proposed $5M (v3) / $2.5M (v4) | No public per-finding disclosures | — | — | 2026-09-14 |
| **Compound** v2/v3 | Immunefi $1M (2024→); forum before | Comet Base WETH 2023-11 (brrito): `withdraw`/`transfer` theft path, gas cost 5,000–10,000× the take, patched, top-of-scale bounty proposed ([forum](https://www.comp.xyz/t/comet-vulnerability-disclosure-patched/4854)); OZ follow-up not located | B14 | triage matches | 2026-09-14 |
| **Venus** (incident) | no active platform program at the time | 2026-03 vTHE, ~$5M: direct-transfer exchange-rate inflation bypasses supply cap; borrow–pump–donate loop ([QuillAudits](https://www.quillaudits.com/blog/hack-analysis/venus-5m-exploit)) | B11 | venue-side; our read bounded | 2026-09-14 |
| **Silo** v1 (bounty) | Immunefi | 2023-04-28, kankodu, $100k USDC: zero-deposit market + donation → utilisation >100% → inflated rate → over-borrow, ~$3M at risk ([review](https://immunefi.com/blog/bug-fix-reviews/silo-finance-logic-error/)) | B11 | venue-side | 2026-09-14 |
| **Euler** v1 (incident) / v2 | v2: Cantina, $1M → $5M → $7.5M | v1 2023-03-13, ~$197M: `donateToReserves` without debt check + liquidation discount ([Swivel](https://swivel.substack.com/p/post-mortem-euler-liquidation-vulnerability)); v2: no public per-finding disclosures | B11 | venue-side; EVC batch analogue in `reference-audits.md` | 2026-09-14 |
| **Morpho** Blue / MetaMorpho / Bundler | Immunefi + Cantina, $2.5M | App incident 2025-04-10: SDK approved `Bundler3` instead of adapters, one bundle intercepted (~$2.6M) by a white-hat bot and returned ([Morpho](https://morpho.org/blog/morpho-app-incident-april-10-2025/)); contracts unaffected; no contract-level disclosures | B13 | closed (spender-keyed book) | 2026-09-14 |
| **Exactly** (incident) | Immunefi | 2023-08-18, ~$7.3M: `DebtManager.leverage()` trusts caller-supplied `market`; fake market passes `safePermit`, re-enters `crossDeleverage` ([Halborn](https://www.halborn.com/blog/post/explained-the-exactly-protocol-hack-august-2023)) | B6, C1 | closed (root-derived venues where a root exists; `module-security-model.md`) | 2026-09-14 |
| **Dolomite** (incident) | — | 2024-03-20, ~$1.8M / 187 victims: 2019 contract, stale approvals, `callFunction` reentrancy guard bypassed via `SoloMargin.call` ([post-mortem](https://medium.com/dolomite-official/legacy-smart-contract-vulnerability-post-mortem-analysis-931d7b555269)) | B10, C1 | B10 operational | 2026-09-14 |
| **Liquity** v2 (incident) | Hats Finance | 2025-02-12: Stability Pool bug 3 weeks after launch, ~$30M outflows, full redeploy (relaunched 2025-05); root cause **never published** ([Defiant](https://thedefiant.io/news/defi/liquity-protocol-suffers-usd30-million-of-outflows-after-disclosing-v2-bug)) | — | untriageable; note the registry-rooted `boldToken()` pin is against the *relaunched* registry `0xf949…6684` | 2026-09-14 |
| **Fluid / Instadapp** | Immunefi up to $500k; Hats proposal | No per-finding disclosures. 2026-03 Resolv contagion: >$10M bad debt from a hard-coded wstUSR oracle ([BlockBeats/Defiant](https://m.theblockbeats.info/en/news/61670)) — an oracle class, not a Fluid bug | — | our pricing modules carry staleness checks (`ChainlinkPriceValidators`, `MocPriceBandValidator`) | 2026-09-14 |
| Pendle | Cantina, up to $1M (min $100k critical) | No public per-finding disclosures | — | — | 2026-09-14 |
| Gearbox | Immunefi (2022, $150k) | No public per-finding disclosures | — | — | 2026-09-14 |
| Lista DAO | Immunefi (min $1k/severity, paid by team) | No public per-finding disclosures | — | — | 2026-09-14 |
| Teller | — | No program or disclosures located | — | — | 2026-09-14 |
| Threshold tBTC | Immunefi | 2023-08-20, Kayaba, $50k T: Bitcoin tx malleability × SPV verifier ([review](https://immunefi.com/blog/bug-fix-reviews/threshold-transaction-malleability/)) | B8 | benign-pinned | 2026-09-14 |
| Immunefi bug-fix review index | — | [Bug Fix Reviews](https://immunefi.com/blog/bug-fix-reviews/) (2 pages, 2023–2024: Raydium, Sky, Alchemix, Threshold, The Graph, Stacks, competitions) and the [Top 10](https://immunefi.com/immunefi-top-10/) (V01 input validation, V02 incorrect calculation, V06 rounding lead) — read for class coverage; no intent-settlement entries | — | — | 2026-09-14 |

---

## Ledger

| # | Date | Class | What we changed |
| --- | --- | --- | --- |
| BB-1 | 2026-09-14 · reopened and **closed again** (rows keyed by the whole commitment) | B12 | `BridgedOrderInbox._credit` pins the beneficiary on every credit; expiry = min (F28 finding 1). F29 (same day): the pin closed the theft and left the first-writer's ownership of `commits[H]` — a dust credit + `settle(H)` at `expiry = 0` makes the hash terminal; a dust credit in another enabled token pins `k.token`. Needs the row keyed by `(orderHash, beneficiary, token)` with non-terminal settle and an order-deadline refund path |
| BB-2 | 2026-09-14 | B2 | `NativeUnwrapModule` sized from the delivery ledger, not a signed constant (F28 finding 2) |
| BB-3 | 2026-09-14 | B6 | Liquity/River repay tokens pinned to the venue root; Dolomite Exact withdraw guarded (F28 findings 3, 6) |
| BB-4 | 2026-09-14 | B7 | *No change* — bounds already present; recorded as the check to keep |
| BB-5 | 2026-09-14 | B14 | ERC4626 dust-fill unwind and the five Full-mode bounds fixed although "not profitable today" |
| BB-6 | open | B2 | `ExactlyPreFundModule._scaledFace` delivered/total as fill fraction (numbers in the F29 write-up) |
| BB-7 | open | B6 | PULL/BALANCE funding shapes: token in `data` vs leg not cross-checked (self-harm) |
| BB-8 | 2026-09-14 | B4, B3 | **Cross-language encoding vectors.** `packages/sdk/test/fixtures/encoding-vectors.json` is written by `encodingGolden.test.ts` (the SDK must reproduce it byte-for-byte) and read by `packages/core/test/EncodingGolden.t.sol`, which runs every vector through the real interpreter: `PreFundGuard` for the three descriptor shapes, `Proportional`, the `DutchAuction` accessors for `timing`/`params`, a deployed `ConditionTreeValidator`, `OcoGroupModule`, `CosignedQuotePriceModule`. One fixture, two consumers; a one-bit drift fails both sides (verified). What it does NOT cover: the SDK ships no module-`data` builders, so those blobs have no encoder to pin — the per-module byte maps + `check-module-shapes.py` remain the control there |
| BB-9 | 2026-09-14 (netted path) | B14 | proportional-anchor 1-wei donation grief — netted path now honours the `type(uint256).max` sentinel; plain entries stay ceiling-semantics by documented design (`fillUpTo` is the route) |
| BB-10 | 2026-09-14 | — | Periphery read by F29: six defects (P1–P6 in the screening write-up) and eight lens/SDK leads — the corpus was right about where the next one was |
| BB-11 | 2026-09-14 | B1 | `ChainlinkTickFloorValidator.scale` sub-integer → 0 → validator passes unconditionally (F29 finding 1, PoC) |
| BB-12 | 2026-09-14 | B3 | `ExactlyRepayModule` header/reader offset drift on the fixed branch (F29 finding 2, PoC); shapes tool needs an offset-vs-header rule |
| BB-13 | 2026-09-14 | B6 | `OcoGroupModule` item nonce unbound to `order.nonce`; SDK `patchOrder` copies items (F29 finding 3, PoC) |
| BB-14 | 2026-09-14 | B11 | `DolomiteOperatorModule._batch` close lacks the `WouldBorrow` read the Exact path got (F28 finding-3 sibling) |
| BB-15 | 2026-09-14 | B14 | stale nomination permit revokes a live direct delegate (`setOrderSignerWithSig`) |
| BB-16 | 2026-09-14 | PERIPHERY | `SettlementLens` ≠ settler on fill-once, reserved nonce, delta-verify, strict mode, pre-fund override, leg reuse, slice-zero threshold |
