// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {LimitOrderLeverageSolver} from "@solvers/single-input/LimitOrderLeverageSolver.sol";
import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";

import {IEulerVault, IEVC} from "../../src/interfaces/IEulerV2.sol";
import {
    EulerV2DepositModule,
    EulerV2RepayModule,
    EulerV2TakerModule,
    EulerV2BatchModule
} from "../../src/EulerV2Modules.sol";

/// @dev Euler V2 integration harness. Forks mainnet at the default block (the EVC
/// and both vaults are live there) and drives a WETH-collateral / USDC-debt
/// position across the Euler vault pair, mirroring the Aave/Comet harnesses:
///
///   collateral vault = eWETH-2 (asset WETH) — in eUSDC-2's collateral set @ 84% LTV
///   borrow     vault = eUSDC-2 (asset USDC)
///
/// Euler authorisation differs per direction: deposit/repay are direct, permission-
/// less vault calls (the module funds them as the authenticated account); borrow/
/// withdraw/batch are routed through the EVC and need the maker to grant the module
/// operator rights once plus enable the controller/collateral.
abstract contract EulerV2ModulesBase is CoreSettlementBase {
    IEVC constant EVC = IEVC(0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383);
    IEulerVault constant EWETH = IEulerVault(0xD8b27CF359b7D15710a5BE299AF6e7Bf904984C2); // collateral
    IEulerVault constant EUSDC = IEulerVault(0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9); // borrow

    EulerV2DepositModule depositModule;
    EulerV2RepayModule repayModule;
    EulerV2TakerModule takerModule;
    EulerV2BatchModule batchModule;
    LimitOrderLeverageSolver leverageSolver;

    function setUp() public virtual override {
        super.setUp();

        depositModule = new EulerV2DepositModule(address(permit3), address(settlement));
        repayModule = new EulerV2RepayModule(address(permit3), address(settlement));
        takerModule = new EulerV2TakerModule(address(permit3));
        batchModule = new EulerV2BatchModule(address(permit3));
        // Balancer v2 Vault + UniswapV3 SwapRouter — mainnet canonical addresses.
        leverageSolver = new LimitOrderLeverageSolver(
            address(permit3),
            address(settlement),
            0xBA12222222228d8Ba445958a75a0704d566BF2C8,
            0xE592427A0AEce92De3Edee1F18E0157C05861564
        );

        vm.label(address(EVC), "EVC");
        vm.label(address(EWETH), "eWETH-2");
        vm.label(address(EUSDC), "eUSDC-2");
        vm.label(address(depositModule), "eulerDepositModule");
        vm.label(address(repayModule), "eulerRepayModule");
        vm.label(address(takerModule), "eulerTakerModule");
        vm.label(address(batchModule), "eulerBatchModule");
        vm.label(address(leverageSolver), "leverageSolver");

        // Euler-native authorisation for the value-out (EVC-routed) modules: the
        // maker enables the borrow vault as controller, the collateral vault in
        // their collateral set, and grants each taker/batch module operator rights.
        // The Permit3 allowances still cap every fill.
        vm.startPrank(maker);
        EVC.enableCollateral(maker, address(EWETH));
        EVC.enableController(maker, address(EUSDC));
        EVC.setAccountOperator(maker, address(takerModule), true);
        EVC.setAccountOperator(maker, address(batchModule), true);
        vm.stopPrank();
    }

    // ──────────────────── Position reads ────────────────────

    function _wethCollateral(address who) internal view returns (uint256) {
        return EWETH.convertToAssets(EWETH.balanceOf(who));
    }

    function _usdcDebt(address who) internal view returns (uint256) {
        return EUSDC.debtOf(who);
    }

    // ──────────────────── Position seeding ────────────────────

    /// @dev Maker supplies `amount` WETH into eWETH-2 as collateral (no borrow).
    function _seedEulerCollateral(uint256 amount) internal {
        deal(WETH, maker, amount);
        vm.startPrank(maker);
        IERC20(WETH).approve(address(EWETH), amount);
        EWETH.deposit(amount, maker);
        vm.stopPrank();
    }

    /// @dev Maker supplies `collateral` WETH into eWETH-2 and borrows `debt` USDC
    ///      from eUSDC-2, dumping the proceeds so the wallet starts clean.
    function _openEulerPosition(uint256 collateral, uint256 debt) internal {
        deal(WETH, maker, collateral);
        vm.startPrank(maker);
        IERC20(WETH).approve(address(EWETH), collateral);
        EWETH.deposit(collateral, maker);
        EUSDC.borrow(debt, maker);
        IERC20(USDC).transfer(address(0xdead), debt);
        vm.stopPrank();
    }

    // ──────────────────── Order builders ────────────────────

    /// @dev Deposit `collateralIn` WETH + borrow `borrowOut` USDC in one order.
    ///      tokenIn = USDC (from the borrow), tokenOut = WETH (from the solver).
    function _buildDepositBorrowOrder(uint256 collateralIn, uint256 borrowOut)
        internal
        view
        returns (Order memory)
    {
        Item[] memory items = new Item[](2);
        items[0] = Item(ItemOp.MAKE, address(depositModule), collateralIn, address(0), abi.encode(address(EWETH)));
        items[1] = Item(
            ItemOp.TAKE,
            address(takerModule),
            borrowOut,
            address(0),
            abi.encode(uint8(EulerV2TakerModule.Op.Borrow), address(EUSDC))
        );
        return _order(maker, 1, USDC, WETH, borrowOut, collateralIn, items);
    }

    function _approveDepositBorrowSide(uint256 collateralIn, uint256 borrowOut) internal {
        vm.startPrank(maker);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(depositModule), WETH, uint160(collateralIn), 0);
        permit3.approveTaker(
            address(settlement),
            keccak256(abi.encode(uint8(EulerV2TakerModule.Op.Borrow), address(EUSDC))),
            uint160(borrowOut),
            0
        );
        // USDC fallback for the tokenIn shortfall path (never triggers here).
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDC, uint160(borrowOut), 0);
        vm.stopPrank();
    }
}
