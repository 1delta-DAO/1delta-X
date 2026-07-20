// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, OrderSide, Validator} from "@core/settlement/Settlement.sol";

import {CompoundV3ModulesBase} from "../shared/CompoundV3ModulesBase.t.sol";

/// @dev Base-deposit entry + rising relayer fee: the "integrator earn product"
/// on-ramp, mirroring the base-withdraw exit in {WithdrawWithFeeTest}. The maker
/// enters a USDC earn position gaslessly; with no conversion leg to price a
/// filler's compensation into, the order carries a same-asset fee leg that
/// dutch-RISES (`startAmountIn < endAmountIn`) until filling covers a relayer's
/// gas + margin — auction-discovered, zero filler capital:
///
///   items    = MAKE deposit D USDC       (CometDepositModule `supplyTo` base)
///   tokenIn  = USDC, F0 → FMAX rising    (the relayer fee, maker pays)
///   tokenOut = —                         (empty; nothing is delivered back)
///
/// Production deposits should be full-fill-only (`minFillAnchor = anchor`);
/// the partial-fill test below only pins the pro-rata math.
contract DepositWithFeeTest is CompoundV3ModulesBase {
    uint256 constant DEPOSIT = 2_000e6; //  the deposited principal
    uint256 constant F0 = 1e6; //           fee floor (auction start, best for maker)
    uint256 constant FMAX = 5e6; //         fee ceiling (auction end, worst for maker)
    uint32 constant DURATION = 1000;

    function _buildDepositOrder(uint256 nonce) internal view returns (Order memory order) {
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(depositModule),
            amount: DEPOSIT,
            recipient: address(0),
            data: abi.encode(COMET, USDC)
        });
        order = Order({
            maker: maker,
            side: OrderSide.SELL,
            nonce: nonce,
            deadline: block.timestamp + 1 hours,
            tokenIn: _a1(USDC),
            startAmountIn: _u1(F0),
            endAmountIn: _u1(FMAX),
            decayStartTime: uint32(block.timestamp),
            decayDuration: DURATION,
            tokenOut: new address[](0),
            startAmountOut: new uint256[](0),
            endAmountOut: new uint256[](0),
            recipientOut: new address[](0),
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
            fillModule: address(0),
            fillTotal: 0
        });
    }

    function _approveMakerDepositSide() internal {
        vm.startPrank(maker);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        // Deposit module pulls the principal from the maker during MAKE.
        permit3.approveToken(address(depositModule), USDC, uint160(DEPOSIT), 0);
        // Settlement pulls the (risen) fee leg — cap at the auction ceiling.
        permit3.approveToken(address(settlement), USDC, uint160(FMAX), 0);
        vm.stopPrank();
    }

    function test_depositBase_withRisingFee_cometV3() public {
        deal(USDC, maker, DEPOSIT + FMAX);
        _approveMakerDepositSide();

        Order memory order = _buildDepositOrder(21);
        bytes memory sig = _sign(order);

        vm.warp(block.timestamp + DURATION / 2); // bump = 5000
        uint256 fee = F0 + (FMAX - F0) / 2; //      3e6

        vm.prank(solver);
        settlement.fill(order, sig, F0); //         anchor = the fee floor

        // The earn position opened in full; the relayer earned the risen tick.
        assertApproxEqAbs(_baseSupply(maker), DEPOSIT, 2, "maker base supply opened");
        assertEq(IERC20(USDC).balanceOf(solver), fee, "relayer earned the auction-tick fee");
        assertEq(IERC20(USDC).balanceOf(maker), FMAX - fee, "maker paid principal + risen fee");

        // Nothing stranded.
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(USDC).balanceOf(address(depositModule)), 0, "module USDC drained");
    }

    /// @dev Two half fills: deposit slices and the fee leg scale by the same fill
    /// fraction, each fee slice priced at its own tick.
    function test_depositBase_withRisingFee_partialFills_cometV3() public {
        deal(USDC, maker, DEPOSIT + FMAX);
        _approveMakerDepositSide();

        Order memory order = _buildDepositOrder(22);
        bytes memory sig = _sign(order);

        // First half at the floor tick.
        vm.prank(solver);
        settlement.fill(order, sig, F0 / 2);
        uint256 fee1 = F0 / 2; // (F0/2 · F0) / F0
        assertEq(IERC20(USDC).balanceOf(solver), fee1, "first slice at floor tick");
        assertApproxEqAbs(_baseSupply(maker), DEPOSIT / 2, 2, "half the position opened");

        // Second half mid-decay. Re-baseline after the warp — the base supply
        // accrues interest over the 500s and would skew a whole-order delta.
        vm.warp(block.timestamp + DURATION / 2);
        uint256 supplyMid = _baseSupply(maker);
        vm.prank(solver);
        settlement.fill(order, sig, F0 - F0 / 2);
        uint256 fee2 = ((F0 - F0 / 2) * (F0 + (FMAX - F0) / 2)) / F0; // risen tick
        assertEq(IERC20(USDC).balanceOf(solver), fee1 + fee2, "second slice at the risen tick");
        assertApproxEqAbs(_baseSupply(maker) - supplyMid, DEPOSIT / 2, 2, "second half opened");

        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
    }
}
