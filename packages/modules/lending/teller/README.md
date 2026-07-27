# @1delta-x/modules-teller

Teller V2 lending adapters for `Settlement`. Depends on `@core`.

## Scope — value-in only

Teller's pooled `LenderCommitmentGroup` model exposes only two legs that fit the
**atomic on-behalf** module mechanic, both permissionless value-in:

| Contract | Op | Action | `data` |
|---|---|---|---|
| `TellerPoolDepositModule` | MAKE | pool `deposit(assets, onBehalfOf)` (ERC-4626, V2/V3) | `abi.encode(pool, asset[, permit])` |
| `TellerRepayModule` | MAKE | `repayLoanFull(bidId)` / `repayLoan(bidId, amount)` | `abi.encode(tellerV2, principalToken, bidId, full[, permit])` |

Both are gated by `msg.sender == settlement`; there is **no taker module**.

## Why borrow & withdraw are NOT wired

- **Borrow** (`SmartCommitmentForwarder.acceptSmartCommitmentWithRecipient`)
  attributes the loan to the forwarder's ERC-2771 `_msgSender`, so a third-party
  module cannot incur debt *for the maker* (the debt would land on the module). It
  is additionally gated by a **Hypernative oracle firewall**
  (`onlyOracleApprovedAllowEOA`) and per-market **borrower attestation**. Delegation
  exists (`approveMarketForwarder`) but only lets the *forwarder* act — not an
  arbitrary settlement module.
- **Pool withdraw** enforces a **per-owner cooldown** (V1 is a two-step burn
  queue; V2/V3 a withdrawal delay), so it cannot be expressed as one atomic fill.

These are protocol constraints, not gaps in the mechanic — the same class of
blocker as Term Finance's sealed-bid auction. Repay-and-withdraw at Teller is a
**full close** (`repayLoanFull` releases all collateral) driven by the borrower
directly, outside the atomic on-behalf flow.

## Tests

Fork the chain where the target Teller pool is deployed (set an RPC endpoint). The
`security/` auth check runs without a fork.

```
FOUNDRY_PROFILE=modules-teller forge test --root ../../../..
```
