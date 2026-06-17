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

| File                                   | Purpose                                                          |
|----------------------------------------|------------------------------------------------------------------|
| [`Permit3.sol`](Permit3.sol)           | Allowance-hub contract. Token + taker books, `take()` dispatch.  |
| [`../interfaces/IPermit3.sol`](../interfaces/IPermit3.sol)       | External surface.                       |
| [`../interfaces/ITakerModule.sol`](../interfaces/ITakerModule.sol) | Uniform adapter interface modules implement.         |

## Architecture

```
                     ┌──────────────────────────┐
                     │         Permit3          │
                     │                          │
       approveToken  │  tokenAllowance          │
       transferFrom  │    (user, spender, tok)  │
    ────────────────▶│                          │
                     │  takerAllowance          │
       approveTaker  │    (user, module, ref)   │
           take      │                          │
    ────────────────▶│  take(...) ──────┐       │
                     └──────────────────┼───────┘
                                        │
                                        │  1. ref = keccak256(data)
                                        │  2. _spend allowance on ref
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
  Spender calls `permit3.transferFrom(user, to, token, amount)`.

- **Taker book** — keyed `(user, module, bytes32 ref)` where
  `ref = keccak256(data)`. Any caller invokes
  `permit3.take(module, user, amount, receiver, data)`; Permit3
  decrements the allowance on that ref and calls
  `module.takeOnBehalf(...)`. Asset identity lives inside `data` (or
  is implicit to the position for protocols like Morpho/Comet).

  The bytes that produce the ref are the *exact* bytes the module
  decodes — so whatever the user authorised is byte-for-byte what
  gets executed. No canonicalisation layer, no module indirection.

Permit3 never speaks to a lending/staking protocol directly — all
protocol-specific plumbing lives in taker modules.

### Single-operation modules

Every `ITakerModule` performs exactly one operation. The op is identified
by the module's address; the position is identified by `keccak256(data)`.
This has three consequences:

- Approvals are legible: `approveTaker(AaveV3BorrowModule, ref, 1000 USDC)`
  is unambiguously a borrow authorisation.
- Module code stays tiny — one protocol call, one optional
  `permit3.transferFrom` for ERC20 legs, nothing else.
- A compromised borrow module cannot be used to withdraw collateral, and
  vice versa.

Adding a new lender or op = adding a new module. Permit3 and the
interface do not change.

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

```solidity
bytes32 ref = keccak256(data);     // same bytes the solver will pass to `take`
permit3.approveTaker(borrowModule, ref, 1_000e6, uint48(block.timestamp + 1 hours));
```

Sign the order and hand it to a solver (or self-solve).

### Settlement / solver (per fill)

```solidity
permit3.take(borrowModule, maker, 1_000e6, settlement, data);
// internally:
//   ref = keccak256(data)
//   _spend(takerAllowance[maker][borrowModule][ref], 1_000e6)
//   borrowModule.takeOnBehalf(maker, 1_000e6, settlement, data)
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
- `revokeTaker(module, ref)` — zero a taker allowance.
- `lockdown(TokenSpenderPair[])` — atomically zero a batch of token
  allowances on-chain (ported from Permit2's `lockdown`).
- `lockdownTakers(ModuleRefPair[])` — taker-book analogue (Permit3 extension).
- `invalidateUnorderedNonces(wordPos, mask)` — cancel signed permits before
  they are consumed (ported from Permit2's `invalidateUnorderedNonces`).

## Security properties

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
- [x] [`LimitOrderSettlement`](../settlement/LimitOrderSettlement.sol)
      rewired to Permit3: taker legs via `permit3.take`, maker legs via
      `module.makeOnBehalf`, token legs via `permit3.transferFrom`, no
      module whitelist, no admin role.

Not yet implemented:
- [ ] Concrete taker modules (AaveV3Borrow/Withdraw, Comet, Morpho
      Blue, Compound V2, Lido unstake/claim).
- [ ] `revokeAll(module)` helper that also calls the module's
      per-protocol revoke path.
- [ ] Foundry invariant suite asserting `data` round-trips cleanly
      through each module (the ref a frontend hashes matches the bytes
      the module decodes).
