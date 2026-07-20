// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Item, ItemOp, Order} from "@core/settlement/Settlement.sol";

import {MidnightModulesBase} from "./shared/MidnightModulesBase.t.sol";

/// @dev End-to-end fills over the mock Midnight singleton, one per module,
/// exercising the real Settlement forward flow (deliver outputs → items → pay
/// inputs). Assets: COLL (collateral, 18d) / LOAN (loan token, 6d).
contract MidnightFlowsTest is MidnightModulesBase {
    // ──────────────────── Leverage: supply collateral + borrow (take, buy) ────────────────────
    //
    //   tokenIn  = LOAN   (maker borrows → solver receives)
    //   tokenOut = COLL   (solver funds  → forwarded into the supply item)
    //   items    = [MAKE supplyCollateral, TAKE borrow]
    function test_supply_and_borrow() public {
        uint256 collateralIn = 1e18;
        uint256 borrowUnits = 1_000e6;

        COLL.mint(solver, collateralIn); //           solver funds the collateral
        LOAN.mint(address(midnight), borrowUnits); //  lender liquidity for the borrow proceeds

        bytes memory supplyData = _supplyData();
        bytes memory borrowData = _borrowData(borrowUnits);

        _makerApproveToken(address(supplyModule), address(COLL), collateralIn);
        _makerApproveTaker(keccak256(borrowData), borrowUnits);
        _makerAuthorize(address(borrowModule));
        _approveSolverColl(collateralIn);

        Item[] memory items = new Item[](2);
        items[0] = _item(ItemOp.MAKE, address(supplyModule), collateralIn, supplyData);
        items[1] = _item(ItemOp.TAKE, address(borrowModule), borrowUnits, borrowData);
        Order memory order = _order(maker, 1, address(LOAN), address(COLL), borrowUnits, collateralIn, items);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, borrowUnits)[0];

        assertEq(paid, collateralIn, "solver paid 1 COLL of collateral");
        assertEq(_collateralOf(maker), collateralIn, "maker collateral up");
        assertEq(_debtOf(maker), borrowUnits, "maker debt up");
        assertEq(COLL.balanceOf(solver), 0, "solver COLL spent");
        assertEq(LOAN.balanceOf(solver), borrowUnits, "solver received borrow proceeds");
        _assertDrained();
    }

    // ──────────────────── Close: repay + withdraw collateral ────────────────────
    //
    //   tokenIn  = COLL   (collateral withdrawn → solver)
    //   tokenOut = LOAN   (solver funds → forwarded into the repay item)
    //   items    = [MAKE repay, TAKE withdrawCollateral]
    function test_repay_and_withdraw_collateral() public {
        uint256 debtUnits = 1_000e6;
        uint256 collat = 1e18;

        _seedCollateral(maker, collat);
        midnight.seedDebt(_market(), maker, debtUnits);

        LOAN.mint(solver, debtUnits); // solver funds the repayment

        bytes memory repayData = _repayData();
        bytes memory wcData = _withdrawCollateralData(0); // Exact

        _makerApproveToken(address(repayModule), address(LOAN), debtUnits);
        _makerApproveTaker(keccak256(wcData), collat);
        _makerAuthorize(address(takerModule));
        _approveSolverLoan(debtUnits);

        Item[] memory items = new Item[](2);
        items[0] = _item(ItemOp.MAKE, address(repayModule), debtUnits, repayData);
        items[1] = _item(ItemOp.TAKE, address(takerModule), collat, wcData);
        Order memory order = _order(maker, 2, address(COLL), address(LOAN), collat, debtUnits, items);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, collat);

        assertEq(_debtOf(maker), 0, "maker debt cleared");
        assertEq(_collateralOf(maker), 0, "maker collateral withdrawn");
        assertEq(COLL.balanceOf(solver), collat, "solver received collateral");
        assertEq(LOAN.balanceOf(solver), 0, "solver LOAN spent on repay");
        _assertDrained();
    }

    // ──────────────────── Full-mode close: repay + withdraw ALL collateral ────────────────────
    //
    // Withdraw the ENTIRE live collateral, forward the signed amount to the solver,
    // sweep the surplus back to the maker. Fill-or-kill.
    function test_repay_and_withdraw_collateral_full() public {
        uint256 debtUnits = 1_000e6;
        uint256 collat = 1e18;
        uint256 collForward = 0.9e18; // the order's tokenIn slice; surplus → maker

        _seedCollateral(maker, collat);
        midnight.seedDebt(_market(), maker, debtUnits);
        LOAN.mint(solver, debtUnits);

        bytes memory repayData = _repayData();
        bytes memory wcData = _withdrawCollateralData(1); // Full

        _makerApproveToken(address(repayModule), address(LOAN), debtUnits);
        _makerApproveTaker(keccak256(wcData), collForward);
        _makerAuthorize(address(takerModule));
        _approveSolverLoan(debtUnits);

        Item[] memory items = new Item[](2);
        items[0] = _item(ItemOp.MAKE, address(repayModule), debtUnits, repayData);
        items[1] = _item(ItemOp.TAKE, address(takerModule), collForward, wcData);
        Order memory order = _order(maker, 3, address(COLL), address(LOAN), collForward, debtUnits, items);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, collForward);

        assertEq(_debtOf(maker), 0, "maker debt cleared");
        assertEq(_collateralOf(maker), 0, "entire collateral withdrawn");
        assertEq(COLL.balanceOf(solver), collForward, "solver received forwarded slice");
        assertEq(COLL.balanceOf(maker), collat - collForward, "surplus swept to maker");
        _assertDrained();
    }

    // ──────────────────── Lend: buy credit units (take, sell side) ────────────────────
    //
    //   tokenIn  = COLL   (maker pays for the lend, via Permit3)
    //   tokenOut = LOAN   (solver funds → forwarded into the lend item)
    //   items    = [MAKE lend]
    function test_lend() public {
        uint256 lendUnits = 1_000e6;
        uint256 collCost = 0.5e18;

        LOAN.mint(solver, lendUnits); //  solver funds the LOAN to be lent
        COLL.mint(maker, collCost); //     maker pays COLL for the lend position

        bytes memory lendData = _lendData(lendUnits);

        _makerApproveToken(address(lendModule), address(LOAN), lendUnits); // lend pulls delivered LOAN
        _makerApproveToken(address(settlement), address(COLL), collCost); //  tokenIn payout to solver
        _makerAuthorize(address(lendModule)); //                             take routes credit to maker
        _approveSolverLoan(lendUnits);

        Item[] memory items = new Item[](1);
        items[0] = _item(ItemOp.MAKE, address(lendModule), lendUnits, lendData);
        Order memory order = _order(maker, 4, address(COLL), address(LOAN), collCost, lendUnits, items);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, collCost);

        assertEq(_creditOf(maker), lendUnits, "maker credit up");
        assertEq(LOAN.balanceOf(maker), 0, "delivered LOAN fully lent");
        assertEq(COLL.balanceOf(solver), collCost, "solver paid in COLL");
        assertEq(LOAN.balanceOf(solver), 0, "solver LOAN spent");
        _assertDrained();
    }

    // ──────────────────── Lend with a budget buffer: unspent budget swept back ────────────────────
    //
    // The maker signs a loan-token budget larger than the offer actually consumes
    // (`buyerAssets < budget`); the module sweeps the unspent remainder to the maker.
    function test_lend_with_buffer() public {
        uint256 budget = 1_000e6; //   maker-signed spend ceiling
        uint256 lendUnits = 900e6; //  what the offer actually consumes
        uint256 collCost = 0.5e18;

        LOAN.mint(solver, budget);
        COLL.mint(maker, collCost);

        bytes memory lendData = _lendData(lendUnits);

        _makerApproveToken(address(lendModule), address(LOAN), budget);
        _makerApproveToken(address(settlement), address(COLL), collCost);
        _makerAuthorize(address(lendModule));
        _approveSolverLoan(budget);

        Item[] memory items = new Item[](1);
        items[0] = _item(ItemOp.MAKE, address(lendModule), budget, lendData);
        Order memory order = _order(maker, 6, address(COLL), address(LOAN), collCost, budget, items);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, collCost);

        assertEq(_creditOf(maker), lendUnits, "maker credit = consumed units");
        assertEq(LOAN.balanceOf(maker), budget - lendUnits, "unspent budget swept to maker");
        _assertDrained();
    }

    // ──────────────────── Redeem: withdraw credit for the loan token ────────────────────
    //
    //   tokenIn  = LOAN   (redeemed credit → solver)
    //   tokenOut = COLL   (solver funds → maker; a redeem-and-swap exit)
    //   items    = [TAKE withdraw (credit)]
    function test_withdraw_credit() public {
        uint256 creditUnits = 1_000e6;
        uint256 collOut = 0.5e18;

        _seedCredit(maker, creditUnits); // mock holds the redeemable LOAN
        COLL.mint(solver, collOut);

        bytes memory wData = _withdrawCreditData(0); // Exact

        _makerApproveTaker(keccak256(wData), creditUnits);
        _makerAuthorize(address(takerModule));
        _approveSolverColl(collOut);

        Item[] memory items = new Item[](1);
        items[0] = _item(ItemOp.TAKE, address(takerModule), creditUnits, wData);
        Order memory order = _order(maker, 5, address(LOAN), address(COLL), creditUnits, collOut, items);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, creditUnits);

        assertEq(_creditOf(maker), 0, "maker credit redeemed");
        assertEq(COLL.balanceOf(maker), collOut, "maker received COLL out");
        assertEq(LOAN.balanceOf(solver), creditUnits, "solver received redeemed LOAN");
        _assertDrained();
    }

    // ──────────────────── shared assertions / helpers ────────────────────

    function _assertDrained() internal view {
        assertEq(COLL.balanceOf(address(settlement)), 0, "settlement COLL drained");
        assertEq(LOAN.balanceOf(address(settlement)), 0, "settlement LOAN drained");
        assertEq(COLL.balanceOf(address(supplyModule)), 0, "supply module COLL drained");
        assertEq(LOAN.balanceOf(address(repayModule)), 0, "repay module LOAN drained");
        assertEq(LOAN.balanceOf(address(lendModule)), 0, "lend module LOAN drained");
        assertEq(COLL.balanceOf(address(takerModule)), 0, "taker module COLL drained");
        assertEq(LOAN.balanceOf(address(takerModule)), 0, "taker module LOAN drained");
        assertEq(LOAN.balanceOf(address(borrowModule)), 0, "borrow module LOAN drained");
    }

    function _seedCollateral(address who, uint256 amount) internal {
        COLL.mint(address(this), amount);
        COLL.approve(address(midnight), amount);
        midnight.seedCollateral(_market(), who, 0, amount);
    }

    function _seedCredit(address who, uint256 units) internal {
        LOAN.mint(address(this), units);
        LOAN.approve(address(midnight), units);
        midnight.seedCredit(_market(), who, units);
    }

    function _approveSolverColl(uint256 cap) internal {
        vm.prank(solver);
        permit3.approveToken(address(settlement), address(COLL), uint160(cap), 0);
    }

    function _approveSolverLoan(uint256 cap) internal {
        vm.prank(solver);
        permit3.approveToken(address(settlement), address(LOAN), uint160(cap), 0);
    }
}
