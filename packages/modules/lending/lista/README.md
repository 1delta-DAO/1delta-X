# @1delta-x/modules-lista

Lista DAO lending adapters for `Settlement`. Lista's core is a **Moolah** (a
Morpho Blue fork), so collateral custody reuses the Morpho module shape; the debt
side of a brokered market runs through a **`LendingBroker`**. Depends on `@core`.

## Shape

| Side | Contract | Where | Grant |
|---|---|---|---|
| collateral in | Moolah `supplyCollateral(onBehalf)` | Moolah singleton | Permit3 token allowance |
| collateral out | Moolah `withdrawCollateral(onBehalf, receiver)` | Moolah singleton | Moolah `setAuthorization(module)` |
| debt out (borrow) | `broker.borrow(amount, termId, user, receiver)` | LendingBroker (fixed-term) | Moolah `setAuthorization(module)` |
| debt in (repay) | `broker.repay(amount, [loanId,] onBehalf)` / `repayAll(onBehalf)` | LendingBroker | Permit3 token allowance |

## Modules (`src/`)

| Contract | Op | `data` |
|---|---|---|
| `ListaSupplyCollateralModule` | MAKE | `abi.encode(moolah, MarketParams[, permit])` |
| `ListaBrokerModule` (op 0) | MAKE | `abi.encode(uint8(0), broker, loanToken, loanId[, DustAction[, permit]])` — PULL-funded repay |
| `ListaBrokerModule` (op 0) | MAKE (preFund) | `abi.encode(forDesc, broker, loanToken, loanId)` — same repay, funded from the delivered leg; op rides in descriptor bits [244,252) |
| `ListaBrokerModule` (op 1) | TAKE | `abi.encode(uint8(1), broker, termId[, moolah, authBlock])` — fixed-term borrow → receiver |
| `ListaTakerModule` (op 0) | — | RESERVED. The borrow used to live here; the slot is kept so ops 1/2 keep their wire values, and reverts `BadOp(0)` |
| `ListaTakerModule` (op 1) | TAKE | `abi.encode(uint8(1), moolah, MarketParams[, BalanceMode])` — withdraw collateral → receiver |
| `ListaTakerModule` (op 2) | TAKE | `abi.encode(uint8(2), provider, moolah, MarketParams[, BalanceMode])` — withdraw via an ERC20-forwarding provider; venue and auth target split |
| `ListaNativeSupplyCollateralModule` | MAKE | `abi.encode(provider, MarketParams[, permit])` — pull wrapped native, unwrap, payable supply |
| `ListaNativeCollateralTakerModule` | TAKE | `abi.encode(provider, moolah, MarketParams[, BalanceMode])` — provider pays native, wrapped back → receiver |
| `ListaSmartSupplyCollateralModule` | MAKE | `abi.encode(provider, coin, coinIndex, minLpRateE18, MarketParams[, permit])` — one-sided coin zap into LP collateral |
| `ListaSmartTakerModule` | TAKE | `abi.encode(provider, moolah, coinIndex, minOutRateE18, MarketParams)` — burn LP units, one coin → receiver |
| `ListaPreFundModule` | MAKE (preFund) | `abi.encode(forDesc, moolah, MarketParams)` — supply the core-delivered leg from the module's own balance |

### The two files, split by venue

`ListaModules.sol` + `ListaPreFundModules.sol` are the **Moolah** (collateral)
half. `ListaBrokerModule.sol` is the **broker** (debt) half — all of it: borrow,
and repay in BOTH funding shapes behind one body.

That merge is not cosmetic. The broker repay branch used to be written twice —
once on a pull-funded maker module, once inside the pre-funded sibling — and it
drifted: the `repayAll` full-close sentinel landed on the pull twin and not on
the pre-funded one, so a maker signing the documented sentinel handed the broker
`type(uint256).max` as a literal fixed-position id. One body, one meaning for
`loanId`, and the two shapes can no longer disagree.

Hosting a MAKE and a TAKE seam on one contract is safe because they draw on
DIFFERENT Permit3 books (token vs taker), and the op word makes it structural
anyway: each entrypoint asserts its own op and reverts `BadOp` on the other's.
See `test/security/TakerModuleAuth.t.sol`.

**The pre-fund shape** ("supply/repay whatever the conversion delivered"): the
maker routes the signed output leg to the module (`recipient = module`), so the
DELIVERED asset needs no ERC20 approval, no Permit3 token allowance and no
Moolah `setAuthorization` (both value-in venue ops are permissionless on behalf;
the provider-gate caveat above still applies to supply-collateral). Only that
branch is descriptor-restricted — on `ListaBrokerModule` everything else is the
PULL branch, gated by the maker's Permit3 token allowance instead. ⚠
Fork-validated deviation: the DEPLOYED broker rejects `repay(0, …)`
(`ZeroAmount()`), so both shapes pass a literal amount and rely on the broker's
repay-up-to-debt/refund-excess behaviour (measured on a BSC fork).

