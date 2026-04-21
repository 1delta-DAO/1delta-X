# Settlement

Core entry point for the lending intent system. Verifies maker-signed
EIP-712 orders and orchestrates lending operations and conversions.

## LimitOrderSettlement.sol

Permit3-native limit-order settler with partial fills, optional dutch
decay, and pro-rata lending-item execution. No module whitelist; no
admin role. All authority flows through Permit3 allowances + the
maker's EIP-712 signature.

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
item.amount ≤ endAmountOut   (for MAKE items funded by tokenOut)
```

If `item.amount > endAmountOut`, a late fill (when the solver pays
only `endAmountOut`) can't fund the module's pull → tx reverts.
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

1. solver → maker: fillAmountOut of tokenOut         ← auction-priced
2. for each item (pro-rata slice):
     MAKE: module.makeOnBehalf(maker, slice, data)   ← pulls from maker
     TAKE: permit3.take(module, maker, slice, to)    ← pulls from position
3. settlement → solver: fillAmountIn of tokenIn      ← fixed
```

Partial fills slice everything proportionally:
```
fillAmountOut = fillAmountIn × currentAmountOut / amountIn   (ceil)
itemSlice     = item.amount  × fillAmountIn    / amountIn    (cumulative)
```

Both scale by the same `fillAmountIn / amountIn` fraction, so items
and the auction stay in sync across partial fills.

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

| Contract | Passes when |
|---|---|
| `ChainlinkPriceGte` | feed.latestAnswer ≥ threshold |
| `ChainlinkPriceLte` | feed.latestAnswer ≤ threshold |
| `PredicateStaticCall` | arbitrary staticcall returns non-zero uint256 |

**Example — stop-loss on an Aave position:**

```
// "Unwind my WETH collateral into USDC, but only if ETH ≤ $1500"

validators[0] = Validator({
    target: address(chainlinkPriceLte),
    data:   abi.encode(ETH_USD_FEED, int256(1500 * 1e8))
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
