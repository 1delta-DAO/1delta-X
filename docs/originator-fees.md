# Originator Fees (Sourcing-Fee Legs)

How the party that *sources* an order — a frontend, wallet, aggregator, or any
integrator that brings the user — earns a fee on it, and how that composes with
lending flows such as "deposit for the user, charge an interest margin on
withdrawal".

There is **no fee subsystem**: no global fee switch, no protocol fee registry,
no packed fee word, and no governance surface. A fee is an **ordinary output
leg** addressed to the originator — maker-signed, per-order, and rendered by
wallets as a plain amount + recipient in the EIP-712 prompt.

---

## 1. The mechanism

### Per-leg recipients

Every `LegOut` carries its own `recipient` (`address(0)` = the maker). An
originator fee is one more signed `LegOut`:

```
legsOut = [
  LegOut{ token: USDC, start: gross − fee, end: …, recipient: 0 (maker)  },
  LegOut{ token: USDC, start: fee,         end: …, recipient: originator },
]
```

```ts
import { feeSplitLegs } from "@1delta-x/sdk";
// bps-of-tick fee: maker leg + fee leg decay proportionally on the shared clock
const feeLegs = feeSplitLegs(USDC, grossStart, grossEnd, originator, 100n /* 1% */);
// feeSplitLegs returns [makerLeg, feeLeg] — concat into legsOut
const order = { ...base, legsOut: [...base.legsOut, ...feeLegs] };
```

Fee shapes:

| Want | Encode |
| --- | --- |
| bps of the realized auction tick | fee leg with `start/end` proportional to the main leg (`feeSplitLegs`) |
| exact absolute fee | fixed fee leg (`end == 0`) |
| multiple recipients (tiers) | one leg per recipient |
| fee on an outputless order | a `FeeTransferModule` **item** — see §3 |

Because the legs are part of the `Order` EIP-712 typehash, they are inside the
maker's signature: a solver **cannot add, remove, or redirect** a fee.

### Settlement flow

`_deliverOutputs` transfers each leg solver → its recipient. No skim math, no
fee validation path — the fee is delivery. Key properties:

- **The solver's economics are unchanged.** Solvers quote and deliver the gross
  total across legs; the auction competes on gross. The maker nets less — the
  fee is the maker paying the originator, with settlement doing the routing.
- **Partial fills slice pro-rata** (ceil per leg): the accumulated fee over any
  fill sequence equals the full-fill fee.
- `outs[]` / fill return values report per-leg amounts; there is no dedicated
  fee event — originator accounting reads its own leg's ERC-20 `Transfer`.
- **Same token to different recipients is legitimate** (maker leg + fee leg);
  `validateOrder` only rejects a duplicate `(token, recipient)` pair.

### Soft exclusivity leaves the fee leg alone

Soft exclusivity (the override bps in `params`) makes a non-exclusive in-window
filler improve the maker's terms — deliver more on SELL, charge less on the
input. That improvement is the **maker's** compensation for a bypassed exclusive
filler, so settlement applies it **only to legs delivered to the maker**, never
to a fee leg addressed to a third party. Consequences the integrator can rely
on:

- An **absolute fee leg stays absolute** even when a soft-exclusivity fill lands
  — the originator receives exactly the signed amount, not an inflated one.
- A **proportional fee leg** is computed on the un-bumped auction tick, so the
  maker keeps the full override improvement on its own leg.

(Symmetric with the input side, where the override adjusts only what the maker
pays; a rising relayer-fee input leg *is* reduced by the override, i.e. the
queue-jumping relayer gives up part of its fee to the maker.)

### What the fee does NOT touch

- **`legsIn`** — the solver's receipts are never skimmed.
- **Items** — MAKE (deposit/repay) and TAKE (borrow/withdraw) legs execute on
  their signed amounts. If an output leg funds a MAKE item (delivered WETH goes
  into a deposit), size the item to the MAKER leg's amount.

---

## 2. Originator flow

1. **Quote.** Originator prices the user's intent and decides its fee.
2. **Build.** Append the fee leg (`feeSplitLegs` for bps, a fixed leg for
   absolute) — or the fee item for outputless shapes.
3. **Sign.** The user signs the order (single order sig, or the one-signature
   `fillWithPermit` witness batch — the fee needs no extra approval; the fee
   ITEM needs one Permit3 allowance to `FeeTransferModule`).
4. **Fill.** Any solver fills; the originator receives the fee in-kind at fill
   time — no claim step, no fee custody in the settlement contract.

Fee determinism:

- **Fixed fee leg** — exact at signing (any side).
- **Proportional fee leg on a decaying SELL** — the realized fee is the bps of
  the auction tick at fill: rate exact, absolute amount floats in the band.

---

## 3. Outputless orders: the fee ITEM (`FeeTransferModule`)

Pure deposits, zero-capital exits (TAKE `recipient = maker`), and repays have
no solver delivery to carry a fee leg. The originator fee there is a
maker-signed **item**:

