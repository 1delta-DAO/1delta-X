# Settlement

Core entry point for the lending intent system. Verifies maker-signed
EIP-712 orders and orchestrates lending operations and conversions.

## UniversalSettlement.sol

Permit3-native limit-order settler with partial fills, optional dutch
decay, and pro-rata lending-item execution. No module whitelist; no
admin role. All authority flows through Permit3 allowances + the
maker's EIP-712 signature.

> **Multi-asset conversion.** The conversion leg is a basket on both sides:
> the maker gives `tokenIn[]`/`amountIn[]` and receives
> `tokenOut[]`/`startAmountOut[]`/`endAmountOut[]`. Partial fills are driven by
> the single fraction `fillAmountIn / amountIn[0]`, so every input, output, and
> lending-item leg scales together. The single-asset examples below are the
> `length == 1` case. See [`MULTI_ASSET.md`](./MULTI_ASSET.md) for the full
> design (struct, typehash, token flow, guards).

> **Settlement is the system's only trusted spender.** Makers approve it as
> their Permit3 taker/token spender; TAKE legs go through `permit3.take`
> (spender-keyed, so only Settlement can consume the allowance and it enforces
> the signed `recipient`), and MAKE legs call modules that require
> `msg.sender == settlement`. Settlement pays the solver only from the proceeds
> produced by the current fill. See [`/SECURITY.md`](../../../../SECURITY.md).

### Dutch auctions — how they work

The auction applies **only to the conversion** (`tokenIn ↔ tokenOut`),
not to lending items. Items always execute at their signed `amount`,
regardless of the current auction tick.

```
                    ┌─── conversion (auction-priced) ───┐
                    │                                    │
   solver ──tokenOut──▶ maker ──tokenIn──▶ solver
                    │                                    │
                    │  startAmountOut ─▷ endAmountOut   │
                    │  (decays linearly over time)      │
                    └────────────────────────────────────┘

                    ┌─── lending items (fixed amounts) ──┐
                    │                                     │
                    │  MAKE deposit 0.9 WETH              │
                    │  TAKE borrow 1500 USDC              │
                    │  (always these values, every fill)  │
                    └─────────────────────────────────────┘
```

#### Fixed price (no auction)

Set `startAmountOut == endAmountOut` (or `decayDuration == 0`).
The solver must pay exactly this amount. No time dependency.

**Use when:** self-solving, migrations, any order where the user
already knows the exact exchange rate they want.

#### Dutch decay (solver competition)

Set `startAmountOut > endAmountOut` with `decayStartTime` and
`decayDuration`. Price decays linearly from best-for-maker to
worst-for-maker. The `endAmountOut` is the maker's absolute floor
— no fill can ever pay less.

**Use when:** the user wants price discovery. Solvers compete by
filling earlier (paying more) or later (paying less). The first
solver whose expected profit exceeds gas + capital cost fills.

### How to size items relative to auction bounds

The critical constraint is for **MAKE items whose funding comes from
`tokenOut`** (i.e., the deposited/repaid asset is what the solver
pays). These pull from the maker's wallet, which holds `tokenOut`
only because the solver just paid it there.

```
item.amount ≤ endAmountOut · (1 − feeBps/10000)   (for MAKE items funded by tokenOut)
```

(Without a sourcing fee, `feeBps = 0` and this is just `item.amount ≤
endAmountOut`.) If `item.amount` exceeds this, a late fill (when the solver pays
only `endAmountOut` and the fee is then skimmed) can't fund the module's pull → tx reverts.
This is a malformed order, not a security issue — the revert
protects the user.

**If the MAKE item is funded by the maker's own balance** (the
deposited asset ≠ `tokenOut`), there is no constraint from the
auction. The item executes at its signed amount regardless.

**TAKE items** (borrow, withdraw) are never constrained by the
auction. They produce `tokenIn`, whose total is `amountIn` (fixed).

### Token flow during a fill

