# Reference audits and common pitfalls

The published audit corpus for this exact class of protocol — signed limit orders
settled by a permissionless third party — is small enough to read end to end, and
it repeats itself. The same fifteen shapes account for essentially every High and
Medium finding across 1inch, 0x, CoW Protocol, UniswapX and Velora, plus both of
the live incidents.

This note is that corpus, distilled into failure **classes** rather than a list of
other people's bugs, with a verdict for each against this codebase and a ledger of
what we changed in response. It exists for three jobs:

- **Before writing a feature** — the classes are the design constraints. Most of
  them are already load-bearing decisions here (the price module returns a *bump*,
  not an amount, because of C5; the callback runs through a trampoline because of
  C1). Knowing which finding a piece of code is answering stops it being
  "simplified" back into the bug.
- **Before an external audit** — an auditor arrives with this corpus in their head.
  Everything here is a question they will ask; having the answer written and
  measured is the difference between a finding and a note.
- **When reviewing a PR** — the class keys `C1…C15` are a shared vocabulary.
  "That's a C4" is a complete review comment.

**Related:** [`/SECURITY.md`](../../SECURITY.md) is the reporting policy and trust
model. This note is the adversarial reading of the design.
[`reference-bounties.md`](../reference-bounties.md) is its post-deployment twin: what
bug bounties and live incidents found at the same protocols and at the venues our
modules drive — a different distribution (units, offsets, encoder/interpreter
drift, periphery), with its own class keys `B1…B14`. The
[settlement README](../../packages/core/src/settlement/README.md) is the API.
[`edge-case-matrix.md`](../edge-case-matrix.md) is the other half of this note: where
this one asks *what has gone wrong elsewhere*, that one asks *what combinations
exist here* — the F-ledger entries below should each be locatable as a cell in it,
and the ones that are not mean the matrix is missing an axis.

---

## Glossary

The vocabulary is not shared across protocols — the same word means different
things in 0x, CoW and UniswapX, and this codebase borrows from all three. These
are the senses used throughout the repo.

| Term | Sense used here |
| --- | --- |
| **Maker** / *swapper* | The party who signs the order. Never sends the transaction. `swapper` in UniswapX. |
| **Filler** / *taker*, *solver*, *resolver* | The party who executes. `resolver` in 1inch Fusion, `solver` in CoW, `filler` in UniswapX. One role: supplies the counter-side, pays gas, keeps the surplus. |
| **Settler** | The contract that verifies the signature and moves funds. The most privileged address in the system, because every maker approves it. |
| **Intent** | A signed statement of *outcome* ("I want ≥ X out"), not a route. |
| **Dutch decay / bump** | A price moving against the maker over time. Normalised here to one shared `bumpBps ∈ [0, 10000]` per order, mapped through each leg's own signed `start`/`end`. |
| **Anchor** | The fill denominator — the fixed side's leg 0, or a signed `fillTotal`. `filled[orderHash]` counts in anchor units. |
| **Partial fill** | Executing a fraction of a signed order. The source of a disproportionate share of real findings — gates and rounding written for the whole often break on the slice. |
| **Overfill** | Executing more in aggregate than the maker signed for. 0x v4's audit carried non-overfillability as a stated invariant. |
| **Interaction / callback / hook** | An arbitrary call the settler makes mid-settlement. The richest vulnerability surface in this class. |
| **Amount getter / price module** | An external contract consulted for the price. In 1inch LOP an amount getter **is** the price; here an `IPriceModule` returns only a clamped bump. |
| **Validator / invariant** | A read-only precondition (pre-items) or postcondition (post-items) the maker attaches. AND-composed. |
| **Exclusivity window** | A period in which only a nominated filler may execute. *Hard* blocks everyone else; *soft* admits them against a price improvement paid to the maker. |
| **Coincidence of wants / netting** | Matching N orders against each other so no filler capital is needed. `matchSettle` here. |
| **Allowance hub** | Permit2 / Permit3 — a shared approval registry. Concentrates convenience and blast radius alike. |
| **Witness permit** | A permit signature that also commits to an application payload (here, the order hash), so one signature authorises both the pull and the trade. |
| **Nonce invalidator / rollback** | Bulk cancellation. 0x's `minValidSalt`, `rollbackNonces` here. |
| **Delta verification** | Requiring a measured balance increase rather than pushing a nominal amount. The correct answer for fee-on-transfer outputs. |
| **Surplus / residue** | What is left in the settler after every obligation is met. Whoever it is swept to is being paid, so that must be a deliberate decision. |
| **Priority auction** | Bidding for the fill in priority fee rather than in time, relying on the sequencer to order by tip. |

---

## How this corpus is split

The note was one ~2,000-line file; it is now split for reading. The class keys
are the cross-file vocabulary: a `C` link points into `failure-classes.md`, an
`F` into `findings-ledger.md`, an `S` into `signature-validation.md`. Anchor
links across files are written `file.md#anchor` (GitHub slugs).

| File | What it is | Read it when |
| --- | --- | --- |
| [failure-classes.md](failure-classes.md) | `C1…C15` — the fifteen failure classes, each anchored to a published finding or live exploit, with our verdict. | Designing a feature; reviewing a PR ("that's a C4"). |
| [findings-ledger.md](findings-ledger.md) | `F1…F32` — every internal finding with the regression that pins it; all resolved except F32 (fixes and docs merged; independent verification and the final gate pending). | Chasing a bug's history; before an external audit. |
| [reaudit-sweep.md](reaudit-sweep.md) | The generalised questions distilled from F13–F15. | Sweeping a new surface; re-checking authorisation / refund logic. |
| [signature-validation.md](signature-validation.md) | `S1…S7` — the published signature corpus vs. our position. | Touching `Signatures`, `SignatureVerification`, or the 1271 path. |
| [corpus-v4-evk-rfq.md](corpus-v4-evk-rfq.md) | Second corpus — Uniswap v4, Euler EVK, Bebop RFQ. | The modular / venues read. |
| [corpus-modular-protocols.md](corpus-modular-protocols.md) | Third corpus — modular signature-validating order protocols; the Balancer lesson. | The composition-bug argument. |
| [permit2-forked-source.md](permit2-forked-source.md) | Fourth pass — ChainSecurity's Permit2 audit vs. our fork. | Touching Permit3 or the ported signature code. |
| [corpus-2026-incidents.md](corpus-2026-incidents.md) | Fifth pass — the 2026 live incidents (Liquid, Symbiosis, Drift, KelpDAO, …) and the operational gap. | Post-2026-09-14 incidents; the non-injective cache-key shape. |
| [checked-and-clean.md](checked-and-clean.md) | The re-check checklist — what to re-run when the relevant code moves. | Any change to dispatch, funding, or sweep code. |
| [sources.md](sources.md) | The de-duplication ledger of reports read / searched. | **Before starting any new research round.** |

Siblings in [`../`](../): [`reference-bounties.md`](../reference-bounties.md)
(`B1…B14`, the post-deployment twin) and
[`edge-case-matrix.md`](../edge-case-matrix.md) (the internal state-space).
