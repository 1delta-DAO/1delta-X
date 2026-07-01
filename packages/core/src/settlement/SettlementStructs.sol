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

/// @notice A signed limit order.
/// @dev    The conversion leg is multi-asset: the maker gives a basket
///         (`tokenIn[]`/`amountIn[]`) and receives a basket
///         (`tokenOut[]`/`startAmountOut[]`/`endAmountOut[]`). Partial fills are
///         driven by a SINGLE scalar fraction `f = fillAmountIn / amountIn[0]`;
///         `amountIn[0]` is the fill denominator and `fillAmountIn` is expressed
///         in `tokenIn[0]` units. Every other input, every output, and every
///         item slice scale by the same `f`, so the whole basket fills
///         proportionally (the solver cannot size each leg independently).
struct Order {
    address maker;
    uint256 nonce;
    uint256 deadline;
    address[] tokenIn; //   maker gives (solver receives); tokenIn[0] anchors the fill
    uint256[] amountIn; //  amountIn[0] is the fill denominator
    uint32 decayStartTime;
    uint32 decayDuration;
    address[] tokenOut; //  maker receives (solver gives)
    uint256[] startAmountOut; //     per output: best for maker (auction start / fixed price)
    uint256[] endAmountOut; //       per output: worst for maker (auction end floor)
    address exclusiveFiller; //      only this address may fill until exclusivityEndTime; 0 = open
    uint32 exclusivityEndTime; //    unix timestamp; ignored if exclusiveFiller == 0
    uint256 minFillAmountIn; //      anti-dust floor per fill (tokenIn[0] units); 0 = no minimum
    Item[] items;
    Validator[] validators; //       pre-execution trigger conditions; AND-composed
    Validator[] invariants; //       post-execution invariants; AND-composed
}
