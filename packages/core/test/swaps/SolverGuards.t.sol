// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order, Item, Validator} from "@core/settlement/UniversalSettlement.sol";
import {BaseFlashSolver} from "@core/solver/BaseFlashSolver.sol";
import {LimitOrderLeverageSolver} from "@core/solver/LimitOrderLeverageSolver.sol";
import {MultiOutputFlashSolver, OutputLeg} from "@core/solver/MultiOutputFlashSolver.sol";

import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

/// @dev Negative / guard coverage for the flash-solver family. The happy paths
/// live in MultiOutputFlash.t.sol (core) and the modules-* leverage suites; this
/// file pins the revert paths that previously had NO coverage:
///
///   • NotInFlash            — a provider callback invoked outside a flash this
///                             solver started (the reentrancy / stray-callback guard).
///   • OnlyVault             — a provider callback invoked by a non-vault caller.
///   • MultiInputUnsupported — a multi-input order handed to a single-debt solver.
///   • FlashLoanNotRepaid    — the fill+swap left the solver unable to repay.
///   • slippage              — the repayment swap violates its minOut.
///
/// All are fork tests (they touch the real Balancer vault / Uniswap router), so
/// they inherit the RPC-fallback fork from CoreSettlementBase.
contract SolverGuardsTest is CoreSettlementBase {
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address constant UNI_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    LimitOrderLeverageSolver leverageSolver;
    MultiOutputFlashSolver outputSolver;

    function setUp() public override {
        super.setUp();
        vm.label(DAI, "DAI");
        leverageSolver = new LimitOrderLeverageSolver(address(permit3), address(settlement), BALANCER_VAULT, UNI_ROUTER);
        outputSolver = new MultiOutputFlashSolver(address(permit3), address(settlement), BALANCER_VAULT, UNI_ROUTER);
        vm.label(address(leverageSolver), "leverageSolver");
        vm.label(address(outputSolver), "outputSolver");
    }

    // ──────────────────── Empty-array helpers ────────────────────

    function _emptyAddrs() internal pure returns (address[] memory) {
        return new address[](0);
    }

    function _emptyUints() internal pure returns (uint256[] memory) {
        return new uint256[](0);
    }

    // ══════════════════════ NotInFlash: stray callback ══════════════════════
    //
    // The `initiatesFlash` / `_requireInFlash` guard is the solver's reentrancy
    // boundary: a provider callback may only run inside a flash THIS solver
    // started. A stray call from the real vault address — the caller that passes
    // the `OnlyVault` check — must still revert because no flash is armed. This
    // is exactly the vector an attacker would use to hand the callback crafted
    // `userData` (a forged order) and drive `settlement.fill` out of band.

    function test_leverage_strayCallbackFromVault_revertsNotInFlash() public {
        vm.prank(BALANCER_VAULT);
        vm.expectRevert(BaseFlashSolver.NotInFlash.selector);
        leverageSolver.receiveFlashLoan(_emptyAddrs(), _emptyUints(), _emptyUints(), "");
    }

    function test_multiOutput_strayCallbackFromVault_revertsNotInFlash() public {
        vm.prank(BALANCER_VAULT);
        vm.expectRevert(BaseFlashSolver.NotInFlash.selector);
        outputSolver.receiveFlashLoan(_emptyAddrs(), _emptyUints(), _emptyUints(), "");
    }

    // ══════════════════════ OnlyVault: wrong caller ══════════════════════
    //
    // The first line of every provider callback pins the vault as the sole
    // caller. A non-vault caller is rejected before the flash guard is even
    // consulted.

    function test_leverage_callbackFromNonVault_revertsOnlyVault() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(LimitOrderLeverageSolver.OnlyVault.selector);
        leverageSolver.receiveFlashLoan(_emptyAddrs(), _emptyUints(), _emptyUints(), "");
    }

    function test_multiOutput_callbackFromNonVault_revertsOnlyVault() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(MultiOutputFlashSolver.OnlyVault.selector);
        outputSolver.receiveFlashLoan(_emptyAddrs(), _emptyUints(), _emptyUints(), "");
    }

    // ══════════════════════ MultiInputUnsupported ══════════════════════
    //
    // The single-debt leverage core only routes `tokenIn[0]`; handing it a
    // multi-input order would silently strand legs [1..] as maker shortfalls, so
    // `_fillAndSwap` rejects it. The check fires inside the flash callback,
    // BEFORE `settlement.fill`, so the whole flash unwinds with our error (no
    // lending market needed to trip it).

    function _multiInputOrder() internal view returns (Order memory o) {
        address[] memory tokenIn = new address[](2);
        tokenIn[0] = USDC;
        tokenIn[1] = DAI;
        uint256[] memory amountIn = new uint256[](2);
        amountIn[0] = 2_000e6;
        amountIn[1] = 500e18;

        o = Order({
            maker: maker,
            nonce: 0,
            deadline: block.timestamp + 1 hours,
            tokenIn: tokenIn,
            amountIn: amountIn,
            decayStartTime: 0,
            decayDuration: 0,
            tokenOut: _a1(WETH),
            startAmountOut: _u1(1 ether),
            endAmountOut: _u1(1 ether),
            exclusiveFiller: address(0),
            exclusivityEndTime: 0,
            minFillAmountIn: 0,
            items: new Item[](0),
            validators: new Validator[](0),
            invariants: new Validator[](0)
        });
    }

    function test_leverage_multiInputOrder_revertsMultiInputUnsupported() public {
        Order memory order = _multiInputOrder();
        bytes memory sig = _sign(order);

        // 1 WETH flash is well within the Balancer vault's balance; the callback
        // reverts before any repayment is attempted.
        vm.expectRevert(BaseFlashSolver.MultiInputUnsupported.selector);
        leverageSolver.executeFill(WETH, 1 ether, order, sig, 2_000e6, 500, 0);
    }

    // ══════════════════════ FlashLoanNotRepaid ══════════════════════
    //
    // A single-output flash fill where the buyback is omitted (`spendIn == 0`):
    // Settlement delivers the flashed USDC to the maker and pays the solver WETH,
    // but with no buyback the solver holds 0 USDC and cannot repay the flash, so
    // `_ensureRepayable` reverts. Proves the repayment floor actually bites.

    function _singleOutputOrder() internal view returns (Order memory o) {
        o = Order({
            maker: maker,
            nonce: 0,
            deadline: block.timestamp + 1 hours,
            tokenIn: _a1(WETH),
            amountIn: _u1(3 ether),
            decayStartTime: 0,
            decayDuration: 0,
            tokenOut: _a1(USDC),
            startAmountOut: _u1(3_000e6),
            endAmountOut: _u1(3_000e6),
            exclusiveFiller: address(0),
            exclusivityEndTime: 0,
            minFillAmountIn: 0,
            items: new Item[](0),
            validators: new Validator[](0),
            invariants: new Validator[](0)
        });
    }

    function test_multiOutput_noBuyback_revertsFlashLoanNotRepaid() public {
        deal(WETH, maker, 3 ether);
        _approveMakerToSettlement(WETH, 3 ether);
        outputSolver.setupTokenApproval(USDC);

        Order memory order = _singleOutputOrder();
        bytes memory sig = _sign(order);

        OutputLeg[] memory legs = new OutputLeg[](1);
        // spendIn == 0 → no buyback → solver ends the callback with 0 USDC.
        legs[0] = OutputLeg({token: USDC, flashAmount: 3_000e6, dexFee: 500, spendIn: 0, minOut: 0});

        vm.expectRevert(BaseFlashSolver.FlashLoanNotRepaid.selector);
        outputSolver.executeFill(order, sig, 3 ether, legs);
    }

    // ══════════════════════ Slippage guard ══════════════════════
    //
    // Same single-output fill, but the buyback demands an impossible `minOut`.
    // The Uniswap v3 router aborts the swap ("Too little received"), unwinding
    // the flash. We assert only that it reverts — the point is that `minOut`
    // (the solver's slippage bound) is enforced, not the exact router message.

    function test_multiOutput_slippage_reverts() public {
        deal(WETH, maker, 3 ether);
        _approveMakerToSettlement(WETH, 3 ether);
        outputSolver.setupTokenApproval(USDC);

        Order memory order = _singleOutputOrder();
        bytes memory sig = _sign(order);

        OutputLeg[] memory legs = new OutputLeg[](1);
        // Spend 1 WETH but demand an impossible amount of USDC out.
        legs[0] = OutputLeg({token: USDC, flashAmount: 3_000e6, dexFee: 500, spendIn: 1 ether, minOut: 3_000e6 * 1_000});

        vm.expectRevert();
        outputSolver.executeFill(order, sig, 3 ether, legs);
    }
}
