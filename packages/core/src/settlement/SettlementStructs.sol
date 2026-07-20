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
///         SETTLE — generic solver↔maker exchange: Settlement calls
///                `module.settle(maker, filler, amount, data)`. Unlike MAKE/TAKE
///                (which only touch the maker's own assets/positions), SETTLE is
///                FILLER-AWARE — the module receives `ctx.filler`, so the maker's
///                asset can be routed to whoever fills (e.g. an NFT sale to an
///                open solver set, with no exclusivity). This is the generic
///                fallback for exchanges the typed `tokenIn`/`tokenOut` fast path
///                can't express; the typed legs stay inline (zero dispatch) and
///                SETTLE pays one CALL only when used. The maker's RECEIPT is
///                guaranteed by the order's mandatory `tokenOut` delivery and/or
///                a post-execution invariant. See {ISettlementModule}.
enum ItemOp {
    MAKE,
    TAKE,
    SETTLE
}

/// @notice Where the solver callback runs relative to settlement, chosen by the
///         filler in `fillWithCallback` (single-order path).
enum CallbackMode {
    PreDelivery, // callback → deliver outputs → items → pay inputs (works for any order)
    PostInputs // pay inputs → callback → deliver outputs (item-free only; JIT-from-proceeds)
}

/// @notice Which leg of the order is the auction (variable) side and which is
///         the fixed anchor that the fill amount is denominated in.
///
///         SELL — the maker gives a FIXED input basket and receives an
///                auction-priced output basket (outputs decay
///                `startAmountOut → endAmountOut`, best-for-maker first). The
///                fill is denominated in `tokenIn[0]` units. The classic
///                "sell exactly X, take what the auction clears" order. An
///                input leg with `start != end` RISES instead of being fixed —
///                the relayer-fee auction (see the {Order} docs).
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

/// @notice One point on a piecewise-linear auction curve. `timeDelta` is seconds
///         after the order's `decayStartTime`; `bumpBps` is the normalized decay
///         at that instant — 0 = the `start` price (best for maker), 10000 = the
///         `end` price (worst). The current bump is linearly interpolated between
///         adjacent points and clamped outside the range. The whole curve is
///         shared by every leg (one clock); each leg maps it through its own
///         `start`/`end` bounds. An empty curve means the classic single linear
///         segment over `decayDuration`.
struct CurvePoint {
    uint32 timeDelta;
    uint32 bumpBps;
}

