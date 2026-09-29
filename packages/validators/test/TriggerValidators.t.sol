// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Order, Validator, LegOut} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";
import {
    ChainlinkRead,
    ChainlinkPriceGte,
    ChainlinkPriceLte,
    ChainlinkTickFloorValidator
} from "@validators/ChainlinkPriceValidators.sol";
import {TimestampValidator} from "@validators/TimestampValidator.sol";
import {PredicateStaticCall} from "@validators/PredicateStaticCall.sol";

import {MockSettlementBase} from "@coretest/shared/MockSettlementBase.t.sol";

/// @dev Fully controllable Chainlink-shaped feed.
contract MockAggregator {
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId = 10;
    uint80 public answeredInRound = 10;

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function setRounds(uint80 roundId_, uint80 answeredInRound_) external {
        roundId = roundId_;
        answeredInRound = answeredInRound_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, 0, updatedAt, answeredInRound);
    }
}

/// @dev Boolean predicate target for {PredicateStaticCall}.
contract BoolBox {
    bool public flag;

    function set(bool v) external {
        flag = v;
    }

    function isSet() external view returns (bool) {
        return flag;
    }

    function boom() external pure returns (bool) {
        revert("boom");
    }
}

/// @title TriggerValidators
/// @notice First direct coverage for the trigger surface: the {ChainlinkRead}
///         hardening (staleness, incomplete rounds, non-positive answers — all
///         previously untested), {ChainlinkPriceGte} (never before instantiated),
///         {PredicateStaticCall} (zero prior tests), the new {TimestampValidator},
///         and the new {ChainlinkTickFloorValidator} market-limit — each both at
///         the unit level and THROUGH a fill (a reverting/false validator must
///         surface as `ValidationFailed`).
contract TriggerValidatorsTest is MockSettlementBase {
    MockAggregator feed;
    ChainlinkPriceGte gte;
    ChainlinkPriceLte lte;
    ChainlinkTickFloorValidator tickFloor;
    TimestampValidator timeGate;
    PredicateStaticCall predicate;
    BoolBox box;

    Order ordDummy; // storage scratch never used; orders built per test

    function setUp() public override {
        super.setUp();
        feed = new MockAggregator();
        gte = new ChainlinkPriceGte();
        lte = new ChainlinkPriceLte();
        tickFloor = new ChainlinkTickFloorValidator();
        timeGate = new TimestampValidator();
        predicate = new PredicateStaticCall();
        box = new BoolBox();
        vm.warp(1_700_000_000); // real-ish clock for staleness math
    }

    function _order(uint256 nonce) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), 1_000e18, 2e18);
    }

    function _withValidator(Order memory o, address target, bytes memory data) internal pure returns (Order memory) {
        Validator[] memory v = new Validator[](1);
        v[0] = Validator(target, data);
        o.validators = PackedEncode.validators(v);
        return o;
    }

    function _fund() internal {
        tA.mint(maker, 1_000e18);
        tB.mint(solver, 4e18);
        _makerApprove(address(settlement), address(tA), type(uint160).max);
        _solverApprove(address(settlement), address(tB), type(uint160).max);
    }

    // ──────────────────── ChainlinkRead hardening ────────────────────

    function test_read_staleness_reverts() public {
        feed.set(1500e8, block.timestamp - 2 hours);
        Order memory o = _withValidator(_order(1), address(gte), abi.encode(address(feed), int256(1000e8), 1 hours));
        vm.expectRevert(ChainlinkRead.StalePrice.selector);
        gte.validate(o, solver, PackedEncode.getValidatorData(o.validators, 0), "");
    }

    function test_read_zeroUpdatedAt_reverts() public {
        feed.set(1500e8, 0);
        Order memory o = _withValidator(_order(2), address(gte), abi.encode(address(feed), int256(1000e8), 1 hours));
        vm.expectRevert(ChainlinkRead.StalePrice.selector);
        gte.validate(o, solver, PackedEncode.getValidatorData(o.validators, 0), "");
    }

    function test_read_incompleteRound_reverts() public {
        feed.set(1500e8, block.timestamp);
        feed.setRounds(11, 10); // answeredInRound < roundId
        Order memory o = _withValidator(_order(3), address(gte), abi.encode(address(feed), int256(1000e8), 1 hours));
        vm.expectRevert(ChainlinkRead.IncompleteRound.selector);
        gte.validate(o, solver, PackedEncode.getValidatorData(o.validators, 0), "");
    }

    function test_read_nonPositivePrice_reverts() public {
        feed.set(0, block.timestamp);
        Order memory o = _withValidator(_order(4), address(gte), abi.encode(address(feed), int256(0), 1 hours));
        vm.expectRevert(ChainlinkRead.NonPositivePrice.selector);
        gte.validate(o, solver, PackedEncode.getValidatorData(o.validators, 0), "");
    }

    /// @dev A REVERTING validator (stale feed) surfaces as ValidationFailed on
    ///      the fill — the gate treats staticcall failure as false.
    function test_read_staleFeed_abortsFill() public {
        _fund();
        feed.set(1500e8, block.timestamp - 2 hours);
        Order memory o = _withValidator(_order(5), address(gte), abi.encode(address(feed), int256(1000e8), 1 hours));
        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.ValidationFailed.selector, 0));
        settlement.fill(o, sig, 1_000e18);
    }

    // ──────────────────── Gte / Lte thresholds ────────────────────

    function test_gte_takeProfit_gatesFill() public {
        _fund();
        Order memory o = _withValidator(_order(6), address(gte), abi.encode(address(feed), int256(2000e8), 1 hours));
        bytes memory sig = _sign(o);

        feed.set(1999e8, block.timestamp); // below the take-profit trigger
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.ValidationFailed.selector, 0));
        settlement.fill(o, sig, 1_000e18);

        feed.set(2000e8, block.timestamp); // trigger reached → fills
        vm.prank(solver);
        settlement.fill(o, sig, 1_000e18);
        assertEq(tB.balanceOf(maker), 2e18, "filled once the trigger hit");
    }

    function test_lte_stopLoss_unit() public {
        feed.set(1500e8, block.timestamp);
        Order memory o = _withValidator(_order(7), address(lte), abi.encode(address(feed), int256(1500e8), 1 hours));
        assertTrue(lte.validate(o, solver, PackedEncode.getValidatorData(o.validators, 0), ""), "at threshold passes");
        feed.set(1501e8, block.timestamp);
        assertFalse(
            lte.validate(o, solver, PackedEncode.getValidatorData(o.validators, 0), ""), "above threshold fails"
        );
    }

    // ──────────────────── PredicateStaticCall ────────────────────

    function test_predicate_trueFalseReverting() public {
        Order memory o = _order(8);
        bytes memory dTrue = abi.encode(address(box), abi.encodeCall(BoolBox.isSet, ()));
        box.set(true);
        assertTrue(predicate.validate(o, solver, dTrue, ""), "true predicate");
        box.set(false);
        assertFalse(predicate.validate(o, solver, dTrue, ""), "false predicate");
        // A REVERTING predicate is swallowed and reads as false — fail-closed.
        bytes memory dBoom = abi.encode(address(box), abi.encodeCall(BoolBox.boom, ()));
        assertFalse(predicate.validate(o, solver, dBoom, ""), "reverting predicate fails closed");
    }

    function test_predicate_gatesFill() public {
        _fund();
        Order memory o =
            _withValidator(_order(9), address(predicate), abi.encode(address(box), abi.encodeCall(BoolBox.isSet, ())));
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.ValidationFailed.selector, 0));
        settlement.fill(o, sig, 1_000e18);

        box.set(true);
        vm.prank(solver);
        settlement.fill(o, sig, 1_000e18);
    }

    // ──────────────────── TimestampValidator ────────────────────

    function test_timestamp_windowGate() public {
        Order memory o = _order(10);
        bytes memory d = abi.encode(block.timestamp + 100, block.timestamp + 200);
        assertFalse(timeGate.validate(o, solver, d, ""), "before window");
        vm.warp(block.timestamp + 150);
        assertTrue(timeGate.validate(o, solver, d, ""), "inside window");
        vm.warp(block.timestamp + 100);
        assertFalse(timeGate.validate(o, solver, d, ""), "after window");
    }

    function test_timestamp_unboundedEnd() public {
        Order memory o = _order(11);
        bytes memory d = abi.encode(block.timestamp, uint256(0));
        vm.warp(block.timestamp + 365 days);
        assertTrue(timeGate.validate(o, solver, d, ""), "notAfter=0 is unbounded");
    }

    // ──────────────────── ChainlinkTickFloor (TWAP market limit) ────────────────────

    /// @dev SELL 1000 tA → 2e18..1e18 tB decaying. Tick rate = out/in.
    ///      Feed reports tB-per-tA at 1e8 decimals; the maker folds decimals +
    ///      tolerance into the rational `num/den` = (10000−tol)/10000 · 10^(18−18−8),
    ///      i.e. `num = 10000 − tol`, `den = 10000 · 1e8`.
    function _decayingSell(uint256 nonce) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), 1_000e18, 2e18);
        o.legsOut = PackedEncode.setLegOutEnd(o.legsOut, 0, 1e18);
        _setDecayStart(o, block.timestamp);
        _setDecayDuration(o, 1000);
    }

    function test_tickFloor_passesWithinTolerance_failsWhenMarketRunsAway() public {
        // Mid-decay: out = 1.5e18 per 1000e18 in → rate 1.5e15 (1e18-scaled).
        Order memory o = _decayingSell(12);
        // 2% tolerance, decimals folded: num/den = 9800 / (10000 · 1e8)
        bytes memory d = abi.encode(address(feed), uint256(1 hours), uint256(9_800), uint256(10_000 * 1e8));
        vm.warp(block.timestamp + 500);

        feed.set(int256(0.0015e8), block.timestamp); // market == tick → within tolerance
        assertTrue(tickFloor.validate(o, solver, d, ""), "at-market passes");

        feed.set(int256(0.0016e8), block.timestamp); // market 6.7% above the signed tick
        assertFalse(tickFloor.validate(o, solver, d, ""), "runaway market blocks the fill");
    }

    function test_tickFloor_gatesFill_andReleasesAsDecayCatchesUp() public {
        _fund();
        Order memory o = _decayingSell(13);
        // zero tolerance: tick must be ≥ market exactly — num/den = 1 / 1e8
        o = _withValidator(o, address(tickFloor), abi.encode(address(feed), uint256(1 hours), uint256(1), uint256(1e8)));
        bytes memory sig = _sign(o);

        // Auction starts at 2e18 out (tick rate 2e15). Set the market ABOVE the
        // start rate so the gate blocks, then let it come back / the decay open it.
        feed.set(int256(0.0025e8), block.timestamp); // market rate 2.5e15 > start tick 2e15
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.ValidationFailed.selector, 0));
        settlement.fill(o, sig, 1_000e18);

        feed.set(int256(0.0015e8), block.timestamp); // market falls to 1.5e15
        vm.warp(block.timestamp + 250); // tick decayed to 1.75e15 ≥ market → opens
        vm.prank(solver);
        settlement.fill(o, sig, 1_000e18);
        assertEq(tA.balanceOf(solver), 1_000e18, "filled once tick >= market");
    }

    function test_tickFloor_staleFeed_abortsFill() public {
        _fund();
        Order memory o = _decayingSell(14);
        o = _withValidator(o, address(tickFloor), abi.encode(address(feed), uint256(1 hours), uint256(1), uint256(1e8)));
        bytes memory sig = _sign(o);
        feed.set(int256(0.001e8), block.timestamp - 2 hours);
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.ValidationFailed.selector, 0));
        settlement.fill(o, sig, 1_000e18);
    }

    /// @dev F29 finding 1 — the shape that broke the 1e18 `scale`: an 18-decimal
    ///      input, a 6-decimal output and an 8-decimal feed (WETH → USDC against
    ///      ETH/USD). The exponent is −20, so the old scale was 0.0098 → 0 and the
    ///      gate passed at ANY price. With the rational form it blocks a runaway
    ///      market and passes at market.
    function test_tickFloor_18in6out8feed_blocksRunawayMarket() public {
        // sell 1e18 (18-dec) for 2500e6 (6-dec), fixed; market 4000 USD/ETH at 1e8.
        Order memory o = _plainOrder(15, address(tA), address(tB), 1e18, 2_500e6);
        // 2% tolerance: num/den = 9800 / (10000 · 1e20)
        bytes memory d = abi.encode(address(feed), uint256(1 hours), uint256(9_800), uint256(10_000) * 1e20);

        feed.set(int256(4_000e8), block.timestamp);
        assertFalse(tickFloor.validate(o, solver, d, ""), "2500 < 4000 * 0.98: blocked");
        feed.set(int256(1_000_000e8), block.timestamp);
        assertFalse(tickFloor.validate(o, solver, d, ""), "runaway market: blocked");
        feed.set(int256(2_500e8), block.timestamp);
        assertTrue(tickFloor.validate(o, solver, d, ""), "at market: passes");
        feed.set(int256(2_550e8), block.timestamp);
        assertTrue(tickFloor.validate(o, solver, d, ""), "within 2% of market: passes");
    }

    /// Re-audit 2026-09-29: an empty leg blob is refused rather than read — the tick
    /// accessors are unchecked, so an empty `legsOut` read neighbouring signed bytes.
    function test_tickFloor_emptyLeg_reverts() public {
        Order memory o = _order(41);
        bytes memory d = abi.encode(address(feed), uint256(1 hours), uint256(1), uint256(1e8));
        o.legsOut = hex"00"; // well-formed EMPTY blob: count 0
        vm.expectRevert(ChainlinkTickFloorValidator.EmptyLeg.selector);
        tickFloor.validate(o, solver, d, "");
        o = _order(42);
        o.legsIn = hex"00";
        vm.expectRevert(ChainlinkTickFloorValidator.EmptyLeg.selector);
        tickFloor.validate(o, solver, d, "");
    }

    /// @dev A zero on either side is not a market limit: refused, which
    ///      {OrderGates.gatePasses} folds to a failed fill.
    function test_tickFloor_zeroRatio_reverts() public {
        Order memory o = _plainOrder(16, address(tA), address(tB), 1e18, 2_500e6);
        feed.set(int256(2_500e8), block.timestamp);
        vm.expectRevert(ChainlinkTickFloorValidator.ZeroRatio.selector);
        tickFloor.validate(o, solver, abi.encode(address(feed), uint256(1 hours), uint256(0), uint256(1e8)), "");
        vm.expectRevert(ChainlinkTickFloorValidator.ZeroRatio.selector);
        tickFloor.validate(o, solver, abi.encode(address(feed), uint256(1 hours), uint256(1), uint256(0)), "");
        // The pre-F29 three-word blob decodes short: fails closed, never passes.
        vm.expectRevert();
        tickFloor.validate(o, solver, abi.encode(address(feed), uint256(1 hours), uint256(0)), "");
    }
}
