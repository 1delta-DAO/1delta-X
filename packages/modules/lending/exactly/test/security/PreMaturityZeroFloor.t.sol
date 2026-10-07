// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ExactlyTakerModule} from "../../src/ExactlyModules.sol";

/// @dev Minimal fixed-maturity market: a live fixed deposit and a recording
///      `withdrawAtMaturity` that pays face (the module never sees the discount).
contract RecordingFixedWithdrawMarket {
    uint256 public calls;
    uint256 public lastMinAssets;

    function fixedDepositPositions(uint256, address) external pure returns (uint256, uint256) {
        return (1_000_000e6, 0);
    }

    function withdrawAtMaturity(uint256, uint256 assets, uint256 minAssetsRequired, address, address)
        external
        returns (uint256)
    {
        ++calls;
        lastMinAssets = minAssetsRequired;
        return assets;
    }
}

/// @title ExactlyPreMaturityZeroFloorTest
/// @notice ACCEPTED-PATTERNS-REVIEW B15 (2026-10-06), pinned without a fork RPC.
///         A pre-maturity fixed withdraw signed with `minAssetsRequired == 0` is an
///         unbounded wallet draw (`owed − assetsDiscounted`) a filler can widen in the
///         same block, so the module refuses it — the twin of the repay side's
///         `ZeroMaxAssets`. At/after maturity the face is paid in full and 0 is legal.
///         `takeFloored` (the lens's early warning) must agree with the revert.
contract ExactlyPreMaturityZeroFloorTest is Test {
    ExactlyTakerModule internal module;
    RecordingFixedWithdrawMarket internal market;

    address internal permit3 = address(0xBEEF);
    address internal maker = address(0xA11CE);
    address internal receiver = address(0x5011);
    address internal asset = address(0xA55E7);

    uint256 internal constant MATURITY = 1_800_000_000;
    uint256 internal constant AMOUNT = 10_000e6;

    function setUp() public {
        module = new ExactlyTakerModule(permit3);
        market = new RecordingFixedWithdrawMarket();
    }

    function _data(uint256 minAssets) internal view returns (bytes memory) {
        return abi.encode(uint8(ExactlyTakerModule.Op.Withdraw), address(market), asset, MATURITY, minAssets, AMOUNT);
    }

    function _take(bytes memory data) internal {
        vm.prank(permit3);
        module.takeOnBehalf(maker, AMOUNT, receiver, data);
    }

    function test_preMaturity_zeroFloor_reverts() public {
        vm.warp(MATURITY - 1);
        bytes memory data = _data(0);
        assertFalse(module.takeFloored(0, address(0), 0, data), "lens flags it");
        vm.prank(permit3);
        vm.expectRevert(ExactlyTakerModule.ZeroMinAssets.selector);
        module.takeOnBehalf(maker, AMOUNT, receiver, data);
        assertEq(market.calls(), 0, "venue never reached");
    }

    function test_preMaturity_nonZeroFloor_passesThrough() public {
        vm.warp(MATURITY - 1);
        bytes memory data = _data(1);
        assertTrue(module.takeFloored(0, address(0), 0, data));
        _take(data);
        assertEq(market.calls(), 1);
        assertEq(market.lastMinAssets(), 1, "floor forwarded unscaled");
    }

    function test_atMaturity_zeroFloor_allowed() public {
        vm.warp(MATURITY);
        bytes memory data = _data(0);
        assertTrue(module.takeFloored(0, address(0), 0, data));
        _take(data);
        assertEq(market.calls(), 1);
    }

    function test_afterMaturity_zeroFloor_allowed() public {
        vm.warp(MATURITY + 30 days);
        bytes memory data = _data(0);
        assertTrue(module.takeFloored(0, address(0), 0, data));
        _take(data);
        assertEq(market.calls(), 1);
    }

    /// @dev The revert and the lens view are the same predicate, at every time and floor.
    function testFuzz_revertMatchesTakeFloored(uint32 offset, bool before, uint256 minAssets) public {
        minAssets = bound(minAssets, 0, 3);
        vm.warp(before ? MATURITY - 1 - (offset % 1_000_000) : MATURITY + (offset % 1_000_000));
        bytes memory data = _data(minAssets);
        bool floored = module.takeFloored(0, address(0), 0, data);
        vm.prank(permit3);
        (bool ok,) = address(module).call(abi.encodeCall(module.takeOnBehalf, (maker, AMOUNT, receiver, data)));
        assertEq(ok, floored, "revert <=> lens flag");
    }
}
