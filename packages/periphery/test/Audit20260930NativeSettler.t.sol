// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, LegOut} from "@core/settlement/Settlement.sol";
import {NativeSettler} from "@periphery/NativeSettler.sol";
import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

/// @dev Route stand-in that pulls the settler's WETH and returns `amtOut` of
///      `tokenOut` — the pull-from-the-settler shape {NativeSettler} documents.
contract FeeSplitRoute20260930 {
    function swap(address who, address tokenIn, uint256 amtIn, address tokenOut, uint256 amtOut) external {
        IERC20(tokenIn).transferFrom(who, address(this), amtIn);
        IERC20(tokenOut).transfer(who, amtOut);
    }
}

/// @title Audit 2026-09-30 PERIPH-9 — NativeSettler order shape
/// @notice The settler took exactly one output leg, so the SDK's fee-split
///         `[LegOut, LegOut]` and originator fee legs could not pay native in. Any
///         number of output legs now settles, each token approved for its summed
///         ceiling, floored and swept.
contract Audit20260930NativeSettlerTest is CoreSettlementBase {
    NativeSettler settler;
    FeeSplitRoute20260930 route;
    address constant FEE = address(0xFEE5);

    function setUp() public override {
        super.setUp();
        settler = new NativeSettler(WETH, address(settlement));
        route = new FeeSplitRoute20260930();
    }

    function test_audit_PERIPH_9_feeSplitOutputs_settleFromNative() public {
        uint256 ethIn = 1 ether;
        uint256 toMaker = 2_000e6;
        uint256 fee = 10e6;
        deal(USDC, address(route), toMaker + fee);
        vm.prank(maker);
        permit3.approveToken(address(settlement), WETH, uint160(ethIn), 0);

        Order memory order = _order(maker, 900, WETH, USDC, ethIn, toMaker, new Item[](0));
        LegOut[] memory lo = new LegOut[](2);
        lo[0] = LegOut(USDC, toMaker, 0, address(0));
        lo[1] = LegOut(USDC, fee, 0, FEE); // the fee leg
        order.legsOut = PackedEncode.legsOut(lo);
        bytes memory sig = _sign(order);
        bytes memory routeData =
            abi.encodeCall(FeeSplitRoute20260930.swap, (address(settler), WETH, ethIn, USDC, toMaker + fee));

        vm.deal(maker, ethIn);
        vm.prank(maker);
        settler.settleFromNative{value: ethIn}(order, sig, ethIn, address(route), routeData);

        assertEq(IERC20(USDC).balanceOf(maker), toMaker, "maker leg delivered");
        assertEq(IERC20(USDC).balanceOf(FEE), fee, "fee leg delivered");
        assertEq(IERC20(USDC).balanceOf(address(settler)), 0, "nothing held");
        assertEq(IERC20(WETH).balanceOf(address(settler)), 0, "nothing held");
        assertEq(IERC20(USDC).allowance(address(settler), address(settlement)), 0, "nothing approved");
    }

    function test_audit_PERIPH_9_noOutputLeg_refused() public {
        Order memory order = _order(maker, 901, WETH, USDC, 1 ether, 2_000e6, new Item[](0));
        order.legsOut = PackedEncode.legsOut(new LegOut[](0));
        bytes memory sig = _sign(order);
        vm.deal(maker, 1 ether);
        vm.prank(maker);
        vm.expectRevert(NativeSettler.OutputLegRequired.selector);
        settler.settleFromNative{value: 1 ether}(order, sig, 1 ether, address(route), "");
    }
}
