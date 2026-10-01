// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Item, ItemOp, Order} from "@core/settlement/Settlement.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";

import {MidnightModulesBase} from "../shared/MidnightModulesBase.t.sol";
import {MidnightMock} from "../shared/MidnightMock.sol";
import {MidnightPreFundModule} from "../../src/MidnightPreFundModules.sol";
import {MidnightTakerModule, MidnightBlob} from "../../src/MidnightModules.sol";
import {Offer} from "../../src/interfaces/IMidnight.sol";

/// @notice 2026-09-30 audit regressions for the Midnight modules (group B-lend2).
///
///  Every test asserts the SAFE end state; each failed against the pre-fix module
///  and/or the pre-fix (unfaithful) {MidnightMock}.
contract MidnightAudit20260930Test is MidnightModulesBase {
    // ──────────────────── L-CV2-1.v2 — borrow delivery bound ────────────────────

    /// @dev [MAKE supply, TAKE borrow] signed against a fee-0 quote; the venue's
    ///      `feeSetter` then raises the settlement fee before the fill.
    function _leverageOrder(uint256 nonce, uint256 collateralIn, uint256 borrowUnits)
        internal
        returns (Order memory order, bytes memory sig)
    {
        COLL.mint(solver, collateralIn);
        bytes memory supplyData = _supplyData();
        bytes memory borrowData = _borrowData(borrowUnits, borrowUnits);
        _makerApproveToken(address(supplyModule), address(COLL), collateralIn);
        _makerAuthorize(address(supplyModule));
        _makerApproveTaker(address(borrowModule), keccak256(borrowData), borrowUnits);
        _makerAuthorize(address(borrowModule));
        _approveSolverColl(collateralIn);

        Item[] memory items = new Item[](2);
        items[0] = _item(ItemOp.MAKE, address(supplyModule), collateralIn, supplyData);
        items[1] = _item(ItemOp.TAKE, address(borrowModule), borrowUnits, borrowData);
        order = _order(maker, nonce, address(LOAN), address(COLL), borrowUnits, collateralIn, items);
        sig = _sign(order);
    }

    /// Before the fix the short proceeds were forwarded and the core pulled the
    /// `units · Δfee` gap from the maker's wallet. Now the leg reverts.
    function test_audit_L_CV2_1_v2_borrowFeeRaiseRevertsInsteadOfBillingWallet() public {
        uint256 borrowUnits = 1_000e6;
        // The maker holds loan token with a Settlement-reachable allowance — the
        // wallet the shortfall used to be billed to.
        LOAN.mint(maker, 100e6);
        _makerApproveToken(address(settlement), address(LOAN), 100e6);

        (Order memory order, bytes memory sig) = _leverageOrder(1, 1e18, borrowUnits);
        midnight.setSettlementFee(_market(), 0.005e18); // +50 bps between signing and fill

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(FullFillGuard.ShortWithdraw.selector, 995e6, borrowUnits));
        settlement.fill(order, sig, borrowUnits);

        assertEq(LOAN.balanceOf(maker), 100e6, "maker wallet untouched");
        assertEq(_debtOf(maker), 0, "no debt booked");
    }

    /// Control: at the quoted fee the same order fills and the wallet is not used.
    function test_audit_L_CV2_1_v2_borrowAtQuotedFeeStillFills() public {
        uint256 borrowUnits = 1_000e6;
        LOAN.mint(maker, 100e6);
        _makerApproveToken(address(settlement), address(LOAN), 100e6);
        (Order memory order, bytes memory sig) = _leverageOrder(2, 1e18, borrowUnits);

        vm.prank(solver);
        settlement.fill(order, sig, borrowUnits);

        assertEq(LOAN.balanceOf(solver), borrowUnits, "solver paid from the borrow");
        assertEq(LOAN.balanceOf(maker), 100e6, "maker wallet untouched");
        assertEq(_debtOf(maker), borrowUnits, "debt booked");
    }

    /// A maker who signs `totalAmount` below the quote absorbs a fee rise up to the
    /// margin; the excess proceeds come back to them.
    function test_audit_L_CV2_1_v2_borrowWithMarginAbsorbsFeeRise() public {
        uint256 borrowUnits = 1_000e6;
        uint256 signed = 990e6; // 1% margin under the fee-0 quote
        COLL.mint(solver, 1e18);
        bytes memory borrowData = _borrowData(borrowUnits, signed);
        _makerApproveToken(address(supplyModule), address(COLL), 1e18);
        _makerAuthorize(address(supplyModule));
        _makerApproveTaker(address(borrowModule), keccak256(borrowData), signed);
        _makerAuthorize(address(borrowModule));
        _approveSolverColl(1e18);
        Item[] memory items = new Item[](2);
        items[0] = _item(ItemOp.MAKE, address(supplyModule), 1e18, _supplyData());
        items[1] = _item(ItemOp.TAKE, address(borrowModule), signed, borrowData);
        Order memory order = _order(maker, 3, address(LOAN), address(COLL), signed, 1e18, items);
        bytes memory sig = _sign(order);
        midnight.setSettlementFee(_market(), 0.005e18);

        vm.prank(solver);
        settlement.fill(order, sig, signed);

        assertEq(LOAN.balanceOf(solver), signed, "solver paid the signed amount");
        assertEq(LOAN.balanceOf(maker), 995e6 - signed, "excess proceeds to the maker");
    }

    // ──────────────────── L-ML-1 — supply / repay need the grant ────────────────────

    function test_audit_L_ML_1_supplyCollateralWithoutGrantReverts() public {
        COLL.mint(maker, 1e18);
        _makerApproveToken(address(supplyModule), address(COLL), 1e18);
        vm.prank(address(settlement));
        vm.expectRevert(MidnightMock.Unauthorized.selector);
        supplyModule.makeOnBehalf(maker, 1e18, _supplyData());
    }

    function test_audit_L_ML_1_repayWithoutGrantReverts() public {
        midnight.seedDebt(_market(), maker, 100e6);
        LOAN.mint(maker, 100e6);
        _makerApproveToken(address(repayModule), address(LOAN), 100e6);
        vm.prank(address(settlement));
        vm.expectRevert(MidnightMock.Unauthorized.selector);
        repayModule.makeOnBehalf(maker, 100e6, _repayData());
    }

    function test_audit_L_ML_1_supplyAndRepayWithGrantSucceed() public {
        midnight.seedDebt(_market(), maker, 100e6);
        COLL.mint(maker, 1e18);
        LOAN.mint(maker, 100e6);
        _makerApproveToken(address(supplyModule), address(COLL), 1e18);
        _makerApproveToken(address(repayModule), address(LOAN), 100e6);
        _makerAuthorize(address(supplyModule));
        _makerAuthorize(address(repayModule));
        vm.startPrank(address(settlement));
        supplyModule.makeOnBehalf(maker, 1e18, _supplyData());
        repayModule.makeOnBehalf(maker, 100e6, _repayData());
        vm.stopPrank();
        assertEq(_collateralOf(maker), 1e18, "supplied");
        assertEq(_debtOf(maker), 0, "repaid");
    }

    function test_audit_L_ML_1_preFundRepayWithoutGrantReverts() public {
        MidnightPreFundModule preFund =
            new MidnightPreFundModule(address(permit3), address(settlement), address(midnight));
        midnight.seedDebt(_market(), maker, 100e6);
        LOAN.mint(address(preFund), 100e6); // the fill's delivery, already here
        uint256 desc = (uint256(1) << 255) | (uint256(1) << 253) | (uint256(uint160(address(LOAN))) << 16)
            | (uint256(MidnightPreFundModule.Op.Repay) << 244);
        vm.prank(address(settlement));
        vm.expectRevert(MidnightMock.Unauthorized.selector);
        preFund.makeOnBehalf(maker, 100e6, abi.encode(desc, _market()));
    }

    // ──────────────────── L-ML-3 — Full credit exit after a slash / fee ────────────────────

    /// The stored `credit()` is stale once a slash or continuous fee is pending; the
    /// Full branch used to withdraw that stale figure and underflow inside the venue.
    function test_audit_L_ML_3_fullCreditWithdrawAfterSlashOrFee() public {
        uint256 creditUnits = 1_000e6;
        uint256 forward = 500e6;
        _seedCredit(maker, creditUnits);
        midnight.setPendingCreditCut(_market(), maker, 10e6); // slash + accrued fee

        bytes memory data = _withdrawCreditData(1, forward); // Full
        _makerAuthorize(address(takerModule));

        vm.prank(address(permit3));
        takerModule.takeOnBehalf(maker, forward, solver, data);

        assertEq(LOAN.balanceOf(solver), forward, "signed amount forwarded");
        assertEq(LOAN.balanceOf(maker), creditUnits - 10e6 - forward, "live remainder swept to the maker");
        assertEq(_creditOf(maker), 0, "position fully exited");
        assertEq(LOAN.balanceOf(address(takerModule)), 0, "module drained");
    }

    // ──────────────────── G-BYTE_MAP-1 — README layout without totalAmount ────────────────────

    /// The old README taker layout (no trailing `totalAmount`) decoded with
    /// `totalAmount = Market.chainId = 1`, so a 1-wei slice passed the full-fill
    /// guard and force-closed the WHOLE position. Now it fails closed.
    function test_audit_G_BYTE_MAP_1_takerBlobWithoutTotalReverts() public {
        _seedCollateral(maker, 1e18);
        _makerAuthorize(address(takerModule));
        bytes memory readmeBlob =
            abi.encode(uint8(MidnightTakerModule.Op.WithdrawCollateral), _market(), uint256(0), uint8(1));

        vm.prank(address(permit3));
        vm.expectRevert(MidnightBlob.MalformedData.selector);
        takerModule.takeOnBehalf(maker, 1, solver, readmeBlob);

        assertEq(_collateralOf(maker), 1e18, "position untouched");
    }

    /// The old README borrow layout decoded with `totalAmount = 0x1e0` (Offer's
    /// inner offset), so every 480-wei slice re-took the full signed `units`.
    function test_audit_G_BYTE_MAP_1_borrowBlobWithoutTotalReverts() public {
        _seedCollateral(maker, 1e18);
        _makerAuthorize(address(borrowModule));
        bytes memory readmeBlob = abi.encode(_offer(true), bytes(""), uint256(1_000e6));

        vm.prank(address(permit3));
        vm.expectRevert(MidnightBlob.MalformedData.selector);
        borrowModule.takeOnBehalf(maker, 0x1e0, solver, readmeBlob);

        assertEq(_debtOf(maker), 0, "no debt taken");
    }

    function test_audit_G_BYTE_MAP_1_lendBlobWithoutTotalReverts() public {
        LOAN.mint(maker, 1_000e6);
        _makerApproveToken(address(lendModule), address(LOAN), 1_000e6);
        _makerAuthorize(address(lendModule));
        bytes memory readmeBlob = abi.encode(_offer(false), bytes(""), uint256(1_000e6));

        vm.prank(address(settlement));
        vm.expectRevert(MidnightBlob.MalformedData.selector);
        lendModule.makeOnBehalf(maker, 0x1e0, readmeBlob);
    }

    /// The current layouts still decode (the head check is exact, not a ban).
    function test_audit_G_BYTE_MAP_1_currentLayoutsAccepted() public {
        _seedCollateral(maker, 1e18);
        _makerAuthorize(address(takerModule));
        vm.prank(address(permit3));
        takerModule.takeOnBehalf(maker, 0.4e18, solver, _withdrawCollateralData(0, 0));
        assertEq(_collateralOf(maker), 0.6e18, "exact withdraw still works");
    }

    // ──────────────────── L-CENSUS-8 (1) — untagged balanceMode ────────────────────

    function test_audit_L_CENSUS_8_balanceModeOutOfRangeReverts() public {
        _seedCollateral(maker, 1e18);
        _makerAuthorize(address(takerModule));
        bytes memory data = _withdrawCollateralData(2, 0);

        vm.prank(address(permit3));
        vm.expectRevert(abi.encodeWithSelector(MidnightTakerModule.BadBalanceMode.selector, uint8(2)));
        takerModule.takeOnBehalf(maker, 0.4e18, solver, data);
    }

    // ──────────────────── L-ML-8 — mock fidelity: re-delegation ────────────────────

    /// The venue lets an AUTHORIZED address re-delegate (a grant is full control) —
    /// the old mock required `msg.sender == onBehalf`, understating the grant.
    function test_audit_L_ML_8_authorizedAddressCanRedelegate() public {
        address delegate = address(0xDE1E);
        address third = address(0x7171);
        vm.prank(maker);
        midnight.setIsAuthorized(delegate, true, maker);
        vm.prank(delegate);
        midnight.setIsAuthorized(third, true, maker);
        assertTrue(midnight.isAuthorized(maker, third), "re-delegated");

        // ...while an unauthorized caller still cannot.
        vm.prank(address(0xBAD));
        vm.expectRevert(MidnightMock.Unauthorized.selector);
        midnight.setIsAuthorized(address(0xBAD), true, maker);
    }

    /// The venue's `take` caps consumption per (maker, group): a second take past
    /// `maxUnits` reverts. The old mock had no caps at all.
    function test_audit_L_ML_8_offerCapsAreConsumed() public {
        LOAN.mint(maker, 2_000e6);
        _makerApproveToken(address(lendModule), address(LOAN), 2_000e6);
        _makerAuthorize(address(lendModule));
        // Sell offer capped at 1_000 units.
        bytes memory data = _cappedLendData(1_000e6);
        vm.startPrank(address(settlement));
        lendModule.makeOnBehalf(maker, 1_000e6, data);
        vm.expectRevert(MidnightMock.ConsumedUnits.selector);
        lendModule.makeOnBehalf(maker, 1_000e6, data);
        vm.stopPrank();
    }

    function _cappedLendData(uint256 units) internal view returns (bytes memory) {
        return abi.encode(_cappedOffer(units), bytes(""), units, units);
    }

    function _cappedOffer(uint256 units) internal view returns (Offer memory o) {
        o = _offer(false);
        o.maxUnits = uint128(units);
    }
}
