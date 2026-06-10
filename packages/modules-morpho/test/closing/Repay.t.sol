// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {LimitOrder, Item, ItemOp} from "@core/settlement/LimitOrderSettlement.sol";

import {MorphoModulesBase} from "../shared/MorphoModulesBase.t.sol";

/// @dev Repay with over-repay dust refund. Maker has an open Morpho USDC debt and
/// signs a repay amount that intentionally over-shoots (`currentDebt + buffer`) so
/// the position closes no matter what interest accrues between signing and fill.
///
/// Unlike Aave, Morpho's `repay(assets)` does not cap at the live debt, so the
/// module closes by *shares* (reads `borrowShares`, repays them) and sweeps the
/// unused buffer back to the maker.
///
///   tokenIn  = wstETH  (maker gives — pays solver)
///   tokenOut = USDC    (solver gives — funds the repay leg)
///
/// Items:
///   [0] MAKE  MorphoBlueRepayModule   repay full debt, refund dust → maker
contract RepayTest is MorphoModulesBase {
    // ──────────────────── Direct fill ────────────────────

    function test_repay_with_dust_refund_morpho() public {
        uint256 debtAmount = 3_000e6;
        uint256 buffer = 50e6; //              over-repay buffer for accrual
        uint256 bufferedAmount = debtAmount + buffer;
        uint256 wstethForSolver = 1 ether;

        _openPosition(2 ether, debtAmount);
        // Maker needs free wstETH in-wallet to pay the solver the tokenIn leg
        // (the collateral is locked in Morpho).
        deal(WSTETH, maker, wstethForSolver);

        // Fund solver side.
        deal(USDC, solver, bufferedAmount);

        _approveMakerRepaySide(bufferedAmount, wstethForSolver);
        _approveSolverSide(bufferedAmount, USDC);

        // Record pre-state.
        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);
        uint256 makerDebtBefore = _borrowAssets(maker);
        assertGt(makerDebtBefore, 0, "pre: maker should have debt");

        LimitOrder memory order = _buildRepayOrder(bufferedAmount, wstethForSolver);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, wstethForSolver);

        assertEq(paid, bufferedAmount, "solver paid buffered USDC");

        // Debt fully closed (shares zeroed).
        assertEq(_position(maker).borrowShares, 0, "debt shares zeroed");

        // Dust refunded to maker: buffered - actualRepaid (≈ buffer minus tiny accrual).
        uint256 expectedDust = bufferedAmount - makerDebtBefore;
        uint256 makerUsdcDelta = IERC20(USDC).balanceOf(maker) - makerUsdcBefore;
        assertApproxEqAbs(makerUsdcDelta, expectedDust, 1e6, "dust refunded to maker");
        assertGt(makerUsdcDelta, 0, "some dust exists given the buffer");

        // Solver spent USDC, gained wstETH.
        assertEq(IERC20(USDC).balanceOf(solver), 0, "solver USDC spent");
        assertEq(IERC20(WSTETH).balanceOf(solver), wstethForSolver, "solver received wstETH");

        // Module holds nothing — residual swept, dust returned to maker.
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), 0, "repay module USDC drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
    }

    // ──────────────────── Single-signature permit fill ────────────────────

    function test_permit_repay_with_dust() public {
        uint256 debt = 3_000e6;
        uint256 buffer = 50e6;
        uint256 buffered = debt + buffer;

        _openPosition(2 ether, debt);
        deal(WSTETH, maker, 1 ether); // free wstETH for the tokenIn payout to solver
        deal(USDC, solver, buffered);

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.MAKE, address(repayModule), buffered, address(0), _marketData());

        LimitOrder memory order = _order(maker, 3, WSTETH, USDC, 1 ether, buffered, items);

        IPermit3.PermitBatch memory batch = _buildBatch(
            _tokenPermits(address(settlement), WSTETH, 1 ether, address(repayModule), USDC, buffered),
            _noTakerPermits(),
            2,
            order.deadline
        );

        bytes memory sig = _signPermitWitness(batch, _hashOrder(order));

        vm.prank(solver);
        settlement.fillWithPermit(order, batch, sig, 1 ether);

        assertEq(_position(maker).borrowShares, 0, "debt shares zeroed");
        assertGt(IERC20(USDC).balanceOf(maker), 0, "dust refunded");
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), 0, "module drained");
    }
}
