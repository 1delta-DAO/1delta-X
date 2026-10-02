---
title: How it works
slug: architecture
eyebrow: Technical
description: Three on-chain layers — Settlement, Permit3, modules — plus a netted settlement path, a periphery and an off-chain stack. What each one is responsible for, and why the boundaries sit where they do.
---

## The three layers

```
   maker (EIP-712 order + Permit3 allowances)
        │
        ▼
   Settlement ───────────── the only trusted "spender" ───────┐
        │  fill(order, sig, amount)                           │
        │                                                     │
        ├─ MAKE item ─▶ IMakerModule.makeOnBehalf(...)        │  gated: msg.sender == settlement
        │                 └─ permit3.transferFrom(...)  ◀──────┤  token book (spender = module)
        │                                                      │
        └─ TAKE item ─▶ permit3.take(module, maker, ...)  ◀────┘  taker book (spender = settlement)
                          └─ ITakerModule.takeOnBehalf(...)      gated: msg.sender == permit3
                                └─ protocol borrow / withdraw
```

**Settlement** verifies the order, runs the gates, prices the legs, dispatches
items and pays the filler out of the proceeds *that fill produced*. It is the one
address makers approve as a spender. It holds no funds between fills, grants no
ERC20 approvals, and is not payable.

**Permit3** is the allowance hub: a Permit2-derived token book plus a second book
for pulling value *out of a position*.

**Modules** are single-operation adapters — one Aave borrow, one Comet withdraw.
They are shared singletons with no authority of their own; what they may touch is
bounded by the caller pin plus the grant the maker made.

## Permit3 — two allowance books

| Book | Key | Consumed by |
|---|---|---|
| Token | `(user, spender, token)` | `transferFrom(user, to, token, amount)` — `msg.sender == spender` |
| Taker | `(user, spender, module, ref)` | `take(module, user, amount, receiver, data)` — `msg.sender == spender`, `ref = keccak256(data)` |

The token book is the familiar Permit2 shape. The **taker book** is the piece
that makes lending intents possible: borrow, withdraw, unstake, claim and vault
redeem do not fit the ERC20 `transferFrom` shape, so they get their own
spender-keyed grant. `take` decrements `(user, msg.sender, module, ref)` and then
calls `module.takeOnBehalf(...)`, which performs the protocol-native call.

Both books are **spender-keyed**: a standing allowance can only be consumed by
the spender the maker approved — Settlement — which then enforces the
maker-signed recipient. The `module` is part of the taker key as well, so a grant
for a borrow module is unusable to dispatch any other module whatever its data.

Permit3 also carries signed allowance grants (`permitBatch`, with an order-hash
witness), one-shot signed transfers, and the revocation surface: `revokeToken`,
`revokeTaker`, `lockdown`, `lockdownAll`, plus **strict mode**, which makes
revocation binding for makers who opt in.

## The fill flow

```
fill(order, sig, fillAmountIn)

  verify        signature / delegate / on-chain approval, deadline, nonce, exclusivity
  gates         validators — staticcall, AND-composed, filler-aware
  open          write `filled`, resolve the bump once, resolve the denominator
  deliver       solver → recipients: every output leg, priced now       (inline, no dispatch)
  items         per item, pro-rata slice:
                  MAKE    module.makeOnBehalf(maker, slice, data)
                  TAKE    permit3.take(module, maker, slice, recipient)
                  SETTLE  module.settle(maker, filler, slice, data)
  pay           settlement → solver: the input legs, from this fill's measured proceeds
  invariants    staticcall, after everything
```

Entry points, all sharing that flow:

