// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {Narrow160} from "@lib/Narrow160.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";

import {DolomiteModulesBase} from "../shared/DolomiteModulesBase.t.sol";
import {DolomiteOperatorModule} from "../../src/DolomiteOperatorModule.sol";
import {IDolomiteMargin, AccountInfo, WeiBalance} from "../../src/interfaces/IDolomite.sol";

/// @dev {Narrow160} AT THE TWO ORDER-DATA PERMIT3 PULLS IN `_batch`, DRIVEN END TO END.
///
///  Both fused plain-`TAKE` ops pull their side leg out of the maker's wallet with
///  `permit3.transferFrom(…, uint160 amount)` and then `forceApprove` the SAME amount,
///  un-truncated, to the order-decoded venue. The amount comes from `BatchData`
///  (maker-signed item `data`), which the core never width-checks — unlike the item
///  slice. A clipping cast there was the F-2 drain (pull 1 wei, approve 2^160 + 1);
///  `Narrow160.to160` must REVERT instead. Pinned here, per site:
///
///   • `BatchOpen`  (:417) — the pull amount IS `p.sideAmount`, verbatim.
///   • `BatchClose` (:426) — the pull amount is `min(p.sideAmount, debt)`, so reaching
///     the narrowing with 2^160 + 1 needs BOTH the signed `sideAmount` AND the live
///     debt at or above it. A real Dolomite position cannot hold 2^160 wei of USDC
///     debt, so the venue's `getAccountWei` is mocked for exactly
///     (maker, ACCOUNT, DEBT_MARKET) — the same number a maker-signed fake venue
///     (`p.dolomite` is order-decoded) would report. With a smaller debt the `min`
///     clamps below the bound and the site is not reachable with an overflowing value.
///
///  Entry path: `Settlement.fill` → `Permit3.take` (spends the maker's taker bucket
///  for the item slice, which fits in uint160) → `DolomiteOperatorModule.takeOnBehalf`
///  → `_batch`. Each overflow test asserts the bare `AmountOverflow` selector surfaces
///  from the outer `fill` (nothing wraps it) and that no balance or Permit3 allowance
///  moved. The boundary tests sign exactly `type(uint160).max` and assert the revert
///  that follows (the maker never granted that much) is NOT `AmountOverflow`.
contract DolomiteNarrow160OverflowTest is DolomiteModulesBase {
    uint256 constant OVER = uint256(type(uint160).max) + 1;
    uint256 constant AT_MAX = uint256(type(uint160).max);

    uint256 constant ITEM_AMOUNT = 1_000e6; // Open: USDC borrowed. Close: see below.
    uint256 constant CLOSE_ITEM = 1 ether; // Close: WETH collateral withdrawn
    uint256 constant LEG_OUT = 1 ether; // the order's (small) output leg
    /// @dev Distinct from every other grant, so an `InsufficientAllowance(MODULE_GRANT)`
    ///      revert can only be the module's own side-leg pull — i.e. past the narrowing.
    uint160 constant MODULE_GRANT = 1 ether + 7;

    // ──────────────────── builders ────────────────────

    function _batchData(DolomiteOperatorModule.Op op, uint256 sideAmount, uint256 total)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(
            DolomiteOperatorModule.BatchData({
                op: uint256(op),
                dolomite: address(DOLOMITE),
                collMarketId: COLL_MARKET,
                collToken: COLL,
                borrowMarketId: DEBT_MARKET,
                borrowToken: DEBT,
                accountNumber: ACCOUNT,
                sideAmount: sideAmount,
                totalAmount: total
            })
        );
    }

    /// @dev Maker grants: the taker bucket for the item (so `Permit3.take` passes and
    ///      the module is reached) and a SMALL token grant to the module for the
    ///      pulled side token — far below either tested amount.
    function _grants(bytes memory data, uint256 itemAmount, address pulledToken) internal {
        vm.startPrank(maker);
        IERC20(pulledToken).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(operatorModule), pulledToken, MODULE_GRANT, 0);
        permit3.approveTaker(address(settlement), address(operatorModule), keccak256(data), uint160(itemAmount), 0);
        vm.stopPrank();
    }

    function _openFill(uint256 sideAmount) internal returns (Order memory order, bytes memory sig, bytes memory data) {
        data = _batchData(DolomiteOperatorModule.Op.BatchOpen, sideAmount, ITEM_AMOUNT);
        deal(COLL, maker, 5 ether);
        deal(COLL, solver, LEG_OUT);
        _grants(data, ITEM_AMOUNT, COLL);
        _approveSolverSide(LEG_OUT, COLL);

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE, address(operatorModule), ITEM_AMOUNT, address(0), data);
        order = _order(maker, 11, DEBT, COLL, ITEM_AMOUNT, LEG_OUT, items);
        sig = _sign(order);
    }

    /// @dev Force the maker's live USDC debt on the fork venue to `debt`.
    function _mockDebt(uint256 debt) internal {
        vm.mockCall(
            address(DOLOMITE),
            abi.encodeCall(IDolomiteMargin.getAccountWei, (AccountInfo(maker, ACCOUNT), DEBT_MARKET)),
            abi.encode(WeiBalance(false, debt))
        );
    }

    function _closeFill(uint256 sideAmount) internal returns (Order memory order, bytes memory sig, bytes memory data) {
        data = _batchData(DolomiteOperatorModule.Op.BatchClose, sideAmount, CLOSE_ITEM);
        deal(DEBT, maker, 5_000e6);
        deal(DEBT, solver, LEG_OUT);
        _grants(data, CLOSE_ITEM, DEBT);
        _approveSolverSide(LEG_OUT, DEBT);

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE, address(operatorModule), CLOSE_ITEM, address(0), data);
        order = _order(maker, 12, COLL, DEBT, CLOSE_ITEM, LEG_OUT, items);
        sig = _sign(order);
    }

    // ──────────────────── state snapshot ────────────────────

    struct Snap {
        uint256 makerColl;
        uint256 makerDebt;
        uint256 solverColl;
        uint256 solverDebt;
        uint256 moduleColl;
        uint256 moduleDebt;
        uint256 venueColl;
        uint256 venueDebt;
        uint160 moduleGrantColl;
        uint160 moduleGrantDebt;
        uint160 takerBucket;
        uint256 venueAllowanceColl;
        uint256 venueAllowanceDebt;
    }

    function _snap(bytes memory data) internal view returns (Snap memory s) {
        s.makerColl = IERC20(COLL).balanceOf(maker);
        s.makerDebt = IERC20(DEBT).balanceOf(maker);
        s.solverColl = IERC20(COLL).balanceOf(solver);
        s.solverDebt = IERC20(DEBT).balanceOf(solver);
        s.moduleColl = IERC20(COLL).balanceOf(address(operatorModule));
        s.moduleDebt = IERC20(DEBT).balanceOf(address(operatorModule));
        s.venueColl = IERC20(COLL).balanceOf(address(DOLOMITE));
        s.venueDebt = IERC20(DEBT).balanceOf(address(DOLOMITE));
        (s.moduleGrantColl,) = permit3.tokenAllowance(maker, address(operatorModule), COLL);
        (s.moduleGrantDebt,) = permit3.tokenAllowance(maker, address(operatorModule), DEBT);
        (s.takerBucket,) = permit3.takerAllowance(maker, address(settlement), address(operatorModule), keccak256(data));
        s.venueAllowanceColl = IERC20(COLL).allowance(address(operatorModule), address(DOLOMITE));
        s.venueAllowanceDebt = IERC20(DEBT).allowance(address(operatorModule), address(DOLOMITE));
    }

    function _assertUnchanged(Snap memory a, Snap memory b) internal pure {
        assertEq(b.makerColl, a.makerColl, "maker WETH moved");
        assertEq(b.makerDebt, a.makerDebt, "maker USDC moved");
        assertEq(b.solverColl, a.solverColl, "solver WETH moved");
        assertEq(b.solverDebt, a.solverDebt, "solver USDC moved");
        assertEq(b.moduleColl, a.moduleColl, "module WETH moved");
        assertEq(b.moduleDebt, a.moduleDebt, "module USDC moved");
        assertEq(b.venueColl, a.venueColl, "venue WETH moved");
        assertEq(b.venueDebt, a.venueDebt, "venue USDC moved");
        assertEq(b.moduleGrantColl, a.moduleGrantColl, "maker->module WETH grant spent");
        assertEq(b.moduleGrantDebt, a.moduleGrantDebt, "maker->module USDC grant spent");
        assertEq(b.takerBucket, a.takerBucket, "taker bucket spent");
        assertEq(b.venueAllowanceColl, 0, "module left a WETH approval on the venue");
        assertEq(b.venueAllowanceDebt, 0, "module left a USDC approval on the venue");
    }

    function _fillRevertData(Order memory order, bytes memory sig, uint256 amount)
        internal
        returns (bytes memory err)
    {
        vm.prank(solver);
        try settlement.fill(order, sig, amount) {
            fail();
        } catch (bytes memory e) {
            err = e;
        }
    }

    /// @dev The revert is the module's own Permit3 pull running out of the maker's
    ///      (deliberately small) grant — so `to160` returned and the pull was attempted.
    function _assertPastNarrowing(bytes memory err) internal pure {
        assertTrue(bytes4(err) != Narrow160.AmountOverflow.selector, "uint160.max must pass the narrowing");
        assertEq(err, abi.encodeWithSelector(IPermit3.InsufficientAllowance.selector, MODULE_GRANT), "module pull hit");
    }

    // ──────────────────── :417 — BatchOpen side-leg pull ────────────────────

    function test_narrow160_batchOpenSideAmount_reverts() public {
        (Order memory order, bytes memory sig, bytes memory data) = _openFill(OVER);
        Snap memory before = _snap(data);

        vm.prank(solver);
        vm.expectRevert(Narrow160.AmountOverflow.selector);
        settlement.fill(order, sig, ITEM_AMOUNT);

        _assertUnchanged(before, _snap(data));
    }

    function test_narrow160_batchOpenSideAmount_atMaxPassesNarrowing() public {
        (Order memory order, bytes memory sig,) = _openFill(AT_MAX);
        bytes memory err = _fillRevertData(order, sig, ITEM_AMOUNT);
        _assertPastNarrowing(err);
    }

    // ──────────────────── :426 — BatchClose repay pull ────────────────────

    function test_narrow160_batchCloseRepayAmount_reverts() public {
        (Order memory order, bytes memory sig, bytes memory data) = _closeFill(OVER);
        _mockDebt(OVER); // toRepay = min(sideAmount, debt) = 2^160
        Snap memory before = _snap(data);

        vm.prank(solver);
        vm.expectRevert(Narrow160.AmountOverflow.selector);
        settlement.fill(order, sig, CLOSE_ITEM);

        _assertUnchanged(before, _snap(data));
    }

    /// @dev The `min` clamp: an overflowing signed `sideAmount` against a normal-sized
    ///      debt narrows fine — the site is only reachable with both words ≥ 2^160.
    function test_narrow160_batchCloseRepayAmount_clampedByDebtPassesNarrowing() public {
        (Order memory order, bytes memory sig,) = _closeFill(OVER);
        _mockDebt(AT_MAX);
        bytes memory err = _fillRevertData(order, sig, CLOSE_ITEM);
        _assertPastNarrowing(err);
    }

    function test_narrow160_batchCloseRepayAmount_atMaxPassesNarrowing() public {
        (Order memory order, bytes memory sig,) = _closeFill(AT_MAX);
        _mockDebt(OVER);
        bytes memory err = _fillRevertData(order, sig, CLOSE_ITEM);
        _assertPastNarrowing(err);
    }
}
