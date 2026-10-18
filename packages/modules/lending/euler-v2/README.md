# @1delta-x/modules-euler-v2

Permit3 maker/taker modules for **Euler v2** (EVK vaults fronted by the EVC).

An EVK vault pulls from and credits the *authenticated account*. Called directly,
that account is `msg.sender` — the module — so value flowing INTO a vault
(`deposit`, `repay`) is funded by the module while crediting any `receiver`, and
needs no grant on the maker's account. Value flowing OUT (`borrow`, `withdraw`)
must be authenticated as the maker, which the modules do through
`EVC.call(vault, maker, …)` / `EVC.batch` — admitted only for an EVC **account
operator**.

## Modules

| Module | Seam | Ops | Funding | Maker grant |
| --- | --- | --- | --- | --- |
| `EulerV2DepositModule` (`src/EulerV2Modules.sol`) | MAKE | deposit | PULL (Permit3) | Permit3 token allowance |
| `EulerV2RepayModule` (`src/EulerV2Modules.sol`) | MAKE | repay, clamped to `debtOf` | PULL (Permit3) | Permit3 token allowance |
| `EulerV2PreFundModule` (`src/EulerV2PreFundModules.sol`) | MAKE | `Deposit` (0) / `Repay` (1) | PRE-FUND (the fill's delivery) | **none** |
| `EulerV2OperatorModule` (`src/EulerV2OperatorModule.sol`) | TAKE / TAKE_FOR | `Borrow` 0, `Withdraw` 1, `BatchOpen` 2, `BatchClose` 3, `Open` 4 (TAKE_FOR, both funding shapes) | — | `EVC.setAccountOperator(maker, module, true)` + controller/collateral + taker allowance |

The operator ops share ONE address because Euler's operator flag is an unscoped,
uncapped boolean: four addresses were four total-control grants, not a partition.
The makers stay separate because they consume a different grant (or none).

## Pre-funded sinks (`EulerV2PreFundModule`)

"Deposit / repay whatever the conversion delivered." The maker signs the converted
output leg with `recipient = EulerV2PreFundModule` and a `MAKE` item whose word 0
is the pre-fund leg-reference descriptor:

```
data = abi.encode(forDesc, vault[, subId])
forDesc = (5 << 253) | op << 244 | uint160(token) << 16 | legIndex
```

`token` must be `vault.asset()` (`PreFundGuard.FundingTokenMismatch` otherwise);
the core binds it to the referenced leg. `item.amount` is unread — the core sizes
`forAmount` from the delivery ledger. `subId` (optional, < 256) targets the EVC
sub-account `maker ^ subId`; sweeps always go to the maker's own wallet.

- **Gate:** `msg.sender == settlement` and the pre-fund descriptor
  (`_gatePreFundMake`).
- **Floor:** `PreFundGuard.floorOf` before the vault call; the remainder above it
  is swept to the maker (`sweepSurplus`) — so a vault that consumes less, a repay
  clamped to the live debt (EVK reverts `E_RepayTooMuch` above it), or a zero debt
  all return the unconsumed delivery to the maker and never touch another fill's
  balance.
- **Approvals:** scoped to the amount and cleared after the call — the vault is
  maker-named, and EVK vaults are permissionless.

This is what makes the two **acyclic** position shapes zero-capital with no
receive-side grant (review 2026-10-18 M-1):

| Shape | Items (ORDERED) | Maker grants |
| --- | --- | --- |
| open against headroom | `TAKE` operator `Borrow` (early, funds the input) → swap → `MAKE` pre-fund `Deposit` (late) | operator flag + borrow taker allowance |
| close / deleverage against headroom | `TAKE` operator `Withdraw` (early) → swap → `MAKE` pre-fund `Repay` (late) | operator flag + withdraw taker allowance |

With the pull makers the late sink needed a Permit3 allowance to the module for a
token the maker never held. Leverage at the LTV edge is a cycle and still needs a
flash (or the fused `Open` / `BatchOpen` composites).

## Test

```
FOUNDRY_PROFILE=modules-euler-v2 forge test
```

Forks Ethereum mainnet at the harness block (eWETH-2 collateral / eUSDC-2 borrow,
84% LTV). `test/netted/NettedPreFund.t.sol` runs the pre-fund sinks on
`matchSettle` against a CoW counter-order with a solver holding nothing: the
acyclic open and close, two makers' deliveries parked on one singleton (with
residue), a hostile zero-consume repay, an item hoisted before its own delivery
(`Base.ForLegInvalid`), and the gate/floor refusals at the door.
