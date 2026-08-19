// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {DustHandler} from "@core/dust/DustHandler.sol";

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

        Order memory order = _buildRepayOrder(bufferedAmount, wstethForSolver);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, wstethForSolver)[0];

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

        Order memory order = _order(maker, 3, WSTETH, USDC, 1 ether, buffered, items);

        IPermit3.PermitBatch memory batch = _buildBatch(
            _tokenPermits(address(settlement), WSTETH, 1 ether, address(repayModule), USDC, buffered),
            _noTakerPermits(),
            2,
            _deadline(order)
        );

        bytes memory sig = _signPermitWitness(batch, _hashOrder(order));

        vm.prank(solver);
        settlement.fillWithPermit(order, batch, sig, 1 ether);

        assertEq(_position(maker).borrowShares, 0, "debt shares zeroed");
        assertGt(IERC20(USDC).balanceOf(maker), 0, "dust refunded");
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), 0, "module drained");
    }

    // ──────────────────── Recycle dust back into the position ────────────────────

    /// @dev Same over-repay setup, but `data` opts into `DustAction.Recycle`. The
    /// module takes custody of the full signed ceiling, repays the shares with
    /// empty callback data (Morpho pulls the exact accrued assets straight from
    /// the module), and re-supplies the surplus as a lend balance into the same
    /// market — instead of leaving it in the maker's wallet. Morpho supply has no
    /// cap, so the recycle always lands.
    function test_repay_with_dust_recycle_morpho() public {
        uint256 debtAmount = 3_000e6;
        uint256 buffer = 50e6;
        uint256 bufferedAmount = debtAmount + buffer;
        uint256 wstethForSolver = 1 ether;

        _openPosition(2 ether, debtAmount);
        deal(WSTETH, maker, wstethForSolver);
        deal(USDC, solver, bufferedAmount);

        _approveMakerRepaySide(bufferedAmount, wstethForSolver);
        _approveSolverSide(bufferedAmount, USDC);

        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);
        assertEq(_position(maker).supplyShares, 0, "pre: no lend position");

        // Repay item with the dust action appended: Recycle (1).
        Item[] memory items = new Item[](1);
        items[0] = Item(
            ItemOp.MAKE,
            address(repayModule),
            bufferedAmount,
            address(0),
            abi.encode(marketParams, uint8(DustHandler.DustAction.Recycle))
        );
        Order memory order = _order(maker, 3, WSTETH, USDC, wstethForSolver, bufferedAmount, items);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, wstethForSolver);

        // Debt closed.
        assertEq(_position(maker).borrowShares, 0, "debt shares zeroed");

        // Surplus recycled into a Morpho lend position, not swept to the wallet.
        assertApproxEqAbs(IERC20(USDC).balanceOf(maker), makerUsdcBefore, 2, "wallet unchanged (no sweep)");
        assertGt(_position(maker).supplyShares, 0, "dust recycled as lend supply");

        // Module + settlement end empty regardless of disposal path.
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), 0, "module drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement drained");
    }
}
