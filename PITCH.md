# 1delta-x: Intent-Based Lending, Solved

DeFi lending is powerful. Using it is not.

Today, creating a leveraged position on Aave requires 5+ transactions. Migrating collateral from Compound to Morpho requires manually unwinding one position and rebuilding another — while praying the market doesn't move against you mid-migration. Setting up a stop-loss on a lending position? You can't. You just watch your screen and hope.

**1delta-x changes this.** One signature. Any lending operation. Any protocol. Executed atomically by competitive solvers.

---

## For users: sign once, done

A user never submits a transaction. They sign a single off-chain message that says what they want:

- *"Deposit my ETH and open a 3x leveraged long on Aave"*
- *"Move my entire Compound position to Morpho"*
- *"If ETH drops below $2,500, deleverage me automatically"*

That's it. No gas estimation, no multi-step approvals, no monitoring. A solver picks up the intent, sources the liquidity (flash loans, DEX aggregation, whatever it takes), and executes it atomically. The user's signed order guarantees they get at least the rate they agreed to — enforced on-chain by dutch auction math.

**The experience is: describe what you want, sign, walk away.**

No failed transactions. No stuck intermediate states. No MEV sandwiching your multi-step migration. The solver bears the execution complexity and gas costs. The user gets a clean, atomic outcome.

---

## For builders: infinite composability

The protocol doesn't hardcode lending operations. It defines a universal module interface — `deposit`, `withdraw`, `borrow`, `repay` — and lets anyone plug in any lending protocol behind it.

**Today, six protocols are supported out of the box:**

| Module | Protocols covered |
|--------|-------------------|
| Aave | V2, V3, Spark, Seamless, and any fork |
| Morpho | Morpho Blue, Lista/Moolah, any Morpho fork |
| Compound V3 | All Comet markets |
| Compound V2 | Venus, Benqi, Moonwell, and forks |
| Silo V2 | All Silo markets |
| Universal | Routes to any of the above via a single address |

Adding a new protocol is one contract: implement seven functions (four actions + three balance views), deploy, whitelist. The settlement contract doesn't change. The order format doesn't change. Solvers don't need updates. Users don't notice.

**Every module carries a `bytes data` parameter** — an opaque blob that the maker commits to in their signature. This is where protocol-specific configuration lives: Aave's interest rate mode, Morpho's full MarketParams (5 fields), Compound's comet address, Silo's collateral type. No lowest-common-denominator compression. Each protocol gets its native parameterization, signed and validated on-chain.

This means the system is not just multi-protocol — it's multi-*version*, multi-*market*, multi-*mode*. A single order can deposit ETH as protected collateral on Silo V2 while borrowing USDC at variable rate from Aave V3 through a specific pool address. The signed intent captures all of it.

---

## From simple to sophisticated

### Basic: Position migration

*"Move my USDC supply from Aave to Morpho."*

The solver settles two lending items in one atomic batch: withdraw from Aave, deposit to Morpho. No capital at risk during the transition. No exposure window.

### Intermediate: Leveraged entry

*"I have 1 ETH. Give me 3x leverage on Aave with USDC debt."*

The solver flash-loans USDC, swaps to ETH via a DEX aggregator, deposits 3 ETH into Aave, borrows USDC against it, and repays the flash loan — all inside the settlement callback. The user signed one message. The dutch auction guarantees a minimum conversion rate for the USDC→ETH swap. The solver profits from the spread between the auction rate and their actual execution.

### Advanced: Conditional stop-loss

*"If ETH drops below $2,500, deleverage my Aave position to 1.5x."*

The order includes a `PRICE_LTE` condition pointing at the ETH/USD Chainlink feed. Solvers monitor the price off-chain. The moment the oracle reports a price at or below the threshold, the solver submits the settlement. The on-chain condition check confirms the trigger. The settlement atomically withdraws collateral, swaps, and repays debt — reducing leverage in a single block.

This isn't a centralized keeper. It's a competitive solver market. Multiple solvers race to fill the order when the trigger fires, ensuring timely execution.

### Expert: Multi-condition debt swap

*"When USDC borrow rate on Aave exceeds 8% AND DAI rate on Morpho is below 5%, swap my debt from USDC/Aave to DAI/Morpho."*

Two `PREDICATE` conditions — each pointing at a custom contract that reads protocol rates and returns a boolean. When both conditions are true simultaneously, solvers execute a cross-protocol debt swap: flash-loan DAI, repay USDC on Aave, borrow DAI on Morpho, repay flash loan. One signature. One block. Done.

### Composable conditions

Conditions are AND-composed arrays. Mix and match freely:

```
[PRICE_GTE(ETH/USD, $3000)]                              → price trigger
[MAX_GAS_PRICE(15 gwei), MIN_TIMESTAMP(next Monday)]     → cheap + scheduled
[PRICE_LTE(ETH/USD, $2500), BALANCE_GTE(WETH, 1e18)]    → stop-loss with balance guard
[PREDICATE(healthFactorChecker), MAX_GAS_PRICE(20 gwei)] → custom logic + gas limit
```

Any on-chain state can be a trigger. If a contract can read it, a condition can gate on it.

---

## Why solvers want this

Solvers in 1delta-x aren't charities — they're rational profit-seeking agents, just like Flashbots searchers or 1inch resolvers. Their incentive:

**Dutch auctions create a time-decaying profit opportunity.** When a maker signs an order with a conversion (e.g., "swap my borrowed USDC into ETH collateral"), the required exchange rate starts aggressive (expensive for the solver) and decays toward the maker's worst acceptable rate. Solvers who execute earlier get a tighter spread but first-mover advantage. Solvers who wait get a wider spread but risk being outbid.

**Lending-only orders compensate via MEV.** When there's no conversion, solvers are compensated by the execution environment itself — priority fees, block positioning, or bundled transactions. Gas-price conditions ensure the solver doesn't overpay to execute.

**Zero capital lockup.** Solvers compose flash loans from Aave, Balancer, or any provider. They never need to hold inventory. The entire flow — borrow, swap, settle, repay — happens in a single transaction with no capital commitment.

---

## Security model

**Users cannot be drained.** The settlement contract only executes operations that the maker explicitly signed via EIP-712. Every lending item — the protocol module, the asset, the amount, and the protocol-specific parameters — is committed in the signature hash. A solver cannot change the pool, the interest rate mode, or the market params.

**Modules are whitelisted.** Only owner-approved lending modules can be called. A rogue module address in an order is rejected before any tokens move.

**Bitmap nonces prevent replay.** Each order uses a unique nonce tracked in a gas-efficient bitmap (256 nonces per storage slot). Makers can cancel individual orders or bulk-invalidate 256 nonces in a single transaction.

**Dutch auctions enforce minimum rates.** For conversions, the maker signs the worst rate they'll accept. The on-chain math guarantees it. The solver can give a better rate; they cannot give a worse one.

**Conditions are validated on-chain.** Oracle prices, balances, timestamps, gas prices, and arbitrary predicates are all checked during settlement. A solver cannot fill a stop-loss order when the price hasn't actually dropped.

---

## The bigger picture

DeFi lending protocols are infrastructure. Aave, Morpho, Compound, Silo — they're the rails. But nobody wants to operate rails manually. Users want outcomes: *"protect my position," "maximize my yield," "get me leveraged."*

1delta-x is the intent layer for lending. It translates human-readable goals into atomic, solver-executed, protocol-agnostic operations — with the full security guarantees of on-chain validation.

**One signature. Any protocol. Any strategy. Executed by a competitive solver market.**

That's lending, solved.
