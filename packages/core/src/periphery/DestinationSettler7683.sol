// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Settlement} from "../settlement/Settlement.sol";
import {PackedArraysMem} from "../settlement/PackedArraysMem.sol";
import {SafeTransferLib} from "../utils/SafeTransferLib.sol";
import {SettlementLens} from "./SettlementLens.sol";
import {IDestinationSettler, OrderPayload} from "./Erc7683.sol";

/// @title DestinationSettler7683
/// @notice The ERC-7683 `fill` entry point: a solver that already speaks the standard
///         calls `fill(orderId, originData, fillerData)` and this executes the
///         underlying 1delta-x order, with the solver's own tokens, in one call.
///
///  What it does, in order:
///    1. decode the payload and CHECK IT IS THE ORDER THE CALLER ASKED FOR
///       (`orderId == hashOrder(order)`) — the standard's id is our order hash, so a
///       mismatch means the caller was handed a different order than it quoted;
///    2. record a BALANCE FLOOR for every touched token (input and output), then pull
///       each output leg's amount from the caller (which must have approved this
///       adapter), sized by {SettlementLens.previewFill} — the same numbers the fill
///       will charge;
///    3. approve the settlement the AGGREGATE per token, run `fillUpTo`, reset to zero;
///    4. sweep every touched token's balance above its floor to the caller (or the
///       recipient named in `fillerData`). That one sweep returns both leftover output
///       funds and the fill's input-leg proceeds, and pays only what actually landed.
///
///  ⚠ WHY `fillUpTo`, NOT the strict `fill`. `p.fillAmount` is published VERBATIM in
///  the origin adapter's `Open` event and replayed by every solver. The strict `fill`
///  reverts {OverFill} once the order is partially filled through any other entry, so
///  the published payload would brick for the remainder of the order. `fillUpTo`
///  CLAMPS to remaining, exactly as {SettlementLens.previewFill} does when it sizes
///  the pulls above — so the approval, the pull and the settled amount stay in
///  agreement — and every partially-fillable order stays fillable through the
///  standard for its whole life.
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
    /// @param fillerData optional `abi.encode(address recipient)` — where proceeds go.
    ///                   Empty means the caller. A destination only: authority for the
    ///                   fill is this contract, and the caller pays for it either way.
    function fill(bytes32 orderId, bytes calldata originData, bytes calldata fillerData) external override {
        OrderPayload memory p = abi.decode(originData, (OrderPayload));
        if (LENS.hashOrder(p.order) != orderId) revert OrderIdMismatch();
        address payTo = fillerData.length == 32 ? abi.decode(fillerData, (address)) : msg.sender;

        // Quote with THIS contract as the filler — it is the address Settlement will
        // pull outputs from and pay inputs to. `previewFill` mirrors the `fillUpTo`
        // clamp, so `paid[j]` is exactly what the (clamped) fill pulls per output leg.
        (,, uint256[] memory paid) = LENS.previewFill(p.order, p.fillAmount, address(this), p.takerData);

        uint256 nOut = PackedArraysMem.count(p.order.legsOut);
        uint256 nIn = PackedArraysMem.count(p.order.legsIn);

        // The floor is taken over the UNION of every touched token, BEFORE any caller
        // funds arrive — the true on-entry balance. A token that appears on both sides
        // is floored once and swept once.
        (address[] memory tokens, uint256[] memory floors) =
            _touchedFloors(p.order.legsIn, p.order.legsOut, nIn, nOut);

        // Pull each output leg from the caller.
        for (uint256 j; j < nOut; j++) {
            PackedArraysMem.legOutToken(p.order.legsOut, j).safeTransferFrom(msg.sender, address(this), paid[j]);
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
        // this contract (the caller/filler), so the single floor sweep below settles
        // them. `minBumpBps = 0`: the adapter takes no price floor of its own.
        SETTLEMENT.fillUpTo(p.order, p.signature, p.fillAmount, address(0), 0, p.takerData);

        // Reset each output-token approval to 0, once.
        for (uint256 j; j < nOut; j++) {
            address token = PackedArraysMem.legOutToken(p.order.legsOut, j);
            if (_firstOutIndex(p.order.legsOut, token, nOut) == j) token.forceApprove(address(SETTLEMENT), 0);
        }

        // Enforce the floor and sweep everything above it — leftover output funds and
        // input proceeds alike — to `payTo`. Paying the actual balance delta (not a
        // preview nominal) is fee-on-transfer safe and cannot draw a stranded balance.
        for (uint256 t; t < tokens.length; t++) {
            uint256 bal = tokens[t].balanceOf(address(this));
            if (bal < floors[t]) revert BalanceFloorBreached();
            if (bal > floors[t]) tokens[t].safeTransfer(payTo, bal - floors[t]);
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
