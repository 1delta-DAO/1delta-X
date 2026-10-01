# @1delta-x/modules-exactly

Exactly lending adapters for `Settlement`. Each contract is a **single-op
module** that performs exactly one Exactly action (deposit, withdraw, borrow,
repay) on the order maker's behalf. Composed inside one signed order they express
leverage, deleverage and migration as a single atomic intent. Depends on `@core`.

## Why Exactly fits the mechanic

Each `Market` is an **ERC-4626 vault + floating & fixed borrow books**. Because
`borrow`/`withdraw` carry a `receiver`, the value-out legs forward straight to the
order's `receiver` — the clean case. `maturity == 0` in the order `data` selects
the floating pool; a non-zero unix timestamp selects a fixed pool, with the
maker-signed slippage guard (`maxAssets` on borrow, `minAssetsRequired` on
withdraw) carried alongside.

## Modules (`src/`)

The `data` columns below are the encoder spec; the contract headers in
[`src/ExactlyModules.sol`](src/ExactlyModules.sol) and
[`src/ExactlyPreFundModules.sol`](src/ExactlyPreFundModules.sol) carry the full
byte maps (offsets in bytes, `check-module-shapes.py` rule 9b holds the code to
them). Optional fields are in `[...]`; a later optional field requires every
earlier one to be encoded.

| Contract | Op | Exactly action | `data` |
|---|---|---|---|
| `ExactlyDepositModule` | MAKE | `deposit` / `depositAtMaturity` (onBehalfOf) | `abi.encode(market, asset, maturity, minAssets[, deadline, v, r, s])` — permit@128 (value = this fill's amount) |
| `ExactlyRepayModule` (floating, `maturity == 0`) | MAKE | `repay` (clamped to the live FLOATING debt); recycle/sweep dust | `abi.encode(market, asset, 0, maxAssets[, DustAction[, deadline, v, r, s]])` — DustAction@128, permit@160 (value = this fill's amount) |
| `ExactlyRepayModule` (fixed, `maturity != 0`) | MAKE | `repayAtMaturity` bounded by the slice-scaled `maxAssets`; recycle/sweep dust | `abi.encode(market, asset, maturity, maxAssets, DustAction, totalAmount[, value, deadline, v, r, s])` — DustAction@128, **totalAmount@160 mandatory**, permit@192 with an explicit `value` (sign ≥ the item's `maxAssets`) |
| `ExactlyTakerModule` (op 0) | TAKE | `borrow` / `borrowAtMaturity` → receiver | `abi.encode(uint8(0), market, asset, maturity, maxAssets, totalAmount[, value, deadline, v, r, s])` — totalAmount@160 (mandatory on the fixed leg), share-permit@192 |
| `ExactlyTakerModule` (op 1) | TAKE | `withdraw` / `withdrawAtMaturity` → receiver | `abi.encode(uint8(1), market, asset, maturity, minAssets, totalAmount[, BalanceMode[, value, deadline, v, r, s]])` — totalAmount@160, **BalanceMode@192**, share-permit@224 |
| `ExactlyPreFundModule` (op Deposit / Repay) | MAKE (pre-funded) | supply / repay whatever the fill delivered to the module | Deposit: `abi.encode(forDesc, market, asset, maturity, minAssets)`; Repay: `abi.encode(forDesc, market, asset, maturity, positionAssets[, totalAmount])` — totalAmount@160 mandatory on the fixed branch (see below) |

Encoding notes:

- `BalanceMode` is a **tagged** word: encode it with `DustHandler.encodeMode(mode)`
  (`0` = Exact, `0xB0DE0000 | 1` = Full), never a bare `uint8(1)` — an untagged
  non-zero word reverts `InvalidModeWord`. It sits at **192**, after
  `totalAmount@160`, which is also the `Full` guard's total. A blob that omits
  `totalAmount` and puts the mode at 160 reads as **Exact** (no mode word at 192).
- `Full` is floating-only. When a share-permit tail follows on op 1, encode the
  mode slot (0 = Exact) even on the fixed leg.
- `DustAction` is `0` = SweepToUser, `1` = Recycle.

## Authorization (per leg)

| Leg | Protocol grant | Permit3 |
|---|---|---|
| deposit / repay | — (permissionless value-in) | token allowance (module) |
| borrow / withdraw | `market.approve(module, max)` — one ERC-4626 share allowance covers **both** legs (Exactly consumes it when principal != caller) | taker allowance (Settlement, `keccak256(data)`) |

Collateral counts only once the maker has `Auditor.enterMarket(market)` — a
maker-side permission (`enterMarket` uses `msg.sender`), not a module call. The
taker module enforces `msg.sender == permit3`; the MAKE modules enforce
`msg.sender == settlement`.

## Notes on the fixed (`…AtMaturity`) legs

- Early fixed repay is a **discount** (the pool rebates unassigned earnings), so
  the actual transfer ≤ face; overdue accrues a per-second late penalty, so
  post-maturity `maxAssets` must exceed the face. The off-chain order-prep sizes
  `amount`/`maxAssets` from `previewRepayAtMaturity` (+buffer); the module scales
  `maxAssets` with the slice (`totalAmount@160`), bounds the transfer and disposes
  any surplus. A gasless fixed repay signs the EIP-2612 permit for an explicit
  `value` ≥ the item's `maxAssets` — a face-valued permit cannot cover the pull.
- Fixed withdraw: Exactly's `withdrawAtMaturity` **clamps** a request above the
  fixed deposit instead of reverting, so the taker module reads
  `fixedDepositPositions` and reverts `ShortFixedPosition` when the slice exceeds
  `principal + fee` — a short position never under-delivers into a fill.
- `BalanceMode.Full` is floating-only and sizes from the RAW position
  (`previewRedeem(balanceOf)`), with `requireDelivered` failing a short delivery
  closed; fixed positions withdraw an explicit `positionAssets` face.
- Pre-funded fixed repay (`ExactlyPreFundModule`): the face is scaled by
  `forAmount / totalAmount`, where `totalAmount` must be the funding leg's
  **smallest full-fill delivery** — its amount for a fixed-price leg, its auction
  `end` for a decaying leg. A full fill then always presents the whole face; an
  early partial slice may present more than its share, which is clamped to the
  live fixed position, and once the position is closed later slices are swept
  back to the maker instead of reverting.
- Share-allowance units: the Market debits `previewWithdraw(x)` deposit shares on
  every path (`x` = assets for floating borrow/withdraw, assets + fixed fee for
  `borrowAtMaturity`, discounted assets for `withdrawAtMaturity`) — size a share
  permit's `value` accordingly.

## Tests

Fork Optimism/Base where Exactly is deployed (set an RPC endpoint). The
`security/` auth check runs without a fork.

```
FOUNDRY_PROFILE=modules-exactly forge test --root ../../../..
```
