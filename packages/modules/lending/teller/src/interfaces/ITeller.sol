// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ──────────────────── Minimal Teller V2 surface ────────────────────
//
// Teller V2 (pooled `LenderCommitmentGroup` model). Only the permissionless
// value-in legs fit the atomic on-behalf module mechanic:
//
//   • pool `deposit(assets, receiver)` — ERC-4626 liquidity provision (V2/V3).
//   • `repayLoan(bidId, amount)` / `repayLoanFull(bidId)` — permissionless: anyone
//     may repay a borrower's loan, so the module funds the maker's repay.
//
// BORROW and WITHDRAW do NOT fit (see README):
//   • Borrow (`acceptSmartCommitmentWithRecipient`) attributes the loan to the
//     forwarder's ERC-2771 `_msgSender`, so a module cannot incur debt FOR the
//     maker; it is also gated by a Hypernative oracle firewall + borrower
//     attestation.
//   • Pool withdraw enforces a per-owner cooldown → not atomically expressible.
interface ITellerPool {
    /// @notice ERC-4626 supply into a V2/V3 LenderCommitmentGroup pool.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
}

interface ITellerV2 {
    /// @notice Partial repay; collateral stays escrowed. Permissionless.
    function repayLoan(uint256 bidId, uint256 amount) external;
    /// @notice Repay principal+interest AND release all collateral. Permissionless.
    function repayLoanFull(uint256 bidId) external;
}
