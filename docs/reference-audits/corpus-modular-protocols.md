## Third corpus — modular signature-validating order protocols (2026-08-27)

A deliberate sweep rather than an opportunistic one: every EVM protocol that (a)
settles signed orders and (b) is modular in the way we are — pluggable validators,
hooks, or an allowance hub. Ordered by how closely the architecture maps onto ours.

### Read this round

| Protocol | Why it maps | What it gave us |
|---|---|---|
| **Seaport** (OpenSea) — [Code4rena](https://code4rena.com/reports/2022-05-opensea-seaport), OpenZeppelin + Trail of Bits (no majors) | The closest architectural sibling we had not read: EIP-712 **bulk/Merkle signatures**, **zones** (≈ our validators), **conduits** (≈ Permit3), partial fills, counter-based cancellation | **[C4 #168](https://github.com/code-423n4/2022-05-opensea-seaport-findings/issues/168) — an INTERNAL NODE passed off as a leaf.** Criteria trees took the leaf as a caller-supplied `tokenId` with no check that it was a leaf, so a fulfiller could submit an intermediate hash and trade an unlisted NFT. **We are structurally immune and it is now pinned**: `_foldProof(orderHash, …)` derives the leaf from the ORDER BEING FILLED, so a filler controls only the proof and has no field in which to submit a node; the root is additionally wrapped in its own `ORDER_ROOT_TYPEHASH`. See `test_bulkSignature_internalNodeCannotBeUsedAsALeaf`. |
| **ERC-4337 EntryPoint** — [OpenZeppelin](https://blog.openzeppelin.com/eth-foundation-account-abstraction-audit), [incremental](https://blog.openzeppelin.com/eip-4337-ethereum-account-abstraction-incremental-audit) | Signature validation inside a **batched** execution, plus modular validation and aggregators | Their finding: `validateUserOp` must RETURN `SIG_VALIDATION_FAILED` rather than revert, because a reverting validation inside a bundle takes the whole bundle down. **Our answer is different but sound**: `batchFill` wraps each fill in `try/catch` via `this.fillSelf`, so a bad signature yields `success[i] = false` instead of DoSing the batch, with `revertIfIncomplete` as the caller's explicit all-or-nothing opt-in. Containment at the batch boundary generalises better than a return-code convention, because it works for arbitrary sub-call failures, not just signatures. |
| **Across / ERC-7683** — [OpenZeppelin](https://www.openzeppelin.com/news/across-v3-incremental-audit), [deposit flow](https://www.openzeppelin.com/news/deposit-flow-audit) | We ship `OriginSettler7683` / `DestinationSettler7683` | A LOW: signed executions lacking single-use replay protection, repeatable until their deadline against a clone that later receives funds. Compare [F11](findings-ledger.md#f11--open-announced-an-erc-7683-order-without-the-signature-check-openfor-performs) — our own 7683 finding was in the same family (an entrypoint announcing without the check its sibling performs). They also flag **no unit tests for the 7683 depositor contracts**; ours are covered by `Erc7683.t.sol`. |
| **Balancer V2** — the 3 Nov 2025 exploit ([Trail of Bits](https://blog.trailofbits.com/2025/11/07/balancer-hack-analysis-and-guidance-for-the-defi-ecosystem/), [Check Point](https://research.checkpoint.com/2025/how-an-attacker-drained-128m-from-balancer-through-rounding-error-exploitation/), [OpenZeppelin](https://www.openzeppelin.com/news/understanding-the-balancer-v2-exploit)) | Not an order protocol, included because it is **this taxonomy's largest realised loss** | **~$128M, and the single most instructive item in this document.** Root cause: **asymmetric rounding between the two directions of one conversion** (upscale rounded down, downscale up/down), **amplified by batch atomicity** — 65 tuned micro-swaps in a single `batchSwap` compounded wei-level truncations into a deflated invariant. Each swap was individually negligible and individually valid. It had been audited by Trail of Bits, Spearbit AND Certora. See the lesson below. |

### Surveyed, audited, NOT yet read — queued with rationale

Recorded so the next round starts here instead of re-deriving the list. None is
believed urgent; each note says what would make it worth the time.

| Protocol | Audits | Why it might matter |
|---|---|---|
| **Clipper** — Quantstamp, Solidified, Immunefi | RFQ/PMM quote signatures. Smaller surface; low priority. |
| **Hashflow** — [Cyberscope](https://www.cyberscope.io/audits/coin-hashflow) | Signed RFQ quotes. Vendor-tier audit; low priority. |
| **Safe** | Not an order protocol, but the 1271 wallet our contract-signer path must interoperate with — relevant if S2 (owner-binding) is ever revisited. |

### The lesson from Balancer, and what we did about it

Three of the best firms in the industry reviewed that code and the bug still shipped,
because **the defect was not in any one operation** — every swap was individually
correct and individually valid. It existed only in the *composition*: a rounding
asymmetry that compounded under batching.

That is the same structure as [V1](corpus-v4-evk-rfq.md#second-corpus--v4--evk--rfq-2026-08-27) (Bunni,
44 valid transactions) and as our own [F15](findings-ledger.md#f15--a-duplicate-pull-step-burned-maker-allowance-without-extra-fill-progress)
(a duplicate step that satisfied every wholeness check). Three independent instances
of one shape is a pattern, not a coincidence:

> **A per-operation review cannot find a composition bug. State the invariant over
> the SEQUENCE and test it directly.**

Concretely, `RoundingDirection.t.sol` asserts the sequence-level property rather
than any single computation: slicing an order into N fills must never favour the
solver. (As first written it did so only for one-leg orders at a constant price, in
equal slices; [F30](findings-ledger.md#f30--re-audit-against-the-2026-09-24-corpus-additions-2026-09-25)
found the gap, and `RoundingSequence.t.sol` now carries the property over fuzzed
UNEVEN partitions, multi-leg, decaying, override, price-module, `fillTotal`,
`fillUpTo`, `batchFill`, item and mixed-decimal shapes — `testFuzz_prefix_*`.) Balancer's specific twist — *asymmetry between the two directions of the same
conversion* — is why that file now covers the **BUY** side as well as SELL: BUY
inverts which leg is anchored and which is auctioned, so it runs a different branch
of {Pricing}, and testing one direction proves nothing about the other.

---

### Read this round (2026-09-24) — the queued intent settlers and modular DEXes

The 2026-08-27 queue was worked down: **deBridge DLN**, **Valantis**, **0x Settler**,
**Aori** (via Dedaub) and **Balancer v3** (via Certora's design analysis) were read.
**Clipper**, **Hashflow** and **Safe** remain queued below.

#### deBridge DLN — Halborn (taker, external-call, crosschain-forwarder allowances)

| report | findings | what it gave us |
| --- | --- | --- |
| DLN Taker (2023-10) | 4 Low/Informational: outdated packages, missing `switch` default, unnecessary switch, TODO comments | **A negative result worth recording.** The taker/filler contract itself carries no severe finding — the filler role is structurally simple, which is the same conclusion [C1](failure-classes.md#c1--arbitrary-call-made-from-the-settlers-own-identity)'s trampoline and the pinned module selectors reach from the other side. |
| DLN External Call (2023-09) | 2 Low. HAL-01: `increaseAllowance` missing from `ExternalCallExecutor._isValideData()`'s `prohibitedSelectors` — the call surface blocks `approve`/`transferFrom`/`transfer` but not `increaseAllowance` | **The C1 selector scan, and why a denylist loses to an allowlist.** deBridge validates external-call `data` against a list of blocked selectors; the list forgot `increaseAllowance`, so an arbitrary call could still bump an allowance from the executor's own identity. We keep no such list — dispatch is selector-pinned to `makeOnBehalf` / `settle` / `takeOnBehalf` / `takeForOnBehalf`, re-checked in `checked-and-clean.md`. Standing rule, sharpened: **a denylist is always missing one selector; pin the allowlist.** |
| CrosschainForwarder Allowances (2024-09) | 1 Low (risk accepted): `_lazyApprove` sets `type(uint256).max` to whitelisted routers/gates | **The C12/[F1](findings-ledger.md#f1--revoking-permit3-is-not-a-kill-switch-on-its-own) lingering-allowance shape, accepted by them and refused by us.** deBridge accepts unlimited allowance to whitelisted routers. We deliberately do not: `transferFromWithFallback`'s direct-approval fallback is exactly this surface, and `setStrictMode` / `buildStrictOnboarding` / `buildRevokeAll` close it. External precedent for F1. |

#### Valantis — Statemind (Core + HOT AMM)

A modular DEX where pools compose modules — the closest external analogue to our
pluggable-module surface. Core: 5 Medium, 32 Informational; HOT: 6 Medium, 7
Informational. The transferable findings:

- **Rounding direction in quotes** (Core MED-04 "rounding in favour of the protocol
  account for the last token in a quote"; Info-11 the inverse) — the [C7](failure-classes.md#c7--rounding-direction-and-split-fill-dust)
  family: whichever way the last unit rounds, someone pays it. External precedent for
  the maker-favourable, per-fill posture in [`pricing-modes.md`](../pricing-modes.md).
- **Delta-balance check bypass** (Core Info-07 "the delta balance check can be
  bypassed in future sovereignVault") and **loss of deposited tokens during a swap**
  (Core Info-14) — the [C15](failure-classes.md#c15--the-settlers-balance-treated-as-a-shared-pot)
  shape: a measurement is only as sound as the binding between what moved and what was
  measured. The discipline `_creditItemProceeds` and `deltaVerifyOutputs` encode here.
- **Reorg on pool/contract creation** (Core MED-02/MED-05) — deployment-time, not
  fill-time; relevant to [`deterministic-deployment.md`](../deterministic-deployment.md)'s
  CREATE2 same-address argument, which pins address-equivalence but does not (yet)
  discuss reorg depth on the young L2s.
- **Rebasing tokens** (HOT MED-03) — [C14](failure-classes.md#c14--assumptions-about-how-tokens-behave),
  the same "the maker chose the token" caveat as here.
- **Fee arithmetic** (HOT MED-01 "incorrect fee calculations") — ordinary bps/rounding
  on the surface [`originator-fees.md`](../originator-fees.md) and
  [`relayer-fees.md`](../relayer-fees.md) pin.
- **AMM-mode ALM breaks without oracles** (HOT MED-04) — [C5](failure-classes.md#c5--the-maker-supplies-the-function-that-is-the-price):
  a relayer/oracle dependency that is not optional once it is load-bearing.

#### 0x Settler CrossChainReceiverFactory — Dedaub (2025-06)

Cross-chain receiver: CREATE2 minimal proxy per (merkle-root, owner), `approvePermit2`
+ swap bundled by a relayer, Permit2 `PermitWitnessTransferFrom` with an ERC-7739
rehash. 1 Medium + 2 protocol-level + advisories:

- **M1 / P1 — front-runner DoS.** Deploying the minimal proxy, or removing the
  `approvePermit2` allowance, can be front-run to brick the swap — the sequence must
  be bundled in one transaction. The [C11](failure-classes.md#c11--the-permit-as-a-liveness-bomb)
  family: a permit/approval in a public order is a liveness bomb when it is not atomic
  with its use; our `fillWithPermit` idempotent spent-bit skip is the same answer.
- **A2 — two signature schemes, one `isValidSignature`.** Merkle-proof and ERC-7739
  signatures are disambiguated by "first 12 bytes zero" — a shape predicate, like our
  bulk-envelope length predicate ([S5](signature-validation.md#signature-validation--the-published-corpus-vs-our-position)).
  The lesson is the same: a shape predicate must be exclusive, or one encoding reads as
  the other.
- **Q1 — nested ERC-7739/ERC-1271.** No standard covers a signature whose owner is
  itself a contract (no nested rehash). This is the [S2](signature-validation.md#signature-validation--the-published-corpus-vs-our-position)
  residual in the wild: owner-binding at the raw-permit layer for naive 1271 wallets is
  delegated to the wallet (ERC-7739) or closed by the witness. Dedaub's sketch of a
  nested format confirms the gap is real and unstandardised.

#### Aori — Dedaub (2023-05)

Aori Prime (under-collateralised options over an RFQ order book). Dedaub's verdict:
**"not ready for deployment"** — 4 Critical, 7 High, 4 Medium, the order-matching
logic (`fillAsks`/`fillBids`) needing a rewrite. The transferable items are the naive
end of two classes we already hold at the sophisticated end:

- **C1/C2/H1 — missing access control on privileged functions.** `whitelistVault`,
  `stakeLPTokens`, `unstakeLPTokens` had no caller check — anyone could whitelist a
  vault/oracle, or stake/unstake arbitrary tokens against a user's approvals. F26's
  C-1 (Liquity caller-supplied root) is the *sophisticated* form of the same lesson;
  Aori is the *naive* form. Either way: a privileged write must be gated, not merely
  named.
- **C4 — caller-supplied beneficiary without authorisation.** `settlePosition(account,
  key)` paid the position's collateral to the caller-named `account` with no check that
  the caller was authorised for it. The [C15](failure-classes.md#c15--the-settlers-balance-treated-as-a-shared-pot)
  shape in its crudest form: a settle/claim's destination must be a deliberate decision
  (the maker, or `msg.sender`), never a bare caller-chosen argument.

#### Balancer v3 — the precise root cause and the formal answer (read 2026-09-24)

[Certora's post-incident analysis](https://www.certora.com/blog/breaking-down-the-balancer-hack)
names the exact mechanism and, more usefully, the two properties that would have
caught it:

- **The root cause, precisely.** `_swapGivenOut` upscales the output amount with
  `_upscale` = `FixedPoint.mulDown` — *rounded down where it should be rounded up*.
  Rounding the output down understates the required input, so the invariant ends lower
  than it should. The two directions of one conversion (upscale vs downscale) round
  asymmetrically, and a composable pool's BPT-deficit state lets an attacker deflate
  liquidity and amplify a wei-level bias into a profitable round-trip. The C7 family,
  one step sharper: **the asymmetry between the two directions is the bug — not either
  direction alone.**
- **The two properties that would have caught it.** Certora's v2 work had proved
  *solvency* (BPT supply ≤ totalAssets; no mint without assets) and it did **not** rule
  this out — "solvency proofs are not sufficient." The missing properties:
  1. *Roundtrip swap invariance* — swapping A→B→A must never yield more than the start.
  2. *Share-value monotonicity* — a single share's value must never decrease across any
     operation.
- **v3's answer**, which is the queue item now answered: centralise scaling and
  rounding in the vault (one place, explicit direction), run every pool at 18-dec
  precision, replace composable pools with ERC-4626 buffers, and pin
  `swappingBackAndForth` with the Prover. v3 bounds composite-op rounding by
  **centralising the rounding decision and enforcing one direction per computation**,
  not by writing a smarter per-pool formula.

Mapped here: `RoundingDirection.t.sol` is the roundtrip property in our terms
(slicing an order into N fills must never favour the solver), covering both SELL and
BUY because BUY inverts which leg is anchored. Certora's
**share-value-monotonicity** phrasing — the same claim read from the maker's side: no
sequence of fills may reduce the maker's realised value per anchor unit — is
`RoundingSequence.t.sol`'s prefix property, checked after EVERY prefix of a fuzzed
partition rather than only at the end (`testFuzz_prefix_sell_multiLeg`,
`testFuzz_prefix_buy_multiLeg` and siblings). If a `matchSettle` or fill-module
change ever moves rounding, that is the property to re-assert. Not yet covered: the
per-venue share round-trip (N slices against one fill burn ≤ one fill's shares + N),
which needs a share-venue mock in core.

---
