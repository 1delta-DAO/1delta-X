// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DutchAuction} from "@core/settlement/DutchAuction.sol";
import {Order} from "@core/settlement/Settlement.sol";
import {ChainlinkPeggedPriceModule} from "../src/ChainlinkPeggedPriceModule.sol";

import {MockSettlementBase} from "@coretest/shared/MockSettlementBase.t.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

/// @dev Fully controllable Chainlink-shaped feed (mirrors the one in core's
///      TriggerValidators.t.sol; duplicated so the two suites stay independent).
contract PriceFeed {
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId = 10;
    uint80 public answeredInRound = 10;

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, 0, updatedAt, answeredInRound);
    }
}

/// @title ChainlinkPeggedPrice
/// @notice {ChainlinkPeggedPriceModule} end to end through a real fill: the peg
///         itself, the two rejections it exists for (stale feed, fresh-but-
///         implausible answer), the core CLAMP that keeps its answer inside the
///         maker's signed band, and lens/fill price parity.
///
///  Lived in core's `PricingModes.t.sol` until the pricing modules moved out to
///  `packages/modules/pricing`; the block-clock and priority-auction cases stayed
///  behind, since those are core pricing rather than a module.
contract ChainlinkPeggedPriceTest is MockSettlementBase {
    uint256 constant SELL_IN = 1_000e18; //   the maker's fixed input (anchor)
    uint256 constant OUT_START = 2_000e18; // best-for-maker output
    uint256 constant OUT_END = 1_000e18; //   the maker's floor

    function _fund(uint256 outAmount) internal {
        tA.mint(maker, SELL_IN);
        _makerApprove(address(settlement), address(tA), SELL_IN);
        tB.mint(solver, outAmount);
        _solverApprove(address(settlement), address(tB), outAmount);
    }

    /// @dev A decaying SELL: fixed input, output falling OUT_START → OUT_END.
    function _decayingSell(uint256 nonce) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), SELL_IN, OUT_START);
        o.legsOut = PackedEncode.oneLegOut(address(tB), OUT_START, OUT_END, address(0));
    }

    function test_oracleModule_pegsInsideBand() public {
        _fund(OUT_START);
        PriceFeed feed = new PriceFeed();
        feed.set(1.5e18, block.timestamp); // 1 tA = 1.5 tB
        // fair = anchor · answer / 1e18, no spread, pricing the OUTPUT band.
        ChainlinkPeggedPriceModule mod =
            new ChainlinkPeggedPriceModule(address(feed), 1 hours, 0.5e18, 3e18, 1, 1e18, true, 0);

        Order memory o = _decayingSell(8);
        o.pricingModule = address(mod);
        bytes memory sig = _sign(o);

        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN);
        // 1_000e18 · 1.5 = 1_500e18, which sits exactly midway in [1_000e18, 2_000e18].
        assertEq(tB.balanceOf(maker) - before_, 1_500e18, "cleared at the oracle rate");
    }

    /// @dev A fresh feed reporting an implausible price is REJECTED, not priced
    ///      against — the freshness-but-not-plausibility gap this module closes.
    function test_oracleModule_implausiblePrice_reverts() public {
        _fund(OUT_START);
        PriceFeed feed = new PriceFeed();
        feed.set(50e18, block.timestamp); // fresh, and far outside the sanity band
        ChainlinkPeggedPriceModule mod =
            new ChainlinkPeggedPriceModule(address(feed), 1 hours, 0.5e18, 3e18, 1, 1e18, true, 0);

        Order memory o = _decayingSell(9);
        o.pricingModule = address(mod);
        bytes memory sig = _sign(o);
        // The module's own revert is not bubbled: the core reads a bool + one word
        // from the staticcall and nothing else, so an unreadable price surfaces as
        // {DutchAuction.PriceModuleFailed}. A solver simulating the module directly
        // still sees {ChainlinkPeggedPriceModule.ImplausiblePrice}.
        vm.prank(solver);
        vm.expectRevert(DutchAuction.PriceModuleFailed.selector);
        settlement.fill(o, sig, SELL_IN);
    }

    function test_oracleModule_staleFeed_reverts() public {
        _fund(OUT_START);
        PriceFeed feed = new PriceFeed();
        vm.warp(block.timestamp + 10 hours);
        feed.set(1.5e18, block.timestamp - 2 hours);
        ChainlinkPeggedPriceModule mod =
            new ChainlinkPeggedPriceModule(address(feed), 1 hours, 0.5e18, 3e18, 1, 1e18, true, 0);

        Order memory o = _decayingSell(10);
        _setExpiry(o, block.timestamp + 1 hours);
        o.pricingModule = address(mod);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert(DutchAuction.PriceModuleFailed.selector); // see the note above
        settlement.fill(o, sig, SELL_IN);
    }

    /// @dev An oracle far ABOVE the maker's ambition cannot pay more than the band's
    ///      `start`: the module's answer is clamped, not obeyed.
    function test_oracleModule_cannotPriceOutsideBand() public {
        _fund(OUT_START);
        PriceFeed feed = new PriceFeed();
        feed.set(2.9e18, block.timestamp); // fair = 2_900e18 > start = 2_000e18
        ChainlinkPeggedPriceModule mod =
            new ChainlinkPeggedPriceModule(address(feed), 1 hours, 0.5e18, 3e18, 1, 1e18, true, 0);

        Order memory o = _decayingSell(11);
        o.pricingModule = address(mod);
        bytes memory sig = _sign(o);
        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN);
        assertEq(tB.balanceOf(maker) - before_, OUT_START, "clamped to the signed ambition");
    }

    /// @dev The lens must quote a module order exactly as the fill prices it —
    ///      otherwise a book publishes prices no fill can honour.
    function test_previewFill_matchesModulePricedFill() public {
        _fund(OUT_START);
        PriceFeed feed = new PriceFeed();
        feed.set(1.25e18, block.timestamp);
        ChainlinkPeggedPriceModule mod =
            new ChainlinkPeggedPriceModule(address(feed), 1 hours, 0.5e18, 3e18, 1, 1e18, true, 0);
        Order memory o = _decayingSell(15);
        o.pricingModule = address(mod);
        bytes memory sig = _sign(o);

        (,, uint256[] memory paid) = lens.previewFill(o, SELL_IN, solver, "");
        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN);
        assertEq(paid[0], tB.balanceOf(maker) - before_, "preview equals execution");
    }
}
