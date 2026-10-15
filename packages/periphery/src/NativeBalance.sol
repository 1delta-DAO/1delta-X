// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title NativeBalance
/// @notice A READ-ONLY view of native currency shaped like the one ERC-20 function
///         a DIRECT (delta-verify) output leg needs: `balanceOf(a) == a.balance`.
///         Signing `legsOut[j].token = NativeBalance` on a DIRECT order (`timing`
///         bit 104, {DutchAuction.deltaVerifyOutputs}) asks for RAW NATIVE COIN in
///         the recipient's wallet with no Settlement change, no item, no module hop
///         and no filler capital (docs/native-rbtc-delivery-plan.md, task 30).
///
///  WHY IT WORKS ON THE DIRECT PATH
///  ───────────────────────────────
///  For a delta-verify order Settlement never moves the output token. It reads
///  `balanceOf(token, recipient)` (a staticcall) before the filler's callback,
///  again after it, and requires the increase to reach the priced amount
///  (`Core._snapshotOutRecipients` / `_deliverOutputs`, `DeltaTooLow` otherwise).
///  Both reads are this function, so the check becomes "the recipient's native
///  balance rose by at least the priced amount" — the filler delivers native coin
///  out of band (the {AggregatorFillSolver} unwraps its route's WNATIVE output and
///  sends it) and the core verifies the receipt, unchanged.
///
///  WHY IT FAILS CLOSED EVERYWHERE ELSE — by having NOTHING but two views
///  ──────────────────────────────────────────────────────────────────────
///  There is no `transfer`, `transferFrom`, `approve`, `allowance`, `totalSupply`
///  and no `fallback` / `receive`. Every Settlement path that would MOVE this
///  "token" therefore calls a function that does not exist, and the call reverts:
///    • a PULL output leg (no bit 104): the core pulls the leg from the filler —
///      Permit3 `transferFrom`, then the direct `transferFrom` fallback — both
///      revert, so the fill reverts. It can never be "delivered" by a transfer;
///    • an INPUT leg: the maker's pull is the same `transferFrom` — reverts. The
///      maker can never "pay" in it;
///    • a DIRECT order that also names it as an input token: the core refuses the
///      shape at the snapshot (`DeltaVerifySameToken`) before anything moves;
///    • `matchSettle`: a delta-verify order is refused at open
///      (`DeltaVerifyNotBatchable`), and a pull-shaped one reverts on the pool's
///      delivery `transfer` (or on the input pull).
///  So it is meaningful ONLY as a DIRECT output leg, which is what makes it safe
///  to list as a token at all: no path can treat a view as value.
///
///  INFLOW ATTRIBUTION is the delta-verify rule's, nothing new: only the order's
///  named `exclusiveFiller` can run the callback across which the balance is
///  measured (re-audit 2026-09-25), so no foreign native inflow can pass as this
///  delivery. The recipient's balance cannot FALL during the fill (it is not the
///  transaction's sender, so it pays no gas); a contract recipient that spends
///  native inside its own `receive()` lowers the measured delta and the fill
///  reverts — fail closed. A recipient whose `receive()` reverts kills the fill
///  (the posture of every in-fill native send, e.g. `NativeUnwrapModule`).
///
/// @dev Stateless and ownerless: no storage, no constructor, no admin. Deploy once
///      per chain by plain CREATE; every order on the chain may name the same one.
///      `decimals()` is for wallets and UIs (native coin has 18 on every EVM chain
///      this repo targets); no core path reads it.
contract NativeBalance {
    /// @notice `a`'s native balance — the only thing a delta-verify output leg reads.
    function balanceOf(address a) external view returns (uint256) {
        return a.balance;
    }

    /// @notice 18, the native coin's precision — for UIs only.
    function decimals() external pure returns (uint8) {
        return 18;
    }
}
