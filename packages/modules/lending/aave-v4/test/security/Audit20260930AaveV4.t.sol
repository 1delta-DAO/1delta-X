// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {IProceedsAsset} from "@core/interfaces/IProceedsAsset.sol";
import {DustHandler} from "@lib/DustHandler.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";

import {ITakerPositionManager, ISpokeV4} from "../../src/interfaces/IAaveV4.sol";
import {AaveV4DepositModule, AaveV4RepayModule, AaveV4WithdrawModule, AaveV4BorrowModule} from "../../src/AaveV4Modules.sol";
import {AaveV4PreFundModule} from "../../src/AaveV4PreFundModules.sol";
import {AaveV4ModulesBase} from "../shared/AaveV4ModulesBase.t.sol";

/// @title Audit20260930AaveV4Test
/// @notice 2026-09-30 whole-tree audit (group B-lend1) — FORK tests against the REAL
///         Aave v4 Main Spoke + position managers (block pinned by the harness).
///
///   • L-CV2-1 (medium) — the live spoke CLAMPS a withdraw to the supplied balance;
///     the `Exact` branch had no lower bound, so a short position under-delivered
///     and the core billed the shortfall to the maker's WALLET. Started from the
///     PoC (`docs/local/audit-2026-09-30/pocs/L_CV2_1.t.sol`), asserting the SAFE
///     end state: the fill reverts and neither the wallet nor the position moves.
///   • L-CV2-4 — the taker modules bind `asset` to the spoke reserve's underlying.
///   • L-CV2-3 / L-CV2-7 — `Full` mode (needs a TakerPM grant covering the live
///     position), Recycle repay, the auth gates and the pre-fund negatives, none of
///     which had a test.
///   • L-CMT-6 — both taker modules declare their proceeds token.
contract Audit20260930AaveV4Test is AaveV4ModulesBase {
    /// @dev `AaveV4ReserveBinding.UnderlyingMismatch(address,address)`, spelled out
    ///      so this file also compiles against the pre-fix modules.
    bytes4 constant UNDERLYING_MISMATCH = bytes4(keccak256("UnderlyingMismatch(address,address)"));

    uint256 constant ORDER_WETH = 10 ether;
    uint256 constant ORDER_USDC = 30_000e6;

    function _withdrawData() internal view returns (bytes memory) {
        return abi.encode(MAIN_SPOKE, TAKER_PM, wethReserveId, WETH); // 128 bytes ⇒ Exact
    }

    function _withdrawOrder(uint256 nonce, bytes memory data, uint256 wethIn, uint256 usdcOut)
        internal
        view
        returns (Order memory)
    {
        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE, address(withdrawModule), wethIn, address(0), data);
        return _order(maker, nonce, WETH, USDC, wethIn, usdcOut, items);
    }

    // ─────────────────────────────── L-CV2-1 ───────────────────────────────

    /// The PoC end-to-end, inverted: the maker's position drops to ~4 WETH after
    /// signing a 10 WETH position-exit. The fill must REVERT rather than take ~4 from
    /// the position and ~6 from the maker's wallet.
    function test_audit_L_CV2_1_exactWithdraw_shortPosition_reverts() public {
        _seedV4WethPosition(ORDER_WETH);
        bytes memory data = _withdrawData();
        _approveMakerWithdrawSide(ORDER_WETH, keccak256(data));
        _approveSolverSide(ORDER_USDC, USDC);
        deal(USDC, solver, ORDER_USDC);

        Order memory order = _withdrawOrder(1, data, ORDER_WETH, ORDER_USDC);
        bytes memory sig = _sign(order);

        // Position drops after signing (direct withdraw by the maker).
        vm.startPrank(maker);
        ITakerPositionManager(TAKER_PM).approveWithdraw(MAIN_SPOKE, wethReserveId, maker, 6 ether);
        ITakerPositionManager(TAKER_PM).withdrawOnBehalfOf(MAIN_SPOKE, wethReserveId, 6 ether, maker);
        vm.stopPrank();
        deal(WETH, maker, IERC20(WETH).balanceOf(maker) + 1 ether);

        uint256 suppliedBefore = ISpokeV4(MAIN_SPOKE).getUserSuppliedAssets(wethReserveId, maker);
        uint256 walletBefore = IERC20(WETH).balanceOf(maker);
        assertLt(suppliedBefore, ORDER_WETH, "position is short of the signed slice");

        vm.prank(solver);
        vm.expectPartialRevert(FullFillGuard.ShortWithdraw.selector);
        settlement.fill(order, sig, ORDER_WETH);

        assertEq(IERC20(WETH).balanceOf(maker), walletBefore, "maker wallet NOT billed");
        assertEq(
            ISpokeV4(MAIN_SPOKE).getUserSuppliedAssets(wethReserveId, maker), suppliedBefore, "position untouched"
        );
        assertEq(IERC20(WETH).balanceOf(solver), 0, "solver received nothing");
    }

    /// Filler-chosen ordering of two ALTERNATIVE exits against one 10 WETH position:
    /// the second fill must revert instead of billing ~6 WETH to the wallet.
    function test_audit_L_CV2_1_alternativeOrders_secondFillReverts() public {
        _seedV4WethPosition(ORDER_WETH);
        deal(WETH, maker, 10 ether);

        bytes memory data = _withdrawData();
        vm.startPrank(maker);
        ISpokeV4(MAIN_SPOKE).setUserPositionManager(TAKER_PM, true);
        permit3.approveToken(address(settlement), WETH, type(uint160).max, 0);
        ITakerPositionManager(TAKER_PM).approveWithdraw(
            MAIN_SPOKE, wethReserveId, address(withdrawModule), type(uint256).max
        );
        permit3.approveTaker(address(settlement), address(withdrawModule), keccak256(data), uint160(16 ether), 0);
        vm.stopPrank();
        _approveSolverSide(type(uint160).max, USDC);
        deal(USDC, solver, 60_000e6);

        Order memory oA = _withdrawOrder(11, data, 6 ether, 18_000e6);
        Order memory oB = _withdrawOrder(12, data, ORDER_WETH, ORDER_USDC);
        bytes memory sigA = _sign(oA);
        bytes memory sigB = _sign(oB);

        vm.prank(solver);
        settlement.fill(oA, sigA, 6 ether);
        assertEq(IERC20(WETH).balanceOf(solver), 6 ether, "first exit filled from the position");

        uint256 walletMid = IERC20(WETH).balanceOf(maker);
        vm.prank(solver);
        vm.expectPartialRevert(FullFillGuard.ShortWithdraw.selector);
        settlement.fill(oB, sigB, ORDER_WETH);

        assertEq(IERC20(WETH).balanceOf(maker), walletMid, "wallet not billed for the second exit");
        assertEq(IERC20(WETH).balanceOf(solver), 6 ether, "solver got only what the position covered");
    }

    /// The bound cannot misfire on a covered position, including partial slices.
    function test_audit_L_CV2_1_exactWithdraw_coveredPosition_partialFills() public {
        _seedV4WethPosition(ORDER_WETH + 1e15);
        bytes memory data = _withdrawData();
        _approveMakerWithdrawSide(ORDER_WETH, keccak256(data));
        _approveSolverSide(ORDER_USDC, USDC);
        deal(USDC, solver, ORDER_USDC);

        Order memory order = _withdrawOrder(2, data, ORDER_WETH, ORDER_USDC);
        bytes memory sig = _sign(order);
        uint256 walletBefore = IERC20(WETH).balanceOf(maker);

        vm.prank(solver);
        settlement.fill(order, sig, 3 ether);
        vm.prank(solver);
        settlement.fill(order, sig, 7 ether);

        assertEq(IERC20(WETH).balanceOf(solver), ORDER_WETH, "solver received the full exit");
        assertEq(IERC20(WETH).balanceOf(maker), walletBefore, "nothing pulled from the wallet");
        assertEq(IERC20(WETH).balanceOf(address(withdrawModule)), 0, "module drained");
    }

    // ─────────────────────────────── L-CV2-4 ───────────────────────────────

    /// The WETH reserve signed with USDC as the asset: the PM pays WETH, the module
    /// used to measure a zero USDC delta, strand the WETH and let the core bill the
    /// whole USDC input leg to the wallet.
    function test_audit_L_CV2_4_withdraw_assetMismatch_reverts() public {
        _seedV4WethPosition(5 ether);
        uint256 sell = 1_000e6;
        bytes memory data = abi.encode(MAIN_SPOKE, TAKER_PM, wethReserveId, USDC); // encoder bug
        vm.startPrank(maker);
        ISpokeV4(MAIN_SPOKE).setUserPositionManager(TAKER_PM, true);
        ITakerPositionManager(TAKER_PM).approveWithdraw(
            MAIN_SPOKE, wethReserveId, address(withdrawModule), type(uint256).max
        );
        permit3.approveTaker(address(settlement), address(withdrawModule), keccak256(data), uint160(sell), 0);
        permit3.approveToken(address(settlement), USDC, type(uint160).max, 0);
        vm.stopPrank();
        deal(USDC, maker, sell);
        deal(WETH, solver, 1 ether);
        _approveSolverSide(1 ether, WETH);

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE, address(withdrawModule), sell, address(0), data);
        Order memory order = _order(maker, 3, USDC, WETH, sell, 0.3 ether, items);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(UNDERLYING_MISMATCH, USDC, WETH));
        settlement.fill(order, sig, sell);

        assertEq(IERC20(USDC).balanceOf(maker), sell, "wallet not billed");
        assertEq(IERC20(WETH).balanceOf(address(withdrawModule)), 0, "nothing stranded");
    }

    function test_audit_L_CV2_4_borrow_assetMismatch_reverts() public {
        bytes memory data = abi.encode(MAIN_SPOKE, TAKER_PM, usdcReserveId, WETH);
        vm.prank(address(permit3));
        vm.expectRevert(abi.encodeWithSelector(UNDERLYING_MISMATCH, WETH, USDC));
        borrowModule.takeOnBehalf(maker, 100e6, address(settlement), data);
    }

    // ───────────────────────────── L-CV2-3 / L-CV2-7 ─────────────────────────────

    function _fullData(uint256 total) internal view returns (bytes memory) {
        return abi.encode(
            MAIN_SPOKE, TAKER_PM, wethReserveId, WETH, DustHandler.encodeMode(DustHandler.BalanceMode.Full), total
        );
    }

    /// `Full` with a TakerPM grant covering the live position: the whole position is
    /// withdrawn, the signed amount goes to the solver, the remainder to the maker.
    function test_audit_L_CV2_3_fullWithdraw_maxGrant_closesPosition() public {
        _seedV4WethPosition(ORDER_WETH);
        uint256 sell = 8 ether;
        bytes memory data = _fullData(sell);
        vm.startPrank(maker);
        ISpokeV4(MAIN_SPOKE).setUserPositionManager(TAKER_PM, true);
        ITakerPositionManager(TAKER_PM).approveWithdraw(
            MAIN_SPOKE, wethReserveId, address(withdrawModule), type(uint256).max
        );
        permit3.approveTaker(address(settlement), address(withdrawModule), keccak256(data), uint160(sell), 0);
        vm.stopPrank();
        _approveSolverSide(ORDER_USDC, USDC);
        deal(USDC, solver, ORDER_USDC);

        Order memory order = _withdrawOrder(4, data, sell, 24_000e6);
        bytes memory sig = _sign(order);
        uint256 supplied = ISpokeV4(MAIN_SPOKE).getUserSuppliedAssets(wethReserveId, maker);

        vm.prank(solver);
        settlement.fill(order, sig, sell);

        assertEq(ISpokeV4(MAIN_SPOKE).getUserSuppliedAssets(wethReserveId, maker), 0, "position closed");
        assertEq(IERC20(WETH).balanceOf(solver), sell, "solver got the signed amount");
        assertApproxEqAbs(IERC20(WETH).balanceOf(maker), supplied - sell, 2, "remainder swept to the maker");
        assertEq(IERC20(WETH).balanceOf(address(withdrawModule)), 0, "module drained");
    }

    /// The documented requirement (L-CV2-3): a TakerPM grant sized to the ITEM —
    /// below the live position — makes the PM refuse the whole-position request.
    /// Fails closed; nothing moves.
    function test_audit_L_CV2_3_fullWithdraw_itemSizedGrant_reverts() public {
        _seedV4WethPosition(ORDER_WETH);
        uint256 sell = 8 ether;
        bytes memory data = _fullData(sell);
        vm.startPrank(maker);
        ISpokeV4(MAIN_SPOKE).setUserPositionManager(TAKER_PM, true);
        ITakerPositionManager(TAKER_PM).approveWithdraw(MAIN_SPOKE, wethReserveId, address(withdrawModule), sell);
        permit3.approveTaker(address(settlement), address(withdrawModule), keccak256(data), uint160(sell), 0);
        vm.stopPrank();
        _approveSolverSide(ORDER_USDC, USDC);
        deal(USDC, solver, ORDER_USDC);

        Order memory order = _withdrawOrder(5, data, sell, 24_000e6);
        bytes memory sig = _sign(order);
        uint256 supplied = ISpokeV4(MAIN_SPOKE).getUserSuppliedAssets(wethReserveId, maker);

        vm.prank(solver);
        vm.expectRevert(); // TakerPositionManager.InsufficientWithdrawAllowance(sell, supplied)
        settlement.fill(order, sig, sell);
        assertEq(ISpokeV4(MAIN_SPOKE).getUserSuppliedAssets(wethReserveId, maker), supplied, "untouched");
    }

    /// `Full` on a position short of the signed total reverts (I-8).
    function test_audit_L_CV2_7_fullWithdraw_shortPosition_reverts() public {
        _seedV4WethPosition(5 ether);
        uint256 sell = 8 ether;
        bytes memory data = _fullData(sell);
        vm.startPrank(maker);
        ISpokeV4(MAIN_SPOKE).setUserPositionManager(TAKER_PM, true);
        ITakerPositionManager(TAKER_PM).approveWithdraw(
            MAIN_SPOKE, wethReserveId, address(withdrawModule), type(uint256).max
        );
        permit3.approveTaker(address(settlement), address(withdrawModule), keccak256(data), uint160(sell), 0);
        permit3.approveToken(address(settlement), WETH, type(uint160).max, 0);
        vm.stopPrank();
        deal(WETH, maker, sell);
        _approveSolverSide(ORDER_USDC, USDC);
        deal(USDC, solver, ORDER_USDC);

        Order memory order = _withdrawOrder(6, data, sell, 24_000e6);
        bytes memory sig = _sign(order);
        vm.prank(solver);
        vm.expectPartialRevert(FullFillGuard.ShortWithdraw.selector);
        settlement.fill(order, sig, sell);
        assertEq(IERC20(WETH).balanceOf(maker), sell, "wallet untouched");
    }

    /// Recycle repay: the over-repay surplus is re-supplied into the maker's v4
    /// position (same reserve), not left on the module.
    function test_audit_L_CV2_7_repayRecycle_resuppliesSurplus() public {
        uint256 debtAmount = 3_000e6;
        uint256 buffered = debtAmount + 50e6;
        uint256 wethForSolver = 1 ether;
        _openV4UsdcDebt(debtAmount);
        deal(USDC, solver, buffered);
        _approveMakerRepaySide(buffered, wethForSolver);
        _approveSolverSide(buffered, USDC);

        Item[] memory items = new Item[](1);
        items[0] = Item(
            ItemOp.MAKE,
            address(repayModule),
            buffered,
            address(0),
            abi.encode(MAIN_SPOKE, GIVER_PM, usdcReserveId, USDC, uint256(DustHandler.DustAction.Recycle))
        );
        Order memory order = _order(maker, 7, WETH, USDC, wethForSolver, buffered, items);
        bytes memory sig = _sign(order);

        uint256 debtBefore = ISpokeV4(MAIN_SPOKE).getUserTotalDebt(usdcReserveId, maker);
        uint256 usdcWalletBefore = IERC20(USDC).balanceOf(maker);
        vm.prank(solver);
        settlement.fill(order, sig, wethForSolver);

        assertEq(ISpokeV4(MAIN_SPOKE).getUserTotalDebt(usdcReserveId, maker), 0, "debt closed");
        assertApproxEqAbs(
            ISpokeV4(MAIN_SPOKE).getUserSuppliedAssets(usdcReserveId, maker),
            buffered - debtBefore,
            2,
            "surplus re-supplied into the maker's position"
        );
        assertEq(IERC20(USDC).balanceOf(maker), usdcWalletBefore, "nothing swept to the wallet");
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), 0, "module drained");
    }

    /// The four modules' caller gates (no test pinned any of them).
    function test_audit_L_CV2_7_authGates() public {
        bytes memory data = _withdrawData();
        vm.startPrank(address(0xBAD));
        vm.expectRevert(AaveV4WithdrawModule.OnlyPermit3.selector);
        withdrawModule.takeOnBehalf(maker, 1, address(0xBAD), data);
        vm.expectRevert(AaveV4BorrowModule.OnlyPermit3.selector);
        borrowModule.takeOnBehalf(maker, 1, address(0xBAD), data);
        vm.expectRevert(AaveV4DepositModule.NotSettlement.selector);
        depositModule.makeOnBehalf(maker, 1, data);
        vm.expectRevert(AaveV4RepayModule.NotSettlement.selector);
        repayModule.makeOnBehalf(maker, 1, data);
        vm.stopPrank();
    }

    /// The pre-fund module's caller and descriptor gates (the venus / compound-v2
    /// pre-fund suites had these; the v4 one did not).
    function test_audit_L_CV2_7_preFund_rejectsNonSettlementAndNonLegRef() public {
        AaveV4PreFundModule preFund = new AaveV4PreFundModule(address(permit3), address(settlement));
        uint256 legRef = (uint256(1) << 255) | (uint256(1) << 253) | (uint256(uint160(WETH)) << 16);
        bytes memory good = abi.encode(legRef, MAIN_SPOKE, GIVER_PM, wethReserveId, WETH);
        vm.prank(address(0xBAD));
        vm.expectRevert(PreFundGuard.OnlySettlement.selector);
        preFund.makeOnBehalf(maker, 1, good);

        bytes memory literal = abi.encode(uint256(0), MAIN_SPOKE, GIVER_PM, wethReserveId, WETH);
        bytes memory balance = abi.encode((uint256(3) << 254) | uint160(WETH), MAIN_SPOKE, GIVER_PM, wethReserveId, WETH);
        vm.startPrank(address(settlement));
        vm.expectRevert(PreFundGuard.PreFundDescriptorRequired.selector);
        preFund.makeOnBehalf(maker, 1, literal);
        vm.expectRevert(PreFundGuard.PreFundDescriptorRequired.selector);
        preFund.makeOnBehalf(maker, 1, balance);
        vm.stopPrank();
    }

    // ─────────────────────────────── L-CMT-6 ───────────────────────────────

    function test_audit_L_CMT_6_takerModules_declareProceedsAsset() public view {
        bytes memory w = _withdrawData();
        bytes memory b = abi.encode(MAIN_SPOKE, TAKER_PM, usdcReserveId, USDC);
        (bool ok1, bytes memory r1) = address(withdrawModule).staticcall(abi.encodeCall(IProceedsAsset.proceedsAsset, (w)));
        (bool ok2, bytes memory r2) = address(borrowModule).staticcall(abi.encodeCall(IProceedsAsset.proceedsAsset, (b)));
        assertTrue(ok1 && r1.length == 32 && ok2 && r2.length == 32, "both answer proceedsAsset");
        assertEq(abi.decode(r1, (address)), WETH, "withdraw delivers the reserve asset");
        assertEq(abi.decode(r2, (address)), USDC, "borrow delivers the reserve asset");
    }
}
