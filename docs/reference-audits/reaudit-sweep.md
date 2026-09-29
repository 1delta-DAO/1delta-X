## Re-audit sweep — the generalised questions from F13–F15

F13–F15 are three instances of two reusable mistakes. Sweep these questions rather
than the specific functions.

**1. "Authorised once" is not "authorised by what".** Any cache, skip or fast path
that remembers *that* a check passed, without remembering *which* credential passed
it, is F13. The credential that can be **withdrawn** is the one that matters: a
signature cannot be, an on-chain record and an EIP-1271 answer can. Where to look:

- every early `return` in `Signatures._verifySignature` and anything reading `filled`
  as an authorisation proxy;
- the **batch paths** — `batchFill`, `matchSettle`, `_openGated` — which take a `sigs[]`
  array per order. Does each element go through the same branch selection, and can a
  caller mix an empty and non-empty `sig` for the same order across calls?
- the 7683 entrypoints (`open`/`openFor`), which authorise by a different route than
  `fill` — cf. [F11](findings-ledger.md#f11--open-announced-an-erc-7683-order-without-the-signature-check-openfor-performs);
- delegated signers (`orderSignerExpiry`): an expiring delegate is a *withdrawable*
  credential, so ask whether expiry binds mid-order or is skipped after a first fill;
- contract signers generally — the file already flags that a 1271 wallet turning
  `false` no longer blocks a part-filled order. That is documented and accepted for
  signatures; confirm no *other* revocable credential inherits the same skip silently.

**2. "Refunded ⇒ harmless" ignores non-refundable side effects.** F15's real lesson:
when a step over-consumes and a later phase gives it back, ask what was spent that the
refund does **not** restore. Allowance is the obvious one; also nonces, one-shot
permits, rate-limit budgets, expiries, and any ledger keyed off cumulative spend.
Where to look:

- every repeated-step tolerance in `matchSettle`. `DELIVER` and `ITEM` have
  exactly-once guards; `PULL` did not. Re-derive the argument for any step added later,
  and state it in terms of *authority consumed*, not tokens moved.
- anywhere the code says a duplicate/surplus is "returned to the maker" — that phrase
  is about assets, and is not an argument about allowances;
- `Permit3TransferLib.transferFromWithFallback`: a failed Permit3 leg that falls back
  to a direct approval spends the *approval* instead — check which budget each path
  draws down;
- the `uint160.max` infinite-allowance sentinel is a **masking** condition. Any test
  that grants max allowance cannot observe this class of bug; assert against a finite
  allowance when the property under test is "how much authority did this consume".

---
