// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IProceedsAsset
/// @notice The value-OUT half of an item's asset declaration: WHICH token a `TAKE`
///         (or `TAKE_FOR`) delivers. The sibling of {IFundingSource}, which declares
///         the value-IN side. Read-only; {SettlementLens} calls it, `Settlement`
///         never does.
///
///  WHY IT EXISTS — the failure it prevents costs the maker twice, silently, with no
///  attacker involved.
///
///  A `TAKE` item's proceeds are credited by MEASUREMENT, not by declaration:
///  {Core._payInputsToSolver} reads the balance delta of `legsIn[i].token` across the
///  item run. The token the module actually delivers is named only inside `data`, in
///  a per-module layout the core deliberately never decodes, and nothing cross-checks
///  it against any leg. Point it at token X while every input leg is token Y and:
///
///    • every leg measures `proceeds = 0`, so the FULL `owed` is pulled from the
///      maker's own wallet — they pay the input leg out of pocket;
///    • token X matches no leg, is credited to nobody, and the single-order `fill`
///      path HAS NO SWEEP. It does not go to the filler; it simply stays in the
///      settler forever. Nothing can retrieve it: `Settlement` grants no ERC-20
///      approval to anyone, which is the same invariant that makes the proceeds
///      measurement sound in the first place.
///
///  So the maker loses the withdrawn or borrowed asset AND pays the leg anyway. That
///  is a maker-signed misconfiguration, exactly the class {ITakerForModule} was built
///  to make unrepresentable on the funding side — and until this interface it had no
///  preflight on the proceeds side. See `docs/reference-audits.md` §F22 and §C15.
///
///  THE RULE THE LENS ENFORCES, and why it is exactly this and not stricter:
///  proceeds routed to the settler (`item.recipient == 0`) MUST be a token some input
///  leg can consume. It holds because a token sitting in the settler can only ever
///  leave through an input leg. It is "SOME leg", never leg 0 — a rising relayer-fee
///  leg in a different token is legitimate. And it does not apply when
///  `item.recipient != 0`: those proceeds are deliberately routed elsewhere (to the
///  maker, or chained into a later item), so the settler never holds them.
interface IProceedsAsset {
    /// @dev MUST NOT REVERT on a well-formed `data`. A module that does not implement
    ///      this, or reverts, reports "unknown" to the lens and the check is SKIPPED —
    ///      never failed. It is an addition to a preflight that shipped without it, so
    ///      silence has to leave the caller where it was rather than reject an order
    ///      that fills perfectly well.
    ///
    ///      Takes no `onBehalfOf`: unlike {IFundingSource.fundingSource} this is a
    ///      pure property of the signed blob, with no live authorisation to read.
    ///
    /// @param data   the item's maker-signed blob, byte-identical to what
    ///               `takeOnBehalf` / `takeForOnBehalf` receives.
    /// @return asset the token this item delivers, or `address(0)` for a module whose
    ///               output is not a single fungible token (an NFT settle, a
    ///               multi-asset unwind). `address(0)` disables the check — the honest
    ///               answer for such a module, not a way to opt out of it.
    function proceedsAsset(bytes calldata data) external view returns (address asset);
}
