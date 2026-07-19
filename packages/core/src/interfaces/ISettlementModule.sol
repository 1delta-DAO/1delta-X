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
///  ERC-721 `setApprovalForAll`). The `filler`'s assets are reachable only via
///  the filler's OWN approval to the module, which the filler grants by choosing
///  to fill. The maker's RECEIPT of value is NOT this module's job to guarantee —
///  it is enforced by the order's mandatory `tokenOut` delivery (an NFT *sale*,
///  where the maker is paid via an inline fungible leg) and/or a post-execution
///  invariant (an NFT *purchase*, where the maker's receipt is non-fungible).
///
///  ⚠ SOLVER CAVEAT (read before filling a SETTLE order): unlike a MAKE/TAKE
///  item — where the filler's receipt is always a real Permit3-gated token move —
///  a SETTLE module's behavior is arbitrary maker-signed code, and there is NO
///  on-chain guarantee the FILLER receives anything (order `invariants` are
///  maker-signed; a filler cannot attach one). A maker could sign an "NFT sale"
///  whose module is a no-op or a hostile `collection`, take the `tokenOut`
///  payment, and deliver nothing. Orders are open (no filler whitelist, no module
///  registry), so solvers MUST protect themselves: vet the immutable maker-signed
///  `(module, collection, tokenId)` triple, and/or wrap the fill in a contract
///  that asserts the expected post-state (e.g. `ownerOf(tokenId) == self`).
///  Same-block simulation is INSUFFICIENT — a maker-controlled `collection` can
///  diverge sim vs. execution.
interface ISettlementModule {
    /// @param maker  the order maker (whose asset the module is authorized over)
    /// @param filler the address executing this fill (msg.sender of the fill)
    /// @param amount this fill's pro-rata slice of the item amount
    /// @param data   the maker-signed module payload (e.g. abi.encode(collection, tokenId))
    function settle(address maker, address filler, uint256 amount, bytes calldata data) external;
}
