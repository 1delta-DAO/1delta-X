// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {FluidModulesBase} from "../shared/FluidModulesBase.t.sol";
import {FluidOperateModule, FluidTakerModule} from "../../src/FluidModules.sol";

/// @dev Integration tests for the Fluid modules against the real ETH-USDC T1 vault
/// on a mainnet fork — the same cases the 1delta composer's FluidLending test covers,
/// re-expressed through the Permit3 module flow:
///
///   • repay      — value-in, permissionless, Permit3 token allowance only.
///   • borrow     — value-out, JIT NFT custody, Permit3 taker allowance.
///   • withdraw   — value-out, JIT NFT custody, native-ETH collateral to `recv`.
///   • full close — Level B: repay-ALL (over-pull + residual sweep) + withdraw, one operate.
///
/// (Deposit of native-ETH collateral is out of scope — the ERC20 deposit module needs
/// a vault with an ERC20 collateral token; on this vault USDC is the debt asset.)
contract FluidLendingIntegrationTest is FluidModulesBase {
    function test_fluid_repay_pull_exact() public {
        uint256 nftId = _openPosition(maker, 1 ether, 1000e6);

        uint256 repayAmount = 500e6;
        deal(USDC, maker, repayAmount);
        // maker→permit3 ERC20 approve already set in CoreSettlementBase.setUp().
        vm.prank(maker);
        permit3.approveToken(address(repayModule), USDC, uint160(repayAmount), 0);

        bytes memory data = abi.encode(VAULT, USDC, nftId);
        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);

        // makeOnBehalf is gated to the settlement contract; the Permit3 token
        // allowance is the value gate.
        vm.prank(address(settlement));
        repayModule.makeOnBehalf(maker, repayAmount, data);

        assertEq(makerUsdcBefore - IERC20(USDC).balanceOf(maker), repayAmount, "maker spent the repay amount");
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), 0, "repay module holds no residual");
        assertEq(_ownerOf(nftId), maker, "maker still owns the position");
    }

    function test_fluid_borrow_jit_custody() public {
        uint256 nftId = _openPosition(maker, 1 ether, 1000e6);

        uint256 borrowAmount = 200e6;
        bytes memory data = abi.encode(uint8(FluidTakerModule.Op.Borrow), VAULT, VAULT_FACTORY, nftId);

        vm.prank(maker);
        permit3.approveTaker(address(settlement), keccak256(data), uint160(borrowAmount), 0);

        uint256 recvBefore = IERC20(USDC).balanceOf(recv);

        // The taker book is keyed by spender (settlement); the maker's taker
        // allowance on (settlement, ref) is the gate.
        vm.prank(address(settlement));
        permit3.take(address(takerModule), maker, uint160(borrowAmount), recv, data);

        assertEq(IERC20(USDC).balanceOf(recv) - recvBefore, borrowAmount, "receiver got the borrow");
        assertEq(_ownerOf(nftId), maker, "position NFT returned to maker");
        assertEq(IERC20(USDC).balanceOf(address(takerModule)), 0, "taker module clean");
    }

    function test_fluid_withdraw_jit_custody_native_collateral() public {
        uint256 nftId = _openPosition(maker, 1 ether, 1000e6);

        uint256 withdrawAmount = 0.1 ether;
        bytes memory data = abi.encode(uint8(FluidTakerModule.Op.Withdraw), VAULT, VAULT_FACTORY, nftId);

        vm.prank(maker);
        permit3.approveTaker(address(settlement), keccak256(data), uint160(withdrawAmount), 0);

        uint256 recvEthBefore = recv.balance;

        vm.prank(address(settlement));
        permit3.take(address(takerModule), maker, uint160(withdrawAmount), recv, data);

        assertEq(recv.balance - recvEthBefore, withdrawAmount, "receiver got withdrawn ETH");
        assertEq(_ownerOf(nftId), maker, "position NFT returned to maker");
        assertEq(address(takerModule).balance, 0, "taker module holds no ETH");
    }

    function test_fluid_operate_full_close_repay_all_and_withdraw() public {
        uint256 nftId = _openPosition(maker, 1 ether, 1000e6);

        uint256 ceiling = 1100e6; // over-pull buffer; Fluid consumes only the live debt
        uint256 withdrawCol = 0.9 ether; // exact collateral leg
        deal(USDC, maker, ceiling);

        FluidOperateModule.OperateData memory p = FluidOperateModule.OperateData({
            mode: uint256(FluidOperateModule.Mode.Close),
            vault: VAULT,
            factory: VAULT_FACTORY,
            fundingToken: USDC,
            nftId: nftId,
            sideAmount: type(uint256).max, // FLUID_ALL ⇒ repay the entire debt
            repayCeiling: ceiling
        });
        bytes memory data = abi.encode(p);

        vm.startPrank(maker);
        permit3.approveToken(address(operateModule), USDC, uint160(ceiling), 0);
        permit3.approveTaker(address(settlement), keccak256(data), uint160(withdrawCol), 0);
        vm.stopPrank();

        uint256 recvEthBefore = recv.balance;
        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);

        // `amount` is the collateral-withdraw leg (value-out); the debt leg repays all.
        vm.prank(address(settlement));
        permit3.take(address(operateModule), maker, uint160(withdrawCol), recv, data);

        assertEq(recv.balance - recvEthBefore, withdrawCol, "receiver got withdrawn collateral");

        uint256 usdcSpent = makerUsdcBefore - IERC20(USDC).balanceOf(maker);
        assertGe(usdcSpent, 1000e6, "spent at least the principal debt");
        assertLe(usdcSpent, ceiling, "spent at most the funded ceiling (residual swept back)");

        assertEq(IERC20(USDC).balanceOf(address(operateModule)), 0, "operate module swept the repay residual");
        assertEq(_ownerOf(nftId), maker, "position NFT returned to maker");
    }
}
