// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {LimitOrder, Item, ItemOp} from "@core/settlement/LimitOrderSettlement.sol";

import {Chains, Lenders} from "@coretest/data/LenderRegistry.sol";

// Cross-protocol: reuse the Aave v3 modules for the destination legs. This is the
// composability claim made concrete — the Morpho repay/withdraw modules and the
// Aave deposit/borrow modules plug into one signed order.
import {IAaveV3Pool, IAaveCreditDelegation} from "../../../modules-aave-v3/src/interfaces/IAaveV3.sol";
import {AaveV3DepositModule, AaveV3BorrowModule} from "../../../modules-aave-v3/src/AaveV3Modules.sol";

import {MorphoModulesBase} from "../shared/MorphoModulesBase.t.sol";

/// @dev Migrate a Morpho position → Aave v3 in ONE order. Maker has an open Morpho
/// wstETH/USDC position; they sign one 4-item order that closes it on Morpho and
/// opens the equivalent position on Aave. Same assets on both sides (wstETH
/// collateral, USDC debt), different protocol — the Aave analog migrates to Spark;
/// here we cross the protocol boundary entirely.
///
/// Items (strictly ordered):
///   [0] MAKE  MorphoBlueRepayModule             repay (debt + buffer), dust → maker
///   [1] TAKE  MorphoBlueWithdrawCollateralModule withdraw `exactWeth` wstETH, recipient = maker
///   [2] MAKE  AaveV3DepositModule               deposit `exactWeth` wstETH onto Aave
///   [3] TAKE  AaveV3BorrowModule                borrow USDC on Aave, recipient = Settlement
contract MigrateTest is MorphoModulesBase {
    AaveV3DepositModule aaveDepositModule;
    AaveV3BorrowModule aaveBorrowModule;

    address AAVE_POOL;
    address aWstETH;
    address aaveUsdcDebt;

    function setUp() public override {
        super.setUp();
        AAVE_POOL = lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3];
        aWstETH = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][WSTETH].collateral;
        aaveUsdcDebt = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][USDC].debt;

        aaveDepositModule = new AaveV3DepositModule(address(permit3), address(settlement));
        aaveBorrowModule = new AaveV3BorrowModule(address(permit3));

        vm.label(AAVE_POOL, "aaveV3Pool");
        vm.label(aWstETH, "aWstETH");
        vm.label(address(aaveDepositModule), "aaveV3DepositModule");
        vm.label(address(aaveBorrowModule), "aaveV3BorrowModule");
    }

    // ──────────────────── Direct fill (4-item order, exact amounts) ────────────────────

    function test_migrate_morpho_to_aaveV3() public {
        uint256 collateral = 2 ether; //     wstETH collateral on Morpho
        uint256 exactWeth = 1.5 ether; //    withdrawn from Morpho, re-supplied to Aave
        uint256 debt = 3_000e6; //           USDC debt (no accrual in test → ~exact)
        uint256 repayBuffer = 50e6;
        uint256 bufferedRepay = debt + repayBuffer;

        _openPosition(collateral, debt);
        deal(USDC, solver, bufferedRepay);

        _approveMigrationSide(bufferedRepay, exactWeth, debt);
        _approveSolverSide(bufferedRepay, USDC);

        LimitOrder memory order = _buildMigrationOrder(bufferedRepay, exactWeth, debt);
        bytes memory sig = _sign(order);

        uint256 makerMorphoCollatBefore = _collateral(maker);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, debt);

        assertEq(paid, bufferedRepay, "solver paid bufferedRepay tokenOut");

        // Morpho side closed / reduced.
        assertEq(_position(maker).borrowShares, 0, "Morpho USDC debt closed");
        assertEq(makerMorphoCollatBefore - _collateral(maker), exactWeth, "Morpho collateral reduced by exactWeth");

        // Aave side opened.
        assertApproxEqAbs(IERC20(aWstETH).balanceOf(maker), exactWeth, 2, "Aave collateral opened");
        assertApproxEqAbs(IERC20(aaveUsdcDebt).balanceOf(maker), debt, 2, "Aave USDC debt opened");

        // Maker wallet: +repayBuffer USDC (solver's margin), wstETH untouched.
        assertApproxEqAbs(IERC20(USDC).balanceOf(maker), repayBuffer, 2, "maker wallet USDC = repay buffer");
        assertEq(IERC20(WSTETH).balanceOf(maker), 0, "maker wallet wstETH net-zero (withdrawn = deposited)");

        // Solver paid bufferedRepay, received debt.
        assertEq(IERC20(USDC).balanceOf(solver), debt, "solver USDC = debt (spread paid for solving)");

        // Nothing stuck at Settlement or modules.
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(WSTETH).balanceOf(address(settlement)), 0, "settlement wstETH drained");
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), 0, "repay module drained");
        assertEq(IERC20(WSTETH).balanceOf(address(aaveDepositModule)), 0, "deposit module drained");
        assertEq(IERC20(USDC).balanceOf(address(aaveBorrowModule)), 0, "borrow module drained");
    }

    // ──────────────────── Single-signature permit fill ────────────────────

    function test_permit_migrate_morpho_to_aaveV3() public {
        uint256 exactWeth = 1.5 ether;
        uint256 debt = 3_000e6;
        uint256 bufferedRepay = 3_050e6;

        _openPosition(2 ether, debt);
        deal(USDC, solver, bufferedRepay);

        // Native delegations (outside the signed batch).
        vm.startPrank(maker);
        MORPHO.setAuthorization(address(withdrawModule), true);
        IAaveCreditDelegation(aaveUsdcDebt).approveDelegation(address(aaveBorrowModule), type(uint256).max);
        vm.stopPrank();

        (LimitOrder memory order, IPermit3.PermitBatch memory batch) =
            _buildMigrationOrderAndBatch(bufferedRepay, exactWeth, debt);
        bytes memory sig = _signPermitWitness(batch, _hashOrder(order));

        vm.prank(solver);
        settlement.fillWithPermit(order, batch, sig, debt);

        assertEq(_position(maker).borrowShares, 0, "Morpho debt closed");
        assertApproxEqAbs(IERC20(aWstETH).balanceOf(maker), exactWeth, 2, "Aave collateral opened");
        assertApproxEqAbs(IERC20(aaveUsdcDebt).balanceOf(maker), debt, 2, "Aave debt opened");
    }

    // ──────────────────── Helpers ────────────────────

    function _aaveBorrowData() internal view returns (bytes memory) {
        return abi.encode(AAVE_POOL, USDC, uint256(2));
    }

    function _approveMigrationSide(uint256 bufferedRepay, uint256 exactWeth, uint256 debt) internal {
        vm.startPrank(maker);

        // [0] Morpho repay: repayModule pulls USDC via Permit3; settlement pulls the
        //     tokenIn shortfall (buffered − borrow).
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(repayModule), USDC, uint160(bufferedRepay), 0);
        permit3.approveToken(address(settlement), USDC, uint160(bufferedRepay), 0);

        // [1] Morpho withdraw: Morpho-native auth + Permit3 taker cap. No token pull.
        MORPHO.setAuthorization(address(withdrawModule), true);
        permit3.approveTaker(address(settlement), keccak256(_marketData()), uint160(exactWeth), 0);

        // [2] Aave deposit: depositModule pulls wstETH from maker via Permit3.
        IERC20(WSTETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(aaveDepositModule), WSTETH, uint160(exactWeth), 0);

        // [3] Aave borrow: credit delegation + Permit3 taker cap.
        IAaveCreditDelegation(aaveUsdcDebt).approveDelegation(address(aaveBorrowModule), type(uint256).max);
        permit3.approveTaker(address(settlement), keccak256(_aaveBorrowData()), uint160(debt), 0);

        vm.stopPrank();
    }

    function _buildMigrationOrder(uint256 bufferedRepay, uint256 exactWeth, uint256 debt)
        internal
        view
        returns (LimitOrder memory order)
    {
        Item[] memory items = new Item[](4);
        items[0] = Item(ItemOp.MAKE, address(repayModule), bufferedRepay, address(0), _marketData());
        items[1] = Item(ItemOp.TAKE, address(withdrawModule), exactWeth, maker, _marketData());
        items[2] = Item(ItemOp.MAKE, address(aaveDepositModule), exactWeth, address(0), abi.encode(AAVE_POOL, WSTETH));
        items[3] = Item(ItemOp.TAKE, address(aaveBorrowModule), debt, address(0), _aaveBorrowData());
        order = _order(maker, 7, USDC, USDC, debt, bufferedRepay, items);
    }

    function _buildMigrationOrderAndBatch(uint256 bufferedRepay, uint256 exactWeth, uint256 debt)
        internal
        view
        returns (LimitOrder memory order, IPermit3.PermitBatch memory batch)
    {
        order = _buildMigrationOrder(bufferedRepay, exactWeth, debt);
        uint48 exp = uint48(order.deadline);

        // Three token permits — Morpho withdraw needs none (collateral isn't tokenised).
        IPermit3.TokenPermit[] memory tp = new IPermit3.TokenPermit[](3);
        tp[0] = IPermit3.TokenPermit(address(repayModule), USDC, uint160(bufferedRepay), exp);
        tp[1] = IPermit3.TokenPermit(address(aaveDepositModule), WSTETH, uint160(exactWeth), exp);
        tp[2] = IPermit3.TokenPermit(address(settlement), USDC, uint160(bufferedRepay), exp);

        IPermit3.TakerPermit[] memory tkp = new IPermit3.TakerPermit[](2);
        tkp[0] = IPermit3.TakerPermit(address(settlement), keccak256(_marketData()), uint160(exactWeth), exp);
        tkp[1] = IPermit3.TakerPermit(address(settlement), keccak256(_aaveBorrowData()), uint160(debt), exp);

        batch = _buildBatch(tp, tkp, 3, order.deadline);
    }
}
