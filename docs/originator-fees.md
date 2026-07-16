# Originator Fees (Order-Sourcing Fee)

How the party that *sources* an order — a frontend, wallet, aggregator, or any
integrator that brings the user — earns a fee on it, and how that composes with
lending flows such as "deposit for the user, charge an interest margin on
withdrawal".

The mechanism is a single optional field on the signed order: `Order.feeConfig`.
There is **no global fee switch, no protocol fee registry, and no governance
surface** — every fee is maker-signed, per-order, and routed directly to the
recipient the maker consented to.

---

## 1. The mechanism

### Encoding

`feeConfig` is one `bytes32`, packed by `FeeConfig` (`core/src/utils/FeeConfig.sol`):

```
bits   0..159  → fee recipient (address)   — low 20 bytes
bits 160..255  → fee in bps    (uint96)    — high 12 bytes

bytes32(0)     → no fee
```

```solidity
order.feeConfig = FeeConfig.pack(feeRecipient, feeBps);
```

or off-chain (the SDK carries the field as a plain `bytes32`):

```ts
const feeConfig: Hex = `0x${((feeBps << 160n) | BigInt(recipient)).toString(16).padStart(64, "0")}`;
```

Because `feeConfig` is part of the `Order` EIP-712 typehash, it is inside the
maker's signature: a solver **cannot add, remove, or redirect** a fee. The fee
exists only because the user signed it.

### Validation (fill-time, `_deliverOutputs`)

| Rule | Effect |
| --- | --- |
| `feeBps > 1_000` (`MAX_FEE_BPS`, 10%) | fill reverts `InvalidFee` — malformed order |
| `feeBps != 0 && recipient == 0` | fill reverts `InvalidFee` — would burn the skim |
| `feeBps == 0` | skim disabled entirely, recipient ignored |

`SettlementLens.validateOrder` runs the same checks statically, so a malformed
fee is catchable before broadcast.

### Settlement flow

The fee is skimmed **from the maker's `tokenOut` delivery**, on every output leg:

```
solver delivers amt (gross, unchanged)
  ├── amt - fee → maker
  └── fee       → feeRecipient        fee = amt * feeBps / 10_000 (floors)
```

Key properties:

- **The solver's economics are untouched.** Solvers quote and deliver the gross
  amount; the auction competes on gross. The maker nets less — the fee is the
  maker paying the originator, with settlement doing the routing. This is the
  UniswapX-style interface-fee seam.
- **The maker keeps the rounding remainder** (fee floors).
- **Partial fills skim pro-rata.** Each fill's delivered slice is split with the
  same bps, so the accumulated fee over any fill sequence equals the full-fill
  fee.
- `outs[]` / fill return values / previews stay **gross** (solver-denominated).
  There is no dedicated fee event — originator accounting reconstructs the skim
  from the config + the ERC-20 `Transfer` logs.
- The fee applies in both settlement directions (classic and reverse/Fusion
  flow) — delivery always goes through `_deliverOutputs`.

### What the fee does NOT touch

- **`tokenIn` legs** — the solver's receipts are never skimmed.
- **Items** — MAKE (deposit/repay) and TAKE (borrow/withdraw) legs execute on
  their signed amounts, untouched by the fee. Only the conversion delivery is
  split. (Corollary: an order whose items pay out directly to the maker with no
  `tokenOut` leg has nothing to skim — the fee only attaches to flow routed
  through settlement delivery.)

---

## 2. Originator flow

1. **Quote.** Originator prices the user's intent and decides its fee rate.
2. **Build.** Set `feeConfig = pack(feeCollector, feeBps)` on the order. If an
   output leg funds a MAKE item (e.g. delivered WETH goes into a deposit), size
   that item to the **post-fee** amount: `item.amount ≤ amountOut · (1 − feeBps/1e4)`.
3. **Sign.** The user signs the order (single order sig, or the one-signature
   `fillWithPermit` witness batch — the fee needs no extra approval of any kind).
4. **Fill.** Any solver fills; the skim happens inside settlement. The
   originator receives the fee in-kind (in `tokenOut` units) at fill time —
   there is no claim step and no fee custody in the settlement contract.

Fee determinism depends on the order side:

- **BUY (exact-output)** — outputs are fixed, so `fee = feeBps × fixed output`
  is known exactly at signing time. Use this when the fee must be an exact
  number (see the interest-margin pattern below).
- **SELL (decaying output)** — the delivered amount depends on the auction tick
  at fill, so the realized fee varies within the `[end, start]` band. The bps
  rate is exact; the absolute amount is not.

