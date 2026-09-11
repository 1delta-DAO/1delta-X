// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPermit3} from "@core/interfaces/IPermit3.sol";

import {PreFundGuard} from "./PreFundGuard.sol";

/// @title PreFundModuleBase
/// @notice The three guards every PRE-FUNDED module must run, in one place.
///
///  Why this exists, concretely
///  ───────────────────────────
///  The guards were hand-rolled per contract. A census over the 34 pre-fund contracts
///  found **five** missing one — not through any subtle reasoning, but because a
///  patch script matched the first site in a file and two files held three
///  contracts, and because four contracts live in files whose OTHER `TakeFor`
///  module is pull-shaped and so never matched a `*PreFund*.sol` glob.
///
///  Both misses are the same failure: a rule that has to be re-typed per contract
///  is a rule that will eventually not be. Inheriting it makes "a pre-fund module
///  without the gate" not a thing that compiles.
///
///  Deliberately NOT a library call the module opts into — that is what the
///  hand-rolled version already was.
abstract contract PreFundModuleBase {
    IPermit3 public immutable permit3;

    /// @dev The ONLY spender allowed to reach this module's pre-funding.
    ///      `Permit3.takeFor` is a permissionless entrypoint (F27/C-1).
    address public immutable settlement;

    /// @dev The caller is not Permit3. See {ITakerModule} for why this is first.
    error OnlyPermit3();

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    /// @notice Require a leg-reference descriptor and report which FUNDING shape
    ///         the maker signed: bit 253 set = PUSH (pre-funded), clear = PULL.
    /// @dev This is what lets ONE contract serve both funding shapes of a `TAKE_FOR`
    ///      op whose two variants otherwise differ by a single line — `transferFrom`
    ///      from the maker's wallet versus a balance floor.
    ///
    ///      Bit 253 is the right discriminator because it is the SAME bit the core
    ///      reads: {Base._forSlice} demands `legsOut[j].recipient == module` when it
    ///      is set and admits the maker/zero form when it is clear. So the module's
    ///      funding shape and the core's recipient rule cannot disagree — they are
    ///      driven off one signed bit, inside `keccak256(data)`, so the taker grant
    ///      binds the shape too.
    ///
    ///      ⚠ The PUSH branch MUST still take its balance floor. Merging the shapes
    ///      is sound only because the floor keeps them isolated: a pull fill pulls
    ///      exactly `forAmount` and spends it, and a pre-funded fill never spends below
    ///      the floor, so neither can consume what the other left.
    ///      ⚠ ONLY the PRE-FUND branch is descriptor-restricted. `w >> 253 == 5` is
    ///      leg-reference (bit 255 set, 254 clear) AND pre-fund (253 set) in one
    ///      comparison; everything else is the PULL shape, which legitimately
    ///      accepts the LITERAL and BALANCE descriptor forms too. Demanding a leg
    ///      reference unconditionally would break the pull shape's balance form.
    ///      ⚠ THE LENGTH TEST IS FOLDED IN, exactly as {Base._isPreFundDesc} folds
    ///      it, and for the reason that function states: without it a blob shorter
    ///      than one word is classified from whatever calldata FOLLOWS it. Every
    ///      shipped call site happens to sit behind a length-checked guard today, so
    ///      this is not a live path — but this is the predicate that chooses between
    ///      "pull from the maker's wallet" and "spend my OWN balance", and a rule
    ///      that holds only because of a gate two contracts away is the kind that
    ///      stops holding. Under 32 bytes it now answers PULL, the branch that
    ///      cannot spend the module's balance.
    function _fundingShape(bytes calldata data) internal pure returns (bool isPreFund) {
        /// @solidity memory-safe-assembly
        assembly {
            isPreFund := and(gt(data.length, 31), eq(shr(253, calldataload(data.offset)), 5))
        }
    }

    /// @notice The op a merged pre-fund module should dispatch on: descriptor bits
    ///         [244,252).
    /// @dev Consolidating a venue's pre-fund siblings onto one contract needs a
    ///      discriminator. It goes in the DESCRIPTOR rather than as a new `data`
    ///      field, for two reasons:
    ///
    ///        • no layout change — siblings already share their leading fields,
    ///          so the op alone tells them apart; and
    ///        • it rides inside `ref = keccak256(data)`, so the taker grant binds
    ///          the op. A grant signed for "supply" cannot be replayed as "repay".
    ///          A separate field would have the same property; a field OUTSIDE
    ///          `data` would not, which is the whole reason it lives here.
    ///
    ///      {Base._forSlice} reads only bits 255, 254, 253 and [0,16) of this word,
    ///      so [16,253) is free space. 8 bits is 256 ops against a maximum of three
    ///      siblings on any venue today.
    ///      Length-guarded like {_fundingShape}: a short blob reads op 0 from its own
    ///      (absent) bytes rather than from a neighbouring item's.
    function _preFundOp(bytes calldata data) internal pure returns (uint256 op) {
        /// @solidity memory-safe-assembly
        assembly {
            op := mul(gt(data.length, 31), and(shr(244, calldataload(data.offset)), 0xff))
        }
    }

    /// @notice The full admission check for a PRE-FUNDED MAKE item.
    /// @dev The MAKE-seam form of the pre-fund gate. On the TAKE_FOR seam the same
    ///      three checks are written inline — `msg.sender == permit3`,
    ///      `requireSettlement(spender)`, then a descriptor pin — because every
    ///      shipped pre-fund `takeForOnBehalf` now serves BOTH funding shapes and so
    ///      pins `requireFundingDescriptor` rather than `requireLegRef`; the
    ///      single-shape `_gatePreFund` helper that folded them had no callers left
    ///      and was removed (2026-09-11). This one is SHORTER by the hub pin:
    ///      MAKE is dispatched Settlement → module directly, so the caller is
    ///      `msg.sender` — asserted by the EVM, not carried in a parameter a module
    ///      has to remember to compare. There is no permissionless hub in front of
    ///      this entrypoint, so the F27/C-1 channel does not exist here at all.
    ///
    ///      What does NOT change: the descriptor pin and the balance floor. The core
    ///      binds the referenced leg's RECIPIENT (bit 253) but not its TOKEN, so a
    ///      funded body must still open with {PreFundGuard.requireDelivered} /
    ///      {PreFundGuard.floorOf} on the asset it is about to spend. The leg-reuse axis
    ///      IS now closed in the core ({Base.ForLegReused}), so the floor is no longer
    ///      load-bearing for that one — it remains load-bearing for the token.
    function _gatePreFundMake(bytes calldata data) internal view {
        PreFundGuard.requireSettlement(msg.sender, settlement);
        PreFundGuard.requireLegRef(data);
    }

    /// @notice The admission check for the PLAIN-`take` entrypoint of a dual-shape
    ///         module.
    /// @dev Pins the other half of the data space, so no blob is accepted by both
    ///      entrypoints and no taker grant can be ambiguous about which dispatch it
    ///      authorised. See {PreFundGuard.requirePlainTake}.
    function _gateTake(bytes calldata data) internal view {
        if (msg.sender != address(permit3)) revert OnlyPermit3();
        PreFundGuard.requirePlainTake(data);
    }
}
