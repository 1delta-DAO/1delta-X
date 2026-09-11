// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

/// @title PreFundGuard
/// @notice The two checks that make PRE-FUNDED `TAKE_FOR` sound, and the reason
///         either one alone is worthless.
///
///  The defect this exists to close (F27/C-1, C-4)
///  ─────────────────────────────────────────────
///  A pre-fund module funds an instructed `forAmount` from its OWN balance. Its
///  headers all asserted that `forAmount` is "core-sized to exactly what the fill
///  delivered here". Neither half of that was enforced:
///
///    1. NOT NECESSARILY CORE-SIZED. `Permit3.takeFor` is a permissionless
///       external entrypoint, and `Permit3.approveTaker` lets a caller name ITSELF
///       spender. So `approveTaker(self, module, keccak256(data), 1, max)` followed
///       by `takeFor(module, self, 1, <any forAmount>, 0, data)` reaches the module
///       with Settlement, the order and the maker's signature all out of the path.
///       `msg.sender == permit3` authorises NOTHING by itself.
///
///    2. NOT NECESSARILY DELIVERED HERE. Even on the honest Settlement path,
///       {Base._forSlice} validates the referenced leg's INDEX and recipient but
///       binds neither the recipient to this module (`address(0)` and the maker are
///       both admitted) nor the leg's TOKEN to the asset the module spends — and it
///       re-prices the leg rather than consuming it, so N items may each claim one
///       delivery.
///
///  WHY THE TWO COMPOSE, AND WHY NEITHER STANDS ALONE
///  ─────────────────────────────────────────────────
///  {floorOf} is the balance check `TellerPreFundRepayModule` already had, and Teller
///  was drained anyway. The subtraction only underflows when `forAmount > balance`
///  — an OVER-ask. An attacker under-asks: with `forAmount == balance` the floor is
///  0 and the module pays out everything; with `forAmount = balance/2` it does it
///  twice. A floor cannot prove receipt while the attacker chooses the subtrahend.
///
///  Pin the spender first and that inverts. `forAmount` is then core-derived, so
///  the attacker no longer picks it, and the same subtraction becomes a real
///  mis-pairing detector: it catches a leg addressed to the maker's wallet, a leg
///  denominated in another token, AND the second claim on a once-delivered leg
///  (the first claim consumes the balance, so the second underflows). That last
///  one is why this closes {Base._forSlice}'s three unbound axes in practice
///  without spending Settlement bytecode the contract does not have.
///
///  USE BOTH. `spender == settlement` without a floor trusts the core's unbound
///  leg reference; a floor without `spender == settlement` is Teller.
library PreFundGuard {
    /// @dev The forwarded `Permit3.takeFor` caller is not this module's Settlement.
    error OnlySettlement();

    /// @dev The funding descriptor is not a leg reference carrying the PRE-FUND bit.
    error PreFundDescriptorRequired();

    /// @dev A plain-`take` blob carried a funding descriptor in word 0. See
    ///      {requirePlainTake} for why this must be rejected rather than ignored.
    error PreFundDescriptorNotAllowed();

    /// @dev A `takeFor` blob used the LITERAL funding form on a contract that also
    ///      hosts `takeOnBehalf`. See {requireFundingDescriptor}.
    error LiteralDescriptorNotAllowed();

    /// @dev The module is about to spend an asset the maker did NOT name as this
    ///      leg's funding token. See {fundingToken}: the descriptor's token field and
    ///      the referenced `legsOut[j].token` are bound to each other by the CORE
    ///      ({Base._forSlice}); this is the other half, binding both to the asset the
    ///      module actually moves. Without it the core proves "X of token T arrived"
    ///      and the module spends "X of token U", which is the whole drain.
    error FundingTokenMismatch();

    /// @notice Assert this call came through the pinned Settlement.
    /// @dev Reverts on the direct-`takeFor` path, which is the primary drain
    ///      channel: there `forAmount` is simply the caller's own argument.
    function requireSettlement(address spender, address settlement) internal pure {
        if (spender != settlement) revert OnlySettlement();
    }

    /// @notice Require the PRE-FUND descriptor form: a leg reference (bit 255, bit 254
    ///         clear) that also declares the pre-fund shape (bit 253).
    /// @dev Bit 253 is what makes {Base._forSlice} demand
    ///      `legsOut[j].recipient == module` rather than accepting the maker or
    ///      `address(0)` (F27/H-1). A pre-fund module MUST require it, or a maker can
    ///      simply omit the bit and get the loose check back. A LITERAL descriptor
    ///      would instruct an amount no delivery backs, and a BALANCE one reads the
    ///      MAKER's wallet while this module funds from its own — both are
    ///      mis-pairings by construction.
    function requireLegRef(bytes calldata data) internal pure {
        if (_word0(data) >> 253 != 5) revert PreFundDescriptorRequired();
    }

    /// @notice Require the PLAIN-`take` data space: word 0 must NOT be a pre-fund
    ///         descriptor.
    /// @dev The mirror of {requireLegRef}, and what lets ONE contract host both
    ///      `takeOnBehalf` and `takeForOnBehalf` safely.
    ///
    ///      Permit3's taker book is keyed `(user, spender, module, keccak256(data))`
    ///      and records NOTHING about which dispatch a grant was meant for. So a
    ///      contract implementing both entrypoints would let one `approveTaker`
    ///      authorise either — and the `takeFor` shape additionally moves value IN.
    ///      That is why one-module-one-shape was enforced rather than documented.
    ///
    ///      The two data spaces are already disjoint at word 0, which is what makes
    ///      the merge safe: a pre-fund blob has bits 255 and 253 set (`>> 253 == 5`),
    ///      while a plain-take blob opens with an address, a `MarketParams` head or
    ///      a `uint8` op — every one of them below `2^160`, so `>> 253 == 0`.
    ///      Assert both halves and NO blob satisfies both entrypoints, so no `ref`
    ///      can ever be valid for both shapes and the grant is unambiguous again.
    ///
    ///      Enforced by `tools/check-module-shapes.py`: a contract carrying both
    ///      entrypoints must carry both guards. The invariant stays machine-checked
    ///      — it changed shape, it did not become prose.
    function requirePlainTake(bytes calldata data) internal pure {
        if (data.length >= 32 && _word0(data) >> 253 != 0) revert PreFundDescriptorNotAllowed();
    }

    /// @notice Require a NON-LITERAL funding descriptor: leg-reference or balance.
    /// @dev The weaker sibling of {requireLegRef}, for a dual-shape contract whose
    ///      `takeFor` op must keep the pull shape's BALANCE form (which
    ///      {requireLegRef} would reject) while still staying clear of the
    ///      plain-`take` data space.
    ///
    ///      The spaces, by `desc >> 253`:
    ///
    ///        LITERAL       0..3      ← overlaps plain-take
    ///        LEG-REF pull  4
    ///        LEG-REF pre-fund  5
    ///        BALANCE       6..7
    ///        plain take    0         (word 0 is an address or a `uint8` op)
    ///
    ///      So the ONLY collision is the literal form, and excluding it leaves
    ///      {4,5,6,7} against {0} — disjoint, which is the property that makes one
    ///      `ref` unable to authorise both dispatches.
    ///
    ///      ⚠ The cost is real and must be a deliberate choice: the op loses the
    ///      LITERAL descriptor, i.e. a maker can no longer sign an absolute funding
    ///      amount for it. Modules whose whole point is a core-sized funding leg
    ///      lose nothing; one that wants literals must stay a separate contract.
    function requireFundingDescriptor(bytes calldata data) internal pure {
        if (_word0(data) < (uint256(1) << 255)) revert LiteralDescriptorNotAllowed();
    }

    /// @dev The descriptor word, read with `calldataload` rather than a
    ///      `bytes32(data[0:32])` slice. The slice form is a bounds-checked
    ///      calldata COPY INTO MEMORY: measured at **417 gas** on the aave-v3
    ///      leverage path, enough on its own to make the composite item cost more
    ///      than the two-item pair it exists to beat. {Base._forSlice} reads the
    ///      same word the same way, for the same reason.
    function _word0(bytes calldata data) private pure returns (uint256 w) {
        if (data.length < 32) revert PreFundDescriptorRequired();
        /// @solidity memory-safe-assembly
        assembly {
            w := calldataload(data.offset)
        }
    }

    /// @notice The funding TOKEN the maker signed into the descriptor — bits [16:176).
    /// @dev THE THIRD AXIS. {Base._forSlice} binds the referenced leg's INDEX, its
    ///      RECIPIENT (bit 253) and its single use ({Base.ForLegReused}), and — since
    ///      the token field was added — requires `legsOut[j].token` to equal this
    ///      word. That makes the delivery's token maker-signed and core-checked; what
    ///      it cannot do is know which asset a module will SPEND, because that is
    ///      decoded from a module-specific layout the core deliberately never reads.
    ///
    ///      So the two halves meet here. Reading the token from the ONE signed word
    ///      both sides check is what collapses "the leg's token" and "the module's
    ///      asset" into a single value; a module that decodes its asset from its own
    ///      `data` field and never compares it to this one re-opens the gap.
    ///
    ///      Rejects any descriptor that is not a PRE-FUND leg reference, so the field
    ///      cannot be read out of a BALANCE blob (whose bits [160:176) are `floorBps`)
    ///      or a LITERAL one.
    function fundingToken(bytes calldata data) internal pure returns (address) {
        uint256 w = _word0(data);
        if (w >> 253 != 5) revert PreFundDescriptorRequired();
        return address(uint160(w >> 16));
    }

    /// @notice The balance that was here BEFORE this fill's delivery.
    /// @dev The underflow IS the check — a funding leg not addressed to this
    ///      module in this token leaves `entry < forAmount` and this reverts. Sound
    ///      only above {requireSettlement}; see the header. Callers spend down to
    ///      this floor and never below it, which is also F19's rule (another
    ///      fill's dust may legitimately be sitting here).
    ///
    ///      ⚠ TAKES `data` SO THE TOKEN CHECK CANNOT BE FORGOTTEN. The asset a module
    ///      spends and the leg the core sized `forAmount` from are two different
    ///      values in two different layouts; every pre-fund body already calls this
    ///      helper with the asset it is about to move, so this is the one place that
    ///      sees both. Asserting here makes "took the floor but not the token" a
    ///      shape that does not compile, rather than a rule each of 17 modules has to
    ///      re-type correctly.
    function floorOf(bytes calldata data, address asset, uint256 forAmount) internal view returns (uint256) {
        if (asset != fundingToken(data)) revert FundingTokenMismatch();
        return IERC20(asset).balanceOf(address(this)) - forAmount;
    }

    /// @notice Assert this fill's delivery actually landed here, in this token.
    /// @dev The `floorOf` check where the floor itself is not needed afterwards
    ///      (deposit-shaped modules, which spend the whole `forAmount` and sweep
    ///      nothing). Same underflow, same meaning; named so the intent reads.
    function requireDelivered(bytes calldata data, address asset, uint256 forAmount) internal view {
        floorOf(data, asset, forAmount);
    }

    /// @notice Return everything this module holds ABOVE `floor` to the maker.
    /// @dev The measured surplus, by construction. `floor` was the balance before
    ///      this fill's delivery, so after the venue has taken what it takes, the
    ///      excess over `floor` IS `forAmount - consumed` — without anyone having
    ///      to compute, or be told, what `consumed` was. That is the point: a
    ///      sweep sized from a venue's RETURN VALUE lets a caller-chosen venue pull
    ///      the whole approval, report 0, and collect a second `forAmount`
    ///      (F27/C-3); a sweep sized from the pre-call CLAMP silently strands the
    ///      difference when the venue consumes less than it was asked for
    ///      (F27/M-1). This is immune to both, and drops the local the two
    ///      stack-tightest repay modules could not afford.
    ///
    ///      The return-value-sized route (`sweepable` / `sweepTo`, a floor-clamped
    ///      `want`) was removed 2026-09-11 once its last caller migrated here: a
    ///      helper for the weaker pattern is an invitation to use it.
    function sweepSurplus(address asset, address to, uint256 floor) internal {
        uint256 bal = IERC20(asset).balanceOf(address(this));
        if (bal > floor) SafeTransferLib.safeTransfer(asset, to, bal - floor);
    }
}
