// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "../shared/PackedEncode.sol";

import {Order, Validator, LegOut} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";
import {
    ChainlinkRead,
    ChainlinkPriceGte,
    ChainlinkPriceLte,
    ChainlinkTickFloorValidator
} from "@core/validators/ChainlinkPriceValidators.sol";
import {TimestampValidator} from "@core/validators/TimestampValidator.sol";
import {PredicateStaticCall} from "@core/validators/PredicateStaticCall.sol";

import {MockSettlementBase} from "../shared/MockSettlementBase.t.sol";

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

    /// @dev SELL 1000 tA → 2e18..1e18 tB decaying. Tick rate = out/in (1e18).
    ///      Feed reports tB-per-tA at 1e8 decimals; the maker folds decimals +
    ///      tolerance into `scale` = 1e18·(1−tol)·10^(18−18−8) = (1e10·(10000−tol))/10000.
    function _decayingSell(uint256 nonce) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), 1_000e18, 2e18);
        o.legsOut = PackedEncode.setLegOutEnd(o.legsOut, 0, 1e18);
        _setDecayStart(o, block.timestamp);
        _setDecayDuration(o, 1000);
    }

    function test_tickFloor_passesWithinTolerance_failsWhenMarketRunsAway() public {
        // Mid-decay: out = 1.5e18 per 1000e18 in → rate 1.5e15 (1e18-scaled).
        Order memory o = _decayingSell(12);
        uint256 tolScale = (1e10 * (10_000 - 200)) / 10_000; // 2% tolerance, decimals folded
        bytes memory d = abi.encode(address(feed), uint256(1 hours), tolScale);
        vm.warp(block.timestamp + 500);

        feed.set(int256(0.0015e8), block.timestamp); // market == tick → within tolerance
        assertTrue(tickFloor.validate(o, solver, d, ""), "at-market passes");

        feed.set(int256(0.0016e8), block.timestamp); // market 6.7% above the signed tick
        assertFalse(tickFloor.validate(o, solver, d, ""), "runaway market blocks the fill");
    }

    function test_tickFloor_gatesFill_andReleasesAsDecayCatchesUp() public {
        _fund();
        Order memory o = _decayingSell(13);
        uint256 tolScale = 1e10; // zero tolerance: tick must be ≥ market exactly
        o = _withValidator(o, address(tickFloor), abi.encode(address(feed), uint256(1 hours), tolScale));
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
        o = _withValidator(o, address(tickFloor), abi.encode(address(feed), uint256(1 hours), uint256(1e10)));
        bytes memory sig = _sign(o);
        feed.set(int256(0.001e8), block.timestamp - 2 hours);
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.ValidationFailed.selector, 0));
        settlement.fill(o, sig, 1_000e18);
    }
}
