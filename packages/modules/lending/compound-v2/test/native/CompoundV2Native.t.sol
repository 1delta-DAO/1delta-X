// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {ICEther} from "../../src/interfaces/ICompoundV2.sol";
import {
    CompoundV2NativeDepositModule,
    CompoundV2NativeRepayModule,
    CompoundV2NativeWithdrawModule
} from "../../src/CompoundV2NativeModules.sol";
import {CompoundV2ModulesBase} from "../shared/CompoundV2ModulesBase.t.sol";

/// @dev Native cEther ops for Compound v2: proves the WETH↔ETH bridge modules let a
/// maker deposit / repay / withdraw the NATIVE market through the ERC20-only core.
/// Borrow is (correctly) absent — vanilla Compound v2 has no on-behalf borrow.
contract CompoundV2NativeTest is CompoundV2ModulesBase {
    ICEther constant CETH = ICEther(0x4Ddc2D193948926D02f9B1fE9e1daa0718270ED5);

    CompoundV2NativeDepositModule nDeposit;
    CompoundV2NativeRepayModule nRepay;
    CompoundV2NativeWithdrawModule nWithdraw;

    function setUp() public override {
        super.setUp();
        nDeposit = new CompoundV2NativeDepositModule(address(permit3), address(settlement), WETH);
        nRepay = new CompoundV2NativeRepayModule(address(permit3), address(settlement), WETH);
        nWithdraw = new CompoundV2NativeWithdrawModule(address(permit3), WETH);

        // Enter the cETH market so supplied cETH counts as collateral (for the debt seed).
        vm.prank(maker);
        address[] memory m = new address[](1);
        m[0] = address(CETH);
        COMPTROLLER.enterMarkets(m);
    }

    function _data() internal pure returns (bytes memory) {
        return abi.encode(address(CETH));
    }

    // ── deposit: WETH → unwrap → cEther.mint → maker holds cETH ──
    function test_native_deposit_mintsCeth() public {
        uint256 amt = 2 ether;
        deal(WETH, maker, amt);
        vm.startPrank(maker);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(nDeposit), WETH, uint160(amt), 0); // module is the funding spender
        vm.stopPrank();

        uint256 cBefore = IERC20(address(CETH)).balanceOf(maker);
        vm.prank(address(settlement));
        nDeposit.makeOnBehalf(maker, amt, _data());

        assertGt(IERC20(address(CETH)).balanceOf(maker) - cBefore, 0, "maker received cETH");
        assertEq(IERC20(WETH).balanceOf(maker), 0, "WETH consumed");
        assertEq(IERC20(WETH).balanceOf(address(nDeposit)), 0, "module WETH drained");
        assertEq(address(nDeposit).balance, 0, "module ETH drained");
    }

    // ── repay: WETH → unwrap → cEther.repayBorrowBehalf clears the maker's ETH debt ──
    function test_native_repay_closesEthDebt() public {
        // Seed a real ETH debt: maker supplies 3 ETH of cETH collateral, borrows 1 ETH.
        vm.deal(maker, 3 ether);
        vm.startPrank(maker);
        CETH.mint{value: 3 ether}();
        require(CETH.borrow(1 ether) == 0, "seed borrow");
        (bool ok,) = address(0xdead).call{value: 1 ether}(""); // dump the borrowed ETH
        require(ok, "dump");
        vm.stopPrank();

        uint256 debt = CETH.borrowBalanceCurrent(maker);
        assertGt(debt, 0, "has debt");
        uint256 ceiling = debt + 0.05 ether; // maker-signed ceiling above the live debt

        deal(WETH, maker, ceiling);
        vm.startPrank(maker);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(nRepay), WETH, uint160(ceiling), 0);
        vm.stopPrank();

        vm.prank(address(settlement));
        nRepay.makeOnBehalf(maker, ceiling, _data());

        assertEq(CETH.borrowBalanceStored(maker), 0, "debt fully closed");
        // Pull-exact: only `debt` was pulled — the buffer stays in the maker's wallet.
        assertEq(IERC20(WETH).balanceOf(maker), ceiling - debt, "buffer kept by maker");
        assertEq(IERC20(WETH).balanceOf(address(nRepay)), 0, "module WETH drained");
        assertEq(address(nRepay).balance, 0, "module ETH drained");
    }

    // ── withdraw: maker's cETH → redeem → wrap → WETH to receiver ──
    function test_native_withdraw_redeemsCethAsWeth() public {
        vm.deal(maker, 3 ether);
        vm.prank(maker);
        CETH.mint{value: 3 ether}();
        assertGt(IERC20(address(CETH)).balanceOf(maker), 0, "has cETH");

        vm.startPrank(maker);
        IERC20(address(CETH)).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(nWithdraw), address(CETH), type(uint160).max, 0);
        vm.stopPrank();

        uint256 withdrawAmt = 1 ether;
        uint256 wethBefore = IERC20(WETH).balanceOf(maker);
        vm.prank(address(permit3));
        nWithdraw.takeOnBehalf(maker, withdrawAmt, maker, _data());

        assertEq(IERC20(WETH).balanceOf(maker) - wethBefore, withdrawAmt, "maker received WETH");
        assertEq(IERC20(WETH).balanceOf(address(nWithdraw)), 0, "module WETH drained");
        assertEq(address(nWithdraw).balance, 0, "module ETH drained");
    }

    // ── auth guards ──
    function test_native_deposit_rejectsNonSettlement() public {
        vm.prank(maker);
        vm.expectRevert(CompoundV2NativeDepositModule.NotSettlement.selector);
        nDeposit.makeOnBehalf(maker, 1 ether, _data());
    }

    function test_native_withdraw_rejectsNonPermit3() public {
        vm.prank(maker);
        vm.expectRevert(CompoundV2NativeWithdrawModule.OnlyPermit3.selector);
        nWithdraw.takeOnBehalf(maker, 1 ether, maker, _data());
    }
}