```
items += [ MAKE FeeTransferModule: amount = absolute fee,
           data = abi.encode(feeToken, originator) ]
```

`core/src/modules/FeeTransferModule.sol` pulls the ABSOLUTE amount from the
maker (via its own Permit3 allowance) straight to the recipient, slicing
pro-rata across partial fills like any item. The relayer-fee counterpart on the
same order is the rising `LegIn` fee leg (see `relayer-fees.md`); the canonical
outputless integrator order carries both. Working example:
`modules/lending/aave-v3/test/swaps/DepositWithFee.t.sol::test_deposit_withRisingFee_andOriginatorFeeItem`.

Design note (peer comparison): per-leg output recipients are the UniswapX
model (an interface fee = one more signed output); the fee item is 1inch LOP's
`FeeTaker`-extension pattern expressed in this protocol's item seam. 0x v4's
hardcoded fee fields and CoW's driver-enforced appData policies were rejected
as less general / operator-dependent.

---

## 4. Pattern: deposit free, charge an interest margin on exit

The integrator onboards users into a lending position (Aave/Comet/Morpho earn)
at no charge and monetizes at **withdrawal** — the accrued charge computed
off-chain at exit and signed into the exit order.

**Exit with conversion** (unwind collateral, receive another asset):

```
items   = [ TAKE withdraw: 1 WETH aWETH → settlement ]
legsIn  = [ LegIn{ WETH, … } ]   (funds the solver)
legsOut = [ LegOut{ USDC, …, maker }, LegOut{ USDC, …, originator } ]   (net → maker, margin → originator)
```

**Same-asset exit** (deposit USDC, exit USDC — the solver's compensation is the
in/out spread):

```
items   = [ TAKE withdraw: 2_000 USDC supply → settlement ]
legsIn  = [ LegIn{ USDC, start: 2_000e6 } ]
legsOut = [ LegOut{ USDC, 1_940.25 → maker }, LegOut{ USDC, 49.75 → originator } ]   (1_990 gross, 10 spread)
```

**Zero-capital exit** (withdraw straight to the wallet; relayer fronts
nothing): TAKE `recipient = maker` + rising fee leg + fee ITEM for the margin —
see `relayer-fees.md`.

Practical notes:

- Use a **fixed fee leg / fee item** when the charge must be exact; a
  proportional leg floats with the auction.
- Interest accrues between signing and fill — short deadlines bound the drift.
- Positions larger than the order are handled by the modules'
  `BalanceMode.Full` (withdraw everything, forward the signed amount, sweep
  accrued excess back to the user in-kind).

### Working examples (fork tests)

| Protocol | Position exited | Test |
| --- | --- | --- |
| Aave v3 | WETH collateral → USDC payout | `modules/lending/aave-v3/test/swaps/WithdrawWithFee.t.sol` |
| Morpho Blue | USDC **loan supply** (earn), same-asset exit | `modules/lending/morpho-blue/test/swaps/WithdrawLoanWithFee.t.sol` |
| Compound v3 | USDC **base supply** (earn), same-asset exit | `modules/lending/compound-v3/test/swaps/WithdrawWithFee.t.sol` |
| Aave v3 | **borrow** + origination fee (same-asset, TAKE) | `modules/lending/aave-v3/test/swaps/BorrowWithFee.t.sol` |
| plain swaps | fee-leg unit coverage (proportional, absolute, tiers, partials) | `core/test/swaps/SourcingFee.t.sol` |
| deposit+borrow | fee leg alongside MAKE/TAKE items | `modules/lending/aave-v3/test/leverage/DepositBorrowWithFee.t.sol` |
| outputless | fee item + rising relayer leg | `core/test/modules/FeeTransferModule.t.sol` |

---

## 5. Boundaries and caveats

- **The fee is consent-based, not enforceable.** Positions are user-owned; a
  user can always exit the underlying protocol directly and pay nothing. Fee
  legs monetize **order flow you originate**, not account relationships.
  Enforceable exit fees require fee-vault custody — deliberately not built.
  Corollary: a no-fee order is simply less attractive to fillers — it fills
  late, at a worse tick, or not at all, unless the originator sponsors it
  (fills it itself); that starvation is the intended market outcome, not a
  protocol gap.
- **No cap.** The old 10% `MAX_FEE_BPS` guard died with `feeConfig` — a fee leg
  is an explicit signed amount the wallet displays, which is the real
  protection. `validateOrder` still catches structural nonsense (zero legs,
  duplicate `(token, recipient)` pairs).
- **Never address a leg at the settlement contract.** A `LegOut` whose
  `recipient == Settlement` delivers into the anti-donation snapshot baseline,
  where it is permanently burned (no sweep exists). It's a maker self-burn, not
  an exploit — but `validateOrder` flags it (`"recipient is settlement (burn)"`)
  so a preflight catches the footgun. Each `LegOut.recipient` is signature-bound
  (part of the order hash), so a filler can never alter a recipient or the
  number of legs.
- **No fee event.** Index the ERC-20 `Transfer` to the recipient, or read the
  fee leg's entry in the fill's return value.
