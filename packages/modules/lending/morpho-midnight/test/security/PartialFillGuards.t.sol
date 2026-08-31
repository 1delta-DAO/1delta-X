// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Item, ItemOp, Order} from "@core/settlement/Settlement.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";

import {MidnightModulesBase} from "../shared/MidnightModulesBase.t.sol";

/// @title MidnightPartialFillGuardsTest
/// @notice Midnight was the LAST package in the tree relying on maker discipline
///         where every sibling enforces on-chain. Three legs carry a side amount
///         that does NOT pro-rate across fills:
///
///           • {MidnightBorrowModule} / {MidnightLendModule} — `units` lives in
///             `data`, which is constant across fills, while `amount` is this
///             fill's slice. Each slice would `take` the SAME `units` again, so an
///             N-slice fill sells N × the debt (or buys N × the credit) the maker
///             signed for. The module headers said "MUST be part of a full-fill
///             order"; nothing enforced it.
///
///           • {MidnightTakerModule} in `BalanceMode.Full` — reads a LIVE protocol
///             balance and liquidates all of it, so a 1-unit slice force-closes the
///             whole position and leaves nothing for the rest of the order.
///
///         All three now carry a maker-signed `totalAmount` and assert the slice
///         equals it ({FullFillGuard}), matching Aave/Comet/Euler/Fluid/Dolomite.
///         The last test is the other half of the contract: `Exact` mode must stay
///         freely sliceable, so the guard is scoped to the modes that need it.
contract MidnightPartialFillGuardsTest is MidnightModulesBase {
    // ──────────────────── Borrow (TAKE, `units` side leg) ────────────────────

    function test_borrow_partialFill_reverts() public {
        uint256 collateralIn = 1e18;
        uint256 borrowUnits = 1_000e6;

        COLL.mint(solver, collateralIn);
        LOAN.mint(address(midnight), borrowUnits);

        bytes memory supplyData = _supplyData();
        bytes memory borrowData = _borrowData(borrowUnits, borrowUnits);

        _makerApproveToken(address(supplyModule), address(COLL), collateralIn);
        _makerApproveTaker(address(borrowModule), keccak256(borrowData), borrowUnits);
        _makerAuthorize(address(borrowModule));
        _approveSolverColl(collateralIn);

        Item[] memory items = new Item[](2);
        items[0] = _item(ItemOp.MAKE, address(supplyModule), collateralIn, supplyData);
        items[1] = _item(ItemOp.TAKE, address(borrowModule), borrowUnits, borrowData);
        Order memory order = _order(maker, 1, address(LOAN), address(COLL), borrowUnits, collateralIn, items);
        bytes memory sig = _sign(order);

        // Half the anchor ⇒ the TAKE slice is half the item, but `units` inside
        // `data` is unchanged — exactly the shape that used to borrow twice over.
        uint256 half = borrowUnits / 2;
        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(FullFillGuard.PartialFillUnsupported.selector, half, borrowUnits)
        );
        settlement.fill(order, sig, half);
    }

    // ──────────────────── Lend (MAKE, `units` side leg) ────────────────────

    function test_lend_partialFill_reverts() public {
        uint256 lendUnits = 1_000e6;
        uint256 collCost = 0.5e18;

        LOAN.mint(solver, lendUnits);
        COLL.mint(maker, collCost);

        bytes memory lendData = _lendData(lendUnits, lendUnits);

        _makerApproveToken(address(lendModule), address(LOAN), lendUnits);
        _makerApproveToken(address(settlement), address(COLL), collCost);
        _makerAuthorize(address(lendModule));
        _approveSolverLoan(lendUnits);

        Item[] memory items = new Item[](1);
        items[0] = _item(ItemOp.MAKE, address(lendModule), lendUnits, lendData);
        Order memory order = _order(maker, 4, address(COLL), address(LOAN), collCost, lendUnits, items);
        bytes memory sig = _sign(order);

        uint256 half = collCost / 2; // the anchor is tokenIn (COLL) on this order
        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(FullFillGuard.PartialFillUnsupported.selector, lendUnits / 2, lendUnits)
        );
        settlement.fill(order, sig, half);
    }

    // ──────────────────── Taker, `BalanceMode.Full` ────────────────────

    function test_withdrawCollateralFull_partialFill_reverts() public {
        uint256 debtUnits = 1_000e6;
        uint256 collat = 1e18;
        uint256 collForward = 0.9e18;

        _seedCollateral(maker, collat);
        midnight.seedDebt(_market(), maker, debtUnits);
        LOAN.mint(solver, debtUnits);

        bytes memory repayData = _repayData();
        bytes memory wcData = _withdrawCollateralData(1, collForward); // Full

        _makerApproveToken(address(repayModule), address(LOAN), debtUnits);
        _makerApproveTaker(address(takerModule), keccak256(wcData), collForward);
        _makerAuthorize(address(takerModule));
        _approveSolverLoan(debtUnits);

        Item[] memory items = new Item[](2);
        items[0] = _item(ItemOp.MAKE, address(repayModule), debtUnits, repayData);
        items[1] = _item(ItemOp.TAKE, address(takerModule), collForward, wcData);
        Order memory order = _order(maker, 3, address(COLL), address(LOAN), collForward, debtUnits, items);
        bytes memory sig = _sign(order);

        // One unit of the anchor: enough to unwind the maker's ENTIRE collateral
        // before the guard existed, leaving every later slice unfillable.
        uint256 slice = collForward / 2;
        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(FullFillGuard.PartialFillUnsupported.selector, slice, collForward)
        );
        settlement.fill(order, sig, slice);

        assertEq(_collateralOf(maker), collat, "position untouched by the rejected slice");
    }

    // ──────────────────── The other half: `Exact` stays sliceable ────────────

    /// @notice The guard must NOT leak into `Exact` mode — that leg moves exactly
    ///         `amount`, pro-rates correctly, and partial fills are the point.
    function test_withdrawCollateralExact_partialFill_stillWorks() public {
        uint256 debtUnits = 1_000e6;
        uint256 collat = 1e18;

        _seedCollateral(maker, collat);
        midnight.seedDebt(_market(), maker, debtUnits);
        LOAN.mint(solver, debtUnits);

        bytes memory repayData = _repayData();
        bytes memory wcData = _withdrawCollateralData(0, 0); // Exact — total unused

        _makerApproveToken(address(repayModule), address(LOAN), debtUnits);
        _makerApproveTaker(address(takerModule), keccak256(wcData), collat);
        _makerAuthorize(address(takerModule));
        _approveSolverLoan(debtUnits);

        Item[] memory items = new Item[](2);
        items[0] = _item(ItemOp.MAKE, address(repayModule), debtUnits, repayData);
        items[1] = _item(ItemOp.TAKE, address(takerModule), collat, wcData);
        Order memory order = _order(maker, 2, address(COLL), address(LOAN), collat, debtUnits, items);
        bytes memory sig = _sign(order);

        uint256 half = collat / 2;
        vm.prank(solver);
        settlement.fill(order, sig, half);

        assertEq(COLL.balanceOf(solver), half, "half the collateral delivered");
        assertEq(_collateralOf(maker), collat - half, "the rest stays in the position");
    }
}
