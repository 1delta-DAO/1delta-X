// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IFillModule} from "@core/interfaces/IFillModule.sol";
import {IFillModuleDescribe} from "@core/interfaces/IFillModuleDescribe.sol";
import {IPositionSource} from "@core/interfaces/IPositionSource.sol";
import {DutchAuction} from "@core/settlement/DutchAuction.sol";
import {PackedArrays} from "@core/settlement/PackedArrays.sol";
import {Order, OrderSide} from "@core/settlement/Structs.sol";

// ════════════════════════════════════════════════════════════════════════════
//  PositionFillModule — size the fill from the maker's LIVE lending position, so
//  the accrued interest is SOLD instead of handed back as dust.
//
//  ONE deployment serves every venue. It holds no venue knowledge and takes no
//  constructor arguments: it reads item 0 out of the maker-signed order, asks
//  THAT module what the position is ({IPositionSource}), and returns it as the
//  fill delta. The module it asks IS the module that will execute the item, so
//  the pairing is structural — there is no address to configure and therefore
//  none to configure wrongly.
//
//  The problem
//  ───────────
//  A maker signing "exit my Aave WETH position" cannot know the amount: it
//  accrues between signing and inclusion. {DustHandler.BalanceMode.Full} closes
//  that gap at the module — read the live position, forward the signed `amount`,
//  pay the remainder back — but the remainder arrives as the RAW UNDERLYING in
//  the maker's wallet: unconverted, at dust size, in exactly the token they signed
//  an order to get rid of.
//
//  {Proportional} is the core's balance-relative encoding and is the wrong shape
//  here twice over. It resolves `balanceOf(legToken, maker)` in
//  {OrderGates.anchorTotal} BEFORE any funds move — pre-withdraw the maker holds
//  none of the underlying — and its output is anchor-invariant at full fill
//  (`ceil(anchor · start / anchor) == start`), so a larger balance is sold for the
//  SAME output. It absorbs the drift; it does not price it.
//
//  The mechanism
//  ─────────────
//  `fillModule` already carries a fill-time number into the core, and unlike a
//  proportional leg EVERY leg and EVERY item scales by `delta / fillTotal`
//  ({Pricing.outputAt}, {Base._prorate}). So returning the position as `delta`
//  sells the accrued interest AT THE MAKER'S OWN SIGNED RATE:
//
//      fillTotal   = 1.5 WETH   (the maker-signed CAP)
//      legsOut[0]  = 3000 USDC  (what the cap is worth)
//      position    = 1.3 WETH   (resolved here, at fill time)
//      ⇒ delta 1.3 → the maker is paid ceil(1.3 · 3000 / 1.5) = 2600 USDC
//
//  ⚠ THE THREE AMOUNTS MUST BE THE SAME NUMBER, AND THAT IS ENFORCED BELOW.
//  {Base._prorate} and {Pricing.inputOwed} both compute `x · delta / fillTotal`,
//  which is exact — no rounding at all — only when `x == fillTotal`. So this
//  requires `item.amount == legsIn[0].start == fillTotal`. Signed any other way
//  the item slice and the leg charge drift apart by a rounding unit; a shape that
//  can only be signed wrongly is one this contract refuses.
//
//  What it retires
//  ───────────────
//  Because the position is resolved BEFORE the item runs, the item runs in
//  `Exact` mode with `amount == the live position`. Within one block the venue's
//  index cannot move between this STATICCALL and the withdraw, so the residual is
//  zero: no `Full` branch, no {FullFillGuard}, no sweep. {FullFillGuard} exists
//  only because a module cannot tell the core what it moved, so the maker must
//  pre-commit the slice against a hand-written per-module byte map — and that map
//  has already produced one filler-reachable force-unwind.
//
//  ⚠ THE CAP IS LOAD-BEARING, FOR THE SAME REASON IT IS ON A PROPORTIONAL LEG
//  ─────────────────────────────────────────────────────────────────────────
//  A maker's POSITION is not under their sole control: on every venue here a third
//  party may supply on their behalf (`supply(asset, amount, onBehalfOf)`), exactly
//  as anyone may raise a wallet balance by transferring in. An uncapped resolve
//  would be a standing offer to sell an arbitrarily large position at a price
//  signed for a much smaller one. `fillTotal` IS that cap, it is maker-signed, and
//  the core independently enforces `filled + delta <= fillTotal`. `fillTotal == 0`
//  is the unset value, so it reverts rather than meaning "unbounded".
//
//  ⚠ ONE-SHOT BY CONSTRUCTION
//  ──────────────────────────
//  `prevFilled != 0` reverts {AlreadyFilled}. The first fill is a PARTIAL one
//  whenever the position is below the cap, so without this the order would stay
//  OPEN at the signed rate and a maker who later re-supplies the same market would
//  find their new position sellable at the old price. {Proportional} gets this for
//  free by being full-fill only. The fill-once timing bit CANNOT substitute — it
//  requires `delta == fillTotal`, precisely the case this module does not produce.
//
//  Trust model
//  ───────────
//  `fillModule` is maker-signed and consensus-critical, and this is a STATICCALL
//  returning one word: a wrong number mis-sizes the FRACTION, which scales the
//  maker's side and the solver's side identically, and the core's cap catches the
//  only extraction direction. The module queried comes from the maker-signed items
//  blob, so a maker can only ever point this at their own position — nothing in
//  the filler's `takerData` reaches it, which is why that argument is ignored.
// ════════════════════════════════════════════════════════════════════════════

