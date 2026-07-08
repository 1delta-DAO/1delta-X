// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IAaveV3Pool} from "../../src/interfaces/IAaveV3.sol";
import {AaveV3WithdrawModule} from "../../src/AaveV3Modules.sol";
import {AaveModulesBase} from "../shared/AaveModulesBase.t.sol";

/// @dev Taker module security. The `msg.sender == permit3` check is load-bearing:
/// without it, a direct takeOnBehalf call would bypass the Permit3 taker-allowance
/// gate and drain the victim via their token allowance.
contract TakerModuleAuthTest is AaveModulesBase {
    function test_takeOnBehalf_rejectsDirectCall() public {
        // Seed position so a successful drain would actually move tokens.
        deal(WETH, maker, 1 ether);
        vm.startPrank(maker);
        IERC20(WETH).approve(AAVE_POOL, 1 ether);
        IAaveV3Pool(AAVE_POOL).supply(WETH, 1 ether, maker, 0);
        IERC20(aWETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(withdrawModule), aWETH, type(uint160).max, 0);
        // (No taker approval — simulating a user who hasn't granted this specific op.)
        vm.stopPrank();

        bytes memory data = abi.encode(AAVE_POOL, WETH, aWETH);

        // Attacker tries to invoke the module directly, pointing `receiver` at themselves.
        address attacker = address(0xDEAD);
        vm.prank(attacker);
        vm.expectRevert(AaveV3WithdrawModule.OnlyPermit3.selector);
        withdrawModule.takeOnBehalf(maker, 1 ether, attacker, data);
    }
}
