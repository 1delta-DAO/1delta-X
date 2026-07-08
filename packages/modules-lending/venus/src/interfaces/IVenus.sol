// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ──────────────────── Minimal Venus (expanded Compound v2) surface ────────────────────
//
// Venus is a Compound v2 fork whose cToken (here `vToken`) holds a position keyed
// to `msg.sender`: `mint`/`redeem`/`borrow`/`repayBorrow` all act on the caller.
// Plain Compound v2 therefore can't act on another account's behalf — but Venus
// EXPANDS the fork with an explicit on-behalf + delegation layer, which is what
// makes it fit the maker/taker module model:
//
//   • value-in (no delegation needed — anyone may fund another's position):
//       mintBehalf(receiver, amount)          pulls underlying from msg.sender,
//                                             credits vTokens to `receiver`.
//       repayBorrowBehalf(borrower, amount)   pulls underlying from msg.sender,
//                                             pays down `borrower`'s debt.
//
//   • value-out (gated by `comptroller.updateDelegate(delegate, true)` from the
//     account owner — the Venus analogue of Comet `allow` / Euler operator):
//       borrowBehalf(borrower, amount)        records debt on `borrower`,
//                                             sends underlying to msg.sender.
//       redeemUnderlyingBehalf(redeemer, amt) burns `redeemer`'s vTokens for an
//                                             exact underlying amount to msg.sender.
//       redeemBehalf(redeemer, vTokens)       burns an exact vToken amount,
//                                             underlying to msg.sender.
//
// Compound-fork convention: these return a `uint` error code (0 == success)
// rather than reverting on protocol-state rejections, so every call site checks
// the code. (Internal transfer failures still revert.)

interface IVToken {
    // ── value in (permissionless on-behalf) ──
    function mintBehalf(address receiver, uint256 mintAmount) external returns (uint256);
    function repayBorrowBehalf(address borrower, uint256 repayAmount) external returns (uint256);

    // ── value out (requires `updateDelegate`); proceeds go to msg.sender ──
    function borrowBehalf(address borrower, uint256 borrowAmount) external returns (uint256);
    function redeemUnderlyingBehalf(address redeemer, uint256 redeemAmount) external returns (uint256);
    function redeemBehalf(address redeemer, uint256 redeemTokens) external returns (uint256);

    // ── views / accruers ──
    function underlying() external view returns (address);
    /// @notice vToken (receipt) balance.
    function balanceOf(address owner) external view returns (uint256);
    /// @notice Underlying value of the account's vTokens (accrues — NOT a view).
    function balanceOfUnderlying(address owner) external returns (uint256);
    /// @notice Present value of the account's borrow (accrues — NOT a view).
    function borrowBalanceCurrent(address account) external returns (uint256);
    /// @notice Borrow value from storage (view; stale until the next accrue).
    function borrowBalanceStored(address account) external view returns (uint256);
    /// @notice vToken/underlying exchange rate from storage (view).
    function exchangeRateStored() external view returns (uint256);
}

interface IVenusComptroller {
    /// @notice Grant/revoke `delegate` the right to borrow/redeem on the caller's
    ///         behalf — the authorisation the value-out modules require.
    function updateDelegate(address delegate, bool approved) external;
    function approvedDelegates(address borrower, address delegate) external view returns (bool);
    /// @notice Enter markets so supplied vTokens count as collateral.
    function enterMarkets(address[] calldata vTokens) external returns (uint256[] memory);
}
