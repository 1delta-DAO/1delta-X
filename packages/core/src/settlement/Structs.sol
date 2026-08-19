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
///                fallback for exchanges the typed `legsIn`/`legsOut` fast path
///                can't express; the typed legs stay inline (zero dispatch) and
///                SETTLE pays one CALL only when used. The maker's RECEIPT is
///                guaranteed by the order's mandatory `legsOut` delivery and/or
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
///                auction-priced output basket (each output leg decays
///                `legsOut[j].start → .end`, best-for-maker first). The
///                fill is denominated in `legsIn[0].start` units. The classic
///                "sell exactly X, take what the auction clears" order. An
///                input leg with `end != 0` RISES instead of being fixed —
///                the relayer-fee auction (see the {Order} docs).
///         BUY  — the maker receives a FIXED output basket and pays an
///                auction-priced input basket (each input leg rises
///                `legsIn[i].start → .end`, best-for-maker first). The
///                fill is denominated in `legsOut[0].start` units. The exact-output
///                "buy exactly X, pay up to Y" order.
enum OrderSide {
    SELL,
    BUY
}

/// @notice One INPUT leg (the maker gives, the solver receives). Consolidates the
///         old parallel `tokenIn`/`startAmountIn`/`endAmountIn` arrays into a struct
///         array, so token↔amount can never be length-mismatched.
/// @dev    `end == 0` ⇒ the leg is FIXED at `start` (no decay). Otherwise the leg
///         RISES `start → end` on the order's shared decay clock (`start ≤ end`) —
///         a BUY conversion input or a SELL relayer-fee leg. `end == 0` is the
///         "fixed" sentinel rather than `start == end`, so a fixed leg carries no
///         duplicated amount word.
struct LegIn {
    address token;
    uint256 start;
    uint256 end;
}

