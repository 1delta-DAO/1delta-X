# @1delta-x/modules-bridge

## Two destination hosts

`order.maker` is the funnel. Settlement pulls `legsIn` from it ([`Core.sol`](../../core/src/settlement/Core.sol)) *and* runs every item with `onBehalfOf = order.maker` ([`Base.sol`](../../core/src/settlement/Base.sol)) — so whatever a destination order names as maker is both where the funds come from and where any position lands. That one fact decides the whole design, and it gives two hosts:

| | `BridgedOrderInbox` (shared) | `PositionFunnel` (per user) |
|---|---|---|
| destination orders | **swap only** — items forbidden | swap **or leverage** |
| authorised by | a bridged commitment → on-chain `approveOrder` | the owner's signature → EIP-1271 |
| bridge payload | 64-byte commitment | **none** — plain transfer |
| LayerZero | needs `lzCompose`, orphan risk, non-reverting handler | no `lzCompose` at all |
| stray/orphaned funds | `liability` + `sync` + owner `rescue` | owner just withdraws |
| refunds | permissionless `settle` after a deadline | withdraw, any time |
| cancellation | nonce / hash | **withdraw the funds** |
| cost | none | ~60k one-off clone deploy per user per chain |

A pooled escrow **cannot** host a position order: `makeOnBehalf(inbox, …)` would open a trove owned by the pool and collateralised by every user's bridged funds, which is why `_checkShape` rejects items outright. One funnel per user removes the conflict, and with it the funding invariant, the liability accounting, the guardian, and the refund machinery — none of which exist to solve a per-user problem.

The source side is identical for both: set `dstRecipient` to the inbox or the funnel, and set `dstOrderHash` to zero for the funnel so no message is attached.

### What a leverage destination order needs

Three grants, each a different authority, none of which a freshly-bridged user has — all relayed by the solver from **one** owner signature via `executeSigned`:

1. a Permit3 **token** allowance to the MAKE module (`enableToken` only covers Settlement, which pulls `legsIn`; a maker module pulls its own funding),
2. a Permit3 **taker** allowance for the TAKE leg, keyed `(funnel, Settlement, keccak256(item.data))`,
3. the lender's own **borrow delegation** — supply is permissionless on behalf of anyone, borrowing is not.

Two of those three can move **into the order itself** as a grant item, so the only thing left needing a separate signature is the lender's own delegation — which is one-time per position, not per order.

### Just-in-time allowances (`FunnelGrantModule`)

```
items[0]  MAKE  FunnelGrantModule   grant(supplyModule, collateral, amount)
items[1]  MAKE  FunnelGrantModule   grant(Settlement, taker ref, amount)
items[2]  MAKE  <lender supply>     pulls against [0]
items[3]  TAKE  <lender borrow>     spends [1]
```

Items run after outputs are delivered and **before** inputs are paid, so a grant can also cover the `legsIn` pull — which makes `enableToken` redundant rather than merely cheap. A funnel can run a leverage order with **no standing approvals of any kind**.

**Why this cannot be used to drain a funnel.** Four links, each verified in code:

1. `PositionFunnel.grant` requires `msg.sender == GRANT_MODULE`, an immutable.
2. `FunnelGrantModule` requires `msg.sender == SETTLEMENT`.
3. Settlement reaches `_executeItems` only after verifying the maker — `fill`, `fillUpTo`, `fillSelf`/`batchFill`, `batchSettle` and `batchSettleItems` all call `_verifySignature`, and `fillWithPermit` binds the order hash as a Permit3 witness. For a funnel that check *is* the owner's key.
4. `_executeItems` passes `order.maker` as `onBehalfOf`, and **the module targets that address, never one taken from item data**. So a grant item in an attacker's order can only ever touch the attacker's own funnel. `test_attack_ownOrderCannotGrantOnAnotherFunnel` proves it.

And the blast radius is bounded even if that chain were broken: `grant` can only create a **Permit3 allowance** — it cannot transfer and cannot call anything else; the amount is the item's pro-rata slice, so a partial fill grants exactly what the paired item pulls; and the expiry is **the current block**, since the pull happens later in the same transaction. Nothing dangles.

