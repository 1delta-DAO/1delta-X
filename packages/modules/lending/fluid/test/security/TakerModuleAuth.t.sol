// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";

import {FluidTakerModule, FluidOperateModule} from "../../src/FluidModules.sol";

/// @dev The taker modules MUST reject any caller other than Permit3 — otherwise a
/// direct `takeOnBehalf(victim, amount, attacker, data)` would bypass the Permit3
/// allowance gate and, combined with the victim's `setApprovalForAll` grant on the
/// VaultFactory, let any caller pull the victim's position NFT and borrow/withdraw
/// it to an attacker-chosen `receiver`. This is the load-bearing invariant for the
/// broad ERC721 operator grant the value-out modules rely on.
///
/// Pure auth check — no fork needed (it reverts before touching Fluid).
contract FluidTakerModuleAuthTest is Test {
    address constant PERMIT3 = address(0xBEEF);
    address constant VAULT = address(0x1111);
    address constant FACTORY = address(0x2222);
    address constant TOKEN = address(0x3333);

    address maker = address(0xA11CE);
    address attacker = address(0xBAD);

    FluidTakerModule takerModule;
    FluidOperateModule operateModule;

    function setUp() public {
        takerModule = new FluidTakerModule(PERMIT3, FACTORY, address(0x4444));
        operateModule = new FluidOperateModule(PERMIT3, FACTORY, address(0x4444));
    }

    function test_borrow_rejects_non_permit3() public {
        vm.prank(attacker);
        vm.expectRevert(FluidTakerModule.OnlyPermit3.selector);
        takerModule.takeOnBehalf(
            maker, 1_000e6, attacker, abi.encode(uint8(FluidTakerModule.Op.Borrow), VAULT, FACTORY, uint256(42))
        );
    }

    function test_withdraw_rejects_non_permit3() public {
        vm.prank(attacker);
        vm.expectRevert(FluidTakerModule.OnlyPermit3.selector);
        takerModule.takeOnBehalf(
            maker, 1 ether, attacker, abi.encode(uint8(FluidTakerModule.Op.Withdraw), VAULT, FACTORY, uint256(42))
        );
    }

    function test_operate_rejects_non_permit3() public {
        FluidOperateModule.OperateData memory p = FluidOperateModule.OperateData({
            mode: uint256(FluidOperateModule.Mode.Close),
            vault: VAULT,
            factory: FACTORY,
            fundingToken: TOKEN,
            nftId: 42,
            sideAmount: 1_000e6,
            repayCeiling: 0,
            totalAmount: 1e18
        });
        vm.prank(attacker);
        vm.expectRevert(FluidOperateModule.OnlyPermit3.selector);
        operateModule.takeOnBehalf(maker, 1 ether, attacker, abi.encode(p));
    }

    /// @dev Re-audit F30: `mode` is range-checked on the FULL word (enum
    ///      conversion panic), so `mode = 256` no longer runs Open.
    function test_operate_modeWordAbove255_reverts() public {
        FluidOperateModule.OperateData memory p = FluidOperateModule.OperateData({
            mode: 256 + uint256(FluidOperateModule.Mode.Open),
            vault: VAULT,
            factory: FACTORY,
            fundingToken: TOKEN,
            nftId: 42,
            sideAmount: 1_000e6,
            repayCeiling: 0,
            totalAmount: 1e18
        });
        vm.prank(PERMIT3);
        vm.expectRevert(stdError.enumConversionError);
        operateModule.takeOnBehalf(maker, 1e18, attacker, abi.encode(p));
    }
}
