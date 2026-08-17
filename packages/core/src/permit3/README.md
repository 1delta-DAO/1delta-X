# Permit3

Unified allowance hub for ERC20 transfers **and** protocol "taker" operations
(borrow, withdraw, unstake, claim, vault redemption, …). Extends the
[Permit2](https://github.com/Uniswap/permit2) model with a second allowance
book for position-pulling ops that don't fit the ERC20 `transferFrom` shape.

## Why

The existing settlement layer relied on a maker-signed order plus an
admin-controlled module whitelist. That conflates two trust decisions:

1. **Which protocols am I willing to interact with?** — user-scoped.
2. **How much am I willing to let this module pull from me right now?** —
   per-order, amount-gated.

Permit3 makes (2) explicit and protocol-agnostic. Users approve Permit3 once
per (token) or per (module, position), and tune amount caps per order
thereafter — the same ergonomic as Permit2, extended to debt/withdrawal/etc.

## Files

Permit3 is decomposed the way Permit2 is: each layer owns its own state and its
own rules, and `Permit3.sol` is nothing but the point where they meet.

| File                                             | Purpose                                                                   |
|--------------------------------------------------|---------------------------------------------------------------------------|
| [`Permit3.sol`](Permit3.sol)                     | Assembly point — `contract Permit3 is SignedPermits, SignatureTransfer {}`. |
| [`Permit3Base.sol`](Permit3Base.sol)             | `IPermit3` + `EIP712`; resolves the `DOMAIN_SEPARATOR` diamond once.       |
| [`AllowanceTransfer.sol`](AllowanceTransfer.sol) | Token book — `approveToken`, `transferFrom`, `revokeToken`, `lockdown`.    |
| [`TakerAllowance.sol`](TakerAllowance.sol)       | Taker book — `approveTaker`, `take`, `revokeTaker`, `lockdownTakers`.     |
| [`SignedPermits.sol`](SignedPermits.sol)         | Signed **allowance grants** over both books — `permitBatch(WithWitness)`.  |
| [`SignatureTransfer.sol`](SignatureTransfer.sol) | Signed **one-shot transfers** — `permitTransferFrom(WitnessTransferFrom)`. |
| [`UnorderedNonces.sol`](UnorderedNonces.sol)     | Nonce bitmap shared by both signed flows + `invalidateUnorderedNonces`.    |
| [`EIP712.sol`](EIP712.sol)                       | Fork-safe domain separator (verbatim Permit2 port).                       |
| [`SignatureVerification.sol`](SignatureVerification.sol) | EOA / EIP-2098 / EIP-1271 / EIP-7702 signature checking.           |
| [`AllowanceHolder.sol`](AllowanceHolder.sol)     | **Standalone.** Signature-free ephemeral allowances (0x port).            |
| [`libraries/Allowance.sol`](libraries/Allowance.sol)   | Packed grant/spend primitives shared by both books.                 |
| [`libraries/Permit3Hash.sol`](libraries/Permit3Hash.sol) | Every EIP-712 type string and struct hasher.                      |
| [`../interfaces/IPermit3.sol`](../interfaces/IPermit3.sol)             | External surface (books + allowance permits).      |
| [`../interfaces/ISignatureTransfer.sol`](../interfaces/ISignatureTransfer.sol) | External surface (one-shot transfers).   |
| [`../interfaces/IAllowanceHolder.sol`](../interfaces/IAllowanceHolder.sol)     | External surface (ephemeral allowances). |
| [`../interfaces/ITakerModule.sol`](../interfaces/ITakerModule.sol)     | Uniform adapter interface modules implement.       |

All libraries are `internal`-only: they inline into their caller, so there is no
delegatecall and no link step.

## Provenance: what is Permit2 and what is not

Permit3 is [Permit2](https://github.com/Uniswap/permit2) (Uniswap, MIT) plus a
second allowance book. Every source file carries a `PROVENANCE` block with the
same detail as below — `grep -rn PROVENANCE` to read them in place.

| File                    | Permit2 origin                        | Status |
|-------------------------|---------------------------------------|--------|
| `Permit3.sol`           | `Permit2.sol`                         | same shape — an empty contract joining the layers |
| `AllowanceTransfer.sol` | `AllowanceTransfer.sol`               | ported, with deviations |
| `SignatureTransfer.sol` | `SignatureTransfer.sol`               | ported — the closest to a straight port here |
| `UnorderedNonces.sol`   | `SignatureTransfer.sol` (nonce half)  | ported, extracted into its own layer |
| `SignedPermits.sol`     | `AllowanceTransfer.permit()`          | reworked |
| `libraries/Allowance.sol`   | `libraries/Allowance.sol`         | rewritten around the same slot layout |
| `libraries/Permit3Hash.sol` | `libraries/PermitHash.sol`        | half ported verbatim, half new |
| `EIP712.sol`            | `EIP712.sol`                          | verbatim but for the domain values + a scratch-space digest |
| `SignatureVerification.sol` | `libraries/SignatureVerification.sol` | adapted (EIP-7702 ordering, calldata reads) |
| `TakerAllowance.sol`    | —                                     | **new in Permit3** |
| `Permit3Base.sol`       | —                                     | **new in Permit3** (glue for the extra layers) |
| `AllowanceHolder.sol`   | —                                     | **not Permit2** — ported from 0x |

### Symbol map

| Permit2                                  | Permit3                          |
|------------------------------------------|----------------------------------|
| `approve(token, spender, …)`             | `approveToken(spender, token, …)` |
| `allowance[owner][token][spender]`        | `tokenAllowance(user, spender, token)` — **key order differs** |
| `transferFrom` (single + batch)          | same                             |
| `lockdown`                               | same (+ `lockdownTakers`)        |
| `permit(owner, PermitSingle\|PermitBatch, sig)` | `permitBatch(owner, PermitBatch, sig)` |
| —                                        | `permitBatchWithWitness`         |
| `permitTransferFrom` / `permitWitnessTransferFrom` | same, all four overloads |
| `nonceBitmap`                            | `permitNonceBitmap` (+ `isPermitNonceUsed`) |
| `invalidateUnorderedNonces`              | same                             |
| `invalidateNonces(token, spender, nonce)` | — (no allowance-level nonce)    |
| —                                        | `approveTaker` / `take` / `takerAllowance` / `revokeTaker` |
| —                                        | `revokeToken`                    |

### Behavioural deviations to know about

These change what identical-looking code does. Read them before porting
reasoning — or an audit finding — across from Permit2.

1. **`expiration == 0` is inverted.** Permit3: never expires. Permit2: the
   opposite — its gate has no zero-exemption, and `approve` rewrites a 0 to
   `block.timestamp`, so the grant dies at the end of that block.
2. **Token-book key order.** `[user][spender][token]` here vs
   `[owner][token][spender]` in Permit2, so it lines up with the taker book.
   Off-chain slot derivations do not carry over.
3. **No allowance-level nonce.** Permit2 gates `permit` on a sequential
   per-(owner, token, spender) nonce and offers `invalidateNonces`. Permit3
   relies on the unordered bitmap alone; `PackedAllowance.nonce` is written as 0
   and reserved.
4. **One nonce space.** Permit3's bitmap is shared by allowance permits and
   signature transfers; Permit2 keeps sequential nonces for the former and a
   private bitmap for the latter. Allocate nonces per-owner, not per-flow.
5. **Verify-then-spend-nonce.** Permit2's signature transfers spend the nonce
   first. Both spend it before any token moves; ours is ordered for consistency
   across the two signed flows, not for a security reason.
6. **Signed grants are one batch spanning both books**, each leg naming its own
   spender — where Permit2 has `PermitSingle`/`PermitBatch`, both scoped to a
   single spender. Permit3 also binds a witness to an allowance grant, which
   Permit2 does only for signature transfers.

Permit2 pieces with no Permit3 counterpart: `PermitSingle`, `invalidateNonces` /
`ExcessiveInvalidation`, `SafeCast160`, `Permit2Lib` (the caller-side helper —
[`Permit3TransferLib`](../utils/Permit3TransferLib.sol) is a different thing: a
direct-approval fallback, not a DAI-permit shim) and `IDAIPermit`.

EIP-712 type strings for signature transfers are **byte-identical** to Permit2's,
so signing tooling needs no changes; digests still differ because the domain
names this contract, so no signature crosses between the two in either direction.

**Base order is load-bearing.** Storage slots follow C3 linearisation, so
reordering the base list in `Permit3.sol` or `SignedPermits.sol` moves every
mapping. Permit3 is deployed fresh per chain and is not upgradeable, so this is
a review hazard rather than a migration one — but a redeploy that silently
relocates `_tokenAllowance` would strand allowances mid-migration.

## Architecture

```
                     ┌──────────────────────────┐
                     │         Permit3          │
                     │                          │
       approveToken  │  tokenAllowance          │
       transferFrom  │    (user, spender, tok)  │
    ────────────────▶│                          │
                     │  takerAllowance          │
       approveTaker  │    (user, spender, ref)  │
           take      │                          │
    ────────────────▶│  take(...) ──────┐       │
                     └──────────────────┼───────┘
                                        │
                                        │  1. ref = keccak256(data)
                                        │  2. _spend (user, msg.sender, ref)
                                        │  3. takeOnBehalf(...)
                                        ▼
                     ┌──────────────────────────┐
                     │     ITakerModule(A)      │   e.g. AaveV3BorrowModule
                     │                          │
                     │   takeOnBehalf(...)      │   calls protocol
                     └──────────────────────────┘
                                        │
                                        ▼
                            protocol-native borrow /
                            withdraw / unstake / claim …
```

### Two allowance books

- **Token book** — keyed `(user, spender, token)`. Permit2-equivalent.
  Spender calls `permit3.transferFrom(user, to, token, amount)`; the
  allowance gates on `msg.sender == spender`.

- **Taker book** — keyed `(user, spender, module, bytes32 ref)` where
  `ref = keccak256(data)`. The **spender** is the address allowed to call
  `take` (the Settlement contract), exactly mirroring the token book, and the
  **module** is the adapter the grant authorises. An approved spender invokes
  `permit3.take(module, user, amount, receiver, data)`; Permit3
  decrements the `(user, msg.sender, module, ref)` allowance and calls
  `module.takeOnBehalf(...)`. Asset identity lives inside `data` (or
  is implicit to the position for protocols like Morpho/Comet).

  `module` is in the key (audit fix S-2): `ref = keccak256(data)` alone did not
  bind the module, and minimal `data` layouts (`abi.encode(comet)`,
  `abi.encode(cToken)`) are shared across modules, so a standing grant to one
  module could be consumed dispatching another. Now approving a borrow module can
  never dispatch a withdraw module, whatever the data.

  Because the book is spender-keyed, a standing taker allowance can only
  ever be consumed by the spender the maker approved — a third party
  calling `take` with the same `data` has no allowance under its own
  address and reverts. The dispatched `module` is bound by the maker's
  signed order (Settlement only ever calls the order's own `item.module`),
  so it does not need to enter `ref`.

  The bytes that produce the ref are the *exact* bytes the module
  decodes — so whatever the user authorised is byte-for-byte what
  gets executed. No canonicalisation layer, no module indirection.

Permit3 never speaks to a lending/staking protocol directly — all
protocol-specific plumbing lives in taker modules.

### Single-operation modules

Every `ITakerModule` performs exactly one operation. The op is identified
by the module's address; the position is identified by `keccak256(data)`.
This has three consequences:

- Approvals are legible: `approveTaker(settlement, AaveV3BorrowModule, ref, 1000
  USDC)` is unambiguously a borrow authorisation — the spender is Settlement, and
  the module (`AaveV3BorrowModule`) is a signed part of the key.
- Module code stays tiny — one protocol call, one optional
  `permit3.transferFrom` for ERC20 legs, nothing else.
- A compromised borrow module cannot be used to withdraw collateral, and
  vice versa.

Adding a new lender or op = adding a new module. Permit3 and the
interface do not change.

## Granting authority

Four paths, distinguished by how long the authority lives and what it costs to
create. The books and the module dispatch are the same underneath.

| Path                     | Where                | Signature? | Survives the call?      |
|--------------------------|----------------------|------------|-------------------------|
| `approveToken` / `approveTaker` | `AllowanceTransfer` / `TakerAllowance` | no  | yes — until revoked  |
| `permitBatch(WithWitness)`      | `SignedPermits`      | one per grant | yes — until spent or expired |
| `permitTransferFrom`            | `SignatureTransfer`  | one per transfer | **no** — nothing is written |
| `AllowanceHolder.exec`          | `AllowanceHolder`    | no         | **no** — zeroed before return |

### Signature transfers (`SignatureTransfer`)

Permit2's `SignatureTransfer`, ported. The owner signs *"`spender` may move at
most `amount` of `token`, once, before `deadline`"*; the spender consumes it by
naming a recipient and an amount at or below the cap. No allowance book is
touched, so there is nothing to revoke afterwards and nothing to expire.

The signed `spender` is always `msg.sender` — never a caller-supplied argument.
A signature that leaks from a mempool, a failed relay or a log is therefore
useless to anyone but the intended spender. **Never add an overload that takes
`spender` in.**

Type strings are byte-identical to Permit2's, so existing tooling produces them
unchanged; digests still differ because the domain names this contract
("Permit3"), so a Permit2 signature can never be replayed here or vice versa.

Nonces come from the same per-owner bitmap the allowance permits use. One nonce
is spendable exactly once, whichever flow spends it, and
`invalidateUnorderedNonces` cancels both kinds — at the cost that off-chain
nonce allocation must be per-owner, not per-message-type.

### Ephemeral allowances (`AllowanceHolder`)

The signature-free option, ported from 0x. The owner approves `AllowanceHolder`
once on the ERC20, then calls
`exec(operator, token, amount, target, data)`: the holder grants `operator` an
allowance, calls `target`, and zeroes the allowance before returning. No
signature, and no standing approval to the consuming contract.

It is deliberately **standalone and unprivileged**, and must stay that way.
`exec` makes an arbitrary call to an arbitrary target from the holder's address,
so anything the holder is trusted with, everyone is trusted with. Folded into
Permit3 the same capability would be a total bypass: taker modules gate on
`msg.sender == permit3`, so a Permit3 that could be told to call anything would
let anyone reach `takeOnBehalf` directly. Never grant the holder authority —
not as a Permit3 spender, not as a module's authorised caller — and never leave
tokens or ETH sitting in it.

Two guards carry the design:

- **`_rejectIfERC20`** — targets that answer `balanceOf(address)` are refused.
  Every user's approval sits on the holder, so a direct call to a token would
  let any caller spend them all (`exec(_, _, 0, USDC, transferFrom(victim, …))`),
  the `amount` grant being irrelevant. Only *direct* calls are dangerous —
  through any intermediate contract `msg.sender` is no longer the holder. The
  probe is a heuristic and deliberately over-broad; loosen it only with a
  positive allowlist.
- **`AllowanceInFlight`** — a nested `exec` on the same (operator, owner, token)
  is rejected rather than allowed to clobber the outer grant and zero it early.
  Nesting on a *different* triple stays legal, which multi-token flows need.

The grant is a real `SSTORE`, not `TSTORE` — some target chains have no
transient storage. Set-then-clear inside one transaction refunds the full write
(EIP-3529), so on any transaction big enough to clear the `gasUsed/5` refund cap
— a settlement fill is an order of magnitude past it — the net cost is about the
cold-slot premium (~2.3k gas), not the ~22k headline.

`msg.sender` is appended to `data` as 20 trailing bytes (ERC-2771 style) so a
target that cares can recover the real caller; Solidity's decoder ignores
trailing calldata, so targets that don't are unaffected.

## Usage

### Maker (one-time, per module/protocol)

1. Protocol-native delegation that lets the module act on-chain:
   ```
   aaveVariableDebtToken.approveDelegation(borrowModule, type(uint256).max)
   comet.allow(withdrawModule, true)
   morpho.setAuthorization(borrowModule, true)
   ```
2. Permit3 token approval for any ERC20 the module may need to pull:
   ```
   token.approve(permit3, type(uint256).max)
   permit3.approveToken(module, token, cap, expiration)
   ```

### Maker (per-order, amount-gated)

The taker allowance is granted to the **spender** that will call `take` — the
Settlement contract — not to the module:

```solidity
bytes32 ref = permit3.refFor(data);   // == keccak256(data); the bytes the solver passes to `take`
permit3.approveTaker(settlement, borrowModule, ref, 1_000e6, uint48(block.timestamp + 1 hours));
```

Sign the order and hand it to a solver (or self-solve). (In the single-signature
flow, the maker instead signs a `TakerPermit{spender: settlement, ref, ...}`
inside a witness-bound permit batch — see `fillWithPermit`.)

### Settlement / solver (per fill)

```solidity
// msg.sender == settlement (the approved spender)
permit3.take(borrowModule, maker, 1_000e6, receiver, data);
// internally:
//   ref = keccak256(data)
//   _spend(takerAllowance[maker][msg.sender /* settlement */][ref], 1_000e6)
//   borrowModule.takeOnBehalf(maker, 1_000e6, receiver, data)
```

Inside `takeOnBehalf` the module is free to call
`permit3.transferFrom(maker, ..., token, amount)` to pull ERC20s as part
of the op (fees, collateral swaps, etc.) — the token book gates those
pulls independently.

## Module parameterisation

Since `ref = keccak256(data)`, the `data` layout is simultaneously the
allowance preimage and the module's decode input. Everything the
module needs must live in `data`; everything that scopes the
allowance is *also* in `data`, because there is nowhere else for it
to go. Sub-configs (rate modes, collateral types) are therefore
always scoped correctly — they can't be omitted.

### Aave v3

```solidity
// Borrow module — handles both rate modes
data = abi.encode(address pool, address asset, uint8 rateMode)   // 1=stable, 2=variable

// Withdraw module
data = abi.encode(address pool, address asset)
// (aToken is derivable from pool+asset; if the module wants to cache it,
//  it can read it from pool. Keeping it out of `data` means allowances
//  don't have to be reissued if the aToken address is ever known via
//  a different lookup path.)
```

`rateMode` is part of `data` → part of the ref. Stable-debt and
variable-debt are separate positions with separate protocol-layer
delegations, and a user approving one does not approve the other.

### Compound V3 (Comet)

```solidity
// Borrow — base asset is fixed by the comet instance
data = abi.encode(address comet)

// Withdraw collateral — collateral asset needs scoping
data = abi.encode(address comet, address collateralAsset)
```

### Compound V2 / Venus

```solidity
data = abi.encode(address cToken)
```

Underlying asset is derivable from `cToken`; the cToken address alone
identifies the position.

### Morpho Blue

```solidity
// Morpho markets are identified by the full MarketParams struct —
// morpho.borrow takes the struct, not the id.
data = abi.encode(MarketParams memory mp)   // (loanToken, collateralToken, oracle, irm, lltv)
```

The ref `keccak256(data)` is effectively the namespaced marketId.
Borrow and withdraw modules have different addresses, so the same
`data` yields different allowance buckets per op.

### Silo (sub-config example)

```solidity
enum CollateralType { Collateral, Protected }

data = abi.encode(address silo, address asset, CollateralType ct)
```

`Protected` vs `Collateral` are economically distinct positions
(different earn rate, different liquidation behaviour). Because they
sit in `data`, they're automatically part of the ref — authorising
"borrow against my protected USDC" cannot be used to borrow against
the regular deposit.

### The sub-config rule

If a parameter changes what position is being touched, put it in
`data`. If it only routes information the module already has (or can
derive trivially), leave it out — including it just pins allowances
to a specific derivation path for no gain.

Two practical tips:

1. **Decide the `data` layout once per module and don't change it.**
   Changing the layout later invalidates every existing approval,
   silently. If you need a v2, ship `ModuleV2` at a new address.

2. **Keep `data` tight.** Don't pad it with "nice to have" UX fields
   (protocol name, expected receiver, etc.) — those go in order
   metadata, not in the bytes the allowance is keyed to.

## Semantics

| Field                 | Meaning                                                |
|-----------------------|--------------------------------------------------------|
| `amount = uint160.max`| Infinite — not decremented on spend.                   |
| `expiration = 0`      | No expiration.                                         |
| `expiration > 0`      | Allowance expires at `block.timestamp > expiration`.   |
| `nonce`               | Reserved for future EIP-712 signed permits.            |

Revocation:
- `revokeToken(spender, token)` — zero a token allowance.
- `revokeTaker(spender, ref)` — zero a taker allowance.
- `lockdown(TokenSpenderPair[])` — atomically zero a batch of token
  allowances on-chain (ported from Permit2's `lockdown`).
- `lockdownTakers(SpenderRefPair[])` — taker-book analogue (Permit3 extension).
- `invalidateUnorderedNonces(wordPos, mask)` — cancel signed permits before
  they are consumed (ported from Permit2's `invalidateUnorderedNonces`).

## Security properties

- **Taker authority is spender-keyed** (`_takerAllowance[user][msg.sender][ref]`),
  exactly like the token book. Only the spender the maker approved (Settlement)
  can consume a taker allowance and choose the proceeds `receiver` — a third
  party calling `take` directly has no allowance under its own address and
  reverts. Settlement, in turn, enforces the maker-signed `recipient`. This is
  the load-bearing taker-side gate; the module's `msg.sender == permit3` check is
  necessary but not sufficient on its own (it funnels all calls through `take`).
  *(See finding C-1 in [`/SECURITY.md`](../../../../SECURITY.md).)*
- **Consume-then-call invariant is enforced by Permit3**, not by the
  module. A buggy module cannot silently bypass the allowance gate.
- **`nonReentrant` guards `take()`** — a module cannot re-enter Permit3
  to inflate its own allowance window mid-op.
- **Ref = `keccak256(data)` with no module-side canonicalisation.** The
  bytes a user authorises are the same bytes the module decodes — the
  module can't lie about which position the approval was for. A buggy
  module that decodes `data` wrong harms only its own users, bounded
  by the approved cap, same as a buggy Permit2 spender.

### Blast-radius caveats (document for UX)

- **Infinite taker allowance to a compromised module is worse than
  infinite token approval.** Token compromise drains balances; taker
  compromise can incur max-LTV debt and route proceeds elsewhere. The
  UX should not push "approve max" for taker allowances the way wallets
  do for ERC20.
- **Boolean-only protocols** (Comet `allow`, Morpho `setAuthorization`)
  have no amount cap at the protocol layer. Permit3 is the *only*
  amount-gate for those. Module correctness is load-bearing.
- **Two-layer revocation.** To fully lock out a compromised module a
  user must revoke at Permit3 *and* revoke the protocol-native
  delegation. A `revokeAll` helper that bundles both per-protocol is a
  worthwhile future addition.

## Status

Implemented:
- [x] Token book (`approveToken`, `transferFrom` single + batch, `revokeToken`).
- [x] Taker book (`approveTaker`, `take`, `revokeTaker`).
- [x] `take()` dispatch with `nonReentrant` + `ref = keccak256(data)` + `_spend`.
- [x] `uint160.max` infinite semantics; `expiration == 0` sentinel.
- [x] EIP-712 signed permits (`permitBatch`, `permitBatchWithWitness`) with
      unordered (bitmap) nonces.
- [x] One-shot signature transfers (`permitTransferFrom`,
      `permitWitnessTransferFrom`, both single and batched) sharing that nonce
      space — Permit2's `SignatureTransfer`, ported.
- [x] `AllowanceHolder` — signature-free ephemeral allowances, standalone and
      unprivileged, with the confused-deputy probe and the in-flight guard.
      **Not wired into Settlement**; see below.
- [x] Permit2-derived signature stack: `SignatureVerification` (EOA 65-byte +
      EIP-2098 compact + EIP-1271 contract signatures + EIP-7702 accounts,
      verified ecrecover-first then EIP-1271 fallback) and fork-safe `EIP712`
      domain separator (recomputed if `block.chainid` changes).
- [x] `lockdown` / `lockdownTakers` (atomic batch revocation) and
      `invalidateUnorderedNonces` (cancel signed permits).
- [x] `ITakerModule` interface — single-method surface (`takeOnBehalf`).
- [x] `IMakerModule` interface — symmetric single-method surface
      (`makeOnBehalf`) for deposit/repay-style ops. (Name mirrors
      limit-order parlance: takers draw value out, makers put it in.)
- [x] [`Settlement`](../settlement/Settlement.sol)
      rewired to Permit3: taker legs via `permit3.take`, maker legs via
      `module.makeOnBehalf`, token legs via `permit3.transferFrom`, no
      module whitelist, no admin role.

Added in the 2026-08-17 audit remediation:
- [x] **Module-bound taker key** (S-2) — `(user, spender, module, ref)`;
      `TakerPermit`/`approveTaker`/`takerAllowance`/`revokeTaker`/`SpenderRefPair`
      all carry `module`.
- [x] **Idempotent `permitBatchWithWitnessIfNeeded`** (S-1) — verifies the
      signature every time but skips a spent nonce (and its grant) instead of
      reverting, so front-running the permit can no longer brick a `fillWithPermit`
      order and partial fills reuse one signature. `Core.fillWithPermit` uses it.
- [x] **Zero-amount guards** (S-3) on `transferFrom` and the transfer library.
- [x] **`Taken` event** on `take` (S-8); **double-probe** confused-deputy check in
      `AllowanceHolder` (S-6).
- [x] **`permitTake` / `permitTakeWithWitness`** — the taker-book analogue of
      `permitTransferFrom`: a signature authorising ONE module dispatch with no
      allowance left behind. Shipped as a Permit3 primitive; Settlement wiring is
      deferred (the generic item loop dispatches every TAKE via a standing
      allowance, so a pre-step would double-dispatch — see the note in
      [`Core.sol`](../settlement/Core.sol)).
- [x] **`refFor(data)`** helper; **`ITakerModuleDescribe.describe`** optional
      module surface for rendering a ref in words (U-5).
- [x] **`setStrictMode` / `strictMode`** (U-6) — opt-in that makes revocation a
      real kill switch by refusing the direct-approval fallback.
- [x] **`lockdownAll`** (U-4) — one call revoking both books + signed-permit
      nonces (supersedes the proposed `revokeAll`).
- [x] **ERC-5267 `eip712Domain()`** on Permit3 (U-8).
- [x] **`SettlementLens.previewTakerAllowances`** (U-3) — per-TAKE-item taker
      allowance preflight, which the token-side preview skipped for item orders.

Not yet implemented:
- [ ] Settlement wiring for `AllowanceHolder` (filler-side, via the `takerData`
      channel) and for `permitTake` (needs the fill item-loop to be permit-aware).
      Both are additive fill-path changes with their own gas-snapshot/test surface.
- [ ] Concrete taker modules for chains not yet covered by the `packages/modules`
      tree.
- [ ] Foundry invariant suite asserting `data` round-trips cleanly through each
      module (the ref a frontend hashes matches the bytes the module decodes).
