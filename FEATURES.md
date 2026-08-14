# 1delta-x — feature reference

A complete inventory of what the protocol does today. Scope note: this is a
descriptive writedown, not a roadmap — items that are partial, blocked, or
untested are marked as such in [Limits and known gaps](#limits-and-known-gaps).

**What it is.** An intent settlement system for lending and trading. A maker
signs one EIP-712 `Order` off-chain describing fungible legs it gives/receives,
arbitrary actions on its own positions (deposit / borrow / withdraw / repay on
any wired lender), pre- and post-execution conditions, and a price curve. Any
permissionless filler executes it in one transaction and keeps the surplus.
There is no admin, no module whitelist, and no on-chain orderbook.

---

## 1. Order model

One struct, [`Structs.sol`](packages/core/src/settlement/Structs.sol), carries
everything.

| Field group | Feature |
|---|---|
| `legsIn[]` / `legsOut[]` | Multi-asset baskets on both sides. Each leg is `(token, start, end)`; output legs additionally carry their own `recipient`. `legsIn[0].start` may instead carry a **balance-relative marker** — see below. |
| `side` (SELL/BUY) | SELL = fixed inputs, decaying outputs, anchored on `legsIn[0].start`. BUY = fixed outputs, rising inputs, anchored on `legsOut[0].start`. |
| `items[]` | Ordered list of maker-signed module calls: `MAKE`, `TAKE`, `SETTLE`. |
| `timing` | Three `uint32` clocks packed into one word (decay start, decay duration, exclusivity end), the item-ordering policy in bits `[96:100)`, fill-once (100), side (101), **BLOCK clock (102)** and **PRIORITY auction (103)**. |
| `curve` | Optional piecewise-linear decay shape (`CurvePoint[]`); empty = single linear segment. |
| `params` | One word holding the four auction scalars: soft-exclusivity bps, gas-bump bps, gas price reference, and the **priority-fee scale**. |
| `pricingModule` | Optional **external price provider** (`IPriceModule`) — oracle-pegged, range, or cosigner-quoted pricing. `0x0` = the built-in clock. |
| `exclusiveFiller` / `params` override bps | Hard exclusivity (only that filler until the deadline) or soft (anyone may jump the queue by improving the maker's leg by N bps). |
| `minFillAnchor` | Anti-dust floor per fill. |
| `validators` / `invariants` | AND-composed pre-execution triggers and post-execution invariants (staticcall only). |
| `fillModule` / `fillTotal` | Fill denominator decoupled from a fungible leg, for indivisible or exotic units. |
| `nonce` / `deadline` | Bitmap nonce (256 per slot) and expiry. |

**Uniform leg pricing.** `end == 0` is the "fixed" sentinel — the leg transfers
`start` on every fill. Otherwise the leg is auctioned on the order's shared
clock: inputs may only rise, outputs may only fall; a falling input reverts
`InvalidAuctionParams`. A fixed-price OTC order is simply `end == 0` everywhere.

**Single-fraction partial fills.** Every leg on both sides and every item slice
scales by one scalar `f = fillAmount / anchor`, so a solver cannot size legs
independently, and repeated partial fills accumulate exactly to the signed
totals.

**Balance-relative amounts.** `legsIn[0].start` on a SELL order may carry a
[`Proportional`](packages/core/src/settlement/Proportional.sol) marker instead of an absolute amount, encoding "sell N bps of
whatever I hold when this fills". The bps live in the top of the existing word
(above `type(uint256).max - 10000`, unreachable by any real token amount), so the
**typehash and golden hash are unchanged** and no order needs re-signing. Such an
order is whole-fill only — a live-balance denominator cannot measure partial
progress — and `end` becomes a **mandatory cap**, without which a balance that
grew after signing would be sold at the price of a much smaller one. Multi-token
sweeps are a module. See
[docs/proportional-legs.md](docs/proportional-legs.md).

**Packed array encoding.** `legsIn`, `legsOut`, `items`, `validators`,
`invariants`, and `curve` are packed `bytes` blobs
([`PackedArrays.sol`](packages/core/src/settlement/PackedArrays.sol)) rather
than struct arrays — materially cheaper to hash and to access than the
equivalent typed arrays.

---

## 2. Settlement entry points

All in [`Core.sol`](packages/core/src/settlement/Core.sol) /
[`Batch.sol`](packages/core/src/settlement/Batch.sol).

| Entry point | Purpose |
|---|---|
| `fill(order, sig, amount)` | The hot path. Overload with `takerData` for orders whose validators/fill module need a filler-supplied blob. |
| `fillWithCallback(...)` | Solver callback in two positions: `PreDelivery` (works for any order) or `PostInputs` (item-free; just-in-time liquidity out of the fill's own proceeds). |
| `fillWithPermit(...)` | Fill with a Permit3 batch bound to the order hash as a witness — no prior on-chain approval needed. |
| `batchFill(...)` | Several independent single-order fills in one transaction. |
| `fillSelf(...)` | The maker fills its own order (fixed price by construction). |
| `fillUpTo(...)` | Aggregator/router integration entry. Clamps to remaining size (race-tolerant) and returns full both-sides accounting `(delta, received, paid)`; `recipient` redirects payment only, never authority. `minBumpBps` is the filler's price floor on the resolved decay bump (`0` = off; quote it via `SettlementLens.previewBump`) — one scalar guards every leg because leg prices are monotone in the shared bump; reverts `BumpTooLow` below it. |
| `matchSettle(MatchPlan)` | Netted N-order settlement — see [§6](#6-netted-settlement-matchsettle). |

**Delegated signing**
([`OrderState.sol`](packages/core/src/settlement/OrderState.sol) /
[`Signatures.sol`](packages/core/src/settlement/Signatures.sol)):
`setOrderSigner(signer, expiry)` nominates a key that may sign the caller's
orders until `expiry`; `setOrderSignerWithSig(...)` does the same from a relayed
EIP-712 permit, for makers with no gas. See [§8](#8-authority-and-security-model).

**Cancellation** — five granularities, four authoritative and one free:

| Primitive | Scope | Binds a filler? |
|---|---|---|
| `cancelOrder(order)` ([`OrderState.sol`](packages/core/src/settlement/OrderState.sol)) | exactly ONE order, by hash — nonce siblings stay fillable | ✅ |
| `cancelOrders(nonces[])` ([`NonceManager.sol`](packages/core/src/settlement/NonceManager.sol)) | every order carrying any of those nonces (bulk) | ✅ |
| `invalidateNonceWord(word)` | 256 nonces in one SSTORE | ✅ |
| `rollbackNonces(minValid)` | everything below a watermark, one SSTORE | ✅ |
| signed `SoftCancel` ([`softcancel.ts`](packages/sdk/src/softcancel.ts)) | any set of hashes, **zero gas** | ❌ advisory |

`cancelOrder` is gas-free on the hot path: it parks `filled` at the
`type(uint256).max` sentinel, a slot every fill already reads, so the check is one
compare. The soft cancel is EIP-712 in the Settlement domain — deployment-bound,
batched, and verified under the same signer set an order is (EOA / EIP-1271 /
delegate). It evicts from books; it does not stop a filler that already holds the
order. See [docs/soft-cancel.md](docs/soft-cancel.md).

---

## 3. Items — acting on the maker's own positions

Three module kinds, one uniform trust rule (`msg.sender == settlement`, or
`== permit3` for TAKE dispatch):

| Op | Scope | Moves | Filler-aware | Cost |
|---|---|---|---|---|
| `MAKE` | maker deposits/repays | maker's funding token → protocol | no | 1 CALL |
| `TAKE` | maker borrows/withdraws | maker's position → `recipient` | no | 1 CALL via Permit3 |
| `SETTLE` | generic solver↔maker exchange | maker's asset → filler, or filler's → maker | **yes** | 1 CALL, pay-per-use |
| `fillModule` | the fill denominator (a scalar) | nothing (view) | no | 1 STATICCALL, or 0 |

- **`data` is opaque and signed.** Each module decodes its own protocol-specific
  params from `item.data`; the blob is inside the EIP-712 hash and is also the
  Permit3 taker-allowance preimage (`ref = keccak256(data)`), so a solver can
  never repoint the pool, market, rate mode, or receiver.
- **Item chaining.** A TAKE item's `recipient` defaults to Settlement (proceeds
  pay the filler); signing `recipient = maker` routes the proceeds into a
  subsequent MAKE item instead, which is how a migration or leverage entry
  composes with no intermediate solver capital.
- **Item ordering policy** (`ItemPolicy`): `ANY` (default), `ORDERED` (signed
  index order), `ATOMIC` (signed order, back-to-back, nothing interleaved — for
  lenders that check health inside each call). The single-order path always
  satisfies all three by construction and pays nothing; only `matchSettle` can
  violate one.
- **Fill modules shipped**: [`FullFillModule`](packages/core/src/modules/FullFillModule.sol)
  (all-or-nothing) and [`TwapFillModule`](packages/core/src/modules/TwapFillModule.sol)
  (one signed order releasing on a TWAP schedule).
- **Settlement modules shipped**: [`NftSettlementModule`](packages/core/src/modules/NftSettlementModule.sol)
  (ERC-721 to whoever fills — an open solver set, no exclusivity),
  [`Erc1155SettlementModule`](packages/core/src/modules/Erc1155SettlementModule.sol),
  [`OcoGroupModule`](packages/core/src/modules/OcoGroupModule.sol) (one-cancels-other,
  below).
- **Escape hatch**: [`PermissionlessCallModule`](packages/core/src/modules/PermissionlessCallModule.sol)
  executes one arbitrary maker-signed contract call as a MAKE item.

---

## 4. Pricing and auctions

- **Dutch decay on either side.** SELL orders decay outputs from best-for-maker
  toward the signed floor; BUY orders raise inputs toward the signed ceiling.
  The floor/ceiling is absolute — no fill can cross it.
- **Piecewise curves.** `curve` supplies arbitrary decay shapes (front-loaded,
  step-like, slow-then-fast) via interpolated `(timeDelta, bumpBps)` points on a
  single shared clock; every leg maps that one bump through its own bounds.
- **Gas-indexed bump.** `gasBumpBps` / `gasPriceRef` widen the filler's margin
  automatically when the network is expensive, so an order stays fillable across
  gas regimes without re-signing.
- **Exclusivity, hard and soft.** A named filler for a window, or a bps
  improvement any other filler must pay to jump in. The soft-exclusivity bump
  applies only to legs delivered to the maker — a third-party fee leg is never
  inflated.
- **Fixed price.** `end == 0` on every leg: exact OTC rate, no time dependency.
  This is the correct setting for self-solving, migrations, and exact rebalances.
- **Balance-relative sizing.** A SELL anchor may be signed as bps-of-balance
  rather than an absolute amount, resolved once at fill time against the maker's
  live balance and capped by the leg's `end`. Whole-fill only, and best filled
  through `fillUpTo`, whose clamp both resolves the size and bounds the solver
  against a stale quote. See [docs/proportional-legs.md](docs/proportional-legs.md).
- **Block clock** (`timing` bit 102). The decay clocks count BLOCKS instead of
  seconds. UniswapX moved its V3 reactor to a block clock for the same reason: on a
  chain with 250ms blocks, a one-second timestamp tick is eight blocks of
  resolution, which is coarser than the interval solvers actually compete over.
- **Priority auction** (`timing` bit 103) — the parity feature with UniswapX's
  `PriorityOrderReactor`, for chains whose sequencer orders by priority fee. The
  maker signs `start` as its ambition and `end` as its **guaranteed floor**; an
  unbid fill clears at the floor and every wei of priority fee (scaled by
  `params.priorityScale`) moves the tick toward `start`. The sequencer's own
  ordering picks the winner; losers revert on the `filled` guard. Nothing new is
  trusted — the floor is the same absolute bound every other order has.
- **Delta-verify delivery** (`timing` bit 104) — a DELIVERY mode rather than a
  pricing one: instead of pushing the computed amount from the filler, the settler
  **verifies the recipient's measured balance delta** against the leg's priced
  amount. That makes a **fee-on-transfer output safe** — the maker's signed amount
  becomes a net-of-fee floor rather than a pre-fee nominal — and it is the generic
  outcome-based settlement primitive: the filler sources liquidity any way it likes
  (pool → recipient, aggregator, inventory) inside its callback, and the core only
  checks the result. Because the required amount is still the leg's price, it
  composes with the dutch clock, priority auctions, price modules and partial fills
  unchanged. Callback-only, and refused on the netted path. See the fee-on-transfer
  stance in [the settlement README](packages/core/src/settlement/README.md).
- **External price modules** ([`IPriceModule`](packages/core/src/interfaces/IPriceModule.sol)) —
  the generalization of the clock, and the 1inch `IAmountGetter` class of orders:

  | Module | Prices from | Parity with |
  |---|---|---|
  | [`ChainlinkPeggedPriceModule`](packages/core/src/modules/ChainlinkPeggedPriceModule.sol) | a Chainlink feed, with staleness **and an absolute plausibility band** | oracle-pegged limit orders |
  | [`RangePriceModule`](packages/core/src/modules/RangePriceModule.sol) | the fill-progress axis (`prevFilled/total`) | 1inch `RangeAmountCalculator`, ladders |
  | [`CosignedQuotePriceModule`](packages/core/src/modules/CosignedQuotePriceModule.sol) | an EIP-712 quote signed by a named cosigner, carried in `takerData` | UniswapX's cosigner — without the trusted party |

  **A module returns a BUMP, never an amount**, and the core clamps it to
  `[0, 10000]` before mapping it through each leg's own signed `start`/`end`. So a
  hostile, buggy or stale module can move the price anywhere *inside* the band the
  maker signed and **nowhere outside it** — the difference from an amount getter,
  which *is* the price. A module is resolved once per fill and pinned, so a
  multi-leg order pays one `STATICCALL`, and orders that don't use one pay a single
  calldata compare. Configuration lives in the module's immutables (one instance per
  configuration, shared via CREATE2), so there is no per-order config blob.

  **Measured, fill-only** ([`PricingGasBench.t.sol`](packages/core/test/swaps/PricingGasBench.t.sol),
  same order shape, warm state): a clock-priced fill is 56,140; the block clock is
  **+17**; the priority auction is **−217**; a range module **+2,315**; the
  oracle-pegged module **+5,273**; a cosigned quote **+7,289**; a 2-level bulk
  signature **+1,368** over a single one. Across the whole existing suite the
  features cost a median **+283 gas (+0.09%)**, and the canonical
  `test_plain_swap_full` **+369 (+0.07%)** — see
  [docs/lop-parity.md](docs/lop-parity.md) §5.
- **Off-chain preview.** [`SettlementLens.previewFill`](packages/core/src/periphery/SettlementLens.sol)
  quotes a fill exactly (same math as the contract), `previewBump` returns the
  resolved bump for the `minBumpBps` floor, plus `remaining` / `hashOrder` /
  `validateOrder`. The context-free per-leg views `previewAmountIn` /
  `previewAmountOut` cover clock-priced orders only; a price-module or priority
  order needs the filler/progress/taker context, so those views revert
  `PricingNeedsContext` — use `previewFill`/`previewBump` there.

---

## 5. Fees — two actors, no fee subsystem

There is no fee machinery in the settlement contract. Both fee actors are paid
through ordinary signed legs.

**Originator / sourcing fee (payee known at signing) — an output leg.** Every
output leg names its own recipient, so a fee is one more signed `LegOut`:

- proportional `start`/`end` ⇒ a bps-of-tick fee that decays with the main leg;
- fixed (`end == 0`) ⇒ an absolute fee;
- several legs ⇒ multiple recipients / partner tiers;
- pro-rata across partial fills for free;
- for outputless orders (pure deposits, exits, repays) the equivalent is a
  [`FeeTransferModule`](packages/core/src/modules/FeeTransferModule.sol) MAKE item.

No fee switch, no protocol owner, no cap registry — the fee is a maker-signed
delivery a solver can neither inject nor redirect.

⚠ It is **not** legible in the wallet prompt, though. Since the legs moved to a
packed `bytes` encoding, EIP-712 hashes each blob as one `keccak256`, so a signer
UI shows six opaque hex blobs rather than amounts, recipients and module addresses.
That is the accepted cost of the packed encoding (six keccaks instead of
per-element hashing); the mitigation — an ERC-7730 descriptor plus a lens-side
decoder a frontend can render — is not built.

**Relayer fee (payee anonymous) — a rising input leg.** The filler is normally
paid the conversion spread. Orders with no conversion (a gasless deposit) carry
an input leg that rises `start → end` on the shared tick. The first filler for
whom `tick ≥ gas + margin` fills. Zero filler capital: nothing is fronted, the
filler only collects the fee leg. Flagless — it falls out of uniform leg
pricing. See [docs/originator-fees.md](docs/originator-fees.md) and
[docs/relayer-fees.md](docs/relayer-fees.md).

---

## 6. Netted settlement (`matchSettle`)

A second settlement mode that clears N orders against the Settlement pool rather
than against a solver's balance sheet. Two mirror makers clear with **no AMM and
zero solver inventory**, even when the batch is imbalanced.

The solver supplies a flat **step schedule** — `PULL`, `DELIVER`, `ITEM`,
`PRESEND`, `CALL` — and every per-order check is deferred to a single flush:

```
PHASE 1  OPEN      per order: gates → _openFill → compute outputs, snapshot token universe
PHASE 2  SCHEDULE  the solver's packed steps, verbatim          ← the only solver-ordered region
PHASE 3  FLUSH     per order: completeness → credit ≥ owed → invariants → whole-check + sweep
```

Phases 1 and 3 are contract-owned loops over every order, so a schedule can
reorder the middle but never skip a gate or a check. Consequences:

- **Items interleave with deliveries**, so mutually-dependent orders (A's
  collateral funded by B's borrow *and* vice versa) settle with no flash loan,
  no solver inventory, and no callback.
- **No re-entrancy is involved** — the composition a callback would express
  becomes a schedule, `nonReentrant` stays intact, and the entire deferred
  context lives in memory (no storage, no transient storage).
- Each maker is charged and paid its **own** signed auction curve; only the
  counterparty (the pool) differs.
- `profitRecipient` is a destination only — authority still keys on
  `msg.sender`.
- Invariants assert the end of the **context**, not of an individual order.

The order hash is unchanged: `matchSettle` adds no `Order` field. Design:
[docs/deferred-match-settle.md](docs/deferred-match-settle.md); the netting
invariant and pre-send bound it inherits are in
[docs/batch-settle.md](docs/batch-settle.md); the recommended filler shape
(guard on `filled` first — a lost race costs 3.9k gas instead of 34k) is
[docs/filler-strategy.md](docs/filler-strategy.md).

---

## 7. Conditions — validators and invariants

Read-only staticcalls, AND-composed, with `target` and `data` inside the
typehash. Validators run before any item executes; invariants run after
everything. `OR` and `NOT` are available *within* one order through
`ConditionTreeValidator`, which is itself one entry in the AND-list — see
[docs/condition-trees.md](docs/condition-trees.md).

| Contract | Passes when |
|---|---|
| `ChainlinkPriceGte` / `ChainlinkPriceLte` | fresh feed price ≥ / ≤ threshold (rejects `price <= 0`, `answeredInRound < roundId`, and staleness beyond the signed heartbeat) |
| `ChainlinkTickFloorValidator` | the signed tick is within tolerance of the live oracle rate |
| `TimestampValidator` | `notBefore ≤ block.timestamp ≤ notAfter` |
| `PredicateStaticCall` | an arbitrary staticcall returns non-zero |
| `FillerWhitelistValidator` | the filler is on a curator's list (registry + validator in one) |
| `FillerAttestationValidator` | the filler presents a valid off-chain attestation bound to the order |
| `ConditionTreeValidator` | a maker-signed boolean expression over other validators holds — `OR` and `NOT` inside one order, in disjunctive normal form ([docs](docs/condition-trees.md)) |
| `MinBalanceInvariant` | the account ends the fill holding ≥ a floor (aggregator-style min-return / FoT protection) |
| `Erc721OwnerInvariant` / `Erc1155BalanceInvariant` | the maker ends the fill owning the NFT / ≥ N units |

Validators are **filler-aware** (`validate(order, filler, data)`), which is what
makes whitelist and attestation gating expressible. `staticcall` forbids state
mutation, logs, and re-entrancy, so a broken validator can do nothing worse than
return the wrong boolean. Arbitrary filler-supplied inputs reach validators
through a single signed `takerData` channel.

This covers stop-loss, take-profit, scheduled execution, gas-price gating,
health-factor predicates, rate-differential debt swaps, and any other read-only
on-chain condition.

**Brackets / one-cancels-other.** The one order type whose defining property is a
relationship *between* orders rather than a condition on one. Two expressions,
neither touching the core:

- **Shared nonce** — sign every leg with the same nonce and the fill-once bit;
  the first full fill consumes it and the siblings then fail the nonce gate the
  settlement already runs. Zero contracts, zero extra gas, **whole-fill only**.
- **[`OcoGroupModule`](packages/core/src/modules/OcoGroupModule.sol)** — a
  validator that reads a group claim plus a SETTLE item that writes it (a
  `staticcall` validator can read the fact but never record it, and validators run
  before items, which is exactly the ordering OCO needs). Survives partial fills
  of the winner — the claim records *which* order took the group — scales to
  N-way brackets, and AND-composes with each leg's own trigger. The claim is a
  SETTLE item because SETTLE is the one op that **reverts** on a zero pro-rata
  slice instead of skipping it, so a misconfigured bracket fails loudly rather
  than silently opening up.

See [docs/oco.md](docs/oco.md).

---

## 8. Authority and security model

- **No admin, no module whitelist, no upgradeability.** Authority is the maker's
  EIP-712 signature plus their Permit3 allowances, nothing else.
- **Permit3** ([`packages/core/src/permit3/`](packages/core/src/permit3/README.md))
  extends the Permit2 model with a **second allowance book** for position-pulling
  operations (borrow, withdraw, unstake, claim, vault redeem) that don't fit the
  ERC20 `transferFrom` shape. Both books are **spender-keyed**: a standing
  allowance can only be consumed by Settlement, which then enforces the
  maker-signed recipient. Includes signed allowance grants
  (`permitBatch(WithWitness)`), one-shot signed transfers, `revokeToken` /
  `revokeTaker` / `lockdown`, and a standalone signature-free `AllowanceHolder`.
- **Uniform module gate.** TAKE modules require `msg.sender == permit3`; MAKE and
  SETTLE modules require `msg.sender == settlement`. A rogue module a maker signs
  can only ever touch *that maker's* approved assets.
- **Signature support**: EOA, EIP-2098 compact, **EIP-1271** (Safe / multisig /
  contract makers), **EIP-7702**, plus an on-chain `approveOrder` fallback for
  makers who cannot produce a signature at all — with a batch `approveOrders`
  so a multisig authorizes its whole order ladder in one queued action
  (all-or-nothing on the maker check; per-order events).
- **Bulk (Merkle) signatures** — one signature authorizing N orders: the maker signs
  `OrderRoot(bytes32 root)` and each order carries its own inclusion proof in the
  signature envelope (`innerSig(65) ‖ proof ‖ 0xB0`). A 50-slice ladder, an N-way
  bracket or a market maker's quote refresh becomes **one wallet prompt**. The root
  is authorized by exactly the signer set a single order is (maker, delegate, or the
  maker's own EIP-1271 wallet), and every cancellation primitive still binds — a
  root does not outrank `cancelOrder`, the nonce bitmap or the deadline.
- **Maker-nominated delegated signers.** A maker may authorize another key —
  a session key, a desk's hot wallet, a Safe or passkey account — to sign *its*
  orders, with an expiry, via `setOrderSigner` (or a relayed permit). The registry
  is keyed by `msg.sender` on write and by the **order's own maker** on read, so
  nobody can nominate a signer for someone else and a delegate can author nothing
  its nominator could not have authored itself. There is **no protocol-level
  operator**: unlike designs where an admin-set address may sign for users, every
  delegate in the book was named by the maker whose orders it can sign, and
  delegates cannot appoint further delegates. See
  [docs/delegated-signers.md](docs/delegated-signers.md).
- **Bitmap nonces** — 256 per storage slot, replay-proof, with individual, word,
  and watermark cancellation.
- **Funding fallback.** Ordinary transfer legs try Permit3 first and fall back to
  a plain ERC20 `transferFrom` when the payer approved Settlement directly. Only
  the payer's own tokens move, only to the leg's fixed recipient, so the fallback
  grants no new authority. The taker book is **not** covered by the fallback.
- **Anti-donation accounting.** TAKE proceeds into Settlement are measured by
  balance delta, so a donated balance cannot be claimed as fill proceeds.
- **`nonReentrant` throughout, and no transient storage** — the deferred match
  context is a memory struct, keeping the system portable to EVMs without
  TSTORE/TLOAD.
- **Fee-on-transfer stance is explicit**: simple single-order swaps of FoT tokens
  work (the receiving party nets the post-fee amount); `matchSettle` relies on
  balance-delta pool accounting and **reverts safely** rather than mis-settling.
  A maker wanting a hard floor attaches `MinBalanceInvariant` (absolute, fixed at
  signing) or opts into **delta-verify delivery** (`timing` bit 104), which turns
  the signed output into a true net-of-fee floor measured inside the fill.

Authoritative document, including the trust model, per-layer invariants, the
caveats integrators get wrong, and the audit history with findings and fixes:
[SECURITY.md](SECURITY.md).

---

## 9. Protocol coverage

### Lending adapters ([`packages/modules/lending/`](packages/modules/lending/README.md))

Each package is a set of single-op MAKE/TAKE modules acting on the maker's own
position.

| Lender | Package | Delegation primitive | Status |
|---|---|---|---|
| Aave V2 | [`aave-v2`](packages/modules/lending/aave-v2) | `approveDelegation` · aToken approve | ✅ |
| Aave V3 (+ Spark, Seamless, forks) | [`aave-v3`](packages/modules/lending/aave-v3) | same — pool-agnostic, forks need no new code | ✅ |
| Aave V4 | [`aave-v4`](packages/modules/lending/aave-v4) | hub/spoke position manager | ✅ |
| Compound V2 (+ forks) | [`compound-v2`](packages/modules/lending/compound-v2) | cToken approve | ✅ pool-agnostic |
| Venus | [`venus`](packages/modules/lending/venus) | `updateDelegate` + `enterMarkets` | ✅ |
| Compound V3 (Comet) | [`compound-v3`](packages/modules/lending/compound-v3) | `allow(manager)` | ✅ |
| Euler V2 | [`euler-v2`](packages/modules/lending/euler-v2) | EVC `setAccountOperator` | ✅ |
| Morpho Blue | [`morpho-blue`](packages/modules/lending/morpho-blue) | `setAuthorization` | ✅ |
| Morpho Midnight | [`morpho-midnight`](packages/modules/lending/morpho-midnight) | `setIsAuthorized` | ✅ order-book |
| Fluid | [`fluid`](packages/modules/lending/fluid) | just-in-time position-NFT custody | ✅ |
| Dolomite | [`dolomite`](packages/modules/lending/dolomite) | `setOperators` | ✅ |
| Silo V2 | [`silo`](packages/modules/lending/silo) | `setReceiveApproval` · share allowance | ✅ |
| Exactly | [`exactly`](packages/modules/lending/exactly) | ERC-4626 share allowance | ✅ floating **and** fixed-maturity |
| Lista DAO | [`lista`](packages/modules/lending/lista) | Moolah `setAuthorization` | ✅ fixed-term legs |
| River (Satoshi) | [`river`](packages/modules/lending/river) | diamond `setDelegateApproval` | ✅ CDP |
| Liquity V2 (+ forks) | [`liquity-v2`](packages/modules/lending/liquity-v2) | per-trove add/remove managers | ✅ CDP |
| Gearbox V3 | [`gearbox-v3`](packages/modules/lending/gearbox-v3) | pool ERC-4626 · `setBotPermissions` | 🟡 pool solid, credit best-effort |
| Teller V2 | [`teller`](packages/modules/lending/teller) | permissionless value-in only | 🟡 deposit + repay |

Adding a lender is one package implementing the single-op module interfaces —
no registry, no whitelist, no settlement change, no solver update. A maker just
references the new module address in the order it signs.

### Other module families

| Package | What it does |
|---|---|
| [`modules/erc4626`](packages/modules/erc4626) | Generic ERC-4626 vault withdraw/redeem as a TAKE module. |
| [`modules/transfer`](packages/modules/transfer) | `ERC20PermitTransferModule` — EIP-2612 permit replayed inside the fill. `ProportionalSweepModule` — SETTLE item sweeping a capped bps of the maker's balance of an extra token to the filler, the multi-token half of balance-relative orders. |
| [`modules/redeem/usdrif`](packages/modules/redeem/usdrif) | USDRIF exit path: `RedemptionSettledValidator` (MoC op executed *and* cleared) + optional `MocPriceBandValidator` (bands the MoC RIF↔USDRIF quote; **not** a peg guard — see that package's README). |
| [`modules/bridge`](packages/modules/bridge/README.md) | Cross-chain orders over Across, LayerZero OFT and **Circle CCTP** — see [§11](#11-cross-chain). |

---

## 10. Periphery and tooling

**On-chain periphery**

- [`SettlementLens`](packages/core/src/periphery/SettlementLens.sol) — exact fill
  preview, `getOrderRelevantStates` (one call returning everything an off-chain
  book needs to decide whether an order is still live and funded), signature
  check, `validateOrder` with a human-readable reason.
- [`NativeSettler`](packages/core/src/periphery/NativeSettler.sol) +
  [`NativeForwarderFactory`](packages/core/src/periphery/NativeForwarderFactory.sol)
  — native ETH handled entirely at the edge: the core and Permit3 stay
  ERC20-only, while a maker can still pay native into a WETH-denominated order in
  one transaction.
- **ERC-7683 adapters** —
  [`OriginSettler7683`](packages/core/src/periphery/OriginSettler7683.sol) and
  [`DestinationSettler7683`](packages/core/src/periphery/DestinationSettler7683.sol).
  The intent networks (Across, UniswapX, Eco, CoW) all expose 7683 endpoints and
  most of Across's flow arrives that way, so this exists for **distribution**: an
  existing solver fleet resolves and fills our orders through the interface it
  already speaks. `orderId` is the EIP-712 order hash (no second id space);
  `minReceived`/`maxSpent` come from the same `previewFill` the fill prices with.
  **Escrow-free**, which is the one deviation: `open`/`openFor` verify liveness
  (signature, order deadline, nonce) and broadcast rather than take custody, because
  maker funds move only at fill time under the maker's own Permit3 allowances — the
  property that keeps the protocol admin- and custody-free. `openFor` broadcasts the
  exact signature it verified (an override sponsor-signature replaces the embedded
  one), and a hard-exclusive order can still be opened by its exclusive filler (or
  the maker) during the window. Nothing to refund, and a filler that walks away costs
  the maker nothing. The destination adapter fills through `fillUpTo` (so a published
  payload stays fillable after a partial fill instead of reverting `OverFill`), and
  is a conduit that must end every call holding nothing, approving nothing, and above
  a balance floor taken over the union of every input and output token it touched.
- [`DustHandler`](packages/core/src/dust/DustHandler.sol) — residual disposal for
  MAKE modules: sweep to the user, or best-effort **recycle** back into the
  position, with an automatic fall back to sweep when a re-supply would revert
  (supply caps, frozen/paused reserves, isolation mode).

**Reference solvers** ([`packages/solvers`](packages/solvers/README.md)) — hold
no funds between fills:

- `BaseFlashSolver` — the shared flash → fill → swap → repay machinery.
- Single-input leverage solvers, one per flash provider: **Balancer v2, Aave v3,
  Morpho Blue, Euler EVK**, plus a Morpho Midnight variant.
- Multi-input and multi-output variants for basket orders.
- `MatchRaceGuard` / `GuardedMatchSolver` — cheap-loss guard for contested
  `matchSettle` races.
- `UsdrifInventorySolver` — the principal (inventory-holding) case, for fills
  whose recycle leg cannot complete inside the fill transaction.

**Off-chain stack**

- [`@1delta-x/sdk`](packages/sdk/README.md) — viem-only TypeScript SDK for both
  sides: build/hash/sign orders, witness-bound Permit3 batches, cancellations,
  filler calldata, off-chain dutch pricing. A golden test pins the SDK's order
  hash against the contract's `hashOrder` byte-for-byte.
- [`@1delta-x/orderbook`](packages/orderbook/README.md) — transport-agnostic
  order distribution: protobuf wire format, a two-layer verification pipeline
  (local recover/deadline/shape, then a **chunked** on-chain lens call,
  TTL-cached), an in-memory `Book` with expiry, signed soft-cancel eviction, and
  atomic cancel-and-replace. Eviction is **event-driven**: `ChainWatcher` turns
  Settlement logs into evictions with **zero RPC** — a cancellation event carries
  maker plus which hash/nonces died, and one `GroupClaimed` retires every sibling
  of an OCO bracket — so the periodic sweep is a safety net for what no log can
  announce (a maker's balance falling away) rather than the primary signal. The
  `Transport` seam lets the same book run in-memory, over HTTP, or over Waku
  unchanged.
- [`@1delta-x/orderbook-server`](packages/orderbook-server/README.md) — a Fastify
  REST/WS reference backend.
- [docs/waku-orderbook.md](docs/waku-orderbook.md) — the decentralized transport
  design, including the spam / unbacked-order defense (RLN rate limiting,
  cheap→expensive verification, per-maker negative cache, on-chain revert as the
  capital backstop).

---

## 11. Cross-chain

[`modules/bridge`](packages/modules/bridge/README.md) ships two destination
hosts, both exploiting the fact that `order.maker` is simultaneously the funding
source and the position owner:

| | `BridgedOrderInbox` (shared) | `PositionFunnel` (per user) |
|---|---|---|
| destination orders | swap only — items forbidden | swap **or** leverage |
| authorised by | bridged commitment → on-chain `approveOrder` | owner signature → EIP-1271 |
| bridge payload | 64-byte commitment | none (plain transfer) |
| stray funds | liability accounting + `sync` + owner rescue | owner withdraws |
| refunds | permissionless `settle` after a deadline | withdraw, any time |
| cost | none | ~60k one-off clone per user per chain |

`FunnelGrantModule` supplies **just-in-time allowances** as items, so a funnel
can run a leverage order with no standing approvals of any kind. Grants can only
create a Permit3 allowance (never transfer, never call), are sized to the item's
pro-rata slice, and expire in the current block.

---

## 12. Deployment

[docs/deterministic-deployment.md](docs/deterministic-deployment.md) — Permit3,
the core, and the bridge package land on **identical addresses on every chain**
via a shared CREATE2 factory. The source compiles to only three distinct
bytecodes across all EVM versions, so cross-chain portability reduces to PUSH0 +
MCOPY and the `evm_version` is a global choice: **`cancun`**, which puts 38 of 43
surveyed chains in one address family.

Settlement exceeds the EIP-170 legacy limit by ~4.5KB, so the core deploy profile
compiles via-IR (23,228 bytes); `make size-check` enforces it.

---

## Limits and known gaps

Stated plainly, so nothing here reads as more finished than it is.

- **Fee-on-transfer / rebasing tokens** — supported only for simple single-order
  swaps. `matchSettle` reverts on them by design. Nominal amounts are reported in
  `filled` and `OrderFilled`, so those figures are pre-fee.
- **Gearbox credit accounts** — shipped best-effort and unvalidated (bot
  permission bitmask, account resolution, multicall fund flow). The PoolV3
  ERC-4626 side is solid.
- **Teller** — borrow and withdraw are not wireable (ERC-2771 sender attribution
  makes the module the borrower; withdrawals have a per-owner cooldown).
- **Lista flex borrow** — `broker.borrow(uint256)` is `msg.sender`-only, so only
  the fixed-term broker borrow is delegable.
- **Term Finance** — structurally incompatible (sealed-bid asynchronous
  clearing, no delegation surface, `msg.sender`-scoped repay).
- **Fork test coverage** — several newer packages (silo, exactly, lista, river,
  liquity-v2, gearbox-v3, teller) compile and pass their security gates, but the
  full fork suites await an RPC endpoint in `foundry.toml`. Each package README
  flags its own unvalidated assumption.
- **Oracle *validators* check freshness, not plausibility** (the *price module*
  does — `ChainlinkPeggedPriceModule` carries a maker-signed `[MIN, MAX]` band, so
  this gap now applies only to the trigger validators). `ChainlinkRead`
  rejects stale rounds, incomplete rounds and non-positive prices, but has no
  absolute sanity band — a feed that is fresh and *wrong* (depeg, misconfigured
  decimals, a thin feed that got pushed) passes, and
  `ChainlinkTickFloorValidator` will then use it as the floor. A maker-signed
  `[min, max]` band per feed would close this; it is a validator change, so it
  costs no core bytes.
- **Multi-token sweeps are a module, not a leg.** Balance-relative markers on
  `legsIn[1..n]` are sound and were implemented, but cost +2,106 bytes of
  Settlement (over EIP-170) because the `balanceOf` read inlines at every pricing
  site. Buying that back via `optimizer_runs` would charge ~+4,300 gas to *every*
  fill of *every* order, so it is expressed as a `ProportionalSweepModule` SETTLE
  item instead — zero settler bytes, gas only when used.
- **Revoking a delegated signer does not bind mid-order.** Signatures are
  re-checked only on an order's first fill, so revocation does not stop the
  remainder of an order the delegate already part-filled. Same caveat as EIP-1271
  makers. `cancelOrder`, nonce cancellation, the deadline and Permit3 revocation
  all still bind. See [docs/delegated-signers.md](docs/delegated-signers.md).
- **EIP-170 headroom is ~390 bytes, and it was bought with `optimizer_runs`.** The
  2026-08 pricing/signing features put Settlement over the cap at
  `optimizer_runs = 20000`; the deploy profile now compiles at **400**, which
  restores roughly the margin the contract had before them. That step costs runtime
  gas on the deployed contract, and the size below 400 is flat, so there is nothing
  left in that dial. The measured curve and the three restructurings that returned
  ~3.3KB are in [`foundry.toml`](foundry.toml) and
  [docs/lop-parity.md](docs/lop-parity.md) §4. **Weigh any further *core*
  feature against this** — and note that anything reachable from `Pricing`/`bumpBps`
  is inlined ~8× and pays 8× for every byte. Modules and periphery cost nothing here.
- **The committed gas baseline does not measure the deployed contract.** `make gas`
  runs `[profile.core]` (legacy codegen, `optimizer_runs = 20000`); production
  deploys `[profile.core-deploy]` (via-IR, 400). The two were always slightly
  different; since 2026-08 they differ by the optimizer step as well. A via-IR gas
  baseline needs a test profile that skips the ~900KB `LenderRegistry` data
  contract — worth building, not built.
- **Docs drift** — the top-level [README.md](README.md) is now a front door
  (status, repo map, build commands) rather than an architecture sketch, so it
  has nothing to drift *from*; the architecture lives here. This file,
  [SECURITY.md](SECURITY.md), the
  [settlement README](packages/core/src/settlement/README.md), and
  [docs/](docs/README.md) are current.
- **Breaking signing-format changes** — the 2026-07 audit changed the encoding
  for Gearbox, Liquity, ERC4626 claims, composite items, and every
  `BalanceMode.Full` taker leg; two of those fail *silently* if missed. Read
  SECURITY.md's breaking-change section before touching an encoder.
