# CoW Protocol × Aave v3 — how excess / dust is handled in repay-with-collateral & swap flows

Reference notes for the dust-handling design in this repo (`src/dust/DustHandler.sol`,
`offchain/chooseDustAction.ts`). Captures how the **CoW × Aave** integration handles
the over-repay / leftover problem so we have the prior art at hand.

> Status: distilled from public docs + adapter source (Dec 2025 integration). Where a
> detail wasn't pinned down in the docs, it's flagged as such. Verify against current
> contracts before relying on a specific revert string or storage layout.

---

## 1. What the integration covers

Aave routes its **asset swap, collateral swap, debt swap, and "repay with collateral"**
actions through CoW Protocol's batch-auction settlement instead of doing them inline.
The user signs an intent; CoW solvers compete to fill it; execution is atomic
(all-or-nothing). Benefits cited: better price via solver competition, MEV protection.

Fee schedule (informs which surplus is "expected"):
- **Debt swaps:** 0 bps.
- **Correlated pairs** (e.g. ETH/wstETH): 15 bps.
- **Everything else:** 25 bps.

A new piece of the integration is an **intent-based flash loan** product: a flash loan
designed to be consumed inside CoW settlement, which is what makes
"repay debt with collateral" expressible as a single signed order.

Sources: [Aave × CoW Swap announcement](https://aave.com/blog/aave-cow-swap),
[Aave v3 swap features](https://aave.com/docs/aave-v3/smart-contracts/swap-features).

---

## 2. Flash-loan settlement mechanics (repay-with-collateral)

The canonical "repay my Aave debt using my collateral" flow:

1. **Solver triggers the flash loan router.** Borrowed funds (the debt asset) are sent
   to the router / made available to settlement.
2. **Pre-hooks execute** as the user (via COWShed, see §4): repay the outstanding Aave
   debt with the flash-loaned debt asset; this frees the associated collateral so it
   can be withdrawn.
3. **The swap happens** in the CoW batch: the freed collateral is swapped to the debt
   asset.
4. **Post-interaction repays the flash-loan provider** from settlement proceeds.

Key invariant: **the order's `receiver` is always the settlement contract**, "to let the
protocol handle repaying the appropriate amount for you" — the driver takes exactly the
flash-loan repayment from settlement, and the user never has to wire funds back manually.
It's the solver's responsibility that the flash loan is fully repaid within the same tx.

Sources: [CoW flash-loans tutorial](https://docs.cow.fi/cow-protocol/tutorials/cow-swap/flash-loans),
[CoW flash-loans / how-it-works](https://docs.cow.fi/cow-protocol/concepts/flash-loans/how-it-works),
[Repay debt with collateral using flash loans](https://docs.cow.fi/cow-protocol/concepts/order-types/pay-debt-flash-loans).

---

## 3. The three dust strategies (the core of it)

The over-repay / leftover problem is attacked from **three complementary angles**. The
integration picks per context.

### (a) Exact-OUT (buy) swap — kill dust on the OUTPUT side

The CoW order is a **buy order**, not a sell order: the **buy amount is set to the exact
flash-loan repayment = borrowed amount + the 0.05% Aave flash-loan premium**. The solver
must produce *exactly* that; the swap consumes a *variable* amount of the input
collateral.

> "the exact amount needed to repay the flash loan (it must be sufficient to complete the
> transaction; otherwise, the transaction will revert!)"

Aave's debt-swap adapter says the same about the protocol leg: it swaps to the underlying
of the **current debt** via an exact-out swap — "it will receive `1000 BUSD`, but might
only need `1000.1 USDC` for the swap." So the output is exact (no output-side dust), and
any leftover lands on the **input** side.

### (b) Recycle the INPUT leftover back into the position — not the wallet

The unused input is returned to the most useful place: the user's own position.

- Aave's `ParaSwapRepayAdapter` computes `collateralBalanceLeft = collateralAmount -
  amountSold` and, if `> 0`, **re-supplies it to Aave on behalf of the user** (rather than
  transferring to their EOA).
- The **debt-swap adapter** does the analogous thing: leftover new-debt asset (`9.9 USDC`
  in their example) is used to **repay part of the freshly created target debt**.

Principle: *unused input is recycled into the position, keeping capital productive and the
adapter empty.*

### (c) Sweep the unavoidable remainder to the user

Whatever can't be recycled goes back to the user. CoW's docs acknowledge:

> "Some USDC may remain in the user's wallet as surplus"

…when swap proceeds exceed the flash-loan repayment. Because `receiver = settlement`,
settlement keeps exactly the repayment and the surplus is swept to the user (their COWShed
proxy / wallet) — settlement itself retains nothing.

---

## 4. COWShed — where funds live mid-settlement

Pre-hooks run through **COWShed**: a user-owned **ERC-1967 proxy deployed at a
deterministic address** per user. It's what holds funds during the multi-step settlement
and ends owned by the user, so anything left in it is theirs. This is the structural
reason "leftover ends up safely with the user" rather than stranded in a shared contract.

---

## 5. Security lesson — the ParaSwap repay-adapter hack

Aave's older `ParaSwapRepayAdapter` had a vulnerability rooted in **dust + shared-adapter
custody**:
- On a buy (exact-out) swap, if the adapter received more than the exact buy amount, the
  excess was treated as **dust and left in / donated to the adapter contract**.
- `_buyOnParaSwap` approved `assetToSwapFrom` for `maxAmountToSwap` but made an arbitrary
  external call on a different amount embedded in `paraswapData` — an approve-vs-call
  amount mismatch on a data-supplied target.

Combined, leftover dust resting in a shared adapter that also makes arbitrary approved
calls became an attack surface.

**Takeaway for us:** never let residue rest in a shared module across the tx boundary, and
be very careful approving + calling data-supplied targets while holding funds. (This is
exactly the concern behind gating our maker modules — see the note in
`src/dust/DustHandler.sol` and the repay-module discussion.)

Source: [Verichains — Aave ParaSwap Repay Adapter hack](https://blog.verichains.io/p/aave-paraswap-repay-adapter-hack),
[aave/aave-debt-swap](https://github.com/aave/aave-debt-swap).

---

## 6. How this maps onto our setup

| CoW × Aave technique | Our equivalent | Notes |
|---|---|---|
| (a) Exact-out buy = exact repayment | **pull-exact repay**: read live debt on-chain, pull `min(amount, debt)`; Morpho repays by *shares* via `onMorphoRepay` | We do better than (a): we never overshoot the repay, so there's no output-side dust to begin with. |
| (b) Recycle leftover into the position | **`DustAction.Recycle`** in `DustHandler` — re-supply surplus into the user's position, best-effort with a sweep fallback | Their re-supply can revert (cap/frozen/non-depositable); we made it best-effort with `try/catch`→sweep, which they don't document. |
| (c) Sweep remainder to user | **`DustAction.SweepToUser`** (default) — surplus lands in the maker's wallet (solver pays `tokenOut` straight to the maker) | This is our default and is the no-dust-in-module posture. |
| `receiver = settlement`, driver takes exact repayment | settlement pays `tokenOut` to maker, repay module pulls only what's needed; `_payTokenInToSolver` drains exactly | Equivalent "settlement keeps nothing" property. |
| Don't strand dust in a shared adapter (hack lesson) | module ends empty every call (`nonReentrant` + end-of-call dispose); **open item:** gate `makeOnBehalf` to Settlement so the over-pull + approve-data-target path can't be abused on a direct call | The ParaSwap hack is the precedent for taking that gate seriously. |

### Net

CoW × Aave don't have a magic trick: they (a) make the **swap output** exact via exact-out
buy orders, (b) **recycle leftover input back into the position**, and (c) sweep the
unavoidable remainder to a user-owned proxy, never leaving it in a shared contract. Our
pull-exact repay already beats (a); our `DustAction` policy adds (b)/(c) with an explicit
best-effort + fallback that the Aave adapters leave implicit; and the open module-gating
work is the direct application of the ParaSwap-hack lesson.

---

## Sources

- [Aave Labs partners with CoW Swap](https://aave.com/blog/aave-cow-swap)
- [CoW — Repay debt with collateral using flash loans](https://docs.cow.fi/cow-protocol/concepts/order-types/pay-debt-flash-loans)
- [CoW — Flash loans tutorial](https://docs.cow.fi/cow-protocol/tutorials/cow-swap/flash-loans)
- [CoW — Flash loans, how it works](https://docs.cow.fi/cow-protocol/concepts/flash-loans/how-it-works)
- [aave/aave-debt-swap (BGD debt-swap adapter)](https://github.com/aave/aave-debt-swap)
- [Aave v3 swap features](https://aave.com/docs/aave-v3/smart-contracts/swap-features)
- [Verichains — Aave ParaSwap Repay Adapter hack analysis](https://blog.verichains.io/p/aave-paraswap-repay-adapter-hack)
