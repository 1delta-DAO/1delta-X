// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";

import {Chains, Lenders} from "@coretest/data/LenderRegistry.sol";
import {IAaveCreditDelegation} from "../../src/interfaces/IAaveV3.sol";
import {AaveModulesBase} from "../shared/AaveModulesBase.t.sol";

/// @dev Migrate Aave v3 → Spark in ONE order. Maker has an open Aave v3 position
/// (10 WETH collateral, 3000 USDC debt). They sign one 4-item order that closes
/// the Aave position and opens an equivalent Spark position. Spark is an Aave v3
/// fork on mainnet — same ABI, so the existing Aave modules are reused pointed at
/// the Spark pool via `data`.
///
/// Items (strictly ordered):
///   [0] MAKE  AaveV3RepayModule         repay (debt + buffer), dust → maker
///   [1] TAKE  AaveV3WithdrawModule      withdraw `exactWeth` WETH, recipient = maker
///   [2] MAKE  AaveV3DepositModule→Spark deposit `exactWeth` WETH onto Spark
///   [3] TAKE  AaveV3BorrowModule→Spark  borrow USDC on Spark, recipient = Settlement
contract MigrateTest is AaveModulesBase {
    // ──────────────────── Direct fill (4-item order, exact amounts) ────────────────────

    function test_migrate_aaveV3_to_spark() public {
        uint256 collateral = 10 ether; //    WETH collateral on Aave (also re-supplied on Spark)
        uint256 exactWeth = 9 ether; //      conservative floor for withdrawal (leaves dust on Aave)
        uint256 debt = 3_000e6; //           USDC debt on Aave (no accrual in test → exact)
        uint256 repayBuffer = 50e6;
        uint256 bufferedRepay = debt + repayBuffer;

        address SPARK_POOL = lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.SPARK];
        address spWETH = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SPARK][WETH].collateral;
        address sparkUsdcDebt = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SPARK][USDC].debt;
        address aaveUsdcDebt = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][USDC].debt;

        vm.label(SPARK_POOL, "sparkPool");
        vm.label(spWETH, "spWETH");
        vm.label(sparkUsdcDebt, "sparkUsdcDebt");

        _openAaveV3Position(collateral, debt);

        // Fund solver.
        deal(USDC, solver, bufferedRepay);

        _approveMakerMigrationSide(bufferedRepay, exactWeth, debt, SPARK_POOL, sparkUsdcDebt);
        _approveSolverSide(bufferedRepay, USDC);

        Order memory order = _buildMigrationOrder(bufferedRepay, exactWeth, debt, SPARK_POOL);
        bytes memory sig = _sign(order);

        uint256 makerAaveAWethBefore = IERC20(aWETH).balanceOf(maker);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, debt)[0];

        assertEq(paid, bufferedRepay, "solver paid bufferedRepay tokenOut");

        // Maker ended with: Aave debt 0, Aave collateral ≈ 1 WETH (10 supplied - 9 withdrawn),
        // Spark collateral ≈ 9 WETH, Spark debt = 3000 USDC.
        assertEq(IERC20(aaveUsdcDebt).balanceOf(maker), 0, "Aave USDC debt closed");
        assertApproxEqAbs(
            IERC20(aWETH).balanceOf(maker), makerAaveAWethBefore - exactWeth, 2, "Aave collateral reduced by exactWeth"
        );
        assertApproxEqAbs(IERC20(spWETH).balanceOf(maker), exactWeth, 2, "Spark collateral opened");
        assertApproxEqAbs(IERC20(sparkUsdcDebt).balanceOf(maker), debt, 2, "Spark USDC debt opened");

        // Maker wallet: +repayBuffer USDC (solver's margin) — in a production flow this would be
        // near-zero under dutch decay, but the static spread keeps the test deterministic.
        assertApproxEqAbs(IERC20(USDC).balanceOf(maker), repayBuffer, 2, "maker wallet USDC = repay buffer");
        assertEq(IERC20(WETH).balanceOf(maker), 1 ether, "maker wallet WETH untouched by migration");

        // Solver paid bufferedRepay, received debt = bufferedRepay - repayBuffer.
        assertEq(IERC20(USDC).balanceOf(solver), debt, "solver USDC = debt (spread paid for solving)");

        // Nothing stuck at Settlement or modules.
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), 0, "repay module drained");
        assertEq(IERC20(WETH).balanceOf(address(depositModule)), 0, "deposit module drained");
        assertEq(IERC20(WETH).balanceOf(address(withdrawModule)), 0, "withdraw module drained");
        assertEq(IERC20(USDC).balanceOf(address(borrowModule)), 0, "borrow module drained");
    }

    // ──────────────────── Single-signature permit fill (4-item order, one signature) ────────────────────

    function test_permit_migrate_aaveV3_to_spark() public {
        _setupMigration();
        (Order memory order, IPermit3.PermitBatch memory batch) = _buildMigrationOrderAndBatch();
        bytes memory sig = _signPermitWitness(batch, _hashOrder(order));

        vm.prank(solver);
        settlement.fillWithPermit(order, batch, sig, 3_000e6);

        _assertMigration();
    }

    function _setupMigration() internal {
        address sparkUsdcDebt = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SPARK][USDC].debt;
        _openAaveV3Position(10 ether, 3_000e6);
        deal(USDC, solver, 3_050e6);
        vm.prank(maker);
        IAaveCreditDelegation(sparkUsdcDebt).approveDelegation(address(borrowModule), type(uint256).max);
    }

    function _buildMigrationOrderAndBatch()
        internal
        view
        returns (Order memory order, IPermit3.PermitBatch memory batch)
    {
        address SPARK_POOL = lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.SPARK];
        bytes memory aaveWithdrawData = abi.encode(AAVE_POOL, WETH, aWETH);
        bytes memory sparkBorrowData = abi.encode(SPARK_POOL, USDC, uint256(2));
        uint48 exp = uint48(block.timestamp + 1 hours);

        Item[] memory items = new Item[](4);
        items[0] = Item(
            ItemOp.MAKE,
            address(repayModule),
            3_050e6,
            address(0),
            abi.encode(AAVE_POOL, USDC, uint256(2), usdcDebtToken)
        );
        items[1] = Item(ItemOp.TAKE, address(withdrawModule), 9 ether, maker, aaveWithdrawData);
        items[2] = Item(ItemOp.MAKE, address(depositModule), 9 ether, address(0), abi.encode(SPARK_POOL, WETH));
        items[3] = Item(ItemOp.TAKE, address(borrowModule), 3_000e6, address(0), sparkBorrowData);

        order = _order(maker, 7, USDC, USDC, 3_000e6, 3_050e6, items);

        IPermit3.TokenPermit[] memory tp = new IPermit3.TokenPermit[](4);
        tp[0] = IPermit3.TokenPermit(address(repayModule), USDC, uint160(3_050e6), exp);
        tp[1] = IPermit3.TokenPermit(address(withdrawModule), aWETH, uint160(9 ether), exp);
        tp[2] = IPermit3.TokenPermit(address(depositModule), WETH, uint160(9 ether), exp);
        tp[3] = IPermit3.TokenPermit(address(settlement), USDC, uint160(3_050e6), exp);

        IPermit3.TakerPermit[] memory tkp = new IPermit3.TakerPermit[](2);
        tkp[0] = IPermit3.TakerPermit(address(settlement), address(withdrawModule), keccak256(aaveWithdrawData), uint160(9 ether), exp);
        tkp[1] = IPermit3.TakerPermit(address(settlement), address(borrowModule), keccak256(sparkBorrowData), uint160(3_000e6), exp);

        batch = _buildBatch(tp, tkp, 3, _deadline(order));
    }

    function _assertMigration() internal view {
        address aaveUsdcDebt = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][USDC].debt;
        address spWETH = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SPARK][WETH].collateral;
        address sparkUsdcDebt = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SPARK][USDC].debt;

        assertEq(IERC20(aaveUsdcDebt).balanceOf(maker), 0, "Aave debt closed");
        assertApproxEqAbs(IERC20(spWETH).balanceOf(maker), 9 ether, 2, "Spark collateral opened");
        assertApproxEqAbs(IERC20(sparkUsdcDebt).balanceOf(maker), 3_000e6, 2, "Spark debt opened");
    }
}
