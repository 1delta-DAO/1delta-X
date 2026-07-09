// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ──────────────────── Minimal Compound v2 surface ────────────────────
//
// Vanilla Compound v2 (cToken) keys every position to `msg.sender`:
//   • mint(amount)             pulls underlying from the caller, mints cTokens
//                              TO THE CALLER (no `mintBehalf`).
//   • redeem / redeemUnderlying burns the caller's cTokens, underlying to caller.
//   • borrow(amount)           records debt on the caller, underlying to caller —
//                              there is NO `borrowBehalf`/delegation in vanilla
//                              Compound v2 (that is a Venus extension), so a router
//                              CANNOT borrow on a user's behalf. Hence this package
//                              ships no borrow module.
//   • repayBorrowBehalf(borrower, amount)  the ONE native on-behalf call: anyone
//                              may pay down `borrower`'s debt.
//
// Because mint/redeem act on the caller, the deposit module mints to ITSELF and
// forwards the cTokens to the user, and the withdraw module pulls the user's
// cTokens (via Permit3) before redeeming — the cToken is the user-held receipt,
// exactly like an Aave aToken, but NOT 1:1 with the underlying (an `exchangeRate`
// applies, so the withdraw module converts).
//
// Compound-fork convention: these return a `uint` error code (0 == success)
// rather than reverting on protocol-state rejections, so every call site checks
// the code. (Internal transfer failures still revert.)

interface ICErc20 {
    // ── value in ──
    /// @notice Pulls `mintAmount` underlying from msg.sender, mints cTokens to msg.sender.
    function mint(uint256 mintAmount) external returns (uint256);
    /// @notice Repays `borrower`'s debt, funded by msg.sender (permissionless on-behalf).
    function repayBorrowBehalf(address borrower, uint256 repayAmount) external returns (uint256);

    // ── value out (act on msg.sender; no on-behalf variant) ──
    function redeem(uint256 redeemTokens) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);

    // ── views / accruers ──
    function underlying() external view returns (address);
    /// @notice cToken (receipt) balance.
    function balanceOf(address owner) external view returns (uint256);
    /// @notice Present value of the account's borrow (accrues — NOT a view).
    function borrowBalanceCurrent(address account) external returns (uint256);
    /// @notice Borrow value from storage (view; stale until the next accrue).
    function borrowBalanceStored(address account) external view returns (uint256);
    /// @notice cToken/underlying exchange rate, accrued to now (NOT a view). Scaled
    ///         by 1e18: underlying = cTokens * exchangeRate / 1e18.
    function exchangeRateCurrent() external returns (uint256);
    /// @notice Exchange rate from storage (view; stale until the next accrue).
    function exchangeRateStored() external view returns (uint256);
}

interface ICompoundV2Comptroller {
    /// @notice Enter markets so supplied cTokens count as collateral.
    function enterMarkets(address[] calldata cTokens) external returns (uint256[] memory);
}

// ──────────────────── cEther (the native pool) ────────────────────
//
// The native-currency market (cETH and fork equivalents). Its value-IN calls take
// NATIVE ETH via `msg.value` (no ERC20/amount arg) and REVERT on error (unlike the
// cErc20 code-returning convention); value-OUT (`redeem*`) still returns a code and
// sends ETH to the caller. cEther is itself an ERC20 cToken, so its receipt balance
// and transfers go through the standard `IERC20` surface.
interface ICEther {
    /// @notice Supplies `msg.value` ETH, mints cTokens to msg.sender. Reverts on error.
    function mint() external payable;
    /// @notice Repays `borrower`'s ETH debt, funded by `msg.value` (on-behalf). Reverts
    ///         on error. cEther caps at the debt via SafeMath, so an over-send reverts —
    ///         the caller must send exactly `min(intended, liveDebt)`.
    function repayBorrowBehalf(address borrower) external payable;

    // ── value out (act on msg.sender; ETH sent to caller) ──
    function redeem(uint256 redeemTokens) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);

    // ── borrow (self only — no delegation; used by tests to seed a debt) ──
    function borrow(uint256 borrowAmount) external returns (uint256);

    // ── views / accruers ──
    function borrowBalanceCurrent(address account) external returns (uint256);
    function borrowBalanceStored(address account) external view returns (uint256);
    function exchangeRateCurrent() external returns (uint256);
    function exchangeRateStored() external view returns (uint256);
}
