# Gasless Permit Relay

Makers can attach a signature to a module's `data` blob so that an on-chain approval
is not needed beforehand. The signature is replayed inside the module call, best
effort; if it is absent (or the replay fails) the module falls back to whatever
standing approval exists, and the Permit3 pull or venue call that follows is the
real gate.

There are four mechanisms, each an optional trailing block appended to the module's
ABI-encoded `data`. **The offset of the block is per module and per op, and it is
NOT always the base length**: a module with an op word, a `DustAction`/`BalanceMode`
word or a mandatory `totalAmount` places the block after those. The offset table at
the end of this page is checked against the code by `make docs-check` (every `@N`
in a row must be an offset at which that contract replays a signature), and the
per-module byte maps live in each module's header comment, which shapes rule 9b
holds to the code. When this page and a module header disagree, the header wins.

---

## 1. EIP-2612 token permit (`PermitHelper`)

**Library:** `PermitHelper.replayIfPresent` (and `replayValueIfPresent`, below).
**Used by:** the pull-shaped MAKE modules (deposit, repay, add-collateral) of most
venues, `ERC20PermitTransferModule`, and `AaveV3WithdrawModule` (aToken permit).

### Byte layout

```
base_data                 module-specific encoding (see the table)
[optional 128 or 160 bytes]
  deadline     uint256
  v            uint8   (ABI-padded)
  r            bytes32
  s            bytes32
  [signedValue uint256]   optional trailing word (2026-09-30, L-AAVE-2)
```

If `data.length < offset + 128` the helper is a no-op.

**`signedValue`.** An EIP-2612 signature commits to `value`. Without the trailing
word the replay uses `amount`, i.e. THIS fill's pro-rated slice, so the signature
verifies only on a fill whose slice equals what the maker signed: in practice one
full fill. A maker who wants partial fills signs `value = item total` and appends it
as `signedValue`; the first fill lands an allowance for the total and every later
slice finds it sufficient and skips the replay.

**`replayValueIfPresent`** (the Exactly fixed-maturity repay and the Exactly share
permits) reads an EXPLICIT value first: `abi.encode(value, deadline, v, r, s)`, 160
bytes.

**The spender** is `Permit3` for a pull module. `AaveV3WithdrawModule` is the
exception: its permit is an **aToken** permit to the **module itself** (the module
pulls the aToken directly), not to Permit3.

### The replay is BEST-EFFORT, and must stay that way

`PermitHelper` wraps the `permit` call in `try/catch` and ignores any revert. ERC-2612
`permit` burns a per-owner nonce and reverts once it is spent. The signature bytes
live **inside the module's `data`**, which is part of the order hash and, for a TAKE
item, of `ref = keccak256(data)`, so they cannot be re-encoded without invalidating
both. If the replay reverted on a used nonce, anyone could kill a gasless order for
the price of one transaction: lift `(deadline, v, r, s)` from the mempool and submit
`token.permit(...)` directly.

Swallowing the revert is correct **for the pending fill**: the front-runner leaves
the allowance the fill wanted, and the `permit3.transferFrom` that follows still
reverts if the allowance is genuinely missing. Regression coverage:
`packages/core/test/utils/PermitReplayGriefing.t.sol`.

### What best-effort does NOT cover (2026-09-30, L-LIB-4 / L-CMT-3)

- **A permit SETS the allowance, it does not raise it.** Replayed over a maker's
  standing `approve(permit3, max)` it would shrink that grant to this fill's value
  and silently break the maker's other resting orders in the token. The helpers
  therefore **skip the replay when the standing allowance already covers the fill**.
- **The signature is public and any-sender.** A third party can land it directly at
  any time before its deadline, including after the maker cancelled the order, and
  so reset a standing allowance to the signed value. No value moves (Permit3's books
  still gate every pull), but the maker must re-approve.
- **Advice:** do not append a permit when a sufficient standing grant already exists,
  and sign the permit `deadline` no later than the order deadline.

**Consequence for integrators:** an expired or consumed permit does not surface its
own revert; a failing gasless fill reports the *pull* failing.

### Example: Aave v2 deposit with a permit

```solidity
bytes memory data = abi.encode(
    address(pool),   // Aave v2 pool       @0
    address(asset),  // underlying         @32   (base = 64)
    deadline, v, r, s // permit block      @64
    // , signedValue  // optional, for partial fills
);
```

---

## 2. Aave credit delegation (`delegationWithSig`)

**Library:** `DelegationHelper.replayAaveDelegation`
**Used by:** `AaveV3CreditModule` (both ops, both seams). Aave **v2 has no
`delegationWithSig`**: Aave v2 borrows need an on-chain `approveDelegation`.

