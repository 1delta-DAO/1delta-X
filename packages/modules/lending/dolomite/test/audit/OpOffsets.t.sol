// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {DustHandler} from "@lib/DustHandler.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";

import {AccountInfo, WeiBalance} from "../../src/interfaces/IDolomite.sol";
import {DolomiteOperatorModule} from "../../src/DolomiteOperatorModule.sol";
import {DolomiteModulesBase} from "../shared/DolomiteModulesBase.t.sol";

/// @dev THE OFFSETS THE MERGE MOVED, PINNED BY EXECUTION.
///
///  Prepending the op word to every single-op blob shifted each trailing optional
///  field by 32 bytes: the withdraw's `BalanceMode` 128→160 and its `total`
///  160→192, the repay's `DustAction` 128→160. Nothing in the suite executed those
///  branches — `Full` withdraw, `Recycle` repay and `BatchClose` had zero
///  non-revert tests — so a wrong offset would have shipped silently: a `Full`
///  order read as `Exact` withdraws the signed amount instead of the position, a
///  `Recycle` read as `SweepToUser` leaves the surplus in the wallet, and neither
///  reverts.
///
///  Each test here takes the branch that only the CORRECT offset can reach, and
///  asserts the venue state that only that branch produces. The modules are called
///  directly as their dispatcher (Settlement for MAKE, Permit3 for TAKE), the way
///  {DolomiteRepayToZeroTest} already does; the gating itself is pinned in
///  `security/TakerModuleAuth.t.sol`.
contract DolomiteOpOffsetsTest is DolomiteModulesBase {
    uint256 constant COLLATERAL = 5 ether;
    uint256 constant PRINCIPAL = 1_000e6;
    address receiver = address(0xCAFE);

    function _repayData(DustHandler.DustAction action) internal view returns (bytes memory) {
        // op@0 … accountNumber@128, DustAction@160
        return abi.encode(uint8(DolomiteOperatorModule.Op.Repay), address(DOLOMITE), DEBT_MARKET, DEBT, ACCOUNT, uint8(action));
    }

    function _withdrawFullData(uint256 total) internal view returns (bytes memory) {
        // op@0 … accountNumber@128, BalanceMode@160, total@192
        return abi.encode(
            uint8(DolomiteOperatorModule.Op.Withdraw),
            address(DOLOMITE),
            COLL_MARKET,
            COLL,
            ACCOUNT,
            // TAGGED, via `encodeMode` — a bare `1` is rejected as `InvalidModeWord`, by
            // design, so that a field nobody filled in can never select the lenient mode.
            // This also makes the test unambiguous: `accountNumber` at 128 is ALSO `1`,
            // so a `Full` result can only come from reading the tagged word at 160.
            DustHandler.encodeMode(DustHandler.BalanceMode.Full),
            total
        );
    }

    function _debtMarketWei(address who) internal view returns (WeiBalance memory) {
        return DOLOMITE.getAccountWei(AccountInfo(who, ACCOUNT), DEBT_MARKET);
    }

    // ──────────────────── Withdraw: BalanceMode@160, total@192 ────────────────────

    /// @dev `Full` withdraws the WHOLE live position, not the signed amount. Signing
    ///      `amount` well UNDER the position and asserting the position ends at zero
    ///      is what proves the mode was read from word 160 — an `Exact` read would
    ///      leave `COLLATERAL - amount` behind.
    function test_withdraw_full_readsModeAt160_andTotalAt192() public {
        _seedDolomiteCollateral(COLLATERAL);
        uint256 amount = COLLATERAL / 2;

        vm.prank(address(permit3));
        operatorModule.takeOnBehalf(maker, amount, receiver, _withdrawFullData(amount));

        assertEq(_collateralOf(maker), 0, "Full: the ENTIRE position was withdrawn (mode read at 160)");
        assertEq(IERC20(COLL).balanceOf(receiver), amount, "receiver got the signed amount");
        assertEq(IERC20(COLL).balanceOf(maker), COLLATERAL - amount, "excess swept back to the maker");
        assertEq(IERC20(COLL).balanceOf(address(operatorModule)), 0, "module drained");
    }

    /// @dev The mandatory `total` at 192 is what {FullFillGuard} compares the slice
    ///      against. A slice that is not the whole item must fail CLOSED, with the
    ///      guard's error — which can only happen if `total` was read from 192.
    function test_withdraw_full_slicedFill_failsClosedOnTotalAt192() public {
        _seedDolomiteCollateral(COLLATERAL);
        uint256 total = COLLATERAL;
        uint256 slice = COLLATERAL / 3;

        vm.prank(address(permit3));
        vm.expectRevert(abi.encodeWithSelector(FullFillGuard.PartialFillUnsupported.selector, slice, total));
        operatorModule.takeOnBehalf(maker, slice, receiver, _withdrawFullData(total));
    }

    /// @dev And the control: with no mode word, `Exact` withdraws exactly `amount`.
    function test_withdraw_exact_leavesTheRemainder() public {
        _seedDolomiteCollateral(COLLATERAL);
        uint256 amount = COLLATERAL / 2;

        vm.prank(address(permit3));
        operatorModule.takeOnBehalf(maker, amount, receiver, _withdrawData());

        assertEq(_collateralOf(maker), COLLATERAL - amount, "Exact: only the signed amount left the position");
        assertEq(IERC20(COLL).balanceOf(receiver), amount);
    }

    // ──────────────────── Repay: DustAction@160 ────────────────────

    /// @dev `Recycle` pulls the FULL signed ceiling and re-supplies the surplus into
    ///      the position. The surplus therefore ends up as a POSITIVE balance in the
    ///      debt market of the sub-account — a state `SweepToUser` can never
    ///      produce, because it never pulls the surplus at all. That is the
    ///      observable that proves the action word was read from 160.
    function test_repay_recycle_readsActionAt160_resuppliesSurplus() public {
        _neutralizeRiskOverride();
        _openDolomitePosition(COLLATERAL, PRINCIPAL);
        _freezeOracles();

        uint256 debt = _debtOf(maker);
        uint256 surplus = 250e6;
        uint256 ceiling = debt + surplus;
        deal(DEBT, maker, ceiling);
        vm.prank(maker);
        permit3.approveToken(address(operatorModule), DEBT, uint160(ceiling), 0);

        vm.prank(address(settlement));
        operatorModule.makeOnBehalf(maker, ceiling, _repayData(DustHandler.DustAction.Recycle));

        assertEq(_debtOf(maker), 0, "debt closed");
        WeiBalance memory w = _debtMarketWei(maker);
        assertTrue(w.sign, "Recycle: the surplus was RE-SUPPLIED (positive balance in the debt market)");
        assertEq(w.value, surplus, "exactly the surplus was recycled");
        assertEq(IERC20(DEBT).balanceOf(maker), 0, "Recycle pulled the whole ceiling from the wallet");
        assertEq(IERC20(DEBT).balanceOf(address(operatorModule)), 0, "module drained");
    }

    /// @dev The control: `SweepToUser` (explicit word 0 at 160) never pulls the
    ///      surplus, so the wallet keeps it and the debt market stays flat.
    function test_repay_sweepToUser_leavesSurplusInWallet() public {
        _neutralizeRiskOverride();
        _openDolomitePosition(COLLATERAL, PRINCIPAL);
        _freezeOracles();

        uint256 debt = _debtOf(maker);
        uint256 surplus = 250e6;
        uint256 ceiling = debt + surplus;
        deal(DEBT, maker, ceiling);
        vm.prank(maker);
        permit3.approveToken(address(operatorModule), DEBT, uint160(ceiling), 0);

        vm.prank(address(settlement));
        operatorModule.makeOnBehalf(maker, ceiling, _repayData(DustHandler.DustAction.SweepToUser));

        assertEq(_debtOf(maker), 0, "debt closed");
        assertEq(IERC20(DEBT).balanceOf(maker), surplus, "SweepToUser: surplus never left the wallet");
        WeiBalance memory w = _debtMarketWei(maker);
        assertEq(w.value, 0, "nothing recycled");
    }

    // ──────────────────── BatchClose: the op the suite never executed ────────────────────

    /// @dev repay `sideAmount` (capped at live debt) + withdraw `amount` collateral in
    ///      ONE `operate`. The first executing test for `Op.BatchClose`.
    function test_batchClose_repaysAndWithdrawsInOneOperate() public {
        _neutralizeRiskOverride();
        _openDolomitePosition(COLLATERAL, PRINCIPAL);
        _freezeOracles();

        uint256 debt = _debtOf(maker);
        uint256 withdrawColl = 1 ether;
        deal(DEBT, maker, debt);
        vm.prank(maker);
        permit3.approveToken(address(operatorModule), DEBT, uint160(debt), 0);

        bytes memory data = abi.encode(
            DolomiteOperatorModule.BatchData({
                op: uint256(DolomiteOperatorModule.Op.BatchClose),
                dolomite: address(DOLOMITE),
                collMarketId: COLL_MARKET,
                collToken: COLL,
                borrowMarketId: DEBT_MARKET,
                borrowToken: DEBT,
                accountNumber: ACCOUNT,
                sideAmount: debt,
                totalAmount: withdrawColl
            })
        );

        vm.prank(address(permit3));
        operatorModule.takeOnBehalf(maker, withdrawColl, receiver, data);

        assertEq(_debtOf(maker), 0, "BatchClose: debt repaid");
        assertEq(_collateralOf(maker), COLLATERAL - withdrawColl, "BatchClose: collateral withdrawn");
        assertEq(IERC20(COLL).balanceOf(receiver), withdrawColl, "receiver got the collateral");
        assertEq(IERC20(DEBT).balanceOf(address(operatorModule)), 0, "module drained (debt)");
        assertEq(IERC20(COLL).balanceOf(address(operatorModule)), 0, "module drained (coll)");
        assertEq(IERC20(DEBT).allowance(address(operatorModule), address(DOLOMITE)), 0, "scoped grant cleared");
    }

    // ──────────────────── the two findings the differential review added ────────────────────

    /// @dev I-8. A `Full` leg whose live position is SHORT of the signed total must
    ///      REVERT, not deliver less: the withdraw item funds an INPUT leg, and
    ///      {Core._payInputsToSolver} would pull the shortfall from the maker's
    ///      WALLET at the signed price. Every other `Full` leg in the tree carried this
    ///      guard since 2026-09-10; Dolomite's never did — the differential review of
    ///      the merge found the sibling the patch missed.
    function test_withdraw_full_shortPosition_failsClosed_I8() public {
        _seedDolomiteCollateral(COLLATERAL);
        uint256 signedTotal = COLLATERAL + 1 ether; // the maker signed MORE than they hold

        vm.prank(address(permit3));
        vm.expectRevert(abi.encodeWithSelector(FullFillGuard.ShortWithdraw.selector, COLLATERAL, signedTotal));
        operatorModule.takeOnBehalf(maker, signedTotal, receiver, _withdrawFullData(signedTotal));
    }

    /// @dev `Op.Borrow` kept wire value 0 — which was ALSO the old `BatchMode.Open`.
    ///      A stale 9-word `BatchData` blob would otherwise decode as a clean 5-field
    ///      Borrow (from `collMarketId`, on sub-account `borrowMarketId`) rather than
    ///      revert. The exact-length pin makes it fail closed.
    function test_borrow_rejectsAStaleBatchDataBlob() public {
        bytes memory stale = abi.encode(
            DolomiteOperatorModule.BatchData({
                op: 0, // the OLD BatchMode.Open
                dolomite: address(DOLOMITE),
                collMarketId: COLL_MARKET,
                collToken: COLL,
                borrowMarketId: DEBT_MARKET,
                borrowToken: DEBT,
                accountNumber: ACCOUNT,
                sideAmount: 1 ether,
                totalAmount: 1_000e6
            })
        );
        vm.prank(address(permit3));
        vm.expectRevert(DolomiteOperatorModule.MalformedData.selector);
        operatorModule.takeOnBehalf(maker, 1_000e6, receiver, stale);
    }
}
