# @1delta-x/modules-bridge

## Two destination hosts

`order.maker` is the funnel. Settlement pulls `legsIn` from it ([`Core.sol`](../../core/src/settlement/Core.sol)) *and* runs every item with `onBehalfOf = order.maker` ([`Base.sol`](../../core/src/settlement/Base.sol)) — so whatever a destination order names as maker is both where the funds come from and where any position lands. That one fact decides the whole design, and it gives two hosts:

| | `BridgedOrderInbox` (shared) | `PositionFunnel` (per user) |
|---|---|---|
| destination orders | **swap only** — items forbidden | swap **or leverage** |
| authorised by | a bridged commitment → on-chain `approveOrder` | the owner's signature → EIP-1271 |
| bridge payload | 64-byte commitment | **none** — plain transfer |
| LayerZero | needs `lzCompose`, orphan risk, non-reverting handler | no `lzCompose` at all |
| stray/orphaned funds | `liability` + `sync`; owner `rescue` (announced orphans) or timelocked stray rescue | owner just withdraws |
| refunds | permissionless `settle` after a deadline | withdraw, any time |
| cancellation | **none** — exit only at the order's deadline (or the bridged fallback expiry) | **withdraw the funds** |
| cost | none | ~60k one-off clone deploy per user per chain |

A pooled escrow **cannot** host a position order: `makeOnBehalf(inbox, …)` would open a trove owned by the pool and collateralised by every user's bridged funds, which is why `_checkShape` rejects items outright. One funnel per user removes the conflict, and with it the funding invariant, the liability accounting, the guardian, and the refund machinery — none of which exist to solve a per-user problem.

The source side is identical for both: set `dstRecipient` to the inbox or the funnel, and set `dstOrderHash` to zero for the funnel so no message is attached.

**Inbox orders cannot be cancelled.** The inbox is the maker and never calls `cancelOrder`/`cancelOrders`/`rollbackNonces`; `revokeOrderApproval` runs only inside `settle` once the order's deadline has passed. So an activated destination order stays fillable at its signed price floor until its deadline, and a never-activated row waits for its fallback expiry. That irrevocability is what the shared-nonce safety relies on (no stranger can burn an inbox nonce), and it has a consequence for authors: **keep destination-order deadlines short**, and treat the output legs' `end` amounts as the effective floor for the whole window.

**Wrapped native to a not-yet-deployed funnel arrives as ETH.** Across unwraps a `wrappedNativeToken` output and sends native ETH to a recipient with no code, so a counterfactual funnel receives ETH and its WETH-input order cannot fill until that is wrapped. For a WETH route to a funnel, deploy the funnel on the destination before the deposit is relayed (`PositionFunnelFactory.deploy` is permissionless), or put `WETH.deposit{value: outputAmount}` in the owner's `executeSigned` batch. The ETH is never lost — `withdrawNative` reaches it. A WETH address cannot be pinned in the funnel: it differs per chain and would change every predicted funnel address.

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
3. Settlement reaches `_executeItems` only after verifying the maker — `fill`, `fillWithCallback`, `fillUpTo`, `fillSelf`/`batchFill` call `_verifySignature` before any item, and `matchSettle` verifies every order in its contract-owned OPEN phase before any schedule step runs. For a funnel that check *is* the owner's key. The two Permit3-witness entries are reachable only if the owner opted Permit3 in as a 1271 consumer: `fillWithPermit` verifies its witness before any item, while `fillWithPermitTake` runs the items signed ahead of the TAKE before its `PermitTake` is verified — safe only by atomicity (a bad permit reverts the whole fill, an unconsumed one reverts `PermitTakeNotConsumed`). See the NatSpec on `PositionFunnel.grant`.
4. `_executeItems` passes `order.maker` as `onBehalfOf`, and **the module targets that address, never one taken from item data**. So a grant item in an attacker's order can only ever touch the attacker's own funnel. `test_attack_ownOrderCannotGrantOnAnotherFunnel` proves it.

