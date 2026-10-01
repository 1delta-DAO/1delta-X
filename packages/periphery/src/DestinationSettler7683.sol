// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Settlement} from "@core/settlement/Settlement.sol";
import {PackedArraysMem} from "@core/settlement/PackedArraysMem.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {SettlementLens} from "./SettlementLens.sol";
import {IDestinationSettler, FillBounds, FillerData, FillPayload, Order7683, OrderPayload} from "./Erc7683.sol";

/// @title DestinationSettler7683
/// @notice The ERC-7683 `fill` entry point: a solver that already speaks the standard
///         calls `fill(orderId, originData, fillerData)` and this executes the
///         underlying 1delta-x order, with the solver's own tokens, in one call.
///
///  What it does, in order:
///    1. decode the {FillPayload} and CHECK IT IS THE ORDER THE CALLER ASKED FOR
///       (`orderId == hashOrder(order)`) — the standard's id is our order hash, so a
///       mismatch means the caller was handed a different order than it quoted;
///    2. record a BALANCE FLOOR for every touched token (input and output), then pull
///       each output leg's amount from the caller (which must have approved this
///       adapter), sized by {SettlementLens.previewFill} — the same numbers the fill
///       will charge;
///    3. approve the settlement the AGGREGATE per token, run `fillUpTo`, reset to zero;
///    4. HOLD THE FILL TO THE CALLER'S BOUNDS ({FillBounds}) — the published
///       `maxSpent` / `minReceived`, or the caller's own from `fillerData` — against
///       the `paid` / `received` the settlement itself returns;
///    5. sweep every touched token's balance above its floor to the caller (or the
///       recipient named in `fillerData`). That one sweep returns both leftover output
///       funds and the fill's input-leg proceeds, and pays only what actually landed.
///
///  ⚠ STEP 4 IS WHAT MAKES `maxSpent` A CAP (audit 2026-09-30 PERIPH-1). This adapter
///  pulls whatever the IN-TRANSACTION price is, and a maker controls several things
///  that move that price toward itself between the quote and the fill: a priority
///  auction prices off `tx.gasprice` (an `eth_call` at gas price 0 quotes the floor, a
///  real tip clears near `start`), a maker-chosen price module receives the filler
///  address and may answer this adapter differently from the resolver, and a curve or
///  a gas bump can move the tick back up. The signed `start` was the only ceiling, and
///  a solver with a standing approval paid it. Every fill now reverts {BoundExceeded}
///  unless each leg settled at the bound's price or better.
///
///  ⚠ WHY `fillUpTo`, NOT the strict `fill`. `p.fillAmount` is published VERBATIM in
///  the origin adapter's `Open` event and replayed by every solver. The strict `fill`
///  reverts {OverFill} once the order is partially filled through any other entry, so
///  the published payload would brick for the remainder of the order. `fillUpTo`
///  CLAMPS to remaining, exactly as {SettlementLens.previewFill} does when it sizes
///  the pulls above, and the bounds are per-unit, so the clamped fill is held to the
///  quoted PRICE rather than to its size. A {Proportional} order is the exception to
///  the clamp — the core never trims one down, and the `type(uint256).max` "whatever
///  the balance is" sentinel is the one size it resolves against the live balance. A
///  proportional fill pays every output IN FULL whatever the anchor resolves to, so a
///  maker draining its balance before the fill moves the per-unit price, and step 4
///  reverts it (PERIPH-3).
///
///  ⚠ THE FILLER THE SETTLEMENT SEES IS THIS CONTRACT, never the solver calling it
///  (PERIPH-7). So:
///    • an exclusivity window names someone else ⇒ the fill is an OUTSIDER's: a HARD
///      window reverts `NotExclusiveFiller`, a SOFT one charges the override premium
///      (the origin quotes it that way);
///    • a filler-aware gate — a solver whitelist, an attestation validator, a
///      cosigned quote bound to a filler — sees this permissionless adapter. Naming
///      the adapter opens the order to every caller; naming the solver makes it
///      unfillable here;
///    • a `SETTLE` item would pay the adapter, so such orders are refused
///      ({Order7683.SettleItemUnsupported}), and the adapter has no ERC-721/1155
///      receiver hooks;
///    • the flow is inventory-funded only — there is no callback.
///
///  ⚠ THIS CONTRACT MUST END EVERY CALL HOLDING NOTHING AND APPROVING NOTHING, and
///  that is load-bearing rather than hygiene — the same argument {NativeSettler}
///  makes. `originData` is fully caller-controlled, so the order it carries is
///  attacker-chosen, and Settlement pulls OUTPUT legs from whoever is filling (this
///  contract). Any balance or standing approval left here between calls is therefore
///  free for the next caller to name as an output leg and walk away with. Four
///  properties close it, and the fourth is the one that actually does the work:
///    1. approvals are scoped to this fill's own aggregate amounts, never `type(uint256).max`;
///    2. approvals are reset to 0 before returning;
///    3. residue is swept to the caller, so nothing accumulates;
///    4. a BALANCE FLOOR — every touched token (input AND output) must end at or above
///       what this contract held on entry, so a donated or stranded balance is
///       unreachable and a caller can only ever extract what this fill actually
///       produced for it. Measuring the floor over the UNION of both sides is what
///       makes a same-asset order (a token that is both an input and an output leg)
///       safe: the input proceeds are swept exactly once, never paid twice.
contract DestinationSettler7683 is IDestinationSettler {
    using SafeTransferLib for address;

    Settlement public immutable SETTLEMENT;
    SettlementLens public immutable LENS;

    /// @dev The caller asked to fill `orderId` but `originData` carries a different
    ///      order. Never silently fill the other one.
    error OrderIdMismatch();
    /// @dev The balance floor tripped — see the contract note. Nothing was settled.
    error BalanceFloorBreached();
    /// @dev The lens passed to the constructor serves a different settlement.
    error LensSettlementMismatch();
    /// @dev The bounds do not fit the order: `quotedDelta == 0`, or an array whose
    ///      length is not the order's leg count. Fails closed — a bound that cannot
    ///      be applied is never read as "no bound".
    error MalformedBounds();
    /// @dev Output leg `leg` charged the filler more than the bound's price, or input
    ///      leg `leg` paid it less (`output` says which side). Nothing was settled.
    error BoundExceeded(bool output, uint256 leg);

    /// @dev The two addresses MUST be a pair: `LENS` sizes the amounts this contract
    ///      pulls from the caller and approves, and `SETTLEMENT` is what then charges
    ///      them. A lens from another deployment would quote one order while the
    ///      settlement charges for another, so the approval could be short (the fill
    ///      reverts) or LONG — an over-approval scoped to an amount the caller never
    ///      intended. Bound here, and both are immutable.
    constructor(address settlement, address lens) {
        if (address(SettlementLens(lens).SETTLEMENT()) != settlement) revert LensSettlementMismatch();
        SETTLEMENT = Settlement(settlement);
        LENS = SettlementLens(lens);
    }

    /// @inheritdoc IDestinationSettler
    /// @param originData `abi.encode(FillPayload)` — the published fill instruction's
    ///                   `originData`, verbatim.
    /// @param fillerData empty (proceeds to the caller, published bounds), or
    ///                   `abi.encode(address payTo)`, or `abi.encode(FillerData)` —
    ///                   see {FillerData}. Authority for the fill is this contract,
    ///                   and the caller pays for it either way.
    function fill(bytes32 orderId, bytes calldata originData, bytes calldata fillerData) external override {
        FillPayload memory fp = abi.decode(originData, (FillPayload));
        OrderPayload memory p = fp.payload;
        if (LENS.hashOrder(p.order) != orderId) revert OrderIdMismatch();
        Order7683.requireNoSettleItem(p.order.items);

        (address payTo, uint256 minBumpBps) = _fillerTerms(fillerData, fp);
        uint256 nOut = PackedArraysMem.validateLegsOut(p.order.legsOut);
        uint256 nIn = PackedArraysMem.validateLegsIn(p.order.legsIn);
        if (fp.bounds.quotedDelta == 0 || fp.bounds.maxPaid.length != nOut || fp.bounds.minReceived.length != nIn) {
            revert MalformedBounds();
        }

        // The floor is taken over the UNION of every touched token, BEFORE any caller
        // funds arrive — the true on-entry balance. A token that appears on both sides
        // is floored once and swept once.
        //
        // Note the packed leg blobs are decoded per-access rather than cached into a
        // memory array: for the realistic 1–2 leg orders this settles, allocating and
        // filling an `address[]` MEASURED MORE (+~1.1k gas on a single-leg fill) than
        // the handful of cheap re-decodes it would save — the array only wins for many-
        // leg baskets that do not occur here. Keep the direct reads.
        (address[] memory tokens, uint256[] memory floors) =
            _touchedFloors(p.order.legsIn, p.order.legsOut, nIn, nOut);

        _fundAndFill(p, nOut, minBumpBps, fp.bounds);

        // Enforce the floor and sweep everything above it — leftover output funds and
        // input proceeds alike — to `payTo`. Paying the actual balance delta (not a
        // preview nominal) is fee-on-transfer safe and cannot draw a stranded balance.
        for (uint256 t; t < tokens.length; t++) {
            uint256 bal = tokens[t].balanceOf(address(this));
            if (bal < floors[t]) revert BalanceFloorBreached();
            if (bal > floors[t]) tokens[t].safeTransfer(payTo, bal - floors[t]);
        }
    }

    /// @dev `payTo` and the price floor from `fillerData`, and — in the long form — the
    ///      caller's own bounds written over the published ones in `fp`.
    function _fillerTerms(bytes calldata fillerData, FillPayload memory fp)
        private
        view
        returns (address payTo, uint256 minBumpBps)
    {
        if (fillerData.length == 32) {
            payTo = abi.decode(fillerData, (address));
        } else if (fillerData.length != 0) {
            FillerData memory fd = abi.decode(fillerData, (FillerData));
            payTo = fd.payTo;
            minBumpBps = fd.minBumpBps;
            if (fd.bounds.quotedDelta != 0) fp.bounds = fd.bounds;
        }
        if (payTo == address(0)) payTo = msg.sender;
    }

    /// @dev Steps 2–4: pull, approve, `fillUpTo`, reset, then the bound check on what
    ///      the settlement REPORTS it charged and paid. Its own frame for the legacy
    ///      (non-via-IR) stack limit.
    function _fundAndFill(OrderPayload memory p, uint256 nOut, uint256 minBumpBps, FillBounds memory b) private {
        // Quote with THIS contract as the filler — it is the address Settlement will
        // pull outputs from and pay inputs to. `previewFill` mirrors the `fillUpTo`
        // clamp, so `paid[j]` is exactly what the (clamped) fill pulls per output leg.
        (,, uint256[] memory paid) = LENS.previewFill(p.order, p.fillAmount, address(this), p.takerData);

        // Pull each output leg from the caller. Zero-guarded, like the core's own
        // `_deliverOutputs`: a leg that prices to 0 (a BUY dust slice, a zero fee leg)
        // is skipped there, and a token that rejects zero-value transfers must not
        // make the 7683 path stricter than a direct fill.
        for (uint256 j; j < nOut; j++) {
            if (paid[j] != 0) {
                PackedArraysMem.legOutToken(p.order.legsOut, j).safeTransferFrom(msg.sender, address(this), paid[j]);
            }
        }
        // Approve the settlement the AGGREGATE per token, once. Settlement pulls each
        // output leg with a SEPARATE transferFrom, so a duplicate-token basket (the
        // maker leg + a same-token fee leg — the documented fee shape) needs the sum,
        // not the last leg's amount. Scoped to this fill; Settlement's funding
        // fallback accepts a direct ERC20 approval, so no Permit3 allowance stands.
        for (uint256 j; j < nOut; j++) {
            address token = PackedArraysMem.legOutToken(p.order.legsOut, j);
            if (_firstOutIndex(p.order.legsOut, token, nOut) != j) continue;
            token.forceApprove(address(SETTLEMENT), _sumPaidForToken(p.order.legsOut, token, paid, nOut));
        }

        // `fillUpTo` with `recipient = address(0)` routes the input-leg proceeds to
        // this contract (the caller/filler), so the single floor sweep settles them.
        // `minBumpBps` is the caller's own price floor (0 unless it passed one).
        (uint256 delta, uint256[] memory received, uint256[] memory charged) =
            SETTLEMENT.fillUpTo(p.order, p.signature, p.fillAmount, address(0), minBumpBps, p.takerData);

        // Reset each output-token approval to 0, once.
        for (uint256 j; j < nOut; j++) {
            address token = PackedArraysMem.legOutToken(p.order.legsOut, j);
            if (_firstOutIndex(p.order.legsOut, token, nOut) == j) token.forceApprove(address(SETTLEMENT), 0);
        }

        _checkBounds(delta, received, charged, b);
    }

    /// @dev The {FillBounds} rule, on the settlement's OWN return values — the amounts
    ///      it pulled from this adapter and paid it, not the preview. Cross-multiplied
    ///      so a clamped fill is judged per unit; an overflowing product reverts, which
    ///      fails closed. Walked over the BOUNDS' lengths (already checked against the
    ///      order's leg counts), so a short return array panics rather than skipping
    ///      a leg.
    function _checkBounds(uint256 delta, uint256[] memory received, uint256[] memory paid, FillBounds memory b)
        private
        pure
    {
        uint256 q = b.quotedDelta;
        for (uint256 j; j < b.maxPaid.length; j++) {
            uint256 cap = b.maxPaid[j];
            if (cap != type(uint256).max && paid[j] * q >= cap * delta + q) revert BoundExceeded(true, j);
        }
        for (uint256 i; i < b.minReceived.length; i++) {
            uint256 floor = b.minReceived[i];
            if (floor != 0 && received[i] * q + q <= floor * delta) revert BoundExceeded(false, i);
        }
    }

    /// @dev The deduplicated union of every input- and output-leg token, with each
    ///      token's on-entry balance as its floor. The scratch array is sized to
    ///      `nIn + nOut` and then trimmed to the distinct count, so the sweep visits
    ///      each token exactly once (a same-asset order never appears twice).
    function _touchedFloors(bytes memory legsIn, bytes memory legsOut, uint256 nIn, uint256 nOut)
        private
        view
        returns (address[] memory tokens, uint256[] memory floors)
    {
        address[] memory scratch = new address[](nIn + nOut);
        uint256 nTok;
        for (uint256 j; j < nOut; j++) {
            address token = PackedArraysMem.legOutToken(legsOut, j);
            if (!_contains(scratch, nTok, token)) scratch[nTok++] = token;
        }
        for (uint256 i; i < nIn; i++) {
            address token = PackedArraysMem.legInToken(legsIn, i);
            if (!_contains(scratch, nTok, token)) scratch[nTok++] = token;
        }
        tokens = new address[](nTok);
        floors = new uint256[](nTok);
        for (uint256 t; t < nTok; t++) {
            tokens[t] = scratch[t];
            floors[t] = scratch[t].balanceOf(address(this));
        }
    }

    function _contains(address[] memory arr, uint256 len, address token) private pure returns (bool) {
        for (uint256 i; i < len; i++) {
            if (arr[i] == token) return true;
        }
        return false;
    }

    function _firstOutIndex(bytes memory legsOut, address token, uint256 nOut) private pure returns (uint256) {
        for (uint256 k; k < nOut; k++) {
            if (PackedArraysMem.legOutToken(legsOut, k) == token) return k;
        }
        return nOut;
    }

    function _sumPaidForToken(bytes memory legsOut, address token, uint256[] memory paid, uint256 nOut)
        private
        pure
        returns (uint256 sum)
    {
        for (uint256 k; k < nOut; k++) {
            if (PackedArraysMem.legOutToken(legsOut, k) == token) sum += paid[k];
        }
    }
}
