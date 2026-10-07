# Signature validation: address-binding review

**Date:** 2026-10-06
**Tree:** branch `audit-fixes-2026-09-30` at `0aa7338` plus the uncommitted working set
**Trigger:** a reviewer comment on "mismatching addresses" in the Permit3 and
Settlement signature validation. The comment text was not available, so this
review enumerates every seam where a signer, owner, spender, domain or witness
address is compared or bound, and states what each one actually checks.

- [1. Verdict](#1-verdict)
- [2. On-chain seams](#2-on-chain-seams)
- [3. Off-chain seams](#3-off-chain-seams)
- [4. Findings](#4-findings)
- [5. Asymmetries that are by design](#5-asymmetries-that-are-by-design)
- [6. Evidence](#6-evidence)
- [7. Recommended follow-ups](#7-recommended-follow-ups)

---

## 1. Verdict

**On-chain: no address mismatch.** Every signature path verifies against the
principal whose assets move (the order's maker, the permit's owner), and every
digest binds the contract that consumes it (through the EIP-712 domain, the
`spender = msg.sender` field, or the `SettlementOrder` witness). The hand-coded
typehash and selector literals in the assembly call sites were recomputed and
match.

**Off-chain: three liveness gaps, no funds at risk. All three FIXED 2026-10-06**
(tasks 01–02, `tasks/done/`): Layer 1 now checks taker spenders too and recovers with
`ecrecover` semantics through the shared `recoverEcdsa` (`packages/orderbook/src/ecdsa.ts`).
The original text follows as the record of what was found. All three sit in the
orderbook verifier's single-signature (`fillWithPermit`) announce path, which
was added in the 2026-09-30 remediation (A-FLEX-2). They let an order into the
book that the settler will refuse, or keep one out that it would accept. Two are
confirmed by proof of concept (section 4).

**Two asymmetries read like mismatches but are correct** (section 5): the
two-layer allowance model (ERC-20 approve to Permit3, book grant to Settlement)
and the permit witness being signed under Permit3's domain while naming the
Settlement.

---

## 2. On-chain seams

Each row names the address the signature is verified against and what else the
digest binds. "Verified against" is the `claimedSigner` handed to
`SignatureVerification.verify`, or the address compared to `ecrecover`'s output.

| # | Seam | Verified against | What the digest binds | Verdict |
|---|------|------------------|-----------------------|---------|
| 1 | `SignatureVerification.verify` ([SignatureVerification.sol:120](packages/core/src/permit3/SignatureVerification.sol#L120)) | `claimedSigner` | caller's digest | OK. ECDSA first (`signer != 0 && signer == claimedSigner`), then EIP-1271 on the **same** address, and only if it has code. A standard-length signature that recovers to someone else is final for a codeless signer (`InvalidSigner`). |
| 2 | Permit3 `permitBatch*` ([SignedPermits.sol:236](packages/core/src/permit3/SignedPermits.sol#L236)) | `owner` (caller-supplied) | batch, nonce, deadline, optional witness | OK. `owner` is not a digest field, but the signature itself binds it: the grants are written to `owner`'s books and only `owner`'s key (or 1271 wallet) can produce the signature. Permit2 model. Each leg's `spender` is maker-signed. |
| 3 | Permit3 `permitTake*` ([SignedPermits.sol:167](packages/core/src/permit3/SignedPermits.sol#L167), [:229](packages/core/src/permit3/SignedPermits.sol#L229)) | `owner` | module, ref, amount, **spender = `msg.sender`**, nonce, deadline, optional witness | OK. The consuming contract is folded into the hash, so a leaked signature is useless to any other caller. `keccak256(data) == permit.ref` is enforced before verification. Dispatch is `takeOnBehalf(owner, …)`. |
| 4 | Permit3 `SignatureTransfer` ([SignatureTransfer.sol:63](packages/core/src/permit3/SignatureTransfer.sol#L63), [:130](packages/core/src/permit3/SignatureTransfer.sol#L130)) | `owner` | permitted, **spender = `msg.sender`**, nonce, deadline | OK. Straight Permit2 port. |
| 5 | `Signatures._verifySignature` ([Signatures.sol:277](packages/core/src/settlement/Signatures.sol#L277)) | `order.maker` (`expected`) | order struct hash (or `OrderRoot`) under the Settlement domain | OK. Recovered signer must equal the maker ([:380](packages/core/src/settlement/Signatures.sol#L380)); otherwise the delegate registry is read as `orderSignerExpiry[maker][signer]` ([:386](packages/core/src/settlement/Signatures.sol#L386)), so a delegate can only authorize orders naming the maker who nominated it. The contract-delegate envelope reads the delegate address from the signature ([:423](packages/core/src/settlement/Signatures.sol#L423)) but still looks it up under the maker, and verifies `inner` against that delegate ([:429](packages/core/src/settlement/Signatures.sol#L429)). Everything else falls through to the shared verifier against the maker ([:442](packages/core/src/settlement/Signatures.sol#L442)). |
| 6 | `Signatures.setOrderSignerWithSig` ([Signatures.sol:205](packages/core/src/settlement/Signatures.sol#L205)) | `maker` | maker, signer, expiry, nonce, deadline | OK. Verified through the shared verifier, never through the delegated branch, so no re-delegation. |
| 7 | `Core.fillWithPermit` ([Core.sol:232](packages/core/src/settlement/Core.sol#L232), [:382](packages/core/src/settlement/Core.sol#L382)) | `order.maker`, passed to Permit3 as `owner` | PermitBatch + witness `SettlementOrder{address(this), orderHash}` | OK. The witness names this settler and the order hash commits to the maker, so the permit cannot be lifted onto another order or another Settlement sharing the same Permit3. No `_verifySignature` runs on this path; the Permit3 verification is the authorization. |
| 8 | `Core.fillWithPermitTake` / `Base._takeByPermit` ([Base.sol:1067](packages/core/src/settlement/Base.sol#L1067)) | `order.maker`, passed to Permit3 as `owner` | PermitTake + witness = bare `orderHash` | OK. The witness does not name the settler, and does not need to: Permit3 folds `spender = msg.sender` (this Settlement) into the digest. `PermitTakeNotConsumed` reverts a fill that never reached the permit-consuming TAKE. |
| 9 | `SettlementLens._verifySignature` ([SettlementLens.sol:1124](packages/periphery/src/SettlementLens.sol#L1124)) | `order.maker` | Settlement's own `DOMAIN_SEPARATOR()` ([:1144](packages/periphery/src/SettlementLens.sol#L1144)) | OK. Branch-for-branch mirror of row 5, including the first-fill skip, the bulk branch and the delegate envelope. |
| 10 | `FillerAttestationValidator._isValidAttestation` ([FillerAttestationValidator.sol:235](packages/validators/src/FillerAttestationValidator.sol#L235)) | `attester` from maker-signed validator data | on-chain `filler`, `listId`, `expiry` under the validator's own domain | OK. Same ECDSA-then-1271 ordering; returns `false` instead of reverting so AND-composition holds. |
| 11 | Domains | n/a | Settlement: `"Settlement"/"1"/chainid/address(this)`. Permit3: `"Permit3"/"1"/chainid/address(this)`. | OK. Both cache the separator and rebuild it when `block.chainid` changes. No signature is valid under both domains. |

### Hand-coded literals recomputed

| Literal | Where | Expected | Recomputed |
|---|---|---|---|
| `SETTLEMENT_ORDER_TYPEHASH` | [Core.sol:380](packages/core/src/settlement/Core.sol#L380) | `0xfa3f9753…853c0` | match (`cast keccak` over the full type string) |
| `permitBatchWithWitnessHashIfNeeded` selector | [Core.sol:385](packages/core/src/settlement/Core.sol#L385) | `0x6c837b2e` | match |
| `transferFrom(address,address,address,uint160)` | [Base.sol:329](packages/core/src/settlement/Base.sol#L329) | `0x9fc0d7da` | match |
| `isStrict(address,address)` | [Base.sol:343](packages/core/src/settlement/Base.sol#L343) | `0x339ea7a3` | match |

The EIP-712 type strings are consistent across the four places they appear
(`OrderHash.sol`, `Permit3Hash.sol`, the SDK's `eip712.ts`) and the hashers
encode fields in the order the strings declare them. `HashGolden.t.sol` and the
SDK fixture tests pin this.

---

## 3. Off-chain seams

| # | Seam | Compared to | Verdict |
|---|------|-------------|---------|
| 12 | Orderbook Layer 1, order path ([verify.ts:261](packages/orderbook/src/verify.ts#L261)) | recovered signer vs `order.maker` under `settlementDomain(config.settlement)` | OK. A non-maker signer is deferred to the lens (delegates), not rejected. The lens's `isSignatureValid` is still consulted at Layer 2, so a Layer-1 false positive cannot admit an order on this path. |
| 13 | Orderbook Layer 1, permit path ([verify.ts:233](packages/orderbook/src/verify.ts#L233)) | recovered signer vs `order.maker` under `permit3Domain(config.permit3)` with witness `{settlement: config.settlement, order}` | Domain and witness correct. **Three gaps:** taker-permit spenders unchecked (F1), `v ∈ {0,1}` accepted (F2), 64-byte signatures rejected (F3). Layer 2 trusts Layer 1 for this path ([verify.ts:608](packages/orderbook/src/verify.ts#L608)), so F2 is not caught downstream. |
| 14 | Soft-cancel verifier ([cancels.ts:99](packages/orderbook/src/cancels.ts#L99)) | recovered signer vs `cancel.maker`, then the settler's delegate registry under that maker, then the maker's own 1271 | OK. Mirrors row 5 branch for branch. Its `recoverEcdsa` ([cancels.ts:219](packages/orderbook/src/cancels.ts#L219)) enforces `v ∈ {27, 28}` exactly as `ecrecover` does. Eviction is further restricted to orders whose stored maker equals `cancel.maker`. |
| 15 | App deployment check ([chain.ts:43](packages/app/src/lib/chain.ts#L43)) | `Settlement.PERMIT3()` vs configured `permit3` | OK. The approve prompt is refused on a mismatch (closes audit G-TS_SIGN-14). |
| 16 | Beta filler solver check ([routeFiller.ts:124](packages/beta-filler/src/routeFiller.ts#L124)) | solver's wired Settlement vs configured | OK. |

---

## 4. Findings

All three findings are in [packages/orderbook/src/verify.ts](packages/orderbook/src/verify.ts),
Layer 1, permit path. None affects on-chain authorization: the maker signed the
batch, Permit3 re-verifies it on every fill, and a wrongly admitted order can only
sit in the book unfilled. Severity is liveness and book hygiene.

### F1. Taker-permit spenders are not checked against the settlement (low)

**Where:** [verify.ts:240](packages/orderbook/src/verify.ts#L240) iterates
`batch.tokens` only. `batch.takers` is never inspected.

**Effect:** a permit announce whose taker grant names a foreign spender passes
Layer 1 and is admitted. The token-leg check that exists has no negative test
either. On-chain the fill fails at the TAKE item unless the maker happens to hold a
standing taker grant for the settlement, and the book evicts the order on a later
sweep.

**PoC (confirmed):** a batch with `tokenPermit(settlement, …)` and
`takerPermit(0x…ff, …)` signed by the maker returns `ok: true` from
`verifyLayer1`; the same batch with the foreign address on the token leg returns
`"permit batch grants a spender other than this settlement"`.

**Fix:** apply the same `spender == settlement` test to `batch.takers`, and add a
negative test for both arrays.

### F2. Permit path accepts `v ∈ {0, 1}` signatures that `ecrecover` rejects (low)

**Where:** [verify.ts:245](packages/orderbook/src/verify.ts#L245) recovers with
viem's `recoverTypedDataAddress`. viem 2.54.3 normalises the last byte through
`toRecoveryBit`, which accepts `0`, `1`, `27` and `28`. The settler's
`SignatureVerification.tryRecoverSigner` passes `v` straight to `ecrecover`, which
returns `address(0)` for `0` or `1`, so Permit3 reverts `InvalidSigner`.

**Why Layer 2 does not catch it:** for a permit announce `toResult`
([verify.ts:608](packages/orderbook/src/verify.ts#L608)) sets
`isSignatureValid: true` unconditionally, on the reasoning that the lens cannot see
a Permit3 witness signature. The order path is protected because it still gates on
the lens's answer.

**Effect:** an order whose permit signature carries a yParity-style `v` is admitted
and reported `Fillable` on every sweep until it expires. Fillers simulate and fail.
A maker whose wallet emits `v = 0/1` in 65-byte form (some signers do) will see
its permit orders accepted by the book and never filled. Anyone holding a valid
permit signature can also re-announce it in yParity form under a distinct cache
key, though the book keeps the first-seen announce.

**PoC (confirmed):** a maker-signed permit witness with its last byte rewritten
from `0x1b` to `0x00` returns `ok: true` from `verifyAnnounce` against a lens that
reports the signature invalid. The identical rewrite on an order-path announce is
rejected with `"invalid signature"`.

**Fix:** recover both Layer-1 paths through `recoverEcdsa` from
[cancels.ts:219](packages/orderbook/src/cancels.ts#L219) over
`hashTypedData(permitWitnessTypedData(...))` (and `orderTypedData`), so Layer 1
accepts exactly what `ecrecover` accepts. Add a `v = 0` negative test on the
permit path.

### F3. 64-byte (EIP-2098) permit signatures are rejected at Layer 1 (info)

**Where:** [verify.ts:235](packages/orderbook/src/verify.ts#L235) requires exactly
65 bytes. Permit3 accepts 64-byte compact signatures
([SignatureVerification.sol:106](packages/core/src/permit3/SignatureVerification.sol#L106)).

**Effect:** a maker signing compact permits is kept out of the book although the
settler would fill. Liveness only.

**Fix:** falls out of the F2 fix, since `recoverEcdsa` already handles both
lengths.

### Reproducing the proofs of concept

The throwaway test used for F1 and F2 (not committed) was, in outline:

```ts
// packages/orderbook, vitest. `config`, `maker`, `orderFor`, `inADay` as in test/audit20260930.test.ts
const lens = (sigValid: boolean) =>
  ({ readContract: async () => [[OrderStatus.Fillable], [0n], [sigValid], [true]] }) as unknown as PublicClient;
const yParityForm = (sig: Hex): Hex => {
  const v = parseInt(sig.slice(-2), 16);
  return (sig.slice(0, -2) + (v - 27).toString(16).padStart(2, "0")) as Hex;
};

// F2
const batch = permitBatch([tokenPermit(config.settlement, TOKEN_A, 1000n, 4_000_000_000)], [],
  permit3Nonce(Permit3MessageKind.Batch, 1n), inADay());
const sig = yParityForm(await signPermitWitness(maker, batch, order, config));
const res = await new Verifier(lens(false), config, { batchWindowMs: 0 })
  .verifyAnnounce({ order, sig, permitBatch: batch });
// res.ok === true   ← settler: ecrecover(v=0) = address(0) → InvalidSigner

// F1
const foreign = "0x00000000000000000000000000000000000000ff";
const batch2 = permitBatch([tokenPermit(config.settlement, TOKEN_A, 1000n, 4_000_000_000)],
  [takerPermit(foreign, TOKEN_B, "0x" + "11".repeat(32), 1n, 4_000_000_000)],
  permit3Nonce(Permit3MessageKind.Batch, 2n), inADay());
const l1 = await verifier.verifyLayer1({ order, sig: await signPermitWitness(maker, batch2, order, config), permitBatch: batch2 });
// l1.ok === true
```

---

## 5. Asymmetries that are by design

These are the places a reader is most likely to flag as "mismatching addresses".
Each is intentional and documented in the code.

1. **ERC-20 approve names Permit3; the Permit3 book grant names Settlement.**
   [funding.ts:95](packages/app/src/lib/funding.ts#L95). Tokens are approved to
   the hub, and the hub's book is keyed by the contract that calls `transferFrom`
   on it, which is Settlement. Both are required; neither alone moves funds.
   [chain.ts:43](packages/app/src/lib/chain.ts#L43) refuses to prompt if the
   configured Permit3 is not the one Settlement is wired to.

2. **The permit witness is signed under Permit3's domain but names the
   Settlement.** Permit3's `verifyingContract` is Permit3, and an `Order` has no
   settler field, so the witness struct carries `settlement = address(this)`
   ([OrderHash.sol:144](packages/core/src/settlement/OrderHash.sol#L144)). Without
   it a redeployed Settlement sharing the same Permit3 could re-fill a finished
   order (closed in re-audit 2026-09-25).

3. **The PermitTake witness is the bare order hash.** No settler in the witness,
   because Permit3 already folds `spender = msg.sender` into every PermitTake
   digest ([Permit3Hash.sol:246](packages/core/src/permit3/libraries/Permit3Hash.sol#L246)).
   The two witness shapes differ because the two permit types bind the caller
   differently.

4. **The app signs under a zero-address domain when no deployment is
   configured.** [App.tsx:292](packages/app/src/App.tsx#L292). This is the
   simulated-book demo mode and is labelled "domain not deployed" in the UI. Such a
   signature authorizes nothing on any real Settlement.

5. **Delegate coverage is deliberately narrower on some paths (liveness only).**
   `fillWithPermit` accepts no delegate because Permit3 verifies against `owner`
   only. An EIP-7702 maker cannot use the contract-delegate envelope because its
   `code.length` is non-zero. A 1271 maker can bulk-sign only if its signature is
   exactly 65 bytes. All three are recorded in the NatSpec of
   [Signatures.sol](packages/core/src/settlement/Signatures.sol).

6. **ECDSA before EIP-1271.** A 7702 account's underlying key can always
   authorize even when its delegate would refuse. Accepted and documented at
   [SignatureVerification.sol:29](packages/core/src/permit3/SignatureVerification.sol#L29);
   OpenZeppelin's `SignatureChecker` makes the same trade.

---

## 6. Evidence

Test suites run on this tree, all green:

| Suite | Command | Result |
|---|---|---|
| Permit3 hub, hash golden, hash differential, encoding golden | `FOUNDRY_PROFILE=core forge test --match-path "packages/core/test/{Permit3,HashGolden,HashDifferential,EncodingGolden}.t.sol"` | 69 passed |
| Permit3 batch encoding, PermitTake blob, signature transfer, hub coverage | `FOUNDRY_PROFILE=core forge test --match-path "packages/core/test/permit3/*.t.sol"` | 43 passed |
| Bulk, compact, delegated signer, delegate revocation, witness settler binding, signature edge cases, Permit3 PoC, pull via Permit3, PermitTake dirty bits | `FOUNDRY_PROFILE=core forge test --match-path "packages/core/test/{swaps/BulkSignature,swaps/CompactSignature,swaps/DelegatedOrderSigner,swaps/DelegateRevocationResurrect,swaps/PermitWitnessSettlementBinding,swaps/SignatureEdgeCases,swaps/AuditPermit3PoC,utils/PullViaPermit3,audit/Audit20260930PermitTakeDirty}.t.sol"` | 92 passed |
| Orderbook hardening | `cd packages/orderbook && npx vitest run test/hardening.test.ts` | 30 passed |
| Orderbook verify, 2026-09-30 regressions, cross-component | `cd packages/orderbook && npx vitest run test/verify.test.ts test/audit20260930.test.ts test/crossComponent.audit.test.ts` | 48 passed |
| Proof of concept for F1 and F2 (throwaway, removed) | see section 4 | 3 passed (each asserting the gap) |

Constants recomputed with `cast keccak` and `cast sig` (section 2).

---

## 7. Recommended follow-ups

> **Status 2026-10-06: all done.** 1–3 landed with tests named after the findings
> (`test/audit20260930.test.ts`, SIG-REVIEW blocks; orderbook 143/143). 4 needed no
> change. Whether the §5 asymmetries match common practice (Permit2 / UniswapX) is
> assessed in `ACCEPTED-PATTERNS-REVIEW.md`.

1. **verify.ts:** check `batch.takers[i].spender` against the settlement next to
   the existing token check (F1).
2. **verify.ts:** replace both `recoverTypedDataAddress` calls with
   `recoverEcdsa(hashTypedData(...), sig)` so Layer 1 accepts exactly the
   `v` values and lengths the settler accepts (F2, F3). `recoverEcdsa` is already
   exported from `cancels.ts`.
3. **Tests:** negative cases for a foreign taker spender, a foreign token
   spender, a `v = 0` permit signature, and a positive case for a 64-byte permit
   signature.
4. **Optional:** have `toResult(permit = true)` keep trusting Layer 1 for the
   signature but record the lens's lifecycle verdict unchanged, which it already
   does. No change needed there once Layer 1 is exact.

None of these touch Settlement or Permit3 bytecode.