```
[optional 160 or 192 bytes]
  debtToken    address
  deadline     uint256
  v, r, s
  [signedValue uint256]   optional trailing word, same rule as §1
```

`delegationWithSig` SETS the borrow allowance to the signed value, so the replay is
skipped when the standing `borrowAllowance` already covers the fill (L-LIB-4). With
`signedValue` appended the delegation is no longer full-fill-only.

---

## 3. Comet `allowBySig`

**Library:** `DelegationHelper.replayCometAllow`
**Used by:** `CometTakerModule` (op 0 Borrow, op 1 Withdraw). The old
`CometBorrowModule` / `CometWithdrawModule` were merged into it.

```
[optional 160 bytes]
  nonce, expiry, v, r, s
```

Byte map (op word first): `abi.encode(uint8(op), comet, asset, …)`, base 96.

- Borrow: allow block at 96.
- Withdraw `Exact`: `BalanceMode` word at 96 (encode it explicitly when a tail
  follows), allow block at 128.
- Withdraw `Full`: the tagged mode word `0xB0DE0001` at 96, the mandatory
  `totalAmount` at 128, allow block at 160.

The replay runs even when the module is already allowed: landing the signature
consumes Comet's `userNonce`, which retires it.

---

## 4. Morpho Blue / Lista Moolah `setAuthorizationWithSig`

**Library:** `DelegationHelper.replayMorphoAuth`
**Used by:** `MorphoBlueTakerModule` (op 0 Borrow, op 1 WithdrawCollateral, op 2
Withdraw), `ListaTakerModule`, `ListaNativeCollateralTakerModule`,
`ListaSmartTakerModule` and `ListaBrokerModule` (op 1 Borrow). The old
`MorphoBlueBorrowModule` / `MorphoBlueWithdrawCollateralModule` were merged into
`MorphoBlueTakerModule`.

```
[optional 160 bytes]
  nonce, deadline, v, r, s
```

Morpho byte map: `abi.encode(uint8(op), MarketParams, …)`, base 192. Borrow: auth at
192. Withdraw `Exact`: mode word at 192, auth at 224. Withdraw `Full`: tagged mode at
192, `totalAmount` at 224, auth at 256. The Lista modules carry a leading `moolah`
(and for op 2 a `provider`) address, which shifts every offset by one or two words.

Morpho authorization is coarse (all markets) and permanent once installed; the
Permit3 taker allowance caps the per-fill amount.

---

## 5. EVC `permit` (Euler v2)

**Library:** `DelegationHelper.replayEvcPermit`
**Used by:** `EulerV2OperatorModule` (`Op.Open`), tail at 128.

The tail is DYNAMIC: `abi.encode(DelegationHelper.EvcPermit[])` with
`EvcPermit = (nonceNamespace, nonce, deadline, evcData, sig)`; each permit is
replayed independently. **The maker signs `sender = EulerV2OperatorModule`**
(2026-09-30, L-ED-1): the replay submits with `sender = address(this)`, so only a
live fill of the maker's own order can land it, and a lifted permit cannot be landed
directly. Put the long-lived operator grant in its own permit and nonce namespace,
apart from per-order controller/collateral enables. BREAKING vs. the earlier single
`(ns, nonce, deadline, evcData, sig)` tail signed with `sender = 0`.

---

## 6. `ERC20PermitTransferModule`: a gasless transfer

A TAKE module that moves an ERC-20 from the maker to a recipient, funded by a Permit3
taker grant, with the solver paid by the spread.

```solidity
bytes memory data = abi.encode(
    address(token),     // @0
    address(recipient), // @32
    transferAmount,     // @64  reaches the recipient
    totalAmount,        // @96  the item's full signed amount (fee + transfer)
    deadline, v, r, s   // optional permit block @128 (+ signedValue)
);
```

Order shape: an outputless order, `legsIn[0]` = the solver's fee (it may RISE over
time to attract a solver; the rise above the module's spread is pulled from the
maker's Settlement token grant), one TAKE item of `fee + transferAmount`. **Full-fill
only** (2026-09-30, L-LIB-2): the slice must equal `totalAmount`. BREAKING: the permit
tail moved from byte 96 to byte 128. End-to-end coverage:
`PermitTransferSettlementFlowTest`
(`test_audit_MISC_MOD_6_transferFlow_risingFeeLeg_coreBillsTheRise`).

## 7. Gasless order FUNDING: a book-carried ERC-2612 permit (off-chain, no module)

