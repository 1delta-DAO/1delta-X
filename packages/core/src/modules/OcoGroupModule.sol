// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISettlementModule} from "../interfaces/ISettlementModule.sol";
import {IOrderValidator} from "../interfaces/IOrderValidator.sol";
import {Order} from "../settlement/Settlement.sol";

/// @title OcoGroupModule
/// @notice One-cancels-other (OCO) and N-way brackets: a maker-chosen GROUP of
///         its own orders of which AT MOST ONE may ever fill. The classic
///         take-profit + stop-loss bracket, where triggering either side must
///         retire the other, plus its generalization to any number of legs
///         (TP + SL + trailing + time-out) under one group id.
///
///         Registry, validator and claim-writer in ONE contract — the same
///         shape as {FillerWhitelistValidator}. No owner, no admin, no
///         whitelist: every record is keyed by the ORDER'S OWN MAKER, so a
///         group can only ever gate orders that maker signed.
///
///  Why a validator alone cannot do this
///  ────────────────────────────────────
///  A validator is a STATICCALL ({IOrderValidator}), so it can READ that a
///  sibling already went, but nothing in a fill can ever WRITE that fact from
///  the validator layer. The write has to be an ITEM — items are ordinary CALLs
///  — and the settlement runs every validator BEFORE any item. That ordering is
///  exactly what OCO needs:
///
///      fill A:  validators → group unclaimed, PASS   →  item → claim group
///      fill B:  validators → group claimed by A, FAIL (ValidationFailed)
///
///  So each leg of the group carries BOTH halves of this contract:
///
///      validators[] += Validator({target: this, data: abi.encode(groupId)})
///      items[]      += Item({op: SETTLE, module: this, amount: <anchor>,
///                            recipient: 0, data: abi.encode(groupId, nonce)})
///
///  Both live inside the order's EIP-712 hash, so a solver can neither drop the
///  validator (which would let it fill a retired leg) nor drop the item (which
///  would let it fill leg A and leave leg B live).
///
///  Why SETTLE and why `amount` must be the anchor
///  ──────────────────────────────────────────────
///  Item amounts are sliced pro-rata, and {Base._runItem} SKIPS a MAKE/TAKE item
///  whose slice floors to zero — so a claim signed as a MAKE with `amount = 0`
///  (or any amount small enough to round away on a partial fill) would silently
///  NOT retire the siblings, and the whole group would become fillable. That
///  failure is invisible: the fill succeeds and the bracket is quietly broken.
///
///  SETTLE is the one item op that REVERTS on a zero slice (`SettleSliceZero`),
///  which converts that silent break into a loud, fail-closed one: a misconfigured
///  bracket does not fill at all. Signing `amount` equal to the order's ANCHOR
///  (`legsIn[0].start` for SELL, `legsOut[0].start` for BUY, or `fillTotal` when
///  set) makes the slice exactly this fill's delta, so it is non-zero for every
///  admissible fill including the smallest partial. Any `amount >= anchor` is
///  also safe; the anchor is the canonical choice.
///
///  `settle` also receives the `filler`, which this module ignores on purpose —
///  an OCO group is a property of the maker's own book, not of who fills it.
///
///  Why the claim records the NONCE
///  ───────────────────────────────
///  A naive `claimed[maker][groupId] = true` would retire the WINNER too: its
///  own second partial fill would run the validator again, see the group
///  claimed, and revert. The claim therefore records WHICH order took the group
///  (`order.nonce + 1`, the `+1` reserving zero for "unclaimed"), and the
///  validator passes for the claimant as well as for an untouched group. So the
///  winning leg keeps filling to completion, in as many partial fills as it
///  likes, while every sibling is dead from the winner's FIRST fill — which is
///  the standard OCO semantic (a partial take-profit retires the stop; sizing
///  the survivor down to the unfilled remainder is not expressible in a
///  single-signature model and is not attempted here).
///
///  ⚠ The nonce is read from the ITEM DATA, not from the order — `settle`
///  receives only `(maker, filler, amount, data)`, with no order context. That is
///  safe because `item.data` is inside the signed order hash: a solver cannot
///  rewrite it, and a maker that signs a nonce other than its own can only
///  retire its own order early. {OcoGroupModule.validate} is the half that reads
///  the REAL `order.nonce`, so the two only agree when the maker encoded
///  honestly — a mismatch simply makes the order unfillable after its first
///  fill, never exploitable.
///
///  Cheaper alternative, no contract at all
///  ───────────────────────────────────────
///  For a WHOLE-FILL bracket, OCO needs no module: sign both legs with the SAME
///  `nonce` and set the fill-once bit (`timing` bit 100, see
///  {DutchAuction.useNonceInvalidator}). The first full fill consumes the shared
///  nonce, and every sibling then reverts `NonceCancelled` on the nonce gate the
///  settlement already runs on every fill. Zero extra gas, zero deployment. Use
///  THIS contract when the legs must stay partially fillable, when the group has
///  more legs than one nonce word can conveniently carry, or when the legs must
///  keep independent nonces for off-chain bookkeeping.
///
/// @dev Item data  = `abi.encode(uint256 groupId, uint256 nonce)`, op `SETTLE`,
///      `amount` = the order's anchor.
///      Validator data = `abi.encode(uint256 groupId)`.
///      `groupId` is any maker-chosen number (a random 256-bit value keeps two
///      of a maker's unrelated brackets from colliding).
contract OcoGroupModule is ISettlementModule, IOrderValidator {
    /// @notice The settlement allowed to dispatch {settle}. Immutable and
    ///         set once — this contract writes state, so unlike a pure validator
    ///         it MUST know who may call it.
    address public immutable settlement;

    /// @notice `claim[maker][groupId]` — `0` when the group is untouched, else
    ///         the claiming order's `nonce + 1`. The `+1` is what lets zero mean
    ///         "unclaimed" while still allowing an order with `nonce == 0` to be
    ///         a group member.
    mapping(address maker => mapping(uint256 groupId => uint256 noncePlusOne)) public claim;

    /// @notice A group was retired by one of its legs. Indexers watching this
    ///         can drop every sibling from an off-chain book the moment the
    ///         winner lands, without waiting for a failed fill to prove it.
    event GroupClaimed(address indexed maker, uint256 indexed groupId, uint256 nonce);

    /// @dev {settle} was not called by the settlement. The uniform module gate —
    ///      a rogue caller must not be able to retire a maker's bracket out of
    ///      band.
    error NotSettlement();
    /// @dev The group is already claimed by a DIFFERENT order. Unreachable
    ///      through a well-formed order (the validator rejects the fill first);
    ///      kept as a fail-closed backstop for a maker that signed the item
    ///      WITHOUT the matching validator.
    error GroupAlreadyClaimed();
    /// @dev `nonce == type(uint256).max` cannot be stored as `nonce + 1`.
    ///      Rejected rather than silently wrapping to the "unclaimed" sentinel.
    error NonceNotRepresentable();

    constructor(address settlement_) {
        settlement = settlement_;
    }

    // ──────────────────── the write half (a SETTLE item) ────────────────────

    /// @notice Claim `groupId` for the order identified by `nonce`, retiring
    ///         every sibling leg of the maker's bracket.
    /// @dev    Moves no value and touches no token, so it needs no approval of
    ///         any kind — neither the maker's nor the filler's. `amount` is
    ///         ignored: the claim is not a quantity and must land identically on
    ///         a 1% fill and a 100% fill. It still has to be signed as the
    ///         order's anchor so the settlement's pro-rata slice never floors to
    ///         zero — see the note on the contract.
    /// @param  maker  the order maker, threaded by the settlement.
    /// @param  data   `abi.encode(uint256 groupId, uint256 nonce)`.
    function settle(address maker, address, uint256, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();
        (uint256 groupId, uint256 nonce) = abi.decode(data, (uint256, uint256));
        if (nonce == type(uint256).max) revert NonceNotRepresentable();

        uint256 mine = nonce + 1;
        uint256 current = claim[maker][groupId];
        if (current == mine) return; // a later partial fill of the winner — nothing to write
        if (current != 0) revert GroupAlreadyClaimed();

        claim[maker][groupId] = mine;
        emit GroupClaimed(maker, groupId, nonce);
    }

    // ──────────────────── the read half (a validator) ────────────────────

    /// @inheritdoc IOrderValidator
    /// @dev Passes iff the group is untouched, OR this very order is the one
    ///      that claimed it (so the winner stays partially fillable). Reads the
    ///      REAL `order.nonce`, never the item blob — the item's copy only
    ///      decides what gets WRITTEN, this decides what is ALLOWED.
    ///      `filler` and `takerData` are irrelevant: an OCO group is a property
    ///      of the maker's own book, not of who is filling.
    function validate(Order calldata order, address, bytes calldata data, bytes calldata)
        external
        view
        override
        returns (bool)
    {
        uint256 groupId = abi.decode(data, (uint256));
        uint256 current = claim[order.maker][groupId];
        if (current == 0) return true; // nobody went yet
        unchecked {
            // `current` is a stored `nonce + 1`, so it is never 0 here and the
            // comparison cannot wrap: an `order.nonce` of max never matches
            // because {makeOnBehalf} refuses to store it.
            return current == order.nonce + 1;
        }
    }

    // ──────────────────── views ────────────────────

    /// @notice Whether `groupId` has been retired for `maker` by some OTHER
    ///         order than `nonce`. The exact predicate an off-chain book needs
    ///         to evict a sibling — and the negation of what {validate} allows.
    function isRetiredFor(address maker, uint256 groupId, uint256 nonce) external view returns (bool) {
        uint256 current = claim[maker][groupId];
        if (current == 0) return false;
        unchecked {
            return current != nonce + 1;
        }
    }
}
