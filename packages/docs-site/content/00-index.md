---
title: What 1delta x is
slug: index
eyebrow: Overview
description: An intent settlement system for lending and trading. One signed order describes a trade, a lending action, the conditions it may run under and the price it may run at — and any permissionless filler executes it in a single transaction.
---

1delta x is an **intent settlement system**. A maker signs one EIP-712 `Order`
off-chain. That order describes, in a single object:

- the fungible assets it **gives** and **receives** (baskets on both sides, not just one pair);
- arbitrary actions on the maker's **own lending positions** — deposit, borrow, withdraw, repay on any wired venue;
- **conditions** that must hold before it runs and invariants that must hold after;
- a **price curve** between two signed endpoints, and which clock or oracle moves along it.

Any filler may execute it. The filler is the counterparty, pays gas, and keeps
whatever surplus the price curve leaves. There is **no admin, no module
whitelist, no upgradeability and no on-chain orderbook**: authority is the
maker's signature plus the maker's own allowances, and nothing else.

## The problem it solves

Two things a DeFi user does are normally in separate worlds. Trading is an
intent — "sell this at that price, someone else pays gas" — and is well served by
limit orders and solver networks. Working with a lending position is not: opening
leverage, migrating collateral between venues, swapping a debt asset or
deleveraging into a price move is a multi-step transaction the user has to sign,
fund, time and pay for themselves, at the moment they happen to be looking.

Existing intent settlers move fungible tokens between two parties. They cannot
express "borrow against my collateral and sell the proceeds", because the
borrow is an action on the *maker's* position, not a transfer between maker and
filler, and the settler has no way to be authorised for it.

1delta x closes that gap with a second allowance book and a module seam. The
result is one order format in which:

| A user can sign | And it settles as |
|---|---|
| A limit order or TWAP on a token pair | the fungible fast path, inline, no module dispatch |
| "Open 3× ETH leverage when ETH < $2,800" | deposit + borrow items, gated by an oracle validator |
| "Move my Aave position to Morpho" | withdraw + deposit items, funded by each other, no flash loan |
| "Swap my USDC debt for USDT debt" | a fused borrow/repay item at one venue |
| "Deposit my USDC into Aave, I have no gas" | an outputless order whose rising input leg pays the relayer |
| "Stop-loss my position at the oracle price" | a Chainlink validator plus a withdraw/repay item |
| "Sell this NFT to whoever fills first" | a `SETTLE` item with a maker-signed fill denominator |
| "Sell 100% of whatever I hold, capped" | a balance-relative input leg resolved at fill time |

Every one of those is the *same* order struct, the same settlement contract and
the same permissionless filler set. The differences live in maker-signed data.

## What it gives each party

**Makers** keep custody until the instant of the fill, and keep it under their
own allowances. Nothing is escrowed, no contract holds their funds between
signing and settling, and the price floor or ceiling they signed is absolute —
no clock, no oracle, no filler and no hostile module can price a fill outside
the band the maker signed.

**Fillers** get an open, permissionless market. There is no whitelist and no
registration; the reference solvers in the repository hold no inventory between
fills, and the netted path lets two opposite orders clear against each other
with no capital at all. A losing race is cheap by design.

**Order sources** — a wallet, an aggregator, a frontend — earn a fee as an
ordinary signed output leg, with their own recipient. There is no fee switch, no
protocol owner and no cap registry to negotiate with, and a filler can neither
inject nor redirect that leg.

**Integrators** add a lending venue by shipping one package of single-operation
modules. No registry entry, no governance vote, no settlement change and no
solver update: a maker simply names the new module address in the order it signs.

## The shape of a fill

```
maker                             filler                          on-chain
─────                             ──────                          ────────
sign Order (EIP-712)
  └─ legsIn / legsOut
     items (MAKE/TAKE/SETTLE)
     validators / invariants
     price curve + clock
        │
        ├── published off-chain ──▶ orderbook (REST / WS / Waku / 7683)
        │                                   │
        │                            quote with SettlementLens.previewFill
        │                                   │
        │                            fill(order, sig, amount) ──▶ Settlement
        │                                                          ├ verify signature + nonce + deadline
        │                                                          ├ run validators   (staticcall)
        │                                                          ├ deliver outputs  (priced now)
        │                                                          ├ run items        (pro-rata slices)
        │                                                          ├ pay filler from this fill's proceeds
        │                                                          └ run invariants   (staticcall)
        └──────────────────── assets move once, atomically ────────┘
```

A partial fill scales **everything** — every leg on both sides and every item —
by one scalar, so a filler cannot size the legs independently and repeated
partial fills accumulate exactly to the signed totals.

## What makes it different

**Authority is per-operation, not per-account.** The allowance a maker grants is
keyed by `(user, spender, module, ref)` where `ref` is the hash of the exact
signed parameter blob. Approving a borrow module for one market at one size
cannot be used to withdraw collateral, to borrow elsewhere, or to dispatch a
different module.

**Everything exotic is a module, and the fast path stays free.** The fungible
legs are settled inline. Everything else — a venue action, an NFT, a fill
denominator, a price source, a condition — is a maker-signed, pay-per-use call.
An order that uses none of them pays a calldata compare, not a dispatch.

**A price source can choose only where inside the band a fill lands.** External
price modules return a *bump* that the core clamps to `[0, 10000]` and maps
through each leg's own signed `start`/`end` — not an amount. A hostile, stale or
broken oracle module cannot price outside the maker's signed floor, cannot
redirect a leg and cannot introduce a token.

**Netting without inventory.** `matchSettle` clears N orders against the
settlement pool instead of a solver's balance sheet, with the solver supplying a
flat step schedule and every per-order check deferred to one flush at the end.
Two mirror orders clear with no AMM and zero solver inventory — and because the
composition is a schedule rather than a re-entrant callback, the reentrancy guard
stays intact and the whole deferred context lives in memory.

## Status

Nothing in the repository is deployed. The protocol has had several **internal**
security reviews and **no external audit**; several newer module packages compile
and pass their gates but await fork validation. Read
[Security](/security/) for the trust model, the failure classes considered, and
the caveats an integrator has to know before writing an encoder — and
[Reference](/reference/) for the honest list of limits and gaps.

## Where to go next

| Page | What it answers |
|---|---|
| [The signed order](/order-model/) | What a maker actually signs, field by field, and what each field is allowed to do |
| [How it works](/architecture/) | The contracts, the fill flow, the allowance hub, the module seam, the netted path, the off-chain stack |
| [Security](/security/) | The attack vectors considered, what structurally prevents each, and the audit record |
| [Optimization](/optimization/) | The gas and bytecode techniques, what each cost, and the ones that measured worse |
| [Reference](/reference/) | Glossary, repository map, build commands, limits and known gaps |