Sections 1–6 replay a signature inside a module call, so they only reach orders with
items. A plain conversion order (no items — every order the Rootstock beta app signs)
is funded through a different, already-deployed seam: Settlement's
**direct-approval fallback**. `Base._pullViaPermit3` tries the Permit3 leg and, when
it fails and the payer is not in Permit3 strict mode, pulls with a plain
`token.transferFrom(maker, …)` against an ERC-20 allowance to **Settlement**
([account-onboarding.md](account-onboarding.md), "two funding surfaces"). An EIP-2612
permit with `spender = Settlement` creates exactly that allowance from a signature.
Shipped 2026-10-12 with **no core change**; the permit is submitted by the
`AggregatorFillSolver` inside the fill (its `executeFill(…, permits)` argument, new in
the 2026-10-12 solver version):

```
maker (no RBTC):  sign Order  +  sign Permit(owner, spender = Settlement, value = order input,
                                              nonce = token.nonces(owner), deadline = order expiry)
app → book:       POST /orders { order, sig, erc2612Permit: { token, spender, value, nonce, deadline, v, r, s } }
book:             verify the permit (below), admit the order although the lens says fillable 0
filler:           gate the fill WITH the permit's gas → ONE tx: solver.executeFill(order, sig, amount, plan, "",
                                                                  permits = [{token, owner = maker, value, deadline, v, r, s}])
solver:           token.permit(maker, SETTLEMENT, value, deadline, v, r, s)  — failed? accept iff allowance ≥ value
                  → the ordinary fill (Settlement pulls through the direct allowance)
```

