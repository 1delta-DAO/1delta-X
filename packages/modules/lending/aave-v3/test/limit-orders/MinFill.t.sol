// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OrderState} from "@core/settlement/OrderState.sol";
import {Base} from "@core/settlement/Base.sol";
import {Settlement, Order, Item, ItemOp} from "@core/settlement/Settlement.sol";

import {AaveModulesBase} from "../shared/AaveModulesBase.t.sol";

/// @dev minFillAmountIn (anti-dust): a fill smaller than the maker-signed floor
/// is rejected.
contract MinFillTest is AaveModulesBase {
    function test_minFillAmountIn_rejectsTooSmall() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;

        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);

        _approveMakerSide(usdcIn, wethOut);
        _approveSolverSide(wethOut, WETH);

        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(depositModule),
            amount: wethOut,
            recipient: address(0),
            data: abi.encode(AAVE_POOL, WETH)
        });

        // Sign with minFillAmountIn = 100 USDC. Attempt a 50 USDC fill → reverts.
        Order memory order = _orderWithMinFill(203, USDC, WETH, usdcIn, wethOut, items, 100e6);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(OrderState.FillTooSmall.selector);
        settlement.fill(order, sig, 50e6);
    }
}
