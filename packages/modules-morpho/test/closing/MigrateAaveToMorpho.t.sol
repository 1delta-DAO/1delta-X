// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {LimitOrder, Item, ItemOp} from "@core/settlement/LimitOrderSettlement.sol";

import {Chains, Lenders} from "@coretest/data/LenderRegistry.sol";

// Cross-protocol: the SOURCE legs are the Aave v3 modules, the DESTINATION legs
// are the Morpho modules. The reverse of Migrate.t.sol — same composability claim,
// other direction.
import {IAaveV3Pool, IAaveCreditDelegation} from "../../../modules-aave-v3/src/interfaces/IAaveV3.sol";
import {AaveV3RepayModule, AaveV3WithdrawModule} from "../../../modules-aave-v3/src/AaveV3Modules.sol";

import {MorphoModulesBase} from "../shared/MorphoModulesBase.t.sol";

/// @dev Migrate an Aave v3 position → Morpho Blue in ONE order. Maker has an open
/// Aave v3 wstETH/USDC position; they sign one 4-item order that closes it on Aave
/// and opens the equivalent position on the Morpho wstETH/USDC market. Same assets
/// on both sides (wstETH collateral, USDC debt), opposite protocol boundary to
/// `MigrateTest`.
///
/// Items (strictly ordered):
///   [0] MAKE  AaveV3RepayModule                  repay Aave debt (debt + buffer), dust → maker
///   [1] TAKE  AaveV3WithdrawModule               withdraw `exactWeth` wstETH from Aave, recipient = maker
///   [2] MAKE  MorphoBlueSupplyCollateralModule   supply `exactWeth` wstETH onto Morpho
///   [3] TAKE  MorphoBlueBorrowModule             borrow USDC on Morpho, recipient = Settlement
contract MigrateAaveToMorphoTest is MorphoModulesBase {
    AaveV3RepayModule aaveRepayModule;
    AaveV3WithdrawModule aaveWithdrawModule;

    address AAVE_POOL;
    address aWstETH;
    address aaveUsdcDebt;

    function setUp() public override {
        super.setUp();
        AAVE_POOL = lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3];
        aWstETH = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][WSTETH].collateral;
        aaveUsdcDebt = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][USDC].debt;

        aaveRepayModule = new AaveV3RepayModule(address(permit3));
        aaveWithdrawModule = new AaveV3WithdrawModule(address(permit3));

        vm.label(AAVE_POOL, "aaveV3Pool");
        vm.label(aWstETH, "aWstETH");
        vm.label(address(aaveRepayModule), "aaveV3RepayModule");
        vm.label(address(aaveWithdrawModule), "aaveV3WithdrawModule");

        // Withdraw module pulls aWstETH from the maker via Permit3 — bare-approve it.
        vm.prank(maker);
        IERC20(aWstETH).approve(address(permit3), type(uint256).max);
    }

    // ──────────────────── Position seeding ────────────────────

    /// @dev Maker supplies `collateral` wstETH on Aave and borrows `debt` USDC,
    ///      dumping the proceeds so the wallet starts clean.
    function _openAavePosition(uint256 collateral, uint256 debt) internal {
        deal(WSTETH, maker, collateral);
        vm.startPrank(maker);
        IERC20(WSTETH).approve(AAVE_POOL, collateral);
        IAaveV3Pool(AAVE_POOL).supply(WSTETH, collateral, maker, 0);
        IAaveV3Pool(AAVE_POOL).borrow(USDC, debt, 2, 0, maker);
        IERC20(USDC).transfer(address(0xdead), debt);
        vm.stopPrank();
    }

    // ──────────────────── Direct fill (4-item order, exact amounts) ────────────────────

    function test_migrate_aaveV3_to_morpho() public {
        uint256 collateral = 2 ether; //     wstETH collateral on Aave
        uint256 exactWeth = 1.5 ether; //    withdrawn from Aave, re-supplied to Morpho
        uint256 debt = 3_000e6; //           USDC debt (no accrual in test → ~exact)
        uint256 repayBuffer = 50e6;
        uint256 bufferedRepay = debt + repayBuffer;

        _openAavePosition(collateral, debt);
        deal(USDC, solver, bufferedRepay);

        _approveMigrationSide(bufferedRepay, exactWeth, debt);
        _approveSolverSide(bufferedRepay, USDC);

        LimitOrder memory order = _buildMigrationOrder(bufferedRepay, exactWeth, debt);
        bytes memory sig = _sign(order);

        uint256 makerAWstethBefore = IERC20(aWstETH).balanceOf(maker);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, debt);

        assertEq(paid, bufferedRepay, "solver paid bufferedRepay tokenOut");

        // Aave side closed / reduced.
        assertEq(IERC20(aaveUsdcDebt).balanceOf(maker), 0, "Aave USDC debt closed");
        assertApproxEqAbs(
            makerAWstethBefore - IERC20(aWstETH).balanceOf(maker), exactWeth, 2, "Aave collateral reduced by exactWeth"
        );

        // Morpho side opened.
        assertEq(_collateral(maker), exactWeth, "Morpho collateral opened exactly");
        assertApproxEqAbs(_borrowAssets(maker), debt, 2, "Morpho USDC debt opened");

        // Maker wallet: +repayBuffer USDC (solver's margin), wstETH net-zero.
        assertApproxEqAbs(IERC20(USDC).balanceOf(maker), repayBuffer, 2, "maker wallet USDC = repay buffer");
        assertEq(IERC20(WSTETH).balanceOf(maker), 0, "maker wallet wstETH net-zero (withdrawn = supplied)");

        // Solver paid bufferedRepay, received debt.
        assertEq(IERC20(USDC).balanceOf(solver), debt, "solver USDC = debt (spread paid for solving)");

        // Nothing stuck at Settlement or modules.
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(WSTETH).balanceOf(address(settlement)), 0, "settlement wstETH drained");
        assertEq(IERC20(USDC).balanceOf(address(aaveRepayModule)), 0, "aave repay module drained");
        assertEq(IERC20(WSTETH).balanceOf(address(aaveWithdrawModule)), 0, "aave withdraw module drained");
        assertEq(IERC20(WSTETH).balanceOf(address(supplyModule)), 0, "morpho supply module drained");
        assertEq(IERC20(USDC).balanceOf(address(borrowModule)), 0, "morpho borrow module drained");
    }

    // ──────────────────── Single-signature permit fill ────────────────────

    function test_permit_migrate_aaveV3_to_morpho() public {
        uint256 exactWeth = 1.5 ether;
        uint256 debt = 3_000e6;
        uint256 bufferedRepay = 3_050e6;

        _openAavePosition(2 ether, debt);
        deal(USDC, solver, bufferedRepay);

        // Native delegation (outside the signed batch): Morpho authorises the borrow.
        vm.prank(maker);
        MORPHO.setAuthorization(address(borrowModule), true);

        (LimitOrder memory order, IPermit3.PermitBatch memory batch) =
            _buildMigrationOrderAndBatch(bufferedRepay, exactWeth, debt);
        bytes memory sig = _signPermitWitness(batch, _hashOrder(order));

        vm.prank(solver);
        settlement.fillWithPermit(order, batch, sig, debt);

        assertEq(IERC20(aaveUsdcDebt).balanceOf(maker), 0, "Aave debt closed");
        assertEq(_collateral(maker), exactWeth, "Morpho collateral opened");
        assertApproxEqAbs(_borrowAssets(maker), debt, 2, "Morpho debt opened");
    }

    // ──────────────────── Helpers ────────────────────

    function _aaveRepayData() internal view returns (bytes memory) {
        // The reorganised AaveV3RepayModule reads the live debt from `debtToken`
        // and pulls only min(amount, debt) — so `data` carries the debt token too.
        return abi.encode(AAVE_POOL, USDC, uint256(2), aaveUsdcDebt);
    }

    function _aaveWithdrawData() internal view returns (bytes memory) {
        return abi.encode(AAVE_POOL, WSTETH, aWstETH);
    }

    function _approveMigrationSide(uint256 bufferedRepay, uint256 exactWeth, uint256 debt) internal {
        vm.startPrank(maker);

        // [0] Aave repay: repayModule pulls USDC via Permit3; settlement pulls the
        //     tokenIn shortfall (buffered − borrow).
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(aaveRepayModule), USDC, uint160(bufferedRepay), 0);
        permit3.approveToken(address(settlement), USDC, uint160(bufferedRepay), 0);

        // [1] Aave withdraw: withdrawModule pulls aWstETH via Permit3 + taker cap.
        permit3.approveToken(address(aaveWithdrawModule), aWstETH, uint160(exactWeth), 0);
        permit3.approveTaker(address(aaveWithdrawModule), keccak256(_aaveWithdrawData()), uint160(exactWeth), 0);

        // [2] Morpho supply: supplyModule pulls wstETH from maker via Permit3.
        IERC20(WSTETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(supplyModule), WSTETH, uint160(exactWeth), 0);

        // [3] Morpho borrow: Morpho-native auth + Permit3 taker cap.
        MORPHO.setAuthorization(address(borrowModule), true);
        permit3.approveTaker(address(borrowModule), keccak256(_marketData()), uint160(debt), 0);

        vm.stopPrank();
    }

    function _buildMigrationOrder(uint256 bufferedRepay, uint256 exactWeth, uint256 debt)
        internal
        view
        returns (LimitOrder memory order)
    {
        Item[] memory items = new Item[](4);
        items[0] = Item(ItemOp.MAKE, address(aaveRepayModule), bufferedRepay, address(0), _aaveRepayData());
        items[1] = Item(ItemOp.TAKE, address(aaveWithdrawModule), exactWeth, maker, _aaveWithdrawData());
        items[2] = Item(ItemOp.MAKE, address(supplyModule), exactWeth, address(0), _marketData());
        items[3] = Item(ItemOp.TAKE, address(borrowModule), debt, address(0), _marketData());
        order = _order(maker, 8, USDC, USDC, debt, bufferedRepay, items);
    }

    function _buildMigrationOrderAndBatch(uint256 bufferedRepay, uint256 exactWeth, uint256 debt)
        internal
        view
        returns (LimitOrder memory order, IPermit3.PermitBatch memory batch)
    {
        order = _buildMigrationOrder(bufferedRepay, exactWeth, debt);
        uint48 exp = uint48(order.deadline);

        // Four token permits — the Aave withdraw needs an aWstETH pull; the Morpho
        // borrow needs none (collateral isn't tokenised, debt isn't pulled).
        IPermit3.TokenPermit[] memory tp = new IPermit3.TokenPermit[](4);
        tp[0] = IPermit3.TokenPermit(address(aaveRepayModule), USDC, uint160(bufferedRepay), exp);
        tp[1] = IPermit3.TokenPermit(address(aaveWithdrawModule), aWstETH, uint160(exactWeth), exp);
        tp[2] = IPermit3.TokenPermit(address(supplyModule), WSTETH, uint160(exactWeth), exp);
        tp[3] = IPermit3.TokenPermit(address(settlement), USDC, uint160(bufferedRepay), exp);

        IPermit3.TakerPermit[] memory tkp = new IPermit3.TakerPermit[](2);
        tkp[0] = IPermit3.TakerPermit(address(aaveWithdrawModule), keccak256(_aaveWithdrawData()), uint160(exactWeth), exp);
        tkp[1] = IPermit3.TakerPermit(address(borrowModule), keccak256(_marketData()), uint160(debt), exp);

        batch = _buildBatch(tp, tkp, 4, order.deadline);
    }
}
