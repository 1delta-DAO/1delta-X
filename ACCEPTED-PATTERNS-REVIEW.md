# Accepted patterns: comparison with common practice

**Date:** 2026-10-06
**Tree:** `main` at `168c1f0` plus the uncommitted working set
**Scope:** the 26 "accepted / by design / documented, not fixed" patterns listed in
[SIGNATURE-VALIDATION-REVIEW.md](SIGNATURE-VALIDATION-REVIEW.md) §5 and
[REVIEW-2026-10-05-amount-mismatch.md](REVIEW-2026-10-05-amount-mismatch.md) §2–§4, §6, §8,
plus the closed tasks in `tasks/done/` that recorded the decisions.

- [1. Method](#1-method)
- [2. Summary](#2-summary)
- [3. Signature and authorization (A1–A6)](#3-signature-and-authorization-a1a6)
- [4. Amounts and matching (B7–B20)](#4-amounts-and-matching-b7b20)
- [5. Off-chain and operator (C21–C26)](#5-off-chain-and-operator-c21c26)
- [6. Ranked recommendations](#6-ranked-recommendations)

---

## 1. Method

Each pattern was re-checked against the current source (file:line below), not only
against the review text. Comparisons are to Uniswap Permit2, UniswapX, 1inch LOP v4 /
Fusion, CoW Protocol, 0x Settler, OpenZeppelin and Seaport. External claims are
cited to primary sources. A claim this pass could not check against a primary source
is marked **unverified** and does not carry the verdict on its own. The repo's own
corpus ([docs/reference-audits/](docs/reference-audits/README.md),
[findings-ledger.md](docs/reference-audits/findings-ledger.md),
[reference-bounties.md](docs/reference-bounties.md)) was used where it already holds a
verified comparison (e.g. Permit2 malleability, S1 / F6).

Verdicts:

- **R/C**: reasonable, and the same as common practice.
- **R/D**: reasonable, but different from common practice. The difference is stated.
- **Q**: questionable. Change recommended.

Not an external audit. No code changed. The only file written is this one.

---

## 2. Summary

| # | Pattern | Verdict | One line |
|---|---|---|---|
| A1 | ERC-20 approve → Permit3, book grant → Settlement | R/C | Permit2's two-layer AllowanceTransfer model. |
| A2 | Permit-batch witness under Permit3 domain naming Settlement | R/C | UniswapX `OrderInfo.reactor` pattern. |
| A3 | PermitTake witness = bare orderHash, spender folded in | R/C | Permit2 SignatureTransfer binds `spender = msg.sender` the same way. |
| A4 | Zero-address domain demo signing in the app | R/D | Harmless on-chain. Production apps do not sign under placeholder domains. |
| A5 | Narrower delegate coverage on some paths | R/C | Fails closed (liveness only), and documented. |
| A6a | ECDSA before EIP-1271, also for signers with code | R/D | Practice is split. Permit2, OZ ≥ 5.1 and Solady check code first. Seaport, OZ ≤ 5.0 and 1inch try ECDSA first. Our NatSpec cites OZ, which changed sides in 5.1. |
| A6b | High-s signatures accepted (no low-s check) | R/C | Same as Permit2, Solady, Seaport and CoW. OZ and 1inch reject high-s. Safe because no state is keyed on signature bytes. |
| B7 | `maxPay` is per token | R/C | Operator-side parameter. Documented and tested. |
| B8 | Late TAKE on an input-leg token under `ItemPolicy.ANY` spends allowance twice | **Q** | Permissionless griefing of finite allowances under the **default** policy. The same harm was fixed as a bug for duplicate PULL. **Resolved 2026-10-06** off-chain: SDK defaults to CANONICAL, lens flags it. |
| B9 | Netted path pushes input residue, then sweeps it back | R/C | Two extra transfers, no accounting effect. |
| B10 | FoT anchor + patch always reverts | R/C | CoW calls FoT tokens unsuitable. UniswapX transfers the nominal amount. Our core is general, and one solver fails closed. |
| B11 | SELL output ceil vs input floor, so a tight partial is 1 wei short | R/C | Maker-favourable rounding, same direction as 1inch `AmountCalculator`. |
| B12 | OverFill race burns a revert's gas | R/C | Same as UniswapX (Permit2 `InvalidNonce`). 1inch clamps instead, like our `fillUpTo`. |
| B13 | Market order: 60 s decay, then rests at floor until 300 s | **Q** | On direct orders the only filler is our own `exclusiveFiller` for the whole life. The auction has no competition, so a rational filler waits for the floor. UniswapX limits exclusivity to about 2–24 s and ends about 1 min of decay with expiry. 1inch Fusion's default tail is 12 s. |
| B14 | Lista per-slice 1-wei rounding drawn from wallet | R/C | Sub-unit, bounded per slice, maker-signed rate floor. |
| B15 | Exactly pre-maturity withdraw discount bounded only by a maker floor that may be 0 — *Resolved 2026-10-06 (`ZeroMinAssets`)* | **Q** | The sibling repay branch refuses a signed 0 (`ZeroMaxAssets`). Withdraw should too while `maturity > now`. A 0 here is an unbounded wallet draw that a filler can push in the same block. |
| B16 | Exactly repay on a closed position is a no-op | R/C | Same as the `min(amount, debt)` clamp in the other repay modules. |
| B17 | `DustHandler.readAction` untagged | R/D | Benign, maker-signed. Inconsistent with `readBalanceMode`. Tag at the next breaking encoding change. |
| B18 | `FunnelGrantModule` fixed-input only | R/C | Fails closed and is documented. |
| B19 | `FullFillGuard` items unusable with position-sized fills | R/C | Fails closed, and the design rules it out. |
| B20 | Pre-fund over-delivery strands below the floor | R/D | Loss falls only on the over-delivering solver. Routers usually refund the excess. Recovery path is not documented. |
| C21 | Dropped tx keeps gas + inventory reservation for an hour | R/C | Conservative accounting under uncertainty. |
| C22 | Stable haircut 5 bps, `MIN_PROFIT_RBTC = 0` | R/D | Principal safe (on-chain floors). Expected value is negative per revert. Needs a revert-rate guard. |
| C23 | Sushi executors not pinned by default | R/D | Router pinned and min-out checked, so it fails closed. Pin executors in production config. |
| C24 | Inventory gas priced from one pool when `RBTC_PRICE_USD` is unset | R/C | Off-chain, bounded to gas. Set `RBTC_PRICE_USD` in production. |
| C25 | `/status` shows RPC origin to admin | R/C | Admin-only, origin only (no path or key). |
| C26 | `RouteSandbox` standing max approvals per (token, router) | R/C | 0x Settler does the same (`safeApproveIfBelow` → max). Safe only because route authorship is gated. CoW's 2023 buffer loss is the matching failure. |

**Counts:** R/C 18, R/D 6, Q 3. (A6 is counted once, as R/D.)

---

## 3. Signature and authorization (A1–A6)

### A1. ERC-20 approve to Permit3, Permit3 book grant to Settlement — R/C

The maker approves the token to Permit3, and Permit3's book is keyed
`(owner, token, spender = Settlement)`
([funding.ts:95](packages/app/src/lib/funding.ts#L95)). The app refuses to prompt if
`Settlement.PERMIT3()` is not the configured hub
([chain.ts:43](packages/app/src/lib/chain.ts#L43)).

**Precedent:** Permit2's AllowanceTransfer works the same way. Users `approve` Permit2
once, and Permit2 keeps `allowance[owner][token][spender]`
([AllowanceTransfer.sol](https://github.com/Uniswap/permit2/blob/main/src/AllowanceTransfer.sol),
[Permit2 docs](https://docs.uniswap.org/contracts/permit2/overview)). UniswapX and 0x
Settler use the same two layers.
**Recommendation:** none.

### A2. Permit-batch witness signed under Permit3's domain, naming the Settlement — R/C

`SettlementOrder(address settlement, Order order)`
([OrderHash.sol:144](packages/core/src/settlement/OrderHash.sol#L144)). The domain is
Permit3's, so the settler address has to be inside the witness. Without it, a
redeployed Settlement sharing the hub could replay the order (closed 2026-09-25).

**Precedent:** UniswapX does the same. The order is a Permit2 witness signed under
Permit2's domain, and `OrderInfo` carries `reactor`. `ResolvedOrderLib.validate`
reverts `InvalidReactor` when `info.reactor != address(this)`
([ResolvedOrderLib.sol](https://github.com/Uniswap/UniswapX/blob/main/src/lib/ResolvedOrderLib.sol)).
**Recommendation:** none.

### A3. PermitTake witness = bare orderHash, `spender = msg.sender` folded in — R/C

`hashPermitTake(permit, spender)` hashes `spender` taken from `msg.sender` at
consumption ([Permit3Hash.sol:246](packages/core/src/permit3/libraries/Permit3Hash.sol#L246)).

**Precedent:** Permit2 SignatureTransfer's `PermitTransferFrom` typehash includes
`spender`, filled from `msg.sender`
([PermitHash.sol](https://github.com/Uniswap/permit2/blob/main/src/libraries/PermitHash.sol)).
The two witness shapes differ for a good reason: each permit type binds the caller
differently.
**Recommendation:** none. Keep the comment explaining why the two witness shapes
differ. It is the first thing a reviewer flags.

### A4. Zero-address domain signing in the app — R/D

When no deployment is configured the app signs under
`{chainId, settlement: 0x0, permit3: 0x0}`
([App.tsx:292](packages/app/src/App.tsx#L292)), labelled "domain not deployed".
Such a signature cannot authorize anything: no contract has `verifyingContract = 0`.

**Deviation:** production apps for Uniswap, 1inch and CoW do not ask users to sign
real-looking typed data that is not consumable (**unverified** as a stated policy;
observed practice). The harm is not on-chain. It trains users to sign `Order`
payloads with a zeroed domain.
**Recommendation:** compile the demo path out of production builds, or refuse to sign
when `import.meta.env.PROD` and no deployment is set. Low priority.

### A5. Narrower delegate coverage on some paths — R/C

The limits are: `fillWithPermit` takes no delegate (Permit3 verifies `owner` only); a
7702 maker cannot use the contract-delegate envelope (the `expected.code.length == 0`
guard, [Signatures.sol:417](packages/core/src/settlement/Signatures.sol#L417)); a
1271 maker can bulk-sign only with a 65-byte wallet signature
([Signatures.sol:319](packages/core/src/settlement/Signatures.sol#L319)). Each gap
makes a signature fail, never succeed.

**Precedent:** session-key / delegate signing is not offered in Permit2, UniswapX or
1inch LOP at all. Here it is an extra, and narrowing it costs only liveness.
**Recommendation:** none beyond the existing NatSpec. Surface the limits in the SDK
error messages.

### A6a. ECDSA tried before EIP-1271, also for signers with code — R/D

`SignatureVerification.verify`
([SignatureVerification.sol:120](packages/core/src/permit3/SignatureVerification.sol#L120))
first tries `ecrecover` on any 64/65-byte signature and returns if the result matches
`claimedSigner`. Only then does it fall back to 1271 for an address with code. The
same order appears in `Signatures._verifySignature`, the lens, and
`FillerAttestationValidator`.

**How the compared systems order it (all verified against source on 2026-10-06):**

| Order | Systems | Source |
|---|---|---|
| Code first. A contract is never checked with ECDSA. | Permit2, OZ ≥ 5.1, Solady | [permit2 SignatureVerification.sol](https://github.com/Uniswap/permit2/blob/main/src/libraries/SignatureVerification.sol) `if (claimedSigner.code.length == 0) {…} else {1271}`; OZ CHANGELOG 5.1.0: "refactor `isValidSignatureNow` to avoid validating ECDSA signatures if there is code deployed at the signer's address (#4951)" ([CHANGELOG](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/CHANGELOG.md), [SignatureChecker.sol](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/cryptography/SignatureChecker.sol)); [Solady SignatureCheckerLib](https://github.com/Vectorized/solady/blob/main/src/utils/SignatureCheckerLib.sol) "If `signer.code.length == 0`, then validate with `ecrecover`, else … ERC1271" |
| ECDSA first, then 1271 | OZ ≤ 5.0, Seaport, 1inch `recoverOrIsValidSignature` | [OZ v5.0.0 SignatureChecker](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v5.0.0/contracts/utils/cryptography/SignatureChecker.sol); [seaport-core SignatureVerification.sol](https://github.com/ProjectOpenSea/seaport-core/blob/main/src/lib/SignatureVerification.sol) "An ERC-1271 fallback will be attempted if … the recovered signer does not match"; [1inch solidity-utils ECDSA.sol](https://github.com/1inch/solidity-utils/blob/master/contracts/libraries/ECDSA.sol) |
| Scheme chosen explicitly, nothing inferred | CoW (order flag `Eip712/EthSign/Eip1271/PreSign`), 1inch LOP v4 (separate `fillOrder` / `fillContractOrder` entrypoints) | [GPv2Signing.sol](https://github.com/cowprotocol/contracts/blob/main/src/contracts/mixins/GPv2Signing.sol); [OrderMixin.sol](https://github.com/1inch/limit-order-protocol/blob/master/contracts/OrderMixin.sol) |

Under EIP-7702 a delegated EOA has `EXTCODESIZE == 23`
([EIP-7702](https://eips.ethereum.org/EIPS/eip-7702)). So with every code-first
verifier (Permit2, OZ ≥ 5.1, Solady), a 7702 account can sign only through its
delegate's `isValidSignature`.

**The repo's justification is out of date.** "OpenZeppelin's `SignatureChecker` makes
the same trade"
([SignatureVerification.sol:35](packages/core/src/permit3/SignatureVerification.sol#L35))
was true up to 5.0.x. OZ moved to code-first in 5.1.0 (October 2024), and it did so
for the very 7702 case this comment invokes. Seaport and 1inch are still valid
precedents for ECDSA-first.

**What the deviation costs:** under 7702 the account's key can always authorize
orders and permits, even when the delegate would refuse (rotated owners, a
passkey-only policy). The key can re-delegate at any time, so on-chain it never loses
power. EIP-7702 says the delegate code "has unrestricted access to the account", and
an account delegated to `0x0` "is indistinguishable from a true EOA". The EIP gives
no guidance for signature verifiers, so this point is inference, not quotation.
Honouring the key adds no power the key lacks. It does override a delegate policy
the user may believe is in force, and that is exactly what OZ chose to stop doing. A second cost: a
contract wallet whose own key-derived address equals its address cannot exist
outside 7702, so for plain contract wallets ECDSA-first cannot be exploited.

**Verdict:** a defensible choice with precedent (Seaport, 1inch, OZ ≤ 5.0). It
supports raw-key 7702 makers, which Permit2 refuses. But the current direction of
the libraries (OZ ≥ 5.1, Solady) is code-first, and our NatSpec cites OZ for the
opposite of what OZ now does.
**Recommendation:** (1) correct the NatSpec here, in `Signatures.sol`, and in
`FillerAttestationValidator`: cite Seaport / OZ ≤ 5.0, and say that OZ ≥ 5.1 and
Permit2 deliberately chose code-first;
(2) say in the maker docs that revocation goes through `cancelOrder` / nonces /
Permit3 allowances, never through delegate policy (already in the NatSpec, not in
user docs).

### A6b. High-s signatures accepted (no low-s check) — R/C

`tryRecoverSigner` passes `s` to `ecrecover` unchecked
([SignatureVerification.sol:84](packages/core/src/permit3/SignatureVerification.sol#L84)).
One authorization therefore has four valid byte encodings (high/low s × 64/65 bytes).

**Precedent:** Permit2 has the same gap, and its own auditor called it out as a reuse
hazard ([permit2-forked-source.md 7.2](docs/reference-audits/permit2-forked-source.md)).
Solady ("does NOT check if a signature is non-malleable",
[ECDSA.sol](https://github.com/Vectorized/solady/blob/main/src/utils/ECDSA.sol)),
Seaport and CoW `GPv2Signing.ecdsaRecover` also skip the check. OZ
`ECDSA.tryRecover` rejects `s > 0x7FFF…20A0` with `InvalidSignatureS`
([ECDSA.sol](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/cryptography/ECDSA.sol)),
and 1inch solidity-utils returns 0 above `_S_BOUNDARY`. EIP-2: "The ECDSA recover
precompiled contract remains unchanged and will keep accepting high s-values"
([EIP-2](https://eips.ethereum.org/EIPS/eip-2)). Practice is split, and the systems
that skip the check are the ones that, like us, never key replay on signature bytes.

**Why it is safe here:** fill state is keyed on `orderHash`, permits on nonces;
nothing on-chain is keyed on signature bytes (grep: no `keccak256(sig…)` in
`packages/core/src`, `periphery`, `solvers`). Ledger rule F6 / S1 says so and
`test_malleability_fourEncodings_stillOneFill` pins it.

**One off-chain exception to note:** the orderbook verifier's cache key includes
`keccak256(sig)` ([verify.ts:518](packages/orderbook/src/verify.ts#L518)), which goes
against F6's literal "never key cache entries on signature bytes". It was done on
purpose (F29 P2: a verdict must not be inherited by a different sig), and it fails
safe: a malleated variant only costs a cache miss, and the cache and queue are
bounded. Malleability multiplies the lens calls per announce by four.
**Recommendation:** optional: normalise to low-s in Layer 1 before keying (falls out
of the F2 `recoverEcdsa` fix). Update the F6 rule to "never key a *grant* or a
*dedup* on signature bytes".

---

## 4. Amounts and matching (B7–B20)

### B7. `maxPay` is per token — R/C

Two output legs in the anchor token (maker 90 + fee 2) need `maxPay ≥ 92`
([AggregatorFillSolver.sol:264](packages/solvers/src/aggregator/AggregatorFillSolver.sol#L264)).
This is a solver-side cap the operator supplies, and it fails closed (revert). There
is no direct external analogue: UniswapX fillers and CoW solvers carry this kind of
bound in their own executor code.
**Recommendation:** none. `test_S3_maxPayIsPerToken` pins it.

### B8. Late TAKE on an input-leg token under `ItemPolicy.ANY` spends the maker's allowance twice — **Q**

How it happens: `_stepPull` draws `owed − credit`
([Batch.sol:583](packages/core/src/settlement/Batch.sol#L583)). A TAKE scheduled
after the PULL credits the leg again, and Phase 3 refunds the duplicate tokens. The
Permit3 allowance spent on the first draw is not refunded. `ItemPolicy.ANY = 0` is
the default ([Structs.sol:425](packages/core/src/settlement/Structs.sol#L425)), and
`matchSettle` is permissionless
([Batch.sol:342](packages/core/src/settlement/Batch.sol#L342)).

**Why this is questionable:** the Batch NatSpec
([Batch.sol:565–580](packages/core/src/settlement/Batch.sol#L565)) treats exactly this
harm as a bug when it is reached by a duplicate PULL ("consumed 2× the allowance for
1× the fill … any solver could do it") and fixed it. The same harm reached by
*ordering* is accepted, and it is open to any matcher, not just "the operator's
schedule choice". The opt-out (ORDERED / CANONICAL) exists, but the default does not
protect the maker. Impact is griefing only: tokens round-trip, and a finite
allowance is halved until the maker re-approves. Makers on `uint160.max` allowances
are not affected.

**Precedent:** Permit2 and UniswapX never debit an allowance for value that is
returned in the same transaction, because pulls are exact. In 1inch LOP the
pre/post interaction hooks are maker-chosen, not chosen by whoever fills
(**unverified** line reference). No compared system lets a third party pick an order
of execution that costs the maker allowance.
**Recommendation (cheapest first):** (1) the SDK and app sign `ItemPolicy.ORDERED`
by default whenever an item produces a token that is also an input leg; (2) the lens
`validateOrder` flags ANY + an input-token-producing TAKE; (3) at the next core
redeploy, revert an ITEM that credits a leg whose credit already reached `owed` (no
new storage: `st.credit` is in memory). (1) and (2) cost no bytecode.

**Resolved 2026-10-06 (off-chain + lens; no core/Settlement change).** One correction
to the recommendation first: **ORDERED does not close this.** ORDERED and ATOMIC only
order the maker's items among themselves; a PULL of an input leg may still be
scheduled ahead of the item group. Only CANONICAL is enforced against the PULL
(`_stepPull` reverts `ItemPolicyViolated` for an order whose items have not all run),
and CANONICAL is exactly the single-order path's shape (deliver → items → pull), so it
costs `fill`/`fillUpTo` nothing. Its cost is on the netted path only: the order cannot
join a CYCLE and a solver cannot use the TAKE's proceeds to fund this order's own
delivery. `test_S2_lateTakeOnInputToken_canonicalRefusesTheSchedule` pins both halves
(ORDERED still burns the allowance; CANONICAL reverts the schedule and spends nothing).
- (1) SDK: `takeFundsInputLeg` + `withDefaultItemPolicy`
  ([types.ts:578](packages/sdk/src/types.ts#L578)) sign CANONICAL when a plain TAKE
  routed to the settler (`0x0` or the Settlement address) credits an input leg and
  no policy was set; an explicit `itemPolicy` (ANY included) wins. `patchOrder` /
  `amendOrder` apply it; `signOrder`
  ([orders.ts:89](packages/sdk/src/orders.ts#L89)) refuses that shape at ANY unless
  `opts.itemPolicy === ItemPolicy.ANY` (it cannot default silently: the caller
  submits its own order object). The app signs `items = []` and is unaffected.
- (2) Lens: `validateOrder` returns "input-funding TAKE needs ItemPolicy.CANONICAL
  (late TAKE spends the allowance twice)" for a TAKE to the settler whose
  `IProceedsAsset` names an input-leg token under any policy below CANONICAL
  ([SettlementLensChecks.sol:980](packages/periphery/src/SettlementLensChecks.sol#L980)).
  Not flagged: a TAKE routed to the maker (borrow after deposit), a silent module,
  TAKE_FOR (`matchSettle` refuses those orders). SettlementLensChecks 17,221 →
  17,412 B (via-IR); the lens initcode changes, so the CREATE2 lens moves address
  on its next deploy. (3) stays open for the next core redeploy.

### B9. Netted path pushes unspent input residue, then sweeps it back — R/C

Two extra transfers, no accounting effect. Skipping the push would be wrong when
`avail < outstanding` (review §2). This is a gas trade, not a correctness issue. CoW's
settlement also moves buffer balances in and out within one transaction.
**Recommendation:** none.

### B10. Fee-on-transfer anchor + `amountInOffset` always reverts — R/C

Documented at
[AggregatorFillSolver.sol:90–99](packages/solvers/src/aggregator/AggregatorFillSolver.sol#L90).
The core settles FoT for any maker; this one solver specialises to exact-transfer
tokens and reverts (fails closed) instead of mis-routing.

**Precedent:** UniswapX "handles fee-on-transfer tokens by transferring the amount
specified … the actual amount received … will be _after_ fees" (UniswapX README),
so the loss lands on the recipient. CoW lists FoT tokens as "unsuitable"
([docs.cow.fi tokens](https://docs.cow.fi/cow-protocol/reference/core/tokens)).
Permit2 and 1inch LOP make no explicit statement (unverified). A general core plus
one solver that fails closed is at least as careful as common practice.
**Recommendation:** none. Matches the "core general, solvers specialise" principle.

### B11. SELL outputs per-fill ceil vs inputs floor, so a tight partial fill can be 1 wei short — R/C

[Pricing.sol:22–30](packages/core/src/settlement/Pricing.sol#L22): outputs are
`ceilDiv`, inputs are floored. Rounding always favours the maker. 1inch LOP's
`AmountCalculator` makes the same choice (making amount floor, taking amount ceil;
[AmountCalculatorLib.sol](https://github.com/1inch/limit-order-protocol/blob/master/contracts/libraries/AmountCalculatorLib.sol):
"Floored maker amount" / "Ceiled taker amount", verified). UniswapX's
`PriorityFeeLib` rounds both sides "to favor the swapper".
**Recommendation:** none. A filler sizes slices one wei looser.

### B12. OverFill race between book read and inclusion — R/C

`fillWithCallback` reverts `OverFill`
([OrderState.sol:485](packages/core/src/settlement/OrderState.sol#L485)). `fillUpTo`
clamps, and `type(uint256).max` means "the remainder". UniswapX reverts the losing fill on the Permit2 nonce
(`if (flipped & bit == 0) revert InvalidNonce();`,
[SignatureTransfer.sol](https://github.com/Uniswap/permit2/blob/main/src/SignatureTransfer.sol)).
1inch LOP v4 instead clamps to the remaining amount
(`makingAmount = Math.min(amount, remainingMakingAmount)`) under a taker price
`threshold` ([OrderMixin.sol](https://github.com/1inch/limit-order-protocol/blob/master/contracts/OrderMixin.sol)).
Our `fillUpTo` is the 1inch shape and `fillWithCallback` is the UniswapX shape. The route
path cannot clamp safely, because its calldata is sized for one amount.
**Recommendation:** none on-chain. On Rootstock (no private mempool), keep the
filler's simulate-just-before-send step.

### B13. Market order: 60 s decay, then rests at the floor until the 300 s expiry — **Q**

How it works: `MARKET_DECAY_SECONDS = 60`, `MARKET_TTL_SECONDS = 300`,
`MARKET_SLIPPAGE_BPS = 50` ([plan.ts:9–30](packages/app/src/lib/plan.ts#L9)). On
direct (delta-verify) markets the app names the operator's solver as
`exclusiveFiller` ([order.ts:254](packages/app/src/lib/order.ts#L254)), and the core
lets **only** that filler fill a delta-verify order, for its whole life (ledger
F-entry at [findings-ledger.md:1665](docs/reference-audits/findings-ledger.md#L1665)).

**What actually happens:** a Dutch auction with one permitted bidder is a posted
price at the floor. A filler gains by waiting: every second of decay is its margin,
and the 240 s rest gives it a free option on the price at the floor. The task-15
e2e shows it: every market fill landed 11–13 s *after* the floor
([tasks/done/15-market-floor-economics.md](tasks/done/15-market-floor-economics.md)),
so makers paid the full 50 bps. Today the operator is the filler and is assumed to
behave well, but the protocol does not enforce it.

**Precedent (verified):**

- **Resting at the floor is normal.** UniswapX `DutchDecayLib` returns `endAmount`
  once `decayEndTime <= block.timestamp`, and the Dutch reactors require
  `deadline >= decayEndTime` (`DeadlineBeforeEndTime`,
  [V2DutchOrderReactor.sol](https://github.com/Uniswap/UniswapX/blob/main/src/reactors/V2DutchOrderReactor.sol)).
- **The tail is short.** Uniswap's auction-types docs give Ethereum Dutch V2
  exclusivity of "~24 seconds (2 blocks)" and "about 1 minute, then expiry", and
  DutchV3 exclusivity of "~2 to 4 seconds". 1inch fusion-sdk sets
  `deadline = start + duration + orderExpirationDelay` with
  `orderExpirationDelay: 12n` (fusion-order.ts). Both keep the rest at the floor to
  seconds.
- **Exclusivity is a window, not a lifetime.** After it, anyone fills, with
  `exclusivityOverrideBps` as the price of early access
  ([ExclusivityLib.sol](https://github.com/Uniswap/UniswapX/blob/main/src/lib/ExclusivityLib.sol)).

A one-minute auction followed by a 240 s rest at the floor, with one exclusive
filler for the whole life, has no counterpart in either design. The 240 s comes from
the book and filler gates (task 04), not from auction design.

**Recommendation:** pick one. (a) Shorten the rest: TTL just above the book/filler
gates (e.g. decay 60 s → floor, TTL 150 s with `MIN_TTL` and `EXPIRY_MARGIN`
retuned). (b) Commit the operator filler to fill at the first profitable tick (it
already does), and disclose in the UI that the expected price is the floor. (c)
Longer term: let direct orders fall back to pull delivery after the exclusive window,
so others can compete. At minimum, state in the order form that market orders fill at
or near the floor.

**2026-10-06: a pull-market window was built and is opt-in, off by default.**
Pull markets can sign `exclusiveFiller` = the deployment's solver with a soft window
(`pullExclusivity` / `marketExclusivity`, packages/app/README.md). 60 s is about 2
Rootstock blocks, and the premium is 5 bps. After the window the order is open to
every filler until the unchanged 300 s expiry. The default is `seconds: 0`, which
keeps today's open pull shape, because the user rule is "no additional gas on fills"
(stablecoin quotes are tight). Measured on the plain SELL fill against
`exclusiveFiller = 0`:

- one named filler with a window costs **+509 gas per fill** (+245 execution,
  +264 calldata);
- a `FILLER_SET` covering both our fillers costs **+1,229 to +1,304 gas per
  fill**, and the SDK cannot express it (`curve` is typed as curve points).

Under a single-solver window the inventory EOA, which fills with `fillUpTo` as
itself, is an **outsider**. It must pay the premium or wait for the window to end.
The beta filler handles soft and hard windows either way. Direct markets are
unchanged: the core makes delta-verify exclusivity whole-life (F30), so option (c)
would need core work and is still open. The order form now shows who may fill and
when ("Filled by"). Pull markets are open to all by default, so on them the floor
is not a one-bidder price. Direct markets still are.

### B14. Lista per-slice 1-wei rounding drawn from the wallet — R/C

Per-slice floors are `amount × rate / 1e18`
([ListaSmartModules.sol:47](packages/modules/lending/lista/src/ListaSmartModules.sol#L47)).
Any sub-unit shortfall against the leg's `owed` is pulled from the maker's wallet by
the core, at most one wei per slice. The lens floor test pins the boundary
(`Review20261006Lens.t.sol:159`, "one wei short"). Amounts this small are the
normal rounding tolerance in any pro-rata system.
**Recommendation:** none. Note it beside the unit-split rule (task 11).

### B15. Exactly pre-maturity withdraw discount bounded only by a maker floor that may be 0 — **Q**

`withdrawAtMaturity` before maturity pays `assetsDiscounted < amount`, and the core
bills `owed − assetsDiscounted` to the maker's wallet. The only bound is the
maker-signed `minAssetsRequired`, which may be 0
([ExactlyModules.sol:318–330](packages/modules/lending/exactly/src/ExactlyModules.sol#L318)).
The fixed rate behind the discount is live utilisation, which a filler can raise in
the same block by borrowing first. The lens now flags a zero floor
([ExactlyModules.sol:383–398](packages/modules/lending/exactly/src/ExactlyModules.sol#L383)).

**Why this is questionable:** the same file **refuses** a signed zero on the
repay-at-maturity bound (`ZeroMaxAssets`, [ExactlyModules.sol:254](packages/modules/lending/exactly/src/ExactlyModules.sol#L254)).
The withdraw side carries the larger risk, because a filler can widen the discount,
yet it relies on an off-chain lens warning. Uniswap routers allow
`amountOutMinimum = 0`, but that is the caller protecting themselves; here a third
party (the filler) can move the price. Modules are not under the EIP-170 limit.
**Recommendation:** revert when `op == Withdraw ∧ maturity > block.timestamp ∧
bound == 0` (one comparison, mirrors `takeFloored`). This is BREAKING only for orders
that would already be flagged.

**Resolved 2026-10-06.** `ExactlyTakerModule._withdrawAtMaturity` now reverts
`ZeroMinAssets()` when `maturity > block.timestamp ∧ minAssetsRequired == 0` (before
the position read, so the venue is never reached); at/after maturity a zero floor
stays legal. `takeFloored` keeps the identical predicate as the lens's pre-signing
warning (NatSpec says so). No encoding/typehash change; the only orders that stop
filling are pre-maturity zero-floor fixed withdraws, which the lens already flagged.
Pinned by `test/security/PreMaturityZeroFloor.t.sol` (mock, no RPC; includes a fuzz
that the revert ⇔ `takeFloored == false`) and the Optimism fork suite
`test/audit/PreMaturityWithdraw.t.sol` (`test_preMaturity_zeroFloor_reverts`,
`test_atMaturity_zeroFloor_fillsAtFace`). `modules-exactly` 65/65.

### B16. Exactly repay on an already-closed position succeeds as a no-op — R/C

`if (principal + fee == 0 || maxAssets == 0) return;`
([ExactlyModules.sol:259](packages/modules/lending/exactly/src/ExactlyModules.sol#L259)).
Nothing is pulled, and the face stays with the maker. The other repay modules clamp
to `min(amount, debt)` (Euler, Liquity, Exactly floating), which is also a no-op at
zero debt. Aave reverts on zero debt, but within an order that would wedge the tail.
**Recommendation:** none.

### B17. `DustHandler.readAction` is untagged — R/D

[DustHandler.sol:74–89](packages/lib/src/DustHandler.sol#L74). An auth-tail word of
`1` reads as `Recycle`, which is benign (re-supply to the maker's own position, then
sweep) and needs the maker to sign it. It is inconsistent with the tagged
`readBalanceMode`.
**Recommendation:** add the tag at the next BREAKING module-encoding change, not on
its own.

### B18. `FunnelGrantModule` fixed-input only — R/C

`_prorate(item.amount)` cannot match an auctioned input, so such an order fails
closed. The sibling-grant overwrite is a Permit3 `approveTaker` plain-set, the same
semantics as Permit2's `approve`. Both are documented in the module NatSpec
([FunnelGrantModule.sol:83–90](packages/modules/bridge/src/funnel/FunnelGrantModule.sol#L83)).
**Recommendation:** none. Have the lens flag BUY / rising + funnel.

### B19. `FullFillGuard` items unusable with position-sized fills — R/C

The guard needs a slice known at signing time. A position-sized fill is defined by
not having one. Fails closed, and documented
([position-sized-fills.md:368](docs/position-sized-fills.md#L368)).
**Recommendation:** none.

### B20. Pre-fund over-delivery strands below the floor — R/D

Delta-verify accepts `>= amt` but records `outs[j] = amt`, so the excess sits on the
module singleton below `floorOf`
([PreFundGuard.sol:180–188](packages/lib/src/PreFundGuard.sol#L180)). Only the
over-delivering solver loses. The maker is unaffected.

**Deviation:** exact-output routers (SwapRouter02 `refundETH` / `sweepToken`, 0x
Settler's final-sweep pattern, **unverified** for Settler) give the excess back to
the payer. Here nothing can tell it apart from pre-existing balance, so it stays.
**Recommendation:** document where the stranded balance goes and who can recover it,
if anyone. Set `amountOutOffset` (typed callback) so routes deliver exactly.

---

## 5. Off-chain and operator (C21–C26)

### C21. Dropped tx keeps gas and inventory reservation for an hour — R/C

`pendingDropMs = 15 min`, budget window 1 h
([guard.ts:31–42](packages/beta-filler/src/guard.ts#L31)). A same-data speed-up may
have filled under another hash, so keeping the charge errs on the safe side. The
cost is under-use of the hot wallet for at most an hour.
**Recommendation:** none. Task 21 (a mined tx resolved as "replaced" on a flaky RPC)
is the open related issue and matters more.

### C22. 5 bps haircut on $1/$1 pairs and `MIN_PROFIT_RBTC = 0` — R/D

[config.ts:347–351](packages/beta-filler/src/config.ts#L347),
[route.ts:211](packages/beta-filler/src/route.ts#L211). Principal is protected
on-chain: `minOut = owed + grossUp(gas + profit)` on pull, `amountInMaximum` on
direct, Sushi `amountOutMin ≥ owed + cost`. So a mis-quote costs a revert's gas.

**Deviation:** with zero minimum profit, a fill that reverts costs gas and one that
succeeds earns ≈ 0, so expected value is negative unless the revert rate is near
zero. "$1/$1" assumes the peg holds: USDRIF trades about 55 bps off the MoC oracle
on the exit venue (task 15). Professional fillers price in a revert-rate buffer
(**unverified**; no public parameter to cite). The existing strike / backoff in
`guard.ts` covers repeat reverts on one order, but not a systematic quote bias across
orders.
**Recommendation:** alert, or bump the stable haircut automatically, when the
route-path revert rate over the hourly window passes a threshold. Keep
`USD_TOKENS` limited to tokens with a hard redemption path.

### C23. Sushi executors not pinned by default — R/D

The router (`tx.to`) **is** pinned, and tokens, `amountIn`, recipient and
`amountOutMin ≤ assumedAmountOut` are checked
([sushi.ts:126–144](packages/beta-filler/src/sushi.ts#L126)). An empty
`SUSHI_EXECUTORS` accepts any executor, with a start-up warning
([routeFiller.ts:140](packages/beta-filler/src/routeFiller.ts#L140)). The executor
receives `amountIn` from the RedSnwapper and must raise the solver's balance by
`amountOutMin`. It holds no sandbox approval. Worst case after a compromised API: it
keeps the spread above `amountOutMin`. The maker and the filler's principal are
safe.
**Recommendation:** set `SUSHI_EXECUTORS` in production `wrangler.toml`, and refuse
(not just warn) when `DRY_RUN=false` and the list is empty. Pinning costs nothing.

### C24. Inventory gas priced from one pool when `RBTC_PRICE_USD` is unset — R/C

`max(pool quote, RBTC_PRICE_USD)` ([README.md:259](packages/beta-filler/README.md#L259),
[filler.ts:139](packages/beta-filler/src/filler.ts#L139)). Without the fixed price,
a manipulated thin WRBTC pool can only make gas look cheaper. The loss is bounded to
the gas of the fills it admits. Off-chain spot pricing for gas is normal for bots.
**Recommendation:** set `RBTC_PRICE_USD` in production config so the `max()` floor
always applies.

### C25. `/status` exposes the RPC origin to admin — R/C

Origin only, never path or query ([do.ts:640–674](packages/filler-worker/src/do.ts#L640)),
behind `Authorization: Bearer ADMIN_TOKEN`
([index.ts:49](packages/filler-worker/src/index.ts#L49)). Reasons and logs go through
`redact()`. Keyed RPC providers put the key in the path, so the origin leaks nothing
secret.
**Recommendation:** none. Task 25 (redact before truncate) is the related open item.

### C26. `RouteSandbox` standing max approvals per (token, router) — R/C

`ensureApproval` sets `type(uint256).max` once per (token, target)
([RouteSandbox.sol:160](packages/solvers/src/aggregator/RouteSandbox.sol#L160),
[SafeTransferLib.sol:122](packages/core/src/utils/SafeTransferLib.sol#L122)). The
sandbox ends every call empty (`FLOOR = 0`). Targets are not allowlisted; only
operator-written routes reach it. The contract's own note
([RouteSandbox.sol:37–58](packages/solvers/src/aggregator/RouteSandbox.sol#L37)) says
the approvals are **not** worthless: a planted approval holder that gets control
mid-fill can take the spread (two PoCs in `test/RouteSandbox.t.sol`).

**Precedent (verified):** 0x Settler does the same thing. Its
`safeApproveIfBelow` sets `type(uint256).max` whenever the allowance is short, and it
does so for arbitrary `pool` targets in `Basic.sol` and a dozen bridge and RFQ
actions (0x-settler `src/vendor/SafeTransferLib.sol`, `src/core/Basic.sol`). Its
README draws the same line we do: Settler "does not hold TVL or allowances" from
users, so it "can be more lax with the calls that it makes"
([0x-settler](https://github.com/0xProject/0x-settler)). CoW lets solvers run
arbitrary interactions from `GPv2Settlement`, whose only target guard is
`!= vaultRelayer`, and its docs warn that "malicious solvers … can steal funds from
the settlement contract" ([docs.cow.fi settlement](https://docs.cow.fi/cow-protocol/reference/contracts/core/settlement)).
CoW's February 2023 loss of about $166k of buffers came from a solver-set max DAI
approval to an arbitrary-call contract. That is the exact failure the sandbox's own
note describes (secondary sources only; the CoW post-mortem could not be fetched).
1inch executors: unverified.

So the pattern is common practice, and so is its known failure. Our mitigation
matches CoW's: only gated authors may name targets.
**Recommendation:** keep the operator set small and immutable (it is). Add a
`revokeApproval(token, target)` operator call so a target found unsafe later can be
cut off without redeploying.

---

## 6. Ranked recommendations

1. **B13: market-order economics.** Lifetime exclusivity plus a 4-minute rest at the
   floor removes the competition the Dutch auction exists for. Makers pay the full
   50 bps, as the e2e shows. Shorten the rest or open the order after an exclusive
   window. Product-visible, and no contract change needed for the short fix.
2. **B8: late TAKE allowance burn under the default `ItemPolicy.ANY`.** A
   permissionless griefing vector of the same class the core already fixed for
   duplicate PULLs. Default the SDK to ORDERED for such orders and flag it in the lens.
   Not on the beta path (app signs `items = []`). **Resolved 2026-10-06** — with
   CANONICAL, not ORDERED (ORDERED leaves the PULL free); see B8.
3. **B15: Exactly pre-maturity withdraw with a zero floor.** Make it a module revert,
   mirroring the repay branch's `ZeroMaxAssets`. *Resolved 2026-10-06 (`ZeroMinAssets`).*
4. **C23 / C24: production config.** Pin Sushi executors and set `RBTC_PRICE_USD`.
   Configuration only.
5. **C22: revert-rate guard** for the zero-profit stable route.
6. **A6a: correct the OZ citation.** OZ moved to code-first in 5.1.0, so the
   NatSpec cites OZ for the opposite of what it now does. Cite Seaport / OZ ≤ 5.0
   instead, and put 7702 revocation guidance in maker docs. Keeping ECDSA-first is
   defensible. Switching to code-first would drop raw-key 7702 makers, as Permit2
   does.
7. **C26: `revokeApproval`** on the sandbox at its next redeploy.
8. **A4, B17, B20:** hygiene: gate demo signing out of production, tag `DustAction`
   at the next breaking encoding, document the pre-fund strand.

**Overall verdict.** The signature and authorization layer matches Permit2 / UniswapX
practice. Its one real deviation (ECDSA first) has precedent in Seaport and 1inch, but
it rests on an OZ citation that has been stale since OZ 5.1. Most
amount-path items are maker-favourable reverts with direct precedent. Three
accepted items are worse than common practice: B13 (an auction without competition),
B8 (a griefing path left open by the default), and B15 (a zero floor accepted where
the sibling branch refuses it). None puts principal at risk. B13 is the only one that
reaches beta users today.
