// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {FluidModulesBase} from "../shared/FluidModulesBase.t.sol";
import {FluidOperateModule} from "../../src/FluidModules.sol";
import {IFluidVault} from "../../src/interfaces/IFluid.sol";

/// @dev Repay-to-zero coverage for {FluidOperateModule}'s Close path.
///
/// Fluid is the one lending module that closes a position through a *sentinel*
/// rather than a read: `sideAmount == FLUID_ALL` maps to Fluid's
/// `type(int256).min`, the vault consumes the exact live debt out of the
/// `repayCeiling` the module pulled, and the residual is swept back. The
/// integration test that exercises this path opens and closes inside one block,
/// where the live debt equals the opening principal and the sentinel is
/// indistinguishable from an exact amount. These tests warp first, so the live
/// debt is strictly above the principal — the only regime where the sentinel is
/// doing any work — and then assert the position is actually closed rather than
/// merely paid down.
///
/// The vault exposes no position getter, so "debt == 0" is proven behaviourally:
/// Fluid runs a single health check at the end of `operate`, and a position
/// carrying ANY debt cannot have its collateral taken to zero. Withdrawing the
/// entire collateral therefore succeeds if and only if the debt is exactly zero.
contract FluidFullCloseTest is FluidModulesBase {
    uint256 constant COLLATERAL = 1 ether;
    uint256 constant PRINCIPAL = 1_000e6;
    uint256 constant CEILING = 1_100e6;

    /// @dev See the contract note: a full-collateral withdrawal is the observable
    ///      proxy for "no debt left". Snapshot / roll back so the probe is a pure read.
    function _debtIsZero(uint256 nftId) internal returns (bool ok) {
        address owner_ = _ownerOf(nftId);
        uint256 snap = vm.snapshotState();
        vm.prank(owner_);
        try IFluidVault(VAULT).operate(nftId, type(int256).min, 0, owner_) {
            ok = true;
        } catch {
            ok = false;
        }
        vm.revertToState(snap);
    }

    function _close(uint256 nftId, uint256 sideAmount, uint256 withdrawCol) internal {
        FluidOperateModule.OperateData memory p = FluidOperateModule.OperateData({
            mode: uint256(FluidOperateModule.Mode.Close),
            vault: VAULT,
            factory: VAULT_FACTORY,
            fundingToken: USDC,
            nftId: nftId,
            sideAmount: sideAmount,
            repayCeiling: CEILING,
            totalAmount: withdrawCol // composite items are full-fill only
        });
        bytes memory data = abi.encode(p);

        vm.startPrank(maker);
        permit3.approveToken(address(operateModule), USDC, uint160(CEILING), 0);
        permit3.approveTaker(address(settlement), address(operateModule), keccak256(data), uint160(withdrawCol), 0);
        vm.stopPrank();

        vm.prank(address(settlement));
        permit3.take(address(operateModule), maker, uint160(withdrawCol), recv, data);
    }

    function test_fluid_close_repayAll_afterAccrual_leavesZeroDebt() public {
        uint256 nftId = _openPosition(maker, COLLATERAL, PRINCIPAL);

        // Accrue, so the live debt is strictly above the signed principal.
        vm.warp(block.timestamp + 30 days);

        uint256 withdrawCol = 0.9 ether;
        deal(USDC, maker, CEILING);
        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);

        _close(nftId, type(uint256).max, withdrawCol); // FLUID_ALL

        assertTrue(_debtIsZero(nftId), "sentinel closed the debt to zero");

        // The sentinel is what makes this hold: the vault consumed MORE than the
        // signed principal out of the ceiling, and the module swept the rest back.
        uint256 spent = makerUsdcBefore - IERC20(USDC).balanceOf(maker);
        assertGt(spent, PRINCIPAL, "paid the accrued interest on top of the principal");
        assertLt(spent, CEILING, "residual swept back to the maker");
        assertEq(IERC20(USDC).balanceOf(address(operateModule)), 0, "operate module clean");
        assertEq(_ownerOf(nftId), maker, "position NFT returned to maker");
    }

    /// @dev The counterfactual the sentinel exists for: an exact amount quoted from
    ///      the opening principal under-repays once interest has accrued, and the
    ///      position stays open with the accrued interest as residual debt.
    function test_fluid_close_exactStalePrincipal_leavesResidualDebt() public {
        uint256 nftId = _openPosition(maker, COLLATERAL, PRINCIPAL);

        vm.warp(block.timestamp + 30 days);

        uint256 withdrawCol = 0.9 ether;
        deal(USDC, maker, CEILING);

        _close(nftId, PRINCIPAL, withdrawCol); // exact, stale

        assertFalse(_debtIsZero(nftId), "stale principal cannot close the position");
        assertEq(IERC20(USDC).balanceOf(address(operateModule)), 0, "operate module clean");
    }
}
