// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ──────────────────── Minimal River (Satoshi) surface ────────────────────
//
// River (Satoshi Protocol) mints satUSD behind ONE SatoshiXApp diamond per chain.
// EVERY borrower op targets the diamond (`xapp`) and takes the per-collateral
// `troveManager` as its first arg. Troves are keyed by OWNER ADDRESS (≤1 per user
// per TroveManager — no id/discovery).
//
// Delegation: a single diamond-wide boolean `setDelegateApproval(module, true)`.
// Every op takes an `account` and passes the caller-or-delegate check, so an
// approved module drives the FULL borrower surface for `account`.
//
// Fund flow (Prisma/Liquity-V1 lineage): value-in (`addColl`, `repayDebt`,
// `openTrove` collateral) is pulled from `msg.sender` (the module, which funds it
// via a Permit3 pull from the maker); value-out (`withdrawColl`, `withdrawDebt`,
// `openTrove` debt) lands on `account` (the maker) — the ops carry NO receiver.
// The taker modules therefore Permit3-sweep the proceeds from the maker to the
// order's `receiver`.
interface IRiverXApp {
    function openTrove(
        address troveManager,
        address account,
        uint256 _maxFeePercentage,
        uint256 _collateralAmount,
        uint256 _debtAmount,
        address _upperHint,
        address _lowerHint
    ) external;

    function addColl(
        address troveManager,
        address account,
        uint256 _collateralAmount,
        address _upperHint,
        address _lowerHint
    ) external;

    function withdrawColl(
        address troveManager,
        address account,
        uint256 _collWithdrawal,
        address _upperHint,
        address _lowerHint
    ) external;

    function withdrawDebt(
        address troveManager,
        address account,
        uint256 _maxFeePercentage,
        uint256 _debtAmount,
        address _upperHint,
        address _lowerHint
    ) external;

    function repayDebt(
        address troveManager,
        address account,
        uint256 _debtAmount,
        address _upperHint,
        address _lowerHint
    ) external;

    function closeTrove(address troveManager, address account) external;

    function setDelegateApproval(address _delegate, bool _isApproved) external;
    function isApprovedDelegate(address _account, address _delegate) external view returns (bool);
}

interface IRiverTroveManager {
    function getEntireDebtAndColl(address _borrower)
        external
        view
        returns (uint256 debt, uint256 coll, uint256 pendingDebtReward, uint256 pendingCollateralReward);
    function getTroveStatus(address _borrower) external view returns (uint256);
    function collateralToken() external view returns (address);
}
