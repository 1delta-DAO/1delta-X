// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ──────────────────── Minimal Teller V2 surface ────────────────────
//
// Teller V2 (pooled `LenderCommitmentGroup` model). Only the value-in legs fit
// the atomic on-behalf module mechanic:
//
//   • pool `deposit(assets, receiver)` — ERC-4626 liquidity provision (V2/V3).
//     NOT permissionless for a contract caller: Hypernative-firewalled (below).
//   • `repayLoan(bidId, amount)` / `repayLoanFull(bidId)` — permissionless: anyone
//     may repay a borrower's loan, so the module funds the maker's repay.
//
// BORROW and WITHDRAW do NOT fit (see README):
//   • Borrow (`acceptSmartCommitmentWithRecipient`) attributes the loan to the
//     forwarder's ERC-2771 `_msgSender`, so a module cannot incur debt FOR the
//     maker; it is also gated by a Hypernative oracle firewall + borrower
//     attestation.
//   • Pool withdraw enforces a per-owner cooldown → not atomically expressible.
//
// ⚠ POOL DEPOSIT IS FIREWALLED. V2/V3 `deposit` carries `onlyOracleApprovedAllowEOA`:
// for a contract caller (every module, which is never `tx.origin`) the pool's
// ORACLE_MANAGER (the SmartCommitmentForwarder) requires the caller to be
// registered with the Hypernative oracle and past its threshold, else it reverts
// "Account not registered". Registration (`SCF.oracleRegister(module)`) is public
// and is a per-chain DEPLOY STEP for each deposit module — see the README.
interface ITellerPool {
    /// @notice ERC-4626 supply into a V2/V3 LenderCommitmentGroup pool.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
}

/// @notice `calculateAmountOwed`'s return shape (TellerV2 `Payment`).
struct TellerPayment {
    uint256 principal;
    uint256 interest;
}

interface ITellerV2 {
    /// @notice Partial repay; collateral stays escrowed. Permissionless.
    /// @dev ⚠ DOES NOT CLAMP AN OVERPAYMENT. The deployed implementation (mainnet
    ///      impl 0x37f483c8…b002, and the Base / Arbitrum / Polygon impls, all equal
    ///      to teller-protocol-v2 `develop`) builds `Payment{principal: amount −
    ///      interest, interest}`, caps only a LOCAL copy at the owed amount (used for
    ///      the PAID transition), then `_sendOrEscrowFunds` transfers the UNCAPPED
    ///      `amount` from the caller to the lender. Anything above the live debt is
    ///      the lender's — there is no refund path. (The 2023-03 snapshot did
    ///      transfer the capped amount; it is not what is deployed.) Callers must
    ///      therefore never pass more than {calculateAmountOwed}; the modules route
    ///      `amount ≥ owed` to {repayLoanFull} instead (2026-09-30 audit, L-CMT-1).
    ///      Also reverts `PaymentNotMinimum` when `amount` is below the current
    ///      cycle's minimum due (`duePrincipal + interest`).
    function repayLoan(uint256 bidId, uint256 amount) external;
    /// @notice Repay principal+interest AND release all collateral. Permissionless.
    ///         Pulls EXACTLY the live owed amount.
    function repayLoanFull(uint256 bidId) external;
    /// @notice The live amount owed on `bidId` at `timestamp` (principal + accrued
    ///         interest). Public view on TellerV2.
    function calculateAmountOwed(uint256 bidId, uint256 timestamp) external view returns (TellerPayment memory);
    /// @notice The loan's borrower (`bids[bidId].borrower`). Public view on TellerV2;
    ///         the repay modules bind it to the maker.
    function getLoanBorrower(uint256 bidId) external view returns (address borrower);
}
