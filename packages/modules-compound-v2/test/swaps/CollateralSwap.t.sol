// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/UniversalSettlement.sol";
import {CompoundV2ModulesBase} from "../shared/CompoundV2ModulesBase.t.sol";

/// @dev Collateral swap that exercises BOTH the withdraw and deposit modules with
/// no borrow leg: move USDC collateral → DAI collateral in one order.
///   [0] TAKE CompoundV2WithdrawModule  redeem USDC collateral (pull cUSDC + redeemUnderlying)
///   [1] MAKE CompoundV2DepositModule   mint cDAI collateral for the maker (mint + forward receipt)
/// The solver supplies DAI and receives the withdrawn USDC.
contract CompoundV2CollateralSwapTest is CompoundV2ModulesBase {
    function test_withdrawUsdc_depositDai_compoundV2() public {
        uint256 seed = 2_000e6; //   maker's starting USDC collateral
        uint256 usdcOut = 500e6; //  USDC collateral withdrawn → solver
        uint256 daiIn = 500e18; //   DAI collateral deposited ← solver

        _seedUsdcCollateral(seed);
        deal(DAI, solver, daiIn);

        // Maker approvals: deposit pulls DAI; withdraw pulls cUSDC (token allowance)
        // and is gated by the taker allowance on the withdraw item's data.
        vm.startPrank(maker);
        IERC20(DAI).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(depositModule), DAI, uint160(daiIn), 0);
        IERC20(address(CUSDC)).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(withdrawModule), address(CUSDC), type(uint160).max, 0);
        permit3.approveTaker(address(settlement), keccak256(_withdrawUsdcData()), uint160(usdcOut), 0);
        vm.stopPrank();
        _approveSolverSide(daiIn, DAI);

        uint256 usdcCollBefore = _usdcCollateral(maker);
        uint256 daiCollBefore = _daiCollateral(maker);

        Item[] memory items = new Item[](2);
        items[0] = Item(ItemOp.TAKE, address(withdrawModule), usdcOut, address(0), _withdrawUsdcData());
        items[1] = Item(ItemOp.MAKE, address(depositModule), daiIn, address(0), _depositDaiData());
        Order memory order = _order(maker, 1, USDC, DAI, usdcOut, daiIn, items);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, usdcOut);
        assertEq(paid, daiIn, "solver paid 500 DAI");

        // Maker collateral rebalanced: USDC down ~500, DAI up ~500.
        assertApproxEqRel(usdcCollBefore - _usdcCollateral(maker), usdcOut, 1e15, "USDC collateral down ~500");
        assertApproxEqRel(_daiCollateral(maker) - daiCollBefore, daiIn, 1e15, "DAI collateral up ~500");

        // Solver swapped DAI for USDC.
        assertEq(IERC20(USDC).balanceOf(solver), usdcOut, "solver received USDC");
        assertEq(IERC20(DAI).balanceOf(solver), 0, "solver DAI spent");

        // Nothing sticks in the maker wallet, settlement, or modules.
        assertEq(IERC20(USDC).balanceOf(maker), 0, "maker USDC forwarded out");
        assertEq(IERC20(DAI).balanceOf(maker), 0, "maker DAI forwarded into deposit");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(DAI).balanceOf(address(settlement)), 0, "settlement DAI drained");
        assertEq(IERC20(USDC).balanceOf(address(withdrawModule)), 0, "withdraw module USDC drained");
        assertEq(IERC20(address(CUSDC)).balanceOf(address(withdrawModule)), 0, "withdraw module cUSDC drained");
        assertEq(IERC20(DAI).balanceOf(address(depositModule)), 0, "deposit module DAI drained");
        assertEq(IERC20(address(CDAI)).balanceOf(address(depositModule)), 0, "deposit module cDAI drained");
    }
}
