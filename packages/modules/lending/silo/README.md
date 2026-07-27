# @1delta-x/modules-silo

Silo v2 lending adapters for `Settlement`. Each contract is a **single-op
module** — a thin, stateless adapter that performs exactly one Silo action
(deposit, withdraw, borrow, repay) on the order maker's behalf when Settlement
processes an order item. Composed inside one signed order they express leverage,
deleverage and cross-protocol migration as a single atomic intent any solver can
fill. Depends on `@core`, never the reverse.

## Why Silo fits the mechanic

A Silo is an **ERC-4626 vault + a borrow extension**; a market pairs two silos
(one per asset). Because `borrow` and `withdraw` both take a `receiver`, the
value-out legs forward straight to the order's `receiver` — no post-op sweep, the
clean case (contrast the CDP packages). Each single-op module only needs the silo
address it acts on, pinned in the maker-signed `data`.

## Modules (`src/`)

| Contract | Op | Silo action | `data` |
|---|---|---|---|
| `SiloDepositModule` | MAKE | pull asset → `silo.deposit(onBehalfOf)` (Collateral) | `abi.encode(silo, asset[, permit])` |
| `SiloRepayModule` | MAKE | pull buffered amount → `silo.repay`; recycle/sweep dust | `abi.encode(silo, asset[, DustAction[, permit]])` |
| `SiloTakerModule` (op 0) | TAKE | `silo.borrow(amount, receiver, onBehalfOf)` | `abi.encode(uint8(0), silo, asset)` |
| `SiloTakerModule` (op 1) | TAKE | `silo.withdraw(amount, receiver, onBehalfOf)` | `abi.encode(uint8(1), silo, asset[, BalanceMode])` |

## Authorization (per leg)

| Leg | Protocol grant | Permit3 |
|---|---|---|
| deposit | — (permissionless value-in) | token allowance (module) |
| repay | — (permissionless value-in) | token allowance (module) |
| withdraw | `silo.approve(module, max)` — ERC-4626 owner allowance on the Collateral share (the silo itself) | taker allowance (Settlement, `keccak256(data)`) |
| borrow | `debtShareToken.setReceiveApproval(module, cap)` — Silo's reverse-approval (the credit-delegation analogue) | taker allowance (Settlement, `keccak256(data)`) |

The taker book is keyed by **spender = Settlement**, so a standing taker allowance
cannot be drained by an arbitrary caller; the taker module additionally enforces
`msg.sender == permit3` (see [`test/security/TakerModuleAuth.t.sol`](test/security/TakerModuleAuth.t.sol)),
and the MAKE modules enforce `msg.sender == settlement`.

## Notes

- Only the **Collateral** leg is wired (the borrowable side). Protected deposits
  (`CollateralType = 0`) and `borrowSameAsset` are out of scope for now.
- `SiloRepayModule` reads the live debt via `maxRepay(onBehalfOf)` and repays
  `min(amount, debt)`, so an interest-accrual buffer is never over-pulled.
- `BalanceMode.Full` on withdraw closes the whole position (fill-or-kill; only
  after debt is cleared) and sweeps the accrued excess back to the maker.

## Tests

Fork Sonic/Arbitrum where Silo v2 is deployed (set an RPC endpoint). The
`security/` auth check runs without a fork.

```
FOUNDRY_PROFILE=modules-silo forge test --root ../../../..
```
