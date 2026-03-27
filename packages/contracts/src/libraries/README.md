# Libraries

Pure/view helper libraries used by the Settlement and off-chain tooling.

## OrderLib.sol

EIP-712 struct hashing for the `Order` type and all nested structs. Produces the struct hash that gets signed by the maker.

**Typehash hierarchy:**

```
Order (top level)
├── Condition
├── LendingItem[]     — each item hashed individually, array hashed as encodePacked(hashes)
└── ConversionItem[]  — same pattern
```

**Key detail:** The `bytes data` field on `LendingItem` is hashed as `keccak256(data)` per EIP-712 spec for dynamic `bytes` types. This means the maker commits to the exact protocol-specific params without the settlement needing to understand them.

**Usage:**
```solidity
using OrderLib for Order;
bytes32 structHash = order.hash();
bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
```

## DutchDecayLib.sol

Calculates the current required output amount for a dutch auction conversion.

```
startAmountOut ─────────╲
                         ╲
                          ╲  linear decay
                           ╲
endAmountOut ───────────────╲───────────
             |              |           |
         decayStart    current     decayEnd
```

**Function:** `currentAmountOut(ConversionItem) → uint256`

- Before `decayStartTime`: reverts with `AuctionNotStarted`
- During decay: linear interpolation between start and end
- After `decayStartTime + decayDuration`: returns `endAmountOut`
- Reverts with `InvalidAuctionParams` if `startAmountOut < endAmountOut`

## MakerChecks.sol

View helpers for off-chain use. Checks whether a maker has sufficient balances and approvals for an order's deposit/repay operations before a solver attempts to fill it.

**Function:** `checkOrder(Order, settlement) → CheckResult(bool ready, string reason)`

Does NOT check protocol-level delegation (credit delegation, Comet `allow()`, etc.) — that's protocol-specific and verified by the modules at execution time.
