// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";

import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";
import {Chains, Lenders} from "@coretest/data/LenderRegistry.sol";

import {AaveV2DepositModule, AaveV2BorrowModule} from "../../src/AaveV2Modules.sol";
import {IAaveV2CreditDelegation} from "../../src/interfaces/IAaveV2.sol";

/// @dev Leverage fork tests for the Aave V2 modules — deposit X + borrow Y in ONE
/// order against the live mainnet LendingPool (still active/unfrozen at the pinned
/// fork block; verified via `getConfiguration`: WETH + USDC active, not frozen,
/// borrowing enabled).
///
/// The maker deposits WETH as collateral and borrows USDC against it. The solver
/// funds the WETH collateral from inventory (the simplest fill proving the module
/// round-trip — no flash provider needed) and receives the borrow proceeds:
///
///   tokenIn  = USDC   (maker gives — sourced from the borrow item)
///   tokenOut = WETH   (solver gives → delivered to maker, pulled into the deposit)
///
/// Items:
///   [0] MAKE  AaveV2DepositModule   deposit WETH   (`pool.deposit`, V2's supply)
///   [1] TAKE  AaveV2BorrowModule    borrow USDC    (variable rate = 2)
///
/// Auth surface exercised:
///   • Permit3 token allowance  maker → depositModule (WETH pull during MAKE)
///   • Aave-native credit delegation on the variable-debt token → borrowModule
///   • Permit3 taker allowance  (settlement, keccak256(borrowData)) caps the TAKE
contract AaveV2LeverageTest is CoreSettlementBase {
    AaveV2DepositModule depositModule;
    AaveV2BorrowModule borrowModule;

    address AAVE_V2_POOL;
    address aWETH;
    address usdcVariableDebt;

    function setUp() public override {
        super.setUp();

        AAVE_V2_POOL = lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2];
        aWETH = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][WETH].collateral;
        usdcVariableDebt = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][USDC].debt;

        depositModule = new AaveV2DepositModule(address(permit3), address(settlement));
        borrowModule = new AaveV2BorrowModule(address(permit3));

        vm.label(AAVE_V2_POOL, "aaveV2Pool");
        vm.label(aWETH, "aWETH_v2");
        vm.label(usdcVariableDebt, "variableDebtUSDC_v2");
        vm.label(address(depositModule), "aaveV2DepositModule");
        vm.label(address(borrowModule), "aaveV2BorrowModule");
    }

    // ──────────────────── Helpers ────────────────────

    function _borrowData() internal view returns (bytes memory) {
        return abi.encode(AAVE_V2_POOL, USDC, uint256(2)); // 2 = variable rate
    }

    function _approveMakerDepositBorrowSide(uint256 collateralIn, uint256 borrowOut) internal {
        vm.startPrank(maker);
        // WETH: deposit module pulls the collateral via Permit3 during MAKE.
        // (maker's ERC20 approve to Permit3 is set in CoreSettlementBase.setUp.)
        permit3.approveToken(address(depositModule), WETH, uint160(collateralIn), 0);

        // Credit delegation: Aave-native authorisation for the borrow module to
        // incur USDC debt on the maker's behalf. Infinite here — the Permit3
        // taker allowance is what actually caps the fill.
        IAaveV2CreditDelegation(usdcVariableDebt).approveDelegation(address(borrowModule), type(uint256).max);

        // Permit3 taker gate on the exact borrow position + amount.
        permit3.approveTaker(address(settlement), keccak256(_borrowData()), uint160(borrowOut), 0);

        // USDC fallback allowance for the tokenIn shortfall path — never triggers
        // here since the borrow fully funds tokenIn, but keeps it safe.
        permit3.approveToken(address(settlement), USDC, uint160(borrowOut), 0);
        vm.stopPrank();
    }

    function _buildDepositBorrowOrder(uint256 nonce, uint256 collateralIn, uint256 borrowOut)
        internal
        view
        returns (Order memory order)
    {
        Item[] memory items = new Item[](2);
        items[0] =
            Item(ItemOp.MAKE, address(depositModule), collateralIn, address(0), abi.encode(AAVE_V2_POOL, WETH));
        items[1] = Item(ItemOp.TAKE, address(borrowModule), borrowOut, address(0), _borrowData());
        order = _order(maker, nonce, USDC, WETH, borrowOut, collateralIn, items);
    }

    // ──────────────────── Full leverage open ────────────────────

    function test_depositX_borrowY_aaveV2() public {
        uint256 collateralIn = 1 ether; //  maker receives + deposits
        uint256 borrowOut = 1_000e6; //     maker borrows → solver receives

        deal(WETH, solver, collateralIn);

        _approveMakerDepositBorrowSide(collateralIn, borrowOut);
        _approveSolverSide(collateralIn, WETH);

        Order memory order = _buildDepositBorrowOrder(1, collateralIn, borrowOut);
        bytes memory sig = _sign(order);

        uint256 makerAWethBefore = IERC20(aWETH).balanceOf(maker);
        uint256 makerDebtBefore = IERC20(usdcVariableDebt).balanceOf(maker);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, borrowOut)[0];

        assertEq(paid, collateralIn, "solver paid 1 WETH of collateral");

        // Maker: fresh ~1 aWETH collateral position and ~1000 USDC of variable debt.
        assertApproxEqAbs(IERC20(aWETH).balanceOf(maker) - makerAWethBefore, collateralIn, 2, "maker aWETH up");
        assertApproxEqAbs(
            IERC20(usdcVariableDebt).balanceOf(maker) - makerDebtBefore, borrowOut, 2, "maker variable debt up"
        );

        // Solver: spent WETH inventory, received the borrow proceeds.
        assertEq(IERC20(WETH).balanceOf(solver), 0, "solver WETH spent");
        assertEq(IERC20(USDC).balanceOf(solver), borrowOut, "solver received USDC");

        // Wallet balances unchanged — neither leg's asset sat in the maker's EOA.
        assertEq(IERC20(WETH).balanceOf(maker), 0, "maker WETH forwarded into deposit");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "maker USDC forwarded out via borrow");

        // Settlement & modules end empty.
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(WETH).balanceOf(address(depositModule)), 0, "deposit module WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(borrowModule)), 0, "borrow module USDC drained");
    }

    // ──────────────────── Partial fill (pro-rata items) ────────────────────

    /// @dev Both items pro-rate: filling half the order deposits half the collateral
    ///      and borrows half the debt; a second half-fill completes the totals exactly.
    function test_partialFill_depositBorrow_aaveV2() public {
        uint256 collateralIn = 1 ether;
        uint256 borrowOut = 1_000e6;
        uint256 half = borrowOut / 2;

        deal(WETH, solver, collateralIn);

        _approveMakerDepositBorrowSide(collateralIn, borrowOut);
        _approveSolverSide(collateralIn, WETH);

        Order memory order = _buildDepositBorrowOrder(2, collateralIn, borrowOut);
        bytes memory sig = _sign(order);

        // ── First half ──
        vm.prank(solver);
        uint256 paid1 = settlement.fill(order, sig, half)[0];

        assertEq(paid1, collateralIn / 2, "first fill: half the collateral");
        assertApproxEqAbs(IERC20(aWETH).balanceOf(maker), collateralIn / 2, 2, "maker aWETH at half");
        assertApproxEqAbs(IERC20(usdcVariableDebt).balanceOf(maker), half, 2, "maker debt at half");
        assertEq(IERC20(USDC).balanceOf(solver), half, "solver received half the borrow");
        assertEq(IERC20(WETH).balanceOf(solver), collateralIn / 2, "solver kept half its inventory");

        // ── Second half completes the order ──
        vm.prank(solver);
        uint256 paid2 = settlement.fill(order, sig, half)[0];

        assertEq(paid1 + paid2, collateralIn, "fills sum to the full collateral");
        assertApproxEqAbs(IERC20(aWETH).balanceOf(maker), collateralIn, 3, "maker aWETH complete");
        assertApproxEqAbs(IERC20(usdcVariableDebt).balanceOf(maker), borrowOut, 3, "maker debt complete");
        assertEq(IERC20(USDC).balanceOf(solver), borrowOut, "solver received the full borrow");
        assertEq(IERC20(WETH).balanceOf(solver), 0, "solver inventory fully spent");

        // Settlement & modules end empty.
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(WETH).balanceOf(address(depositModule)), 0, "deposit module WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(borrowModule)), 0, "borrow module USDC drained");
    }
}
