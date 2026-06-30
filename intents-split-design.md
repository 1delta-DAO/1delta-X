# Design: split USDRIF exit — `instantBps` deposit + auction remainder

**Builds on:** [`intents-integration-plan.md`](./intents-integration-plan.md) (variant 1, shipped as
[`packages/modules-usdrif`](./packages/modules-usdrif)).
**Adds:** a deposit-holding escrow that splits each exit into an **instant leg** (paid now from a
USDT0 float) and an **auction leg** (the existing intent), where the split fraction is a
**runtime parameter** (`instantBps`) on the deposit/intent — not a hardcoded mode.

The escrow is the plan's deferred **variant‑2 escrow** ([plan §3.4](./intents-integration-plan.md))
and the deferred **LP backstop** ([plan §10](./intents-integration-plan.md)) fused into one
contract, parameterised so `instantBps = 0` degrades to pure-auction and `instantBps = 10000`
to pure-instant.

---

## 1. The split, in one picture

```
 deposit(D usdrif, instantBps = b)          one redeemTP(recipient = escrow) for the FULL D
        │                                              │  (~30–90s) escrow receives R RIF
        ▼                                              ▼
 ┌──────────────┐   instant: pay user now      ┌──────────────────────────────┐
 │              │   q = quote(D·b)  USDT0  ◀────│  ESCROW float (USDT0 capital) │
 │  USER (EOA)  │   from float                 └──────────────────────────────┘
 │              │                                       owns  R·b/1e4  RIF  (it pre-paid)
 │              │   auction: signs intent over user's   ┌──────────────────────────────┐
 │              │   claim  =  R·(1e4−b)/1e4  RIF   ────▶ │  claim ledger: user ⇒ opId,b │
 └──────────────┘                                       └──────────────────────────────┘
        │                                                        │
        │ later: solver fills the auction intent                 │ TAKE item releases the
        ▼                                                        ▼ user's RIF share from escrow
   USER ◀── USDT0 ── SOLVER ── RIF ◀────────────────────────────  ESCROW
```

One `redeemTP` for the whole deposit. The escrow keeps the **instant share** of the realised RIF
(its inventory, to refill the float) and ledgers the **auction share** as the user's claim. The
user is paid instantly for `b/1e4` of the exit and auctions the rest at a better price.

---

## 2. Why this shape (the binding constraints)

Two on-chain facts from the verified mechanics drive every decision:

