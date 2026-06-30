# Plan: USDRIF→USDT exit via the intent settlement (module integration)

**Audience:** the intents / `UniversalSettlement` repository.
**Goal:** let a USDRIF holder exit to USDT0 in one signed intent, filled by competing
solvers, by tokenising the protocol's *native redemption* and auctioning the result. No new
AMM, no LP pool required in the base design — the settlement is the marketplace; solvers bring
the capital.

This plan targets the existing `UniversalSettlement` (signed orders, partial fills, dutch
decay, Permit3 auth, `IMakerModule` / `ITakerModule` / `IOrderValidator` plug-ins).

---

## 1. The flow

```
STEP 1  (user, one tx + one signature)
  user ──USDRIF──▶ RedeemInitiator
                     └─ calls MoC redeemTP(recipient = user, qACmin)   [escrows USDRIF, queues redemption]
  user signs a Order:  tokenIn = RIF,  tokenOut = USDT0,
                            amountIn = qACmin (guaranteed floor),
                            startAmountOut → endAmountOut (the haircut, dutch decay),
                            decayStartTime ≈ now + 90s

  ~30–90s later: MoC executor delivers a KNOWN, fixed RIF amount to the user.

STEP 2  (any solver, later)
  solver calls settlement.fill(order, sig, amount):
     solver ──USDT0──▶ user        (≥ endAmountOut floor; settlement enforces it)
     user   ──RIF────▶ solver      (Permit3 pulls the now-settled RIF from the user)
  solver disposes of the RIF "by any means" (atomic DEX sell, inventory, OTC) — their risk.
```

**Why this resolves the async problem:** the redemption is *initiated* in step 1 and has
*settled* before step 2. By fill time the output (RIF) is a present, fixed, on-chain fact —
so it is fully checkable and the fill is a clean, synchronous swap.

---

## 2. Key insight on what's actually needed

In the **minimal (variant 1)** design, the settlement needs **no new module at all**:

- The order is a plain `RIF → USDT0` limit order. The settlement already supports this (the
  README's "pure swap, no items" case).
- The fill *cannot* succeed until the user holds the RIF, because step 2 does a Permit3 pull
  of `amountIn` RIF from the maker — if the redemption hasn't settled, that pull reverts.
  Setting `amountIn = qACmin` (the redemption floor) guarantees the user holds at least that.
- `decayStartTime ≈ +90s` keeps the auction closed until the RIF can exist.

So the **base integration is: an off-settlement `RedeemInitiator` (UX wrapper for `redeemTP`)
+ a normally-constructed limit order.** Everything below is *optional hardening* that lives in
the intents repo.

---

## 3. Components

### 3.1 `RedeemInitiator` — UX wrapper (lives in ZipVault repo; optional `IMakerModule`)
Pull USDRIF from the user and start the MoC redemption so the user never touches `redeemTP`.

```solidity
function initiate(uint256 usdrifAmount, uint256 qACmin)
    external payable returns (uint256 opId);
    // pulls USDRIF (approve/transferFrom), forwards msg.value as the MoC exec fee,
    // calls MoC.redeemTP(USDRIF, usdrifAmount, qACmin, recipient = msg.sender, vendor = 0),
    // returns/records the queue opId for off-chain tracking.
```

Optionally also implement `IMakerModule.makeOnBehalf(onBehalfOf, amount, data)` so a future
single-tx flow can bundle the deposit into a fill via Permit3. **Not required for variant 1.**

### 3.2 `RedemptionSettledValidator` — `IOrderValidator` (lives in intents repo) — *recommended*
Belt-and-suspenders gate so a fill can only land after the user's redemption has actually
settled with sufficient backing. Even though the Permit3 RIF pull already enforces this
implicitly, an explicit validator gives a clean revert and lets the seller bind the exact
`opId`.

```solidity
// staticcalled by Settlement: validate(order, data) returns bool
// data = abi.encode(mocQueue, opId, address user, uint256 minRif)
function validate(Order calldata order, bytes calldata data)
    external view returns (bool);
    // true iff: opId no longer pending in mocQueue (executed)  AND
    //           IERC20(RIF).balanceOf(user) >= minRif
```

### 3.3 `DepegGuardValidator` — `IOrderValidator` (lives in intents repo) — *recommended*
Seller protection: only fillable while the RIF/USD (or USDRIF/USD0) oracle is within a band —
replaces ZipVault's old built-in circuit breaker, now signed by the seller. Can reuse the
existing `ChainlinkPriceGte` / `ChainlinkPriceLte` / `PredicateStaticCall` validators in
`src/validators/` if a compatible feed exists; otherwise a thin `PredicateStaticCall` over the
MoC price provider.

### 3.4 `zvClaim` token + escrow — *only if you choose variant 2*
If you prefer redemption `recipient = escrow` and a fungible/ tradeable claim as `tokenIn`
(more composable, abstracts that it's RIF). Adds an escrow + ERC20. **Skip for the first
cut** — variant 1 (redeem-to-user, plain RIF order) is strictly simpler.

---

## 4. The intent (Order) shape

```
maker            = USDRIF seller
tokenIn          = RIF                       (0x2AcC95758f8b5F583470ba265EB685a8F45fC9D5)
tokenOut         = USDT0                      (0x779ded0c9e1022225f8e0630b35a9b54be713736)
amountIn         = qACmin                     (guaranteed RIF floor from the redemption)
startAmountOut   = optimistic USDT0           (e.g. ~par − 1%)
endAmountOut     = seller's floor USDT0       (e.g. ~par − 4%)   ← hard minimum, enforced
decayStartTime   = deposit_time + ~90s        (auction opens after settlement)
decayDuration    = e.g. 10–30 min
items            = []                          (variant 1: no module legs)
validators       = [ RedemptionSettledValidator, DepegGuardValidator ]   (recommended)
invariants       = []
```

Pricing/competition is the dutch auction; "USDT0 output is enough" = `endAmountOut` floor,
guaranteed by the settlement. Solvers fill when current tick ≤ what they can realise from the
RIF minus their margin.

---

## 5. On-chain facts (Rootstock mainnet, verified 2026-06-02)

| Thing | Value |
|---|---|
| USDRIF token | `0x3a15461d8ae0f0fb5fa2629e9da7d66a794a6e37` |
| RIF token (redemption output) | `0x2AcC95758f8b5F583470ba265EB685a8F45fC9D5` |
| USDT0 / "USD0" | `0x779ded0c9e1022225f8e0630b35a9b54be713736` |
| USDT | `0xaf368c91793cb22739386dfcbbb2f1a9e4bcbebf` |
| MoC RIF bucket core (MocRif) | `0xA27024Ed70035E46dba712609fc2Afa1c97aA36A` |
| MoC RIF-bucket queue | `0x47f5014115d3bb29B20b5168Ee75050D6f8c3Bf1` |
| Uniswap v3 QuoterV2 (for solver routing) | `0xb51727c996C68E60F598A923a5006853cd2fEB31` |

- `redeemTP(address tp, uint256 qTP, uint256 qACmin, address recipient, address vendor)` —
  **payable** (queue exec fee in native RBTC). Escrows USDRIF, queues a `RedeemTP` op.
- Output RIF amount is fixed **at execution** (oracle price then), bounded below by `qACmin`.
  USD value is ~peg-locked regardless of RIF price.
- `minOperWaitingBlk = 1`; executor delivers in ~30–90s; queue currently has **no backlog**.
- DOC bucket is empty (~$18) → redemption pays **RIF** in practice; ignore DOC for now.

---

## 6. Design decisions to resolve

1. **redeem `recipient`:** user (variant 1, simplest) vs escrow+claim (variant 2). → start with user.
2. **Who funds the MoC exec fee** (native RBTC at `redeemTP`): seller in step 1 (recommended).
3. **`amountIn = qACmin` vs realized RIF:** signing `qACmin` guarantees the pull succeeds;
   surplus RIF (if RIF fell, more RIF delivered) stays with the seller. Confirm this is the
   desired UX (seller keeps upside dust) vs. selling the full realized amount.
4. **Settlement-detection in the validator:** read `mocQueue` op-pending state vs. just trust
   the RIF balance check. Confirm how an executed op is represented (removed vs. flagged).
5. **Partial fills:** allow? If yes, the seller's RIF is sold in slices — fine, but confirm
   the validator/oracle band holds per slice.

---

## 7. Risks & honest constraints

- **Step 1 irreversibly commits USDRIF → RIF.** If no solver fills, the seller simply keeps
  the RIF (no worse than self-redeeming). Make this explicit in UX: "you are exiting to RIF;
  the intent auctions it for USDT0."
- **Thin RIF→USDT0 market is unchanged.** Atomic solver fills cap ~$36k / ~2–3% slippage
  (measured); larger exits need inventory solvers or chunking. The design makes the
  marketplace clean but does not manufacture liquidity.
- **RIF price + MEV risk** sits entirely with the solver, after they choose to fill a known
  amount — the correct place for it.
- **Oracle window (~30–90s)** between submit and execution: RIF *quantity* floats, value is
  peg-locked, `qACmin` is the floor. Minor.

---

## 8. Implementation steps

1. **`RedeemInitiator`** (ZipVault repo): `initiate(usdrif, qACmin) payable` → `redeemTP`,
   record `opId`. Forge tests against a forked Rootstock (real MoC core + queue).
2. **`RedemptionSettledValidator`** (intents repo, `src/validators/`): implement
   `IOrderValidator.validate`; unit-test against a mocked queue + RIF balance.
3. **`DepegGuardValidator`** (intents repo): reuse `ChainlinkPriceLte/Gte` or wrap the MoC
   price provider via `PredicateStaticCall`.
4. **End-to-end fork test:** initiate → wait for execution (advance blocks/executor) → build
   the signed order → `settlement.fill` from a mock solver that flash/inventory-sources USDT0
   and sells the RIF via QuoterV2/router. Assert seller nets ≥ `endAmountOut`.
5. **SDK helper:** build-order + initiate calldata; solver reference using QuoterV2 to decide
   fillability.
6. **(Optional, later)** `IMakerModule` on `RedeemInitiator` for a single-tx bundled flow;
   `zvClaim` escrow for variant 2; a ZipVault LP "backstop solver" for guaranteed fills.

## 9. Test plan (must-pass)

- Fill **reverts before settlement** (RIF not yet delivered) — both via Permit3 pull and via
  `RedemptionSettledValidator`.
- Fill **succeeds after settlement**, seller receives ≥ `endAmountOut`, solver receives `qACmin` RIF.
- **Depeg**: `DepegGuardValidator` blocks fills outside the band.
- **No-solver path**: seller can reclaim/keep the RIF.
- **Realized RIF < qACmin** path (oracle moved): redemption itself reverts/refunds at MoC layer
  → assert graceful handling.

## 10. Out of scope (first cut)

- LP pool / NAV / share token (not needed; solvers provide capital).
- DOC-bucket redemption (bucket empty today).
- USDT (non-0) routing — target USDT0, the deepest stable pair.
