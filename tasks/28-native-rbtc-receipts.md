# 28. App: receive native RBTC from a fill (in-fill unwrap)

- **Status:** open — steps 1–2 READY (2026-10-14): deploy script + Rootstock fork check pass; broadcast pending the owner
- **Layer:** contracts (deploy) + app + filler
- **Package:** `packages/modules/transfer` (`NativeUnwrapModule`), `packages/app`, `packages/beta-filler`
- **Severity:** feature — UX
- **Opened:** 2026-10-12

## Problem

A BUY of WRBTC delivers WRBTC. The only way to native RBTC is the wallet strip's
manual "unwrap" (`WRBTC.withdraw`, a second transaction paid in RBTC). The receive
selector offers no RBTC.

## Change

1. **Deploy `NativeUnwrapModule` on Rootstock.** It is outside the 6-contract
   pre-audit beta set, so this is an explicit owner decision. The module was in the
   2026-09 audit scope (pre-fund leg-ref consumer, F28).
2. **Check the fill path first, on a fork.** Run a fork test of an order with
   `legsOut = [WRBTC, amt, recipient = module]` plus one MAKE item
   (`data = forLegPreFund(j, payee)`) through `AggregatorFillSolver.executeFill`, on
   both the pool route and the API route. Learn a gas default for the shape (an
   estimated +35k for the withdraw and the native send).
3. **App:** add "RBTC" as a receive option on WRBTC markets, building the order shape
   above with the maker as payee. Fill tracking must read the payout, because the
   maker's WRBTC balance never moves.
4. **Filler:** quote the shape with its own gas default, keyed so that
   `gasShape` learns it separately.

## Why in-fill beats the manual unwrap

The in-fill unwrap costs about +35k gas inside the fill, charged into the quote. The
manual unwrap costs about the same plus a second transaction's 21k base, and the
user needs RBTC for it. That RBTC requirement also breaks the gasless flow.

## Pre-deploy check (2026-10-14)

- **No drift:** `NativeUnwrapModule.sol`, `packages/lib` and `packages/core/src` are
  unchanged since the deployed `b23ec90`, so the tree's module matches the live Settlement.
- **Script:** `packages/modules/transfer/script/DeployNativeUnwrap.s.sol`, run under the
  `modules-transfer-deploy` profile (Cancun). The make targets are
  `simulate-native-unwrap` and `deploy-native-unwrap` (env `SETTLEMENT`; `WRAPPED` defaults
  to WRBTC on chain 30). The script asserts both immutables after deploying.
- **Simulation** against public-node.rsk.co from deployer `0x00001d47…B30D` (nonce 5):
  the module lands at **`0xB6107a1DEa7Ae04129aBc27ce607249049f3C735`**, runtime 1,633 B,
  ~527k gas ≈ 0.0000137 RBTC. The deployer holds 0.0000719 RBTC.
- **Fork test:** `test/fork/NativeUnwrapRootstock.fork.t.sol`, opt-in via `RSK_FORK_URL`. It
  runs the LIVE Settlement and Lens with real WRBTC. A maker sells 50 USD₮0 and receives
  0.0006 raw RBTC in the same fill (211,904 gas, Cancun schedule); partial fills and an
  explicit payee also pass. The module ends empty.
- **Residual, not testable on anvil:** WRBTC `withdraw` pays the module through
  `transfer` (2300 stipend) under Rootstock's own gas rules. The module's `receive()` is
  empty, so this is expected to hold. One live 1-cent smoke fill after deploying settles it.

Deploy:
`SETTLEMENT=0xe6EDbb5c49Fb4CFb313476e3B78E274D3584ddf5 make deploy-native-unwrap RPC=https://public-node.rsk.co DEPLOY_ARGS="--account deployer --sender 0x00001d4754680958E7f8fe42D60842Ebde4Cb30D --legacy --slow" VERIFY_ARGS="--verify --verifier blockscout --verifier-url https://rootstock.blockscout.com/api/"`