1. **`redeemTP` enforces `recipient == msg.sender`** ([facts](./packages/modules-usdrif/ARCHITECTURE.md#L166)).
   → a contract can only redeem **to itself**. So the escrow-holds-deposits design is the *only*
   way to put redemption behind a contract — and it works: the escrow is `msg.sender`, RIF lands
   in the escrow.
2. **The settlement verifies the maker with raw `ecrecover` — no EIP‑1271**
   ([`UniversalSettlement._verifySignature`](./packages/core/src/settlement/UniversalSettlement.sol#L415-L420)).
   → the **escrow cannot be the order `maker`**. The **user stays the EOA signer**; the escrow only
   *releases* the user's RIF into the fill via a TAKE item. No settlement change is needed.

And the one that makes "instant" cost money:

3. **MoC redemption is always async** (queued, executed by the guard, ~30–90s). There is **no
   synchronous redeem**. So the instant USDT0 can only come from the escrow's **float**, and the
   float carries 30–90s timing risk + RIF price/slippage risk until it sells the instant-share RIF.
   The `instantBps` haircut is the price of that risk.

---

## 3. Components

| Component | Kind | New? | Role |
|---|---|---|---|
| `ZvEscrow` | contract (holds deposits + float) | **new** | `deposit(...)` → redeem-to-self, pay instant leg from float, ledger the auction claim; `claim(...)` no-fill fallback; float owner/keeper sells instant-share RIF. |
| `ZvRedeemTakerModule` | `ITakerModule` | **new** | `takeOnBehalf(user, amount, receiver=settlement, data)` releases the user's auction RIF share out of `ZvEscrow` into the settlement. Permit3-gated, `msg.sender == permit3`. |
| `RedemptionSettledValidator` | `IOrderValidator` | **reuse** | gate the auction order on `opId < firstOperId()` **and** escrow holds ≥ the claim. |
| `DepegGuardValidator` | `IOrderValidator` | **reuse** | gate both the **instant quote** (escrow reads it internally) and the **auction fill** to a MoC price band. |
| `UniversalSettlement` | core | **unchanged** | user is maker; TAKE item + `_payTokenInToSolver` local-balance path already supports module-funded `tokenIn`. |

The whole instant/float subsystem (capital, NAV, keeper) lives in `ZvEscrow`. The auction leg is
*exactly* variant 1, only with the RIF sourced from the escrow via a TAKE item instead of from the
user's wallet.

---

## 4. Deposit flow (the `instantBps` parameter)

```solidity
struct DepositParams {
    uint256 usdrifAmount;  // D — full amount the user is exiting
    uint16  instantBps;    // b — share paid instantly (0..10000), the runtime split knob
    uint256 qACmin;        // MoC redemption floor for the WHOLE D
    uint256 minInstantOut; // user's slippage floor on the instant USDT0 (revert if quote < this)
}

function deposit(DepositParams calldata p) external payable returns (uint256 opId, uint256 instantOut) {
    // 1. pull the full USDRIF from the user (Permit3 / transferFrom)
    // 2. redeemTP(USDRIF, p.usdrifAmount, p.qACmin, recipient = address(this)) {value: execFee}
    //      → records opId; escrow receives R RIF in ~30–90s
    // 3. INSTANT LEG (only if b > 0):
    //      require depeg guard in band (escrow reads IPriceProvider.peek())
    //      instantOut = quoteInstant(p.usdrifAmount * b / 1e4)   // peg − instantHaircut
    //      require instantOut >= p.minInstantOut && float >= instantOut
    //      transfer instantOut USDT0 from float → user
    //      escrow now OWNS  b/1e4  of opId's realised RIF (it pre-paid for it)
    // 4. AUCTION LEG (only if b < 10000):
    //      ledger[user][opId] = Claim({ shareBps: 1e4 - b, qACmin: p.qACmin })
    //      (user signs the auction intent off-chain — see §5)
}
```

`instantBps` is the only new degree of freedom. Everything else is mechanical. The split is *per
deposit*, so the same user can exit 90/10 today and 0/100 tomorrow.

---

## 5. Auction leg = variant 1 with escrow-sourced RIF

The user signs the **same** RIF→USDT0 `Order` as today, with three deltas:

```
maker          = USER (EOA — must stay the signer; settlement is ecrecover-only)
tokenIn        = RIF
tokenOut       = USDT0
amountIn       = qACmin · (1e4 − b)/1e4            (floor of the user's auction share)
items          = [ TAKE { module: ZvRedeemTakerModule, amount: amountIn,
                          recipient: settlement, data: abi.encode(escrow, opId, user) } ]
validators     = [ RedemptionSettledValidator(opId, escrow, minRif),  DepegGuardValidator(band) ]
decayStartTime = depositTime + ~90s ; startAmountOut → endAmountOut (dutch)
```

On `fill`, the settlement:
1. runs the validators (settled? in band?),
2. pays USDT0 solver→user,
3. **executes the TAKE item** → `ZvRedeemTakerModule.takeOnBehalf` moves the user's auction RIF
   share out of escrow into the settlement (escrow debits `ledger[user][opId]`),
4. [`_payTokenInToSolver`](./packages/core/src/settlement/UniversalSettlement.sol#L285-L296) pays
   the solver from that settlement-local RIF — no wallet pull needed, user never custodies RIF.

The user authorises the taker once via `permit3.approveTaker(module, key(opId,user), amount, exp)` —
same trust model as every other taker module ([ITakerModule](./packages/core/src/interfaces/ITakerModule.sol#L42-L60)).

---

## 6. Share accounting (the realised RIF is unknown at deposit)

RIF amount `R` is fixed only at MoC execution, so the escrow ledgers **proportions, not amounts**:

```
at deposit:   escrow_owns_bps[opId] = b              (instant share, escrow's inventory)
              ledger[user][opId]    = { shareBps: 1e4 - b }
at execution: escrow receives R RIF for opId
              escrow inventory  +=  R · b / 1e4       (sell via keeper to refill float)
              user claim worth  =   R · (1e4 - b) / 1e4   (releasable via TAKE item / claim())
```

Surplus handling mirrors variant 1: the auction order's `amountIn` is the **floor**
(`qACmin · auctionBps`); if RIF fell and more RIF was delivered, the dust above the floor stays in
the user's claim and is withdrawable via `claim()`. `escrow_owns_bps` and the sum of user
`shareBps` for an op always total `1e4`.

---

## 7. Failure & edge cases

| Case | Handling |
|---|---|
| **No solver fills the auction leg** | user calls `claim(opId)` → escrow transfers the user's RIF share to them. Same "no worse than self-redeem" guarantee as variant 1 (user just ends in RIF). |
| **Float too small for instant leg** | `deposit` reverts on `float < instantOut`, or the escrow caps `instantBps` to what the float covers and returns the effective `b`. Pick one; cap-and-return is friendlier. |
| **Depeg during deposit** | `DepegGuardValidator` band checked *before* quoting the instant leg → revert; user can still deposit with `instantBps = 0` (pure auction, no float risk). |
| **Realised RIF < qACmin** | MoC reverts the redemption at the source → whole `deposit` reverts, float untouched. |
| **Op dequeued but errored (no RIF)** | `RedemptionSettledValidator`'s explicit RIF-balance floor blocks the auction fill; `claim()` reverts on zero balance. |
| **Instant-share RIF sale loss** | borne by the float (the LP), priced into `instantHaircut`. This is the LP's business risk, isolated to the escrow. |

---

## 8. Risk model — the float is an LP

`instantBps > 0` turns the escrow into a liquidity provider. It must be capitalised and
risk-managed; this is the real cost of "instant," stated honestly:

- **Capital**: a USDT0 float sized to expected instant volume between keeper refills.
- **Inventory risk**: instant-share RIF held ~30–90s + until sold; `instantHaircut` must cover RIF
  vol + sell slippage + margin. The measured RIF→USDT0 depth (~$36k / 2–3%,
  [plan §7](./intents-integration-plan.md)) caps prudent per-deposit instant size.
- **Keeper**: a permissioned role that, after execution, sells the escrow's instant-share RIF and
  refills the float. Off the user's critical path.
- **Accounting**: float balance + outstanding-claim liabilities = NAV; needed if the float is ever
  multi-LP / share-tokenised (defer; single-owner float first).

`instantBps = 0` is always available and carries **none** of this — it's pure variant 1 routed
through the escrow, so the escrow can ship before the float is funded.

---

## 9. Build order

1. **`ZvEscrow.deposit` with `instantBps = 0` only** + `claim()` + the auction ledger. This is
   variant‑2 escrow with zero float risk. Reuse both existing validators; add the TAKE-item path.
2. **`ZvRedeemTakerModule`** + fork e2e: deposit(b=0) → execute queue → solver fills via the TAKE
   item (user never holds RIF). Extends the existing [UsdrifExit.t.sol](./packages/modules-usdrif/test/UsdrifExit.t.sol) matrix.
3. **Add the instant leg** (`instantBps > 0`): float, `quoteInstant`, depeg-gated quote,
   `minInstantOut`. Fork test: deposit(b=5000) → assert instant USDT0 paid now, auction leg still
   fills for the rest, shares total `1e4`.
4. **Keeper** RIF-sale path + float refill; NAV accounting.
5. **SDK**: `deposit` calldata builder (compute `qACmin`, `instantBps`, `minInstantOut`) +
   auction-order builder with the TAKE item and `approveTaker`.

## 10. Reused vs new

- **Reused unchanged**: `UniversalSettlement`, `Permit3`, `RedemptionSettledValidator`,
  `DepegGuardValidator`, the dutch-auction + TAKE-item machinery, the MoC interfaces.
- **New**: `ZvEscrow` (deposit/redeem-to-self/float/ledger/claim), `ZvRedeemTakerModule`, the
  keeper sale path, and SDK helpers. No core/settlement edits.
</content>
</invoke>
