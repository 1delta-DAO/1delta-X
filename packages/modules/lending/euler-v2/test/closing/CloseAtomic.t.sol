// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {EulerV2ModulesBase} from "../shared/EulerV2ModulesBase.t.sol";
import {EulerV2BatchModule} from "../../src/EulerV2Modules.sol";

/// @dev Level B: atomically repay the USDC debt AND withdraw WETH collateral in a
/// SINGLE `EVC.batch` — one deferred liquidity check covers both legs. The check
/// sees the debt reduced before validating the collateral withdrawal, so the
/// unwind never trips an intermediate health violation.
///
///   tokenIn  = WETH  (solver receives the withdrawn collateral)
///   tokenOut = USDC  (solver funds the repay)
///   [0] TAKE EulerV2BatchModule (Close)  repay debt + withdraw collateral
contract EulerCloseAtomicTest is EulerV2ModulesBase {
    uint256 constant DEBT = 1_000e6;
    uint256 constant REPAY_CEIL = 1_002e6; // debt + interest headroom
    uint256 constant WETH_OUT = 0.9 ether; // collateral pulled out for the solver

    function test_atomic_repay_and_withdraw_oneBatch() public {
        _openEulerPosition(1 ether, DEBT);

        // Solver funds the repay in USDC.
        deal(USDC, solver, REPAY_CEIL);

        EulerV2BatchModule.BatchData memory p = EulerV2BatchModule.BatchData({
            mode: uint256(EulerV2BatchModule.BatchMode.Close),
            collateralVault: address(EWETH),
            borrowVault: address(EUSDC),
            sideAmount: REPAY_CEIL,
            totalAmount: WETH_OUT // composite items are full-fill only
        });
        bytes memory data = abi.encode(p);

        // Maker approvals: USDC pulled by the batch module to repay; taker
        // allowance on the collateral leg. (Operator/controller set in setUp.)
        vm.startPrank(maker);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(batchModule), USDC, uint160(REPAY_CEIL), 0);
        permit3.approveTaker(address(settlement), address(batchModule), keccak256(data), uint160(WETH_OUT), 0);
        vm.stopPrank();

        _approveSolverSide(REPAY_CEIL, USDC);

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE, address(batchModule), WETH_OUT, address(0), data);
        Order memory order = _order(maker, 2, WETH, USDC, WETH_OUT, REPAY_CEIL, items);
        bytes memory sig = _sign(order);

        uint256 debtBefore = _usdcDebt(maker);
        uint256 collatBefore = _wethCollateral(maker);
        assertGt(debtBefore, 0, "precondition: maker has debt");

        vm.prank(solver);
        settlement.fill(order, sig, WETH_OUT);

        // Debt cleared (repay ceiling exceeded it), collateral down by WETH_OUT.
        assertEq(_usdcDebt(maker), 0, "debt fully repaid in the batch");
        assertApproxEqAbs(collatBefore - _wethCollateral(maker), WETH_OUT, 1e12, "collateral down by ~WETH_OUT");

        // Solver received the withdrawn WETH; modules end empty.
        assertEq(IERC20(WETH).balanceOf(solver), WETH_OUT, "solver received withdrawn WETH");
        assertEq(IERC20(WETH).balanceOf(address(batchModule)), 0, "batch module WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(batchModule)), 0, "batch module USDC drained");
    }
}
