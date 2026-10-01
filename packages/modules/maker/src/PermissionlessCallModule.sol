// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

/// @title PermissionlessCallModule
/// @notice Escape-hatch MAKE module: executes ONE arbitrary, maker-signed contract
///         call as a fill item. The state-mutating analogue of {PredicateStaticCall}
///         (which does the read-only version for validators).
///
///  What it is FOR
///  ──────────────
///  A maker-signed PERMISSIONLESS poke, guaranteed to run inside their own fill:
///  `comet.accrueAccount(maker)`, `morpho.accrueInterest(marketParams)`, a vault
///  `harvest()`, an oracle `poke()`. Items run after the output delivery and before
///  the input payout and the order's invariants, so a refresh here is visible to a
///  LATER item and to every invariant — which is the one thing a solver-side
///  callback cannot promise the maker.
///
///  That is the whole of it, and it is deliberately narrow: this contract holds NO
///  authority, so the call it makes can only do what any anonymous address could do
///  unprompted. The protocol already has two authority-less arbitrary-call
///  primitives — {SolverCallbackExecutor} via `fillWithCallback`, and `matchSettle`'s
///  `CALL` step — and both make the identical call. The ONLY thing this adds is that
///  the `(target, callData)` pair is inside the maker's signed order hash (and its
///  slice is pro-rated like any item), rather than being the filler's choice.
///
///  ⚠ WHY THERE IS NO FUNDING, AND WHY IT MUST NOT BE ADDED BACK
///  ─────────────────────────────────────────────────────────────
///  This module used to pull a funding token from the maker via Permit3 and approve
///  it to `target`, which required makers to run
///  `permit3.approveToken(thisModule, token, cap, expiry)`. That was unsafe, and not
///  in a way any check inside this contract can fix:
///
///    • The `msg.sender == SETTLEMENT` gate does NOT bound `spec`. Anyone can sign an
///      order naming THEMSELVES as `maker`, so `spec.target` and `spec.callData` are
///      fully attacker-controlled by simply going through Settlement legitimately.
///    • The arbitrary call runs FROM THIS CONTRACT'S ADDRESS. So it can spend any
///      authority ANY user has granted this address — not only the caller's.
///
///  Together: an attacker signs their own order with
///  `spec.target = permit3`,
///  `spec.callData = transferFrom(victim, attacker, token, amount)`
///  and drains every maker who followed the documented setup, up to their allowance.
///
///  Removing the funding branch removes the REASON anyone would ever grant this
///  address anything. It is not a containment boundary, and nothing here can be:
///
///  ⚠ NEVER GRANT THIS ADDRESS AUTHORITY IN ANY BOOK. Not `permit3.approveToken`,
///  not `permit3.approveTaker`, not a plain ERC20 `approve`, not
///  `setApprovalForAll`, not `comet.allow`, not `morpho.setAuthorization`, not Aave
///  `approveDelegation`. Anything this address can do, an attacker's self-signed
///  order can do for them. This module never asks for any of it, and a maker who
///  needs a FUNDED inline call must use a purpose-built single-op module, or the
///  just-in-time same-block grant pattern ({PositionFunnel.grant} +
///  {FunnelGrantModule}), where the allowance cannot outlive the fill that uses it.
///
///  The guard against regression is the absence of a Permit3 reference in this file.
///  Adding one back re-opens the drain above.
///
///  ⚠ POKES THAT PAY `msg.sender` (audit 2026-09-30 MISC-MOD-5)
///  ───────────────────────────────────────────────────────────
///  Many `harvest()`/`poke()` entrypoints pay an incentive to their caller (Convex
///  `earmarkRewards`, keeper bounties). Run through this module, the caller IS this
///  shared contract, so the bounty used to land here — and anything on this address
///  is claimable by the next self-signed order that calls `token.transfer(self, …)`.
///  A maker expecting such a bounty names its token in `CallSpec.bountyToken`: the
///  module floors its own balance of that token before the call and forwards the
///  increase to the maker (`onBehalfOf`) in the same item. Pre-existing balance is
///  never touched. With `bountyToken == address(0)` nothing is forwarded, so only
///  use that for targets that pay nobody — or pay `tx.origin` / a named recipient. A
///  NATIVE-ETH bounty cannot land here at all (no `receive`), so such a call reverts.
contract PermissionlessCallModule is IMakerModule {
    address public immutable SETTLEMENT;

    error OnlySettlement();
    error CallFailed(bytes ret);

    /// @param target      contract to invoke.
    /// @param callData    exact calldata for `target`. Part of the maker-signed
    ///                    `Item.data`, so authorised by construction — but see the
    ///                    contract note: "authorised by the order's maker" is NOT the
    ///                    same as "safe", because every address can be a maker.
    /// @param bountyToken ERC-20 the call may pay THIS module as its caller; the
    ///                    module's balance increase of it is forwarded to the maker.
    ///                    `address(0)` = the call pays no bounty. (BREAKING: added by
    ///                    audit 2026-09-30 MISC-MOD-5.)
    struct CallSpec {
        address target;
        bytes callData;
        address bountyToken;
    }

    constructor(address settlement) {
        SETTLEMENT = settlement;
    }

    /// @inheritdoc IMakerModule
    /// @dev `amount` is deliberately unused: with no funding leg there is nothing to
    ///      pull and nothing to size. The item's `amount` still governs WHETHER this
    ///      runs — `Base._runItem` skips a slice that floors to zero — so a maker can
    ///      still make the poke proportional to the fill by signing a per-fill
    ///      amount. `onBehalfOf` (the maker, supplied by Settlement) is only the
    ///      destination of a forwarded bounty.
    function makeOnBehalf(address onBehalfOf, uint256, bytes calldata data) external override {
        if (msg.sender != SETTLEMENT) revert OnlySettlement();
        CallSpec memory spec = abi.decode(data, (CallSpec));
        address bounty = spec.bountyToken;
        uint256 floor = bounty == address(0) ? 0 : SafeTransferLib.balanceOf(bounty, address(this));
        (bool ok, bytes memory ret) = spec.target.call(spec.callData);
        if (!ok) revert CallFailed(ret);
        if (bounty != address(0)) {
            uint256 bal = SafeTransferLib.balanceOf(bounty, address(this));
            if (bal > floor) SafeTransferLib.safeTransfer(bounty, onBehalfOf, bal - floor);
        }
    }
}