/// @notice A read-only trigger. Settlement `staticcall`s
///         `target.validate(order, filler, data)` — `filler` being the address
///         executing the fill — and aborts the fill unless the returned bool is
///         `true`. Multiple validators on an order are AND-composed. Both
///         `target` and `data` are in the EIP-712 typehash → solver cannot alter.
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
///
///         Leg pricing is uniform and flag-free: a leg with `start == end` is
///         FIXED; a leg with `start != end` is auctioned on the order's shared
///         decay clock. Inputs may only RISE (`start ≤ end`), outputs may only
///         FALL (`start ≥ end`). A rising SELL input leg is the relayer-fee
///         auction for orders with no conversion output to price a filler's
///         compensation into (e.g. a pure gasless deposit: `tokenOut` may be
///         EMPTY and the fee leg rises until filling covers gas + margin).
///
///         Every output leg names its own `recipientOut` (`address(0)` = the
///         maker). An originator/sourcing fee is simply one more output leg
///         addressed to the originator — decaying proportionally with the main
///         leg for a bps-of-tick fee, or fixed for an absolute fee.
struct Order {
    address maker;
    OrderSide side; //      SELL (outputs decay) or BUY (inputs rise)
    uint256 nonce;
    uint256 deadline;
    address[] tokenIn; //   maker gives (solver receives)
    uint256[] startAmountIn; //      per input: fixed amount when == end; else the auction floor
    //                               (best for maker) of a RISING leg — BUY conversion inputs or a
    //                               SELL relayer-fee leg
    uint256[] endAmountIn; //        per input: == start (fixed) or the auction ceiling (worst for
    //                               maker / "pay up to"); must be ≥ start — inputs only rise
    uint32 decayStartTime;
    uint32 decayDuration;
    address[] tokenOut; //  the solver delivers (to recipientOut, default = maker)
    uint256[] startAmountOut; //     per output: SELL auction start (best for maker); BUY fixed amount (== end)
    uint256[] endAmountOut; //       per output: SELL auction floor (worst for maker); BUY == start
    address[] recipientOut; //       per output: delivery recipient; address(0) = the maker. A fee
    //                               leg is an output addressed to the originator (proportional
    //                               start/end = bps-of-tick fee; start == end = absolute fee)
    address exclusiveFiller; //      only this address may fill until exclusivityEndTime; 0 = open
    uint32 exclusivityEndTime; //    unix timestamp; ignored if exclusiveFiller == 0
    uint256 minFillAnchor; //        anti-dust floor per fill (anchor units); 0 = no minimum
    uint256 exclusivityOverrideBps; //  0 = hard exclusivity; else the bps a non-exclusive
    //                                  in-window filler must improve the maker's auction leg by
    CurvePoint[] curve; //           optional piecewise decay shape (shared clock); empty = linear
    uint256 gasBumpBps; //           max extra decay (bps) the gas bump adds at/above gasPriceRef; 0 = off
    uint256 gasPriceRef; //          reference basefee (wei) at which the gas bump reaches gasBumpBps
    Item[] items;
    Validator[] validators; //       pre-execution trigger conditions; AND-composed
    Validator[] invariants; //       post-execution invariants; AND-composed
    address fillModule; //           optional fill denominator/matcher; address(0) = identity
    //                               (the fill delta is the requested `fillAmount`, denominated in
    //                               the leg anchor — the classic fungible fill). When set, the module
    //                               validates the filler's proposal (carried in the shared takerData)
    //                               against this order and returns the accepted delta; the core keeps
    //                               the over-fill cap and the uniform per-leg scaling. See {IFillModule}.
    uint256 fillTotal; //            fill denominator when the unit isn't a fungible leg; 0 = derive
    //                               from the leg anchor (startAmountIn[0]/startAmountOut[0]). Maker-
    //                               signed so the cap `filled + delta <= fillTotal` stays in the core.
}

/// @notice Per-fill execution context — the resolved, in-memory state of ONE fill.
///         NOT a signed type: it is derived at fill time (never hashed) and passed
///         by memory pointer to the settlement helpers so each settle flow runs in
///         its own stack frame (keeps a fill under the EVM stack limit). Shared by
///         the settlement contracts and {SettlementPricing} so the per-leg slice
///         math has a single home.
struct FillCtx {
    bytes32 orderHash;
    uint256 anchor; //       fill denominator (fixed-side leg 0, or signed fillTotal)
    uint256 prevFilled; //   cumulative filled before this fill
    uint256 newFilled; //    cumulative filled after this fill
    uint256 overrideBps; //  soft-exclusivity improvement (0 = none)
    address filler; //       who is paid / delivers
    bool fullFill; //        prevFilled == 0 && newFilled == anchor: the whole order in
    //                       one shot ⇒ every pro-rata slice is the leg's full amount,
    //                       skipping the mul/div.
}

/// @notice The `batchSettleItems` call bundle — one calldata struct so the external
///         ABI decode stays under the stack limit without via-IR (seven dynamic
///         params would overflow it). Arrays are aligned 1:1 with `orders`.
struct ItemsBatch {
    Order[] orders;
    bytes[] sigs;
    uint256[] fillAmounts;
    uint256[] pullMask; //          bit j of [i] ⇒ pull order i's input leg j up front
    uint256[] sequence; //          execution order (a permutation of [0, n))
    address interactionTarget; //   optional (0 = skip) solver seed call
    bytes interactionData;
}
