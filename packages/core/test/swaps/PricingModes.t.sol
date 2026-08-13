// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Settlement, Order, OrderSide} from "@core/settlement/Settlement.sol";
import {DutchAuction} from "@core/settlement/DutchAuction.sol";
import {ChainlinkPeggedPriceModule} from "@core/modules/ChainlinkPeggedPriceModule.sol";
import {CosignedQuotePriceModule} from "@core/modules/CosignedQuotePriceModule.sol";
import {RangePriceModule} from "@core/modules/RangePriceModule.sol";

import {MockSettlementBase} from "../shared/MockSettlementBase.t.sol";
import {PackedEncode} from "../shared/PackedEncode.sol";

/// @dev Fully controllable Chainlink-shaped feed (mirrors the one in
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

/// @title PricingModes
/// @notice The 2026-08 pricing additions, end to end through a real fill:
///           • the BLOCK clock (`timing` bit 102) — decay measured in blocks;
///           • the PRIORITY auction (bit 103) — the bump is bid in priority fee;
///           • external {IPriceModule} pricing — oracle-pegged, range, cosigned;
///           • the CLAMP that keeps every one of them inside the maker's band.
contract PricingModesTest is MockSettlementBase {
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

    // ════════════════════ block clock (timing bit 102) ════════════════════

    function test_blockClock_decaysPerBlock() public {
        _fund(OUT_START);
        Order memory o = _decayingSell(1);
        // 10-BLOCK decay window starting at the current block, on the block clock.
        o.timing = uint256(uint32(block.number)) | (uint256(10) << 32) | (uint256(1) << 102);
        bytes memory sig = _sign(o);

        // Half the window — in BLOCKS, with the timestamp deliberately untouched, so
        // a timestamp-clock reading would report no decay at all.
        vm.roll(block.number + 5);
        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN);
        assertEq(tB.balanceOf(maker) - before_, (OUT_START + OUT_END) / 2, "midpoint of the block window");
    }

    function test_blockClock_beforeStartBlock_reverts() public {
        _fund(OUT_START);
        Order memory o = _decayingSell(2);
        o.timing = uint256(uint32(block.number + 50)) | (uint256(10) << 32) | (uint256(1) << 102);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert(DutchAuction.AuctionNotStarted.selector);
        settlement.fill(o, sig, SELL_IN);
    }

    // ════════════════════ priority auction (timing bit 103) ════════════════════

    /// @dev The floor is what a zero-bid fill clears at — the guarantee the maker
    ///      signed, identical to any other order's `end`.
    function test_priorityAuction_noBid_clearsAtFloor() public {
        _fund(OUT_START);
        Order memory o = _decayingSell(3);
        o.timing = uint256(1) << 103;
        o.params = DutchAuction.packParams(0, 0, 0, 1 gwei);
        bytes memory sig = _sign(o);

        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei); // no priority fee above basefee
        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN);
        assertEq(tB.balanceOf(maker) - before_, OUT_END, "unbid fill clears at the floor");
    }

    function test_priorityAuction_bidMovesTickTowardStart() public {
        _fund(OUT_START);
        Order memory o = _decayingSell(4);
        o.timing = uint256(1) << 103;
        o.params = DutchAuction.packParams(0, 0, 0, 2 gwei); // 2 gwei buys a FULL bump
        bytes memory sig = _sign(o);

        vm.fee(1 gwei);
        vm.txGasPrice(2 gwei); // 1 gwei of priority = half of the scale
        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN);
        assertEq(tB.balanceOf(maker) - before_, (OUT_START + OUT_END) / 2, "half-bid lands mid-band");
    }

    /// @dev Overbidding is capped by the maker's own `start` — the band is absolute.
    function test_priorityAuction_overbid_capsAtStart() public {
        _fund(OUT_START);
        Order memory o = _decayingSell(5);
        o.timing = uint256(1) << 103;
        o.params = DutchAuction.packParams(0, 0, 0, 1 gwei);
        bytes memory sig = _sign(o);

        vm.fee(1 gwei);
        vm.txGasPrice(100 gwei);
        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN);
        assertEq(tB.balanceOf(maker) - before_, OUT_START, "capped at the signed ambition");
    }

    function test_priorityAuction_withoutScale_reverts() public {
        _fund(OUT_START);
        Order memory o = _decayingSell(6);
        o.timing = uint256(1) << 103; // no priorityScale in `params`
        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert(DutchAuction.InvalidAuctionParams.selector);
        settlement.fill(o, sig, SELL_IN);
    }

    // ════════════════════ external price modules ════════════════════

    function test_rangeModule_pricesOnFillProgress() public {
        _fund(OUT_START * 2);
        // 0 bps at 0% filled (the maker's ambition) → 10000 bps at 100% (its floor).
        RangePriceModule mod = new RangePriceModule(0, 10_000);
        Order memory o = _decayingSell(7);
        o.pricingModule = address(mod);
        bytes memory sig = _sign(o);

        // First half: priced at progress 0 ⇒ the full `start` rate.
        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN / 2);
        assertEq(tB.balanceOf(maker) - before_, OUT_START / 2, "first slice at the start rate");

        // Second half: progress is now 50% ⇒ the midpoint rate.
        before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN / 2);
        assertEq(tB.balanceOf(maker) - before_, ((OUT_START + OUT_END) / 2) / 2, "second slice at the midpoint");
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
        o.deadline = block.timestamp + 1 hours;
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

    function test_cosignedQuote_improvesWithinBand() public {
        _fund(OUT_START);
        uint256 cosignerPk = 0xC05161;
        CosignedQuotePriceModule mod = new CosignedQuotePriceModule(vm.addr(cosignerPk), 10_000);

        Order memory o = _decayingSell(12);
        o.pricingModule = address(mod);
        bytes memory sig = _sign(o);
        bytes32 orderHash = lens.hashOrder(o);

        // The cosigner quotes a 2500 bps bump — a quarter of the way down from the
        // maker's ambition, i.e. an improvement on the unquoted floor.
        uint256 deadline = block.timestamp + 5 minutes;
        bytes32 digest = mod.quoteDigest(orderHash, solver, 2_500, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(cosignerPk, digest);
        bytes memory takerData = abi.encodePacked(solver, uint256(2_500), deadline, r, s, v);

        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN, takerData);
        assertEq(tB.balanceOf(maker) - before_, OUT_START - (OUT_START - OUT_END) / 4, "quoted tick");
    }

    /// @dev No quote ⇒ the configured fallback (here: the maker's floor). The order
    ///      stays fillable without the cosigner — the cosigner is an improver, never
    ///      a gatekeeper.
    function test_cosignedQuote_absentQuote_fallsBackToFloor() public {
        _fund(OUT_START);
        CosignedQuotePriceModule mod = new CosignedQuotePriceModule(address(0xC0), 10_000);
        Order memory o = _decayingSell(13);
        o.pricingModule = address(mod);
        bytes memory sig = _sign(o);

        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN);
        assertEq(tB.balanceOf(maker) - before_, OUT_END, "unquoted fills clear at the floor");
    }

    function test_cosignedQuote_forgedQuote_reverts() public {
        _fund(OUT_START);
        uint256 cosignerPk = 0xC05161;
        uint256 attackerPk = 0xBAD;
        CosignedQuotePriceModule mod = new CosignedQuotePriceModule(vm.addr(cosignerPk), 10_000);

        Order memory o = _decayingSell(14);
        o.pricingModule = address(mod);
        bytes memory sig = _sign(o);
        uint256 deadline = block.timestamp + 5 minutes;
        bytes32 digest = mod.quoteDigest(lens.hashOrder(o), solver, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attackerPk, digest);
        bytes memory takerData = abi.encodePacked(solver, uint256(0), deadline, r, s, v);

        vm.prank(solver);
        vm.expectRevert();
        settlement.fill(o, sig, SELL_IN, takerData);
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
