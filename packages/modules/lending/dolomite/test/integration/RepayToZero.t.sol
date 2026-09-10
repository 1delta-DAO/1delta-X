// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {DolomiteModulesBase} from "../shared/DolomiteModulesBase.t.sol";

/// @dev Repay-to-zero coverage for {DolomiteRepayModule}.
///
/// Dolomite has NO "repay all" sentinel: the module reads the live debt
/// (`getAccountWei`) and clamps `min(amount, debt)`, then deposits exactly that
/// many Wei back. Two properties have to hold for a full close to actually
/// close, and neither is implied by the leverage tests:
///
///   1. Over-funding does not over-repay. The clamp must cap the pull at the live
///      debt so the maker is never charged for more than they owe (and the
///      account is never pushed positive by a stale quote).
///   2. The clamp lands on EXACTLY zero. Dolomite stores balances as Par and
///      converts on the way in, so a Wei-denominated `Delta` deposit is a
///      rounding surface — 1 wei of residual debt here is what keeps a position
///      alive after a "full" close, and it accrues.
///
/// Interest is accrued with a warp before the repay so the live debt is strictly
/// above the opening principal: that is the case where a caller quoting the
/// opening amount under-repays, and the case where the clamp is a no-op.
contract DolomiteRepayToZeroTest is DolomiteModulesBase {
    uint256 constant COLLATERAL = 5 ether;
    uint256 constant PRINCIPAL = 1_000e6;

    function _repayData() internal view returns (bytes memory) {
        return abi.encode(address(DOLOMITE), DEBT_MARKET, DEBT, ACCOUNT);
    }

    /// @dev Fund the maker and open the Permit3 token allowance the repay module pulls on.
    function _fundRepay(uint256 amount) internal {
        deal(DEBT, maker, amount);
        vm.prank(maker);
        permit3.approveToken(address(repayModule), DEBT, uint160(amount), 0);
    }

    function test_dolomite_repay_full_leavesExactlyZeroDebt() public {
        _neutralizeRiskOverride();
        _openDolomitePosition(COLLATERAL, PRINCIPAL);

        // Accrue: the live debt is now strictly above the opening principal.
        _freezeOracles();
        vm.warp(block.timestamp + 30 days);
        uint256 debt = _debtOf(maker);
        assertGt(debt, PRINCIPAL, "interest accrued past the principal");

        // Over-fund deliberately: the module must clamp to the live debt.
        uint256 ceiling = debt + 100e6;
        _fundRepay(ceiling);
        uint256 makerBefore = IERC20(DEBT).balanceOf(maker);

        vm.prank(address(settlement));
        repayModule.makeOnBehalf(maker, ceiling, _repayData());

        assertEq(_debtOf(maker), 0, "debt closed to exactly zero");
        assertEq(makerBefore - IERC20(DEBT).balanceOf(maker), debt, "maker charged the live debt, not the ceiling");
        assertEq(IERC20(DEBT).balanceOf(address(repayModule)), 0, "repay module holds no residual");
        assertEq(IERC20(DEBT).allowance(address(repayModule), address(DOLOMITE)), 0, "scoped grant cleared");
    }

    /// @dev Quoting the *opening* principal after interest accrued under-repays —
    ///      the residual is the accrued interest, and the position stays open.
    ///      This is the counterpart the "repay all" callers must avoid.
    function test_dolomite_repay_stalePrincipal_leavesAccruedInterest() public {
        _neutralizeRiskOverride();
        _openDolomitePosition(COLLATERAL, PRINCIPAL);

        _freezeOracles();
        vm.warp(block.timestamp + 30 days);
        uint256 debt = _debtOf(maker);

        _fundRepay(PRINCIPAL);

        vm.prank(address(settlement));
        repayModule.makeOnBehalf(maker, PRINCIPAL, _repayData());

        uint256 left = _debtOf(maker);
        assertGt(left, 0, "stale principal cannot close the position");
        assertApproxEqAbs(left, debt - PRINCIPAL, 2, "residual is the accrued interest");
    }

    function test_dolomite_repay_partial_reducesDebt() public {
        _neutralizeRiskOverride();
        _openDolomitePosition(COLLATERAL, PRINCIPAL);

        uint256 debt = _debtOf(maker);
        uint256 part = PRINCIPAL / 2;
        _fundRepay(part);
        uint256 makerBefore = IERC20(DEBT).balanceOf(maker);

        vm.prank(address(settlement));
        repayModule.makeOnBehalf(maker, part, _repayData());

        assertEq(makerBefore - IERC20(DEBT).balanceOf(maker), part, "maker charged exactly the partial amount");
        assertApproxEqAbs(_debtOf(maker), debt - part, 2, "debt reduced by the partial amount");
        assertEq(IERC20(DEBT).balanceOf(address(repayModule)), 0, "repay module holds no residual");
    }
}