And the blast radius is bounded even if that chain were broken: `grant` can only create a **Permit3 allowance** — it cannot transfer and cannot call anything else; the amount is the item's pro-rata slice, so a partial fill grants exactly what the paired item pulls; and the expiry is **the current timestamp second** (`block.timestamp`), since the pull happens later in the same transaction — on a chain with several blocks per second that is a few blocks, harmless because only the funnel's own orders can consume it. Nothing dangles.

**Grants and `enableToken` compose.** A grant whose spender is Settlement (covering the `legsIn` pull) is skipped when the funnel already holds `enableToken`'s infinite, never-expiring Permit3 allowance to Settlement: Permit3's `approveToken` is a plain overwrite, so the grant used to replace that allowance with `(slice, now)` and stall every other live order of the funnel on that token.

**Two liveness limits (review 2026-10-06, task 13).** Both fail closed — the fill reverts, nothing moves — but both make a signed order dead:

- **Fixed-input legs only.** The grant is `_prorate(item.amount)`: a constant fraction of a constant. A `legsIn` pull on an AUCTIONED input (a BUY order, or a rising relayer-fee leg) is priced per fill and can exceed that slice, so a grant sized to cover it reverts on allowance as soon as the auction moves. Cover such a leg with `enableToken` (an infinite, unexpiring Settlement allowance, which the grant then skips), not with a grant item.
- **Byte-identical TAKE data across live orders.** A taker grant is keyed `(funnel, spender, module, keccak256(item.data))`, and Permit3's `approveTaker` is a plain overwrite. Two live orders whose TAKE items carry the same `data` share one key, so a fill of one rewrites the other's taker allowance to `(slice, now)` — expired once the block moves — and the sibling stalls until it is granted again. Unlike the token side (above), there is no standing taker allowance the module could recognise and skip. Give every live order its own JIT taker grant (each fill re-grants its own key), or vary the TAKE `data` between orders.

The residual is the ordinary one — an owner who signs an order whose grant item names a hostile spender has authorised it. That is the same trust every item carries: a module's authority lives in maker-signed `data` throughout the protocol (`FluidModules.OperateData` names the vault, `RiverModules.BorrowParams` the trove manager). Against that this module is strictly narrower — it can only ever create a Permit3 allowance, never make a call, and only on the funnel the order's own maker **is**.

That last clause is the load-bearing half. "Maker-signed `data`" on its own is **not** a safety argument, because every address can be the maker of its own order. The 2026-08 audit found precisely that in the old `GenericCallModule`: a *shared* module that held per-user Permit3 allowances **and** made an arbitrary maker-signed call from its own identity, so an attacker's self-signed order could spend a stranger's allowance to it. It has since been reduced to `PermissionlessCallModule`, which holds no authority at all. What protects the grant module is not the signature but the target: it calls `order.maker`, never an address taken from item data, so an attacker's order reaches only the attacker's own funnel. Decoding item data for display is worth doing in the signing UI, but as a general property of items rather than a mitigation specific to this one.

`setGrantsDisabled` is the per-funnel circuit breaker if the module ever has to be abandoned.

Total user involvement on the destination chain: two off-chain signatures at most, zero transactions.

### Funnel deployment

Clone-with-immutable-args: the owner is baked into the proxy's runtime code rather than written to storage, so a funnel is **one CREATE2 and nothing else** — no `initialize` call, no cold SSTORE, and no window in which an uninitialised clone exists to be front-run. ~60k gas, about 21k cheaper than the storage-owner variant.

