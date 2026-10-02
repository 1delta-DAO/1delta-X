// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ISettlementModule
/// @notice A generic settler for the solver↔maker exchange — the `SETTLE` item
///         op. It is the pluggable *fallback* for exchanges the typed
///         `tokenIn`/`tokenOut` fast path can't express (an NFT sale/swap, a
///         cross-type trade). The fungible legs stay inline on the settlement
///         (zero dispatch overhead); a `SETTLE` item pays one CALL only when the
///         exchange is non-standard.
///
///  What makes it distinct from a MAKE/TAKE (maker-side) module: `settle`
///  receives the `filler`, so the maker's asset can be routed to WHOEVER fills —
///  the piece that lets an NFT be sold to an open solver set without pinning an
///  exclusive filler at signing time.
///
///  Trust model (mirrors {IMakerModule}): bind `msg.sender == settlement` so the
///  maker's order signature is the sole authority over `(module, amount, data)`,
///  and cap what the module can move by the maker's own approval to it (e.g. an
///  ERC-721 `setApprovalForAll`).
///
///  ⚠ A SETTLE MODULE MUST NEVER PULL FROM THE FILLER (audit 2026-09-30 X-SPEC-1;
///  the rule SECURITY.md states). `filler` is passed so the module can route the
///  MAKER's asset TO whoever fills — never as a `from`. A shared module that pulled
///  from the filler under the filler's standing approval (say `setApprovalForAll`
///  for one purchase) would let any maker sign an order naming that module and an
///  arbitrary `tokenId` the filler owns, and take it. This used to read "the
///  filler's assets are reachable only via the filler's OWN approval to the
///  module", which invited exactly that design. A PURCHASE (filler's asset → maker)
///  belongs on the fungible legs plus a maker-side ownership invariant, with the
///  filler delivering the asset itself in its own callback.
///
///  The maker's RECEIPT of value is NOT this module's job to guarantee —
///  it is enforced by the order's mandatory `tokenOut` delivery (an NFT *sale*,
///  where the maker is paid via an inline fungible leg) and/or a post-execution
///  invariant (an NFT *purchase*, where the maker's receipt is non-fungible).
///  ⚠ An invariant proves an END STATE, not DELIVERY (audit 2026-09-30 VAL-1): if
///  the maker obtains the asset any other way, any filler can collect the payment
///  without delivering. An order whose only consideration is an invariant (no
///  `legsOut`, or SETTLE items only) therefore REQUIRES a single named hard
///  `exclusiveFiller` for its whole life. With no `legsOut` the CORE enforces it for
///  every invariant, third-party ones included (`Base._runInvariants` reverts
///  `NotExclusiveFiller` for any other filler, items or not); the shipped
///  invariants also enforce it themselves (`InvariantReceiptGuard`), and the lens /
///  SDK refuse the shape. A SETTLE hand-over beside an output leg is advisory only.
///
///  ⚠ SOLVER CAVEAT (read before filling a SETTLE order): unlike a MAKE/TAKE
///  item — where the filler's receipt is always a real Permit3-gated token move —
///  a SETTLE module's behavior is arbitrary maker-signed code, and there is NO
///  on-chain guarantee the FILLER receives anything (order `invariants` are
///  maker-signed; a filler cannot attach one). A maker could sign an "NFT sale"
///  whose module is a no-op or a hostile `collection`, take the `tokenOut`
///  payment, and deliver nothing. Orders are open (no filler whitelist, no module
///  registry), so solvers MUST protect themselves, with BOTH of (audit 2026-09-30
///  VAL-1.v3 — this used to say "and/or", which made the second alone look
///  sufficient):
///    1. VETTING, mandatory: the immutable maker-signed `(module, collection,
///       tokenId)` triple. A post-state check is only as good as the collection it
///       reads — a hostile `collection` answers any `ownerOf` / `balanceOf`.
///    2. A TRANSITION check bound to THIS fill, never an absolute end state: record
///       `ownerOf(id) != self` (ERC-721) or `balanceOf(self, id)` (ERC-1155)
///       immediately before the Settlement call and require `ownerOf(id) == self`
///       / a balance increase `>= slice` immediately after. An absolute
///       `ownerOf(id) == self` is satisfied by inventory the solver already held or
///       by an earlier fill in the same transaction. Check PER ORDER: `batchFill`
///       runs every order in one call, so wrap single fills or dedupe
///       `(collection, id)` and assert the summed increase.
///  Same-block simulation is INSUFFICIENT — a maker-controlled `collection` can
///  diverge sim vs. execution.
interface ISettlementModule {
    /// @param maker  the order maker (whose asset the module is authorized over)
    /// @param filler the address executing this fill (msg.sender of the fill)
    /// @param amount this fill's pro-rata slice of the item amount
    /// @param data   the maker-signed module payload (e.g. abi.encode(collection, tokenId))
    function settle(address maker, address filler, uint256 amount, bytes calldata data) external;
}
