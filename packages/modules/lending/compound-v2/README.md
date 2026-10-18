# @1delta-x/modules-compound-v2

Permit3 maker/taker modules for **vanilla Compound v2** — all ops **except borrow**.

Unlike Venus (see [`modules-venus`](../venus)), vanilla Compound v2 has no
`borrowBehalf` and no delegation: `mint` / `redeem` / `borrow` all act on
`msg.sender`, and only `repayBorrowBehalf` is a native on-behalf call. A router
therefore **cannot borrow on a user's behalf**, so this package ships no borrow
module. The other three ops are supported by handling the cToken receipt the way
the Aave package handles aTokens.

## Modules (`src/CompoundV2Modules.sol`)

| Module                     | Op   | Compound v2 call                              | Authorisation |
| -------------------------- | ---- | --------------------------------------------- | ------------- |
| `CompoundV2DepositModule`  | MAKE | `mint(amount)` → forward cToken receipt to user | none (value-in) |
| `CompoundV2RepayModule`    | MAKE | `repayBorrowBehalf(user, amount)`             | none; pull-exact + recycle/sweep dust |
| `CompoundV2WithdrawModule` | TAKE | pull cToken (Permit3) → `redeemUnderlying` / `redeem` (Full mode) → forward | user approves cToken to the module via Permit3 |

`data = abi.encode(cToken, underlying)` for every module. Repay accepts an
optional trailing `DustHandler.DustAction`; withdraw accepts an optional trailing
`DustHandler.BalanceMode` (`Full` redeems the whole balance and sweeps the excess
to the user). `Full` is the **tagged** word `0xB0DE0001`
(`DustHandler.encodeMode(Full)`) followed by the mandatory `totalAmount`; a bare
`1` reverts `InvalidModeWord`. The native modules take `abi.encode(cEther[, ...])`.

## Pre-funded modules (`src/CompoundV2PreFundModules.sol`)

"Deposit / repay whatever the conversion delivered": the maker routes the signed
output leg to the module (`recipient = module`) and signs a pre-funded `MAKE` item
whose leg-reference descriptor points at it; the core sizes `forAmount` to exactly
that delivery and the module spends it from its own balance (floor + sweep). The
delivered asset needs no ERC20 approval, no Permit3 allowance and no venue grant
(`mint` and `repayBorrowBehalf` are permissionless on behalf).

| Module | Op (descriptor bits [244,252)) | Compound v2 call | `data` |
| --- | --- | --- | --- |
| `CompoundV2PreFundModule` | 0 Deposit / 1 Repay | `mint(forAmount)` → forward cToken receipt / `repayBorrowBehalf(min(forAmount, debt))` → sweep the rest | `abi.encode(forDesc, cToken, underlying)` |
| `CompoundV2NativePreFundModule` | 0 Deposit / 1 Repay | `weth.withdraw` → `cEther.mint{value}` → forward receipt / `cEther.repayBorrowBehalf{value: min(forAmount, debt)}` → unused WETH swept back, still wrapped | `abi.encode(forDesc, cEther)` — funding token must be the immutable `weth` |

The native one (review 2026-10-18 M-5) replaces the WETH pull of
`CompoundV2NativeDepositModule` / `CompoundV2NativeRepayModule` — a Permit3 grant
on a token a "sell X, deposit/repay ETH" maker never held — with a delivered WETH
leg unwrapped inside the item. It unwraps EXACTLY `forAmount` (or the debt-capped
part), never "whatever WETH is here": on `matchSettle` two makers' deliveries can
park on the singleton at once (the `NativeUnwrapModule` rule). The size comes
from the core's delivery ledger, not a pro-rated `item.amount`, so the SELL-leg
per-fill-ceil vs item cumulative-floor gap does not arise (the extra wei of a
partial fill is minted for the maker). ETH and WETH sweeps are floored at their
pre-call balances.

`test/netted/NettedPreFund.t.sol` (mock cTokens + a WETH9-shaped mock, real
Settlement + Permit3) drives both modules on the netted path with WETH, ETH and
underlying residue on the singletons: two native items parked side by side,
a hostile zero-debt sweep, an item hoisted ahead of its own DELIVER failing closed
(`ForLegInvalid`), the ERC20 pair interleaved, the acyclic CLOSE at zero capital
(`CompoundV2WithdrawModule` TAKE early → sell → native pre-funded repay late),
partial forward fills, and the gates. `test/native/NativePreFundSettlement.t.sol`
runs the native module against live mainnet cETH + WETH9 with no WETH grant at
all. (No acyclic OPEN with a borrow: vanilla Compound v2 has no on-behalf borrow;
the open here is swap-and-deposit.)

### Notes

- **No borrow.** Vanilla Compound v2 cannot record debt on a third party. If you
  need delegated borrowing, use the Venus package (Venus adds `borrowBehalf` +
  `comptroller.updateDelegate`).
- **Deposit** mints to the module (no `mintBehalf`) and forwards the cTokens to
  the user, who holds the collateral receipt.
- **Withdraw** pulls the user's cTokens first (cTokens are not 1:1 with the
  underlying — the module converts via the accrued exchange rate), then redeems.
- **Withdraw binds the underlying** to `cToken.underlying()` (`UnderlyingMismatch`
  otherwise), declares it through `IProceedsAsset`, and requires the measured
  redeem to cover `amount` in BOTH modes (`ShortWithdraw`): a Compound-v2 fork that
  charges a redeem fee (Venus core pool with a non-zero `treasuryPercent`) would
  otherwise have the core bill the gap to the maker's wallet.
- **Recycle** dust re-mints into the user's position; since the surplus becomes
  the *receipt* token it is handled inline (not via `DustHandler.disposeResidual`),
  best-effort with a sweep fallback. The fallback RE-MEASURES the module's balance
  against its pre-call floor: a maker-chosen cToken can spend the approval and
  still return an error code, and paying the pre-measured residual then would come
  out of the module's pre-existing balance (2026-09-30 audit, X-STATIC-1).
- Compound forks return a `uint` error code (0 == success); each call's code is
  checked and reverts with `CompoundV2Error(code)`.

## Test

```
npm test --prefix packages/modules-compound-v2
```

Forks Ethereum mainnet and drives the live cUSDC / cDAI markets (set `ETH_RPC_URL`
to pin an RPC).
