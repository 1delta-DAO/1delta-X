// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISettlementModule} from "../interfaces/ISettlementModule.sol";

/// @dev Minimal ERC-721 surface this module needs.
interface IERC721 {
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

/// @title NftSettlementModule
/// @notice The canonical `SETTLE` module: delivers the maker's ERC-721 to the
///         FILLER — an NFT *sale* to an open solver set, no exclusive filler.
///         The maker is paid on the same order via an inline `legsOut`
///         (fungible) leg, whose delivery is mandatory and runs BEFORE items, so
///         the maker is paid first or the whole fill reverts; only then does this
///         module hand the NFT to whoever filled.
///
///         This replaces the item + solver-callback + ownership-invariant stitch
///         the NFT sale previously required, and removes the exclusivity
///         constraint (the maker no longer has to sign the solver's address as
///         the recipient).
///
/// @dev    `data = abi.encode(collection, tokenId)`. Gated by
///         `msg.sender == settlement` (so the maker's order signature is the
///         authority) + the maker's `setApprovalForAll(this)` on the collection
///         (which caps it to the maker's own NFTs).
///
///         `amount` is ignored HERE (an ERC-721 is indivisible), BUT it is NOT
///         inert at the order level: the settlement computes the item slice as
///         `amount · newFilled/anchor − …` and skips the item when the slice
///         floors to 0. So the item's `amount` must be a NON-ZERO sentinel (use
///         `1`) — a zero `amount` skips the NFT transfer while the maker is still
///         paid. And the order MUST be full-fill (`minFillAnchor == anchor`, or a
///         `FullFillModule`): a partial fill floors the slice to 0, so a first
///         filler would pay pro-rata and receive nothing. `validateOrder`
///         enforces both (`"settle item requires full-fill"`).
contract NftSettlementModule is ISettlementModule {
    address public immutable SETTLEMENT;

    error OnlySettlement();

    constructor(address settlement) {
        SETTLEMENT = settlement;
    }

    /// @inheritdoc ISettlementModule
    function settle(address maker, address filler, uint256, bytes calldata data) external {
        if (msg.sender != SETTLEMENT) revert OnlySettlement();
        (address collection, uint256 tokenId) = abi.decode(data, (address, uint256));
        IERC721(collection).safeTransferFrom(maker, filler, tokenId);
    }
}
