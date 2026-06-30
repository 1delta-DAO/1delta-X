// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {Order, Item, ItemOp} from "@core/settlement/UniversalSettlement.sol";

import {DustHandler} from "@core/dust/DustHandler.sol";

import {IComet} from "../../src/interfaces/ICompoundV3.sol";
import {CompoundV3ModulesBase} from "../shared/CompoundV3ModulesBase.t.sol";

/// @dev Repay with over-repay dust refund: maker has an open USDC debt on the
/// USDC Comet and signs a repay amount that intentionally over-shoots
/// (`currentDebt + buffer`) so the repay lands fully no matter what interest
/// accrues between signing and fill. Because Comet's `supplyTo` would otherwise
/// turn the surplus into a *supply* balance, the module caps the supply at the
/// live debt and sweeps the unused portion back to the maker.
///
///   tokenIn  = WETH  (maker gives — pays solver)
///   tokenOut = USDC  (solver gives — funds the repay leg)
///
/// Items:
///   [0] MAKE  CometRepayModule   repay up to `bufferedAmount` USDC
///
/// Trust model for the refund: `makeOnBehalf`'s `onBehalfOf` argument is the
/// *only* place the refund can go — no attacker-controlled redirection is
/// possible, because the destination is not a field of `data`.
contract RepayTest is CompoundV3ModulesBase {
    // ──────────────────── Direct fill ────────────────────

    function test_repay_with_dust_refund_cometV3() public {
        uint256 debtAmount = 3_000e6;
        uint256 buffer = 50e6; //              over-repay buffer for accrual
        uint256 bufferedAmount = debtAmount + buffer;
        uint256 wethForSolver = 1 ether;

        _openUsdcDebt(debtAmount);

        // Fund solver side.
        deal(USDC, solver, bufferedAmount);

        _approveMakerRepaySide(bufferedAmount, wethForSolver);
        _approveSolverSide(bufferedAmount, USDC);

        // Record pre-state.
        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);
        uint256 makerWethBefore = IERC20(WETH).balanceOf(maker);
        uint256 makerDebtBefore = _usdcDebt(maker);
        assertGt(makerDebtBefore, 0, "pre: maker should have debt");

        Order memory order = _buildRepayOrder(bufferedAmount, wethForSolver);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, wethForSolver);

        assertEq(paid, bufferedAmount, "solver paid buffered USDC");

        // Debt fully closed (≤1 wei of Comet rounding tolerated).
        assertApproxEqAbs(_usdcDebt(maker), 0, 2, "debt zeroed");

        // Dust refunded to maker: the buffer that wasn't consumed by the repay
        // came back to the wallet, NOT converted into a Comet supply balance.
        uint256 actualRepaid = makerDebtBefore; //                 ≈ debtAmount + tiny accrual
        uint256 expectedDust = bufferedAmount - actualRepaid;
        uint256 makerUsdcDelta = IERC20(USDC).balanceOf(maker) - makerUsdcBefore;
        assertApproxEqAbs(makerUsdcDelta, expectedDust, 1e6, "dust refunded to maker");
        assertGt(makerUsdcDelta, 0, "some dust exists given the buffer");

        // Maker did NOT end up with a stray supply position from over-repay.
        assertEq(IComet(COMET).balanceOf(maker), 0, "no surplus supply position");

        // Solver spent USDC, gained WETH.
        assertEq(IERC20(USDC).balanceOf(solver), 0, "solver USDC spent");
        assertEq(IERC20(WETH).balanceOf(solver), wethForSolver, "solver received WETH");
        assertEq(IERC20(WETH).balanceOf(maker), makerWethBefore - wethForSolver, "maker WETH spent");

        // Module holds nothing — residual was swept, dust returned to maker.
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), 0, "repay module USDC drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
    }

    // ──────────────────── Single-signature permit fill ────────────────────

    function test_permit_repay_with_dust() public {
        uint256 debt = 3_000e6;
        uint256 buffer = 50e6;
        uint256 buffered = debt + buffer;

        _openUsdcDebt(debt);
        deal(USDC, solver, buffered);

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.MAKE, address(repayModule), buffered, address(0), abi.encode(COMET, USDC));

        Order memory order = _order(maker, 3, WETH, USDC, 1 ether, buffered, items);

        IPermit3.PermitBatch memory batch = _buildBatch(
            _tokenPermits(address(settlement), WETH, 1 ether, address(repayModule), USDC, buffered),
            _noTakerPermits(),
            2,
            order.deadline
        );

        bytes memory sig = _signPermitWitness(batch, _hashOrder(order));

        vm.prank(solver);
        settlement.fillWithPermit(order, batch, sig, 1 ether);

        assertApproxEqAbs(_usdcDebt(maker), 0, 2, "debt zeroed");
        assertGt(IERC20(USDC).balanceOf(maker), 0, "dust refunded");
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), 0, "module drained");
    }

    // ──────────────────── Recycle dust back into the position ────────────────────

    /// @dev Same over-repay setup, but the maker-signed `data` opts into
    /// `DustAction.Recycle` (trailing field). Instead of the surplus landing in
    /// the maker's wallet, the module re-supplies it into the same Comet as a
    /// base supply balance — the CoW × Aave "leftover back into the position"
    /// pattern. Comet's base supply has no cap, so the recycle always succeeds.
    function test_repay_with_dust_recycle_cometV3() public {
        uint256 debtAmount = 3_000e6;
        uint256 buffer = 50e6;
        uint256 bufferedAmount = debtAmount + buffer;
        uint256 wethForSolver = 1 ether;

        _openUsdcDebt(debtAmount);
        deal(USDC, solver, bufferedAmount);

        _approveMakerRepaySide(bufferedAmount, wethForSolver);
        _approveSolverSide(bufferedAmount, USDC);

        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);
        uint256 makerDebtBefore = _usdcDebt(maker);
        assertEq(IComet(COMET).balanceOf(maker), 0, "pre: no base supply position");

        // Repay item with the dust action appended: Recycle (1).
        Item[] memory items = new Item[](1);
        items[0] = Item(
            ItemOp.MAKE,
            address(repayModule),
            bufferedAmount,
            address(0),
            abi.encode(COMET, USDC, uint8(DustHandler.DustAction.Recycle))
        );
        Order memory order = _order(maker, 3, WETH, USDC, wethForSolver, bufferedAmount, items);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, wethForSolver);

        // Debt closed.
        assertApproxEqAbs(_usdcDebt(maker), 0, 2, "debt zeroed");

        // Surplus was NOT swept to the wallet — it was recycled into the position.
        uint256 expectedDust = bufferedAmount - makerDebtBefore;
        assertApproxEqAbs(IERC20(USDC).balanceOf(maker), makerUsdcBefore, 2, "wallet unchanged (no sweep)");
        assertApproxEqAbs(IComet(COMET).balanceOf(maker), expectedDust, 1e6, "dust recycled as base supply");
        assertGt(IComet(COMET).balanceOf(maker), 0, "recycle actually happened");

        // Module + settlement end empty regardless of disposal path.
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), 0, "module drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement drained");
    }
}
