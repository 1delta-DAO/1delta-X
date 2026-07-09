// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, OrderSide, Item, ItemOp, Validator} from "@core/settlement/UniversalSettlement.sol";
import {AaveV3MultiInputFlashSolver} from "@core/solver/AaveV3MultiInputFlashSolver.sol";
import {EulerMultiInputFlashSolver} from "@core/solver/EulerMultiInputFlashSolver.sol";
import {MorphoMultiInputFlashSolver} from "@core/solver/MorphoMultiInputFlashSolver.sol";

import {AaveModulesBase} from "../shared/AaveModulesBase.t.sol";

/// @dev All multi-input flash solvers share ONE entrypoint (arrays of dex fees /
///      min-outs, aligned with `order.tokenIn`), so the runner is provider-agnostic.
interface IMultiInputFlashSolver {
    function setupTokenApproval(address token) external;
    function executeFill(
        address flashSource,
        uint256 flashAmount,
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmountIn,
        uint24[] calldata dexFees,
        uint256[] calldata minSwapOuts
    ) external;
}

/// @dev The dual-conversion + leverage fill (borrow USDC + equity DAI → WETH
/// collateral, in one shot) sourced from THREE flash providers, proving the
/// multi-input solver family is interchangeable — the Balancer sibling is covered
/// in DualConversionLeverageFlash. Only the flash source + repayment convention
/// change; the maker intent and the swap-both-inputs-back core are identical.
contract MultiInputFlashProvidersTest is AaveModulesBase {
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant UNI_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address constant EULER_WETH_VAULT = 0xD8b27CF359b7D15710a5BE299AF6e7Bf904984C2;

    function test_dualConversion_via_aaveV3_flash() public {
        AaveV3MultiInputFlashSolver s =
            new AaveV3MultiInputFlashSolver(address(permit3), address(settlement), AAVE_POOL, UNI_ROUTER);
        _runDualVia(address(s), WETH);
    }

    function test_dualConversion_via_euler_flash() public {
        EulerMultiInputFlashSolver s =
            new EulerMultiInputFlashSolver(address(permit3), address(settlement), UNI_ROUTER);
        _runDualVia(address(s), EULER_WETH_VAULT);
    }

    function test_dualConversion_via_morpho_flash() public {
        MorphoMultiInputFlashSolver s =
            new MorphoMultiInputFlashSolver(address(permit3), address(settlement), MORPHO, UNI_ROUTER);
        _runDualVia(address(s), WETH);
    }

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

    /// @dev Provider-agnostic: flash 1 WETH, deposit it as the maker's collateral,
    ///      borrow 3k USDC + pull 3k DAI equity, swap both → WETH, repay the flash.
    function _runDualVia(address solver, address flashSource) internal {
        uint256 collateralIn = 1 ether;
        uint256 borrowOut = 3_000e6; //   amountIn[0]
        uint256 equityIn = 3_000e18; //   amountIn[1]

        _seedAWethPosition(10 ether);
        deal(DAI, maker, equityIn);

        _approveMakerDepositBorrowSide(collateralIn, borrowOut);
        vm.startPrank(maker);
        IERC20(DAI).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), DAI, uint160(equityIn), 0);
        vm.stopPrank();

        IMultiInputFlashSolver(solver).setupTokenApproval(WETH);

        bytes memory borrowData = abi.encode(AAVE_POOL, USDC, uint256(2));
        Item[] memory items = new Item[](2);
        items[0] = Item(ItemOp.MAKE, address(depositModule), collateralIn, address(0), abi.encode(AAVE_POOL, WETH));
        items[1] = Item(ItemOp.TAKE, address(borrowModule), borrowOut, address(0), borrowData);

        Order memory order = Order({
            maker: maker,
            side: OrderSide.SELL,
            nonce: 50,
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

        // USDC via 0.05% pool, DAI via 0.3% pool.
        IMultiInputFlashSolver(solver).executeFill(
            flashSource, collateralIn, order, sig, borrowOut, _fees(500, 3000), _u2(0, 0)
        );

        // Maker: +1 aWETH collateral, +3000 USDC debt, -3000 DAI equity. Tolerance
        // absorbs Aave liquidity-index accrual when the flash source IS the pool.
        assertApproxEqAbs(IERC20(aWETH).balanceOf(maker) - makerAWethBefore, collateralIn, 1e13, "maker aWETH up");
        assertApproxEqAbs(IERC20(usdcDebtToken).balanceOf(maker) - makerDebtBefore, borrowOut, 2, "maker debt up");
        assertEq(IERC20(DAI).balanceOf(maker), 0, "maker DAI equity spent");

        // Solver swapped both inputs and repaid the flash.
        assertEq(IERC20(USDC).balanceOf(solver), 0, "solver USDC swapped");
        assertEq(IERC20(DAI).balanceOf(solver), 0, "solver DAI swapped");
        assertGe(IERC20(WETH).balanceOf(solver), 0, "solver WETH non-negative (flash repaid)");
    }
}