The residual is the ordinary one — an owner who signs an order whose grant item names a hostile spender has authorised it. That is the same trust every item carries: a module's authority lives in maker-signed `data` throughout the protocol (`FluidModules.OperateData` names the vault, `RiverModules.BorrowParams` the trove manager). Against that this module is strictly narrower — it can only ever create a Permit3 allowance, never make a call, and only on the funnel the order's own maker **is**.

That last clause is the load-bearing half. "Maker-signed `data`" on its own is **not** a safety argument, because every address can be the maker of its own order. The 2026-08 audit found precisely that in the old `GenericCallModule`: a *shared* module that held per-user Permit3 allowances **and** made an arbitrary maker-signed call from its own identity, so an attacker's self-signed order could spend a stranger's allowance to it. It has since been reduced to `PermissionlessCallModule`, which holds no authority at all. What protects the grant module is not the signature but the target: it calls `order.maker`, never an address taken from item data, so an attacker's order reaches only the attacker's own funnel. Decoding item data for display is worth doing in the signing UI, but as a general property of items rather than a mitigation specific to this one.

`setGrantsDisabled` is the per-funnel circuit breaker if the module ever has to be abandoned.

Total user involvement on the destination chain: two off-chain signatures at most, zero transactions.

### Funnel deployment

Clone-with-immutable-args: the owner is baked into the proxy's runtime code rather than written to storage, so a funnel is **one CREATE2 and nothing else** — no `initialize` call, no cold SSTORE, and no window in which an uninitialised clone exists to be front-run. ~60k gas, about 21k cheaper than the storage-owner variant.

