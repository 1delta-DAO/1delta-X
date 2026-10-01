// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOrderValidator} from "@core/interfaces/IOrderValidator.sol";
import {Order} from "@core/settlement/Structs.sol";
import {InvariantReceiptGuard} from "@validators/InvariantReceiptGuard.sol";

/// @dev Minimal read surfaces.
interface IERC721OwnerOf {
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IERC1155BalanceOf {
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

/// @title Erc721OwnerInvariant
/// @notice Passes iff `collection.ownerOf(tokenId) == expectedOwner`. The missing
///         half of exotic settlement: attached as a post-execution INVARIANT it
///         turns "the maker holds NFT X when the fill ends" into a reverting
///         on-chain condition — the receiving side of an NFT *purchase* (maker
///         pays a fungible leg, the filler delivers the NFT in its callback) and
///         the counter-leg of an NFT-for-NFT swap (maker's NFT leaves via a SETTLE
///         item, the incoming one is checked here).
///
///         ⚠ IT PROVES AN END STATE, NOT A DELIVERY (audit 2026-09-30 VAL-1).
///         `ownerOf == maker` is equally true when the maker got the NFT some other
///         way — a second bid, a marketplace offer the filler accepts inside its
///         callback, a purchase at the ask. So when this is the order's ONLY
///         receipt (`legsOut` empty) the fill must come from the order's named
///         `exclusiveFiller` ({InvariantReceiptGuard}; reverts
///         {InvariantReceiptGuard.ReceiptNeedsNamedFiller} otherwise), and a maker
///         with alternative offers for the same asset should share one fill-once
///         nonce across them (or cancel the stale one).
///
///         Also usable as a pre-execution VALIDATOR ("only fill while the maker
///         still owns X" — e.g. gating a collection-collateral order).
///
/// @dev    `data = abi.encode(collection, tokenId, expectedOwner)`. Stateless and
///         ownerless; everything is maker-signed. An `ownerOf` revert (burned /
///         nonexistent id) propagates and aborts the fill — the conservative
///         direction. `takerData` is ignored.
contract Erc721OwnerInvariant is IOrderValidator {
    function validate(Order calldata order, address filler, bytes calldata data, bytes calldata)
        external
        view
        override
        returns (bool)
    {
        InvariantReceiptGuard.enforce(order, filler);
        (address collection, uint256 tokenId, address expectedOwner) = abi.decode(data, (address, uint256, address));
        return IERC721OwnerOf(collection).ownerOf(tokenId) == expectedOwner;
    }
}

/// @title Erc1155BalanceInvariant
/// @notice Passes iff `token.balanceOf(account, id) >= minBalance` — the ERC-1155
///         sibling of {MinBalanceInvariant}: an absolute post-fill floor proving
///         a quantity of id `id` arrived at `account` (a 1155 purchase, or the
///         receiving side of a 1155 swap).
///
/// @dev    `data = abi.encode(token, account, id, minBalance)`. ABSOLUTE floor —
///         signing it requires knowing the account's expected post-fill balance;
///         if the account transacts the id meanwhile, re-sign (same caveat as
///         {MinBalanceInvariant}). `takerData` is ignored.
///
///         ⚠ An END STATE, not a delivery: as the sole receipt (`legsOut` empty) the
///         fill must come from the named `exclusiveFiller` — see
///         {Erc721OwnerInvariant} and {InvariantReceiptGuard} (audit 2026-09-30 VAL-1).
contract Erc1155BalanceInvariant is IOrderValidator {
    function validate(Order calldata order, address filler, bytes calldata data, bytes calldata)
        external
        view
        override
        returns (bool)
    {
        InvariantReceiptGuard.enforce(order, filler);
        (address token, address account, uint256 id, uint256 minBalance) =
            abi.decode(data, (address, address, uint256, uint256));
        return IERC1155BalanceOf(token).balanceOf(account, id) >= minBalance;
    }
}