Why the spender is Settlement and not Permit3: a 2612 permit to Permit3 is only the
first of Permit3's two legs; the book grant to Settlement would need a second
signature (`Permit3.permitBatch`, relayed as a second call) or the single-signature
`fillWithPermit` entry, which the `AggregatorFillSolver` cannot call (it fills
through `fillWithCallback`; see its header). The direct allowance is one signature
and one `permit` call, and it is just as bounded — Settlement pulls from a maker only
against an order that maker signed — and as exact (`value` = this order's input).

Core regression (mainnet fork, USDC is also EIP-2612): a third party relays the
maker's permit to Settlement, a replay reverts, and the item-free fill pulls exactly
the permitted input through the fallback —
`DirectApprovalFallbackTest:test_maker_tokenIn_relayedErc2612PermitToSettlement`.

### Which Rootstock tokens support it (verified 2026-10-12, chain 30)

| token | EIP-2612 | domain (name, version) | notes |
|---|---|---|---|
| USD₮0 `0x779D…3736` | **yes** — `permit(v,r,s)`, `permit(bytes)` (EIP-1271), `nonces`, `DOMAIN_SEPARATOR` | `("USD₮0", "1")`, chainId 30, the proxy | TransparentUpgradeableProxy → `TetherTokenOFTExtension` (impl `0x1ec7…b6a3`): OZ `ERC20PermitUpgradeable` + EIP-3009 (`transferWithAuthorization`); the domain name is the LIVE `name()` (`updateNameAndSymbol` would change it); no `eip712Domain()` / `version()` view. `DOMAIN_SEPARATOR()` = `0x69a2…97ef` = the computed value |
| USDRIF `0x3A15…6e37` | no | — | proxy → impl `0x6d1b…5af9`: no `permit` / `nonces` / `DOMAIN_SEPARATOR` |
| WRBTC `0x542f…677d` | no | — | WETH9 port: its fallback answers ANY call with empty data — a naive "does `permit` succeed?" probe would say yes |
| WETH `0x2F6F…7590` | no | — | |
| RIF `0x2AcC…9D5` | no | — | ERC-677 |
| DOC `0xe700…D9Db` | no | — | fallback answers with empty data, like WRBTC |
| rUSDT `0xEf21…BB96` | no | — | |

No DAI-style `permit(holder, spender, nonce, expiry, allowed, …)` on any of them. The
SDK pins the one supported domain (`ERC2612_TOKENS`, `erc2612DomainOf`), and the app
refuses to sign when the token's on-chain `DOMAIN_SEPARATOR()` differs from it.

### Verification (book) — `Verifier.checkErc2612` in `@1delta-x/orderbook`

Layer 1 (no RPC): spender = this Settlement; token is one of the order's input
tokens; `value > 0`; `deadline ≥ order.expiry` (the permit must stay relayable for the
order's whole life) and in the future; `v ∈ {27, 28}`, low `s`; not combined with a
`permitBatch` or `sigless`. On-chain: read `DOMAIN_SEPARATOR()`, `nonces(maker)`,
`balanceOf(maker)`; recover the signature locally against the token's OWN separator
(no name/version string is trusted, and a token without the views — WRBTC, DOC — is
refused); `nonce > current` is malformed; `nonce < current` means spent or superseded,
which is NOT a rejection — the order is then judged on whatever allowance exists. A
live permit is finally run as an `eth_call` of `token.permit(...)` so the token itself
confirms it. A live permit with a non-zero balance admits the order with
`state.erc2612Live = true` and the lens's (zero) `fillableAmount`; the periodic
re-check re-judges it every sweep.

### In-fill permit (filler + solver) — `packages/beta-filler/src/permit.ts`, `AggregatorFillSolver._permits`

The engine stages every book entry that carries a permit (four reads — lens
`getOrderRelevantState` + `remaining`, the token's `nonces` + `balanceOf` — only for
shapes a strategy takes):

- the permit does not name this Settlement as spender or an input-leg token → ignored;
- **funded** already (the lens's fillable > 0: someone ran the permit, or the maker
  approved) → fill normally on the lens's fillable, **without** the permit (the solver
  would accept it, but it only costs gas);
- **permit**: unfunded, the permit live (`nonce == nonces(maker)`, deadline more than
  60 s away, maker balance > 0) → hand the route strategy the size the order WILL have
  (`remaining`, capped by the balance and `value` for a fixed-input sell) and the
  permit;
- **dead**: spent / superseded with nothing funding the order, expiring, no balance, or
  `PERMIT_FILLS_ENABLED=0` → skip and hold.

The route strategy runs every gate it always runs (preview, price, route quotes,
profit) with `PERMIT_IN_FILL_GAS` added to the pre-simulation gas estimate, then
simulates and sends ONE `executeFill(…, permits = [toSolverPermit(maker, permit,
Settlement)])`: the solver calls `token.permit(maker, SETTLEMENT, …)` and then fills.
The simulation runs the permit too, so no prior relay is needed to price the fill, and
its `eth_estimateGas` is what the tx is priced and sent at. The solver refuses a permit
whose `owner` is not the order's maker (`PermitOwnerNotMaker`) — the spender is never a
field, always its own `SETTLEMENT`. The inventory strategy (an EOA `fillUpTo`) cannot
carry a permit: it skips such an order until something else has funded it.

### Gas, latency, risks

- **Gas**: no extra tx; the permit is part of the fill. USD₮0 `permit` to Settlement
  inside `executeFill`: +46.5k net / +59.3k execution gas on the fill (USD₮0 permit:
  0→value allowance + nonce 0→1 writes), vs 95.1k for the old separate relay tx;
  `PoolRouteForkBench.test_permit_inFill` vs `test_permit_baseline_directApproval` /
  `test_permit_standaloneRelayTx` (`packages/solvers/test/PoolRouteFork.t.sol`). At
  Rootstock's ~0.026 gwei that is ~1–2 × 10⁻⁶ RBTC. The filler's gate charges
  `PERMIT_IN_FILL_GAS` (60,000, `packages/beta-filler/src/route.ts`) before simulating.
- **Latency**: none added — the permit and the fill land in the same tx (the replaced
  relay design sent the permit first and filled a block later).
- **Front-running the permit** (anyone may submit it — it is public in the book):
  harmless. The solver's `permit` call then fails on the used nonce, and the solver
  accepts that because Settlement's allowance from the maker already covers `value`
  (relayed, front-run, or approved directly); otherwise it reverts `PermitFailed` before
  anything moves. Once the allowance exists the filler's stage says `funded` and it sends
  no permit at all.
- **Owner must be the maker**: only the party whose order is filling can be the one
  whose allowance the solver sets (`PermitOwnerNotMaker`).
- **EOA / inventory path**: `Settlement.fillUpTo` from an EOA cannot carry a permit, so the
  inventory strategy fills a gasless order only once it is funded.
- **Stripping**: the permit is not covered by the order signature, so a relay could
  drop it (the order is then unfunded); it cannot forge one.
- **Sequential nonces**: two gasless orders in the same token signed before either is
  filled carry the SAME nonce; running one makes the other's permit stale. And a
  permit SETS the allowance, so a newer gasless order replaces an older unfilled one's
  — the same exact-size overwrite the approve path already has. The app says so.
- **Strict mode**: a maker with `Permit3.setStrictMode(true)` (or per token) refuses the
  direct surface by design — no fallback, the fill reverts `Permit3Denied` even with the
  permit in it; strict makers are unsupported and the app does not offer gasless
  funding then.
- **Leftover**: an unfilled order leaves its direct allowance standing until a fill uses
  it or the maker revokes it (one `approve(Settlement, 0)`, which the app's revoke now
  includes) — as the approve path leaves its ERC-20 approval to Permit3. Only an order
  the maker signed can spend it.

---

## Offset table

Every `@N` below is checked by `make docs-check` against the contract's replay calls.

| Contract (op / branch) | Mechanism | Signature offset |
|---|---|---|
| `AaveV2DepositModule` | EIP-2612 to Permit3 | permit @64 |
| `AaveV2RepayModule` | EIP-2612 to Permit3 | permit @160 (after `debtToken` at 96 and `DustAction` at 128) |
| `AaveV3DepositModule` | EIP-2612 to Permit3 | permit @64 |
| `AaveV3RepayModule` | EIP-2612 to Permit3 | permit @160 |
| `AaveV3WithdrawModule` (Exact) | aToken EIP-2612 to the module | permit @128 (mode word explicit) |
| `AaveV3CreditModule` (Borrow) | `delegationWithSig` | delegation @128 |
| `AaveV3CreditModule` (Leverage, plain TAKE) | `delegationWithSig` | delegation @224 |
| `AaveV3CreditModule` (Leverage, pre-funded) | `delegationWithSig` | delegation @192 |
| `AaveV4DepositModule` | EIP-2612 to Permit3 | permit @128 |
| `AaveV4RepayModule` | EIP-2612 to Permit3 | permit @160 |
| `CometDepositModule` | EIP-2612 to Permit3 | permit @64 |
| `CometRepayModule` | EIP-2612 to Permit3 | permit @96 |
| `CometTakerModule` (Borrow) | `allowBySig` | allow @96 |
| `CometTakerModule` (Withdraw, Exact) | `allowBySig` | allow @128 |
| `CometTakerModule` (Withdraw, Full) | `allowBySig` | allow @160 |
| `MorphoBlueSupplyModule` / supply-collateral | EIP-2612 to Permit3 | permit @160 |
| `MorphoBlueRepayModule` | EIP-2612 to Permit3 | permit @192 |
| `MorphoBlueTakerModule` (Borrow) | `setAuthorizationWithSig` | auth @192 |
| `MorphoBlueTakerModule` (Withdraw*, Exact) | `setAuthorizationWithSig` | auth @224 |
| `MorphoBlueTakerModule` (Withdraw*, Full) | `setAuthorizationWithSig` | auth @256 |
| `ListaTakerModule` (op 1, Exact / Full) | Moolah `setAuthorizationWithSig` | auth @256 / @288 |
| `ListaTakerModule` (op 2 provider, Exact / Full) | Moolah `setAuthorizationWithSig` | auth @288 / @320 |
| `ListaBrokerModule` (op 1 Borrow) | Moolah `setAuthorizationWithSig` | auth @224 (`moolah` word at 192) |
| `ListaBrokerModule` (op 0 Repay, pull) | EIP-2612 to Permit3 | permit @160 |
| `EulerV2OperatorModule` (Open) | EVC `permit[]`, sender = module | tail @128 |
| `ExactlyDepositModule` | EIP-2612 to Permit3 | permit @128 |
| `ExactlyRepayModule` (floating / fixed) | EIP-2612 (fixed: explicit value) | permit @160 / @192 |
| `ExactlyTakerModule` (Borrow / Withdraw) | share permit, explicit value | permit @192 / @224 |
| `SiloDepositModule` | EIP-2612 to Permit3 | permit @64 |
| `SiloRepayModule` | EIP-2612 to Permit3 | permit @96 |
| `GearboxPoolDepositModule` | EIP-2612 to Permit3 | permit @64 |
| `LiquityV2AddCollModule` | EIP-2612 to Permit3 | permit @96 |
| `RiverAddCollModule` | EIP-2612 to Permit3 | permit @160 |
| `TellerRepayModule` | EIP-2612 to Permit3 | permit @128 |
| `ERC20PermitTransferModule` | EIP-2612 to Permit3 | permit @128 |

All blocks are no-ops when absent. A `BalanceMode.Full` taker leg carries the tagged
mode word `0xB0DE0001` (`DustHandler.encodeMode(Full)`; a bare `1` reverts
`InvalidModeWord`) followed by the item's full signed amount, and the module requires
this fill's slice to equal it (`FullFillGuard.requireFullFillFromData`, fails closed
with `PartialFillUnsupported`). On a module whose `Full` branch moves the signature
tail (Comet, Morpho, Lista), the tail sits after that total, as the rows show.
