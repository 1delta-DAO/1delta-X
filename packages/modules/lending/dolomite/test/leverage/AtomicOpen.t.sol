// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {DolomiteModulesBase} from "../shared/DolomiteModulesBase.t.sol";
import {DolomiteOperateModule} from "../../src/DolomiteModules.sol";

/// @dev Level B: deposit WETH collateral AND borrow USDC against it in a SINGLE
/// `operate` — one end-of-call solvency check covers both legs (Dolomite's
/// batch primitive), versus two separate `operate` calls for the single-op path.
///
///   tokenIn  = USDC  (solver receives the borrow proceeds)
///   tokenOut = WETH  (solver funds the collateral)
///   [0] TAKE DolomiteOperateModule (Open)  Deposit collateral + Withdraw borrow
contract DolomiteAtomicOpenTest is DolomiteModulesBase {
    uint256 constant COLLATERAL_IN = 1 ether;
    uint256 constant BORROW_OUT = 1_000e6;

    function test_atomic_deposit_and_borrow_oneOperate() public {
        _neutralizeRiskOverride();
        deal(COLL, solver, COLLATERAL_IN);

        DolomiteOperateModule.BatchData memory p = DolomiteOperateModule.BatchData({
            mode: uint256(DolomiteOperateModule.BatchMode.Open),
            dolomite: address(DOLOMITE),
            collMarketId: COLL_MARKET,
            collToken: COLL,
            borrowMarketId: DEBT_MARKET,
            borrowToken: DEBT,
            accountNumber: ACCOUNT,
            sideAmount: COLLATERAL_IN,
            totalAmount: BORROW_OUT // composite items are full-fill only
        });
        bytes memory data = abi.encode(p);

        // Maker approvals: WETH pulled by the operate module to fund the deposit
        // leg; taker allowance on the borrow leg. (Operator set in setUp.)
        vm.startPrank(maker);
        IERC20(COLL).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(operateModule), COLL, uint160(COLLATERAL_IN), 0);
        permit3.approveTaker(address(settlement), address(operateModule), keccak256(data), uint160(BORROW_OUT), 0);
        IERC20(DEBT).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), DEBT, uint160(BORROW_OUT), 0);
        vm.stopPrank();

        _approveSolverSide(COLLATERAL_IN, COLL);

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE, address(operateModule), BORROW_OUT, address(0), data);
        Order memory order = _order(maker, 2, DEBT, COLL, BORROW_OUT, COLLATERAL_IN, items);
        bytes memory sig = _sign(order);

        uint256 collatBefore = _collateralOf(maker);
        uint256 debtBefore = _debtOf(maker);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, BORROW_OUT)[0];

        assertEq(paid, COLLATERAL_IN, "solver funded the WETH collateral");
        assertApproxEqAbs(_collateralOf(maker) - collatBefore, COLLATERAL_IN, 2, "collateral up ~1 WETH");
        assertApproxEqAbs(_debtOf(maker) - debtBefore, BORROW_OUT, 2, "debt up ~1000 USDC");

        assertEq(IERC20(DEBT).balanceOf(solver), BORROW_OUT, "solver received borrow proceeds");
        assertEq(IERC20(COLL).balanceOf(address(operateModule)), 0, "operate module WETH drained");
        assertEq(IERC20(DEBT).balanceOf(address(operateModule)), 0, "operate module USDC drained");
    }
}