The proxy is 81 bytes: 61 of runtime (EIP-1167's, plus a `CODECOPY` of the argument, a widened `argsSize`, and the short circuit below) followed by the 20-byte owner. `PositionFunnel.owner()` reads it off the end of calldata. The init code is hand-assembled in `PositionFunnelFactory._writeInitCode`; `test_cloneRuntimeCodeIsExactlyAsSpecified` pins the resulting bytes, because a mis-sized constant there produces a proxy that deploys successfully and then misbehaves.

**Ether arrives by any means.** Appending an immutable argument means every delegatecall carries ≥20 bytes, which would ordinarily make `receive()` unreachable and leave a plain transfer to be read as a selector. The proxy solves it on its own side: the runtime opens with `CALLDATASIZE; ISZERO; PUSH1 0x3b; JUMPI` and terminates at a bare `JUMPDEST; STOP`. A value transfer therefore never reaches the implementation at all — no dispatcher, no selector, and ~19 gas, so `transfer` and `send` work inside the 2300-gas stipend. `test_receivesEtherByEveryMeans` and `test_receivesEtherUnderTheStipend` cover it; `fallback()` in the implementation is left to revert on unmatched selectors.

**The implementation must never be called directly.** Called directly, `owner()` returns whatever the caller placed in the last 20 bytes of calldata, so every state-changing entry point carries `onlyProxy`/`onlyOwner`, which compare `address(this)` against an immutable `_SELF` — and `isValidSignature` returns the failure value on the implementation and for a zero owner. (Without that, Settlement's ABI-encoded 65-byte signature put zero padding where `owner()` reads, `ecrecover` of garbage returned zero too, and the implementation authorised any order whose maker was itself.)


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

**An inbox-committed Across deposit is full-fill only.** The source filler picks
the slices, and the "slices sum to the floor" property holds only for slices that
are actually delivered: a slice whose relay-fee share cannot pay a relayer is never
relayed (it refunds to the maker on the origin chain), and a negative
`dstScalingFactor` floors every slice separately. Either leaves the row below its
anchor for good. `AcrossSpec.totalAmount` (the item's full signed amount) is
therefore mandatory when `dstOrderHash` is set and the slice must equal it; funnel
deposits may opt in. A sponsored LayerZero send (`feePayer != maker`) is full-fill
only for the same per-message reason.

**Enabled tokens must be exact-transfer and non-rebasing.** Credits are the
bridge-reported amount and fills pull from the pooled balance, so a fee-on-transfer
token (including a dormant fee switch such as USDT's `basisPointsRate`) or a
negatively rebasing one makes `credited > held`, and the last row of that token
pays the difference. The inbox cannot measure arrival (LayerZero tokens land in an
earlier transaction; Settlement's pulls are not observed, so `balance − liability`
reads low by every unsynced fill), so this is an admission rule on `enableToken` —
trust assumption 4 in `BridgedOrderInbox`. Positive rebase yield is unattributed
and reachable only through the timelocked stray rescue.

**The escrow row is the whole commitment.** Deliveries are unauthenticated on the
destination — any depositor can author a commitment naming any order hash — and
the order hash commits to neither the refund target nor the token. Keyed by hash
alone, whichever delivery landed first owned the record: a 1-wei front-credit
became the refund recipient of the victim's principal (F28), and once that was
pinned, the same wei still *occupied* the hash and made the victim's real delivery
revert or orphan (F29). Rows are therefore keyed by
`commitKey(orderHash, beneficiary, token)`: a stranger's credit lands in a row of
its own and can neither block, redirect nor settle the victim's; one that copies
the victim's whole commitment is a gift to the victim's row. `activate(order,
beneficiary)` funds the order from the `(hash, beneficiary, legsIn[0].token)` row
and only one row may back a hash at a time (`RowActive`); `settle(hash,
beneficiary, token)` refunds a row and is **not terminal** — a late delivery
re-credits it; `settleExpired(order, beneficiary, token)` refunds ANY row of the
order's hash, whatever its bridged fallback `expiry` (the max over credits) says,
once the ORDER's signed deadline has passed — and at once for a row that can never
fund the order (a token other than `legsIn[0].token`, or an order whose shape the
inbox will never activate, including a never-expiring one). So a copycat cannot
park any row's unlock in 2106; a zero-amount credit cannot move the clock at all.
Consequence for source-side authors: pick one beneficiary per destination order;
every delivery carrying it accumulates in one row.

## Bridge paths

| | Across | Stargate V2 | OFT (USDT0) | CCTP |
|---|---|---|---|---|
| source module | `AcrossBridgeOutModule` | `LzOftBridgeOutModule` | `LzOftBridgeOutModule` | `CctpBridgeOutModule` |
| arrival | atomic (relayer's fill tx) | two txs (`lzReceive`, then `lzCompose`) | two txs | mint after Circle attestation |
| destination hook | `handleV3AcrossMessage` | `lzCompose` | `lzCompose` | **none — plain mint** |
| native messaging fee | none | yes → `nativeCredit` ledger | yes | none |
| delivery floor | `outputAmount`, exact | `minAmountLD` | `minAmountLD` (dust only) | `amount − maxFee` (V2; `amount` itself at `maxFeeBps = 0`, Standard) |
| destination host | inbox or funnel | inbox or funnel | inbox or funnel | **funnel only** |
| **revert posture** | **must revert on bad input** | **must never revert** | **must never revert** | n/a — nothing to handle |

### CCTP (V2): no counterparty, funnel only

**V2, not V1.** Circle phases CCTP V1 out — V1 burn limits fall from 2026-10-31 and
the V1 contracts are halted on 2026-12-01 — and V2 is not backward compatible: the
V2 TokenMessenger exposes only the seven-argument `depositForBurn(amount, domain,
mintRecipient, burnToken, destinationCaller, maxFee, minFinalityThreshold)`.
`CctpBridgeOutModule` targets V2 (`script/Deploy.s.sol` deploys it when
`CCTP_TOKEN_MESSENGER_V2` is set).

CCTP is burn-and-mint rather than a liquidity network: there is no relayer and no
LP, so nothing fronts capital and nothing can under-fill it. V2 does charge a fee,
withheld from the mint and bounded by the burn's `maxFee`; the maker signs that
bound as `CctpSpec.maxFeeBps` of the slice, so the guaranteed delivery floor is
`amount − maxFee` — the amount itself for a Standard transfer
(`minFinalityThreshold = 2000`) signed with `maxFeeBps = 0`. Fast transfers
(`<= 1000`) need a fee bound that covers Circle's fast fee, or the burn never mints.

But `depositForBurn` carries **tokens only**. There is no message field, so this
path cannot carry the `CommitmentCodec` payload that authorises a destination
order on the shared `BridgedOrderInbox` — USDC sent to the inbox over CCTP would
arrive unattributed and no commitment would ever claim it. `CctpSpec` therefore
has no `dstOrderHash` **field at all**, rather than one that must be zero: a
parameter with exactly one legal value is a trap. The destination host must be a
`PositionFunnel`, whose order is owner-signed and validated through its EIP-1271.

Routing the inbox path over CCTP would need V2's `depositForBurnWithHook` plus a
destination handler that runs the hook — a separate module.

#### Who pays for the mint

CCTP has **no destination-side incentive**. The mint only happens when someone
calls `MessageTransmitter.receiveMessage(message, attestation)` on the destination
chain, and that costs gas. Across pays its relayer out of the token amount;
LayerZero charges a native messaging fee at the source. The module burns with
`destinationCaller = 0`, so anyone may submit.

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
module emits `CctpBurn(dstDomain, recipient, token, amount, maxFee,
minFinalityThreshold)`. V2 assigns the message nonce off-chain, so an indexer pairs
the event with Circle's attestation by the **source transaction hash**, and the
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
amount is worth — but it rounds PER SLICE, so N slices can land up to N−1
destination units short of the whole-order floor. That is one of the two reasons an
inbox-committed Across deposit is full-fill only (see "The funding invariant").
CCTP has no equivalent field — see above.

### Revert posture

The table's last row is the one to internalize. For Across, a reverting handler
unwinds the relayer's fill, so they skip the deposit and it refunds on the origin
chain — nothing is stranded. For LayerZero the tokens already landed in a previous
transaction, so a permanent revert in `lzCompose` would orphan them; the inbox
therefore parks malformed, wrong-chain, and unknown-token deliveries as `Orphaned`
events (their amounts recorded in `orphaned[token]`, recoverable via `rescue`), and
only reverts on authorization failures (which delivered nothing) and on a compose
carrying native value (the inbox has no native exit; the compose stays queued and
is re-executable with zero value). Source-side `extraOptions` must therefore not
request an lzCompose value.

Stargate and OFT share one module because `IStargate` is `IOFT`-shaped; the
difference is purely which address the signed spec names. Stargate sends go in taxi
mode (empty `oftCmd`). The module checks `IOFT(oft).token() == inputToken`: a native
OFT burns from its caller with no allowance, so without the binding a spec pulling a
junk token but naming a real native OFT burned the module's resident balance.

**Fee sponsorship** (`feePayer != maker`) is consent per (payer, maker) with an
amount (`approveFeeSponsorship` / `increaseFeeSponsorship` /
`decreaseFeeSponsorship`) and a per-message cap (`maxFeePerSend`), and a sponsored
send must be the whole item (`LzSpec.totalAmount`). It is also **bound to the
FILLER** (audit 2026-09-30 X-DIFF-REST-3): a sponsored spec must be signed as a
`SETTLE` item — the one seam on which the core passes the filler
(`ISettlementModule.settle(maker, filler, amount, data)`) — and the filler must be
the sponsor itself or an agent it named with `setSponsorFiller(agent, true)`
(never a permissionless public solver). On the `MAKE` seam, which carries no filler
identity, a sponsored spec reverts `SponsoredSendNeedsSettle`; a self-paid spec
(`feePayer == maker`) works on either seam. **BREAKING:** sponsored orders signed
as `MAKE` items no longer fill. The SDK's `assertLzSponsorshipSafe` (hard lifelong
`exclusiveFiller` = sponsor, full-fill only) is now a liveness preflight — a
stranger's fill reverts instead of charging the sponsor. `SETTLE` items are not
admitted by `matchSettle`, so sponsored sends fill through the single-order and
batch entrypoints only.

### Recovery order for a LayerZero delivery that hasn't credited

1. **Check whether the compose simply hasn't run.** The endpoint stores the message
   in `composeQueue` whether or not the send budgeted an `lzComposeOption`, and
   `endpoint.lzCompose` is **permissionless** — anyone can execute it and pay the
   gas. An underfunded or missing compose option delays a delivery; it does not lose
   it. This is the fix for the overwhelming majority of cases. Note a delivery
   through a compose source that is still in its `COMPOSE_SOURCE_DELAY` (or was
   removed) reverts in `lzCompose` and stays queued until the source is live —
   it is not rescuable in the meantime, by design.
2. Only if an `Orphaned` event with an amount was emitted is the payload one the
   inbox will never accept. `rescue(token, to, amount)` releases at most
   `orphaned[token]` (the announced amounts), capped by `balance − liability`;
   `sync` any filled-but-unsettled commits first so that cap is not understated.
3. Anything no event announced — a donation, an Across deposit sent with no
   message, a `header` orphan, rebase yield — goes through
   `queueStrayRescue` → (`COMPOSE_SOURCE_DELAY`) → `executeStrayRescue`, re-bounded
   at execution by `balance − liability − orphaned`. The delay is public, so a
   delivery whose compose is merely pending gets the chance to land (and become
   liability) first.

Why the split (audit 2026-09-30 BRIDGE-A-1): a plain `balance − liability` sweep
also took deliveries whose compose had not run yet; when that compose later
landed it credited a row nothing backed, paid out of other users' escrow — and a
compromised owner key could do it with no delay at all.

## LayerZero conformance

Checked against LayerZero's composer guidance and the community audit checklist:

| Item | Status |
|---|---|
| `msg.sender == endpoint` | ✅ |
| `_from` is a trusted OApp | ✅ `composeSourceToken` registry; the delivered token is taken from the registry, never from the payload |
| Compose replay protection | ✅ by the endpoint: EndpointV2 marks `composeQueue[from][to][guid][index]` RECEIVED before calling the composer and `sendCompose` refuses an occupied slot. The inbox keeps no dedupe of its own — a `keccak256(guid, message)` map could only ever catch a SECOND INDEX with an identical payload (a real delivery) and silently dropped it |
| Non-blocking handler | ✅ business-logic failures park as `Orphaned`; only authorization (and a native-value compose) reverts |
| Escape hatch for stuck funds | ✅ `rescue` for announced orphans (`orphaned[token]`, capped by `balance − liability`); timelocked `queueStrayRescue`/`executeStrayRescue` for anything unannounced. Neither can reach a delivery whose compose is still pending |
| Minimum enforced in payload, not options | ✅ the floor is `legsIn[0].start` of the maker-signed order the commitment names, checked in `activate`. Executor options are an off-chain agreement and are never load-bearing |
| Decoding via the compose codec | ✅ plus a length check before slicing — an out-of-range slice would revert, which is the one thing this handler must not do |
| Ordered-execution blocking risk | ✅ n/a — `nextNonce` is not implemented, so delivery is unordered; the non-reverting handler is safe under either mode |
| `amountLD` trust | ⚠️ **inherent**. See "Trust assumptions" in `BridgedOrderInbox`. On the LayerZero path tokens land in an earlier transaction, so no balance delta is observable and the reported amount must be taken on faith. Mitigation is operational: register only canonical addresses |
| Shared-decimal dust | ⚠️ handled by the source module's signed `maxSlippageBps`, which must cover it. Zero is correct for USDT0 (6 local == 6 shared); an 18-decimal OFT needs headroom or `send` reverts on the source (fail-safe) |

## Constrained destination-order shape

`activate` rejects anything but: the inbox as maker, `SELL`, not fill-once, exactly
one FIXED input leg, at least one output leg, no output addressed to `address(0)`
or the inbox, no items, no fill module, no `fillTotal`, a live and FINITE deadline
(`type(uint48).max` is refused), and leg blobs whose element count is backed by
bytes (the `PackedArrays` validator rule — a truncated blob would otherwise decode
from unhashed padding). Each guard has a reason documented at
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
- **On the funnel**: EIP-1271 is closed by default to Settlement and the lens (`setSigConsumer` opens more). Permit3 was removed from the built-in set in the 2026-09-25 re-audit (F30): the funnel checks the owner's key on the raw digest, and no Permit3 message names the funnel, so any permit the owner signs for its own wallet would also verify for the funnel. A general-purpose 1271 would make any third-party domain lacking `chainId` replayable at the same funnel address on every chain.
- **Not on-chain**: whether `dstEid` and `dstChainId` name the same chain, and whether the destination has the factory deployed. Neither is knowable from the source chain, and both would need an owner on contracts that are otherwise ownerless and immutable. They belong to the off-chain preflight, where the stored `chainId` is self-authenticating — it is an input to the domain, so a wrong label simply fails to verify.

## Deployment

`script/Deploy.s.sol` deploys everything through CREATE2 with a fixed salt. This is a fund-safety property, not a convenience: funnel addresses are derived from the factory address and its init code, so a factory that lands somewhere else on one chain invalidates every funnel address predicted for it — including ones tokens have already been bridged to.

The factory's constructor args (`permit3`, `settlement`, `lens`, `grantModule`) are inside its init code, so **those four must already be at identical addresses on every chain** or the factory diverges silently. `FunnelGrantModule` is deployed by the same script through CREATE2 with `settlement` as its only constructor arg, so it lands identically wherever Settlement does — but it is an input to every funnel address all the same. The optional `CctpBridgeOutModule` (CCTP V2) is deployed when `CCTP_TOKEN_MESSENGER_V2` is set. `saltFor` and `initCodeHashFor` are exposed so an off-chain implementation can reproduce the derivation and be checked against a published registry rather than trusted; `test_addressDerivationIsReproducible` pins the formula.

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
