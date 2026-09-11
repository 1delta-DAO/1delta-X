// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";

import {EulerV2OperatorModule} from "../../src/EulerV2OperatorModule.sol";
import {EulerV2ModulesBase} from "../shared/EulerV2ModulesBase.t.sol";

/// @dev `TAKE_FOR` on Euler V2. Euler is the EASY case, and that is the finding: an
/// Euler position has no identity object — it is just the balances of an EVC
/// account — so `deposit` + `borrow` may be applied to it any number of times.
/// {EulerV2OperatorModule}'s {FullFillGuard} was therefore never protecting a protocol
/// constraint, only the fact that a constant `sideAmount` in `data` cannot pro-rate.
/// {EulerV2OperatorModule} carries no guard at all: it partial-fills freely, every
/// slice being its own two-item `EVC.batch` under ONE deferred status check.
contract EulerTakeForOpenTest is EulerV2ModulesBase {

    uint256 constant COLLATERAL = 1 ether;
    uint256 constant BORROW = 1_500e6;

    function setUp() public override {
        super.setUp();
        // No `setAccountOperator` here any more. The base grants it ONCE to
        // `operatorModule`, and every op this suite exercises rides that one grant —
        // which is the merge's whole point. Re-granting would revert: the EVC rejects
        // a `setAccountOperator` that does not change the flag.
        vm.startPrank(maker);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev ⚠ THE OP RIDES THE DESCRIPTOR — bits [244,252). {EulerV2OperatorModule}
    ///      hosts every op the maker's EVC operator grant covers, so the `TAKE_FOR`
    ///      seam has to name which one. It goes here rather than in a new field
    ///      because word 0 is inside `ref = keccak256(data)`, so the taker grant binds
    ///      the op: a grant signed for `Open` cannot be replayed as anything else.
    ///      {Base._forSlice} reads only bits 255, 254, 253 and [0,16), so these bits
    ///      are invisible to the core.
    function _forLeg(uint256 j) internal pure returns (uint256) {
        return (uint256(1) << 255) | (uint256(EulerV2OperatorModule.Op.Open) << 244) | j;
    }

    function _data() internal pure returns (bytes memory) {
        return abi.encode(
            EulerV2OperatorModule.OpenData({
                forDesc: _forLeg(0),
                forCap: 0,
                collateralVault: address(EWETH),
                borrowVault: address(EUSDC)
            })
        );
    }

    function _auth(bytes memory data, uint256 colCap, uint256 debtCap) internal {
        vm.startPrank(maker);
        permit3.approveToken(address(operatorModule), WETH, uint160(colCap), 0);
        permit3.approveTaker(address(settlement), address(operatorModule), keccak256(data), uint160(debtCap), 0);
        vm.stopPrank();
    }

    function _order_(uint256 nonce, bytes memory data) internal view returns (Order memory) {
        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE_FOR, address(operatorModule), BORROW, address(0), data);
        return _order(maker, nonce, USDC, WETH, BORROW, COLLATERAL, items);
    }

    // ──────────── the guard is simply gone: partial fills work ────────────

    function test_partialFills_noGuardNeeded() public {
        deal(WETH, solver, COLLATERAL * 2); // per-fill-ceil headroom on a SELL leg
        _approveSolverSide(COLLATERAL * 2, WETH);

        bytes memory data = _data();
        _auth(data, COLLATERAL + 2, BORROW);

        Order memory o = _order_(11, data);
        bytes memory sig = _sign(o);

        uint256 col0 = _wethCollateral(maker);
        uint256 debt0 = _usdcDebt(maker);
        uint256 makerWeth = IERC20(WETH).balanceOf(maker);

        vm.prank(solver);
        settlement.fill(o, sig, BORROW / 3);
        assertEq(IERC20(WETH).balanceOf(maker), makerWeth, "net zero in the funding token after slice 1");

        vm.prank(solver);
        settlement.fill(o, sig, BORROW - BORROW / 3);
        assertEq(IERC20(WETH).balanceOf(maker), makerWeth, "net zero after slice 2");

        assertApproxEqRel(_wethCollateral(maker) - col0, COLLATERAL, 1e15, "collateral = the whole signed leg");
        assertApproxEqRel(_usdcDebt(maker) - debt0, BORROW, 1e15, "debt = the whole signed amount");
        assertEq(IERC20(USDC).balanceOf(solver), BORROW, "solver received the whole borrow");
        assertEq(IERC20(WETH).balanceOf(address(operatorModule)), 0, "module drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement drained");
    }

    /// The contrast: the same slice on the constant-`sideAmount` batch module.
    function test_oldBatchModule_refusesTheSameSlice() public {
        deal(WETH, solver, COLLATERAL);
        _approveSolverSide(COLLATERAL, WETH);

        bytes memory data = abi.encode(
            EulerV2OperatorModule.BatchData({
                op: uint256(EulerV2OperatorModule.Op.BatchOpen),
                collateralVault: address(EWETH),
                borrowVault: address(EUSDC),
                sideAmount: COLLATERAL,
                totalAmount: BORROW
            })
        );
        vm.startPrank(maker);
        permit3.approveToken(address(operatorModule), WETH, uint160(COLLATERAL), 0);
        permit3.approveTaker(address(settlement), address(operatorModule), keccak256(data), uint160(BORROW), 0);
        vm.stopPrank();

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE, address(operatorModule), BORROW, address(0), data);
        Order memory o = _order(maker, 12, USDC, WETH, BORROW, COLLATERAL, items);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(FullFillGuard.PartialFillUnsupported.selector, BORROW / 3, BORROW));
        settlement.fill(o, sig, BORROW / 3);
    }

    /// A full fill opens the same position the batch module would — one dispatch,
    /// one deferred status check.
    function test_fullFill_opensTheSamePosition() public {
        deal(WETH, solver, COLLATERAL);
        _approveSolverSide(COLLATERAL, WETH);

        bytes memory data = _data();
        _auth(data, COLLATERAL + 2, BORROW);

        uint256 col0 = _wethCollateral(maker);
        uint256 debt0 = _usdcDebt(maker);

        Order memory o = _order_(13, data);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        settlement.fill(o, sig, BORROW);

        assertApproxEqRel(_wethCollateral(maker) - col0, COLLATERAL, 1e15, "collateral supplied");
        assertApproxEqRel(_usdcDebt(maker) - debt0, BORROW, 1e15, "debt drawn");
        assertEq(IERC20(WETH).balanceOf(maker), 0, "delivered collateral went into the vault");
    }

    // ──────────── gas: the same open, old shape vs TAKE_FOR ────────────
    //
    // Both runs start from an IDENTICAL fork state via snapshot/revert — run
    // back-to-back, whichever goes second finds the vaults, the interest accumulators
    // and the maker's balances warm, which swamps the difference being measured.
    function test_gas_takeFor_vs_batchModule() public {
        deal(WETH, solver, COLLATERAL);
        _approveSolverSide(COLLATERAL, WETH);

        bytes memory tfData = _data();
        _auth(tfData, COLLATERAL + 2, BORROW);
        Order memory tf = _order_(14, tfData);
        bytes memory tfSig = _sign(tf);

        bytes memory bData = abi.encode(
            EulerV2OperatorModule.BatchData({
                op: uint256(EulerV2OperatorModule.Op.BatchOpen),
                collateralVault: address(EWETH),
                borrowVault: address(EUSDC),
                sideAmount: COLLATERAL,
                totalAmount: BORROW
            })
        );
        vm.startPrank(maker);
        permit3.approveToken(address(operatorModule), WETH, uint160(COLLATERAL), 0);
        permit3.approveTaker(address(settlement), address(operatorModule), keccak256(bData), uint160(BORROW), 0);
        vm.stopPrank();
        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE, address(operatorModule), BORROW, address(0), bData);
        Order memory b = _order(maker, 15, USDC, WETH, BORROW, COLLATERAL, items);
        bytes memory bSig = _sign(b);

        uint256 snap = vm.snapshotState();

        vm.prank(solver);
        uint256 g0 = gasleft();
        settlement.fill(b, bSig, BORROW);
        uint256 batchGas = g0 - gasleft();

        vm.revertToState(snap);
        vm.prank(solver);
        g0 = gasleft();
        settlement.fill(tf, tfSig, BORROW);
        uint256 takeForGas = g0 - gasleft();

        emit log_named_uint("EulerV2OperatorModule  (gas)", batchGas);
        emit log_named_uint("EulerV2OperatorModule(gas)", takeForGas);
        emit log_named_int("delta               (gas)", int256(takeForGas) - int256(batchGas));
    }
}
