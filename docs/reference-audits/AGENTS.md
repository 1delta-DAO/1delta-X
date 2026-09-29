# AGENTS — navigating the reference audit corpus

This directory is the adversarial reading of the design: the published audit
corpus for this protocol class (signed limit orders settled by a permissionless
third party), distilled into reusable failure classes, plus the internal
findings ledger. It is reference material, not API docs — read it before
designing, auditing, or reviewing, and keep it accurate when you change code.

## The map

| File | Keys | Contents |
| --- | --- | --- |
| [README.md](README.md) | — | The entry point: the three jobs this corpus serves and the glossary. The same word means different things in 0x / CoW / UniswapX; read the glossary before anything else. |
| [failure-classes.md](failure-classes.md) | `C1…C15` | What has gone wrong **elsewhere**, as classes. Each is anchored to a published finding or live exploit and carries our verdict ("structurally prevented", "correct", "applies — accepted"). |
| [findings-ledger.md](findings-ledger.md) | `F1…F30` | What **we** found, all resolved, each with the regression test that pins it. Chronological; later entries build on earlier ones. |
| [reaudit-sweep.md](reaudit-sweep.md) | — | The generalised questions distilled from F13–F15 ("authorised once" vs. "authorised by what"; "refunded ⇒ harmless"). Sweep these, not the specific functions. |
| [signature-validation.md](signature-validation.md) | `S1…S7` | The published signature corpus vs. our position. |
| [corpus-v4-evk-rfq.md](corpus-v4-evk-rfq.md) | — | Second corpus: Uniswap v4, Euler EVK, Bebop RFQ. |
| [corpus-modular-protocols.md](corpus-modular-protocols.md) | — | Third corpus: modular signature-validating order protocols; the Balancer composition-bug lesson. |
| [permit2-forked-source.md](permit2-forked-source.md) | — | Fourth pass: ChainSecurity's Permit2 audit vs. our fork. |
| [corpus-2026-incidents.md](corpus-2026-incidents.md) | — | Fifth pass: the 2026 live incidents and the operational gap; names the non-injective cache-key shape. |
| [checked-and-clean.md](checked-and-clean.md) | — | The re-check checklist — re-run when the relevant code moves (module-dispatch selector scan, `forAmount` gating, the `matchSettle` item-op guard, …). |
| [sources.md](sources.md) | — | **The de-duplication ledger.** A protocol listed here has been read; one listed "no public audit report" has been searched. Check it before starting any research round. |

Companions, one level up: [`reference-bounties.md`](../reference-bounties.md)
(`B1…B14`, post-deployment bounty/incident corpus) and
[`edge-case-matrix.md`](../edge-case-matrix.md) (the internal state-space; every
`F` entry should be locatable as a cell in it). [`SECURITY.md`](../../SECURITY.md)
is the trust model and audit log.

## Cross-references

- Class keys are the shared vocabulary. "That's a C4" / "missed instance of F19"
  is a complete review comment; cite the key rather than re-explaining.
- Links across files are `file.md#anchor`; anchors are GitHub slugs (lowercase,
  spaces → `-`, punctuation dropped, underscores kept). Same-file links are bare
  `#anchor`.
- A finding's "generalised question" is the reusable part. When you fix a bug,
  ask the generalised question across the whole surface — the ledger's repeated
  lesson is "the rule was applied to N−1 of N call sites" (F19, G-1, G-6, H-1).

## When to read what

- **Designing a feature** → `failure-classes.md` first. Most classes are already
  load-bearing decisions (the price module returns a clamped *bump* because of
  C5; the solver callback runs through a trampoline because of C1). Name which
  class a piece of code answers, so it is not "simplified" back into the bug.
- **Reviewing a PR** → `failure-classes.md` + the relevant finding's "generalised
  question" in `findings-ledger.md` / `reaudit-sweep.md`.
- **Before an external audit** → `failure-classes.md` + `signature-validation.md`
  + `checked-and-clean.md`. An auditor arrives with this corpus in their head.
- **Touching signature / permit code** → `signature-validation.md` and
  `permit2-forked-source.md` (the latter audits the code we forked).
- **Researching new external audits/exploits** → `sources.md` first (dedup), then
  add the protocol to the relevant corpus file and a row to `sources.md`.

## The citation gate (do not break it)

`make docs-check` runs `tools/check-doc-citations.py`. It greps the tree for
`function test_*` / `function invariant_*` and fails if any backtick span in
these docs cites a test that does not exist.

- Every finding you add MUST cite the regression test that pins it, in backticks,
  exactly as declared. Citation forms the gate recognises:
  ```
  Suite:test_name     a specific test
  test_name           a specific test, suite implied by context
  test_prefix_*       a family (at least one must exist)
  ..._suffix          prefix elided from the previous citation
  ```
- If you rename or delete a test, update every doc citation in this directory or
  the gate goes red — that drift is itself the F13 failure mode the gate exists
  to catch.

## Style

- Keep the verdicts honest: "structurally prevented", "correct, with a standing
  hazard", "applies — accepted class", "not a vulnerability, comment fixed".
  The corpus exists to record *why the code looks the way it does*, including
  the deliberate trade-offs.
- New external findings get: the protocol + auditor + date, the mechanism, and a
  verdict against **this** codebase — not a bullet list of someone else's bugs.
