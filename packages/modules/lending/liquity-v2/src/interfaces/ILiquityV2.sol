// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ──────────────────── Minimal Liquity V2 surface ────────────────────
//
// Liquity V2 (and forks: Felix, Quill, Nerite, …) — troves are ERC-721 sub-
// accounts under a per-branch `BorrowerOperations`. `troveId =
// keccak256(sender, owner, ownerIndex)`.
//
// Delegation is per-trove and splits by direction — a clean map onto MAKE/TAKE:
//   • `setAddManager(troveId, module)` — lets the module ADD collateral / REPAY
//     (the MAKE legs).
//   • `setRemoveManagerWithReceiver(troveId, module, receiver)` — lets the module
//     WITHDRAW collateral / BORROW (the TAKE legs) with proceeds forced to
//     `receiver`. The maker sets `receiver = module`, so the value-out lands on
//     the module, which forwards it to the order's `receiver`.
//
// `withdrawColl`/`withdrawBold`/`addColl`/`repayBold` carry NO receiver — the
// destination is the trove's configured receiver. BOLD is privileged (no
// approval needed to burn/mint); collateral needs an ERC20 approval.
interface ILiquityV2BorrowerOperations {
    function addColl(uint256 _troveId, uint256 _collAmount) external;
    function withdrawColl(uint256 _troveId, uint256 _amount) external;
    function withdrawBold(uint256 _troveId, uint256 _amount, uint256 _maxUpfrontFee) external;
    function repayBold(uint256 _troveId, uint256 _amount) external;
    function closeTrove(uint256 _troveId) external;

    function setAddManager(uint256 _troveId, address _manager) external;
    function setRemoveManagerWithReceiver(uint256 _troveId, address _manager, address _receiver) external;
}

/// @notice `getLatestTroveData` first field = the entire (accrued) debt.
struct LatestTroveData {
    uint256 entireDebt;
    uint256 entireColl;
    uint256 redistBoldDebtGain;
    uint256 redistCollGain;
    uint256 accruedInterest;
    uint256 recordedDebt;
    uint256 annualInterestRate;
    uint256 weightedRecordedDebt;
    uint256 accruedBatchManagementFee;
    uint256 lastInterestRateAdjTime;
}

interface ILiquityV2TroveManager {
    function getLatestTroveData(uint256 _troveId) external view returns (LatestTroveData memory);
    function getTroveStatus(uint256 _troveId) external view returns (uint256);
}
