// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SettlementBase} from "@core/settlement/SettlementBase.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {UniversalSettlement, Order, Item, ItemOp, Validator} from "@core/settlement/UniversalSettlement.sol";

import {TrueInvariant, FalseInvariant} from "../shared/Modules.sol";
import {AaveModulesBase} from "../shared/AaveModulesBase.t.sol";

/// @dev Post-execution invariants run after all items execute. A `FalseInvariant`
/// makes the whole fill revert and rolls maker state back; a `TrueInvariant` lets
/// it complete.
contract InvariantsTest is AaveModulesBase {
    function test_invariants_rollBackOnFailure() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;

        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);

        _approveMakerSide(usdcIn, wethOut);
        _approveSolverSide(wethOut, WETH);

        FalseInvariant failing = new FalseInvariant();

        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.MAKE, module: address(depositModule), amount: wethOut, recipient: address(0), data: abi.encode(AAVE_POOL, WETH)});

        Validator[] memory invariants = new Validator[](1);
        invariants[0] = Validator({target: address(failing), data: ""});

        Order memory order = _orderWithInvariants(204, USDC, WETH, usdcIn, wethOut, items, invariants);
        bytes memory sig = _sign(order);

        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);
        uint256 makerAWethBefore = IERC20(aWETH).balanceOf(maker);

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(SettlementBase.InvariantFailed.selector, uint256(0)));
        settlement.fill(order, sig, usdcIn);

        // Entire fill reverted — maker's state is exactly as before.
        assertEq(IERC20(USDC).balanceOf(maker), makerUsdcBefore, "maker USDC unchanged");
        assertEq(IERC20(aWETH).balanceOf(maker), makerAWethBefore, "maker aWETH unchanged");
    }

    function test_invariants_passWhenTrue() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;

        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);

        _approveMakerSide(usdcIn, wethOut);
        _approveSolverSide(wethOut, WETH);

        TrueInvariant passing = new TrueInvariant();

        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.MAKE, module: address(depositModule), amount: wethOut, recipient: address(0), data: abi.encode(AAVE_POOL, WETH)});

        Validator[] memory invariants = new Validator[](1);
        invariants[0] = Validator({target: address(passing), data: ""});

        Order memory order = _orderWithInvariants(205, USDC, WETH, usdcIn, wethOut, items, invariants);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, usdcIn)[0];
        assertEq(paid, wethOut, "passing invariant lets the fill complete");
    }
}
