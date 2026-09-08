// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ExactlyTakerModule} from "../../src/ExactlyModules.sol";
import {ProratedBound} from "@lib/ProratedBound.sol";

/// @dev Records the `maxAssets` ceiling it is handed, so the test can assert what
///      the module actually presented to the protocol rather than inferring it.
contract RecordingMarket {
    uint256 public lastMaxAssets;
    uint256 public lastAssets;

    function borrowAtMaturity(uint256, uint256 assets, uint256 maxAssets, address, address)
        external
        returns (uint256)
    {
        lastAssets = assets;
        lastMaxAssets = maxAssets;
        return assets;
    }
}

/// @title ExactlyProratedBoundTest
/// @notice F26 regression — a maker-signed ABSOLUTE slippage ceiling must shrink
///         with the slice.
///
///  `Base._executeItems` pro-rates an item's `amount` per fill but hands the module
///  `item.data` byte-for-byte, so `maxAssets` used to arrive at full size on every
///  slice. The maker signs "borrow 10,000, never owe more than 11,000"; the FILLER
///  picks N; each 1/N slice was checked against the whole order's ceiling.
///
///  The victim here did nothing wrong — unlike most findings in this repo it needs
///  no stranded balance, no fake contract and no self-harm. That is what makes it
///  the one worth reading.
contract ExactlyProratedBoundTest is Test {
    ExactlyTakerModule internal module;
    RecordingMarket internal market;

    address internal permit3 = address(0xBEEF);
    address internal maker = address(0xA11CE);
    address internal receiver = address(0x5011);
    address internal asset = address(0xA55E7);

    uint256 internal constant MATURITY = 1_800_000_000;
    uint256 internal constant TOTAL = 10_000e6; //  the maker's whole borrow
    uint256 internal constant CEILING = 11_000e6; // "never owe more than this"

    function setUp() public {
        module = new ExactlyTakerModule(permit3);
        market = new RecordingMarket();
    }

    function _data(uint256 ceiling, uint256 total) internal view returns (bytes memory) {
        return abi.encode(uint8(ExactlyTakerModule.Op.Borrow), address(market), asset, MATURITY, ceiling, total);
    }

    /// @dev The defect, stated as an assertion. A 10% slice must carry a 10%
    ///      ceiling. Before the fix `lastMaxAssets` was the full 11,000e6 — a 1,000e6
    ///      borrow authorised to owe 11,000e6, an 1100% rate the maker never signed.
    function test_partialFill_scalesTheCeiling() public {
        uint256 slice = TOTAL / 10;

        vm.prank(permit3);
        module.takeOnBehalf(maker, slice, receiver, _data(CEILING, TOTAL));

        assertEq(market.lastAssets(), slice, "borrowed the slice");
        assertEq(market.lastMaxAssets(), CEILING / 10, "ceiling scaled with the slice");
    }

    /// @dev The guarantee that matters is the SUM: however the filler slices it, the
    ///      maker's total exposure never exceeds what they signed. Floor rounding is
    ///      what makes this hold rather than drift upward.
    function test_slicesNeverExceedTheSignedCeilingInAggregate() public {
        uint256 n = 7;
        uint256 slice = TOTAL / n;
        uint256 sum;

        for (uint256 i; i < n; ++i) {
            vm.prank(permit3);
            module.takeOnBehalf(maker, slice, receiver, _data(CEILING, TOTAL));
            sum += market.lastMaxAssets();
        }

        assertLe(sum, CEILING, "summed per-slice ceilings stay within the signed total");
    }

    /// @dev A full fill is the boundary and must be untouched — the fix must not
    ///      quietly tighten the common path.
    function test_fullFill_passesTheCeilingUnchanged() public {
        vm.prank(permit3);
        module.takeOnBehalf(maker, TOTAL, receiver, _data(CEILING, TOTAL));

        assertEq(market.lastMaxAssets(), CEILING, "full fill keeps the signed ceiling exactly");
    }

    /// @dev `type(uint256).max` is the conventional "no ceiling" sentinel. Scaling it
    ///      would overflow and revert a legitimate fill; it must pass through.
    ///      The first version of {ProratedBound} got this wrong.
    function test_noCeilingSentinel_passesThrough() public {
        vm.prank(permit3);
        module.takeOnBehalf(maker, TOTAL / 10, receiver, _data(type(uint256).max, TOTAL));

        assertEq(market.lastMaxAssets(), type(uint256).max, "sentinel survives slicing");
    }

    /// @dev An order that omits the total is exactly the order that was unprotected,
    ///      so it must fail closed rather than silently behave as before.
    function test_missingTotal_failsClosed() public {
        vm.prank(permit3);
        vm.expectRevert(ProratedBound.BoundTotalMissing.selector);
        module.takeOnBehalf(maker, TOTAL / 10, receiver, _data(CEILING, 0));
    }
}
