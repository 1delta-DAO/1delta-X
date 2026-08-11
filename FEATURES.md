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
| `legsIn[]` / `legsOut[]` | Multi-asset baskets on both sides. Each leg is `(token, start, end)`; output legs additionally carry their own `recipient`. |
| `side` (SELL/BUY) | SELL = fixed inputs, decaying outputs, anchored on `legsIn[0].start`. BUY = fixed outputs, rising inputs, anchored on `legsOut[0].start`. |
| `items[]` | Ordered list of maker-signed module calls: `MAKE`, `TAKE`, `SETTLE`. |
| `timing` | Three `uint32` clocks packed into one word (decay start, decay duration, exclusivity end) plus the item-ordering policy in bits `[96:100)`. |
| `curve` | Optional piecewise-linear decay shape (`CurvePoint[]`); empty = single linear segment. |
| `gasBumpBps` / `gasPriceRef` | Gas-indexed extra decay: the auction tick moves further toward the maker's floor as basefee rises. |
| `exclusiveFiller` / `exclusivityOverrideBps` | Hard exclusivity (only that filler until the deadline) or soft (anyone may jump the queue by improving the maker's leg by N bps). |
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
| `fillUpTo(...)` | Aggregator/router integration entry. Clamps to remaining size (race-tolerant) and returns full both-sides accounting `(delta, received, paid)`; `recipient` redirects payment only, never authority. |
| `matchSettle(MatchPlan)` | Netted N-order settlement — see [§6](#6-netted-settlement-matchsettle). |

**Cancellation** ([`NonceManager.sol`](packages/core/src/settlement/NonceManager.sol)):
`cancelOrders(nonces[])` for individual orders, `invalidateNonceWord(word)` to
kill 256 at once, `rollbackNonces(minValid)` to invalidate everything below a
watermark.

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
  [`Erc1155SettlementModule`](packages/core/src/modules/Erc1155SettlementModule.sol).
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
- **Off-chain preview.** [`SettlementLens.previewFill`](packages/core/src/periphery/SettlementLens.sol)
  quotes a fill exactly (same math as the contract), plus `previewAmountIn` /
  `previewAmountOut` / `remaining` / `hashOrder` / `validateOrder`.

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
delivery a solver can neither inject nor redirect, and the wallet shows it as a
plain amount + recipient in the EIP-712 prompt.

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
everything.

| Contract | Passes when |
|---|---|
| `ChainlinkPriceGte` / `ChainlinkPriceLte` | fresh feed price ≥ / ≤ threshold (rejects `price <= 0`, `answeredInRound < roundId`, and staleness beyond the signed heartbeat) |
| `ChainlinkTickFloorValidator` | the signed tick is within tolerance of the live oracle rate |
| `TimestampValidator` | `notBefore ≤ block.timestamp ≤ notAfter` |
| `PredicateStaticCall` | an arbitrary staticcall returns non-zero |
| `FillerWhitelistValidator` | the filler is on a curator's list (registry + validator in one) |
| `FillerAttestationValidator` | the filler presents a valid off-chain attestation bound to the order |
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
  makers who cannot produce a signature at all.
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
  A maker wanting a hard floor attaches `MinBalanceInvariant`.

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
| [`modules/transfer`](packages/modules/transfer) | `ERC20PermitTransferModule` — EIP-2612 permit replayed inside the fill. |
| [`modules/redeem/usdrif`](packages/modules/redeem/usdrif) | USDRIF exit path: depeg guard + redemption-settled validators. |
| [`modules/bridge`](packages/modules/bridge/README.md) | Cross-chain orders — see [§11](#11-cross-chain). |

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
  (local recover/deadline/shape, then one on-chain lens call, TTL-cached), an
  in-memory `Book` with expiry and signed soft-cancel eviction. The `Transport`
  seam lets the same book run in-memory, over HTTP, or over Waku unchanged.
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
- **Docs drift** — the top-level [README.md](README.md) architecture sketch
  predates the Permit3 rewrite. This file, [SECURITY.md](SECURITY.md), the
  [settlement README](packages/core/src/settlement/README.md), and
  [docs/](docs/README.md) are current.
- **Breaking signing-format changes** — the 2026-07 audit changed the encoding
  for Gearbox, Liquity, ERC4626 claims, composite items, and every
  `BalanceMode.Full` taker leg; two of those fail *silently* if missed. Read
  SECURITY.md's breaking-change section before touching an encoder.
