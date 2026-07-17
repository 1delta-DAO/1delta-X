// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {Order, OrderSide, Item, ItemOp, Validator} from "@core/settlement/UniversalSettlement.sol";

import {IComet} from "../../src/interfaces/ICompoundV3.sol";
import {CompoundV3ModulesBase} from "../shared/CompoundV3ModulesBase.t.sol";

/// @dev Migrate a Comet position across markets in ONE order. Maker has an open
/// USDC-Comet position (10 WETH collateral, 3000 USDC debt). They sign one
/// 4-item order that closes it and opens an equivalent position on the USDS
/// Comet. Because every Comet shares the same ABI, the SAME four modules drive
/// both markets — only the `comet` address inside `data` changes.
///
/// Unlike the Aave→Spark migration (same USDC debt on both sides), the markets
/// here have *different* base assets, so the swap leg is genuine: the solver
/// funds the USDC repay and is paid in the freshly-borrowed USDS. (USDS is used
/// rather than USDT because Settlement pays `tokenIn` with a raw `transfer`, so
/// the settled token must be a bool-returning ERC20.)
///
/// Items (strictly ordered):
///   [0] MAKE  CometRepayModule          repay USDC (debt + buffer), dust → maker
///   [1] TAKE  CometTakerModule(Withdraw)  withdraw `exactWeth` WETH, recipient = maker
///   [2] MAKE  CometDepositModule→USDS     deposit `exactWeth` WETH onto the USDS Comet
///   [3] TAKE  CometTakerModule(Borrow)→USDS  borrow USDS, recipient = Settlement
contract MigrateTest is CompoundV3ModulesBase {
    // ──────────────────── Direct fill (4-item order, exact amounts) ────────────────────

    function test_migrate_cometUSDC_to_cometUSDS() public {
        uint256 collateral = 10 ether; //    WETH collateral on USDC-Comet (re-supplied on USDS-Comet)
        uint256 exactWeth = 9 ether; //      conservative floor for withdrawal (leaves dust)
        uint256 debt = 3_000e6; //           USDC debt (no accrual in test → exact)
        uint256 repayBuffer = 50e6;
        uint256 bufferedRepay = debt + repayBuffer;
        uint256 borrowUsds = 3_000e18; //    USDS debt opened on the target market (18 decimals)

        _openCometPosition(collateral, debt);

        // Fund solver with the USDC it pays to fund the repay.
        deal(USDC, solver, bufferedRepay);

        _approveMakerMigrationSide(bufferedRepay, exactWeth, borrowUsds);
        _approveSolverSide(bufferedRepay, USDC);

        Order memory order = _buildMigrationOrder(bufferedRepay, exactWeth, borrowUsds);
        bytes memory sig = _sign(order);

        uint256 makerUsdcCollatBefore = _wethCollateral(maker);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, borrowUsds)[0];

        assertEq(paid, bufferedRepay, "solver paid bufferedRepay tokenOut");

        // Maker ended with: USDC-Comet debt 0, USDC-Comet collateral ≈ 1 WETH
        // (10 supplied - 9 withdrawn), USDS-Comet collateral ≈ 9 WETH, USDS debt.
        assertApproxEqAbs(_usdcDebt(maker), 0, 2, "USDC-Comet debt closed");
        assertApproxEqAbs(
            _wethCollateral(maker), makerUsdcCollatBefore - exactWeth, 2, "USDC-Comet collateral reduced by exactWeth"
        );
        assertApproxEqAbs(
            uint256(IComet(COMET_USDS).collateralBalanceOf(maker, WETH)), exactWeth, 2, "USDS-Comet collateral opened"
        );
        assertApproxEqAbs(IComet(COMET_USDS).borrowBalanceOf(maker), borrowUsds, 2, "USDS-Comet debt opened");

        // Maker wallet: +repayBuffer USDC (solver's margin, swept as dust) and the
        // 1 WETH that _openCometPosition left in the wallet, untouched.
        assertApproxEqAbs(IERC20(USDC).balanceOf(maker), repayBuffer, 2, "maker wallet USDC = repay buffer");
        assertEq(IERC20(WETH).balanceOf(maker), 1 ether, "maker wallet WETH untouched by migration");

        // Solver paid bufferedRepay USDC, received borrowUsds USDS.
        assertEq(IERC20(USDC).balanceOf(solver), 0, "solver USDC spent");
        assertEq(IERC20(USDS).balanceOf(solver), borrowUsds, "solver received USDS borrow proceeds");

        // Nothing stuck at Settlement or modules.
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(USDS).balanceOf(address(settlement)), 0, "settlement USDS drained");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), 0, "repay module drained");
        assertEq(IERC20(WETH).balanceOf(address(depositModule)), 0, "deposit module drained");
        assertEq(IERC20(WETH).balanceOf(address(takerModule)), 0, "taker module WETH drained");
        assertEq(IERC20(USDS).balanceOf(address(takerModule)), 0, "taker module USDS drained");
    }

    // ──────────────────── Single-signature permit fill (4-item order, one signature) ────────────────────

    function test_permit_migrate_cometUSDC_to_cometUSDS() public {
        _setupMigration();
        (Order memory order, IPermit3.PermitBatch memory batch) = _buildMigrationOrderAndBatch();
        bytes memory sig = _signPermitWitness(batch, _hashOrder(order));

        vm.prank(solver);
        settlement.fillWithPermit(order, batch, sig, 3_000e18);

        _assertMigration();
    }

    function _setupMigration() internal {
        _openCometPosition(10 ether, 3_000e6);
        deal(USDC, solver, 3_050e6);
        // Comet account-manager flags cannot ride inside the Permit3 signature
        // (they are Comet-native), so grant them up front — the analogue of
        // pre-setting Aave credit delegation. USDC-Comet withdraw is already
        // allowed in setUp; here we allow the USDS-Comet borrow.
        vm.prank(maker);
        IComet(COMET_USDS).allow(address(takerModule), true);
    }

    function _buildMigrationOrderAndBatch()
        internal
        view
        returns (Order memory order, IPermit3.PermitBatch memory batch)
    {
        bytes memory withdrawData = _withdrawData(COMET, WETH);
        bytes memory borrowData = _borrowData(COMET_USDS, USDS);
        uint48 exp = uint48(block.timestamp + 1 hours);

        Item[] memory items = new Item[](4);
        items[0] = Item(ItemOp.MAKE, address(repayModule), 3_050e6, address(0), abi.encode(COMET, USDC));
        items[1] = Item(ItemOp.TAKE, address(takerModule), 9 ether, maker, withdrawData);
        items[2] = Item(ItemOp.MAKE, address(depositModule), 9 ether, address(0), abi.encode(COMET_USDS, WETH));
        items[3] = Item(ItemOp.TAKE, address(takerModule), 3_000e18, address(0), borrowData);

        order = Order({
            maker: maker,
            side: OrderSide.SELL,
            nonce: 7,
            deadline: block.timestamp + 1 hours,
            tokenIn: _a1(USDS),
            tokenOut: _a1(USDC),
            startAmountIn: _u1(3_000e18),
            endAmountIn: _u1(3_000e18),
            decayStartTime: 0,
            decayDuration: 0,
            startAmountOut: _u1(3_050e6),
            endAmountOut: _u1(3_050e6),
            recipientOut: new address[](1),
            exclusiveFiller: address(0),
            exclusivityEndTime: 0,
            minFillAnchor: 0,
            exclusivityOverrideBps: 0,
            curve: _noCurve(),
            gasBumpBps: 0,
            gasPriceRef: 0,
            items: items,
            validators: new Validator[](0),
            invariants: new Validator[](0)
        });

        // No receipt-token pull on the withdraw leg — `comet.allow` covers it.
        IPermit3.TokenPermit[] memory tp = new IPermit3.TokenPermit[](3);
        tp[0] = IPermit3.TokenPermit(address(repayModule), USDC, uint160(3_050e6), exp);
        tp[1] = IPermit3.TokenPermit(address(depositModule), WETH, uint160(9 ether), exp);
        tp[2] = IPermit3.TokenPermit(address(settlement), USDC, uint160(3_050e6), exp);

        IPermit3.TakerPermit[] memory tkp = new IPermit3.TakerPermit[](2);
        tkp[0] = IPermit3.TakerPermit(address(settlement), keccak256(withdrawData), uint160(9 ether), exp);
        tkp[1] = IPermit3.TakerPermit(address(settlement), keccak256(borrowData), uint160(3_000e18), exp);

        batch = _buildBatch(tp, tkp, 3, order.deadline);
    }

    function _assertMigration() internal view {
        assertApproxEqAbs(_usdcDebt(maker), 0, 2, "USDC-Comet debt closed");
        assertApproxEqAbs(
            uint256(IComet(COMET_USDS).collateralBalanceOf(maker, WETH)), 9 ether, 2, "USDS-Comet collateral opened"
        );
        assertApproxEqAbs(IComet(COMET_USDS).borrowBalanceOf(maker), 3_000e18, 2, "USDS-Comet debt opened");
    }
}
