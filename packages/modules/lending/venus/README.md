# @1delta-x/modules-venus

Permit3 maker/taker modules for **Venus** — an *expanded* Compound v2 fork.

Plain Compound v2 keys every position to `msg.sender`, so a router cannot act on a
user's behalf. Venus adds an explicit on-behalf + delegation layer, which is what
lets these modules drive a *user's* position while being funded by / paying out
the module itself — the same shape as the Comet/Euler/Dolomite packages.

## Modules (`src/VenusModules.sol`)

| Module                  | Op   | Venus call                       | Authorisation |
| ----------------------- | ---- | -------------------------------- | ------------- |
| `VenusDepositModule`    | MAKE | `mintBehalf(user, amount)`       | none (permissionless value-in) |
| `VenusRepayModule`      | MAKE | `repayBorrowBehalf(user, amount)`| none; pull-exact + DustHandler recycle/sweep |
| `VenusTakerModule` (op 0, Borrow)   | TAKE | `borrowBehalf(user, amount)`     | `comptroller.updateDelegate(module, true)` |
| `VenusTakerModule` (op 1, Withdraw) | TAKE | `redeemUnderlyingBehalf` / `redeemBehalf` (Full mode) | `comptroller.updateDelegate(module, true)` |

The two value-out legs are fused into a single `VenusTakerModule`, selected by a
leading `uint8 op` flag, so the user delegates ONE module address for the whole
leverage round-trip. The op flag is the first word of `data`, so borrow-data and
withdraw-data hash to different `keccak256(data)` taker refs — each leg still gets
its own amount-gated Permit3 allowance.

Maker `data = abi.encode(vToken, underlying)`; taker
`data = abi.encode(uint8 op, vToken, underlying[, BalanceMode])` (`underlying`
pinned into the order / taker ref). Repay accepts an optional trailing
`DustHandler.DustAction`; withdraw (op 1) accepts an optional trailing
`DustHandler.BalanceMode` (`Full` redeems the entire balance and sweeps the
excess to the user). `Full` is the **tagged** word `0xB0DE0001`
(`DustHandler.encodeMode(Full)`) followed by the mandatory `totalAmount`; a bare
`1` reverts `InvalidModeWord`.

- **Underlying binding.** The taker module checks the signed `underlying`
  against `vToken.underlying()` and reverts `UnderlyingMismatch` otherwise.
  Proceeds are measured as a balance delta of the signed token, so a mis-encoded
  one used to forward nothing, strand the real proceeds on the module and let the
  core bill the whole input leg to the maker's wallet.
- **Delivery bound on both withdraw modes.** BSC core-pool `redeemFresh` sends
  `amount * treasuryPercent / 1e18` to the treasury; with a non-zero fee an
  `Exact` redeem delivers short. Both withdraw branches `requireDelivered`, so a
  short redeem reverts (`ShortWithdraw`) instead of the core pulling the gap from
  the maker's wallet. Size withdraw orders net of any treasury fee.

### Authorisation model

- **value-in** (deposit / repay): Venus lets anyone fund another account, so no
  grant is needed — the module pulls underlying via Permit3 and the behalf-call
  credits/pays the user.
- **value-out** (borrow / withdraw): the user calls
  `comptroller.updateDelegate(module, true)` once. Venus routes proceeds to
  `msg.sender` (the module), which forwards them to the order's `receiver`. The
  taker modules reject any caller other than Permit3, and the Permit3 taker
  allowance caps each fill.

Compound forks return a `uint` error code (0 == success); every behalf-call's
code is checked and reverts with `VenusError(code)` on failure.

## Test

```
npm test --prefix packages/modules-venus
```

Forks Ethereum mainnet and drives a vWETH-collateral / vUSDC-debt position
against the live Venus Core pool (set `ETH_RPC_URL` to pin an RPC).
