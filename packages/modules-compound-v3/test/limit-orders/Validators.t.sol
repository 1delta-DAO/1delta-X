// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {LimitOrderSettlement, LimitOrder, Item, ItemOp, Validator} from "@core/settlement/LimitOrderSettlement.sol";
import {ChainlinkPriceLte} from "@core/validators/ChainlinkPriceValidators.sol";

import {CompoundV3ModulesBase} from "../shared/CompoundV3ModulesBase.t.sol";

/// @dev Validators: stop-loss gating. Maker holds a WETH collateral position on
/// the USDC Comet and signs an order to unwind it into USDC, gated by a
/// Chainlink ETH/USD price validator.
///
/// Two scenarios using `ChainlinkPriceLte` (typical stop-loss: "fill when price
/// drops to X or lower"):
///   • threshold FAR BELOW current price → validator returns false → fill reverts
///   • threshold FAR ABOVE current price → validator returns true  → fill succeeds
contract ValidatorsTest is CompoundV3ModulesBase {
    address constant ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    int256 constant FAR_BELOW_MARKET = int256(500 * 1e8); //      $500 — ETH is far above
    int256 constant FAR_ABOVE_MARKET = int256(1_000_000 * 1e8); // $1M — never

    function test_validator_rejectsWhenConditionNotMet() public {
        ChainlinkPriceLte priceLte = new ChainlinkPriceLte();

        uint256 wethIn = 1 ether;
        uint256 usdcOut = 2_000e6;

        _seedWethCollateral(wethIn + 1e15);
        deal(USDC, solver, usdcOut);

        bytes memory takerData = _withdrawData(COMET, WETH);
        bytes32 ref = keccak256(takerData);

        _approveMakerWithdrawSide(wethIn, ref, takerData);
        _approveSolverSide(usdcOut, USDC);

        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.TAKE, module: address(takerModule), amount: wethIn, recipient: address(0), data: takerData});

        Validator[] memory validators = new Validator[](1);
        validators[0] = Validator({target: address(priceLte), data: abi.encode(ETH_USD_FEED, FAR_BELOW_MARKET, type(uint256).max)});

        LimitOrder memory order = _orderWithValidators(101, WETH, USDC, wethIn, usdcOut, items, validators);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(LimitOrderSettlement.ValidationFailed.selector, uint256(0)));
        settlement.fill(order, sig, wethIn);
    }

    function test_validator_passesWhenConditionMet() public {
        ChainlinkPriceLte priceLte = new ChainlinkPriceLte();

        uint256 wethIn = 1 ether;
        uint256 usdcOut = 2_000e6;

        _seedWethCollateral(wethIn + 1e15);
        deal(USDC, solver, usdcOut);

        bytes memory takerData = _withdrawData(COMET, WETH);
        bytes32 ref = keccak256(takerData);

        _approveMakerWithdrawSide(wethIn, ref, takerData);
        _approveSolverSide(usdcOut, USDC);

        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.TAKE, module: address(takerModule), amount: wethIn, recipient: address(0), data: takerData});

        Validator[] memory validators = new Validator[](1);
        validators[0] = Validator({target: address(priceLte), data: abi.encode(ETH_USD_FEED, FAR_ABOVE_MARKET, type(uint256).max)});

        LimitOrder memory order = _orderWithValidators(102, WETH, USDC, wethIn, usdcOut, items, validators);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, wethIn);

        assertEq(paid, usdcOut, "filled when gate opened");
        assertEq(IERC20(USDC).balanceOf(maker), usdcOut, "maker received USDC");
    }
}
