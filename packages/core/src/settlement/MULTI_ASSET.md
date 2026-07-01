# Multi-asset conversion leg — design

Status: **implemented**. The `UniversalSettlement` conversion leg was extended
from single `tokenIn → tokenOut` to **multi-in / multi-out**, JAM-style, while
preserving the single-fraction partial-fill invariant. `fill`/`fillWithPermit`
return `uint256[]` (per output leg) and `OrderFilled` carries `uint256[]
fillAmountsOut`. Coverage: `test/swaps/MultiAssetSwap.t.sol` (multi-in,
multi-out, partial-fill basket scaling, validate guards).

## Scope

Only the **conversion leg** (maker ↔ solver swap) is single-asset today. The
`Item[]` system is already arbitrary multi-asset on the position side (the
migration example moves four tokens in one order). This change is confined to
the swap fields:

| Direction | Today | Proposed |
|---|---|---|
| maker gives → solver | `tokenIn`, `amountIn` | `tokenIn[]`, `amountIn[]` |
| solver gives → maker | `tokenOut`, `startAmountOut`, `endAmountOut` | `tokenOut[]`, `startAmountOut[]`, `endAmountOut[]` |

## Load-bearing invariant (do NOT break)

Everything scales by **one** fill fraction `f = fillAmountIn / amountIn` — the
out amount and every item slice. This is what makes partial fills + dutch decay
provably consistent.

JAM's per-token `filledAmounts[]` discards this. **We do not adopt it.** A
single scalar drives every leg:

- `amountIn[0]` is the **fill reference / denominator** (`amountIn` in the math
  below). `fillAmountIn` is still expressed in `tokenIn[0]` units.
- Every other `amountIn[i]`, every `tokenOut[j]`, and every item slice scale by
  the same `f`.

Consequence: the solver cannot independently size each sell token — the whole
basket fills proportionally. That is the correct trade-off for an intent settler
(the maker signed a fixed basket ratio). Independent per-token fills would be a
different protocol, not a parameter.

```
f            = fillAmountIn / amountIn[0]
inAmount_i   = amountIn[i]        × f         (cumulative, ceil for i==0 payout parity)
outAmount_j  = currentAmountOut_j × f         (ceil — maker never underpaid)
itemSlice_k  = item.amount_k      × f         (cumulative, as today)
```

## Proposed `Order` struct

```solidity
struct Order {
    address maker;
    uint256 nonce;
    uint256 deadline;
    address[] tokenIn;          // maker gives (solver receives)
    uint256[] amountIn;         // amountIn[0] is the fill denominator
    uint32 decayStartTime;      // shared clock for all output legs
    uint32 decayDuration;       // shared clock
    address[] tokenOut;         // maker receives (solver gives)
    uint256[] startAmountOut;   // per output: best-for-maker
    uint256[] endAmountOut;     // per output: worst-for-maker (floor)
    address exclusiveFiller;
    uint32 exclusivityEndTime;
    uint256 minFillAmountIn;    // in tokenIn[0] units
    Item[] items;
    Validator[] validators;
    Validator[] invariants;
}
```

Invariants (checked in `validateOrder`, footgun guards only — a malformed order
can only harm its own maker):

- `tokenIn.length == amountIn.length`, both non-empty; `amountIn[0] != 0`.
- `tokenOut.length == startAmountOut.length == endAmountOut.length`, non-empty.
- per index `j`: `startAmountOut[j] != 0`, `startAmountOut[j] >= endAmountOut[j]`.
- `tokenIn[]` and `tokenOut[]` disjoint (generalizes today's
  `tokenIn == tokenOut`). See "overlap" below — supportable, but forbidding is
  the safe default for v1.
- `minFillAmountIn <= amountIn[0]`.
- `decayDuration != 0 ⇒ decayStartTime != 0`.

## EIP-712 typehash

Dynamic arrays of value types hash as `keccak256(abi.encodePacked(elements))`;
`address[]`/`uint256[]` need no per-element struct hashing (unlike `Item[]`).

```solidity
bytes32 internal constant ORDER_TYPEHASH = keccak256(
    "Order(address maker,uint256 nonce,uint256 deadline,address[] tokenIn,uint256[] amountIn,uint32 decayStartTime,uint32 decayDuration,address[] tokenOut,uint256[] startAmountOut,uint256[] endAmountOut,address exclusiveFiller,uint32 exclusivityEndTime,uint256 minFillAmountIn,Item[] items,Validator[] validators,Validator[] invariants)"
    "Item(uint8 op,address module,uint256 amount,address recipient,bytes data)"
    "Validator(address target,bytes data)"
);
```

`_hashOrder` gains array-hash helpers alongside the existing `_hashItems` /
`_hashValidators`:

```solidity
function _hashAddresses(address[] calldata a) private pure returns (bytes32) {
    return keccak256(abi.encodePacked(a));
}
function _hashUints(uint256[] calldata a) private pure returns (bytes32) {
    return keccak256(abi.encodePacked(a));
}
```

The head/tail split in `_hashOrder` stays (stack-too-deep); each array field
contributes its 32-byte sub-hash.

The witness type string `_ORDER_WITNESS_TYPESTRING` must mirror the new `Order`
definition **exactly**, keeping alphabetical ordering of the appended type defs
(Item, Order, TakerPermit, TokenPermit, Validator).

## Token flow (`_fillCore`)

```
fill(order, sig, fillAmountIn)          // fillAmountIn in tokenIn[0] units

f = fillAmountIn / amountIn[0]

1. solver → maker, per output j:
     PERMIT3.transferFrom(msg.sender, maker, tokenOut[j], outAmount_j)
   (batchable via IPermit3.transferFrom(AllowanceTransferDetails[]))

2. snapshot balanceOf(tokenIn[i]) for every i   ← before items (anti-donation)

3. _executeItems(order, prevFilled, newFilled)  ← unchanged, drives off f

4. settle each tokenIn[i] → solver:
     proceeds_i = balanceOf(tokenIn[i]) - before_i
     pay min(proceeds_i, owed_i) from proceeds
     surplus → maker; shortfall → PERMIT3.transferFrom(maker, solver, ...)

5. invariants
```

`_currentAmountOut` returns `uint256[]` — same decay math per index, one shared
clock.

`_payTokenInToSolver` generalizes per-token: the anti-donation snapshot property
holds independently for each `tokenIn[i]`.

## Overlap edge case

If a token appears in more than one of `tokenIn[]`, `tokenOut[]`, or a TAKE
item's output, the proceeds snapshot must be **summed per token address**, not
per array slot — otherwise a shared balance is double-counted. For v1, forbid
`tokenIn ∩ tokenOut` in `validateOrder` and require distinct entries within each
array; revisit if a use case needs overlap.

## Migration / off-chain impact

This is a **breaking order-schema change**: `ORDER_TYPEHASH`, the Permit3
witness type string, and all off-chain signing/SDK. Batch it with the SDK
release that carries the Permit3 spender-keying change rather than shipping two
separate breaking off-chain migrations.

## Explicitly rejected alternatives

- **Per-token `filledAmounts[]` (JAM)** — breaks the single-fraction invariant;
  partial fills would no longer keep items and decay in lockstep.
- **Unified `inputs[]`+`outputs[]` rewrite** — folds the auction-priced
  conversion and fixed-amount items into one list, muddying the "auction prices
  only the conversion, items are fixed" guarantee. The arrays approach keeps
  that boundary crisp.

## Gas note

Output delivery and input settlement become loops over maker-signed arrays,
bounded by the signer (only harms their own order). No protocol DoS risk, but
the README's "fills stay cheap" claim should be re-qualified for large baskets.
