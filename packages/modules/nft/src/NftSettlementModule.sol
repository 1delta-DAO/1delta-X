// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISettlementModule} from "@core/interfaces/ISettlementModule.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";

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
/// @dev    `data = abi.encode(collection, tokenId, total)` — collection at byte 0, tokenId at 32,
///         total at 64 — where `total` is the
///         item's signed `amount`. Gated by `msg.sender == settlement` (so the
///         maker's order signature is the authority) + the maker's
///         `setApprovalForAll(this)` on the collection (which caps it to the
///         maker's own NFTs).
///
///         ⚠ FULL-FILL ONLY, ENFORCED ON-CHAIN (audit 2026-09-30 MISC-MOD-2,
///         BREAKING). An ERC-721 is indivisible, but the settlement pro-rates the
///         item `amount` into per-fill slices. The module used to ignore the slice
///         and lean on the core's {SettleSliceZero} — which only fires when the
///         slice floors to ZERO, i.e. only for the sentinel `amount = 1`. A sale
///         signed with `amount > 1` (e.g. the common `amount == anchor`
///         convention) on a partially fillable order handed the NFT over on a
///         one-unit fill, and the lens cannot tell a 721 module from an 1155 one,
///         so `validateOrder` passed it. The slice must now equal the signed
///         `total` ({FullFillGuard.requireFullFill}); a two-word blob reverts
///         `PartialFillUnsupported(slice, 0)`. Any `amount` works, so long as
///         `total` repeats it — and the order then settles in exactly one fill.
contract NftSettlementModule is ISettlementModule {
    address public immutable SETTLEMENT;

    error OnlySettlement();

    constructor(address settlement) {
        SETTLEMENT = settlement;
    }

    /// @inheritdoc ISettlementModule
    function settle(address maker, address filler, uint256 slice, bytes calldata data) external {
        if (msg.sender != SETTLEMENT) revert OnlySettlement();
        // The token moves whole, so the fill must be whole too.
        FullFillGuard.requireFullFillFromData(data, 64, slice);
        (address collection, uint256 tokenId) = abi.decode(data[0:64], (address, uint256));
        IERC721(collection).safeTransferFrom(maker, filler, tokenId);
    }
}
