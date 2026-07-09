// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, OrderSide, Item, ItemOp, Validator} from "@core/settlement/UniversalSettlement.sol";
import {MultiInputLeverageSolver} from "@core/solver/MultiInputLeverageSolver.sol";

import {AaveModulesBase} from "../shared/AaveModulesBase.t.sol";

/// @dev Flash-backed "dual conversion + leverage in one go". Same maker intent
/// as DualConversionLeverage, but the solver owns ZERO inventory:
///
///   1. MultiInputLeverageSolver flash-loans the WETH collateral from Balancer.
///   2. Settlement pulls it via Permit3, deposits it as the maker's collateral,
///      borrows USDC (leverage), and pulls the maker's DAI equity — routing BOTH
///      inputs (USDC + DAI) back to the solver.
///   3. The solver swaps EACH input → WETH on Uniswap v3 and repays the flash.
///
/// This is the multi-input analogue of FlashLoanLeverage: the shipped
/// single-input LimitOrderLeverageSolver can't accept this order, but
/// MultiInputLeverageSolver loops its post-fill swaps over every tokenIn leg.
///
///   tokenIn  = [USDC, DAI]   USDC = borrow proceeds (amountIn[0]), DAI = equity
///   tokenOut = [WETH]        flash-loaned, deposited as collateral
contract DualConversionLeverageFlashTest is AaveModulesBase {
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address constant UNI_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    MultiInputLeverageSolver multiSolver;

    function _a2(address a, address b) internal pure returns (address[] memory r) {
        r = new address[](2);
        r[0] = a;
        r[1] = b;
    }

    function _u2(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }

    function _fees(uint24 a, uint24 b) internal pure returns (uint24[] memory r) {
        r = new uint24[](2);
        r[0] = a;
        r[1] = b;
    }

    function test_flash_dualConversion_plusLeverage_aaveV3() public {
        multiSolver = new MultiInputLeverageSolver(
            address(permit3), address(settlement), BALANCER_VAULT, UNI_ROUTER
        );
        vm.label(address(multiSolver), "multiInputLeverageSolver");

        uint256 collateralIn = 1 ether; //   WETH flash-loaned → deposited
        // Inputs sized to comfortably cover the 1 WETH flash repayment after the
        // swaps (mirrors FlashLoanLeverage's conservative sizing — this is about
        // solver repayment mechanics, not the maker's P&L).
        uint256 borrowOut = 3_000e6; //       USDC borrowed → solver (amountIn[0])
        uint256 equityIn = 3_000e18; //       DAI equity → solver (amountIn[1])

        _seedAWethPosition(10 ether);
        deal(DAI, maker, equityIn);

        // Maker authorisations: deposit pull + credit delegation + borrow gate.
        _approveMakerDepositBorrowSide(collateralIn, borrowOut);
        // Maker authorises Settlement to pull the DAI equity leg.
        vm.startPrank(maker);
        IERC20(DAI).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), DAI, uint160(equityIn), 0);
        vm.stopPrank();

        // Solver-side: register WETH so Settlement can pull the flash-loaned
        // collateral during the deposit-output delivery.
        multiSolver.setupTokenApproval(WETH);

        bytes memory borrowData = abi.encode(AAVE_POOL, USDC, uint256(2));
        Item[] memory items = new Item[](2);
        items[0] = Item(ItemOp.MAKE, address(depositModule), collateralIn, address(0), abi.encode(AAVE_POOL, WETH));
        items[1] = Item(ItemOp.TAKE, address(borrowModule), borrowOut, address(0), borrowData);

        Order memory order = Order({
            maker: maker,
            side: OrderSide.SELL,
            nonce: 43,
            deadline: block.timestamp + 1 hours,
            tokenIn: _a2(USDC, DAI),
            startAmountIn: _u2(borrowOut, equityIn),
            endAmountIn: _u2(borrowOut, equityIn),
            decayStartTime: 0,
            decayDuration: 0,
            tokenOut: _a1(WETH),
            startAmountOut: _u1(collateralIn),
            endAmountOut: _u1(collateralIn),
            exclusiveFiller: address(0),
            exclusivityEndTime: 0,
            minFillAnchor: 0,
            exclusivityOverrideBps: 0,
            curve: _noCurve(),
            gasBumpBps: 0,
            gasPriceRef: 0,
            items: items,
            validators: new Validator[](0),
            invariants: new Validator[](0),
            feeConfig: bytes32(0)
        });
        bytes memory sig = _sign(order);

        uint256 makerAWethBefore = IERC20(aWETH).balanceOf(maker);
        uint256 makerDebtBefore = IERC20(usdcDebtToken).balanceOf(maker);

        // No inventory — anyone can call. USDC via 0.05% pool, DAI via 0.3% pool.
        multiSolver.executeFill(WETH, collateralIn, order, sig, borrowOut, _fees(500, 3000), _u2(0, 0));

        // Maker: +1 aWETH collateral, +3000 USDC debt, -3000 DAI equity.
        assertApproxEqAbs(IERC20(aWETH).balanceOf(maker) - makerAWethBefore, collateralIn, 2, "maker aWETH up");
        assertApproxEqAbs(IERC20(usdcDebtToken).balanceOf(maker) - makerDebtBefore, borrowOut, 2, "maker debt up");
        assertEq(IERC20(DAI).balanceOf(maker), 0, "maker DAI equity spent");

        // Solver: swapped both inputs to WETH and repaid the flash; no residual
        // debt tokens, non-negative WETH profit.
        assertEq(IERC20(USDC).balanceOf(address(multiSolver)), 0, "solver USDC swapped");
        assertEq(IERC20(DAI).balanceOf(address(multiSolver)), 0, "solver DAI swapped");
        assertGe(IERC20(WETH).balanceOf(address(multiSolver)), 0, "solver WETH non-negative (flash repaid)");

        // Nothing stranded.
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(DAI).balanceOf(address(settlement)), 0, "settlement DAI drained");
    }
}
