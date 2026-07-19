# Relayer Fees (Rising-Input Auction)

How the party that *fills* an order — the relayer/solver paying gas and
executing settlement — is compensated, and specifically how that works for
orders whose economics give it **no conversion price to charge on**: pure
lending deposits, zero-capital exits, repays, and other "execute my items,
nothing converts" intents.

The mechanism is leg pricing itself — no flag, no fee field: **any SELL input
leg with `startAmountIn < endAmountIn` RISES on the order's shared auction
clock** (curve and gas bump included), exactly like a BUY conversion input.
`start == end` legs stay fixed. Inputs may only rise, outputs may only fall.

---

## 1. When the spread already pays the relayer

Most orders need nothing: the filler's compensation is the **conversion
spread**, discovered by the existing auction.

- **Swaps** — SELL outputs decay; the first filler for whom
  `tokenIn − tokenOut ≥ gas + margin` fills.
- **Withdrawals / exits** — same, funded by the position: TAKE proceeds pay the
  solver's `tokenIn`; the maker's payout decays. Works same-asset too
  (`USDC → USDC` earn exits — the in/out spread is the fee).
- **Borrows, leverage, migrations** — every flow where value passes through
  settlement has a spread to price the fill into.

## 2. The gap: nothing flows back

A pure deposit is a MAKE item: the module pulls the maker's funding token
straight into the protocol. Nothing passes through settlement, no output leg,
no spread. A fixed `tokenIn` fee leg could pay the relayer, but a fixed fee
cannot respond to the auction or to gas — the maker would have to guess it at
signing.

## 3. The mechanism: the rising fee leg

```
side      = SELL
items     = [ MAKE deposit D ]               (the real action)
tokenIn   = [ USDC ]  F0 → FMAX rising       (the relayer fee — maker pays, filler earns)
tokenOut  = [ ]                              (EMPTY — nothing is delivered back)
decay …   = shared clock: decayStartTime/Duration, curve, gasBumpBps/gasPriceRef
```

Fill-time semantics (`_payInputsToSolver`):

| Leg | Priced at |
| --- | --- |
| input, `start == end` | fixed `startAmountIn` (exact-input guarantee) |
| input, `start != end` | `amountInAt(tick)` — rising, gas-bumped |
| input, `end < start` | reverts `InvalidAuctionParams` (inputs only rise) |

Soft exclusivity applies to every auctioned input leg: a non-exclusive
in-window filler charges `exclusivityOverrideBps` less.

## 4. Why this is the economically-correct shape

- **Auction-discovered.** The fee rises until the *first* relayer for whom
  `tick ≥ gas + margin` fills. Competition prices the fill at the marginal
  relayer's cost; the maker's worst case is the signed `endAmountIn` ceiling.
- **Gas-indexed.** `gasBumpBps`/`gasPriceRef` widen the fee with `basefee`, so
  a deposit stays fillable through a gas spike without a fat static fee.
- **Zero filler capital.** With an empty `tokenOut` the relayer fronts
  nothing — no inventory, no flash. It pays gas and collects the fee leg.
- **One signature, fully gasless.** `fillWithPermit` covers the deposit pull
  (module allowance) and the fee pull (settlement allowance) in one witness
  batch.
- **Transparent.** The fee band `[F0, FMAX]` sits in plain `uint256[]` fields
  of the EIP-712 prompt.

## 5. The zero-capital exit

The mirror composition for withdrawals: route the TAKE item **straight to the
maker's wallet** (`Item.recipient = maker`) and attach a rising same-asset fee
leg. Items execute before `_payInputsToSolver`, so the withdrawal lands in the
maker's wallet first and the fee pull self-funds from it — the maker can start
with an empty wallet, and the relayer fronts nothing (vs. the same-asset
spread exit, which needs solver inventory). Proven in
`modules/lending/aave-v3/test/swaps/WithdrawWithFee.t.sol::test_withdrawToWallet_withRisingFee`.

## 6. Order-construction rules

- **Anchor = the fee leg** for outputless SELL orders (`startAmountIn[0]`,
  must be > 0; use a dust floor like `1` for a ~zero start). Deposits should be
  **full-fill-only**: `minFillAnchor = startAmountIn[0]`.
- **Empty `tokenOut` is only for item-bearing SELL orders.** `validateOrder`
  rejects an empty-output order with no items (giveaway) and any BUY without
  outputs (BUY anchors on `tokenOut[0]`).
- **Approvals**: module allowance for the principal + settlement allowance for
  the fee **ceiling** (`endAmountIn`). The Lens's fillable-amount preview caps
  item-free orders at the ceiling tick (conservative).
- **Composes with originator fees.** Named-payee fees are orthogonal: a fee
  OUTPUT leg (`recipientOut`) on conversion orders, a `FeeTransferModule` item
  on outputless ones (see `originator-fees.md`). The canonical outputless
  integrator order = action item + fee item + rising leg.

## 7. What it does NOT do

- **No absolute-fee guarantee** — the realized fee depends on when the fill
  lands within `[F0, FMAX]`, like every auction leg.
- **No relayer identity** — the fee pays `msg.sender` of the fill, whoever won
  the race (use `exclusiveFiller` for a nominated relayer). It is not a
  protocol fee and has no recipient registry.
- **No-fee orders are not subsidized** — an order with no spread and no fee leg
  simply won't attract fillers; the originator can sponsor it by filling
  itself. Intentional.

## 8. Working examples (fork tests)

| Case | Test |
| --- | --- |
| Aave v3 WETH deposit, rising fee + gas bump + partials | `modules/lending/aave-v3/test/swaps/DepositWithFee.t.sol` |
| Deposit + **originator fee item** + rising relayer leg (full integrator shape) | same file, `test_deposit_withRisingFee_andOriginatorFeeItem` |
| **Zero-capital exit**: TAKE withdraw to wallet, fee self-funded by proceeds | `modules/lending/aave-v3/test/swaps/WithdrawWithFee.t.sol::test_withdrawToWallet_withRisingFee` |
| Compound v3 USDC **base supply** entry (earn on-ramp) | `modules/lending/compound-v3/test/swaps/DepositWithFee.t.sol` |
| Aave v3 gasless **repay** (MAKE) + rising relayer fee | `modules/lending/aave-v3/test/swaps/RepayWithFee.t.sol` |
| Rising-leg ticks, gas bump, empty-`tokenOut`, exclusivity, Lens | `core/test/swaps/RisingInputFee.t.sol` |
| Fee item mechanics + Lens same-asset overlap | `core/test/modules/FeeTransferModule.t.sol` |
