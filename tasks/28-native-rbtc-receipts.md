# 28. App: receive native RBTC from a fill (in-fill unwrap)

- **Status:** open — deferred by the user (2026-10-12, "note it, skip for now")
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
