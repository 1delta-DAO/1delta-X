# 30. Native RBTC delivery without filler capital (NativeBalance view + solver v3)

- **Status:** contracts DEPLOYED 2026-10-15 (NativeBalance `0xA45ec376…854c`, solver v3 `0x5987A4AF…6cD1`, verified; docs/deployment-rootstock-beta.md). Remaining: the off-chain switch — filler `AGGREGATOR_SOLVER` v2→v3 (with v2 kept for orders naming it), `NATIVE_BALANCE` in the filler and book, `VITE_DEPLOYMENTS[30].nativeBalance` in the app, the SDK's chain-30 `NATIVE_BALANCE` constant, and a first small live RBTC fill.
- **Layer:** contracts (periphery + solver) + filler + app + sdk + book
- **Package:** `packages/periphery`, `packages/solvers`, `packages/beta-filler`, `packages/app`, `packages/sdk`, `packages/orderbook-worker`
- **Severity:** design flaw: native receipts needed per-fill capital (inventory or flash)
- **Opened:** 2026-10-14
- **Plan:** [docs/native-rbtc-delivery-plan.md](../docs/native-rbtc-delivery-plan.md)

## Problem

The in-fill unwrap (task 28) is an item, and the zero-capital route solver cannot fill
item orders of that kind. Every native fill would need inventory or a flash loan. A flash
loan costs a fee and ~100k gas per fill, which is rejected.

## Change

1. A `NativeBalance` view contract with only `balanceOf(a) = a.balance`.
2. DIRECT orders sign `legsOut[0].token = NativeBalance`.
3. Solver v3 routes to WRBTC, unwraps it and sends RBTC to the recipient in its callback.
4. Settlement's delta check verifies the native receipt unchanged. No Settlement change.

Work items, migration (open orders naming solver v2) and the safety argument are in the plan.

## Acceptance

- Fork: a direct USD₮0 → RBTC market order is filled by solver v3 against the live
  Settlement with zero solver capital. The maker's native balance rises by at least the
  priced amount. Gas is within ~25k of a plain direct fill.
- `NativeBalance` in a pull leg, as an input, or in `matchSettle` reverts (fail closed).
- The app's RBTC dropdown entry signs the new shape; quotes are direct; fills display as RBTC.
