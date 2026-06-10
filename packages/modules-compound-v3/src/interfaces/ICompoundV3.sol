// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ──────────────────── Minimal Compound v3 (Comet) surface ────────────────────
//
// Each Comet market has ONE base asset (borrowable/lendable, e.g. USDC) and a
// set of collateral assets. The same four methods cover both sides of every
// position:
//
//   • supplyTo(dst, asset, amount)
//       asset == base       → lend base / repay an outstanding base borrow
//       asset == collateral → post collateral
//   • withdrawFrom(src, to, asset, amount)
//       asset == base       → withdraw a base supply, or BORROW past it
//       asset == collateral → withdraw collateral
//
// That is why this package's four named modules collapse onto two underlying
// calls: deposit/repay both `supplyTo`, withdraw/borrow both `withdrawFrom`.
//
// Authorisation for the `*From` (value-out) side is the account-manager flag
// `allow(manager, true)` — the Comet-native analogue of Aave's credit
// delegation + aToken approval, here a single boolean covering the whole
// position. Permit3's taker allowance is what caps the per-fill amount.

interface IComet {
    // ── value in ──
    function supply(address asset, uint256 amount) external;
    function supplyTo(address dst, address asset, uint256 amount) external;

    // ── value out ──
    function withdraw(address asset, uint256 amount) external;
    /// @notice Value-out on behalf of `src` — requires `allow(msg.sender, true)` from `src`.
    function withdrawFrom(address src, address to, address asset, uint256 amount) external;

    // ── account-manager authorisation ──
    function allow(address manager, bool isAllowed) external;

    // ── views ──
    function baseToken() external view returns (address);
    /// @notice Base supply balance (0 while the account is borrowing).
    function balanceOf(address account) external view returns (uint256);
    /// @notice Present value of the account's base borrow (0 while supplying).
    function borrowBalanceOf(address account) external view returns (uint256);
    /// @notice Collateral balance for a specific collateral asset.
    function collateralBalanceOf(address account, address asset) external view returns (uint128);
}
