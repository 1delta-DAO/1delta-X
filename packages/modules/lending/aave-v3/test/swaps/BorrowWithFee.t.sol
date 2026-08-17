// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";

import {IAaveCreditDelegation} from "../../src/interfaces/IAaveV3.sol";
import {AaveModulesBase} from "../shared/AaveModulesBase.t.sol";

/// @dev Gasless borrow + origination fee — the TAKE-action mirror of the
/// withdraw flow. The maker opens USDC debt and receives USDC (no conversion,
/// same asset); the integrator's origination charge is signed in as a fee OUTPUT
/// LEG addressed to the sourcer. The borrowed USDC funds the solver; the solver
/// delivers USDC back to the maker minus the fee (its own compensation being the
/// in/out spread). Structurally identical to the same-asset {WithdrawWithFeeTest}
/// with a TAKE borrow instead of a TAKE withdraw.
///
///   items    = [ TAKE AaveV3BorrowModule: borrow USDC → settlement ]
///   tokenIn  = USDC  (the borrowed proceeds fund the solver)
///   tokenOut = USDC  [net → maker, fee → originator]
contract BorrowWithFeeTest is AaveModulesBase {
    address feeRecipient = address(0x50FCE);

    function _buildBorrowOrder(uint256 nonce, uint256 borrowAmount, uint256 usdcOut)
        internal
        view
        returns (Order memory order)
    {
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.TAKE,
            module: address(borrowModule),
            amount: borrowAmount,
            recipient: address(0), //  proceeds → settlement, then paid to the solver as tokenIn
            data: abi.encode(AAVE_POOL, USDC, uint256(2))
        });
        order = _order(maker, nonce, USDC, USDC, borrowAmount, usdcOut, items);
    }

    function _approveMakerBorrowSide(uint256 borrowAmount) internal {
        bytes32 borrowRef = keccak256(abi.encode(AAVE_POOL, USDC, uint256(2)));
        vm.startPrank(maker);
        // Aave-native credit delegation: authorize the borrow module to open USDC
        // debt on the maker's behalf.
        IAaveCreditDelegation(usdcDebtToken).approveDelegation(address(borrowModule), type(uint256).max);
        // Permit3 taker gate on the exact borrow position + amount.
        permit3.approveTaker(address(settlement), address(borrowModule), borrowRef, uint160(borrowAmount), 0);
        // USDC fallback for the tokenIn shortfall — never triggers (the borrow
        // fully funds tokenIn), but keeps the shortfall path safe.
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDC, uint160(borrowAmount), 0);
        vm.stopPrank();
    }

    function test_borrow_withSourcingFee_aaveV3() public {
        uint256 borrowAmount = 2_000e6; //     opened as debt, funds the solver
        uint256 usdcOut = 1_990e6; //          solver delivers gross (10 USDC spread)
        uint256 feeBps = 250; //               2.5% — the origination charge
        uint256 fee = usdcOut * feeBps / 10_000; // 49.75 USDC to the sourcer
        uint256 makerNet = usdcOut - fee;

        _seedAWethPosition(10 ether); //       collateral to borrow against
        deal(USDC, solver, usdcOut);
        _approveMakerBorrowSide(borrowAmount);
        _approveSolverSide(usdcOut, USDC);

        Order memory order = _buildBorrowOrder(1, borrowAmount, usdcOut);
        _splitFeeLeg(order, feeRecipient, fee); // origination fee as its own output leg
        bytes memory sig = _sign(order);

        uint256 makerDebtBefore = IERC20(usdcDebtToken).balanceOf(maker);
        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);

        vm.prank(solver);
        uint256[] memory outs = settlement.fill(order, sig, borrowAmount);

        // Solver delivers the full gross; only the split changed.
        assertEq(outs[0] + outs[1], usdcOut, "solver delivered full gross usdcOut");
        assertEq(IERC20(USDC).balanceOf(maker) - makerUsdcBefore, makerNet, "maker received net of fee");
        assertEq(IERC20(USDC).balanceOf(feeRecipient), fee, "sourcer received the origination fee");

        // Borrow leg: debt opened by ~borrowAmount; the solver was funded by it.
        assertApproxEqAbs(IERC20(usdcDebtToken).balanceOf(maker) - makerDebtBefore, borrowAmount, 2, "debt opened");
        assertEq(IERC20(USDC).balanceOf(solver), borrowAmount, "solver received the borrowed USDC");

        // Nothing stranded.
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(USDC).balanceOf(address(borrowModule)), 0, "borrow module USDC drained");

        (uint160 remaining,) =
            permit3.takerAllowance(maker, address(settlement), address(borrowModule), keccak256(abi.encode(AAVE_POOL, USDC, uint256(2))));
        assertEq(remaining, 0, "taker allowance spent");
    }
}