## Collateral-provider coverage

Lista's Moolah gates a market's collateral behind `providers(id,
collateralToken)`; the provider's SHAPE decides which modules serve the market.
Resolve it off-chain (`lista-collateral-providers.json`) and FAIL CLOSED on an
unknown provider. All four shapes are fork-covered:

| provider shape | markets | supply | withdraw |
|---|---|---|---|
| **none** | 14 of 22 brokered | `ListaSupplyCollateralModule` (venue = Moolah) | `ListaTakerModule` op 1 |
| **erc20** (slisBNB `0x33f7…`) | 5 | same module, venue = provider (plain forwarder, permissionless supply) | `ListaTakerModule` op 2 (venue = provider, sig-auth vs Moolah) |
| **native** (WBNB `0x3673…`) | 1 (WBNB/lisUSD) | `ListaNativeSupplyCollateralModule` (payable-only venue: unwrap → `supplyCollateral{value}`) | `ListaNativeCollateralTakerModule` (provider pays native; wrapped back, ERC20 out) |
| **smart-lp** (`SmartProvider`) | 1 brokered (slisBNB&BNB/WBNB) + non-brokered | `ListaSmartSupplyCollateralModule` (one pool coin in, `minLpRate` floor) | `ListaSmartTakerModule` (`withdrawCollateralOneCoin`, `minOutRate` floor) |

The debt side is orthogonal: brokered markets use the broker ops above on ANY
collateral shape (`test/leverage/SmartLp.t.sol` proves SmartLP collateral +
fixed-term broker borrow end to end). SmartLP notes: the collateral receipt is
`onlyMoolah`-transferable, so the modules move POOL COINS, never the LP;
slippage floors are signed as 1e18-scaled RATES (per-slice `amount * rate /
1e18`) because MAKE/TAKE amounts pro-rate while `data` is static; a native pool
coin (the 0xEeee… sentinel) fails closed — enter/exit through the ERC20 coin.

## Scope & caveats

See **[BROKERS.md](BROKERS.md)** for the complete deployed-broker reference:
all 22 live brokers (2 Ethereum + 20 BSC), the verified-source entrypoint
semantics, and the variant axes (wrapped-native loan tokens, collateral
provider shapes, oracle wiring, mutable term menus).

- **Only the fixed-term broker borrow is delegable.** Lista's flex (dynamic)
  borrow is a bare `broker.borrow(uint256)`, `msg.sender`-only, so it cannot be
  driven by a module — deliberately omitted.
- The on-behalf `broker.borrow(amount, termId, user, receiver)` signature is
  **CONFIRMED against the Sourcify-verified `LendingBroker` source**
  (2026-09-04): it gates on `MOOLAH.isAuthorized(user, msg.sender)`, requires
  `receiver != 0`, and always pays ERC20 (never native).
- **`repay(0, …)` reverts `ZeroAmount()` on EVERY deployed broker** — a
  source fact, not a fork quirk (`_pullPayment` transfers the literal amount,
  then zero-checks; there is no repay-from-balance convention). Both repay
  modules therefore pass the explicit amount and rely on repay-up-to-debt +
  refund-to-`msg.sender` (the refund lands on the module, swept to the
  maker): `ListaBrokerModule` passes `forAmount` on the pre-fund shape and the
  maker-signed ceiling on the pull shape — **fixed 2026-09-04** (it
  originally encoded `repay(0, …)` and could not execute; fork-proven since
  by `test/leverage/BrokerRepay.t.sol`, which closes a flex and a fixed
  position against the live BSC broker and pins the `ZeroAmount()` revert).
- **Full closes: `loanId == type(uint256).max` maps to the broker's
  `repayAll(onBehalf)`** — one call retires dynamic + all fixed positions by
  shares (no dust), immune to the refinance race. `repayAll` pulls exactly
  the live total debt and refunds nothing; the module's scoped approval caps
  the pull at the maker-signed ceiling, so a short ceiling fails closed and
  the un-pulled remainder sweeps to the maker (fork-proven, both buckets in
  one item, in `test/leverage/BrokerRepay.t.sol`).
- `loanId == type(uint128).max` selects the flex position on repay — an SDK
  convention mapped to the 2-arg `repay(amount, onBehalf)` overload; the
  broker itself takes a plain `uint256 posId`. Fixed posIds are small
  sequential uuids, so neither sentinel can collide with one.
- Partial repays leaving `0 < remaining < Moolah.minLoan` (~$15) revert
  `broker/fixed-below-min-loan`; term menus are bot-mutable (termIds are NOT
  stable — read `getFixedTerms()` live before encoding a borrow).

## Tests

Fork BNB Chain where Lista/Moolah is deployed (set an RPC endpoint). The
`security/` auth check runs without a fork.

```
FOUNDRY_PROFILE=modules-lista forge test --root ../../../..
```