---

## 3. Pattern: deposit free, charge an interest margin on exit

The flow the lending modules enable: an integrator onboards users into a lending
position (Aave/Comet/Morpho earn) at no charge, and monetizes at **withdrawal**
— e.g. the user was shown a net rate and the integrator keeps the margin, with
the accrued charge computed off-chain at exit time.

### How it's encoded

At withdrawal the originator knows principal, accrued protocol yield, and its
margin. It converts the absolute charge into bps of the exit payout and signs it
into the withdrawal order:

```
feeBps = charge / payout · 10_000        (round in the user's favor)
```

The order shape is a TAKE-item withdrawal whose proceeds fund `tokenIn`, with
the payout delivered as `tokenOut` minus the skim. Two variants:

**Exit with conversion** (unwind collateral, receive another asset):

```
items    = [ TAKE withdraw: 1 WETH aWETH → settlement ]
tokenIn  = WETH  (funds the solver)
tokenOut = USDC  (solver delivers gross; split maker / originator)
```

**Same-asset exit** (the pure earn-product withdrawal — deposit USDC, exit
USDC): `tokenIn = tokenOut = USDC`. The solver's compensation is the in/out
spread; the user receives `usdcOut − fee`:

```
items    = [ TAKE withdraw: 2_000 USDC supply → settlement ]
tokenIn  = USDC 2_000e6
tokenOut = USDC 1_990e6   (10 USDC solver spread)
feeConfig = pack(originator, 250)   → 49.75 USDC fee, 1_940.25 USDC to user
```

Practical notes:

- Prefer **BUY-side encoding** when the charge must be exact (fee on the fixed
  output); on SELL orders the realized fee floats with the auction.
- Interest keeps accruing between signing and fill — the off-chain computation
  goes slightly stale. Short order deadlines bound the undercharge.
- The protocol-side "position larger than the order" case is handled by the
  modules' `BalanceMode.Full` (withdraw everything, forward the signed amount,
  sweep accrued excess back to the user in-kind).

### Working examples (fork tests)

| Protocol | Position exited | Test |
| --- | --- | --- |
| Aave v3 | WETH collateral → USDC payout | `modules/lending/aave-v3/test/swaps/WithdrawWithFee.t.sol` |
| Morpho Blue | USDC **loan supply** (earn), same-asset exit | `modules/lending/morpho/test/swaps/WithdrawLoanWithFee.t.sol` |
| Compound v3 | USDC **base supply** (earn), same-asset exit | `modules/lending/compound-v3/test/swaps/WithdrawWithFee.t.sol` |
| plain swaps | fee unit coverage (cap, rounding, partials) | `core/test/swaps/SourcingFee.t.sol` |
| deposit+borrow | fee alongside MAKE/TAKE items | `modules/lending/aave-v3/test/leverage/DepositBorrowWithFee.t.sol` |

(The Morpho case uses `MorphoBlueTakerModule` op `2` — the loan-asset withdraw
leg; Comet needs no special op since a base-asset `withdrawFrom` *is* the
deposit withdrawal.)

---

## 4. Boundaries and caveats

Read this section before building a business model on the fee.

- **The fee is consent-based, not enforceable.** Positions are user-owned
  (on-behalf modules + Permit3 allowances). A user can always withdraw directly
  from the underlying protocol — or via any other frontend — and pay nothing.
  `feeConfig` monetizes **order flow you originate**, not account
  relationships. Enforceable exit fees require the position to be held by a
  fee-enforcing contract (an integrator fee-vault whose `redeem` takes the
  margin) — a custody model this protocol deliberately does not impose, and a
  separate build if wanted.
- **10% hard cap.** `MAX_FEE_BPS = 1_000`. Fine for margins; can bind if the
  charge is a large fraction of a long-accrued payout. Amount-padding is not a
  workaround — any spread built into the order's amounts flows to the solver
  via the auction, not to the originator.
- **Output-side, percentage-only, uniform.** No absolute-amount fee, no fee on
  `tokenIn`, and the same bps hits every `tokenOut` leg of a multi-asset order.
- **Opaque at signing.** Wallets render `feeConfig` as a raw `bytes32` — users
  cannot read the rate/recipient from the EIP-712 prompt. Disclose the fee in
  the UI; `SettlementLens` previews can back a human-readable confirmation.
- **No fee event.** Index the ERC-20 `Transfer` to the recipient (or derive
  `fee = gross · bps / 10_000` from `OrderFilled` + the order) for revenue
  accounting.
