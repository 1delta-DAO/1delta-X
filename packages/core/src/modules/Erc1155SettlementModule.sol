// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISettlementModule} from "../interfaces/ISettlementModule.sol";

/// @dev Minimal ERC-1155 surface this module needs.
interface IERC1155 {
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external;
}

/// @title Erc1155SettlementModule
/// @notice The ERC-1155 `SETTLE` module: delivers `slice` units of the maker's
///         token id to the FILLER — the quantity-based sibling of
///         {NftSettlementModule}. Because 1155 balances are DIVISIBLE, the item
///         composes with partial fills: `Item.amount` is the TOTAL quantity for a
///         fully-filled order and each fill transfers its exact pro-rata slice
///         (slices accumulate to `amount`, like every item). The maker is paid by
///         the order's mandatory `legsOut` leg(s), delivered BEFORE items — paid
///         first, or the whole fill reverts.
///
/// @dev    `data = abi.encode(collection, id)`. Gated by `msg.sender ==
///         settlement` (the maker's order signature is the authority) + the
///         maker's `setApprovalForAll(this)` on the collection. A dust fill whose
///         slice floors to 0 reverts in the core ({SettleSliceZero}) — a filler
///         can never pay and receive nothing. For all-or-nothing lots, sign
///         `minFillAnchor == anchor` exactly like the 721 sale.
contract Erc1155SettlementModule is ISettlementModule {
    address public immutable SETTLEMENT;

    error OnlySettlement();

    constructor(address settlement) {
        SETTLEMENT = settlement;
    }

    /// @inheritdoc ISettlementModule
    function settle(address maker, address filler, uint256 slice, bytes calldata data) external {
        if (msg.sender != SETTLEMENT) revert OnlySettlement();
        (address collection, uint256 id) = abi.decode(data, (address, uint256));
        IERC1155(collection).safeTransferFrom(maker, filler, id, slice, "");
    }
}
