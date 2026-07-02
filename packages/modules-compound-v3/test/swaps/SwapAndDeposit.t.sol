// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {Order, Item, ItemOp, Validator} from "@core/settlement/UniversalSettlement.sol";

import {CompoundV3ModulesBase} from "../shared/CompoundV3ModulesBase.t.sol";

/// @dev Swap + deposit: maker sells USDC for WETH at a fixed rate; the
/// received WETH is supplied to the USDC Comet as collateral on the maker's
/// behalf as a single MAKE item.
///
///   tokenIn  = USDC   (maker gives, solver receives)
///   tokenOut = WETH   (solver gives, maker receives — then deposited)
contract SwapAndDepositTest is CompoundV3ModulesBase {
    // ──────────────────── Direct fill ────────────────────

    function test_swap_and_deposit_cometV3() public {
        uint256 usdcIn = 2_000e6; //    maker pays 2000 USDC
        uint256 wethOut = 1 ether; //    receives 1 WETH (fixed price for this test)

        // Fund actors.
        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);

        // Approvals on both sides.
        _approveMakerSide(usdcIn, wethOut);
        _approveSolverSide(wethOut, WETH);

        // Build order: one MAKE item — deposit the received WETH into Comet.
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(depositModule),
            amount: wethOut,
            recipient: address(0),
            data: abi.encode(COMET, WETH)
        });

        Order memory order = Order({
            maker: maker,
            nonce: 0,
            deadline: block.timestamp + 1 hours,
            tokenIn: _a1(USDC),
            tokenOut: _a1(WETH),
            amountIn: _u1(usdcIn),
            decayStartTime: 0,
            decayDuration: 0, //        fixed-price (start == end)
            startAmountOut: _u1(wethOut),
            endAmountOut: _u1(wethOut),
            exclusiveFiller: address(0),
            exclusivityEndTime: 0,
            minFillAmountIn: 0,
            items: items,
            validators: new Validator[](0),
            invariants: new Validator[](0)
        });

        bytes memory sig = _sign(order);

        // Pre-state
        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);
        uint256 makerWethBefore = IERC20(WETH).balanceOf(maker);
        uint256 makerCollatBefore = _wethCollateral(maker);
        uint256 solverUsdcBefore = IERC20(USDC).balanceOf(solver);
        uint256 solverWethBefore = IERC20(WETH).balanceOf(solver);

        // Solver fills the full order in one shot.
        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, usdcIn)[0];

        // Post-state assertions.
        assertEq(paid, wethOut, "solver paid exactly wethOut");

        assertEq(IERC20(USDC).balanceOf(maker), makerUsdcBefore - usdcIn, "maker USDC spent");
        assertEq(IERC20(WETH).balanceOf(maker), makerWethBefore, "maker WETH unchanged (deposited)");
        assertApproxEqAbs(_wethCollateral(maker), makerCollatBefore + wethOut, 2, "maker received Comet collateral");

        assertEq(IERC20(USDC).balanceOf(solver), solverUsdcBefore + usdcIn, "solver received USDC");
        assertEq(IERC20(WETH).balanceOf(solver), solverWethBefore - wethOut, "solver WETH spent");

        // Settlement should have no residual token balance.
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
    }

    // ──────────────────── Single-signature permit fill ────────────────────

    function test_permit_swap_and_deposit() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;

        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);

        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(depositModule),
            amount: wethOut,
            recipient: address(0),
            data: abi.encode(COMET, WETH)
        });

        Order memory order = Order({
            maker: maker,
            nonce: 0,
            deadline: block.timestamp + 1 hours,
            tokenIn: _a1(USDC),
            tokenOut: _a1(WETH),
            amountIn: _u1(usdcIn),
            decayStartTime: 0,
            decayDuration: 0,
            startAmountOut: _u1(wethOut),
            endAmountOut: _u1(wethOut),
            exclusiveFiller: address(0),
            exclusivityEndTime: 0,
            minFillAmountIn: 0,
            items: items,
            validators: new Validator[](0),
            invariants: new Validator[](0)
        });

        IPermit3.PermitBatch memory batch = _buildBatch(
            _tokenPermits(address(settlement), USDC, usdcIn, address(depositModule), WETH, wethOut),
            _noTakerPermits(),
            0,
            order.deadline
        );

        bytes memory sig = _signPermitWitness(batch, _hashOrder(order));

        vm.prank(solver);
        settlement.fillWithPermit(order, batch, sig, usdcIn);

        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver received USDC");
        assertApproxEqAbs(_wethCollateral(maker), wethOut, 2, "maker got Comet collateral");
    }
}
