# Gasless Permit Relay

Makers and takers can attach EIP-712 signatures to their module `data` payloads so that
on-chain approvals are not required beforehand. The signature is replayed atomically
inside the module call — if it is absent the module falls back to a standing approval.

There are three distinct signature mechanisms, each appended as an optional trailing block
to the relevant module's ABI-encoded `data`.

---

## 1. EIP-2612 Token Permit — maker modules (deposit / repay)

**Library:** `PermitHelper.replayIfPresent`  
**Applies to:** `AaveV2DepositModule`, `AaveV2RepayModule`, `AaveV3WithdrawModule` (exact mode only), any maker module that calls `PermitHelper`.

### When to use

The maker holds an ERC-20 token that implements EIP-2612 (`permit(owner, spender, value, deadline, v, r, s)`).
Instead of pre-approving Permit3, the maker signs a permit for the exact `amount` and appends
the 128-byte block to `data`.

### Byte layout (appended after the module's base data)

```
base_data           ← module-specific ABI encoding (variable length)
[optional 128 bytes]
  deadline  uint256  (32 bytes)
  v         uint8    (32 bytes, padded)
  r         bytes32  (32 bytes)
  s         bytes32  (32 bytes)
```

If `data.length < base_len + 128` the helper is a no-op; the module falls back to a
standing ERC-20 approval to Permit3.

### Example — AaveV2 deposit with permit

```solidity
bytes memory data = abi.encode(
    address(pool),          // Aave V2 pool
    address(asset),         // underlying token
    uint16(0),              // referral code
    // --- optional permit block ---
    deadline,               // uint256
    v,                      // uint8
    r,                      // bytes32
    s                       // bytes32
);
```

> **AaveV3 withdraw (exact mode only):** aToken rebases continuously; its balance cannot
> be known at signing time if using "full balance" mode. Append the permit block only when
> the withdrawal amount is a fixed exact value. The BalanceMode slot (word at offset 96)
> must be encoded explicitly as `uint8(0)` (Exact) so the delegation block starts at a
> predictable offset.

---

## 2. Credit Delegation Signature — taker modules (borrow)

**Library:** `DelegationHelper.replayAaveDelegation`  
**Applies to:** `AaveV3BorrowModule`

### When to use

The maker wants to borrow from Aave V3 on behalf of the module without calling
`debtToken.approveDelegation(module, amount)` first.
The maker signs the `delegationWithSig` payload off-chain and appends the 160-byte block.

### Byte layout

```
base_data           ← abi.encode(pool, asset, rateMode)  — 96 bytes
[optional 160 bytes]
  debtToken  address  (32 bytes, padded)
  deadline   uint256  (32 bytes)
  v          uint8    (32 bytes, padded)
  r          bytes32  (32 bytes)
  s          bytes32  (32 bytes)
```

If `data.length < 96 + 160` the delegation step is skipped (standing `approveDelegation` assumed).

### Example

```solidity
bytes memory data = abi.encode(
    address(pool), address(asset), uint256(2),   // base (96 bytes)
    // --- optional delegation block ---
    address(variableDebtToken),
    deadline,
    v, r, s
);
```

---

## 3. Comet `allowBySig` — taker modules (Compound V3 borrow / withdraw)

**Library:** `DelegationHelper.replayCometAllow`  
**Applies to:** `CometBorrowModule`, `CometWithdrawModule`

### When to use

The maker authorises the module as a `manager` on Comet so it can call `withdrawFrom`
without a prior on-chain `allow(module, true)`.

### Byte layout — borrow

```
base_data           ← abi.encode(comet, asset)  — 64 bytes
[optional 160 bytes]
  nonce    uint256  (32 bytes)
  expiry   uint256  (32 bytes)
  v        uint8    (32 bytes, padded)
  r        bytes32  (32 bytes)
  s        bytes32  (32 bytes)
```

### Byte layout — withdraw (BalanceMode slot is required when sig present)

```
base_data           ← abi.encode(comet, asset, BalanceMode)  — 96 bytes
[optional 160 bytes — same fields as above]
```

The explicit `BalanceMode` word (even if `uint8(0)` = Exact) must be present so the
delegation block starts at a known offset (96 bytes from the start).

### Example — borrow

```solidity
bytes memory data = abi.encode(
    address(comet), address(asset),              // base (64 bytes)
    nonce, expiry, v, r, s                       // delegation block
);
```

---

## 4. Morpho Blue `setAuthorizationWithSig` — taker modules

**Library:** `DelegationHelper.replayMorphoAuth`  
**Applies to:** `MorphoBlueBorrowModule`, `MorphoBlueWithdrawCollateralModule`

### When to use

The maker grants the module authorization on Morpho Blue (required before
`borrow` or `withdrawCollateral` can be called on the maker's behalf) without
executing a prior `setAuthorization(module, true)` transaction.

### Byte layout — borrow

```
base_data           ← abi.encode(MarketParams)  — 160 bytes (5 × 32)
[optional 160 bytes]
  nonce     uint256  (32 bytes)
  deadline  uint256  (32 bytes)
  v         uint8    (32 bytes, padded)
  r         bytes32  (32 bytes)
  s         bytes32  (32 bytes)
```

### Byte layout — withdraw collateral (BalanceMode slot required when sig present)

```
base_data           ← abi.encode(MarketParams, BalanceMode)  — 192 bytes
[optional 160 bytes — same fields as above]
```

### Example — borrow

```solidity
bytes memory data = abi.encode(
    marketParams,                                // MarketParams (160 bytes)
    nonce, deadline, v, r, s                     // auth sig
);
```

---

## 5. ERC20PermitTransferModule — standalone gasless transfer

This module is not a lending adapter. It lets a maker transfer any EIP-2612 token to an
arbitrary recipient through Permit3 in a fully gasless, atomic, single-signature flow.

### Order shape

```
legsIn   = [ LegIn{ token: the ERC-20 being transferred, … } ]
legsOut  = [] (no output) or one LegOut in the same token (no swap, fee taken as spread)
items    = [] (no lending operations)
```

### data encoding

```solidity
bytes memory data = abi.encode(
    address(recipient),     // where proceeds land
    // --- optional EIP-2612 permit block ---
    deadline,               // uint256
    v,                      // uint8
    r,                      // bytes32
    s                       // bytes32
);
```

Without the permit block the module relies on a standing Permit3 allowance.

### Fee model

The solver earns the spread: `amountIn − amountOut`. For a zero-fee transfer
give the output `LegOut` a fixed amount equal to the input (`start == amountIn`,
`end == 0`).

---

## Offset rule summary

| Module | Base length | Sig block offset |
|---|---|---|
| AaveV2 deposit / repay | 96 bytes | 96 |
| AaveV3 withdraw (exact, permit) | 128 bytes (inc. BalanceMode) | 128 |
| AaveV3 borrow (delegation) | 96 bytes | 96 |
| Compound V3 borrow (allowBySig) | 64 bytes | 64 |
| Compound V3 withdraw (allowBySig) | 96 bytes (inc. BalanceMode) | 96 |
| Morpho Blue borrow (authSig) | 160 bytes (5-word MarketParams) | 160 |
| Morpho Blue withdraw collateral | 192 bytes (inc. BalanceMode) | 192 |
| ERC20PermitTransferModule | 32 bytes (recipient) | 32 |

All sig blocks are 128 bytes (EIP-2612) or 160 bytes (delegation / auth) and are
**no-ops** when absent — the module falls back to whatever standing approval already
exists on-chain.
