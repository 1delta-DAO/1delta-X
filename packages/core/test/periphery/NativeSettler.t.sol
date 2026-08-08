// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item} from "@core/settlement/Settlement.sol";
import {NativeSettler} from "@core/periphery/NativeSettler.sol";
import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

/// @dev Frontend route stand-in (same shape as the SolverCallback SwapHelper):
///      pulls `amtIn` of `tokenIn` from `who` (who approved it) and returns `amtOut`
///      of `tokenOut` from its own stock — modelling a DEX swap of the just-received
///      WETH into the order's output.
contract RouteHelper {
    function swap(address who, address tokenIn, uint256 amtIn, address tokenOut, uint256 amtOut) external {
        IERC20(tokenIn).transferFrom(who, address(this), amtIn);
        IERC20(tokenOut).transfer(who, amtOut);
    }
}

/// @dev Proves native currency CAN settle through the ERC20-only core via the
///      `NativeSettler` periphery: a user pays native ETH, self-settles in one tx,
///      and receives the order's tokenOut — no core change.
contract NativeSettlerTest is CoreSettlementBase {
    NativeSettler settler;
    RouteHelper route;

    function setUp() public override {
        super.setUp();
        settler = new NativeSettler(WETH, address(settlement));
        route = new RouteHelper();
        vm.label(address(settler), "nativeSettler");
        vm.label(address(route), "route");
    }

    function test_selfSettle_nativeIn_userSellsEthForUsdc() public {
        uint256 ethIn = 1 ether;
        uint256 usdcOut = 2_000e6; // frontend quote (the maker's signed min-out)

        // The route is pre-stocked with the output asset.
        deal(USDC, address(route), usdcOut);

        // One-time maker setup: let Settlement pull WETH from the maker via Permit3.
        // (The bare WETH->Permit3 approve is already granted in the base setUp.)
        vm.prank(maker);
        permit3.approveToken(address(settlement), WETH, uint160(ethIn), 0);

        // The maker signs a fixed-price order: sell WETH for USDC (no decay, self-settle).
        Order memory order = _order(maker, 0, WETH, USDC, ethIn, usdcOut, new Item[](0));
        bytes memory sig = _sign(order);

        // Frontend builds the route calldata: pull the settler's WETH, return USDC to it.
        bytes memory routeData = abi.encodeCall(RouteHelper.swap, (address(settler), WETH, ethIn, USDC, usdcOut));

        // The user holds NATIVE ETH and self-settles in one call.
        vm.deal(maker, ethIn);
        vm.prank(maker);
        settler.settleFromNative{value: ethIn}(order, sig, ethIn, address(route), routeData);

        // Maker spent native ETH and received USDC; nothing stranded anywhere.
        assertEq(maker.balance, 0, "maker spent all native ETH");
        assertEq(IERC20(USDC).balanceOf(maker), usdcOut, "maker received the quoted USDC");
        assertEq(IERC20(WETH).balanceOf(maker), 0, "no leftover WETH in maker wallet");
        assertEq(IERC20(WETH).balanceOf(address(settler)), 0, "settler holds no WETH");
        assertEq(IERC20(USDC).balanceOf(address(settler)), 0, "settler holds no USDC");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement drained");
    }

    function test_settleFromNative_rejectsNonMakerCaller() public {
        uint256 ethIn = 1 ether;
        Order memory order = _order(maker, 1, WETH, USDC, ethIn, 2_000e6, new Item[](0));
        bytes memory sig = _sign(order);
        bytes memory routeData = abi.encodeCall(RouteHelper.swap, (address(settler), WETH, ethIn, USDC, 2_000e6));

        vm.deal(solver, ethIn);
        vm.prank(solver); // not the maker
        vm.expectRevert(NativeSettler.NotMaker.selector);
        settler.settleFromNative{value: ethIn}(order, sig, ethIn, address(route), routeData);
    }

    function test_settleFromNative_rejectsNonWethTokenIn() public {
        uint256 usdcIn = 2_000e6;
        Order memory order = _order(maker, 2, USDC, WETH, usdcIn, 1 ether, new Item[](0));
        bytes memory sig = _sign(order);
        bytes memory routeData = abi.encodeCall(RouteHelper.swap, (address(settler), USDC, usdcIn, WETH, 1 ether));

        vm.deal(maker, 1 ether);
        vm.prank(maker);
        vm.expectRevert(NativeSettler.TokenInNotWeth.selector);
        settler.settleFromNative{value: 1 ether}(order, sig, usdcIn, address(route), routeData);
    }
}
