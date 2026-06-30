// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, Validator} from "@core/settlement/UniversalSettlement.sol";

import {AaveModulesBase} from "../shared/AaveModulesBase.t.sol";

/// @dev Close an Aave v3 leveraged position via a Dutch auction. The maker holds
/// aWETH collateral + USDC debt and signs a 2-item close:
///   [0] MAKE  repay the USDC debt (module caps at the live debt)
///   [1] TAKE  withdraw WETH collateral → solver
/// The order's `tokenOut` (USDC the solver provides) decays over time via the
/// native auction (`startAmountOut → endAmountOut`). Filled at the auction
/// midpoint: the solver provides the decayed USDC, the repay closes the debt, and
/// the surplus stays with the maker. No validator is needed — the Dutch price is
/// the native settlement decay.
///
///   tokenIn  = WETH  (withdrawn collateral → solver)
///   tokenOut = USDC  (solver provides, Dutch-decaying → funds the repay)
contract CloseDutchAuctionTest is AaveModulesBase {
    function test_close_aaveV3_dutch_auction() public {
        uint256 debt = 3_000e6;
        uint256 wethIn = 2 ether; //         collateral sold to the solver (tokenIn)
        uint256 startOut = 3_300e6; //       best USDC for the maker (auction start)
        uint256 endOut = 3_100e6; //         worst USDC for the maker (auction end)
        uint256 repayCeiling = 3_300e6; //   ≥ debt; module caps at the live debt

        _openUsdcDebt(debt);
        deal(USDC, solver, startOut); //     solver funds the max it might provide

        bytes memory repayData = abi.encode(AAVE_POOL, USDC, uint256(2), usdcDebtToken);
        bytes memory withdrawData = abi.encode(AAVE_POOL, WETH, aWETH);

        _approveMakerRepaySide(repayCeiling, wethIn);
        _approveMakerWithdrawSide(wethIn, keccak256(withdrawData), withdrawData);
        _approveSolverSide(startOut, USDC);

        Item[] memory items = new Item[](2);
        items[0] = Item({op: ItemOp.MAKE, module: address(repayModule), amount: repayCeiling, recipient: address(0), data: repayData});
        items[1] = Item({op: ItemOp.TAKE, module: address(withdrawModule), amount: wethIn, recipient: address(0), data: withdrawData});

        Order memory order = Order({
            maker: maker,
            nonce: 7,
            deadline: block.timestamp + 1 hours,
            tokenIn: WETH,
            tokenOut: USDC,
            amountIn: wethIn,
            decayStartTime: uint32(block.timestamp),
            decayDuration: 100,
            startAmountOut: startOut,
            endAmountOut: endOut,
            exclusiveFiller: address(0),
            exclusivityEndTime: 0,
            minFillAmountIn: 0,
            items: items,
            validators: new Validator[](0),
            invariants: new Validator[](0)
        });
        bytes memory sig = _sign(order);

        // Fill at the auction midpoint → price = midpoint of [startOut, endOut].
        vm.warp(block.timestamp + 50);
        uint256 expectedOut = startOut - (startOut - endOut) / 2; // 3_200e6
        uint256 makerAWethBefore = IERC20(aWETH).balanceOf(maker);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, wethIn);

        // Dutch price applied.
        assertEq(paid, expectedOut, "solver paid the decayed USDC price");
        // Debt closed.
        assertEq(IERC20(usdcDebtToken).balanceOf(maker), 0, "USDC debt closed");
        // Collateral withdrawn and sold to the solver.
        assertApproxEqAbs(makerAWethBefore - IERC20(aWETH).balanceOf(maker), wethIn, 2, "aWETH reduced by wethIn");
        assertEq(IERC20(WETH).balanceOf(solver), wethIn, "solver received WETH collateral");
        // Maker keeps the surplus (decayed USDC − repaid debt).
        assertApproxEqAbs(IERC20(USDC).balanceOf(maker), expectedOut - debt, 1e6, "maker kept the surplus");
        // Nothing stranded.
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
    }
}
