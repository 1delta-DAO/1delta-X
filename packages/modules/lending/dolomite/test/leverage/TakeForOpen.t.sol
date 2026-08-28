// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";

import {OperatorArg} from "../../src/interfaces/IDolomite.sol";
import {DolomiteTakeForModule, DolomiteOperateModule} from "../../src/DolomiteModules.sol";
import {DolomiteModulesBase} from "../shared/DolomiteModulesBase.t.sol";

/// @dev `TAKE_FOR` on Dolomite. Like Euler, Dolomite has no position identity
/// object: a position IS the balance set of the maker-signed `(owner,
/// accountNumber)` sub-account, and `operate` may be applied to it repeatedly. So
/// {DolomiteOperateModule}'s {FullFillGuard} was never protecting a protocol
/// constraint — only the fact that a constant `sideAmount` cannot pro-rate.
/// {DolomiteTakeForModule} carries no guard: it partial-fills freely, every slice
/// being its own two-action `operate` under ONE end-of-call solvency check.
contract DolomiteTakeForOpenTest is DolomiteModulesBase {
    DolomiteTakeForModule takeForModule;

    uint256 constant COLLATERAL = 1 ether;
    uint256 constant BORROW = 1_000e6;

    function setUp() public override {
        super.setUp();
        takeForModule = new DolomiteTakeForModule(address(permit3));
        vm.label(address(takeForModule), "dolomiteTakeForModule");

        vm.startPrank(maker);
        OperatorArg[] memory ops = new OperatorArg[](1);
        ops[0] = OperatorArg(address(takeForModule), true);
        DOLOMITE.setOperators(ops);
        IERC20(COLL).approve(address(permit3), type(uint256).max);
        IERC20(DEBT).approve(address(permit3), type(uint256).max);
        vm.stopPrank();
    }

    function _forLeg(uint256 j) internal pure returns (uint256) {
        return (uint256(1) << 255) | j;
    }

    function _data() internal view returns (bytes memory) {
        return abi.encode(
            DolomiteTakeForModule.OpenData({
                forDesc: _forLeg(0),
                forCap: 0,
                dolomite: address(DOLOMITE),
                collMarketId: COLL_MARKET,
                collToken: COLL,
                borrowMarketId: DEBT_MARKET,
                accountNumber: ACCOUNT
            })
        );
    }

    function _auth(bytes memory data, uint256 colCap, uint256 debtCap) internal {
        vm.startPrank(maker);
        permit3.approveToken(address(takeForModule), COLL, uint160(colCap), 0);
        permit3.approveTaker(address(settlement), address(takeForModule), keccak256(data), uint160(debtCap), 0);
        permit3.approveToken(address(settlement), DEBT, uint160(debtCap), 0);
        vm.stopPrank();
    }

    function _order_(uint256 nonce, bytes memory data) internal view returns (Order memory) {
        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE_FOR, address(takeForModule), BORROW, address(0), data);
        return _order(maker, nonce, DEBT, COLL, BORROW, COLLATERAL, items);
    }

    // ──────────── the guard is simply gone: partial fills work ────────────

    function test_partialFills_noGuardNeeded() public {
        _neutralizeRiskOverride();
        deal(COLL, solver, COLLATERAL * 2); // per-fill-ceil headroom on a SELL leg
        _approveSolverSide(COLLATERAL * 2, COLL);

        bytes memory data = _data();
        _auth(data, COLLATERAL + 2, BORROW);

        Order memory o = _order_(21, data);
        bytes memory sig = _sign(o);

        uint256 col0 = _collateralOf(maker);
        uint256 debt0 = _debtOf(maker);
        uint256 makerColl = IERC20(COLL).balanceOf(maker);

        vm.prank(solver);
        settlement.fill(o, sig, BORROW / 3);
        assertEq(IERC20(COLL).balanceOf(maker), makerColl, "net zero in the funding token after slice 1");

        vm.prank(solver);
        settlement.fill(o, sig, BORROW - BORROW / 3);
        assertEq(IERC20(COLL).balanceOf(maker), makerColl, "net zero after slice 2");

        assertApproxEqAbs(_collateralOf(maker) - col0, COLLATERAL, 2, "collateral = the whole signed leg");
        assertApproxEqAbs(_debtOf(maker) - debt0, BORROW, 2, "debt = the whole signed amount");
        assertEq(IERC20(DEBT).balanceOf(solver), BORROW, "solver received the whole borrow");
        assertEq(IERC20(COLL).balanceOf(address(takeForModule)), 0, "module drained");
        assertEq(IERC20(DEBT).balanceOf(address(settlement)), 0, "settlement drained");
    }

    /// The contrast: the same slice on the constant-`sideAmount` operate module.
    function test_oldOperateModule_refusesTheSameSlice() public {
        _neutralizeRiskOverride();
        deal(COLL, solver, COLLATERAL);
        _approveSolverSide(COLLATERAL, COLL);

        bytes memory data = abi.encode(
            DolomiteOperateModule.BatchData({
                mode: 0,
                dolomite: address(DOLOMITE),
                collMarketId: COLL_MARKET,
                collToken: COLL,
                borrowMarketId: DEBT_MARKET,
                borrowToken: DEBT,
                accountNumber: ACCOUNT,
                sideAmount: COLLATERAL,
                totalAmount: BORROW
            })
        );
        vm.startPrank(maker);
        permit3.approveToken(address(operateModule), COLL, uint160(COLLATERAL), 0);
        permit3.approveTaker(address(settlement), address(operateModule), keccak256(data), uint160(BORROW), 0);
        vm.stopPrank();

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE, address(operateModule), BORROW, address(0), data);
        Order memory o = _order(maker, 22, DEBT, COLL, BORROW, COLLATERAL, items);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(FullFillGuard.PartialFillUnsupported.selector, BORROW / 3, BORROW));
        settlement.fill(o, sig, BORROW / 3);
    }

    /// A full fill opens the same position the operate module would — one dispatch,
    /// one end-of-call solvency check.
    function test_fullFill_opensTheSamePosition() public {
        _neutralizeRiskOverride();
        deal(COLL, solver, COLLATERAL);
        _approveSolverSide(COLLATERAL, COLL);

        bytes memory data = _data();
        _auth(data, COLLATERAL + 2, BORROW);

        uint256 col0 = _collateralOf(maker);
        uint256 debt0 = _debtOf(maker);

        Order memory o = _order_(23, data);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        settlement.fill(o, sig, BORROW);

        assertApproxEqAbs(_collateralOf(maker) - col0, COLLATERAL, 2, "collateral supplied");
        assertApproxEqAbs(_debtOf(maker) - debt0, BORROW, 2, "debt drawn");
        assertEq(IERC20(COLL).balanceOf(maker), 0, "delivered collateral went into the sub-account");
    }

    // ──────────── gas: the same open, old shape vs TAKE_FOR ────────────
    // Both runs from an IDENTICAL fork state — see the Euler/Aave notes on why
    // back-to-back measurement without a revert is meaningless here.
    function test_gas_takeFor_vs_operateModule() public {
        _neutralizeRiskOverride();
        deal(COLL, solver, COLLATERAL);
        _approveSolverSide(COLLATERAL, COLL);

        bytes memory tfData = _data();
        _auth(tfData, COLLATERAL + 2, BORROW);
        Order memory tf = _order_(24, tfData);
        bytes memory tfSig = _sign(tf);

        bytes memory oData = abi.encode(
            DolomiteOperateModule.BatchData({
                mode: 0,
                dolomite: address(DOLOMITE),
                collMarketId: COLL_MARKET,
                collToken: COLL,
                borrowMarketId: DEBT_MARKET,
                borrowToken: DEBT,
                accountNumber: ACCOUNT,
                sideAmount: COLLATERAL,
                totalAmount: BORROW
            })
        );
        vm.startPrank(maker);
        permit3.approveToken(address(operateModule), COLL, uint160(COLLATERAL), 0);
        permit3.approveTaker(address(settlement), address(operateModule), keccak256(oData), uint160(BORROW), 0);
        vm.stopPrank();
        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE, address(operateModule), BORROW, address(0), oData);
        Order memory o = _order(maker, 25, DEBT, COLL, BORROW, COLLATERAL, items);
        bytes memory oSig = _sign(o);

        uint256 snap = vm.snapshotState();

        vm.prank(solver);
        uint256 g0 = gasleft();
        settlement.fill(o, oSig, BORROW);
        uint256 operateGas = g0 - gasleft();

        vm.revertToState(snap);
        vm.prank(solver);
        g0 = gasleft();
        settlement.fill(tf, tfSig, BORROW);
        uint256 takeForGas = g0 - gasleft();

        emit log_named_uint("DolomiteOperateModule (gas)", operateGas);
        emit log_named_uint("DolomiteTakeForModule (gas)", takeForGas);
        emit log_named_int("delta                 (gas)", int256(takeForGas) - int256(operateGas));
    }
}
