# Fifth pass — 2026 live incidents and the operational gap (2026-09-24)

The C1–C15 corpus and the B1–B14 bounty corpus were built through 2026-09-14. This
pass adds what the rest of 2026 turned up after that, plus the two largest losses of
the year, which the earlier passes had not yet recorded because their write-ups post-date
them. Everything here is a **live incident** rather than a published audit, so each entry
maps the incident onto the existing class keys rather than minting a new one — with one
exception: the Liquid Network's cache-key collision names a shape the C and B vocabularies
do not have, and it is called out as such.

**Method note.** Sources are the vendor post-mortems linked inline: BlockSec's weekly
incident reviews, TRM Labs, OpenZeppelin, and Hacken. Where a vendor page sits behind a
403 (as the Sources table flags for two older reports), the mechanism here comes from a
public post-mortem, not a re-derivation.

---

## Liquid Network — a cache key that did not bind what it attested (~$320M, 2026-09-06)

[BlockSec post-mortem](https://blocksec.com/blog/web3-security-liquid-network-symbiosis-exploits) ·
[Elements fix `94000967`](https://github.com/ElementsProject/elements/commit/94000967f6dc05b1afd435e79b1bbc597e29f816).

**Mechanism.** Elements (the node software under Liquid, a confidential-transactions
Bitcoin sidechain) caches verified rangeproofs so an output already checked in the
mempool is not re-checked on block arrival. The cache key was derived by hashing four
fields — the rangeproof, the value commitment, the asset generator, and the
`scriptPubKey` — concatenated into one SHA-256 stream with **no length prefix or
separator**, and two of the four fields are variable-length. Two *different* sets of four
fields can therefore concatenate to the *same* byte stream and land on the same entry;
whichever is validated first leaves a `valid` verdict the other collects. The attacker
crafted a primer output whose `scriptPubKey` bytes re-divided the stream so that a
second, inflated output's four fields concatenated identically — its proof (not a
rangeproof at all, and committing to a negative amount) was accepted without ever being
checked. 4,000 unbacked L-BTC left through the ordinary peg-out.

The sharpest form of the lesson: **a cache hit is a decision not to run the check.** When
the key does not injectively identify what was checked, the cache turns into a forgery
oracle.

**Here: correct, and this is the class to keep it correct** (re-derived from the tree in
[F30](findings-ledger.md#f30--re-audit-against-the-2026-09-24-corpus-additions-2026-09-25),
which corrected this paragraph's first wording). No cache key here can collide, but not
because every key is a fixed-width struct. `filled[orderHash]` and the approval maps
key on the EIP-712 order digest, whose six variable-length blobs are each hashed into
their OWN fixed slot before the struct hash — the length-commitment the Liquid key
lacked. The taker book keys on `ref = keccak256(data)` over an ARBITRARY-length,
maker-signed blob: injective because it is a SINGLE blob, and it would stop being so
the moment a second variable-length field were concatenated into it. The nonce bitmap
keys on `(maker, word)` and the delegate registry on the signer. The hazard is a
*future* cache or dedup map keyed by `abi.encodePacked` of two dynamic blobs (the
identifier-domain sibling of C2's hand-rolled calldata arithmetic), or a cache that
remembers *that* a check passed without remembering *what* it passed — which is F13's
generalised question, restated in the re-audit sweep. The rule: **an identifier derived
from more than one variable-length input must commit to the boundaries** (length-prefix
each field, or hash each into its own fixed slot), and it is sharpest wherever a cache
stands in for a check.

## Symbiosis — identity read from a field the depositor controls (~$770K, 2026-09-11)

[BlockSec post-mortem](https://blocksec.com/blog/web3-security-liquid-network-symbiosis-exploits) ·
[Symbiosis statement](https://x.com/symbiosis_fi/status/2099566361940795831).

**Mechanism.** Two off-chain flaws in the Bitcoin deposit path had to line up. The decoder
took the depositor's identity from a part of the transaction the depositor controls, so an
attacker could present as the portal's **administrator** and push the minimum portal fee
below zero. The mint amount was then computed by subtracting that fee from the deposit with
no check on the fee's sign — so a negative fee *enlarged* the deposit. A 330-satoshi deposit
minted `46,116,860,184.27 syBTC`, which the destination chain accepted because the MPC
signature over the request was genuine; what it authorized was a number off-chain code had
produced incorrectly. The pools it sold through held 11.26 syBTC, bounding the realized loss.

**Here: the trusted-identity half is already in the ledger as an external precedent for
F26's C-1.** `LiquityV2TroveAuth.authorizeTrove` derived both its ownership oracle and its
dispatch target from one caller-supplied address, and the fix rooted the chain at an
immutable registry. Symbiosis is the same shape one layer further out — the "root" was a
role recovered from depositor-controlled bytes rather than from the input's actual signer.
The standing rule carries over unchanged: **a privileged role can only be established by
something the depositor cannot choose.** The sign/`underflow` half is the C7/C22 family
(rounding and measurement): a value that is subtracted needs bounds on *both* sides, and the
amount minted must never exceed what the source chain actually received — the same "measured
delta, not a nominal amount" discipline the core applies at `_payInputsToSolver`.

## Drift — zero-timelock migration plus an oracle that trusted a manufactured asset (~$285M, 2026-04-01)

[TRM Labs](https://www.trmlabs.com/resources/blog/north-korean-hackers-attack-drift-protocol-in-285-million-heist).

**Mechanism.** Not a smart-contract bug. Social-engineered multisig signers pre-signed
"durable nonce" transactions that carried hidden authorizations; a Security Council
migration to a 2/5 threshold with **zero timelock** removed the detection window; then a
fictitious token (CarbonVote) with a few thousand dollars of seeded liquidity and wash
trading was listed as collateral because the oracle accepted a manufactured price with no
liquidity threshold, no TWAP, and no circuit breaker.

**Here: the two portable lessons map to existing posture, not to code.** (1) Zero-timelock
admin/governance is the operational sibling of C8's rule — when a degenerate or adversarial
configuration resolves, it must resolve *toward the defender*, never silently toward the
attacker; a timelock is that resolution made explicit. (2) The oracle half is C5/C14: the
core already refuses to let a maker-chosen price module move the price outside the signed
band, but a *venue* that accepts an unvetted asset as collateral is making a C14 assumption
about token value that no amount of on-chain arithmetic here can fix. Drift is recorded
because the corpus's own scope — "what has gone wrong elsewhere, and our verdict" — must
include the two largest losses of 2026 even where the failure was operational.

## KelpDAO / rsETH — a single-verifier bridge released a forged message (~$292M, 2026-04-18)

[OpenZeppelin](https://www.openzeppelin.com/news/lessons-from-kelpdao-hack) ·
[Chainalysis](https://www.chainalysis.com/blog/kelpdao-bridge-exploit-april-2026/).

**Mechanism.** The rsETH bridge ran LayerZero messaging on a **1-of-1 DVN** (single
verifier). Attackers poisoned the verifier's RPC infrastructure and injected a synthetic
message claiming 116,500 rsETH was locked on the source chain with no such transaction; the
verifier attested, and the `OFTAdapter` released the escrow. "Zero bugs found" — every
contract behaved exactly as written. Aave absorbed the downstream collateral damage.

**Here: this is the B12/F28 surface, but the failure was operational.** `BridgedOrderInbox`
already pins the refund beneficiary and expiry to the *first* credit (F28), which is the
on-chain half. The off-chain half — how many independent parties must attest before a
cross-chain message is accepted — is a deployment-time configuration the contract cannot
see. The standing rule from OpenZeppelin's post-mortem belongs in any integrator checklist:
**the worst-case outcome if one off-chain component is compromised must never be "all funds
move"; it should require the corruption of multiple independent parties.** LayerZero's own
response (no longer signing 1-of-1 configurations) is the proof that this was a config
choice, not a contract defect.

## Multicall router accepted its own address as a dispatch target (~2,900 aEthrsETH, 2026-09)

[BlockSec](https://blocksec.com/blog/web3-security-multicall-router-nostra-exploits).

**Mechanism.** A multicall router allowed `self` (its own address) as a dispatch target, so
a nested call reached a Safe's `Gateway` module carrying the router's **own already-authorized
identity** instead of the external caller's — routing ~2,900 `aEthrsETH` out of the wallet
into an attacker-created Uniswap v4 pool.

**Here: an external precedent for C1, one step removed.** C1 is "an arbitrary call made from
the settler's own identity"; this is the same shape in a multicall router, and the fix family
is identical: never let a caller-chosen `(target, data)` execute from a standing-authorized
identity, or pin the dispatch target so it cannot be `self`. The core already routes solver
callbacks through `SolverCallbackExecutor` (an approved spender for nobody) and pins module
dispatch to fixed selectors — the C1 posture holds. The re-check belongs in `checked-and-clean`:
any new multicall / router / aggregator surface must refuse `target == address(this)`.

## Notional V1 — an unchecked `uint128` cast valued a debt at zero (~$1.73M, 2026-09)

[BlockSec](https://blocksec.com/blog/web3-security-injective-aquifer-exploits).

**Mechanism.** An unchecked downcast of a large value to `uint128` wrapped to zero, and the
zero was treated as a valid debt amount.

**Here: the F26 Phase 2 class, in the wild.** The repo closed the same shape with
`@lib/Narrow160` (the `uint160`-clipped pull vs. unclipped approve) and the G-4 floor
arithmetic; `Permit3TransferLib` gates `amount <= type(uint160).max` and refuses the rest
rather than casting. Notional is the reminder that a width-cast that *wraps to a benign
value* (zero) is worse than one that reverts: it fails open and the zero propagates as truth.

---

## The rest of the same window (BlockSec weekly reviews, 2026-08-31 → 2026-09-20)

| Incident | Loss | Maps to | One-line mechanism |
| --- | --- | --- | --- |
| **Injective** | ~$4.8M | C2 / F22 | An insurance-fund identifier collided with a binary-options market identifier and the settlement path never compared their denominations — an identifier that did not bind what it attested, the Liquid shape on the ledger side. |
| **Aquifer** (Solana) | ~$2.47M | C1 | The swap path invoked an unvalidated caller-supplied Token Program. |
| **Nostra** (Starknet) | ~$3.5M borrowed | C5 / C14 | Oracle aggregation required only one source, so a manipulated thin-pool quote averaged with a normal one valued `NSTR` at ~$49.52 against overvalued collateral. |
| **Ankr FLOW** | ~$410K | C13 | A staking entry point skipped its pause guard and minted against a stale ratio. |

## Reference added this pass — Hacken, "19 Security Pitfalls in On-Chain Order Books"

[Hacken](https://hacken.io/insights/order-book-security-vulnerabilities/) (2025-11-14). A
curated checklist for spot DEX / perp / RFQ order books. It does not add a new class: every
one of its pitfalls lands in an existing key — front-running and transaction ordering (C4),
signature replay and missing domain separation (C3/S1–S6), partial-fill state consistency
(C6/C7), batch fault tolerance and single-order revert DoS (C6), reentrancy via fill hooks
(C1/C9), unbounded gas over global book operations (C9), time/expiration edge conditions
(C13), fee flags re-read at cancel time (C13), circuit breakers firing on one-sided books,
funding-fee synchronisation, single-snapshot liquidation (C5/C14), and quantity-vs-available
desynchronisation (C6/C7). Its value here is as a second, independent enumeration of the
orderbook surface — `packages/orderbook` — against the same class vocabulary.
