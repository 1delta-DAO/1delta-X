// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UniversalSettlement, Order, Item, ItemOp} from "@core/settlement/UniversalSettlement.sol";

import {CompoundV3ModulesBase} from "../shared/CompoundV3ModulesBase.t.sol";

/// @dev Exclusivity: `exclusiveFiller` + `exclusivityEndTime` gate the order to a
/// single solver for a window. After the window expires, anyone may fill.
contract ExclusivityTest is CompoundV3ModulesBase {
    function test_exclusivity_nonExclusiveFillerReverts() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;

        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);

        _approveMakerSide(usdcIn, wethOut);
        _approveSolverSide(wethOut, WETH);

        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.MAKE, module: address(depositModule), amount: wethOut, recipient: address(0), data: abi.encode(COMET, WETH)});

        // Exclusive to a specific address that is NOT our `solver`.
        address exclusive = address(0xCAFE);
        Order memory order =
            _orderWithExclusivity(201, USDC, WETH, usdcIn, wethOut, items, exclusive, uint32(block.timestamp + 30));
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(UniversalSettlement.NotExclusiveFiller.selector);
        settlement.fill(order, sig, usdcIn);
    }

    function test_exclusivity_expiresAndAnyoneCanFill() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;

        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);

        _approveMakerSide(usdcIn, wethOut);
        _approveSolverSide(wethOut, WETH);

        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.MAKE, module: address(depositModule), amount: wethOut, recipient: address(0), data: abi.encode(COMET, WETH)});

        address exclusive = address(0xCAFE);
        // Window already expired (endTime in the past clears the gate).
        uint32 endTime = uint32(block.timestamp - 1);
        Order memory order = _orderWithExclusivity(202, USDC, WETH, usdcIn, wethOut, items, exclusive, endTime);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, usdcIn);
        assertEq(paid, wethOut, "filled after exclusivity expired");
    }
}
