// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {LimitOrder} from "@core/settlement/LimitOrderSettlement.sol";
import {DolomiteModulesBase} from "../shared/DolomiteModulesBase.t.sol";

/// @dev Deposit WETH collateral + borrow USDC against it in one Dolomite order,
/// into a borrow-position sub-account (see the harness note on account numbers).
///   [0] MAKE DolomiteDepositModule  one-action `operate` Deposit (WETH)
///   [1] TAKE DolomiteBorrowModule   one-action `operate` Withdraw past zero (USDC)
contract DolomiteDepositBorrowTest is DolomiteModulesBase {
    uint256 constant COLLATERAL_IN = 1 ether;
    uint256 constant BORROW_OUT = 1_000e6;

    function test_depositX_borrowY_dolomite() public {
        _neutralizeRiskOverride();
        deal(COLL, solver, COLLATERAL_IN);

        _approveDepositBorrowSide(COLLATERAL_IN, BORROW_OUT);
        _approveSolverSide(COLLATERAL_IN, COLL);

        LimitOrder memory order = _buildDepositBorrowOrder(COLLATERAL_IN, BORROW_OUT);
        bytes memory sig = _sign(order);

        uint256 collatBefore = _collateralOf(maker);
        uint256 debtBefore = _debtOf(maker);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, BORROW_OUT);

        assertEq(paid, COLLATERAL_IN, "solver paid 1 WETH of collateral");
        assertApproxEqAbs(_collateralOf(maker) - collatBefore, COLLATERAL_IN, 2, "maker collateral up ~1 WETH");
        assertApproxEqAbs(_debtOf(maker) - debtBefore, BORROW_OUT, 2, "maker debt up ~1000 USDC");

        assertEq(IERC20(COLL).balanceOf(solver), 0, "solver WETH spent");
        assertEq(IERC20(DEBT).balanceOf(solver), BORROW_OUT, "solver received USDC");
        assertEq(IERC20(COLL).balanceOf(maker), 0, "maker WETH forwarded into deposit");
        assertEq(IERC20(DEBT).balanceOf(maker), 0, "maker USDC forwarded out via borrow");
        assertEq(IERC20(COLL).balanceOf(address(depositModule)), 0, "deposit module WETH drained");
        assertEq(IERC20(DEBT).balanceOf(address(borrowModule)), 0, "borrow module USDC drained");
    }
}
