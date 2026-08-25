// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order} from "@core/settlement/Settlement.sol";
import {Proportional} from "@core/settlement/Proportional.sol";
import {ChainlinkPeggedPriceModule} from "../src/ChainlinkPeggedPriceModule.sol";

import {MockSettlementBase} from "@coretest/shared/MockSettlementBase.t.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

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

/// @title ProportionalPeggedPrice
/// @notice A {Proportional} anchor priced by {ChainlinkPeggedPriceModule} — "sell
///         100% of my stETH at the Chainlink rate", the natural combination of the
///         two features and the one that used to be unfillable.
///
///  ⚠ REGRESSION. `_band` re-read `legsIn[0].start` out of the packed blob for its
///  anchor. On a proportional order that word is a MARKER (≈1.15e77), not an amount,
///  so `anchor · answer` overflowed for every feed answer ≥ 2, the module's
///  `staticcall` panicked, and {DutchAuction.priceBump} — which has no fallback —
///  reverted `PriceModuleFailed`. The order was signable, passed
///  `SettlementLens.validateOrder`, and could never be filled by anyone: a preflight
///  that is LOOSER than the settler, the drift class `docs/reference-audits.md` §C13
///  records this codebase having been bitten by before.
///
///  The fix uses the `total` the core already passes — the denominator resolved
///  against the maker's live balance BEFORE any funds move — so preview and fill
///  agree by construction rather than by two implementations happening to match.
contract ProportionalPeggedPriceTest is MockSettlementBase {
    uint256 constant CAP = 1_000e18; //      the maker's mandatory absolute cap
    uint256 constant OUT_START = 2_000e18; // best-for-maker output
    uint256 constant OUT_END = 1_000e18; //   the maker's floor

    function _mod() internal returns (ChainlinkPeggedPriceModule) {
        PriceFeed feed = new PriceFeed();
        feed.set(1.5e18, block.timestamp); // 1 tA = 1.5 tB
        return new ChainlinkPeggedPriceModule(address(feed), 1 hours, 0.5e18, 3e18, 1, 1e18, true, 0);
    }

    /// @dev A proportional SELL: sweep 100% of the maker's tA, capped at `CAP`,
    ///      against an oracle-pegged output band.
    function _sweepOrder(uint256 nonce, address mod) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), CAP, OUT_START);
        o.legsOut = PackedEncode.oneLegOut(address(tB), OUT_START, OUT_END, address(0));
        o.legsIn = PackedEncode.setLegInStart(o.legsIn, 0, Proportional.encode(10_000)); // 100%
        o.legsIn = PackedEncode.setLegInEnd(o.legsIn, 0, CAP); //                          the cap
        o.pricingModule = mod;
    }

    function _fundMaker(uint256 balance) internal {
        tA.mint(maker, balance);
        _makerApprove(address(settlement), address(tA), balance);
    }

    function _fundSolver() internal {
        tB.mint(solver, OUT_START);
        _solverApprove(address(settlement), address(tB), OUT_START);
    }

    // ──────────────── it fills, and against the RESOLVED balance ────────────────

    /// The number here can only come from the resolved balance. With 800 tA held:
    /// `fair = 800 · 1.5 = 1,200`, so `bump = (2000−1200)·10000/1000 = 8,000 bps`,
    /// and the output tick is `2000 − 1000·0.8 = 1,200 tB`. Reading the raw marker
    /// instead could not produce this — it could only overflow.
    function test_proportional_pricesAgainstResolvedBalance() public {
        ChainlinkPeggedPriceModule mod = _mod();
        _fundMaker(800e18);
        _fundSolver();

        Order memory o = _sweepOrder(1, address(mod));
        bytes memory sig = _sign(o);

        vm.prank(solver);
        settlement.fillUpTo(o, sig, type(uint128).max, solver, 0, "");

        assertEq(tA.balanceOf(maker), 0, "the whole balance was swept");
        assertEq(tB.balanceOf(maker), 1_200e18, "priced at the oracle rate on the RESOLVED anchor");
        assertEq(tA.balanceOf(solver), 800e18, "solver received the sweep");
    }

    /// The cap still binds, and it is the cap — not the balance — that anchors the
    /// price once it does. 1,200 held, cap 1,000: `fair = 1,000 · 1.5 = 1,500`,
    /// `bump = 5,000 bps`, output `1,500 tB`, and 200 tA stay with the maker.
    function test_proportional_capBindsAndAnchorsThePrice() public {
        ChainlinkPeggedPriceModule mod = _mod();
        _fundMaker(1_200e18);
        _fundSolver();

        Order memory o = _sweepOrder(2, address(mod));
        bytes memory sig = _sign(o);

        vm.prank(solver);
        settlement.fillUpTo(o, sig, type(uint128).max, solver, 0, "");

        assertEq(tA.balanceOf(maker), 200e18, "sold exactly the cap, kept the rest");
        assertEq(tB.balanceOf(maker), 1_500e18, "priced on the capped anchor");
    }

    // ──────────────── preflight now agrees with the settler ────────────────

    /// `validateOrder` said this order was fine all along. Now it is.
    function test_lensValidateOrder_andFill_agree() public {
        ChainlinkPeggedPriceModule mod = _mod();
        _fundMaker(800e18);
        _fundSolver();

        Order memory o = _sweepOrder(3, address(mod));
        (bool ok, string memory reason) = lens.validateOrder(o);
        assertTrue(ok, reason);

        // And the quote the lens gives is the price the fill executes at.
        uint256 previewed = lens.previewBump(o, solver, "");
        bytes memory sig = _sign(o);
        vm.prank(solver);
        settlement.fillUpTo(o, sig, type(uint128).max, solver, previewed, ""); // minBumpBps floor

        assertEq(previewed, 8_000, "lens quotes the resolved-anchor bump");
        assertEq(tB.balanceOf(maker), 1_200e18, "and the fill honours it");
    }

    /// The direct module call that used to panic on the marker.
    function test_moduleCall_withProportionalMarker_doesNotPanic() public {
        ChainlinkPeggedPriceModule mod = _mod();
        bytes memory legsIn = PackedEncode.oneLegIn(address(tA), Proportional.encode(10_000), CAP);
        bytes memory legsOut = PackedEncode.oneLegOut(address(tB), OUT_START, OUT_END, address(0));

        // `total` is the resolved anchor the core would pass — 800e18 here.
        uint256 bps = mod.bump(bytes32(0), maker, solver, 0, 800e18, 0, legsIn, legsOut, "");
        assertEq(bps, 8_000, "prices off `total`, never the raw leg word");
    }

    // ──────────────── the ordinary case is unchanged ────────────────

    /// An absolute-amount order prices exactly as it did before the change — `total`
    /// and `legsIn[0].start` are the same number there.
    function test_absoluteAnchor_unchanged() public {
        ChainlinkPeggedPriceModule mod = _mod();
        _fundMaker(CAP);
        _fundSolver();

        Order memory o = _plainOrder(4, address(tA), address(tB), CAP, OUT_START);
        o.legsOut = PackedEncode.oneLegOut(address(tB), OUT_START, OUT_END, address(0));
        o.pricingModule = address(mod);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        settlement.fill(o, sig, CAP);

        assertEq(tB.balanceOf(maker), 1_500e18, "1,000 x 1.5, midway in the band");
    }
}
