// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IFundingSource
/// @notice The PREFLIGHT half of a composite ({ITakerForModule}) adapter: WHAT its
///         funding leg will draw from the maker, and HOW MUCH of it the module can
///         draw right now. Read-only, never called during a fill — {SettlementLens}
///         calls it so a maker learns at BUILD time what they would otherwise learn
///         from a reverting fill.
///
///  Separate from {ITakerForModule} on purpose, and the reason is bytecode rather
///  than taste. `ITakerForModule` is imported by {TakerAllowance}, so it rides into
///  `Settlement`'s compilation unit — where declaring this function measured **+7
///  bytes** of a contract that has single digits of EIP-170 headroom left. Nothing
///  the settler compiles imports THIS file. A composite module implements both.
///
///  It answers two questions the core structurally cannot.
///
///  1. WHICH ASSET. `TAKE_FOR` de-duplicates the funding AMOUNT — the leg-reference
///     descriptor makes `legsOut[j]` the single signed copy of it — but the funding
///     ASSET is still named inside `data`, in a layout only the module knows (an
///     Aave `collateralAsset` field, a Dolomite `collToken`, an Euler vault the
///     asset is derived FROM). Nothing cross-checks it against the leg, so a blob
///     naming a different asset than the leg it is sized by applies that amount in
///     the WRONG DECIMALS — the same silent mis-sizing the op exists to remove,
///     returning through the one door the descriptor left open. Reporting `asset`
///     lets {SettlementLens.validateOrder} close it: for the leg-reference form it
///     requires `asset == legsOut[j].token`.
///
///  2. WHETHER IT IS AUTHORISED. The funding leg is a pull the MODULE makes against
///     the maker's grant to the MODULE — a different book, a different spender, and
///     in the wallet-funded shapes a token that need not appear in `legsIn` at all.
///     Neither the order preflight nor {IPermit3.takerAllowance} sees it, so an
///     order can preflight perfectly and then revert on every fill for want of one
///     approval. {SettlementLens.previewItemFunding} reports it.
interface IFundingSource {
    /// @dev ⚠ `asset` IS NOT NECESSARILY AN ERC-20. It is whatever this module draws
    ///      from — an ERC-20 in every adapter shipped today, but an adapter that
    ///      funds a position with an NFT (a concentrated-liquidity position posted as
    ///      collateral, a vault receipt, a trove) reports the ERC-721 and an
    ///      `available` of 0 or 1. The lens compares `asset` for IDENTITY and treats
    ///      `available` as a MAGNITUDE, and assumes nothing else about either, so no
    ///      module has to be forced into ERC-20 shape to answer. Report the
    ///      authorisation THIS module's funding path actually consults — a Permit3
    ///      token allowance, an ERC-721 `getApproved` / `isApprovedForAll`, or an
    ///      inventory the module holds itself.
    ///
    ///      MUST NOT REVERT on a well-formed `data`, and SHOULD NOT on a malformed
    ///      one: the lens tolerates a failed staticcall by reporting "unknown" and
    ///      skipping both checks, so a reverting implementation degrades to the gap
    ///      this interface exists to close rather than to a loud error.
    ///
    /// @param onBehalfOf the maker whose grant is being read.
    /// @param data       the item's maker-signed blob, descriptor word included —
    ///                   byte-identical to what `takeForOnBehalf` receives.
    /// @return asset     the contract the funding leg draws from, or `address(0)` for
    ///                   a module that pulls nothing external (self-funded, or a
    ///                   `data` shape with no funding leg). `address(0)` disables BOTH
    ///                   lens checks — it is the honest answer for such a module, not
    ///                   a way to opt out of one.
    /// @return available how much of `asset` this module could draw from `onBehalfOf`
    ///                   at this block, through its own funding path. `0` means "not
    ///                   authorised", and is what the lens reports as the reason a
    ///                   fill would fail.
    function fundingSource(address onBehalfOf, bytes calldata data)
        external
        view
        returns (address asset, uint256 available);
}
