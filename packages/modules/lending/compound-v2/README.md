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
