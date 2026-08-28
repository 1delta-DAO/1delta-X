// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ITakerForModule
/// @notice A COMPOSITE adapter: one call that draws value out of a user's position
///         and funds the value-in side of the same position operation — "take
///         `amount`, FOR `forAmount`". Deposit + borrow, repay + withdraw, repay A
///         + borrow B, withdraw A + deposit B.
///
///  Why the pair belongs in one call
///  ────────────────────────────────
///  Most lenders check health INSIDE the value-out call (Aave, Comet, Morpho), and
///  the batch-native ones (Euler's `EVC.batch`, Fluid/Dolomite `operate`) run ONE
///  status check per batch. Expressed as two items — `MAKE` then `TAKE` — the
///  ordering is a SCHEDULING obligation the filler has to honour, and on the
///  batch-native venues the two legs pay two checks instead of one. Several
///  protocols cannot express the split at all: a Liquity-style `openTrove` needs
///  both amounts, and Fluid's `operate(nftId = 0, …)` mints the new position to
///  `msg.sender`, so a one-leg open strands the collateral in the module.
///
///  Why the second amount comes from the CORE, not from `data`
///  ──────────────────────────────────────────────────────────
///  The obvious shape — put the funding amount in `data` and let the module
///  pro-rate it — was tried and it has two defects. It DUPLICATES a number the
///  order usually already signs (a leverage order's collateral is `legsOut[j]`,
///  delivered to the maker moments earlier), so a mis-scaled copy silently
///  desyncs from the leg: too large pulls up to the maker's standing Permit3
///  token allowance, too small under-collateralises or reverts at fill time.
///  And a constant `data` amount does not pro-rate, so every partial fill
///  re-executes it in FULL — the defect {FullFillGuard} exists to reject.
///
///  So `forAmount` is computed by {Base._forSlice} from a DESCRIPTOR the maker
///  signs as the FIRST WORD of `data`:
///
///    • top bit SET  → LEG REFERENCE. The low 16 bits index `legsOut`, and
///      `forAmount` is that leg's priced amount for this fill ({Pricing.outputAt})
///      — the SAME call that decided what the solver just delivered, so the two
///      cannot disagree and the maker's net balance in that token over the fill is
///      zero. Nothing is duplicated: the amount, its token and its decimals live in
///      the typed leg the maker already signed, and a decaying leg carries its
///      auction price straight into the funding side, which a static ratio cannot do.
///    • top bit CLEAR → LITERAL TOTAL, for a funding leg with no matching output
///      (the maker funds it from their own wallet — a fresh Fluid position, a new
///      trove). The core slices it with the SAME differencing it applies to
///      `amount`, so N partial fills sum EXACTLY to the signed total: no ceil
///      drift, no over-pull.
///    • top TWO bits SET → BALANCE-RELATIVE, `min(balanceOf(token, maker), cap)`.
///      The token is the descriptor's low 160 bits, the cap is `data`'s SECOND
///      word and is MANDATORY. For the no-conversion shape where the maker cannot
///      know the amount at signing time — accrued interest, an in-flight transfer,
///      a wallet sweep. FULL-FILL ONLY: a live balance cannot pro-rate, so the core
///      rejects a sliced fill outright ({Base.ForBalanceNeedsFullFill}).
///
///  With the balance form the blob is `abi.encode(forDesc, cap, …)` — the cap is
///  field 1, so a module's own decode shifts by one word relative to the other two
///  forms.
///
///  `data` is passed through WHOLE, descriptor word included, so the taker
///  allowance `ref = keccak256(data)` still covers it and a filler cannot alter
///  which leg funds the op. Lay the blob out as
///  `abi.encode(uint256 forDesc, …)` and the descriptor is simply the first
///  field of an ordinary `abi.decode`.
///
///  Trust model
///  ───────────
///  Both legs stay bounded by something the maker signed, and by DIFFERENT books:
///    • the value-OUT leg by the Permit3 TAKER allowance
///      `(user, Settlement, module, keccak256(data))`, decremented by
///      {TakerAllowance.takeFor} before this function is entered;
///    • the value-IN leg by the maker's Permit3 TOKEN allowance to this module —
///      and, above that, by the signed leg or literal the descriptor names.
///
///  ⚠ ONE MODULE, ONE SHAPE. The taker book does NOT distinguish `take` from
///  `takeFor`: both consume the same `(user, spender, module, keccak256(data))`
///  bucket. A contract implementing BOTH {ITakerModule} and this interface would
///  therefore let a single `approveTaker` grant authorise either shape — the plain
///  take or the composite one with a funding leg attached. Settlement picks the
///  entrypoint from the maker-signed `op` byte, so a filler cannot switch it, but a
///  maker reading their grant cannot tell which they authorised. Implement one or
///  the other per contract, never both.
///
///  Modules MUST enforce `msg.sender == permit3` as their first statement, for
///  exactly the reason {ITakerModule} gives. `Permit3.takeFor` is `nonReentrant`
///  alongside `take`, so a module still cannot nest a second take: a composite op
///  spanning TWO protocols is two items, not one. `Permit3.transferFrom` is not
///  locked, which is how the funding leg is pulled.
interface ITakerForModule {
    /// @param onBehalfOf the order's maker — whose position is opened/closed.
    /// @param amount     this fill's slice of the value-OUT leg, already gated by
    ///                   the taker allowance.
    /// @param forAmount  the value-IN amount for this fill, computed by the core
    ///                   from the signed descriptor. MAY be zero on a dust slice
    ///                   whose funding leg floors out; a module whose protocol
    ///                   rejects a zero leg should revert rather than half-execute.
    /// @param receiver   where the value-out proceeds land — Settlement on the
    ///                   classic flow, so they fund the order's input legs.
    /// @param data       the maker-signed blob, descriptor word FIRST.
    function takeForOnBehalf(
        address onBehalfOf,
        uint256 amount,
        uint256 forAmount,
        address receiver,
        bytes calldata data
    ) external;
}