The proxy is 81 bytes: 61 of runtime (EIP-1167's, plus a `CODECOPY` of the argument, a widened `argsSize`, and the short circuit below) followed by the 20-byte owner. `PositionFunnel.owner()` reads it off the end of calldata. The init code is hand-assembled in `PositionFunnelFactory._writeInitCode`; `test_cloneRuntimeCodeIsExactlyAsSpecified` pins the resulting bytes, because a mis-sized constant there produces a proxy that deploys successfully and then misbehaves.

**Ether arrives by any means.** Appending an immutable argument means every delegatecall carries ≥20 bytes, which would ordinarily make `receive()` unreachable and leave a plain transfer to be read as a selector. The proxy solves it on its own side: the runtime opens with `CALLDATASIZE; ISZERO; PUSH1 0x3b; JUMPI` and terminates at a bare `JUMPDEST; STOP`. A value transfer therefore never reaches the implementation at all — no dispatcher, no selector, and ~19 gas, so `transfer` and `send` work inside the 2300-gas stipend. `test_receivesEtherByEveryMeans` and `test_receivesEtherUnderTheStipend` cover it; `fallback()` in the implementation is left to revert on unmatched selectors.

**The implementation must never be called directly.** Called directly, `owner()` returns whatever the caller placed in the last 20 bytes of calldata, so every state-changing entry point carries `onlyProxy`/`onlyOwner`, which compare `address(this)` against an immutable `_SELF`.


Sequential cross-chain orders — the "v1" model: two ordinary orders on two chains,
linked by a bridge message. No hashlock, no escrow secret, no destination solver
inventory. Nothing in the settlement core changes.

```
chain X                                    chain Y
───────                                    ───────
order 1 settles normally
  legsOut → maker (bridgeable token)
  item    → BridgeOut module
              ├─ pulls it back via Permit3
              └─ bridges to the inbox, carrying
                 a 64-byte commitment = hash(order 2)
                                       ─────────────▶
                                           BridgedOrderInbox credits it
                                           anyone calls activate(order 2)
                                             └─ settlement.approveOrder  (existing
                                                signature-less path)
                                           a solver fills order 2 normally
                                             └─ legsOut.recipient = the end user
```

The end user needs **no allowance, no balance, and no prior interaction** with the
destination chain. That is the whole point, and it is why the inbox — not the
user — is the maker of the destination order.

## Why the inbox is the maker

`OrderState.approveOrder` is `msg.sender`-keyed: nobody can authorize an order on
another maker's behalf. So a destination order whose maker were the end user could
not be authorized by a bridge message at all — and the user would additionally need
Permit3 allowances on a chain they may never have touched. Making the inbox the
maker removes both problems at once. The user appears only as `legsOut[j].recipient`.

## The funding invariant

The inbox is a **pooled** escrow with a standing Permit3 allowance to Settlement
over its whole balance. Settlement pulls a fill's inputs without consulting
anything in this package, so per-order bookkeeping here cannot constrain a pull.
Isolation comes from one rule in `activate`:

> an order is approved only once `credited >= order.legsIn[0].start`

Settlement caps cumulative fills at the anchor, which for the constrained order
shape *is* `legsIn[0].start`. So `filled <= anchor <= credited` for every approved
order, and summing over all of them, total pulled never exceeds total received. One
user's order can never reach another's funds — by construction, not by accounting.
`InboxAccounting.t.sol::test_cannotDrainAnotherCommitsFunds` is the proof.

The practical consequence: **author the destination order against the bridge's
guaranteed delivery floor, never its expected amount.** All three paths give one —
Across enforces `outputAmount` exactly, Stargate enforces `minAmountLD`, an OFT
delivers the sent amount less deterministic shared-decimal dust. Surplus above the
floor stays credited and refunds to the beneficiary via `settle`. Authoring above
the floor is fail-safe: the order simply never activates and the funds come back.

## Bridge paths

| | Across | Stargate V2 | OFT (USDT0) | CCTP |
|---|---|---|---|---|
| source module | `AcrossBridgeOutModule` | `LzOftBridgeOutModule` | `LzOftBridgeOutModule` | `CctpBridgeOutModule` |
| arrival | atomic (relayer's fill tx) | two txs (`lzReceive`, then `lzCompose`) | two txs | mint after Circle attestation |
| destination hook | `handleV3AcrossMessage` | `lzCompose` | `lzCompose` | **none — plain mint** |
| native messaging fee | none | yes → `nativeCredit` ledger | yes | none |
| delivery floor | `outputAmount`, exact | `minAmountLD` | `minAmountLD` (dust only) | **the amount itself — burn == mint** |
| destination host | inbox or funnel | inbox or funnel | inbox or funnel | **funnel only** |
| **revert posture** | **must revert on bad input** | **must never revert** | **must never revert** | n/a — nothing to handle |

### CCTP: no fee, no counterparty, funnel only

CCTP is burn-and-mint rather than a liquidity network, which makes it the odd one
out in both directions. There is no relayer and no LP on v1, so the mint equals
the burn exactly — the tightest delivery floor available here, and the only one a
destination order can be authored against with no slack at all. Nothing can
under-fill it, because nothing is fronting capital.

But `depositForBurn` carries **tokens only**. There is no message field, so this
path cannot carry the `CommitmentCodec` payload that authorises a destination
order on the shared `BridgedOrderInbox` — USDC sent to the inbox over CCTP would
arrive unattributed and no commitment would ever claim it. `CctpSpec` therefore
has no `dstOrderHash` **field at all**, rather than one that must be zero: a
parameter with exactly one legal value is a trap. The destination host must be a
`PositionFunnel`, whose order is owner-signed and validated through its EIP-1271.

Routing the inbox path over CCTP needs v2's `depositForBurnWithHook`, which is a
different messenger ABI and a separate module.

#### Who pays for the mint

CCTP v1 has **no destination-side incentive**. The mint only happens when someone
calls `MessageTransmitter.receiveMessage(message, attestation)` on the destination
chain, and that costs gas. Across pays its relayer out of the token amount;
LayerZero charges a native messaging fee at the source. CCTP charges nothing and
therefore pays nobody — which is exactly why it has no fee.

**The solver does both calls in one transaction of its own:**

```
solver tx:
  1. MessageTransmitter.receiveMessage(message, attestation)   → USDC minted to the funnel
  2. settlement.fill(destinationOrder, sig, amount)            → funnel funds the order
```

and the destination order's **rising input leg** pays the solver for the combined
gas — the same flagless relayer-fee mechanism a gasless deposit uses, gas-indexed
through `gasBumpBps` / `gasPriceRef` so it escalates on its own until someone finds
it profitable. Nothing new is required: `fill` is permissionless, and a solver's
transaction may do anything it likes before it.

⚠ It cannot be an ITEM on the destination order. Items receive only maker-signed
`data` — no filler-supplied channel reaches them — and the Circle attestation does
not exist when the user signs. So this is necessarily solver-side batching, not
order-side composition.

**If nobody submits**, the funds are un-minted rather than lost: the burn already
happened and the attestation stays redeemable, so the user or anyone else can
submit later and the rising fee leg keeps climbing until the economics work. Stuck,
not gone. (Verify attestation longevity against Circle's docs before mainnet, on
the same footing as the ABI-risk note in `ICctp.sol`.)

**Correlation is off-chain, and `CctpBurn` is what makes it possible.** Because no
payload crosses, nothing on either chain says which order a burn funds. The source
module emits `CctpBurn(nonce, dstDomain, recipient, token, amount)` — Circle's
message nonce is the key an indexer pairs with the published attestation, and the
recipient funnel is what an orderbook matches outstanding destination orders
against. The other two paths need no such event; their commitment does this
on-chain and the inbox emits `Credited`.

⚠ CCTP routes on Circle's own **domain id**, which is unrelated to the EVM chain
id (Ethereum is domain 0). `CctpSpec` carries both: the domain is what routes, the
chain id is what `_checkDestination` sanity-checks. Dropping the chain id would
lose that check entirely, since domain 0 is indistinguishable from unset.

### Cross-chain decimals

`AcrossSpec.dstScalingFactor` (`int8`, `destinationDecimals - sourceDecimals`)
converts the delivery floor into the destination token's denomination. `0` — every
route shipped so far — is the identity and costs one comparison.

It matters because the failure is silent. Across enforces `outputAmount` in
destination decimals while the item receives `amount` in source decimals, so a
pair whose decimals differ across chains (USDT 6/18, WBTC 8/18) sets a floor wrong
by a power of ten without reverting. `BridgeOutBase._scaleToDest` rounds DOWN,
which keeps the floor reachable rather than demanding more value than the source
amount is worth. CCTP has no equivalent field — see above.

That last row is the one to internalize. For Across, a reverting handler unwinds the
relayer's fill, so they skip the deposit and it refunds on the origin chain — nothing
is stranded. For LayerZero the tokens already landed in a previous transaction, so a
permanent revert in `lzCompose` would orphan them; the inbox therefore parks
malformed, wrong-chain, and unknown-token deliveries as `Orphaned` events recoverable
via `rescue`, and only reverts on authorization failures (which delivered nothing).

Stargate and OFT share one module because `IStargate` is `IOFT`-shaped; the
difference is purely which address the signed spec names. Stargate sends go in taxi
mode (empty `oftCmd`).

### Recovery order for a LayerZero delivery that hasn't credited

1. **Check whether the compose simply hasn't run.** The endpoint stores the message
   in `composeQueue` whether or not the send budgeted an `lzComposeOption`, and
   `endpoint.lzCompose` is **permissionless** — anyone can execute it and pay the
   gas. An underfunded or missing compose option delays a delivery; it does not lose
   it. This is the fix for the overwhelming majority of cases.
2. Only if an `Orphaned` event was emitted is the payload one the inbox will never
   accept. Then `sync` any filled-but-unsettled commits (so `rescuable` is not
   understated) and use `rescue`.

## LayerZero conformance

Checked against LayerZero's composer guidance and the community audit checklist:

| Item | Status |
|---|---|
| `msg.sender == endpoint` | ✅ |
| `_from` is a trusted OApp | ✅ `composeSourceToken` registry; the delivered token is taken from the registry, never from the payload |
| Compose replay protection | ✅ keyed on `keccak256(guid, message)` — **not** GUID alone, since `composeQueue` is keyed by (…, guid, **index**) and one send can carry several messages |
| Non-blocking handler | ✅ business-logic failures park as `Orphaned`; only authorization reverts |
| Escape hatch for stuck funds | ✅ `rescue`, bounded by `balance − liability`; `sync` keeps that bound from being understated |
| Minimum enforced in payload, not options | ✅ the floor is `legsIn[0].start` of the maker-signed order the commitment names, checked in `activate`. Executor options are an off-chain agreement and are never load-bearing |
| Decoding via the compose codec | ✅ plus a length check before slicing — an out-of-range slice would revert, which is the one thing this handler must not do |
| Ordered-execution blocking risk | ✅ n/a — `nextNonce` is not implemented, so delivery is unordered; the non-reverting handler is safe under either mode |
| `amountLD` trust | ⚠️ **inherent**. See "Trust assumptions" in `BridgedOrderInbox`. On the LayerZero path tokens land in an earlier transaction, so no balance delta is observable and the reported amount must be taken on faith. Mitigation is operational: register only canonical addresses |
| Shared-decimal dust | ⚠️ handled by the source module's signed `maxSlippageBps`, which must cover it. Zero is correct for USDT0 (6 local == 6 shared); an 18-decimal OFT needs headroom or `send` reverts on the source (fail-safe) |

## Constrained destination-order shape

`activate` rejects anything but: `SELL`, exactly one input leg, at least one output
leg, no output addressed to `address(0)` or the inbox, no items, no fill module, no
`fillTotal`, live deadline. Each guard has a reason documented at
`BridgedOrderInbox._checkShape` — mostly that `filled` must stay denominated in the
credited token, which both the funding invariant and `settle`'s accounting rely on.

## Chain binding

The EIP-712 *digest* is chain-bound via the domain separator, but the raw
`orderHash` is not — and the signature-less approval path never computes a digest.
With a CREATE2 inbox at the same address on several chains a replayed message would
otherwise credit the same order twice, so the commitment carries `dstChainId` and
both hooks check it against `block.chainid`.

## Core change

One, in `SettlementLens`: `_verifySignature` now mirrors `Signatures`' empty-`sig`
branch by reading the settler's `orderApproved` record. Without it every sigless
order reports `isSignatureValid == false` and the orderbook has to take the
announcer's own `sigless` claim on faith (which it no longer does — see
`packages/orderbook/src/verify.ts`). **Deployment order matters:** a lens predating
this change reports every sigless order invalid.

## Chain binding

Every signature in the system is already chain-bound — Settlement, Permit3, the funnel's `executeSigned` and the filler-attestation validator all put `chainId` in their EIP-712 domain and recompute it on fork. So with identical addresses everywhere, two orders for two chains are byte-identical structs that differ only in the domain separator, and that difference is enough: `ChainBinding.t.sol` asserts a source signature is refused on the destination and vice versa.

Two guards sit on top of that, and one deliberate omission:

- **In the out-modules** (ownerless, no config): `dstRecipient != 0`, `dstChainId != 0 && != block.chainid`, `dstEid != 0`. Only the encodings that are wrong under every configuration. Zero recipient is the one that prevents an outright loss rather than an inconvenience.
- **On the funnel**: EIP-1271 is closed by default to Settlement, Permit3 and the lens (`setSigConsumer` opens more). A general-purpose 1271 would make any third-party domain lacking `chainId` replayable at the same funnel address on every chain.
- **Not on-chain**: whether `dstEid` and `dstChainId` name the same chain, and whether the destination has the factory deployed. Neither is knowable from the source chain, and both would need an owner on contracts that are otherwise ownerless and immutable. They belong to the off-chain preflight, where the stored `chainId` is self-authenticating — it is an input to the domain, so a wrong label simply fails to verify.

## Deployment

`script/Deploy.s.sol` deploys everything through CREATE2 with a fixed salt. This is a fund-safety property, not a convenience: funnel addresses are derived from the factory address and its init code, so a factory that lands somewhere else on one chain invalidates every funnel address predicted for it — including ones tokens have already been bridged to.

The factory's constructor args (`permit3`, `settlement`, `lens`) are inside its init code, so **those three must already be at identical addresses on every chain** or the factory diverges silently. `saltFor` and `initCodeHashFor` are exposed so an off-chain implementation can reproduce the derivation and be checked against a published registry rather than trusted; `test_addressDerivationIsReproducible` pins the formula.

## Not done yet

- **SDK order-pair builder.** Deliberately held for review. Note there is no
  circular dependency: order 2 does not reference order 1, so build order 2 → hash
  it → embed in order 1's item.
- **Orderbook pending bucket.** `verifyAnnounce` drops anything not immediately
  fillable, so a destination order announced while the bridge is in flight is
  rejected rather than held. Until that lands, announce after `activate`. (The
  arrival race itself needs no handling — the lens already reports
  `fillableAmount == 0` until funds land.)
- **Bridge ABIs are unpinned.** See the `ABI RISK` notes in `src/vendor/`. Across
  has both `address`- and `bytes32`-typed deposit entrypoints live depending on
  SpokePool version; Stargate additionally exposes `sendToken`; and USDT0's OFT
  deployments need checking for compose support on the specific chain pairs.
  Verify against the target deployments before mainnet.