| Entry point | For |
|---|---|
| `fill(order, sig, amount)` | the hot path; exact size; an overload takes `takerData`; accepts an EIP-2098 64-byte signature |
| `fillWithCallback(...)` | solver callback at `PreDelivery` (any order) or `PostInputs` (item-free, just-in-time liquidity out of the fill's own proceeds) |
| `fillWithPermit(...)` | fill with a Permit3 batch whose witness is `SettlementOrder{settlement, order}` — the order bound to this one settler — so no prior on-chain approval |
| `fillWithPermitTake(...)` | fill whose TAKE item is funded by a one-shot `PermitTake` (order-hash witness, settler-bound spender) — no taker allowance survives |
| `batchFill(...)` | several independent single-order fills in one transaction |
| `fillSelf(...)` | `batchFill`'s self-call target (`msg.sender == address(this)` only) |
| `fillUpTo(...)` | router / aggregator entry: clamps to remaining size (except a Proportional request, which is never trimmed — pass `type(uint256).max` — and a fill-module order, which the module sizes at or below your request), returns `(delta, received, paid)`, takes a `minBumpBps` price floor |
| `matchSettle(MatchPlan)` | netted N-order settlement (below) |

## Netted settlement — `matchSettle`

Every entry point above runs one order against the filler's balance sheet.
`matchSettle` clears N orders against the **settlement pool** instead: inputs are
pooled, each maker's outputs are delivered from that pool, and the filler never
holds the transient peak. Two mirror makers clear with no AMM and zero filler
inventory — even when the batch is imbalanced.

The filler supplies a flat **step schedule**, and every per-order check is
deferred to one flush:

```
PHASE 1  OPEN      per order: gates → open the fill → compute outputs,
                   derive and snapshot the touched-token universe
PHASE 2  SCHEDULE  the filler's packed steps, verbatim:       ← the only filler-ordered region
                     PULL(i,j)   maker → pool, credits what arrived
                     DELIVER(i)  pool → recipients, all output legs
                     ITEM(i,k)   one MAKE/TAKE; a TAKE's proceeds are credited
                     PRESEND(t)  pool → solver, surplus net of undelivered obligations
                     CALL(x)     one interaction, through an allowance-less executor
PHASE 3  FLUSH     per order: completeness → credit ≥ owed (surplus → maker)
                   → invariants → whole-check + sweep
```

Phases 1 and 3 are contract-owned loops over every order, so a schedule can
reorder the middle but can never skip a gate or a check. Three consequences:

- **Items interleave with deliveries.** Mutually dependent orders — A's collateral funded by B's borrow *and* vice versa — settle with no flash loan, no filler inventory and no callback.
- **No re-entrancy is involved.** The composition a callback would express becomes a schedule, so `nonReentrant` stays intact and the whole deferred context lives in **memory** — no storage, and no transient storage.
- **Invariants assert the end of the context**, not of an individual order. A maker appearing twice in one match is judged on its final state.

Each maker is charged and paid its **own** signed curve; only the counterparty
(the pool) differs. `profitRecipient` is a destination only — authority still
keys on `msg.sender`. The order hash is unchanged: `matchSettle` adds no field to
`Order`.

## Modules

Every module binds its caller: taker modules require `msg.sender == permit3`,
maker and settle modules require `msg.sender == settlement`. Each performs
exactly one operation, which keeps blast radius small — approving a borrow module
can never be used to withdraw collateral.

The one documented exception is a **fused** module: one call that performs a
value-in and a value-out leg together (supply + borrow, repay + withdraw, a debt
swap), because some venues check health *inside* the value-out call. The
granularity lost at the module boundary is recovered by the allowance key: a
fused module's `data` names both legs, so approving `(module, ref)` authorizes
exactly that composite at those parameters.

### Venue coverage

| Lender | Delegation primitive | Status |
|---|---|---|
| Aave V2 | `approveDelegation` · aToken approve | shipped |
| Aave V3 (+ Spark, Seamless, forks) | same — pool-agnostic, forks need no new code | shipped |
| Aave V4 | hub/spoke position manager | shipped |
| Compound V2 (+ forks) | cToken approve | shipped, pool-agnostic |
| Compound V3 (Comet) | `allow(manager)` | shipped |
| Venus | `updateDelegate` + `enterMarkets` | shipped |
| Euler V2 | EVC `setAccountOperator` | shipped |
| Morpho Blue | `setAuthorization` | shipped |
| Morpho Midnight | `setIsAuthorized` | shipped (order-book venue) |
| Fluid | just-in-time position-NFT custody | shipped |
| Dolomite | `setOperators` | shipped |
| Silo V2 | `setReceiveApproval` · share allowance | shipped |
| Exactly | ERC-4626 share allowance | shipped, floating and fixed-maturity |
| Lista DAO | Moolah `setAuthorization` | shipped, fixed-term legs |
| River (Satoshi) | diamond `setDelegateApproval` | shipped (CDP) |
| Liquity V2 (+ forks) | per-trove add/remove managers | shipped (CDP) |
| Gearbox V3 | pool ERC-4626 · `setBotPermissions` | pool solid, credit best-effort |
| Teller V2 | permissionless value-in only | deposit + repay |

Other families: generic **ERC-4626** vault withdraw/redeem, plain **transfer**
modules (including an EIP-2612 permit replayed inside the fill), a **USDRIF**
exit path, and **bridge** modules over Across, LayerZero OFT and Circle CCTP.

Adding a lender is one package implementing the single-op module interfaces. No
registry, no whitelist, no settlement change, no solver update.

## Cross-chain

Two destination hosts, both exploiting the fact that `order.maker` is
simultaneously the funding source and the position owner:

| | `BridgedOrderInbox` (shared) | `PositionFunnel` (per user) |
|---|---|---|
| destination orders | swap only — items forbidden | swap **or** leverage |
| authorised by | bridged commitment → on-chain `approveOrder` | owner signature → EIP-1271 |
| bridge payload | 64-byte commitment | none (plain transfer) |
| refunds | permissionless `settle` after a deadline | withdraw, any time |
| cost | none | ~60k one-off clone per user per chain |

`FunnelGrantModule` supplies **just-in-time allowances** as items, so a funnel
runs a leverage order with no standing approvals: a grant can only create a
Permit3 allowance (never transfer, never call), is sized to the item's pro-rata
slice, and expires in the current block.

## Periphery

- **`SettlementLens`** — exact fill preview (`previewFill`, same math as the contract), `previewBump` for a filler's price floor, `getOrderRelevantStates` (one call returning everything an off-chain book needs to decide whether an order is live and funded), signature check, and `validateOrder` with a human-readable reason.
- **`NativeSettler` + `NativeForwarderFactory`** — native ETH handled entirely at the edge, so the core and Permit3 stay ERC20-only while a maker can still pay native into a WETH-denominated order in one transaction. One WETH input leg and any number of output legs (fee splits, originator fee legs); name `NativeSettler` as the hard `exclusiveFiller` when the order is meant only for it.
- **ERC-7683 adapters** — `OriginSettler7683` / `DestinationSettler7683`, for distribution: existing solver fleets resolve and fill these orders through an interface they already speak. `orderId` is the EIP-712 order hash, and the adapters are **escrow-free** — `open`/`openFor` verify liveness and broadcast rather than take custody, because maker funds move only at fill time under the maker's own allowances. Quotes are priced for the destination settler (soft windows include the outsider premium; hard windows, SETTLE items and delta-verify orders are not broadcast), and the destination ENFORCES the quoted per-unit bounds against `fillUpTo`'s return (`BoundExceeded`); solvers may pass their own `FillerData{payTo, minBumpBps, bounds}`.
- **`DustHandler`** — residual disposal for MAKE modules: sweep to the user, or best-effort recycle back into the position with an automatic fall back to sweep when a re-supply would revert (supply caps, frozen reserves, isolation mode).

## Reference solvers

The repository ships fillers that hold no funds between fills:

- `BaseFlashSolver` — the shared flash → fill → swap → repay machinery, with one leverage solver per flash provider (Balancer v2, Aave v3, Morpho Blue, Euler EVK, Morpho Midnight), plus multi-input and multi-output variants for basket orders.
- `AggregatorFillSolver` — fills from DEX-aggregator liquidity, with an explicit surplus policy.
- `MatchRaceGuard` / `GuardedMatchSolver` — the cheap-loss guard for contested `matchSettle` races; see [Optimization](/optimization/#filler-side-losing-cheaply).
- `UsdrifInventorySolver` — the inventory-holding case, for fills whose recycle leg cannot complete inside the fill transaction.

## Off-chain stack

- **`@1delta-x/sdk`** — viem-only TypeScript for both sides: build, hash and sign orders, witness-bound Permit3 batches, cancellations, filler calldata, off-chain dutch pricing. A golden test pins the SDK's order hash against the contract's `hashOrder` byte for byte.
- **`@1delta-x/orderbook`** — transport-agnostic distribution: a protobuf wire format, a two-layer verification pipeline (local recover / deadline / shape, then a chunked on-chain lens call, TTL-cached), an in-memory book with expiry, signed soft-cancel eviction and atomic cancel-and-replace. Eviction is **event-driven**: a `ChainWatcher` turns Settlement logs into evictions with zero RPC, so the periodic sweep is only a safety net for what no log announces (a maker's balance falling away).
- **`@1delta-x/orderbook-server`** — a Fastify REST/WS reference backend.
- **Waku transport** (design) — a decentralized mesh for signed orders. Orders are self-authenticating `(Order, sig)` tuples any node verifies against `DOMAIN_SEPARATOR()`, so the mesh needs no trust. The spam defense is RLN rate limiting, a cheap→expensive verification pipeline and a per-maker negative cache, with the on-chain fill revert as the capital backstop.

## Deployment

Permit3, the core and the bridge package land on **identical addresses on every
chain** through a shared CREATE2 factory. The source compiles to only three
distinct bytecodes across all EVM versions, so portability reduces to PUSH0 +
MCOPY and `evm_version` is a global choice: **`cancun`**, which puts 38 of 43
surveyed chains in one address family.

Settlement does not fit under legacy codegen — the deploy profile compiles
via-IR, and `make size-check` gates it. See
[Optimization](/optimization/#the-eip-170-wall).
