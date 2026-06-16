// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {LimitOrder, Item, ItemOp} from "@core/settlement/LimitOrderSettlement.sol";

import {DustHandler} from "@core/dust/DustHandler.sol";

import {Chains, Lenders} from "@coretest/data/LenderRegistry.sol";
import {AaveModulesBase} from "../shared/AaveModulesBase.t.sol";

/// @dev Repay with over-repay dust refund: maker has an open Aave USDC debt and
/// signs a repay amount that intentionally over-shoots (`currentDebt + buffer`)
/// so the repay lands fully no matter what interest accrues between signing and
/// fill. The module sweeps the unused portion back to the maker.
///
///   tokenIn  = WETH  (maker gives — pays solver)
///   tokenOut = USDC  (solver gives — funds the repay leg)
///
/// Items:
///   [0] MAKE  AaveV3RepayModule   repay up to `bufferedAmount` USDC
///
/// Trust model for the refund: `makeOnBehalf`'s `user` argument is the *only*
/// place the refund can go — no attacker-controlled redirection is possible,
/// because `refundTo` is not a field of `data`.
contract RepayTest is AaveModulesBase {
    // ──────────────────── Direct fill ────────────────────

    function test_repay_with_dust_refund_aaveV3() public {
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
        uint256 makerDebtBefore = IERC20(usdcDebtToken).balanceOf(maker);
        assertGt(makerDebtBefore, 0, "pre: maker should have debt");

        LimitOrder memory order = _buildRepayOrder(bufferedAmount, wethForSolver);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, wethForSolver);

        assertEq(paid, bufferedAmount, "solver paid buffered USDC");

        // Debt fully closed.
        assertEq(IERC20(usdcDebtToken).balanceOf(maker), 0, "debt zeroed");

        // Dust refunded to maker. Maker originally held `makerUsdcBefore` USDC;
        // the solver's buffered payment passed through the repay module and what
        // wasn't consumed by Aave came back.
        uint256 actualRepaid = makerDebtBefore; //                 ≈ debtAmount + tiny accrual
        uint256 expectedDust = bufferedAmount - actualRepaid;
        uint256 makerUsdcDelta = IERC20(USDC).balanceOf(maker) - makerUsdcBefore;
        assertApproxEqAbs(makerUsdcDelta, expectedDust, 1e6, "dust refunded to maker");
        assertGt(makerUsdcDelta, 0, "some dust exists given the buffer");

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
        items[0] = Item(
            ItemOp.MAKE, address(repayModule), buffered, address(0), abi.encode(AAVE_POOL, USDC, uint256(2), usdcDebtToken)
        );

        LimitOrder memory order = _order(maker, 3, WETH, USDC, 1 ether, buffered, items);

        IPermit3.PermitBatch memory batch = _buildBatch(
            _tokenPermits(address(settlement), WETH, 1 ether, address(repayModule), USDC, buffered),
            _noTakerPermits(),
            2,
            order.deadline
        );

        bytes memory sig = _signPermitWitness(batch, _hashOrder(order));

        vm.prank(solver);
        settlement.fillWithPermit(order, batch, sig, 1 ether);

        assertEq(
            IERC20(lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][USDC].debt).balanceOf(maker),
            0,
            "debt zeroed"
        );
        assertGt(IERC20(USDC).balanceOf(maker), 0, "dust refunded");
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), 0, "module drained");
    }

    // ──────────────────── Recycle opt-in: best-effort, never strands ────────────────────

    /// @dev The maker-signed `data` opts into `DustAction.Recycle` (trailing
    /// field), asking the module to re-supply the over-repay surplus into the
    /// user's Aave position instead of sweeping it to the wallet. The re-supply
    /// is best-effort: USDC on mainnet may be at its supply cap (or frozen), in
    /// which case the module's `try/catch` falls back to the wallet sweep.
    ///
    /// This test pins the SAFETY INVARIANT that holds either way: the debt is
    /// closed, the module/settlement end empty, and the maker is made whole —
    /// the surplus lands as aUSDC (recycle) OR as wallet USDC (fallback), but is
    /// never stranded. It deterministically exercises the recycle code path
    /// (approve → external call → approval reset → post-balance sweep).
    function test_repay_with_dust_recycle_or_fallback_aaveV3() public {
        address aUSDC = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][USDC].collateral;

        uint256 debtAmount = 3_000e6;
        uint256 buffer = 50e6;
        uint256 bufferedAmount = debtAmount + buffer;
        uint256 wethForSolver = 1 ether;

        _openUsdcDebt(debtAmount);
        deal(USDC, solver, bufferedAmount);

        _approveMakerRepaySide(bufferedAmount, wethForSolver);
        _approveSolverSide(bufferedAmount, USDC);

        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);
        uint256 makerAUsdcBefore = IERC20(aUSDC).balanceOf(maker);
        uint256 makerDebtBefore = IERC20(usdcDebtToken).balanceOf(maker);

        // Repay item with the dust action appended: Recycle (1).
        Item[] memory items = new Item[](1);
        items[0] = Item(
            ItemOp.MAKE,
            address(repayModule),
            bufferedAmount,
            address(0),
            abi.encode(AAVE_POOL, USDC, uint256(2), usdcDebtToken, uint8(DustHandler.DustAction.Recycle))
        );
        LimitOrder memory order = _order(maker, 3, WETH, USDC, wethForSolver, bufferedAmount, items);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, wethForSolver);

        // Debt closed.
        assertEq(IERC20(usdcDebtToken).balanceOf(maker), 0, "debt zeroed");

        // Maker made whole: surplus is in the wallet (fallback) or as aUSDC
        // (recycle), summed it equals the expected dust — never stranded.
        uint256 expectedDust = bufferedAmount - makerDebtBefore;
        uint256 walletDelta = IERC20(USDC).balanceOf(maker) - makerUsdcBefore;
        uint256 aUsdcDelta = IERC20(aUSDC).balanceOf(maker) - makerAUsdcBefore;
        assertApproxEqAbs(walletDelta + aUsdcDelta, expectedDust, 1e6, "maker made whole via one path");

        // Module + settlement end empty regardless of the disposal branch.
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), 0, "module drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement drained");
    }
}
