# Security

This document describes the security model of the 1delta-x intent-settlement
system, the invariants each component upholds, and the findings + fixes from the
internal security audits of 2026-06-18 and 2026-07-29.

- [Architecture & trust model](#architecture--trust-model)
- [Security invariants](#security-invariants)
- [Caveats integrators must know](#caveats-integrators-must-know)
- [Audit (2026-06-18): findings & fixes](#audit-2026-06-18-findings--fixes)
- [Audit (2026-07-29): findings & fixes](#audit-2026-07-29-findings--fixes)
- [Breaking change for integrators](#breaking-change-for-integrators)
- [Reporting a vulnerability](#reporting-a-vulnerability)

> **Integrators:** the 2026-07-29 audit changed the off-chain signing format for
> several modules — read
> [Breaking change for integrators](#breaking-change-for-integrators) before
> writing or updating an encoder. Two of the changes fail *silently*.

---

## Architecture & trust model

The system has three on-chain layers and no admin role / no module whitelist —
authority comes entirely from a maker's EIP-712 signature plus their Permit3
allowances.

```
   maker (EIP-712 order + permits)
        │
        ▼
   Settlement ───────────── the only trusted "spender" ────┐
        │  fill(order, sig, amount)                          │
        │                                                    │
        ├─ MAKE item ─▶ IMakerModule.makeOnBehalf(...)       │  gated: msg.sender == settlement
        │                 └─ permit3.transferFrom(...)  ◀─────┤  token book (spender = module)
        │                                                     │
        └─ TAKE item ─▶ permit3.take(module, maker, ...)  ◀──┘  taker book (spender = settlement)
                          └─ ITakerModule.takeOnBehalf(...)      gated: msg.sender == permit3
                                └─ protocol borrow/withdraw
```

### Permit3 — the allowance hub

Permit3 holds **two allowance books**, both keyed by **spender** (the address
allowed to consume the allowance), exactly like Permit2:

| Book  | Key                       | Consumed by                                   |
|-------|---------------------------|-----------------------------------------------|
| Token | `(user, spender, token)`  | `transferFrom(user, to, token, amount)` — `msg.sender == spender` |
| Taker | `(user, spender, ref)`    | `take(module, user, amount, receiver, data)` — `msg.sender == spender`, `ref = keccak256(data)` |

The taker book lets a module pull *value out of a position* (borrow, withdraw,
unstake, claim) — operations that don't fit the ERC20 `transferFrom` shape.
`take` decrements the `(user, msg.sender, ref)` allowance and then calls
`module.takeOnBehalf(...)`, which performs the protocol-native call.

### Modules — single-operation adapters

Each module performs exactly one operation (one Aave borrow, one Comet
withdraw, …). This keeps blast radius small: approving a borrow module can never
be used to withdraw collateral. Modules come in two shapes:

- **Taker modules** (`ITakerModule.takeOnBehalf`) — borrow/withdraw. Reachable
  **only** through `Permit3.take`; they enforce `msg.sender == permit3`.
- **FUSED modules** (also `ITakerModule`) — a deliberate, documented exception:
  one call that performs a value-IN leg and a value-OUT leg together (supply +
  borrow, repay + withdraw, a debt swap). They exist because some protocols check
  health *inside* the value-out call, so the two legs are only valid back-to-back;
  fusing makes that ordering internal instead of a scheduling obligation the solver
  must honour. **This relaxes the one-operation rule, and the granularity is
  recovered by the allowance key rather than by the module boundary:** the taker
  allowance is keyed on `ref = keccak256(data)` and amount-capped, and a fused
  module's `data` names BOTH legs (pool, both assets, both totals). So approving a
  fused ref authorises exactly that composite at those parameters — strictly
  narrower than approving a generic borrow module for any amount — and the value-in
  leg is separately capped by the maker's ordinary token allowance to that module.
  Reference implementation + the equivalence and pro-rata tests:
  `packages/modules/lending/aave-v3/src/AaveV3FusedModules.sol`.
- **Maker modules** (`IMakerModule.makeOnBehalf`) — deposit/repay. Called
  **only** by Settlement; they enforce `msg.sender == settlement`.

### Settlement — the only trusted spender

`Settlement` is the sole address makers approve as their taker/token
spender. It verifies the EIP-712 order, runs pre-execution validators, executes
items pro-rata, runs post-execution invariants, and pays the solver from the
proceeds **produced by that fill only**.

---

## Security invariants

1. **Taker authority is spender-keyed.** A taker allowance can be consumed only
   by the spender the maker approved (Settlement). `Permit3.take` is *not*
   open to arbitrary callers in practice: a caller with no allowance under its
   own address reverts `InsufficientAllowance`. The `receiver` of proceeds is
   chosen by that trusted spender, which enforces the maker-signed `recipient`.
   *(Regression test: `Permit3.t.sol::test_take_revert_unauthorizedSpender_C1`.)*

2. **Taker modules are Permit3-only.** Every `takeOnBehalf` reverts unless
   `msg.sender == permit3`, so the spender gate above cannot be bypassed by
   calling a module directly.

3. **Maker modules are Settlement-only.** Every `makeOnBehalf` reverts unless
   `msg.sender == settlement`, so an attacker cannot force unsolicited
   deposits/repays that consume a victim's standing token allowance.

4. **`ref = keccak256(data)` with no module-side canonicalisation.** The bytes a
   maker authorises are byte-for-byte the bytes the module decodes. The
   dispatched module is bound by the maker's signed order, so it need not enter
   `ref`.

5. **Reentrancy.** `Permit3.take`, `Settlement.fill`, and the
   repay/operate modules carry `nonReentrant` guards. Flash-solver callbacks are
   authenticated by an in-flight flag plus the provider identity — pinned as an
   **immutable** where the provider is fixed, and, where the provider is chosen
   per call (Euler EVK vaults), recorded in storage by `_armProvider` BEFORE the
   external call and checked by `_requireInFlashFromArmed`. Deriving the expected
   provider from the callback's own payload is circular and therefore no check at
   all (audit H-5). Aave additionally checks `initiator == self`, and the
   per-call providers assert the callback actually ran, so a "provider" that
   returns without calling back cannot fall through to the profit sweep with an
   unvalidated order.

6. **Token movement is safe-by-default.** All ERC20 `transfer`/`transferFrom`/
   `approve` go through [`SafeTransferLib`](packages/core/src/utils/SafeTransferLib.sol)
   (`safeTransfer`, `safeTransferFrom`, `forceApprove`) — tolerating non-standard
   tokens (USDT-style no-return / approve-race). This now covers
   `packages/solvers` too (audit L-3): before that, no solver could fill a USDT
   leg at all, and a `false`-returning token turned the flash-repayment transfer
   into a silent no-op.

7. **Validators are read-only and signer-bound.** They run via `staticcall`
   (no state change, no reentrancy), and their `target` + `data` are in the
   order's EIP-712 typehash, so a solver cannot weaken or swap them.
   Validators also receive the filler address (the fill's `msg.sender`, or the
   threaded caller for `batchFill`) and can express filler-conditional policy
   such as per-order solver whitelists; the gate remains read-only and
   signer-bound.
   Validators additionally receive a filler-supplied `takerData` blob (the same
   blob for every validator + invariant of a fill), threaded from the fill
   entrypoint. `takerData` is **unsigned and adversarial** — it is NOT part of the
   maker's signed order and any filler can set it to anything — so a validator
   MUST independently verify anything it reads from it before trusting it (e.g.
   recover a maker-chosen trusted signer over an EIP-712 digest bound to the
   on-chain `filler` and the validator's own domain, as `FillerAttestationValidator`
   does). Crucially, `takerData` cannot alter the maker's signed outcome (amounts,
   tokens, recipients): only a validator — a read-only gate that can merely pass or
   fail the fill — ever consumes it. Its power is bounded to letting a maker gate a
   fill on a filler-produced proof (off-chain attestation, oracle update, ZK proof).

8. **Oracle freshness is enforced.** Chainlink validators reject
   non-positive prices, incomplete rounds, and prices older than a maker-signed
   `maxStaleness`. The MoC depeg guard rejects zero prices and reversed bands.

9. **Settlement holds no cross-fill funds.** The solver is paid from the TAKE
   proceeds of the current fill (measured as a balance delta), never from any
   pre-existing or donated Settlement balance; surplus is returned to the maker.

---

## Caveats integrators must know

These are properties of the design, not bugs — but each one breaks a reasonable
default assumption, so they are stated explicitly.

### Revoking a Permit3 allowance is NOT a kill switch

`Permit3TransferLib.transferFromWithFallback` tries Permit3 and, if that leg
fails for any reason, falls back to a direct ERC20 `transferFrom`. For a payer
who ALSO holds a plain ERC20 approval to Settlement, that means:

- per-order Permit3 **amount caps are not binding** — the fallback pulls the full
  amount regardless;
- **`revokeToken` / `lockdown` / an expiry do not stop fills.**

This is intended (a direct ERC20 approval *is* the broader grant, made
deliberately), but it means a maker who wants to actually stop settlement from
moving a token must zero BOTH the Permit3 allowance and the direct ERC20
allowance. **Wallets and UIs offering a "revoke" action MUST clear both.**

### Any contract that fills on its own behalf must hold no balance

`_deliverOutputs` pulls output legs **from `ctx.filler`**, with the direct-ERC20
fallback above. So a contract that (a) holds a token balance, (b) has approved
Settlement, and (c) exposes a permissionless path making itself the filler of a
caller-supplied order is fully drainable: anyone can sign an order naming
themselves as maker, name that token and balance as the output leg, and set
themselves as recipient.

Scoping the approval is **not** sufficient — the attacker simply signs an amount
equal to the balance they want, so the scoped approval is exactly large enough.
The working defence is a **balance floor**: snapshot each touched token on entry
and revert if the call ends below it (`NativeSettler` does this, and the
`NativeSettlerDrainPoC` regression test pins it). Solver contracts in
`packages/solvers` rely instead on holding no balance between fills; that is a
weaker posture and depends on every sweep path being exhaustive.

### Position-ID modules MUST bind the position to `onBehalfOf`

`ref = keccak256(data)` proves the bytes were authorised by **someone** — never
that the position named inside them belongs to the user being charged. The taker
book is keyed by the approver (`_takerAllowance[user][spender][ref]`), so an
attacker can self-approve a `ref` computed over a **victim's** position and carry
it in an order they signed themselves.

For most protocols this is harmless because the protocol call itself takes
`onBehalfOf` (Aave, Compound, Morpho, Silo, Venus, Lista) — the charged user and
the position are the same address by construction. It becomes a **full drain** for
protocols that identify a position by an opaque ID and grant the delegation to the
MODULE, because the module is a shared singleton registered against every user who
onboards. The protocol's own check ("is this module authorised on this position?")
then passes for the whole victim set.

Any module of that shape must resolve the position's owner on-chain and require it
to equal `onBehalfOf`:

| Protocol | Position ID | Required binding |
|---|---|---|
| Gearbox V3 | `creditAccount` | `ICreditManagerV3.getBorrowerOrRevert(ca) == onBehalfOf` — `GearboxCreditAuth` |
| Liquity V2 | `troveId` | `TroveNFT.ownerOf(troveId) == onBehalfOf` — `LiquityV2TroveAuth` |
| Fluid | position NFT `nftId` | free: `transferFrom(onBehalfOf, module, nftId)` makes ERC-721 enforce `from == ownerOf` |

Two corollaries, both learned in the composer integration (`GEARBOX.md` A2/A3):
the addresses on the auth path must be **derived on-chain** from the single
caller-supplied root, never taken from `data` (otherwise authorization can read
one contract while dispatch hits another); and the ownership read must **revert**
for an unknown position rather than return a default.

Both bindings are validated against live Ethereum mainnet state, not just mocks:

- `liquity-v2/test/fork/LiquityV2ForkAuth.t.sol` — borrows against a real trove
  through Permit3, blocks the drain, and includes
  `test_protocolItselfWouldHaveAllowedTheDrain`, which calls `withdrawBold`
  directly as the module and **succeeds**. That is the proof the finding was real:
  Liquity mints the victim's borrow with no beneficiary check anywhere, so the
  module's binding is the only control.
- `gearbox-v3/test/fork/GearboxV3ForkAuth.t.sol` — same shape against a live
  credit account.

The fork tests earn their keep: Liquity's binding was first written rooted at
`BorrowerOperations.troveManager()`, which **reverts on mainnet** (BorrowerOps
exposes almost no getters). The unit-test mocks happily provided it, so only the
fork run caught it. The chain is now rooted at the TroveManager, which does expose
`troveNFT()` and `borrowerOperations()`. Both fork files assert the exact getters
they depend on, so a silent reroot fails loudly.

### A TAKE item's proceeds token must appear in `order.legsIn`

TAKE proceeds land on Settlement (when `item.recipient` is 0), and the only code
that pays them out — `_payInputsToSolver` and `_settleInputsToPool` — iterates
`legsIn`. A proceeds token matching no input leg is **permanently stranded**:
Settlement has no sweep and no admin.

It cannot be stolen (every payout is bounded by a per-fill balance delta, and the
batch paths floor each touched token at its pre-batch balance), but it is lost.
The core cannot enforce this — the proceeds token is encoded inside the
module-specific `item.data`, which the core deliberately does not decode — so
order construction owns it. Makers can pin the outcome on-chain with a
`MinBalanceInvariant` on the expected token.

---

## Audit (2026-06-18): findings & fixes

Internal audit of `packages/core` + all module packages. All items below are
fixed in the working tree and covered by the test suite (**133/133 passing**,
including fork tests).

| ID  | Severity | Component | Finding | Fix |
|-----|----------|-----------|---------|-----|
| **C-1** | **Critical** | `Permit3.take` | The taker book was keyed by *module* and `take` was callable by anyone with an arbitrary `receiver`. Any standing taker allowance (required by the `fill()` path; left as a residual by partial `fillWithPermit`) could be drained by anyone — borrow/withdraw proceeds redirected to an attacker while the victim kept the debt. | Re-keyed the taker book by **spender** (`_takerAllowance[user][msg.sender][ref]`), mirroring the token book. Only the approved spender (Settlement) can consume an allowance; Settlement enforces the maker-signed `recipient`. |
| H-1 | High | Chainlink / DepegGuard validators | Oracle reads ignored staleness, round completeness, and price sign — a stale/zero price could pass a take-profit/stop-loss gate. | Added `price > 0`, `answeredInRound >= roundId`, and a maker-signed `maxStaleness` heartbeat to the Chainlink validators; DepegGuard now rejects zero price and reversed bands. |
| M-1 | Medium | Maker modules | `makeOnBehalf` was ungated — anyone could force a victim's pre-approved funds into deposits/repays (griefing / order-layer bypass). | Gated every `makeOnBehalf` to `msg.sender == settlement`. |
| M-2 | Medium | All modules + core | Raw ERC20 calls ignored return values (USDT-class break / silent failure). | Introduced `SafeTransferLib` and applied it repo-wide. |
| M-3 | Medium | `RedemptionSettledValidator` | "Settled" was inferred from the FIFO queue head (`firstOperId`), which only proves the op was *dequeued*, not that it cleared. | Now reads the op's final state via `opersInfo(opId)` / `operIdCount()`. |
| M-4 | Medium | Full-mode withdraws | Trusted a stale pre-read balance / static amount; could over-forward or leak a stray balance. | Forward a **measured** balance delta with `require(received >= amount)`; sweep only the real excess to the user. |
| L-1 | Low | `UniversalSettlement` (now `Settlement`) | Solver payout used the whole contract balance (could scoop donated funds). | Pay from the current fill's measured proceeds only; return surplus to the maker. |
| L-2 | Low | DepegGuard | No `minPrice <= maxPrice` validation (self-DoS). | Reverts `InvalidBand` on a reversed band. |

**Confirmed-safe (no change needed):** flash-solver callback authentication;
Morpho `onMorphoRepay` is morpho-gated with a cap check (and supply uses empty
callback data); Fluid never implements `liquidityCallback` and always returns
the position NFT to the owner; token-side `transferFrom` is spender-gated;
EIP-712 domain caching with fork-recompute; Dutch-decay ceil-div (maker never
underpaid).

---

## Audit (2026-07-29): findings & fixes

Second internal audit, covering `packages/core` (settlement + Permit3 + periphery),
every module package, and `packages/solvers`. All items below are fixed in the
working tree; the whole repo is green (**591/591 across 135 suites**). Every
security-critical fix carries a regression test, and the fixes marked ✓mut were
**mutation-tested** — the guard was removed and the test confirmed to fail — so the
coverage is known to be load-bearing rather than incidental.

| ID | Severity | Component | Finding | Fix |
|----|----------|-----------|---------|-----|
| **C-2** | **Critical** ✓mut | `LiquityV2TakerModule` | Liquity authorises the trove **manager** (this module), never a beneficiary, and `troveId` came from `data` while `onBehalfOf` was used only as a sweep destination. Since the taker book is keyed by the *approver*, an attacker could self-approve a `ref` over a **victim's** trove and fill their own order: the module ran `withdrawBold`/`withdrawColl` against the victim's trove and forwarded the proceeds to the attacker, who kept none of the debt. Every user who completed the documented setup was exposed. | `LiquityV2TroveAuth.authorizeTrove` binds `TroveNFT.ownerOf(troveId) == onBehalfOf`, with the NFT and `borrowerOperations` both DERIVED from one caller-supplied root. Mainnet-fork validated. |
| **C-3** | **Critical** (latent) | `GearboxCreditBorrowModule` | Identical shape: `creditAccount` from `data`, `onBehalfOf` explicitly discarded. Not exploitable as shipped only because the module implemented no `requiredPermissions()`, so it could never be registered as a Gearbox bot — i.e. it was armed by the first change that made it *work*. | `GearboxCreditAuth.authorize` (CA → CreditManager → facade, `getBorrowerOrRevert == onBehalfOf`), plus `requiredPermissions()` so the modules are registerable, plus the approval retargeted to the CreditManager. Mainnet-fork validated. |
| **H-2** | **High** ✓mut | `NativeSettler` | `settleFromNative` force-approved Settlement over an **attacker-named** `legsOut[0].token` and then self-settled as the filler; `_deliverOutputs` pulls outputs *from the filler*, so the contract's whole balance was drainable for 1 wei. | Balance floor: each touched token must end ≥ its entry balance. Scoping the approval alone does **not** fix this — the attacker simply signs an amount equal to the balance. |
| **H-3** | **High** ✓mut | `RiverTakerModule`, `RiverOpenModule` | River's value-out ops carry no `receiver`, so the module pulled the payout from the **maker's wallet** — without measuring what the CDP call delivered. A short or zero delivery was silently covered from the maker's pre-existing balance and paid to the solver. | `RiverProceeds` measures the maker's balance delta and fails closed. Also makes the modules correct under *both* candidate fund-flow directions. |
| **H-4** | **High** | Composite modules (Dolomite, Euler V2, Fluid, River) | `sideAmount` lives in the constant `item.data` and does **not** pro-rate, so every partial fill re-pulled it in full — an N-slice fill pulled N × the signed collateral, at a leverage ratio the maker never signed and a slice count the *solver* chooses. | `FullFillGuard`: composite items carry the item total and are full-fill only. |
| **H-5** | **High** | `EulerFlashSolver`, `EulerMultiInputFlashSolver` | `onFlashLoan` authenticated `msg.sender` against a `flashVault` decoded from the **same attacker-supplied blob** — circular, so no check at all. Separately, a fake vault that returned without calling back fell through to the tail `_sweep`, which names a token from an order that was never signature-checked on that path. | Provider pinned in storage before the external call; `_requireCallbackRan` asserts the callback fired. |
| M-5 | Medium | 15 `BalanceMode.Full` branches | `Full` liquidates the user's entire live balance regardless of slice, so a 1-unit fill force-closed the whole position and bricked the rest of the order. | `FullFillGuard.requireFullFillFromData` — maker signs the item total after the mode slot. |
| M-6 | Medium | `PermitHelper`, `DelegationHelper` (×3) | Nonce-based replays were hard calls, so a mempool front-runner could permanently brick any gasless order for ~50k gas — the signature bytes are inside `ref` and the order hash, so it could not be re-encoded. | Best-effort `try/catch`; the Permit3 pull remains the gate. See [gasless-permit-relay.md](docs/gasless-permit-relay.md). |
| M-7 | Medium | `ERC4626WithdrawModule` | Three: `asset` was caller-supplied (a free transfer of any token the module held); `pendingWithdrawals[vault][requestId]` was blind-overwritten (permanent share loss on any ERC-7540 `REQUEST_ID_0` vault); and `amount` was used as a slippage **floor**, inverting the Permit3 cap. | `vault.asset()` read on-chain; collision reverts; `amount` is the cap with surplus to the beneficiary; `minAssets` moved into `data`. |
| M-8 | Medium | `UsdrifInventorySolver` | `executeFill` accepts an arbitrary `(order, sig)` while holding a max Permit3 allowance, so an **operator** — a deliberately lower trust tier than owner — could take 100% of inventory in one self-signed order. | Owner-set `maxOutflowPerFill`, enforced as a measured delta, defaulting to zero (fail closed). Bounds a compromised key rather than eliminating it. |
| L-3 | Low | `packages/solvers` (18 call sites) | Unchecked bool-returning ERC20 calls: **no solver could fill a USDT leg at all** (the approve reverts on the ABI decode), and a `false`-returning token made the flash-repayment transfer a silent no-op. | `SafeTransferLib` throughout; `forceApprove` also clears the USDT approve-race. |
| L-4 | Low | `Base` (constructor) | A `permit3` address with no code made every transfer a **silent no-op** — orders would "settle" with nothing moving — because `transferFromWithFallback` probes with a low-level call and treats success as done. | `InvalidPermit3` constructor check. |
| L-5 | Low | `Base`, `NonceManager` | Unchecked `uint160(slice)` downcast on a value path; `exclusivityOverrideBps > 10000` surfaced as an arithmetic panic; `invalidateNonceWord` emitted no event, so bulk cancellation was invisible to indexers. | `AmountOverflow`, `InvalidOverrideBps`, `NonceWordInvalidated`. |
| L-6 | Low | `CompoundV2Native*` (×3) | Open `receive()` with no owner or rescue, and only the redeem *delta* was wrapped — stray ETH was stranded permanently. | Wrap/sweep the full native balance; the modules end every call empty. |

**Confirmed-safe (no change needed):** the `SolverCallbackExecutor` trampoline
(callback injection via `target = PERMIT3` gains nothing); `matchSettle` netting (pre-send bounded to the batch's own inflow — in `matchSettle`
netted further against obligations not yet delivered; every schedule step
bounds-checked, deliver/item units guarded exactly-once AT THE STEP, per-order
completeness and input funding asserted in the deferred flush, `BatchNotWhole`
backstop); `IFillModule` / `IOrderValidator`
declared `view`, so solc emits STATICCALL and neither can mutate state or reenter;
Settlement never grants an ERC20 approval and is not payable; EIP-712 typehash
ordering and the hand-rolled `OrderHash` buffer; signature malleability (order replay
is bounded by `filled[orderHash]`, permit replay by the nonce bitmap).

**Known open items** are tracked separately — see the repository issue list. The
notable ones: the Midnight pair (unchecked `offer.buy`; `ensureApproval` with a
caller-designatable payer), Aave v4 forwarding nominal rather than measured amounts,
Fluid's `nftId == 0` stranding a deposit, `DustHandler` truncating with `uint8(word)`
*before* the enum bounds check, and solver F3/F4/F5. `RiverModules` still needs
fork validation against a live deployment.

---

## Breaking change for integrators

### 2026-07-29 — signing-format changes

These change `ref = keccak256(data)` and/or the order hash. **SDK and relayer
encoders must be updated together**; there is no compatibility shim.

| Component | Old `data` | New `data` |
|---|---|---|
| Gearbox credit (borrow / add-collateral) | `(facade, creditAccount, asset)` | `(creditAccount, asset)` — facade **derived** |
| Liquity add-coll | `(borrowerOps, troveId, collateralToken[, permit])` | `(troveManager, troveId, collateralToken[, permit])` |
| Liquity repay | `(borrowerOps, troveManager, troveId, boldToken)` | `(troveManager, troveId, boldToken)` |
| Liquity taker (both ops) | `(op, borrowerOps, troveId, …)` | `(op, troveManager, troveId, …)` |
| ERC4626 claim (phase 2) | `(vault, asset, requestId)` | `(vault, requestId, minAssets)` |
| Composite items (Dolomite / Euler V2 / Fluid / River) | struct without `totalAmount` | `totalAmount` appended — the item's full signed amount |
| Any `BalanceMode.Full` taker leg | `… | mode(32)` | `… | mode(32) | itemTotal(32)` |

Two of these fail **silently** if missed, so they deserve extra care:

- **ERC4626 claim** — the old encoding still decodes without error; the asset address
  is simply reinterpreted as a `requestId`, which will not match a pending entry.
- **Liquity** — the leading address is now the TroveManager, not BorrowerOperations.
  Both are addresses of the same width; passing the old one resolves the chain to the
  wrong contract. (Mainnet BorrowerOperations exposes no `troveManager()` getter,
  which is *why* the root moved — see `LiquityV2TroveAuth`.)

Everything else fails closed with a named error.

### Also required before deployment

- **Gearbox** — users grant the bot role with a mask that must EXACTLY equal the
  module's `requiredPermissions()`: `0x01` for add-collateral, `0x22` for borrow.
  Gearbox rejects any other value.
- **`UsdrifInventorySolver`** — `setMaxOutflowPerFill(token, cap)` must be set by the
  owner before any operator can fill; it defaults to zero and fails closed.
- **Settlement constructor** — now rejects a `permit3` address with no code.
- **Orderbook indexers** — must additionally watch `NonceWordInvalidated`, or they
  will keep serving orders a maker has bulk-cancelled via `invalidateNonceWord`.

### 2026-06-18 — the C-1 fix

The C-1 fix changes the **off-chain signing format**. Relayers / SDKs MUST update:

- **`TakerPermit` struct**: field `module` → **`spender`**. Set it to the
  **Settlement contract address**, not the module.
- **`approveTaker(spender, ref, amount, expiration)`**: the first argument is now
  the spender (Settlement).
- **`ref` is unchanged**: still `keccak256(data)`.
- **`ModuleRefPair` → `SpenderRefPair`** (for `lockdownTakers`).
- **EIP-712 typestrings** changed to
  `TakerPermit(address spender,bytes32 ref,uint160 amount,uint48 expiration)`
  in Permit3's batch/witness typehashes and Settlement's witness typestring.
- **Maker module constructors** now take an extra `address settlement` argument.

---

## Reporting a vulnerability

Report suspected vulnerabilities privately to **security@1delta.io**. Please do
not open public issues for security reports. Include a description, affected
contracts/addresses, and a reproduction (a failing Foundry test is ideal).

### Running the test suite

```bash
forge build --skip '*.s.sol'     # '*.s.sol' skip: boilerplate Deploy script is not part of the system
forge test  --skip '*.s.sol'     # fork tests; set ETH_RPC_URL to pin a fast mainnet RPC
```
