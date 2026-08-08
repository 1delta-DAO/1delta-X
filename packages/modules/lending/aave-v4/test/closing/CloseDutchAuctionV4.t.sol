// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, OrderSide, Item, ItemOp, Validator, LegIn, LegOut} from "@core/settlement/Settlement.sol";

import {ISpokeV4} from "../../src/interfaces/IAaveV4.sol";
import {AaveV4ModulesBase} from "../shared/AaveV4ModulesBase.t.sol";

/// @dev Aave v4 counterpart of `CloseDutchAuctionTest`. The maker holds a v4 WETH
/// supply position + USDC debt and signs a 2-item close:
///   [0] MAKE  repay the USDC debt (module caps at the live debt)
///   [1] TAKE  withdraw WETH collateral → solver
/// `tokenOut` (USDC) decays via the native auction; filled at the midpoint. The
/// debt routes through the v4 Hub/Spoke position managers instead of a pool, but
/// the Dutch-auction pricing is identical — no validator required.
///
///   tokenIn  = WETH  (withdrawn collateral → solver)
///   tokenOut = USDC  (solver provides, Dutch-decaying → funds the repay)
contract CloseDutchAuctionV4Test is AaveV4ModulesBase {
    function test_close_aaveV4_dutch_auction() public {
        uint256 debt = 3_000e6;
        uint256 wethIn = 2 ether;
        uint256 startOut = 3_300e6;
        uint256 endOut = 3_100e6;
        uint256 repayCeiling = 3_300e6;

        _openV4UsdcDebt(debt);
        deal(USDC, solver, startOut);

        bytes memory repayData = abi.encode(MAIN_SPOKE, GIVER_PM, usdcReserveId, USDC);
        bytes memory withdrawData = abi.encode(MAIN_SPOKE, TAKER_PM, wethReserveId, WETH);

        _approveMakerRepaySide(repayCeiling, wethIn);
        _approveMakerWithdrawSide(wethIn, keccak256(withdrawData));
        _approveSolverSide(startOut, USDC);

        Order memory order = _buildCloseOrder(wethIn, startOut, endOut, repayCeiling, repayData, withdrawData);
        bytes memory sig = _sign(order);

        vm.warp(block.timestamp + 50);
        uint256 expectedOut = startOut - (startOut - endOut) / 2; // 3_200e6
        uint256 suppliedBefore = ISpokeV4(MAIN_SPOKE).getUserSuppliedAssets(wethReserveId, maker);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, wethIn)[0];

        // Dutch price applied.
        assertEq(paid, expectedOut, "solver paid the decayed USDC price");
        // Debt closed.
        assertApproxEqAbs(ISpokeV4(MAIN_SPOKE).getUserTotalDebt(usdcReserveId, maker), 0, 2, "USDC debt closed");
        // Collateral withdrawn and sold to the solver.
        assertApproxEqAbs(
            suppliedBefore - ISpokeV4(MAIN_SPOKE).getUserSuppliedAssets(wethReserveId, maker),
            wethIn,
            1e13,
            "v4 supply reduced by wethIn"
        );
        assertEq(IERC20(WETH).balanceOf(solver), wethIn, "solver received WETH collateral");
        // Maker keeps the surplus (decayed USDC − repaid debt).
        assertApproxEqAbs(IERC20(USDC).balanceOf(maker), expectedOut - debt, 1e6, "maker kept the surplus");
        // Nothing stranded.
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
    }

    /// @dev Extracted to keep the test body under the stack-too-deep limit.
    function _buildCloseOrder(
        uint256 wethIn,
        uint256 startOut,
        uint256 endOut,
        uint256 repayCeiling,
        bytes memory repayData,
        bytes memory withdrawData
    ) internal view returns (Order memory order) {
        Item[] memory items = new Item[](2);
        items[0] = Item({
            op: ItemOp.MAKE, module: address(repayModule), amount: repayCeiling, recipient: address(0), data: repayData
        });
        items[1] = Item({
            op: ItemOp.TAKE, module: address(withdrawModule), amount: wethIn, recipient: address(0), data: withdrawData
        });

        LegIn[] memory legsIn = new LegIn[](1);
        legsIn[0] = LegIn(WETH, wethIn, 0); // fixed input
        LegOut[] memory legsOut = new LegOut[](1);
        legsOut[0] = LegOut(USDC, startOut, endOut, address(0)); // Dutch-decaying output → maker

        order = Order({
            maker: maker,
            nonce: 7,
            deadline: block.timestamp + 1 hours,
            legsIn: PackedEncode.legsIn(legsIn),
            legsOut: PackedEncode.legsOut(legsOut),
            timing: _packTiming(uint32(block.timestamp), 100, 0),
            exclusiveFiller: address(0),
            minFillAnchor: 0,
            exclusivityOverrideBps: 0,
            curve: _noCurve(),
            gasBumpBps: 0,
            gasPriceRef: 0,
            items: PackedEncode.items(items),
            validators: PackedEncode.noValidators(),
            invariants: PackedEncode.noValidators(),
            fillModule: address(0),
            fillTotal: 0
        });
    }
}
