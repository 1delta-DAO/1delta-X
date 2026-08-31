// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {MidnightLendModule, MidnightBorrowModule} from "../../src/MidnightModules.sol";
import {MidnightModulesBase} from "../shared/MidnightModulesBase.t.sol";

/// @title MidnightOfferSideAndApprovalsTest
/// @notice The two open Midnight findings.
///
///  (1) `offer.buy` was decoded and used but never checked against the leg's role.
///      Midnight's `take` derives who pays and who receives entirely from that one
///      flag, so an order carrying the wrong value silently INVERTS the leg:
///
///        • `MidnightLendModule` is the lend leg and hard-codes
///          `receiverIfTakerIsSeller = address(0)`. With `buy == true` the maker
///          becomes the seller/borrower — they take on debt and the borrowed
///          proceeds are sent to the zero address. The maker keeps the debt and
///          the funds are burned.
///
///        • `MidnightBorrowModule` is a value-OUT leg. With `buy == false` the
///          maker becomes the buyer/lender and Midnight PULLS from the payer
///          instead of paying out, turning a value-out leg into a value-in one.
///
///  (2) The modules granted Midnight a standing `type(uint256).max` allowance via
///      `ensureApproval`. Midnight being an immutable, trusted singleton is not
///      enough to make that safe: `take` lets the CALLER nominate the payer
///      (`takerCallback`, falling back to `msg.sender` only when zero), so any
///      external account can call `take` designating a module as payer. A standing
///      allowance is exactly what would let that pull succeed. Approvals are now
///      scoped to the amount each call funds and cleared afterwards.
contract MidnightOfferSideAndApprovalsTest is MidnightModulesBase {
    // ── (1) offer.buy must match the leg's role ───────────────────────────────

    /// The lend leg is the buy side: `offer.buy == true` is rejected.
    function test_lend_rejectsSellSideOffer() public {
        bytes memory wrongSide = abi.encode(_offer(true), bytes(""), uint256(1e6), uint256(1e6));

        LOAN.mint(maker, 1e6);
        _makerApproveToken(address(lendModule), address(LOAN), 1e6);

        vm.prank(address(settlement));
        vm.expectRevert(MidnightLendModule.WrongOfferSide.selector);
        lendModule.makeOnBehalf(maker, 1e6, wrongSide);
    }

    /// The borrow leg is the sell side: `offer.buy == false` is rejected.
    function test_borrow_rejectsBuySideOffer() public {
        bytes memory wrongSide = abi.encode(_offer(false), bytes(""), uint256(1e6), uint256(1e6));

        _makerApproveTaker(address(borrowModule), keccak256(wrongSide), 1e6);
        _makerAuthorize(address(borrowModule));

        vm.prank(address(permit3));
        vm.expectRevert(MidnightBorrowModule.WrongOfferSide.selector);
        borrowModule.takeOnBehalf(maker, 1e6, solver, wrongSide);
    }

    /// The side check fires BEFORE the module pulls the maker's budget — the lend
    /// leg fails closed without taking custody of anything.
    function test_lend_wrongSide_takesNoCustody() public {
        bytes memory wrongSide = abi.encode(_offer(true), bytes(""), uint256(1e6), uint256(1e6));

        LOAN.mint(maker, 1e6);
        _makerApproveToken(address(lendModule), address(LOAN), 1e6);

        vm.prank(address(settlement));
        vm.expectRevert(MidnightLendModule.WrongOfferSide.selector);
        lendModule.makeOnBehalf(maker, 1e6, wrongSide);

        assertEq(LOAN.balanceOf(maker), 1e6, "maker budget untouched");
        assertEq(LOAN.balanceOf(address(lendModule)), 0, "module took no custody");
    }

    /// The correctly-sided offer is unaffected — this is a binding, not a ban.
    function test_correctlySidedOffersStillWork() public {
        uint256 units = 1_000e6;

        LOAN.mint(maker, units);
        LOAN.mint(address(midnight), units);
        _makerApproveToken(address(lendModule), address(LOAN), units);
        _makerAuthorize(address(lendModule));

        vm.prank(address(settlement));
        lendModule.makeOnBehalf(maker, units, _lendData(units, units));

        assertGt(_creditOf(maker), 0, "maker holds credit: the lend went through");
    }

    // ── (2) no standing allowance survives a call ─────────────────────────────

    function test_supply_leavesNoStandingAllowance() public {
        uint256 amount = 1e18;
        COLL.mint(maker, amount);
        _makerApproveToken(address(supplyModule), address(COLL), amount);

        vm.prank(address(settlement));
        supplyModule.makeOnBehalf(maker, amount, _supplyData());

        assertEq(
            IERC20(address(COLL)).allowance(address(supplyModule), address(midnight)),
            0,
            "supply module leaves no allowance to Midnight"
        );
    }

    function test_repay_leavesNoStandingAllowance() public {
        uint256 units = 1_000e6;
        midnight.seedDebt(_market(), maker, units);

        LOAN.mint(maker, units);
        _makerApproveToken(address(repayModule), address(LOAN), units);

        vm.prank(address(settlement));
        repayModule.makeOnBehalf(maker, units, _repayData());

        assertEq(
            IERC20(address(LOAN)).allowance(address(repayModule), address(midnight)),
            0,
            "repay module leaves no allowance to Midnight"
        );
    }

    function test_lend_leavesNoStandingAllowance() public {
        uint256 units = 1_000e6;

        LOAN.mint(maker, units);
        LOAN.mint(address(midnight), units);
        _makerApproveToken(address(lendModule), address(LOAN), units);
        _makerAuthorize(address(lendModule));

        vm.prank(address(settlement));
        lendModule.makeOnBehalf(maker, units, _lendData(units, units));

        assertEq(
            IERC20(address(LOAN)).allowance(address(lendModule), address(midnight)),
            0,
            "lend module leaves no allowance to Midnight"
        );
    }

    /// The property stated directly: after any maker leg, a third party who names
    /// a module as `take`'s payer has no allowance to draw on.
    function test_noModuleRetainsAllowanceToMidnight() public {
        uint256 amount = 1e18;
        COLL.mint(maker, amount);
        _makerApproveToken(address(supplyModule), address(COLL), amount);

        vm.prank(address(settlement));
        supplyModule.makeOnBehalf(maker, amount, _supplyData());

        address[3] memory modules = [address(supplyModule), address(repayModule), address(lendModule)];
        for (uint256 i; i < modules.length; i++) {
            assertEq(IERC20(address(COLL)).allowance(modules[i], address(midnight)), 0, "no COLL allowance");
            assertEq(IERC20(address(LOAN)).allowance(modules[i], address(midnight)), 0, "no LOAN allowance");
        }
    }
}
