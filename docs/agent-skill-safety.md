# Agent-skill safety policy

This document is the **operating policy** for adding agent skills and audit
tooling to this repository's workflows. It has two halves: what is *forbidden or
to be audited before use* (the safety measures), and what is *recommended to add*
(the skill manifest). It exists because agent skills and MCP servers execute with
the developer's authority, and the failure class that matters here is not a wrong
answer but a leaked key or a broadcast transaction.

Source of the risk register: [`awesome-solidity-skills`](https://github.com/gonzaloetjo/awesome-solidity-skills),
whose [`SECURITY_AUDIT.md`](https://github.com/gonzaloetjo/awesome-solidity-skills/blob/main/SECURITY_AUDIT.md)
reviews each listed tool for exactly this. The verdicts below are theirs, not ours;
we adopt them because they name a class none of the F1–F29 on-chain audits address.

## 1. Safety measures — the risk register

Any skill/MCP server in the **Dangerous** or **Unsafe** rows below must **not** be
installed, and if it is present it must be removed. The rule: a skill that can
reach a private key, mnemonic, or a mainnet-signing path from model context is out.

| Repository | Risk | Reason |
|------------|------|--------|
| `surfer77/evm-wallet-skill` | Dangerous | Generates and stores a private key at `~/.evm-wallet.json`; full hot-wallet control, mainnet-by-default across 6 chains. |
| `dcSpark/mcp-cryptowallet-evm` | Dangerous | Exposes private keys and mnemonics to LLM context via `wallet_get_private_key`. |
| `lienhage/blockchain-mcp` | Dangerous | Private key passed as a plaintext tool parameter; sends transactions on 7 mainnets. |
| `mcpdotdirect/evm-mcp-server` | Dangerous | Key/mnemonic via env vars across 60+ chains; HTTP mode binds `0.0.0.0`. |
| `PraneshASP/foundry-mcp-server` | Dangerous | Executes arbitrary Forge scripts and sends mainnet transactions with a configured key; no testnet enforcement. |
| `SkandaBhat/evm-agent-skills` | Dangerous | Defaults to Ethereum mainnet with `cast` signing/broadcast; very broad RPC permissions. |
| `kukapay/crypto-skills` | Unsafe | Token Minter deploys contracts requiring signing; write ops via "EVM Swiss Knife"; no testnet safeguards. |

**Standing rule** (the reason this list exists as a policy rather than a memory):
*before installing any agent skill or MCP server, read its source for key
handling.* A skill that writes a key to disk, reads `wallet_get_private_key`, or
broadcasts transactions without a testnet gate is rejected regardless of what it
claims to do. Review the source, not the README.

## 2. Recommended additions — the skill manifest

These are the skills the 2026-09-17 independent audit assessed as *incremental* —
they do something this tree's existing workflow (the F1–F29 ledger, the
`reference-audits.md`/`reference-bounties.md` corpus, the `test/invariants` suite)
does not already do. Order is by value against the current under-audited surface
(the **periphery** — lens, SDK, orderbook — which F29's first read found six
defects in, not core, which is at diminishing returns).

### 2.1 Static analysis (highest value)

Tooling-first: the ToB `static-analysis` skill is an orchestrator over CodeQL /
Semgrep / SARIF, and it is useless without the binaries.

```bash
# Slither — the canonical Solidity analyzer (this is the one to install first)
python3 -m venv ~/.audit-tools-venv
~/.audit-tools-venv/bin/pip install slither-analyzer

# Semgrep — pattern/grep-class detection (the B1/B3 byte-map + offset-drift class)
pip install semgrep          # or: python3 -m pipx install semgrep
```

**Where it pays:** `packages/periphery`, `packages/sdk`, `packages/orderbook`.
The offset/encoder-drift class (B1/B3 — a fixed-point scale truncating to zero, a
byte-map header disagreeing with its reader) is mechanically detectable and has
recurred in every sweep. Core is assembly-heavy and static analyzers are weakest
there — they will *confirm* the C1/C5/C6 structural claims, not find new bugs.

### 2.2 The Trail of Bits skills — corrected 2026-09-17

The first draft of this table named three plugins as "not yet installed". Checked
against the installed set (`~/.agents/skills`, symlinked from `~/.claude/skills`)
and the upstream `trailofbits/skills` tree (`123037e`), it was stale:

| Plugin | Status |
|---|---|
| `static-analysis` | **Already installed** — it is not one skill but three (`codeql`, `semgrep`, `sarif-parsing`), all present. |
| `fix-review` | **Does not exist upstream.** The discipline it was meant to name — verify a remediation closes the finding without opening another — is `post-patch-validation`, already installed. |
| `spec-to-code-compliance` | **Already installed.** |
| `semgrep-rule-creator` | **Installed 2026-09-17** (source reviewed for key handling per §1: none — it writes YAML and runs `semgrep`). This is the one that matters for the periphery: the generic registry packs found nothing there (§3), and the byte-map / offset-drift class needs rules written against this tree's own encoders. |

Install pattern (what the existing set uses — a plain copy, no clone kept):
`cp -r plugins/<plugin>/skills/<skill> ~/.agents/skills/<skill>` and
`ln -s ../../.agents/skills/<skill> ~/.claude/skills/<skill>`.

### 2.3 Corpus search

- **`BowTiedSwan/solodit-api-skill`** (MCP) — searches Cyfrin Solodit's published
  vulnerability database. A superset of this repo's hand-curated
  `reference-audits.md` (C1–C15) + `reference-bounties.md` (B1–B14). Marginal on
  core (the relevant corpus is already mined); useful as a one-time re-screen of
  the modules. Requires a Solodit/Cyfrin API key — keep the key out of the repo and
  out of model context.

### 2.4 Throughput (not discovery)

- **`nicofains1/evm-tx-debugger`** — Foundry-based failed-transaction debugging.
  No new findings; it converts leads into PoCs, which is this repo's bar for
  promoting a lead to a finding.

## 3. Where each lands

| Target | Run |
|---|---|
| `packages/core` | Nothing new — at diminishing returns; the invariant suite + the F-ledger cover it. |
| `packages/periphery` + `sdk` + `orderbook` | Slither + Semgrep + `entry-point-analyzer` + `spec-to-code-compliance`. **Swept 2026-09-17 with the generic packs — nothing** (see `audit-2026-09-17.md` §2); the next pass here is custom rules via `semgrep-rule-creator` over the packed-blob encoders (`sdk/src/packed.ts` ↔ `PackedArrays`), not another generic run. |
| `packages/modules/**` | Solodit one-time re-screen + `variant-analysis` over the B1/B3 shapes. |
