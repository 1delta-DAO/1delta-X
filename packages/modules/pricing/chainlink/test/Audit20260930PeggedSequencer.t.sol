// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {ChainlinkRead} from "@validators/ChainlinkPriceValidators.sol";
import {ChainlinkPeggedPriceModule} from "../src/ChainlinkPeggedPriceModule.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {LegIn, LegOut} from "@core/settlement/Structs.sol";

/// @dev Chainlink-shaped feed: price feed or sequencer-uptime feed.
contract SeqFeed20260930 {
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;

    function set(int256 a, uint256 s, uint256 u) external {
        (answer, startedAt, updatedAt) = (a, s, u);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (10, answer, startedAt, updatedAt, 10);
    }
}

/// @title Audit 2026-09-30 PRICE-8 — ChainlinkPeggedPriceModule checks the L2 sequencer
/// @notice With a sequencer-uptime feed configured, a down sequencer or one still
///         inside its grace period reverts the bump instead of pricing off the
///         last (stale-but-fresh-looking) answer. `address(0)` keeps the L1 shape.
contract Audit20260930PeggedSequencerTest is Test {
    SeqFeed20260930 price;
    SeqFeed20260930 uptime;
    ChainlinkPeggedPriceModule mod;
    bytes legsIn;
    bytes legsOut;

    function setUp() public {
        vm.warp(1_000_000);
        price = new SeqFeed20260930();
        uptime = new SeqFeed20260930();
        price.set(1.5e18, 0, block.timestamp);
        mod = new ChainlinkPeggedPriceModule(
            address(price), 1 hours, 0.5e18, 3e18, 1, 1e18, true, 0, address(uptime), 3600
        );
        legsIn = PackedEncode.oneLegIn(address(0xA), 1_000e18, 0);
        LegOut[] memory outs = new LegOut[](1);
        outs[0] = LegOut({token: address(0xB), start: 2_000e18, end: 1_000e18, recipient: address(0)});
        legsOut = PackedEncode.legsOut(outs);
    }

    function _bump() internal view returns (uint256) {
        return mod.bump(bytes32(0), address(0), address(0), 0, 1_000e18, 0, legsIn, legsOut, "");
    }

    function test_audit_PRICE_8_sequencerDownReverts() public {
        uptime.set(1, block.timestamp - 10 hours, block.timestamp); // 1 = down
        vm.expectRevert(ChainlinkRead.SequencerDown.selector);
        _bump();
    }

    function test_audit_PRICE_8_withinGracePeriodReverts() public {
        uptime.set(0, block.timestamp - 10 minutes, block.timestamp); // up, but just restarted
        vm.expectRevert(ChainlinkRead.GracePeriodNotOver.selector);
        _bump();
    }

    function test_audit_PRICE_8_upPastGracePrices() public {
        uptime.set(0, block.timestamp - 2 hours, block.timestamp);
        assertEq(_bump(), 5_000, "1.5 peg on a 2.0 -> 1.0 band prices at mid");
    }

    function test_audit_PRICE_8_noUptimeFeedIsTheL1Shape() public {
        ChainlinkPeggedPriceModule l1 =
            new ChainlinkPeggedPriceModule(address(price), 1 hours, 0.5e18, 3e18, 1, 1e18, true, 0, address(0), 0);
        uptime.set(1, 0, 0); // irrelevant: not configured
        assertEq(l1.bump(bytes32(0), address(0), address(0), 0, 1_000e18, 0, legsIn, legsOut, ""), 5_000);
    }
}