```
fill(order, sig, fillAmountIn)

1. solver → recipientOut: fillAmountOut of tokenOut   ← auction-priced, inline (0 dispatch)
2. for each item (pro-rata slice):
     MAKE:   module.makeOnBehalf(maker, slice, data)  ← maker deposits/repays
     TAKE:   permit3.take(module, maker, slice, to)   ← maker borrows/withdraws
     SETTLE: module.settle(maker, filler, slice, data)← generic solver↔maker exchange (filler-aware)
3. settlement → solver: fillAmountIn of tokenIn       ← fixed (or rising fee leg)
```

The typed `tokenIn`/`tokenOut` legs are the built-in **fungible fast path** —
settled inline, no module dispatch. Everything the fast path can't express is an
item module: MAKE/TAKE act on the *maker's* own assets, `SETTLE` handles the
*solver↔maker* exchange (an NFT sale, a cross-type trade) and is the only op that
receives the `filler` — see [Item ops & module kinds](#item-ops--module-kinds).

Partial fills slice everything proportionally:
```
fraction      = fillAmount / total          (total = fillTotal if set, else the leg anchor)
fillAmountOut = fillAmountIn × currentAmountOut / total   (ceil)
itemSlice     = item.amount  × fillAmount    / total      (cumulative)
```

Both scale by the same `fraction`, so items and the auction stay in sync across
partial fills. The **denominator** (`total`) is the fixed-side leg 0 for a
fungible order, or a maker-signed `fillTotal` when the fill unit isn't a fungible
amount (an NFT, an auction lot) — see [Fill denominator & fill modules](#fill-denominator--fill-modules).

Every fill above runs the solver as the counterparty: it delivers the maker's
output and receives the maker's input. The `fill` / `fillWithCallback` /
`batchFill` methods all share this single-order flow — the **hot path**, untouched
by everything below.

### Batch settle (coincidence of wants)

`batchSettle` is a *separate* entry point that clears N orders as one **netted**
batch. Instead of each order settling against the solver, every order's inputs are
pooled into Settlement first, each maker's net surplus is pre-sent to the solver,
a single solver interaction swaps that surplus into the net deficit, and every
output is delivered from the pool:

```
batchSettle(orders, sigs, fillAmounts, [takerDatas,] interactionTarget, interactionData)

1. per order: verify + open (writes `filled`) + pull inputs   makers → Settlement
   + compute (not yet deliver) every output amount
2. per token: PRE-SEND net surplus (pooled − owed)            Settlement → solver
3. one interaction (allowance-less EXECUTOR)                  solver swaps surplus → deposits deficit
4. per order: deliver outputs + run invariants               Settlement → makers/recipients
5. per touched token: require balance ≥ pre-batch snapshot    (BatchNotWhole else) + sweep residual → solver
```

Two mirror makers (`sell WETH→USDC` and `sell USDC→WETH`) thus clear against each
other with **no AMM** and **zero solver inventory** — even when the batch is
*imbalanced*, because the solver swaps the surplus it is handed into the deficit it
owes rather than fronting capital. Each maker is charged/paid its own signed curve
(identical math to a single fill); only the counterparty (the pool) differs.
Item-free only; the optional `takerDatas[]` threads a per-order blob into
validators/invariants/fill-module; golden hash unchanged. Full design:
[docs/batch-settle.md](../../../../docs/batch-settle.md).

### Item ops & module kinds

Everything beyond the typed fungible legs is a maker-signed module call. There
are three module kinds, each with a distinct scope — and only `SETTLE` learns who
the filler is:

| Kind (`ItemOp` / field) | Scope | Can move | Filler-aware? | Cost |
| --- | --- | --- | --- | --- |
| **MAKE** | maker deposits/repays | maker's funding token → protocol | no | 1 CALL |
| **TAKE** | maker borrows/withdraws | maker's position → `recipient` | no | 1 CALL (via Permit3) |
| **SETTLE** | solver↔maker exchange | maker's asset → filler, or filler's → maker | **yes** | 1 CALL, pay-per-use |
| **fillModule** | the fill *denominator* (a scalar) | nothing (view) | no | 1 STATICCALL, or 0 |

Trust model is uniform: every module binds `msg.sender == settlement`, so the
maker's order signature is the sole authority over `(module, amount, data)`, and
the maker's own approval to the module caps what it can move. `SETTLE`'s
`filler`-awareness lets the maker's asset route to *whoever fills* (e.g. an NFT
sale to an open solver set, no exclusivity); the maker's *receipt* is guaranteed
by the mandatory `tokenOut` delivery (run before items) and/or an invariant, not
by the module. Full design: [docs/settlement-modules.md](../../../../docs/settlement-modules.md).

### Fill denominator & fill modules

The fill is denominated by `total` — normally the fixed-side leg 0
(`startAmountIn[0]` for SELL, `startAmountOut[0]` for BUY). When an order's unit
isn't a fungible amount (a 1-of-1 NFT, an RFQ lot), the maker sets `fillTotal`
(the denominator) and optionally a `fillModule` that turns the filler's proposal
into the accepted **delta**. The core keeps the over-fill cap
(`filled + delta ≤ total`) and the single-fraction scaling; the module only picks
the delta (and can gate the taker↔maker match by reverting). Identity default —
`fillModule == 0` and `fillTotal == 0` — is byte-for-byte the classic fungible
fill, zero overhead. Full design + gas model: [docs/fill-modules.md](../../../../docs/fill-modules.md).

### Fee-on-transfer & rebasing tokens

Settlement moves **nominal, computed** amounts on the delivery and
solver-payout legs — it does not re-measure balances after a transfer to
confirm what actually arrived. (The one exception is TAKE proceeds *into*
Settlement, which are measured by balance delta for anti-donation.)

For a fee-on-transfer or rebasing token this means the recipient receives
**less than the recorded amount**, exactly as with common swap aggregators:

- **Solver bears the fee** (FoT on the leg the solver receives): the solver
  chooses to fill and can price the fee in — self-protected.
- **Maker bears the fee** (FoT on `tokenOut`): the maker is the passive party
  and is **silently underpaid**. `startAmountOut`/`endAmountOut` set the
  *computed* transfer amount, not a floor on the maker's actual received
  balance, so there is no automatic `minReturn`-style revert.
- **Accounting**: `filled` and the `OrderFilled` event report nominal amounts,
  so they **overstate** what moved for FoT tokens. No funds are lost or
  stranded — the numbers are simply pre-fee.

There is **no built-in FoT validation** — trading such tokens is the
maker's/solver's responsibility. A maker who wants aggregator-style protection
can attach a post-execution **invariant** asserting *"my `tokenOut` balance
increased by ≥ N"* (see Validators/invariants), which reverts the whole fill if
the fee eats into the floor.

### Fees — two actors, two instruments, no fee subsystem

There is no fee machinery in the settlement at all. Both fee actors are paid
through the order's ordinary legs, distinguished by whether the payee is known
at signing:

**Originator / sourcing fee (named payee) — a fee OUTPUT leg.** Every output
leg names its own `recipientOut[j]` (`address(0)` = the maker), so the party
that sourced the order is paid by simply adding one more signed leg addressed
to it:

```
tokenOut       = [ WETH,        WETH        ]
startAmountOut = [ gross − fee, fee         ]     (proportional start/end
endAmountOut   = [ …,           …           ]      = bps-of-tick fee;
recipientOut   = [ 0 (maker),   originator  ]      fixed = absolute fee)
```

- **No fee switch.** No protocol owner, no global toggle, no cap registry —
  the fee is an ordinary maker-signed delivery a solver can neither inject nor
  redirect. The wallet shows it as a plain amount + recipient in the EIP-712
  prompt (not an opaque packed word).
- **bps-of-tick fees**: give the fee leg `start/end` proportional to the main
  leg — both decay by the shared bump, so the realized fee is exactly the bps
  of the delivered tick. **Absolute fees**: a fixed fee leg. **Multiple
  recipients** (originator + partner tiers): one leg each.
- **Pro-rata for free** — legs slice like any output across partial fills.
- **Items untouched** — MAKE funding, TAKE proceeds, chaining, and the solver
  `tokenIn` payout ignore fee legs entirely. A `tokenOut`-funded MAKE item is
  simply sized to the MAKER leg's amount.
- **Soft exclusivity skips fee legs** — the `exclusivityOverrideBps` bump
  (deliver-more) is the maker's queue-jump compensation, so it applies only to
  legs delivered to the maker; a fee leg to a third party is never inflated (an
  absolute fee stays absolute). `recipientOut[j] == address(this)` burns the leg
  into the anti-donation baseline — a maker self-burn the Lens flags.
- For **outputless orders** (pure deposits/exits/repays — nothing delivered by
  the solver) the originator fee is a `FeeTransferModule` MAKE **item**
  instead: absolute amount, pulled from the maker, same pro-rata slicing.

**Relayer fee (anonymous payee) — a rising INPUT leg.** The filler's
compensation is normally the conversion spread. Orders with **no conversion
leg** — a pure gasless deposit is the canonical case — carry a dedicated input
leg that RISES instead: any SELL input leg with `startAmountIn < endAmountIn`
is charged at the shared auction tick (gas bump included), exactly the
BUY-input machinery. No flag, no opt-in — leg pricing is uniform:
`start == end` ⇒ fixed, `start != end` ⇒ auctioned (inputs may only rise,
outputs may only fall; a falling input reverts `InvalidAuctionParams`).

```
side      = SELL
items     = [ MAKE deposit D ]              (the real action)
tokenIn   = [ fee token ]  F0 → FMAX rising (the relayer fee, maker pays)
tokenOut  = [ ]                             (may be EMPTY — nothing delivered back)
```

The fee leg rises until the first filler for whom `tick ≥ gas + margin` fills —
auction-discovered, `gasBumpBps`-indexed, and requiring **zero filler capital**
(nothing is fronted; the filler only collects the fee leg). The anchor is the
fee leg (`startAmountIn[0]`), so pure deposits should be full-fill-only
(`minFillAnchor = anchor`).

### Funding: Permit3 or direct approval

Regular transfer legs (`tokenOut` delivery, `tokenIn` shortfall) try Permit3
first and **fall back to a plain ERC20 `transferFrom`** when the payer approved
Settlement directly instead of routing through Permit3 (the Euler EVK
`SafeERC20Lib` pattern, in `Permit3TransferLib`). Only the payer's own tokens
move, and only to the leg's fixed recipient, so the fallback grants no new
authority. A maker/solver holding a **standing direct approval** to Settlement
therefore opts out of Permit3's per-order allowance cap for that token — the
signed order amount remains the ceiling. The taker book (`take`, i.e. borrow/
withdraw dispatch) is **not** covered by the fallback and stays Permit3-gated.

### Worked examples

#### Pure swap (no lending items)

Maker sells USDC for WETH. No deposit, no borrow.

```
tokenIn  = USDC   amountIn = 2000e6
tokenOut = WETH   start = 1.0 ether   end = 0.95 ether   decay = 30 min
items: []
```

Solver fills when USDC/WETH market rate crosses the current tick.
No lending operations; this is a standard Dutch-auction limit order.

#### Deposit collateral (MAKE funded by tokenOut)

Maker receives WETH from solver and deposits it to Aave.

```
tokenIn  = USDC   amountIn = 1500e6
tokenOut = WETH   start = 1.0 ether   end = 0.9 ether   decay = 20 min
items: [MAKE AaveDeposit 0.9 WETH]
```

Item sized to `endAmountOut` (0.9). If solver fills early (pays 1.0),
maker pockets 0.1 WETH as bonus. If late (pays 0.9), all goes into
the deposit.

#### Deposit + borrow (solver fronts collateral)

Maker receives WETH, deposits it, borrows USDC.

```
tokenIn  = USDC   amountIn = 1500e6
tokenOut = WETH   start = 1.0 ether   end = 0.9 ether
items: [MAKE AaveDeposit 0.9 WETH, TAKE AaveBorrow 1500 USDC]
```

Solver pays 0.9–1.0 WETH, receives 1500 USDC from the borrow.
Their P&L = (1500 USDC at market) - (WETH paid at auction tick).
Borrow amount is fixed; auction only affects the collateral leg.

#### Withdraw + swap (user unwinds)

Maker withdraws WETH from Aave, sells it for USDC.

```
tokenIn  = WETH   amountIn = 1 ether
tokenOut = USDC   start = 2100e6   end = 2000e6
items: [TAKE AaveWithdraw 1 WETH, recipient = settlement]
```

Withdraw produces fixed 1 WETH at Settlement. Auction determines
how much USDC the solver pays the maker. Item amount is independent
of the auction — withdrawal always pulls exactly 1 WETH.

#### Migration (fixed price, no auction)

Close Aave, open Spark. No price discovery needed.

```
tokenIn  = USDC   amountIn = 3000e6
tokenOut = USDC   start = 3050e6   end = 3050e6   (fixed)
items: [MAKE repay 3050, TAKE withdraw 9 WETH → maker,
        MAKE deposit 9 WETH (Spark), TAKE borrow 3000 USDC]
```

`start == end` → no decay. The 50 USDC spread is the solver's fee
for executing the 4-item migration atomically.

#### Self-solve (maker fills their own order)

```
startAmountOut == endAmountOut   (always fixed price)
```

The maker signs and fills. No dutch decay — decay only benefits
solvers competing with each other. For self-solving, the user sets
their exact desired rate and submits in one tx.

### Validators (trigger conditions)

An order may carry an arbitrary `Validator[]` array. Each entry is a
read-only staticcall: Settlement invokes `target.validate(order, data)`
before executing any item and aborts the fill unless the return is
exactly `true`. Multiple validators are AND-composed; any single
`false` reverts with `ValidationFailed(i)`.

```solidity
struct Validator {
    address target;    // implements IOrderValidator
    bytes data;        // validator-specific params, signed in the typehash
}
```

**Safety properties:**

- `staticcall` forbids state mutation, logs, and reentrancy — a broken
  or malicious validator can do nothing beyond returning the wrong
  boolean.
- `target` and `data` are part of the EIP-712 typehash — the solver
  cannot swap in a more lenient validator or rewrite thresholds.
- All validators run *before* any item executes, so a failure is cheap.

**Reference validators** in [`src/validators/`](../validators/):

| Contract | Passes when | `data` |
|---|---|---|
| `ChainlinkPriceGte` | fresh feed price ≥ threshold | `abi.encode(feed, threshold, maxStaleness)` |
| `ChainlinkPriceLte` | fresh feed price ≤ threshold | `abi.encode(feed, threshold, maxStaleness)` |
| `PredicateStaticCall` | arbitrary staticcall returns non-zero uint256 | `abi.encode(target, callData)` |

The Chainlink validators read the full round and **reject stale or invalid
data**: `price > 0`, `answeredInRound >= roundId`, and
`block.timestamp - updatedAt <= maxStaleness` (the heartbeat is signed into the
order, so each feed binds its own freshness bound). A stalled or zero feed
reverts the fill rather than executing a stop-loss/take-profit at a wrong price.

**Example — stop-loss on an Aave position:**

```
// "Unwind my WETH collateral into USDC, but only if ETH ≤ $1500"

validators[0] = Validator({
    target: address(chainlinkPriceLte),
    data:   abi.encode(ETH_USD_FEED, int256(1500 * 1e8), uint256(3600)) // feed, threshold, maxStaleness (s)
});

tokenIn  = WETH   amountIn = 1 ether
tokenOut = USDC   start = end = 1500e6        // fixed price
items:
  [0] TAKE AaveWithdraw 1 WETH, recipient = settlement
```

Solvers monitor the feed off-chain and submit `fill()` when the gate
opens. Submitting earlier reverts with `ValidationFailed(0)` — free
protection for the maker against accidental early execution.

**Composing multiple triggers:**

```
// Only fill if ETH ≤ $1500 AND my aWETH balance ≥ 0.5 ether AND it's after 2pm UTC
validators[0] = Validator(chainlinkPriceLte, ...);
validators[1] = Validator(balanceGte,        ...);
validators[2] = Validator(timestampGte,      ...);
```

All three must return `true` for the fill to proceed. The user opts
into exactly the conditions they want at signing time; the solver
cannot weaken them.

### When NOT to use dutch decay

| Scenario | Reason |
|----------|--------|
| Self-solve | Decay only hurts the maker when they are the solver |
| Migration | Both legs are priced by the same user; no competition |
| Rebalance to exact ratio | User knows the exact amounts; decay adds nothing |
| Time-sensitive orders | If the user needs immediate fill, `start == end` guarantees it |
