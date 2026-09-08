// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title Narrow160
/// @notice One narrowing for an amount that is pulled AND approved.
///
///  The defect this closes (F26/2d)
///  ───────────────────────────────
///  Every funding module pulls with `permit3.transferFrom(..., uint160(x))` and
///  then approves the SAME `x` un-narrowed:
///
///      permit3.transferFrom(user, address(this), asset, uint160(x));  // CLIPPED
///      SafeTransferLib.forceApprove(asset, target, x);                // NOT clipped
///
///  For most sites that is harmless because the amount came from the core, which
///  already width-checks it (`Base._runItem` on `slice`, `Base._dispatchTake` on
///  `forSlice`). It is NOT harmless where the amount is decoded from the order's
///  `data`, which the core never sees: `x = 2^160 + 1` pulls ONE WEI and approves
///  ~1.46e48 to a target the same `data` names.
///
///  ⚠ Enumerate these by the PROVENANCE of the amount, never by the shape of the
///  call. 23 pull/approve pairs share the syntax; only the handful whose amount
///  bypasses the core's width check are exploitable, and a sweep that "fixes" all
///  23 adds churn while a sweep that trusts a hand-listed 6 misses one.
library Narrow160 {
    /// @dev The maker-signed amount does not fit the Permit3 pull width, so the
    ///      pull and the approve would disagree.
    error AmountOverflow();

    /// @param x an amount that will be both pulled (narrowed) and approved (wide)
    /// @return the same value as a `uint160`, or a revert — never a silent wrap
    function to160(uint256 x) internal pure returns (uint160) {
        if (x > type(uint160).max) revert AmountOverflow();
        return uint160(x);
    }
}
