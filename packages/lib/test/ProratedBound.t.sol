// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProratedBound} from "../src/ProratedBound.sol";

/// @dev {ProratedBound.scale} is pure and internal; a thin wrapper lets the tests
///      assert on its reverts.
contract ProratedBoundHarness {
    function scale(uint256 bound, uint256 amount, uint256 total) external pure returns (uint256) {
        return ProratedBound.scale(bound, amount, total);
    }
}

/// @title ProratedBoundTest
/// @notice The scaler's four regions: the max sentinel passes through; a full fill
///         returns the bound; a partial scales it (floor); and — since F29 — a
///         slice LARGER than the total is refused rather than read as a full fill,
///         because that is what a mis-encoded blob looks like (ExactlyRepayModule's
///         header put the permit deadline in the total's slot; every 18-decimal
///         slice exceeded ~1.7e9 and got the whole ceiling).
contract ProratedBoundTest is Test {
    ProratedBoundHarness h;

    function setUp() public {
        h = new ProratedBoundHarness();
    }

    function test_sentinelPassesThrough() public view {
        assertEq(h.scale(type(uint256).max, 1, 1000), type(uint256).max);
    }

    function test_fullFillReturnsTheBound() public view {
        assertEq(h.scale(11_000e6, 10_000e6, 10_000e6), 11_000e6);
    }

    function test_partialScalesDown() public view {
        assertEq(h.scale(11_000e6, 1_000e6, 10_000e6), 1_100e6, "10% slice, 10% of the ceiling");
        assertEq(h.scale(11_000e6, 3_333e6, 10_000e6), (11_000e6 * 3_333e6) / 10_000e6, "floor rounding");
    }

    function test_missingTotalReverts() public {
        vm.expectRevert(ProratedBound.BoundTotalMissing.selector);
        h.scale(1, 1, 0);
    }

    /// @dev F29 finding 2: a deadline where the total should be. Before, `amount >=
    ///      total` returned the whole bound on a 1% slice; now it reverts.
    function test_sliceAboveTotal_reverts() public {
        uint256 deadline = 1_750_000_000;
        vm.expectRevert(abi.encodeWithSelector(ProratedBound.BoundSliceExceedsTotal.selector, 100e18, deadline));
        h.scale(11_000e18, 100e18, deadline);
    }
}
