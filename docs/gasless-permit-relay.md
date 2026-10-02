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
