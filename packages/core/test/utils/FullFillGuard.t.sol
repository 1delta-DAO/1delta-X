// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {FullFillGuard} from "@core/utils/FullFillGuard.sol";

/// @dev Stand-in for a composite module (deposit+borrow / repay+withdraw). It
///      reproduces the exact defect: `sideAmount` lives in the maker-signed blob
///      and does NOT pro-rate, so every slice re-pulls it in full.
contract CompositeModuleStub {
    uint256 public totalPulled;
    bool public guarded;

    constructor(bool _guarded) {
        guarded = _guarded;
    }

    function execute(uint256 amount, uint256 sideAmount, uint256 totalAmount) external {
        if (guarded) FullFillGuard.requireFullFill(amount, totalAmount);
        // The side leg is a constant from `data` — this is the over-pull.
        totalPulled += sideAmount;
    }
}

/// @title FullFillGuardTest
/// @notice Regression test for the composite-item over-pull.
///
///         A maker signs "borrow 1000, post 500 collateral" and grants the module
///         the usual standing Permit3 token allowance. `Base._executeItems`
///         pro-rates the 1000 across fills, but `sideAmount = 500` sits inside
///         `item.data` and is constant, so an N-slice fill pulled N × 500 — a
///         leverage ratio the maker never signed, at a slice count the SOLVER
///         chooses.
contract FullFillGuardTest is Test {
    uint256 constant BORROW_TOTAL = 1_000e6;
    uint256 constant SIDE = 500e18;

    /// The bug, reproduced against an unguarded module: ten slices, ten full pulls.
    function test_unguarded_overpulls_onEveryslice() public {
        CompositeModuleStub m = new CompositeModuleStub(false);
        for (uint256 i; i < 10; i++) {
            m.execute(BORROW_TOTAL / 10, SIDE, BORROW_TOTAL);
        }
        assertEq(m.totalPulled(), SIDE * 10, "10x the signed collateral was pulled");
    }

    /// The guard rejects the first slice, so the over-pull is unreachable.
    function test_guarded_rejectsPartialSlice() public {
        CompositeModuleStub m = new CompositeModuleStub(true);
        vm.expectRevert(
            abi.encodeWithSelector(FullFillGuard.PartialFillUnsupported.selector, BORROW_TOTAL / 10, BORROW_TOTAL)
        );
        m.execute(BORROW_TOTAL / 10, SIDE, BORROW_TOTAL);
        assertEq(m.totalPulled(), 0, "nothing pulled");
    }

    /// A genuine full fill still works — the guard is a binding, not a blanket ban.
    function test_guarded_allowsFullFill() public {
        CompositeModuleStub m = new CompositeModuleStub(true);
        m.execute(BORROW_TOTAL, SIDE, BORROW_TOTAL);
        assertEq(m.totalPulled(), SIDE, "exactly the signed collateral, once");
    }

    /// A maker who omits `totalAmount` gets a revert rather than a silently
    /// unguarded pull.
    function test_missingTotalAmount_failsClosed() public {
        CompositeModuleStub m = new CompositeModuleStub(true);
        vm.expectRevert(abi.encodeWithSelector(FullFillGuard.PartialFillUnsupported.selector, BORROW_TOTAL, 0));
        m.execute(BORROW_TOTAL, SIDE, 0);
    }

    function testFuzz_anySliceBelowTotalIsRejected(uint256 slice) public {
        slice = bound(slice, 1, BORROW_TOTAL - 1);
        CompositeModuleStub m = new CompositeModuleStub(true);
        vm.expectRevert(
            abi.encodeWithSelector(FullFillGuard.PartialFillUnsupported.selector, slice, BORROW_TOTAL)
        );
        m.execute(slice, SIDE, BORROW_TOTAL);
    }
}
