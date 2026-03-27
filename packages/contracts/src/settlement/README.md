# Settlement

Core entry point for the lending intent system. Verifies maker-signed EIP-712 orders and orchestrates lending operations and conversions.

## Settlement.sol

### Key functions

| Function | Description |
|----------|-------------|
| `settle(order, sig)` | Fill a single signed order |
| `settleBatch(orders, sigs)` | Fill multiple orders atomically |
| `cancelOrders(nonces)` | Maker cancels specific nonces |
| `invalidateNonceWord(wordIndex)` | Emergency: invalidate 256 nonces in one shot |
| `setModule(module, enabled)` | Owner whitelists/removes a lending module |
| `previewConversion(conversion)` | View: current dutch auction output amount |
| `isNonceUsed(maker, nonce)` | View: check if nonce is consumed |

### Execution flow (`_settle`)

```
1. _verifyOrder       → EIP-712 signature check (ecrecover)
2. deadline + nonce   → revert if expired or replayed (bitmap nonce)
3. _checkCondition    → gas price / timestamp gate
4. _processConversionInputs  → pull tokenOut from solver → maker (dutch auction amount)
5. _executeLendingItems      → deposit/withdraw/borrow/repay via whitelisted modules
6. _processConversionOutputs → send tokenIn (e.g. borrow proceeds) from settlement → solver
```

### Nonce management

Uses bitmap nonces (like Uniswap Permit2): each `uint256` word covers 256 sequential nonces.

```
nonce 0-255   → nonceBitmap[maker][0]
nonce 256-511 → nonceBitmap[maker][1]
...
```

- `cancelOrders(uint256[])` — set individual bits
- `invalidateNonceWord(wordIndex)` — set entire word to `type(uint256).max`

### Token flow for lending items

| Operation | Tokens from | Tokens to | Who pays |
|-----------|-------------|-----------|----------|
| DEPOSIT | maker → settlement → module | module (collateral position) | maker |
| WITHDRAW | module | maker | protocol |
| BORROW | module | settlement (held) | protocol (debt to maker) |
| REPAY | maker → settlement → module | module (debt reduced) | maker |

For conversions, borrowed funds held by the settlement are forwarded to the solver as `tokenIn`.

### Condition types

| Type | Behavior |
|------|----------|
| `NONE` | Always passes |
| `MAX_GAS_PRICE` | Reverts if `tx.gasprice > value` — MEV-gated execution |
| `MIN_TIMESTAMP` | Reverts if `block.timestamp < value` — time-locked orders |
