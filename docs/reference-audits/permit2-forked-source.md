## Fourth pass — the forked source's own audit (Permit2, 2026-08-27)

The one we should have read FIRST. `Permit3` ports Permit2's `SignatureVerification`,
`EIP712`, and the unordered-nonce bitmap close to verbatim (each file says so in its
header), so [ChainSecurity's Permit2 audit](https://old.chainsecurity.com/wp-content/uploads/2022/11/ChainSecurity_Uniswap_Permit2_audit.pdf)
is an audit of OUR code's ancestor. Read via `pdftotext`. Every transferable finding
turned out already handled and already pinned — the value of the pass is the
*confirmation*, and one strong external precedent for a row I had rated on my own.

| # | ChainSecurity finding | Our position |
|---|---|---|
| **6.1** | **HIGH — `Permit2Lib` argument casting.** A `uint256 amount` silently cast to `uint160` for the Permit2 leg: `uint160(2**170) == 0`, the call "succeeds" moving nothing, and the caller believes the transfer happened. Fixed in Permit2 with a SafeCast that reverts | **Clean, and handled more gracefully than the upstream fix.** `Permit3TransferLib.transferFromWithFallback` does NOT cast — it GATES: `amount <= type(uint160).max` uses the Permit3 leg with the in-range value, and anything larger is REFUSED outright with `Permit3Denied`. No truncation path exists. Pinned by `test_amountExceedsUint160_reverts`, which asserts the hub is never called AND that nothing moved — i.e. the book is not routed around. This is STRICTER than it used to be: the oversize case previously fell through to a full-`uint256` direct `safeTransferFrom`, which silently skipped the book's cap, expiration, `revokeToken` and `lockdown`. A future "optimisation" to `uint160(amount)` would reintroduce 6.1 and break that test. |
| **7.1** | **NOTE — nonce overflow via unchecked increment** of the sequential allowance nonce (`uint16`/`uint48`) | **Structurally absent.** Permit3 REMOVED the sequential allowance nonce (`AllowanceTransfer.sol:38`): grants zero the field instead of incrementing it, and replay is stopped by the unordered bitmap alone. `invalidateNonces` / `ExcessiveInvalidation` have no analogue, so neither does the overflow. |
| **7.2** | **NOTE — signature malleability if misused.** The library accepts EIP-2098 compact AND 65-byte forms and performs no Appendix-F low-`s` check (`0 < s < n/2+1`); *"any reuse of the SignatureVerification library must be done with this attack in mind. OpenZeppelin had such an incident before."* Permit2 is safe only because it binds replay to NONCES, not to the signature | **This is the direct external precedent for [S1](signature-validation.md#signature-validation--the-published-corpus-vs-our-position).** It describes our forked library exactly — the missing low-`s` check is inherited, not introduced. We are safe for the same structural reason Permit2 is: order replay binds to `filled[orderHash]` and the book keys by `orderHash`, never by signature bytes. `SignatureEdgeCases.t.sol`'s four-encoding test is the assertion. Having the SOURCE auditor independently name the exact hazard, and the exact reason it is benign, is the strongest confirmation S1 could get. |
| **7.3** | **NOTE — `invalidateUnorderedNonces` accepts `wordPos` up to `uint256.max`, but a usable nonce only reaches `uint248.max`**, so one can invalidate nonces that can never be used | **Same note applies, same harmless verdict.** Our `nonce >> 8` word derivation caps a usable word at `2**248 - 1`, while `invalidateUnorderedNonces(wordPos, mask)` takes a full `uint256` word. Self-invalidation only (keyed by `msg.sender`), so the worst case is a user wasting gas on their own unreachable words. Inherited verbatim; recorded so it is not "rediscovered" as a finding. |
| **5.1** | **MEDIUM (risk-accepted) — approval race**, the ERC-20 `approve` front-run, with `lockdown` offered as the batch mitigation | Same posture, already in our ledger: this is the [C12](failure-classes.md#c12--revocation-that-does-not-revoke) / [F1](findings-ledger.md#f1--revoking-permit3-is-not-a-kill-switch-on-its-own) family, and Permit3 carries the same `lockdown` / `lockdownAll` escape hatch (`permit3-audit-fixes` memory). |
| **6.2** | LOW — `Permit2Lib` reads `DOMAIN_SEPARATOR()` via `CALL` not `STATICCALL`, allowing reentrancy | N/A — we have no `Permit2Lib` analogue; `EIP712` exposes `DOMAIN_SEPARATOR()` as `view` and `_hashTypedData` reads it internally. |

**The takeaway for the process, not just the code:** when a component is forked, its
upstream audit is the highest-value document in the corpus and should be read before
any peer protocol — it audits *your* logic, not an analogue. Reading it last was the
mistake; the finding that it changed nothing is the good outcome.

### Queue additions from this pass

*deBridge DLN and 0x Settler were read 2026-09-24 — see
[the third corpus](corpus-modular-protocols.md#read-this-round-2026-09-24--the-queued-intent-settlers-and-modular-dexes).*

| Protocol | Audits | Note |
|---|---|---|
| **Aggregator routers** (1inch AggregationRouterV6, KyberSwap MetaAggregationRouter, Odos) | various | Permissionless-router allowance-drain class ([C1](failure-classes.md#c1--arbitrary-call-made-from-the-settlers-own-identity)); only worth the time if we add a generic-call surface beyond the current gated modules. |

---

---