/// @notice One OUTPUT leg (the solver delivers, the recipient receives).
/// @dev    `end == 0` ⇒ FIXED at `start`; otherwise FALLS `start → end` (`end ≤
///         start`) — a SELL dutch-auction output. `recipient == address(0)` = the
///         maker; a non-zero recipient is a fee/originator leg (an output addressed
///         elsewhere). (A decay-to-zero output is intentionally not expressible —
///         `end == 0` means fixed, not "give it away".)
struct LegOut {
    address token;
    uint256 start;
    uint256 end;
    address recipient;
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
/// @dev    The conversion is multi-asset: the maker gives a basket of input legs
///         (`legsIn` — see {LegIn}) and receives a basket of output legs
///         (`legsOut` — see {LegOut}). One side is FIXED and the other decays as a
///         dutch auction; `side` selects which:
///           • SELL — inputs fixed, outputs decay; anchor = `legsIn[0].start`,
///                    fill amount is in `legsIn[0].token` units.
///           • BUY  — outputs fixed, inputs rise; anchor = `legsOut[0].start`,
///                    fill amount is in `legsOut[0].token` units.
///         Partial fills are driven by a SINGLE scalar fraction
///         `f = fillAmount / anchor`. Every leg (both baskets) and every item
///         slice scale by the same `f`, so the whole order fills proportionally
///         (the solver cannot size each leg independently).
///
///         Leg pricing is uniform: a leg with `end == 0` is FIXED at `start`; a
///         leg with `end != 0` is auctioned on the order's shared decay clock —
///         inputs RISE (`start ≤ end`), outputs FALL (`end ≤ start`). A rising
///         input leg is the relayer-fee auction for orders with no conversion
///         output to price a filler's compensation into (e.g. a pure gasless
///         deposit: `legsOut` may be EMPTY and the fee leg rises until filling
///         covers gas + margin). A fixed-price order (an exact OTC rate) simply
///         sets `end == 0` on every leg, both sides.
///
///         Every output leg names its own `recipient` (`address(0)` = the maker).
///         An originator/sourcing fee is one more output leg addressed to the
///         originator — decaying with the main leg for a bps-of-tick fee, or fixed
///         (`end == 0`) for an absolute fee.
struct Order {
    address maker;
    uint256 nonce;
    bytes legsIn; //        PACKED {LegIn} blob — see {PackedArrays}. anchor = leg 0
    bytes legsOut; //       PACKED {LegOut} blob — see {PackedArrays}
    uint256 timing; //      PACKED clocks and flags (see {DutchAuction} helpers):
    //                        bits [0:32)   decayStartTime      (unix, or BLOCK when bit 102 is set)
    //                        bits [32:64)  decayDuration       (seconds/blocks; 0 = no decay window)
    //                        bits [64:96)  exclusivityEndTime  (on the order's OWN clock —
    //                                       blocks under bit 102, else unix; ignored if exclusiveFiller == 0)
    //                        bits [96:100) item execution policy ({ItemPolicy})
    //                        bit  100      fill-once (nonce invalidator)
    //                        bit  101      side (0 = SELL, 1 = BUY)
    //                        bit  102      BLOCK clock — the two clocks above count BLOCKS
    //                        bit  103      PRIORITY auction — the bump is bid in priority fee
    //                        bit  104      DELTA-VERIFY outputs (see {DutchAuction.deltaVerifyOutputs})
    //                        bits [160:208) expiry (unix seconds; uint48, 0 = already expired).
    //                                       Folded in here so the order carries no separate
    //                                       `expiry` word — the 1inch `makerTraits` expiration
    //                                       trick. Always a WALL-CLOCK time, independent of the
    //                                       BLOCK clock above.
    address exclusiveFiller; //      only this address may fill until exclusivityEndTime; 0 = open
    uint256 minFillAnchor; //        anti-dust floor per fill (anchor units); 0 = no minimum
    uint256 params; //               PACKED auction scalars (see {DutchAuction} helpers):
    //                        bits [0:16)    exclusivityOverrideBps — 0 = hard exclusivity; else the
    //                                       bps a non-exclusive in-window filler must improve the
    //                                       maker's auction leg by
    //                        bits [16:32)   gasBumpBps — max extra decay the basefee bump adds; 0 = off
    //                        bits [32:96)   gasPriceRef — reference basefee (wei) at which the gas
    //                                       bump reaches gasBumpBps
    //                        bits [96:160)  priorityScale — wei of priority fee that buys a FULL
    //                                       bump under the PRIORITY auction (bit 103); 0 = off
    //                        bits [160:256) free
    bytes curve; //                  PACKED {CurvePoint} blob; optional piecewise decay
    //                               shape (shared clock); empty = linear
    bytes items; //                  PACKED {Item} record blob
    bytes validators; //             PACKED {Validator} records; pre-execution triggers,
    //                               AND-composed
    bytes invariants; //             PACKED {Validator} records; post-execution
    //                               invariants, AND-composed
    address fillModule; //           optional fill denominator/matcher; address(0) = identity
    //                               (the fill delta is the requested `fillAmount`, denominated in
    //                               the leg anchor — the classic fungible fill). When set, the module
    //                               validates the filler's proposal (carried in the shared takerData)
    //                               against this order and returns the accepted delta; the core keeps
    //                               the over-fill cap and the uniform per-leg scaling. See {IFillModule}.
    uint256 fillTotal; //            fill denominator when the unit isn't a fungible leg; 0 = derive
    //                               from the leg anchor (legsIn[0].start / legsOut[0].start). Maker-
    //                               signed so the cap `filled + delta <= fillTotal` stays in the core.
    address pricingModule; //        optional EXTERNAL price provider; address(0) = the built-in
    //                               clock. The module returns the shared decay bump, which the core
    //                               CLAMPS to [0, 10000] and then maps through each leg's own signed
    //                               `start`/`end`. So an oracle-pegged, range (fill-progress) or
    //                               cosigner-quoted price can move the tick anywhere INSIDE the band
    //                               the maker signed and nowhere outside it — unlike an amount getter,
    //                               which would BE the price.
    //
    //                               ⚠ NO PER-ORDER CONFIG BLOB, AND THAT IS A SIZE DECISION. A
    //                               `bytes pricing` carrying `{target, data}` measured **~1,000 bytes**
    //                               of Settlement (2026-08-12) — a SEVENTH dynamic member grows the
    //                               `Order` ABI decoder at EVERY external entry point, and the budget
    //                               against EIP-170 was 404. A module instead carries its config in
    //                               its own immutables (deploy one per configuration; identical
    //                               configs share a CREATE2 address), and reads everything
    //                               order-specific from the `Order` it is handed. See {IPriceModule}.
}

/// @notice Per-fill execution context — the resolved, in-memory state of ONE fill.
///         NOT a signed type: it is derived at fill time (never hashed) and passed
///         by memory pointer to the settlement helpers so each settle flow runs in
///         its own stack frame (keeps a fill under the EVM stack limit). Shared by
///         the settlement contracts and {Pricing} so the per-leg slice
///         math has a single home.
struct FillCtx {
    bytes32 orderHash;
    uint256 anchor; //       fill denominator (fixed-side leg 0, or signed fillTotal)
    uint256 prevFilled; //   cumulative filled before this fill
    uint256 newFilled; //    cumulative filled after this fill
    uint256 overrideBps; //  soft-exclusivity improvement (0 = none)
    address filler; //       who delivers / whose authority the fill runs under
    address payTo; //        where the filler's input-leg proceeds are sent. Defaults
    //                       to `filler` in `_openFill`; the aggregator entry
    //                       (`fillUpTo`) may redirect it. Payment destination ONLY —
    //                       exclusivity, validators, and output pulls all key on
    //                       `filler`, so this grants no new authority (it routes the
    //                       filler's own money, which the filler could forward anyway).
    bool fullFill; //        prevFilled == 0 && newFilled == anchor: the whole order in
    //                       one shot ⇒ every pro-rata slice is the leg's full amount,
    //                       skipping the mul/div.
    uint256 bump; //         the PINNED shared decay bump, plus one (0 = not pinned, resolve
    //                       lazily per decaying leg from the clock — the classic shape, and
    //                       what every order without a `pricingModule` or priority auction
    //                       uses). Both cold modes pin: a PRICE-MODULE order and a PRIORITY
    //                       auction are resolved ONCE per fill by {OrderState._openFill} (via
    //                       {DutchAuction.resolveBump}, where the filler and `takerData` are in
    //                       scope) and the clamped result pinned here. Pinning is what stops a
    //                       two-leg module order from paying the module's STATICCALL twice — and
    //                       per-leg lazy resolution stays the cheaper shape for everything else
    //                       (measured; see {Pricing}).
    /// @dev ABI-encoded `(IPermit3.PermitTake, bytes sig)` for a fill whose TAKE item
    ///      is funded by a ONE-SHOT maker permit instead of a standing taker
    ///      allowance. EMPTY on every ordinary fill — {Base._runItem} tests the length
    ///      and takes the classic `PERMIT3.take` path, so the hot path pays one
    ///      memory word and one length check. See {Core.fillWithPermitTake}.
    bytes permitTake;
    uint256[] receipts; //    per-`legsIn` amounts actually paid to `payTo`, recorded by
    //                       `_payInputsToSolver` as it pays them. `fillUpTo` returns
    //                       this instead of re-deriving it: a second {Pricing} pass
    //                       measured 795 gas for one fixed leg and 3,583 for a
    //                       two-leg order with a rising leg, where recording costs
    //                       ~40. Empty on the netted path, which reconciles inputs
    //                       against its own resolved `owed` ledger.
}

/// @notice The `matchSettle` call bundle — one calldata struct so the external ABI
///         decode stays under the stack limit without via-IR (seven dynamic params
///         would overflow it).
/// @dev    `orders`/`sigs`/`fillAmounts` are aligned 1:1; `takerDatas` is either
///         EMPTY (the no-blob form) or the same length. `schedule` is the only
///         solver-ordered part of the settlement — see {MatchStep} for the packing
///         and {Batch.matchSettle} for the phase model. `callTargets`/`callDatas`
///         are aligned 1:1 and selected by a `CALL` step, so a plan may run several
///         solver interactions at points of its choosing (or none).
struct MatchPlan {
    Order[] orders;
    bytes[] sigs;
    uint256[] fillAmounts;
    bytes[] takerDatas; //      per-order validator/invariant blob; empty = none
    uint256[] schedule; //      packed steps, executed verbatim (see {MatchStep})
    address[] callTargets; //   optional solver interactions, selected by CALL steps
    bytes[] callDatas;
    address profitRecipient; // where the final sweep lands; 0 = msg.sender
}

/// @notice The `matchSettle` step kinds, packed one per `schedule` word:
///
///           bits [ 0,  8)  kind — one of the constants below
///           bits [ 8, 24)  a    — order index (PULL/DELIVER/ITEM), token index
///                                 (PRESEND), or call index (CALL)
///           bits [24, 40)  b    — input-leg index (PULL) or item index (ITEM)
///
///         One word per step keeps the decode to two shifts and a mask — the
///         settler is bytecode-bound, and a denser packing would cost more code
///         than it saves in calldata.
///
///         PULL     — maker → pool for one input leg; credits what actually arrived.
///         DELIVER  — pool → recipients for every output leg of an order.
///         ITEM     — execute one MAKE/TAKE item; a TAKE's proceeds are credited to
///                    the order's input legs, measured around that single call.
///         PRESEND  — hand the solver a token's currently UNENCUMBERED surplus
///                    (pooled inflow minus obligations not yet delivered).
///         CALL     — one solver interaction through the allowance-less EXECUTOR.
/// @notice How much freedom a maker grants the solver over the ORDER in which their
///         `items` execute. Lives in `Order.timing` bits [96:100) — see
///         {DutchAuction.itemPolicy} for why there and not in a new field.
///
///         The single-order path (`fill`, `fillUpTo`, `batchFill`) always runs items
///         in signed index order, so it satisfies every policy by construction and
///         pays nothing for this. Only the schedule-driven {Batch.matchSettle}, where
///         a solver picks the order, can violate one.
///
///         ANY     — the solver may run items in any order, interleaved with any
///                   other step. The default, and what every order signed before this
///                   existed means. Required to participate in a CYCLE, where an
///                   order's borrow is deliberately hoisted ahead of its own delivery.
///         ORDERED — items must execute in signed index order. Other steps may still
///                   interleave. "My deposit happens before my borrow, but you may do
///                   other things in between."
///         ATOMIC  — items must execute in signed index order AND back-to-back, with
///                   no other step between them. This is what a lender that checks
///                   health inside each call needs: deposit and borrow are one
///                   indivisible move. (It constrains the items relative to EACH
///                   OTHER; where the group sits in the schedule, and where the
///                   delivery that funds it sits, stay the solver's choice.)
library ItemPolicy {
    uint256 internal constant ANY = 0;
    uint256 internal constant ORDERED = 1;
    uint256 internal constant ATOMIC = 2;

    /// @notice Pack a policy into a `timing` word. Off-chain builders mirror this.
    function pack(uint256 timing, uint256 policy) internal pure returns (uint256) {
        return (timing & ~(uint256(0xf) << 96)) | ((policy & 0xf) << 96);
    }
}

library MatchStep {
    uint256 internal constant PULL = 0;
    uint256 internal constant DELIVER = 1;
    uint256 internal constant ITEM = 2;
    uint256 internal constant PRESEND = 3;
    uint256 internal constant CALL = 4;

    /// @notice Pack one step. Off-chain builders should mirror this exactly.
    function pack(uint256 kind, uint256 a, uint256 b) internal pure returns (uint256) {
        return kind | (a << 8) | (b << 24);
    }
}
