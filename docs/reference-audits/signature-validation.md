## Signature validation — the published corpus vs. our position

Compiled 2026-08-27 after [F13](findings-ledger.md#f13--a-revoked-on-chain-order-approval-was-bypassed-by-any-non-empty-signature),
because two of the three findings in that round were in signature handling and the
area clearly deserved a systematic pass rather than another one-off. Every row was
checked against the code; the ones that need a behavioural guarantee are pinned in
`packages/core/test/swaps/SignatureEdgeCases.t.sol`.

| # | Class | Our exposure |
|---|---|---|
| S1 | **ECDSA malleability** — `s` and `N − s` recover the same signer (EIP-2), and accepting BOTH the 65-byte and 64-byte EIP-2098 forms compounds it (the OpenZeppelin 4.7.3 advisory) | **Present by construction, benign.** `SignatureVerification.tryRecoverSigner` applies no lower-half-`s` check and accepts both lengths, so one authorisation has **four** valid byte encodings. Not exploitable: on-chain replay is bound by `filled[orderHash]`, and the off-chain book is a map keyed by `orderHash`, never by signature. Pinned by `test_malleability_fourEncodings_stillOneFill`. **The standing hazard is any NEW consumer that treats a signature as an identity** — a dedup cache, a "seen" set, a rate limiter keyed on `keccak256(sig)`. |
| S2 | **Cross-account EIP-1271 replay** (ERC-7739) — a digest that does not name the account is replayable across accounts sharing a validation rule | **Order & settlement paths immune via the WITNESS; standalone permit entrypoints carry raw Permit2's residual.** See the scoped assessment below — the earlier draft of this row overstated it as an open gap on the settlement path. Short version: none of Permit3's permit type strings bind an owner (owner is a verified argument, spender is bound — the exact Permit2 design), so at the RAW permit layer the ERC-7739 exposure is real for naive 1271 wallets. BUT the settlement path signs a `PermitBatchWitness` whose witness is the **order hash**, and {Order} binds `address maker`, so the digest is account-specific and a permit for wallet A cannot be replayed to a sibling wallet B. That is precisely the app-side binding Permit2 recommends (put the account in your witness), and we already do it. Pinned by `CrossAccountReplay.t.sol` (settlement path) and `test_crossAccountReplay_ordersBindTheMaker` (plain orders). |
| S3 | **Domain separator vs. chain id** — a cached separator survives a fork and enables cross-chain replay | **Clean.** `EIP712.DOMAIN_SEPARATOR()` serves the cached value only while `block.chainid` matches construction, else recomputes. Pinned by `test_domainSeparator_followsChainId`. |
| S4 | **Zero-address recovery** — `ecrecover` returns `address(0)` on failure, and a comparison without a zero check promotes every malformed signature to valid | **Clean.** `verify` requires `signer != address(0)` before matching; `setOrderSigner` separately rejects a zero delegate for the same reason. Pinned by `test_reject_invalidV` / `test_reject_zeroComponents`. |
| S5 | **Length-dispatch confusion** — deciding what a signature IS from its length | **Present and documented.** The bulk (Merkle) envelope is detected by shape (`length ≥ 98`, `(length − 66) % 32 == 0`, trailing `0xB0`). `Signatures` already argues why this is a liveness edge and never a bypass: any signature matching the predicate is re-read against a root the maker never signed and reverts. Wallets with attacker-influenceable trailing bytes are the residual exposure. |
| S6 | **EIP-1271 callee misbehaviour** — wrong magic value, revert, empty return | **Clean.** Pinned by the three `test_1271_*` cases. |
| S7 | **"Authorised once" caching** | **Was broken — [F13](findings-ledger.md#f13--a-revoked-on-chain-order-approval-was-bypassed-by-any-non-empty-signature).** See the sweep above for the generalised question. |

### S2 in full — where the account IS bound, and where it is not

Grounded in the code 2026-08-27, correcting an earlier overstatement.

**What Permit2 does (and we inherit verbatim).** None of Permit2's — or Permit3's —
signed permit structs contain an owner/`from` field. The owner is a function
argument the signature is *verified against*; what the struct binds is the
**spender** (`Permit3Hash.hash(permit, msg.sender)`), so a permit can only be
consumed by its intended spender. Cross-account replay for naive 1271 wallets is a
known, accepted residual whose defence Permit2 delegates two ways: **nonces**
(intra-account) and either **the wallet** (ERC-7739 defensive rehashing) or **the
app, via the witness** — `permitWitnessTransferFrom` exists so an app can commit the
account into the digest itself.

**The settlement path: closed, the Permit2-recommended way.** `_fillWithPermitCore`
calls `permitBatchWithWitnessIfNeeded(order.maker, batch, orderHash, …)`. The witness
is `orderHash`, and {Order} binds `address maker`, so the signed digest is
account-specific: reaching a sibling wallet B would require an order with
`maker == B`, a different witness, a different digest — one only B's owner could
produce. A permit signed for A therefore cannot drain B. The witness is doing the
exact job ERC-7739 asks an app to do, and `CrossAccountReplay.t.sol` pins it with a
vacuity guard proving the wallets really are the naive/replayable shape.

**The residual: standalone permit entrypoints.** Calling
`SignatureTransfer.permitTransferFrom` / `permitWitnessTransferFrom` or
`SignedPermits.permitBatchWithWitness` DIRECTLY — off the settlement path — passes an
attacker-choosable `owner`, and the non-witness variant commits no account at all.
That is identically Permit2's residual, further bounded by spender-binding: a drain
needs a **naive 1271 wallet** AND **multiple same-owner accounts** AND a
**malicious/compromised spender** all at once. Our stance matches Permit2's: this is
delegated to the wallet (ERC-7739); Safes and any wallet that rehashes with its own
domain are immune. Binding the account into the standalone structs would CLOSE it but
is a *divergence* from Permit2 — a breaking wire change, new golden hashes, and
hot-path hashing growth against a ~50-byte EIP-170 budget — worth it only if
naive-1271 makers are expected on the standalone entrypoints specifically.

**The naive 1271 wallet turned out to be one of ours** ([F30](findings-ledger.md#f30--re-audit-against-the-2026-09-24-corpus-additions-2026-09-25)).
`PositionFunnel` checks the owner's signature on the raw digest and trusted Permit3,
so every permit the owner key signed for its own EOA also verified for its funnel —
the residual above, with both "naive wallet" and "same-owner accounts" satisfied by
construction. Permit3 is no longer a built-in funnel consumer (explicit owner opt-in
only); pinned by `test_1271_permit3IsNotABuiltInConsumer`. **Rule:** any 1271 wallet
this repo ships must either rehash with its own address or not trust Permit3.

**The witness itself also had to name the SETTLER** (F30). Binding the maker made the
permit account-specific, but not settler-specific: Permit3's domain names Permit3, so
two Settlements on one Permit3 both accepted it. The witness is now
`SettlementOrder{settlement, order}`; see `test_permitWitness_filledOnV1_cannotBeReplayedOnV2`.

**What S1 and S2 have in common, and the rule to carry forward:** neither is a bug in
the verifier. Both are cases where *the digest does not commit to something the
security argument depends on* — the encoding in S1, the account in S2. When adding
any new signed message, write down what the digest commits to and check that against
what the code then assumes. `Order` gets this right by naming `maker`; the Permit3
batch types do not, and inherit Permit2's posture along with its code.

**Sources.** [ERC-7739: Readable Typed Signatures for Smart Accounts](https://eips.ethereum.org/EIPS/eip-7739) ·
[OpenZeppelin ECDSA / Cryptography docs](https://docs.openzeppelin.com/contracts/5.x/api/utils/cryptography) ·
[Zellic — "The ecrecover function allows malleable signatures"](https://reports.zellic.io/publications/orderly-network/findings/medium-signature-the-ecrecover-function-allows-malleable-signatures) ·
[Smart Contract Security Field Guide — signature attacks](https://scsfg.io/hackers/signature-attacks/) ·
[Zokyo — Signature Malleability](https://zokyo.io/blog/signature-malleability/) ·
[Dedaub — 0x Settler audit](https://dedaub.com/audits/0x/0x-settler-crosschainreceiverfactory-june-10-2025/) ·
[Auditor's Digest — the risks of EIP-712](https://medium.com/@chinmayf/auditors-digest-the-risks-of-eip712-5a0fc57e3837) ·
[*One Signature, Multiple Payments* (arXiv 2511.09134)](https://arxiv.org/pdf/2511.09134) ·
[*Demystifying and Detecting Cryptographic Defects* (arXiv 2408.04939)](https://arxiv.org/pdf/2408.04939)

---
