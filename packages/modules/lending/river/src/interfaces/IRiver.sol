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
// Fund flow — ✅ FORK-VALIDATED on the deployed diamond (BSC/Hemi, 0x07Bb…AA4Ec):
//   • value-in: `addColl` / `openTrove` collateral is pulled from `msg.sender` (the
//     module); `repayDebt` BURNS satUSD from `msg.sender` with NO allowance.
//   • value-out (`withdrawColl`, `withdrawDebt`, `openTrove` debt) lands on
//     `msg.sender` — the MODULE when a delegate drives the op — not on `account`
//     as the Prisma lineage documents. The ops carry NO receiver.
// The taker modules settle direction-agnostically ({RiverProceeds.settle}): pay
// `receiver` from what landed on the module, fall back to a Permit3 sweep from the
// maker only on a deployment that routes to `account`, revert on under-delivery.
// `repayDebt` enforces a minimum NET debt: retiring the whole debt reverts (a full
// close is `closeTrove`).
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
    /// @notice The debt token this TroveManager's troves are denominated in —
    ///         `IDebtToken public debtToken` in the Prisma lineage. Verified on BSC:
    ///         TM 0x5EA26D0A1a9aa6731F9BFB93fCd654cd1C3079Ec →
    ///         `debtToken() == 0xb4818BB69478730EF4e33Cc068dD94278e2766cB` (satUSD).
    ///         The repay legs pin the maker-named token to this.
    function debtToken() external view returns (address);
}
