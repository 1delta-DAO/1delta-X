# @1delta-x/modules-usdrif

USDRIF → USDT0 exit via `Settlement`, implementing the integration in
[`FEATURES.md`](../../../../FEATURES.md). A USDRIF
holder exits to USDT0 in one signed intent, filled by competing solvers, by
tokenising MoC's native redemption and auctioning the resulting RIF.

> 📊 See [`ARCHITECTURE.md`](./ARCHITECTURE.md) for sequence / flow / component
> diagrams of how the pieces fit together.

## Flow (plan variant 1)

```
STEP 1  user calls MoC redeemTP(USDRIF, qTP, qACmin, recipient = user)
          → escrows USDRIF, queues a RedeemTP op; ~30–90s later the MoC
            executor delivers a fixed amount of RIF to the user.
        user signs a Order: tokenIn = RIF, tokenOut = USDT0,
          amountIn = qACmin, startAmountOut → endAmountOut (dutch decay),
          decayStartTime ≈ now + 90s, validators = [settled, priceBand?].

STEP 2  any solver calls settlement.fill(order, sig, amount):
          solver ──USDT0──▶ user   (≥ endAmountOut floor, enforced by Settlement)
          user   ──RIF────▶ solver (Permit3 pulls the now-settled RIF)
```

By fill time the RIF is a present, fixed on-chain fact, so the fill is a clean
synchronous swap. The settlement is the marketplace; solvers bring the capital.

## Why there is no redeem "module" contract

The plan sketched a `RedeemInitiator` wrapper that pulls USDRIF and redeems **to
the user**. On-chain, MoC's `redeemTP` enforces **`recipient == msg.sender`**
(`RecipientMustBeSender()`), and exposes no recipient-flexible variant. A helper
contract can therefore only redeem *to itself* — which is the plan's variant‑2
escrow + claim token, explicitly out of scope for the first cut. So variant 1 is
correct: **the user calls `redeemTP` directly** (no module needed — the plan's
own §2), and this package's contribution is the two order validators.

## Contracts (`src/`)

| Contract | Role |
|---|---|
| `RedemptionSettledValidator` | `IOrderValidator` — passes once the maker's MoC op has been executed *and cleared* (`MocQueue.opersInfo(opId).operType == 0`, bounded by `operIdCount()`) **and** the user holds ≥ `minRif` RIF. Clean revert + binds the exact `opId`. `data = abi.encode(mocQueue, opId, user, minRif)`; RIF is an immutable. |
| `MocPriceBandValidator` | `IOrderValidator` — passes only while a MoC `IPriceProvider.peek()` quote is inside a signed band. `data = abi.encode(priceProvider, minPrice, maxPrice)`. **Optional, and only worth carrying on a RESTING order** — see the note below. For Chainlink-style feeds, compose the core `ChainlinkPriceGte/Lte` instead: they enforce a signed staleness heartbeat, which `peek()` cannot. |
| `interfaces/IMoc.sol` | Minimal MoC core / queue / price-provider surfaces. |

Both validators are pure read-only triggers; `target` + `data` are in the order's
EIP‑712 hash, so the solver cannot alter them.

### What `MocPriceBandValidator` does and does not protect (renamed 2026‑08‑14)

It was `DepegGuardValidator`, which overstated it. The MoC provider quotes the
pegged token in **asset-collateral terms** — USDRIF per RIF (~7.09e16 live,
~6.85e16 at the tests' pinned block), the same rate `getPACtp` exposes. Being
denominated in USDRIF, it **cannot see a USDRIF depeg**: USDRIF 10% down and RIF
10% up read identically. It bands the collateral price, and nothing else. A real
depeg guard needs a USDRIF/USD source, and the decision it informs — redeem at
all? — is taken before the redemption is queued, one step earlier than any order
validator can run.

Within that, only half the band does work. On a sell order `minPrice` is
near-redundant (the signed output floor already stops fills at a collapsed price —
solvers just walk away); `maxPrice` is the half that earns its gas, capping the
free option a resting order hands solvers when the collateral rallies after
signing. And `peek()` has no `updatedAt`, so a frozen feed reads in-band forever:
this is cover against slow drift, not against a fast move on a stale quote. Bound
that with a short expiry.

Net: skip it for an order that fills within seconds, carry it on a resting one.

## Verified Rootstock mainnet facts (used by the fork tests)

| Thing | Value |
|---|---|
| USDRIF (18 dec) | `0x3A15461d8aE0F0Fb5Fa2629e9DA7D66A794a6e37` |
| RIF (18 dec, redemption output) | `0x2AcC95758f8b5F583470ba265EB685a8F45fC9D5` |
| USDT0 (6 dec) | `0x779Ded0c9e1022225f8E0630b35a9b54bE713736` |
| MoC RIF core (proxy) | `0xA27024Ed70035E46dba712609fc2Afa1c97aA36A` |
| MoC queue (proxy) | `0x47f5014115d3bb29B20b5168Ee75050D6f8c3Bf1` |
| MoC price provider — `peek()` = **USDRIF per RIF** (~7.09e16), *not* USDRIF/USD | `0x6a5b2C84E63b5C1330bf4CcCff1Ad6F23116CC14` |
| Multi-collateral guard (executes the queue) | `0x0237Ad1f0831b479a344E56646BC48B0885cF46F` |

- `redeemTP(tp, qTP, qACmin, recipient, vendor)` is **payable**; `msg.value` must
  equal `MocQueue.getExecFee(OperType.redeemTP)` = `execCost × block.basefee`
  (`OperType.redeemTP == 4`; on Rootstock BASEFEE returns the block's
  minimumGasPrice per RSKIP-412 — the fee does NOT track `tx.gasprice`, so pin
  it with `vm.fee` in fork tests). `recipient` must equal `msg.sender`.
- Operations execute FIFO via `MocQueue.execute(...)`, which is restricted to the
  multi-collateral guard — the fork tests impersonate it. `firstOperId` advances
  past **dequeued** ops, which is enough for off-chain tracking; the on-chain
  validator uses the stricter `opersInfo(opId).operType == 0` (executed *and*
  deleted), since a dequeued op may have errored and refunded.
- The price provider exposes no AggregatorV3 surface — `latestRoundData()`
  reverts on mainnet, which is why `MocPriceBandValidator` reads `peek()`.

## Tests

Forked Rootstock mainnet (chain id 30, pinned block 8_920_000). Set `RSK_RPC_URL`
to use your own archive node; otherwise public RSK RPCs are tried.

```
pnpm --filter @1delta-x/modules-usdrif test
# or, from the repo root:
make test-modules-usdrif
```

The e2e drives the real flow: user redeems → impersonated guard executes the
queue → solver fills the RIF→USDT0 order. Covers the plan's §9 matrix — fill
reverts before settlement (via the validator and via the implicit Permit3 RIF
pull), fill succeeds after settlement, and the price band gates in/out of band
(plus a reversed band, pinning that a validator revert reads as `false`).

## Out of scope (first cut)

Variant‑2 escrow + `zvClaim` token (a contract-mediated redeem that delivers a
fungible claim as `tokenIn`); single-tx bundled redemption + fill. See the
plan's §3.4 / §6 / §10.

An inventory-funded solver now exists at
`packages/solvers/src/inventory/UsdrifInventorySolver.sol`: it fills a direct
USDRIF→USDT0 order from its own USDT0 inventory and recycles the USDRIF via
MoC redemption itself — the one-signature alternative to the two-phase flow
above (and the stepping stone to the plan's LP "backstop solver").
