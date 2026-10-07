# 24. Book: permit announces stay Fillable after the permit deadline

- **Status:** open
- **Layer:** backend
- **Package:** `packages/orderbook` (`verify.ts`, `book.ts`)
- **Severity:** medium — wasted filler simulations, polluted book; no funds
- **Source:** 2026-10-06 pre-merge audit of the working set (four review agents: contracts, modules+tooling, filler, book/app/sdk)
- **Opened:** 2026-10-06

## Problem

`batch.deadline` is checked only at Layer 1
([verify.ts:236](../packages/orderbook/src/verify.ts#L236)); `revalidate` evicts on
`order.expiry` alone ([book.ts:786](../packages/orderbook/src/book.ts#L786)), and for
permit rows `toResult` reports `Fillable` ignoring `fillableAmount`. A 5-minute permit
on a 24-hour order is served as fillable for ~24 h while every `fillWithPermit`
reverts. Same for a batch granting less than the order needs.

## Change

Store the permit deadline with the entry and evict (or drop to the non-permit view)
at `min(order.expiry, batch.deadline)`; reject at Layer 1 a batch whose granted amount
is below the order's input.

## Acceptance

- Tests: a permit entry is evicted at its deadline; an under-granting batch is
  refused at Layer 1. Mirror in `orderbook-worker` (wraps the same Book).