/// @title PositionFillModule
/// @notice Venue-agnostic fill module that sizes an exit from the maker's live
///         position, read from the item's own module via {IPositionSource}.
contract PositionFillModule is IFillModule, IFillModuleDescribe {
    /// @dev The order carries no fill denominator. `fillTotal` is the maker's
    ///      mandatory cap on the resolved position — see the contract note.
    error NoDenominator();
    /// @dev Second and later fills. See the one-shot note for why the fill-once
    ///      timing bit cannot express this.
    error AlreadyFilled();
    /// @dev No item in this order reports a position: the order carries no items or
    ///      no input legs, no item's module implements {IPositionSource}, or the one
    ///      that does refused the op in its `data` (a borrow leg, a share-denominated
    ///      side). Fails closed rather than resolving something.
    error NoPositionItem();
    /// @dev More than one item reports a position, so which one denominates the fill
    ///      is ambiguous. Refused rather than picking the first — the maker meant
    ///      something the encoding cannot express.
    error AmbiguousPositionItem();
    /// @dev `item.amount != fillTotal` or `legsIn[0].start != fillTotal`. See the
    ///      "three amounts" note — any other shape prorates inexactly.
    error DenominatorMismatch(uint256 found, uint256 fillTotal);
    /// @dev The module reports its position in a token that is not the one being
    ///      sold. Without this the fill numerator and the leg it scales would be
    ///      denominated differently — the units check that makes the resolved
    ///      number safe to use at all.
    error PositionAssetMismatch(address reported, address legToken);
    /// @dev A BUY order prices off `legsOut[0]`; "sell my whole position" is a
    ///      SELL. Refused rather than silently resolving against the wrong side.
    error NotASellOrder();
    /// @dev The position resolved ABOVE the size the filler offered to buy. The
    ///      filler's `fillAmount` is honoured as a CEILING — see the note on the
    ///      solver's staleness bound.
    error PositionExceedsQuote(uint256 position, uint256 offered);

    /// @inheritdoc IFillModule
    /// @dev `takerData` is ignored — no filler-supplied byte reaches the venue read.
    ///      The filler does NOT get to size the exit either: that would be choosing
    ///      how much of the maker's position to unwind, which is the `BalanceMode.Full`
    ///      force-unwind problem again.
    ///
    ///      ⚠ BUT `fillAmount` IS HONOURED AS A CEILING, AND MUST BE.
    ///      {Proportional} gets its solver-side staleness bound for free from
    ///      `fillUpTo`'s clamp — "the solver is never silently made to buy more than
    ///      it priced" — and a fill-module order bypasses that clamp entirely
    ///      ({Core._clampToRemaining} returns a module order's proposal untouched).
    ///      Without the check below, a solver who quoted against a 1.3 position and
    ///      found 1.5 at inclusion would be silently made to buy 1.5.
    ///
    ///      It REVERTS rather than filling small, which is {Proportional}'s
    ///      semantics too (a clamped request there fails
    ///      {ProportionalNeedsFullFill}). Filling small would be worse for both
    ///      sides: the order is one-shot, so the maker would be left partially
    ///      exited with their exit order spent, and the filler would be choosing the
    ///      unwind size after all. A solver with no view on size passes the cap
    ///      (`fillTotal`), which can never bind; one bounding its exposure passes its
    ///      quote and gets a revert instead of a surprise.
    ///
    ///      The maker's matching FLOOR needs no machinery here: `order.minFillAnchor`
    ///      is already checked against `delta` by the core.
    function resolveFill(Order calldata order, uint256 prevFilled, uint256 fillAmount, bytes calldata)
        external
        view
        override
        returns (uint256 delta)
    {
        if (prevFilled != 0) revert AlreadyFilled();
        if (DutchAuction.side(order) != OrderSide.SELL) revert NotASellOrder();

        uint256 total = order.fillTotal;
        if (total == 0) revert NoDenominator();
        // ⚠ NOT `b.length == 0` — a well-formed EMPTY packed array is the single
        // byte `0x00`, whose length is 1. {PackedArrays.countUnchecked} is the
        // emptiness test; {validateFixed} is what bounds-checks the read below.
        if (PackedArrays.validateFixed(order.legsIn, PackedArrays.LEG_IN_STRIDE) == 0) revert NoPositionItem();

        // Clamp to the maker's cap. A position ABOVE the cap sells exactly the cap
        // — identical to the absolute order the maker would otherwise have signed,
        // never worse. Below it, they sell what they have and are paid pro rata. A
        // position of zero returns 0, which the core rejects {ZeroFill}: an exit
        // order with nothing to exit fails closed.
        uint256 position = _positionFor(order, total);
        delta = position < total ? position : total;
        if (delta > fillAmount) revert PositionExceedsQuote(delta, fillAmount);
    }

    /// @dev The shape checks and the venue read, in their own frame — the whole lot
    ///      inline overflows the stack under legacy codegen.
    function _positionFor(Order calldata order, uint256 total) private view returns (uint256) {
        (uint256 itemAmount, address asset, uint256 position) = _findPositionItem(order);
        if (itemAmount != total) revert DenominatorMismatch(itemAmount, total);

        (address legToken, uint256 anchorStart, uint256 anchorEnd) = PackedArrays.legIn(order.legsIn, 0);
        if (anchorStart != total) revert DenominatorMismatch(anchorStart, total);
        // ⚠ AND IT MUST BE FIXED. The exactness argument above describes
        // {Pricing.inputOwed}'s FIXED branch; with `end != 0` the auctioned branch
        // runs instead and charges `delta · inTick(start, end, bump) / anchor`, which
        // EXCEEDS the position the item withdrew — and {Core._payInputsToSolver}
        // pulls the difference from the maker's wallet, in an amount the filler picks
        // by choosing the inclusion block. A rising anchor leg is a shape that can
        // only be signed wrongly on a position-sized exit, so it is refused.
        if (anchorEnd != 0) revert DenominatorMismatch(anchorEnd, 0);
        if (asset != legToken) revert PositionAssetMismatch(asset, legToken);
        return position;
    }

    /// @notice The one item in this order that reports a position.
    ///
    /// @dev ⚠ SCANNED, NOT INDEX 0 — and that is forced by how a real close is
    ///      shaped. A levered position cannot have its collateral moved out while
    ///      the debt is open (Aave reverts on the health factor), so a close is
    ///      signed `[repay, withdraw]` and the position-bearing item is NOT first.
    ///      Pinning an index would have made the whole close flow unexpressible.
    ///
    ///      The position item identifies ITSELF: it is the item whose module answers
    ///      {IPositionSource.positionOf}. A module that does not implement it has no
    ///      such function and reverts; one that does but refuses the op in its `data`
    ///      (a borrow leg, a share-denominated side) reverts too. Both are skipped.
    ///      So there is nothing to configure, and — as with the module identity
    ///      itself — nothing to configure wrongly.
    ///
    ///      TWO reporters revert {AmbiguousPositionItem} rather than the first one
    ///      winning: which item denominates the fill would otherwise depend on
    ///      signing order, which is not something a maker should have to know.
    ///
    ///      The cost of `try`/`catch` here is diagnostic, not safety: a module's own
    ///      revert reason (a wrong-op `BadOp`, say) is swallowed and surfaces as
    ///      {NoPositionItem}. Worth it for a shape that does not need an index.
    function _findPositionItem(Order calldata order)
        private
        view
        returns (uint256 itemAmount, address asset, uint256 position)
    {
        // ⚠ validateRecords, NOT countUnchecked. {PackedArrays}' safety contract is
        // explicit: the count must come from the validator, never from the blob's own
        // byte, because an accessor past the validated count reads adjacent calldata
        // as if it were order data. `resolveFill` is the FIRST consumer of this blob
        // on the single-order path — {Base._executeItems} does not validate until
        // after — so the proof has to happen here, exactly as it already does for
        // `legsIn` above.
        uint256 n = PackedArrays.validateRecords(order.items, PackedArrays.ITEM_HEAD);
        // Record blobs are cursor-walked from {recordsStart}, PAST the count byte —
        // a raw `0` cursor reads the count into the top byte of `op` and shifts every
        // field one byte left.
        uint256 cursor = PackedArrays.recordsStart();
        bool found;
        for (uint256 i; i < n;) {
            (uint256 amount, address a, uint256 p, uint256 next) = _tryItem(order, cursor);
            cursor = next;
            if (a != address(0)) {
                if (found) revert AmbiguousPositionItem();
                found = true;
                itemAmount = amount;
                asset = a;
                position = p;
            }
            unchecked {
                ++i;
            }
        }
        if (!found) revert NoPositionItem();
    }

    /// @dev One item's probe, in its own frame — the `try` plus the six-value
    ///      {PackedArrays.itemAt} destructuring overflows the stack inside the loop
    ///      under legacy codegen.
    /// @return amount   the item's signed amount (meaningful only when `asset != 0`).
    /// @return asset    `address(0)` when this item reports no position — its module
    ///                  does not implement {IPositionSource}, or it refused the op in
    ///                  `data`. A module answering with a zero asset is therefore read
    ///                  as "no position", which is the honest reading of a zero token
    ///                  address anyway.
    /// @return position the reported position.
    /// @return next     the cursor for the following record.
    function _tryItem(Order calldata order, uint256 cursor)
        private
        view
        returns (uint256 amount, address asset, uint256 position, uint256 next)
    {
        address module;
        bytes calldata itemData;
        (, module, amount,, itemData, next) = PackedArrays.itemAt(order.items, cursor);
        // ⚠ try/catch CANNOT catch this case. A STATICCALL to a code-less address
        // SUCCEEDS with empty returndata; solc then decodes the return tuple in the
        // caller's frame, so the decode failure propagates instead of reaching
        // `catch` — the whole resolve reverts rather than skipping the item. Verified
        // under solc 0.8.34 for both a code-less address and a permissive
        // `fallback()`. Skip explicitly so the documented "not a reporter ⇒ skipped"
        // rule actually holds.
        if (module.code.length == 0) return (amount, address(0), 0, next);
        try IPositionSource(module).positionOf(order.maker, itemData) returns (address a, uint256 p) {
            (asset, position) = (a, p);
        } catch {}
    }

    /// @inheritdoc IFillModuleDescribe
    /// @dev `dynamicSize` because the delta IS the maker's live position — it moves
    ///      with accrual and with anyone supplying on the maker's behalf. `oneShot`
    ///      because {AlreadyFilled} closes the order after the first fill even though
    ///      that fill is a PARTIAL one whenever the position sat below the cap.
    function describeFill() external pure override returns (bytes32 kind, bool dynamicSize, bool oneShot) {
        return ("POSITION_SIZED", true, true);
    }
}
