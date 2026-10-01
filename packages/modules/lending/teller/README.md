# @1delta-x/modules-teller

Teller V2 lending adapters for `Settlement`. Depends on `@core`.

## Scope — value-in only

Teller's pooled `LenderCommitmentGroup` model exposes only two legs that fit the
**atomic on-behalf** module mechanic, both value-in on someone else's behalf:

| Contract | Op | Action | `data` |
|---|---|---|---|
| `TellerPoolDepositModule` | MAKE | pool `deposit(assets, onBehalfOf)` (ERC-4626, V2/V3) — **firewalled, see below** | `abi.encode(pool, asset[, permit])` |
| `TellerRepayModule` | MAKE | `repayLoanFull(bidId)` when `full` or `amount ≥ owed`, else `repayLoan(bidId, amount)`; unused buffer swept back | `abi.encode(tellerV2, principalToken, bidId, full[, permit])` |
| `TellerPreFundModule` | MAKE (pre-funded) | ONE contract, op in descriptor bits [244,252): `Op.PoolDeposit` — deposit the core-delivered leg; `Op.Repay` — repay it with the same live-debt clamp, surplus swept to the maker | Deposit: `abi.encode(forDesc, pool, asset)`; Repay: `abi.encode(forDesc, tellerV2, asset, bidId, full)` |

All are gated by `msg.sender == settlement`; there is **no taker module**.

## Repay: the module clamps, the venue does not

⚠ The deployed TellerV2 `repayLoan(bidId, X)` (mainnet impl `0x37f483c8…b002`,
and the Base / Arbitrum / Polygon impls — all equal to teller-protocol-v2
`develop`) **does not clamp an overpayment**: it transfers the whole `X` to the
lender and marks the loan PAID once `X ≥ owed`. (The 2023-03 snapshot capped the
transfer; it is not what is deployed.) Both repay modules therefore read
`calculateAmountOwed(bidId, block.timestamp)` and route any amount **at or above**
the live owed figure to `repayLoanFull`, which pulls exactly `owed`; the delta
sweep returns the rest to the maker (2026-09-30 audit, L-CMT-1). Pinned against
the live venue by `test/fork/TellerRepayClampFork.t.sol`.

`full` semantics:

- `full = true` — the maker requires a close. Reverts if the amount held is short
  of the owed amount (the scoped approval is the amount).
- `full = false` — repay up to the amount; closes the loan (and sweeps the
  surplus) if the amount covers it. This is the safe setting for an
  auction-priced or partially fillable repay.

Venue liveness limit: `repayLoan` reverts `PaymentNotMinimum` when a partial
payment is below the current cycle's minimum due (`duePrincipal + interest`). On a
loan whose duration is one payment cycle that minimum is the whole owed amount, so
a partial below it fails closed (nothing moves).

## Pool deposit: the Hypernative firewall

`LenderCommitmentGroup_Pool_V2` / `_V3` mark `deposit(uint256,address)` with
`onlyOracleApprovedAllowEOA`. The pool asks its `ORACLE_MANAGER` (the chain's
SmartCommitmentForwarder) `isOracleApprovedAllowEOA(msg.sender)`; for a caller
that is not `tx.origin` — always the case for a module reached through
Settlement — that requires `oracle.isTimeExceeded(module)`, and
`HypernativeOracle` reverts **`"Account not registered"`** for an address that
was never registered. So on every chain where the forwarder has an oracle set
(Base, Arbitrum and mainnet as of 2026-09), **both deposit legs revert** until:

1. **Deploy step, once per chain and per deposit module address**
   (`TellerPoolDepositModule` and `TellerPreFundModule`): call
   `SmartCommitmentForwarder.oracleRegister(module)` — public, anyone may call it.
2. Wait out the registration threshold (≥ 2 minutes by default; the admin can
   raise it).
3. If the forwarder runs in strict mode, registration marks the address as a
   potential risk and a Hypernative operator must `allow` it.

Residual risk: the module is a shared singleton, so if Hypernative ever
blacklists it (or a filler's `tx.origin`), deposits stop for every maker at once.
The repay legs (`repayLoan`/`repayLoanFull`) carry no oracle gate. The V1
`LenderCommitmentGroup_Smart` has no `deposit(uint256,address)` at all (it uses
`addPrincipalToCommitmentGroup`) and is not supported.

## Why borrow & withdraw are NOT wired

- **Borrow** (`SmartCommitmentForwarder.acceptSmartCommitmentWithRecipient`)
  attributes the loan to the forwarder's ERC-2771 `_msgSender`, so a third-party
  module cannot incur debt *for the maker* (the debt would land on the module). It
  is additionally gated by the same **Hypernative oracle firewall**
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

- `test/unit/` — mock venues. `MockTellerV2` models the DEPLOYED repay semantics
  (uncapped `repayLoan`, `PaymentNotMinimum`), so a missing module clamp fails.
- `test/fork/TellerRepayClampFork.t.sol` — Ethereum mainnet fork against the live
  TellerV2 proxy: a loan is opened on the open market 21, then repaid through the
  real Settlement + Permit3 with both repay modules. Uses the public RPC list in
  `CoreSettlementBase` (override with `ETH_RPC_URL`).
- `test/security/` — direct-call rejection, no fork.

There is no deposit fork test yet: it needs a live V2/V3 pool address and the
registration steps above.

```
FOUNDRY_PROFILE=modules-teller forge test --root ../../../..
```
