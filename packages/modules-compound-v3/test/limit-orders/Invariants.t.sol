// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {LimitOrderSettlement, LimitOrder, Item, ItemOp, Validator} from "@core/settlement/LimitOrderSettlement.sol";

import {TrueInvariant, FalseInvariant} from "../shared/Modules.sol";
import {CompoundV3ModulesBase} from "../shared/CompoundV3ModulesBase.t.sol";

/// @dev Post-execution invariants run after all items execute. A `FalseInvariant`
/// makes the whole fill revert and rolls maker state back; a `TrueInvariant` lets
/// it complete.
contract InvariantsTest is CompoundV3ModulesBase {
    function test_invariants_rollBackOnFailure() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;

        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);

        _approveMakerSide(usdcIn, wethOut);
        _approveSolverSide(wethOut, WETH);

        FalseInvariant failing = new FalseInvariant();

        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.MAKE, module: address(depositModule), amount: wethOut, recipient: address(0), data: abi.encode(COMET, WETH)});

        Validator[] memory invariants = new Validator[](1);
        invariants[0] = Validator({target: address(failing), data: ""});

        LimitOrder memory order = _orderWithInvariants(204, USDC, WETH, usdcIn, wethOut, items, invariants);
        bytes memory sig = _sign(order);

        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);
        uint256 makerCollatBefore = _wethCollateral(maker);

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(LimitOrderSettlement.InvariantFailed.selector, uint256(0)));
        settlement.fill(order, sig, usdcIn);

        // Entire fill reverted — maker's state is exactly as before.
        assertEq(IERC20(USDC).balanceOf(maker), makerUsdcBefore, "maker USDC unchanged");
        assertEq(_wethCollateral(maker), makerCollatBefore, "maker collateral unchanged");
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
        items[0] = Item({op: ItemOp.MAKE, module: address(depositModule), amount: wethOut, recipient: address(0), data: abi.encode(COMET, WETH)});

        Validator[] memory invariants = new Validator[](1);
        invariants[0] = Validator({target: address(passing), data: ""});

        LimitOrder memory order = _orderWithInvariants(205, USDC, WETH, usdcIn, wethOut, items, invariants);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, usdcIn);
        assertEq(paid, wethOut, "passing invariant lets the fill complete");
    }
}
