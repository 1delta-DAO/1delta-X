// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Market} from "./IMidnight.sol";

// ──────────────────── Morpho Midnight order-fill callbacks ────────────────────
//
// Mirrors `morpho-org/midnight` `src/interfaces/ICallbacks.sol`. When an `Offer`
// is filled, Midnight invokes a callback on BOTH sides of the fill — resolved as:
//
//   buyerCallback  = offer.buy ? offer.callback : takerCallback
//   sellerCallback = offer.buy ? takerCallback  : offer.callback
//
// i.e. the MAKER's `offer.callback` is the buy-callback on a `buy == true` offer
// and the sell-callback on a `buy == false` offer; the TAKER supplies the other
// side via `take`'s `takerCallback`. Each hook, when non-zero, MUST return
// `keccak256("morpho.midnight.callbackSuccess")`. Crucially, Midnight fires these
// AFTER moving the assets but BEFORE the borrower solvency check
// (`isHealthy`) — so a seller (borrower) callback can turn freshly borrowed
// proceeds into collateral that makes the new debt healthy in the same fill.

/// @notice Buy-side (lender) fill callback.
interface IBuyCallback {
    function onBuy(
        bytes32 id,
        Market memory market,
        uint256 buyerAssets,
        uint256 units,
        uint256 pendingFeeIncrease,
        address buyer,
        bytes memory data
    ) external returns (bytes32);
}

/// @notice Sell-side (borrower) fill callback. `sellerAssets` (the borrowed loan
///         token) has already been sent to `receiver` when this runs.
interface ISellCallback {
    function onSell(
        bytes32 id,
        Market memory market,
        uint256 sellerAssets,
        uint256 units,
        uint256 pendingFeeDecrease,
        address seller,
        address receiver,
        bytes memory data
    ) external returns (bytes32);
}
