// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";
import {Chains, Tokens} from "@coretest/data/LenderRegistry.sol";
import {DustHandler} from "@lib/DustHandler.sol";

import {SiloRepayModule} from "../../src/SiloModules.sol";
import {ISilo} from "../../src/interfaces/ISilo.sol";

/// @title SiloRepayModuleForkTest
/// @notice 2026-09-30 audit L-FSE-6: `SiloRepayModule` had NO test anywhere in the
///         repo — neither the pull-exact SweepToUser path nor the Recycle path that
///         re-supplies through `deposit(uint256,address)`. Runs against the live
///         Silo v2 wstETH/WETH market on Ethereum mainnet (same pins as the
///         leverage suite), with the MAKE dispatched as Settlement dispatches it.
contract SiloRepayModuleForkTest is CoreSettlementBase {
    address internal constant SILO_WSTETH = 0x1a132e4e90D66E2f4FCDc99420F204D46F907aDB;
    address internal constant SILO_WETH = 0x02AE6A64a0DC17ffFDC5722Ad8270a7B32Be44db;

    uint256 internal constant COLLATERAL = 5 ether;
    uint256 internal constant DEBT = 2 ether;
    uint256 internal constant BUFFER = 0.1 ether;

    address internal WSTETH;
    SiloRepayModule internal repayModule;
    address internal liquidityProvider = address(0x11D0);

    function _forkBlock() internal view virtual override returns (uint256) {
        return 25_600_000;
    }

    function setUp() public virtual override {
        super.setUp();
        WSTETH = tokens[Chains.ETHEREUM_MAINNET][Tokens.WSTETH];
        repayModule = new SiloRepayModule(address(permit3), address(settlement));

        deal(WETH, liquidityProvider, 25 ether);
        vm.startPrank(liquidityProvider);
        IERC20(WETH).approve(SILO_WETH, type(uint256).max);
        ISilo(SILO_WETH).deposit(25 ether, liquidityProvider);
        vm.stopPrank();

        // The maker's own position: wstETH collateral, WETH debt (direct venue calls).
        deal(WSTETH, maker, COLLATERAL);
        vm.startPrank(maker);
        IERC20(WSTETH).approve(SILO_WSTETH, COLLATERAL);
        ISilo(SILO_WSTETH).deposit(COLLATERAL, maker);
        ISilo(SILO_WETH).borrow(DEBT, address(0xD0), maker); // park the cash away
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(repayModule), WETH, type(uint160).max, 0);
        vm.stopPrank();
    }

    function _repay(uint256 amount, DustHandler.DustAction action) internal {
        vm.prank(address(settlement));
        repayModule.makeOnBehalf(maker, amount, abi.encode(SILO_WETH, WETH, uint256(action)));
    }

    /// SweepToUser (the default): ceiling above the debt — the debt is cleared, the
    /// module pulls ONLY the debt, and the buffer never leaves the maker's wallet.
    function test_audit_L_FSE_6_siloRepay_sweepToUser_pullsOnlyTheDebt() public {
        uint256 debt = ISilo(SILO_WETH).maxRepay(maker);
        assertApproxEqAbs(debt, DEBT, 2, "precondition: live debt");
        deal(WETH, maker, debt + BUFFER);

        _repay(debt + BUFFER, DustHandler.DustAction.SweepToUser);

        assertEq(ISilo(SILO_WETH).maxRepay(maker), 0, "debt fully repaid");
        assertApproxEqAbs(IERC20(WETH).balanceOf(maker), BUFFER, 2, "buffer stayed in the maker's wallet");
        assertEq(IERC20(WETH).balanceOf(address(repayModule)), 0, "module ends empty");
        assertEq(IERC20(WETH).allowance(address(repayModule), SILO_WETH), 0, "silo grant cleared");
    }

    /// Recycle: the whole ceiling is pulled, the debt cleared, and the surplus
    /// RE-SUPPLIED as the maker's Collateral balance in the same silo.
    function test_audit_L_FSE_6_siloRepay_recycle_resuppliesSurplus() public {
        uint256 debt = ISilo(SILO_WETH).maxRepay(maker);
        deal(WETH, maker, debt + BUFFER);
        uint256 sharesBefore = ISilo(SILO_WETH).balanceOf(maker);

        _repay(debt + BUFFER, DustHandler.DustAction.Recycle);

        assertEq(ISilo(SILO_WETH).maxRepay(maker), 0, "debt fully repaid");
        assertEq(IERC20(WETH).balanceOf(maker), 0, "whole ceiling pulled");
        uint256 recycled = ISilo(SILO_WETH).previewRedeem(ISilo(SILO_WETH).balanceOf(maker) - sharesBefore);
        assertApproxEqAbs(recycled, BUFFER, 2, "surplus re-supplied as the maker's collateral");
        assertEq(IERC20(WETH).balanceOf(address(repayModule)), 0, "module ends empty");
        assertEq(IERC20(WETH).allowance(address(repayModule), SILO_WETH), 0, "silo grant cleared");
    }

    /// A partial repay below the debt retires exactly the signed amount.
    function test_audit_L_FSE_6_siloRepay_partial() public {
        uint256 debt = ISilo(SILO_WETH).maxRepay(maker);
        deal(WETH, maker, 1 ether);

        _repay(1 ether, DustHandler.DustAction.SweepToUser);

        assertApproxEqAbs(ISilo(SILO_WETH).maxRepay(maker), debt - 1 ether, 2, "debt reduced by the slice");
        assertEq(IERC20(WETH).balanceOf(maker), 0, "slice pulled");
        assertEq(IERC20(WETH).balanceOf(address(repayModule)), 0, "module ends empty");
    }

    /// A balance already sitting on the module (a donation) is the FLOOR: neither
    /// path pays it out to the filling maker.
    function test_audit_L_FSE_6_siloRepay_preExistingBalance_untouched() public {
        uint256 debt = ISilo(SILO_WETH).maxRepay(maker);
        deal(WETH, address(repayModule), 0.5 ether);
        deal(WETH, maker, debt + BUFFER);

        _repay(debt + BUFFER, DustHandler.DustAction.Recycle);

        assertEq(ISilo(SILO_WETH).maxRepay(maker), 0, "debt fully repaid");
        assertEq(IERC20(WETH).balanceOf(address(repayModule)), 0.5 ether, "the floor stays put");
    }

    /// The MAKE seam is Settlement-only.
    function test_audit_L_FSE_6_siloRepay_onlySettlement() public {
        vm.expectRevert(SiloRepayModule.NotSettlement.selector);
        repayModule.makeOnBehalf(maker, 1 ether, abi.encode(SILO_WETH, WETH));
    }
}
