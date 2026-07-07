// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Operation kind per item. Names mirror limit-order parlance:
///         takers draw value out of a position, makers put value in.
///         (Unrelated to the order's `maker` field, which names the signer.)
///
///         MAKE — deposit/repay-style: Settlement calls the module, the
///                module pulls the funding token from the order maker via
///                Permit3.
///         TAKE — borrow/withdraw-style: Settlement calls `permit3.take`,
///                which enforces the taker allowance gate and dispatches
///                to the module; proceeds land at `receiver = Settlement`.
enum ItemOp {
    MAKE,
    TAKE
}

/// @notice Which leg of the order is the auction (variable) side and which is
///         the fixed anchor that the fill amount is denominated in.
///
///         SELL — the maker gives a FIXED input basket and receives an
///                auction-priced output basket (outputs decay
///                `startAmountOut → endAmountOut`, best-for-maker first). The
///                fill is denominated in `tokenIn[0]` units. The classic
///                "sell exactly X, take what the auction clears" order.
///         BUY  — the maker receives a FIXED output basket and pays an
///                auction-priced input basket (inputs rise
///                `startAmountIn → endAmountIn`, best-for-maker first). The
///                fill is denominated in `tokenOut[0]` units. The exact-output
///                "buy exactly X, pay up to Y" order.
enum OrderSide {
    SELL,
    BUY
}

/// @notice A single lending item inside a Order.
/// @dev    `module` is a single-op adapter (`IMakerModule` for MAKE,
///         `ITakerModule` for TAKE). `amount` is the *total* amount for a
///         fully filled order; per-fill slices are computed pro-rata so
///         partial fills accumulate exactly to `amount` once fully filled.
///         `data` is the module's decode input and also the allowance
///         preimage (`ref = keccak256(data)` for TAKE ops).
///
///         `recipient` applies to TAKE items only — it is the address that
///         receives the protocol proceeds (e.g. borrow output, withdrawn
///         collateral). `address(0)` is the canonical default and means
///         "send to Settlement" (classic flow — proceeds flow to the solver
///         via `tokenIn` payout). Signing `recipient = maker` chains the
///         output into a subsequent MAKE item via the maker's wallet.
///         Ignored for MAKE items (set to 0 when constructing).
struct Item {
    ItemOp op;
    address module;
    uint256 amount;
    address recipient;
    bytes data;
}

/// @notice A read-only trigger. Settlement `staticcall`s `target.validate(order, data)`
///         and aborts the fill unless the returned bool is `true`. Multiple
///         validators on an order are AND-composed. Both `target` and `data`
///         are in the EIP-712 typehash → solver cannot alter.
struct Validator {
    address target;
    bytes data;
}

/// @notice A signed limit order (SELL or BUY — see {OrderSide}).
/// @dev    The conversion leg is multi-asset: the maker gives a basket
///         (`tokenIn[]`/`startAmountIn[]`/`endAmountIn[]`) and receives a basket
///         (`tokenOut[]`/`startAmountOut[]`/`endAmountOut[]`). One side is FIXED
///         (`start == end`) and the other decays as a dutch auction; `side`
///         selects which:
///           • SELL — inputs fixed, outputs decay; anchor = `startAmountIn[0]`,
///                    fill amount is in `tokenIn[0]` units.
///           • BUY  — outputs fixed, inputs rise; anchor = `startAmountOut[0]`,
///                    fill amount is in `tokenOut[0]` units.
///         Partial fills are driven by a SINGLE scalar fraction
///         `f = fillAmount / anchor[0]`. Every leg (both baskets) and every item
///         slice scale by the same `f`, so the whole order fills proportionally
///         (the solver cannot size each leg independently).
struct Order {
    address maker;
    OrderSide side; //      SELL (outputs decay) or BUY (inputs rise)
    uint256 nonce;
    uint256 deadline;
    address[] tokenIn; //   maker gives (solver receives)
    uint256[] startAmountIn; //      per input: SELL fixed amount (== end); BUY auction start (best for maker)
    uint256[] endAmountIn; //        per input: SELL == start; BUY auction ceiling (worst for maker / "pay up to")
    uint32 decayStartTime;
    uint32 decayDuration;
    address[] tokenOut; //  maker receives (solver gives)
    uint256[] startAmountOut; //     per output: SELL auction start (best for maker); BUY fixed amount (== end)
    uint256[] endAmountOut; //       per output: SELL auction floor (worst for maker); BUY == start
    address exclusiveFiller; //      only this address may fill until exclusivityEndTime; 0 = open
    uint32 exclusivityEndTime; //    unix timestamp; ignored if exclusiveFiller == 0
    uint256 minFillAnchor; //        anti-dust floor per fill (anchor units); 0 = no minimum
    Item[] items;
    Validator[] validators; //       pre-execution trigger conditions; AND-composed
    Validator[] invariants; //       post-execution invariants; AND-composed
}
