// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IFillModule} from "@core/interfaces/IFillModule.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {ITakerForModule} from "@core/interfaces/ITakerForModule.sol";
import {Order, Item, ItemOp, LegIn, LegOut} from "@core/settlement/Settlement.sol";

import {PackedEncode} from "../shared/PackedEncode.sol";
import {MockSettlementBase, MockERC20} from "../shared/MockSettlementBase.t.sol";
import {FixedBumpModule} from "../shared/MockModules.sol";

// ════════════════════════════ suite-local mocks ════════════════════════════

/// @dev Fill module whose denominator is the signed `fillTotal` and which CLAMPS the
///      filler's proposal to what is left — so a proposal and the resolved delta can
///      differ, which is exactly what the `filled[]` binding property has to survive.
contract ClampFillModule is IFillModule {
    function resolveFill(Order calldata order, uint256 prevFilled, uint256 fillAmount, bytes calldata)
        external
        pure
        returns (uint256)
    {
        uint256 rem = order.fillTotal - prevFilled;
        return fillAmount < rem ? fillAmount : rem;
    }
}

/// @dev PRE-FUNDED MAKE: the referenced output leg is delivered HERE; the module
///      spends from its own balance and records the core-sized amount. The balance
///      check is the floor a real one carries — it fails unless the delivery landed.
contract SeqPreFundMake is IMakerModule {
    address public immutable settlement;
    uint256 public total;

    constructor(address _settlement) {
        settlement = _settlement;
    }

    function makeOnBehalf(address, uint256 amount, bytes calldata data) external override {
        require(msg.sender == settlement, "only settlement");
        (, address token) = abi.decode(data, (uint256, address));
        require(IERC20(token).balanceOf(address(this)) >= total + amount, "unfunded");
        total += amount;
    }
}

/// @dev Ordinary PULL MAKE: draws exactly the core's slice out of the maker's wallet.
contract SeqPullMake is IMakerModule {
    IPermit3 public immutable permit3;
    address public immutable settlement;
    uint256 public total;

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        require(msg.sender == settlement, "only settlement");
        address token = abi.decode(data, (address));
        permit3.transferFrom(onBehalfOf, address(this), token, uint160(amount));
        total += amount;
    }
}

/// @dev Plain TAKE: hands exactly the core's slice of `token` (from a stash) to the
///      receiver, so the item's slices are observable as a real balance.
contract SeqTaker is ITakerModule {
    address public immutable permit3;
    uint256 public total;

    constructor(address _permit3) {
        permit3 = _permit3;
    }

    function takeOnBehalf(address, uint256 amount, address receiver, bytes calldata data) external override {
        require(msg.sender == permit3, "only permit3");
        address token = abi.decode(data, (address));
        IERC20(token).transfer(receiver, amount);
        total += amount;
    }
}

/// @dev TAKE_FOR in either funding shape. `data = (desc, fundToken, proceedsToken,
///      pull)`: `pull` draws `forAmount` from the maker's wallet (literal form);
///      otherwise it spends a delivery that must already sit here (pre-fund form).
///      Hands exactly `amount` of `proceedsToken` to the receiver.
contract SeqTakeFor is ITakerForModule {
    IPermit3 public immutable permit3;
    uint256 public totalAmount;
    uint256 public totalFor;

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeForOnBehalf(
        address,
        address onBehalfOf,
        uint256 amount,
        uint256 forAmount,
        address receiver,
        bytes calldata data
    ) external override {
        require(msg.sender == address(permit3), "only permit3");
        (, address fundToken, address proceedsToken, bool pull) = abi.decode(data, (uint256, address, address, bool));
        if (pull) {
            permit3.transferFrom(onBehalfOf, address(this), fundToken, uint160(forAmount));
        } else {
            require(IERC20(fundToken).balanceOf(address(this)) >= totalFor + forAmount, "unfunded");
        }
        IERC20(proceedsToken).transfer(receiver, amount);
        totalAmount += amount;
        totalFor += forAmount;
    }
}

/// @title RoundingSequence
/// @notice SEQUENCE-level rounding properties of the core settlement: what holds after
///         EVERY PREFIX of an arbitrary, fuzzed, UNEVEN partition of an order — not just
///         at the end, and not just for equal slices.
///
///  Provenance. Balancer v2 (Nov 2025) and the v3 rounding review share one lesson:
///  asymmetric rounding between the two directions of ONE conversion is harmless per
///  call and fatal under batching, because an adversary picks the slice sizes. Certora's
///  post-mortem named the two properties whose absence let it through: ROUND-TRIP
///  INVARIANCE (slice sums reconstruct the signed totals) and SHARE-VALUE MONOTONICITY
///  (every prefix is at least as good for the victim as its exact pro-rata value).
///  {RoundingDirection} pins the direction on a one-leg order sliced evenly; this file
///  pins the SEQUENCE property across the shapes that exercise different branches of
///  {Pricing} and {Base._prorate}:
///
///    • P1 PREFIX MONOTONICITY — after prefix m with running fill F (denominator A):
///        SELL output leg j   Σout_j ≥ ceil(tick_j·F/A)          (per-slice ceil)
///                            ×(1+ov) on the maker's own legs under soft exclusivity
///        BUY  output leg j   Σout_j == ceil(start_j·F/A)        (cumulative ceil)
///        fixed SELL input i  Σin_i  == floor(start_i·F/A)       (cumulative floor)
///        auctioned input i   Σin_i  ≤ floor(tick_i·F/A)         (per-slice floor)
///                            ×(1−ov) under soft exclusivity
///      plus the converse DUST BOUND (≤ m, or 3m / 2m with the override applied), so a
///      change that over-rounds toward the maker is visible too.
///    • P2 ITEM ROUND-TRIP — MAKE/TAKE/TAKE_FOR slices sum EXACTLY to the signed amount;
///      pre-funded legs fund exactly what was delivered; the filler's item-token balance
///      never moves; Settlement ends every fill holding nothing.
///    • P3 `filled[]` BINDING — each fill advances `filled[h]` by exactly the resolved
///      delta (post-clamp, post-module), and that is the anchor-unit value charged
///      (SELL) / delivered (BUY).
///
///  matchSettle rounding lives in {MatchSettleRoundingAttack}; priority slices in
///  {PricingModes}. Neither is duplicated here.
contract RoundingSequenceTest is MockSettlementBase {
    uint256 constant BPS = 10_000;
    uint256 constant MAXK = 12;
    uint256 constant BIG = 1e33; // funding headroom: every amount below is ≤ ~2e30
    address constant FEE_TO = address(0xFEE0);
    address constant RIVAL = address(0xE1E1); // the nominated exclusive filler (not us)

    MockERC20[10] internal tk;
    ClampFillModule internal clampModule;

    // ── the scenario under test (storage: keeps the legacy-profile stack shallow) ──
    LegIn[] internal _in;
    LegOut[] internal _out;
    bool internal _buy;
    uint256 internal _den; // the fill denominator A (leg anchor or fillTotal)
    bool internal _hasFillTotal;
    uint256 internal _bump; // the shared bump the fill must price at
    uint256 internal _ov; // soft-exclusivity override applying to our filler (0 = none)

    // ── running totals ──
    bytes32 internal _h;
    uint256 internal _F;
    uint256 internal _m;
    uint256[] internal _cumIn;
    uint256[] internal _cumOut;
    uint256[] internal _snapSolverIn;
    uint256[] internal _snapMakerIn;
    uint256[] internal _snapOut;

    function setUp() public override {
        super.setUp();
        for (uint256 i; i < 10; i++) {
            tk[i] = new MockERC20(string.concat("t", vm.toString(i)));
        }
        clampModule = new ClampFillModule();
        vm.label(FEE_TO, "feeRecipient");
        vm.label(RIVAL, "exclusiveFiller");
    }

    // ═══════════════════════════ fuzz-input shaping ═══════════════════════════

    function _r(uint256 seed, uint256 tag) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, tag)));
    }

    /// @dev Log-uniform-ish in [lo, hi]: a random order of magnitude, then a mantissa.
    ///      Uniform bounding would make almost every ratio ≈ 1e30 / 1e30; this spreads
    ///      anchor/amount ratios across ~60 orders of magnitude in both directions.
    function _lg(uint256 r, uint256 lo, uint256 hi) internal pure returns (uint256) {
        uint256 e = r % 31;
        uint256 x = 1 + (r >> 8) % (10 ** e);
        return _bound(x, lo, hi);
    }

    function _k(uint8 kRaw) internal pure returns (uint256) {
        return _bound(kRaw, 1, MAXK);
    }

    /// @dev A FUZZED UNEVEN partition of `total` into `k` non-zero slices. Each entry
    ///      of `raw` picks its own shape — dust (1..1000), uniform over what is left,
    ///      exactly 1, or an even share — so one run mixes wei-sized and bulk slices,
    ///      which is where an asymmetric per-slice rounding compounds.
    function _partition(uint96[12] memory raw, uint256 k, uint256 total) internal pure returns (uint256[] memory d) {
        d = new uint256[](k);
        uint256 done;
        for (uint256 i; i + 1 < k; i++) {
            uint256 rem = total - done;
            uint256 maxHere = rem - (k - 1 - i); // leave ≥ 1 for every later slice
            uint256 r = raw[i];
            uint256 mode = r & 3;
            uint256 v = r >> 2;
            uint256 x;
            if (mode == 0) x = 1 + v % (maxHere < 1000 ? maxHere : 1000);
            else if (mode == 1) x = 1 + v % maxHere;
            else if (mode == 2) x = 1;
            else x = rem / (k - i);
            if (x == 0) x = 1;
            if (x > maxHere) x = maxHere;
            d[i] = x;
            done += x;
        }
        d[k - 1] = total - done;
    }

    // ═══════════════════════════ scenario builders ═══════════════════════════

    function _reset(bool buy, uint256 den) internal {
        delete _in;
        delete _out;
        _buy = buy;
        _den = den;
        _hasFillTotal = false;
        _bump = 0;
        _ov = 0;
    }

    /// @dev SELL, two input legs (fixed anchor + a secondary that is fixed or RISING),
    ///      two output legs (maker's + a third-party FEE leg), each fixed or DECAYING.
    function _sellLegs(uint256 seed, uint256 A, bool decay) internal {
        _reset(false, A);
        _in.push(LegIn(address(tk[0]), A, 0));
        uint256 s2 = _lg(_r(seed, 1), 1, 1e30);
        _in.push(LegIn(address(tk[1]), s2, decay ? s2 + _lg(_r(seed, 2), 0, 1e30) : 0));
        uint256 o0 = _lg(_r(seed, 3), 1, 1e30);
        uint256 f0 = _lg(_r(seed, 4), 1, 1e30);
        _out.push(LegOut(address(tk[2]), o0, decay ? _bound(_r(seed, 5), 1, o0) : 0, address(0)));
        _out.push(LegOut(address(tk[3]), f0, decay ? _bound(_r(seed, 6), 1, f0) : 0, FEE_TO));
    }

    /// @dev BUY: fixed anchor output (the maker's) + a fixed third-party fee output;
    ///      a conversion input that is fixed-price or RISING, and a secondary input.
    ///      Every BUY input is priced per slice (floor), rising or not.
    function _buyLegs(uint256 seed, uint256 A, bool decay) internal {
        _reset(true, A);
        uint256 p = _lg(_r(seed, 11), 1, 1e30);
        _in.push(LegIn(address(tk[0]), p, decay ? p + _lg(_r(seed, 12), 0, 1e30) : 0));
        uint256 s2 = _lg(_r(seed, 13), 1, 1e30);
        _in.push(LegIn(address(tk[1]), s2, 0));
        _out.push(LegOut(address(tk[2]), A, 0, address(0)));
        _out.push(LegOut(address(tk[3]), _lg(_r(seed, 14), 1, 1e30), 0, FEE_TO));
    }

    function _order(uint256 nonce) internal view returns (Order memory o) {
        o = _blank(nonce);
        if (_buy) o.timing |= uint256(1) << 101;
        LegIn[] memory li = _in;
        LegOut[] memory lo = _out;
        o.legsIn = PackedEncode.legsIn(li);
        o.legsOut = PackedEncode.legsOut(lo);
        _setExpiry(o, block.timestamp + 30 days);
    }

    /// @dev Linear clock decay from now over `dur`; the caller warps to a FIXED point
    ///      inside it once, before the sequence, so every slice sees the same tick.
    function _decay(Order memory o, uint256 seed) internal returns (uint256 elapsed) {
        uint256 dur = _bound(_r(seed, 21), 1, 1 days);
        elapsed = _bound(_r(seed, 22), 0, dur + 100);
        _setDecayStart(o, block.timestamp);
        _setDecayDuration(o, dur);
        _bump = elapsed >= dur ? BPS : (BPS * elapsed) / dur;
    }

    /// @dev Soft exclusivity: someone else holds the window, we fill against `ov`.
    function _soft(Order memory o, uint256 ov) internal {
        o.exclusiveFiller = RIVAL;
        _setExclusivityEnd(o, block.timestamp + 20 days);
        o.params = (o.params & ~uint256(0xffff)) | ov;
        _ov = ov;
    }

    function _withFillTotal(Order memory o, uint256 total, bool viaModule) internal {
        o.fillTotal = total;
        if (viaModule) o.fillModule = address(clampModule);
        _den = total;
        _hasFillTotal = true;
    }

    // ═══════════════════════════ funding / snapshots ═══════════════════════════

    function _fund() internal {
        for (uint256 i; i < _in.length; i++) {
            MockERC20(_in[i].token).mint(maker, BIG);
            _makerApprove(address(settlement), _in[i].token, type(uint160).max);
        }
        for (uint256 j; j < _out.length; j++) {
            MockERC20(_out[j].token).mint(solver, BIG);
            _solverApprove(address(settlement), _out[j].token, type(uint160).max);
        }
    }

    function _outTo(uint256 j) internal view returns (address r) {
        r = _out[j].recipient;
        if (r == address(0)) r = maker;
    }

    function _snapshot() internal {
        delete _snapSolverIn;
        delete _snapMakerIn;
        delete _snapOut;
        for (uint256 i; i < _in.length; i++) {
            _snapSolverIn.push(IERC20(_in[i].token).balanceOf(solver));
            _snapMakerIn.push(IERC20(_in[i].token).balanceOf(maker));
        }
        for (uint256 j; j < _out.length; j++) {
            _snapOut.push(IERC20(_out[j].token).balanceOf(_outTo(j)));
        }
    }

    /// @dev Fold the balance movement since {_snapshot} into the running totals. Every
    ///      leg has its own token, so balances attribute per leg unambiguously. The
    ///      maker pays exactly what the solver receives (no items on these orders).
    function _absorb(uint256[] memory ret, bool haveRet) internal {
        for (uint256 j; j < _out.length; j++) {
            uint256 d = IERC20(_out[j].token).balanceOf(_outTo(j)) - _snapOut[j];
            if (haveRet) assertEq(d, ret[j], "returned per-leg output == what the recipient received");
            _cumOut[j] += d;
        }
        for (uint256 i; i < _in.length; i++) {
            uint256 got = IERC20(_in[i].token).balanceOf(solver) - _snapSolverIn[i];
            uint256 paid = _snapMakerIn[i] - IERC20(_in[i].token).balanceOf(maker);
            assertEq(got, paid, "maker pays exactly what the filler receives");
            _cumIn[i] += got;
        }
    }

    // ═══════════════════════════ the checker ═══════════════════════════

    function _ceil(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /// @dev P1, output side, at the current prefix (`_F`, `_m`).
    function _checkOut() internal view {
        for (uint256 j; j < _out.length; j++) {
            LegOut memory l = _out[j];
            if (_buy) {
                // Cumulative ceil: EXACT at every prefix, no drift either way.
                assertEq(_cumOut[j], _ceil(l.start * _F, _den), "BUY output != cumulative ceil at prefix");
                continue;
            }
            uint256 tick = l.end == 0 ? l.start : l.start - ((l.start - l.end) * _bump) / BPS;
            bool lifted = _ov != 0 && (l.recipient == address(0) || l.recipient == maker);
            uint256 lo = lifted ? _ceil(tick * _F * (BPS + _ov), _den * BPS) : _ceil(tick * _F, _den);
            assertGe(_cumOut[j], lo, "SELL output prefix below ceil(tick*F/A): slicing favoured the filler");
            assertLe(_cumOut[j], lo + (lifted ? 3 : 1) * _m, "SELL output dust exceeds one unit per slice");
        }
    }

    /// @dev P1, input side, at the current prefix.
    function _checkIn() internal view {
        for (uint256 i; i < _in.length; i++) {
            LegIn memory l = _in[i];
            if (!_buy && l.end == 0) {
                // Fixed SELL input: cumulative floor, EXACT at every prefix.
                assertEq(_cumIn[i], (l.start * _F) / _den, "fixed input != cumulative floor at prefix");
                continue;
            }
            uint256 tick = l.end == 0 ? l.start : l.start + ((l.end - l.start) * _bump) / BPS;
            uint256 hi = _ov != 0 ? (tick * _F * (BPS - _ov)) / (_den * BPS) : (tick * _F) / _den;
            assertLe(_cumIn[i], hi, "auctioned input prefix above floor(tick*F/A): slicing overcharged the maker");
            assertGe(_cumIn[i] + (_ov != 0 ? 2 : 1) * _m, hi, "auctioned input under-charge exceeds per-slice bound");
        }
    }

    /// @dev P3 at the current prefix: the counter is the running sum of resolved deltas,
    ///      and on a leg-anchored order it IS the anchor-unit amount charged (SELL) or
    ///      delivered (BUY) — never more than what moved at the signed rate.
    function _checkFilled() internal view {
        assertEq(settlement.filled(_h), _F, "filled[h] != sum of resolved deltas");
        if (!_hasFillTotal) {
            if (_buy) assertEq(_cumOut[0], _F, "BUY: filled[h] != anchor units delivered");
            else assertEq(_cumIn[0], _F, "SELL: filled[h] != anchor units charged");
        }
    }

    function _checkPrefix() internal view {
        _checkOut();
        _checkIn();
        _checkFilled();
    }

    // ═══════════════════════════ the runner ═══════════════════════════

    uint256 constant E_FILL = 0;
    uint256 constant E_UPTO = 1;
    uint256 constant E_BATCH = 2; // the whole partition in ONE batchFill
    uint256 constant E_MIXED = 3; // per-slice choice of fill / fillUpTo / 1-order batchFill

    /// @dev Run the partition `asks` against `o`, checking P1 + P3 after every prefix.
    ///      `overAsk` is added to the LAST ask on a clamping path (fillUpTo, or a
    ///      clamping fill module); a plain identity fill would revert {OverFill}.
    function _run(Order memory o, uint256[] memory asks, uint256 entry, uint256 overAsk) internal {
        _fund();
        bytes memory sig = _sign(o); // before any prank: _sign consumes it
        _h = _hashOrder(o);
        delete _cumIn;
        delete _cumOut;
        for (uint256 i; i < _in.length; i++) _cumIn.push(0);
        for (uint256 j; j < _out.length; j++) _cumOut.push(0);
        _F = 0;
        _m = 0;

        if (entry == E_BATCH) {
            _runBatch(o, sig, asks);
        } else {
            uint256 k = asks.length;
            for (uint256 s; s < k; s++) {
                uint256 e = entry == E_MIXED ? _r(uint256(keccak256(abi.encode(asks))), s) % 3 : entry;
                uint256 ask = asks[s];
                if (s + 1 == k && overAsk != 0) {
                    ask += overAsk;
                    if (o.fillModule == address(0)) e = E_UPTO; // only the clamp path accepts it
                }
                _step(o, sig, ask, e);
            }
        }
        assertEq(_F, _den, "the sequence completes the order");
    }

    function _step(Order memory o, bytes memory sig, uint256 ask, uint256 e) internal {
        _snapshot();
        uint256 prev = settlement.filled(_h);
        uint256 rem = _den - prev;
        uint256 expDelta = ask < rem ? ask : rem;
        uint256[] memory ret;
        if (e == E_FILL) {
            vm.prank(solver);
            ret = settlement.fill(o, sig, ask);
        } else if (e == E_UPTO) {
            ret = _stepUpTo(o, sig, ask, expDelta);
        } else {
            ret = _stepBatchOne(o, sig, ask);
        }
        uint256 got = settlement.filled(_h) - prev;
        assertEq(got, expDelta, "filled[h] advanced by something other than the resolved delta");
        _F += got;
        _m++;
        _absorb(ret, true);
        _checkPrefix();
    }

    function _stepUpTo(Order memory o, bytes memory sig, uint256 ask, uint256 expDelta)
        internal
        returns (uint256[] memory paid)
    {
        uint256 delta;
        uint256[] memory received;
        vm.prank(solver);
        (delta, received, paid) = settlement.fillUpTo(o, sig, ask, solver, 0, "");
        assertEq(delta, expDelta, "fillUpTo returned delta != clamped delta");
        for (uint256 i; i < _in.length; i++) {
            assertEq(
                received[i],
                IERC20(_in[i].token).balanceOf(solver) - _snapSolverIn[i],
                "fillUpTo receipts != what the filler received"
            );
        }
    }

    function _stepBatchOne(Order memory o, bytes memory sig, uint256 ask) internal returns (uint256[] memory) {
        Order[] memory os = new Order[](1);
        bytes[] memory sigs = new bytes[](1);
        uint256[] memory amts = new uint256[](1);
        os[0] = o;
        sigs[0] = sig;
        amts[0] = ask;
        vm.prank(solver);
        (uint256[][] memory outs, bool[] memory ok) = settlement.batchFill(os, sigs, amts, true);
        assertTrue(ok[0], "batch slice filled");
        return outs[0];
    }

    /// @dev The whole partition in ONE `batchFill` (Balancer's amplifier: many tuned
    ///      slices, one transaction). Output prefixes are checked slice by slice from
    ///      the per-order return values; inputs and balances over the whole batch.
    function _runBatch(Order memory o, bytes memory sig, uint256[] memory asks) internal {
        uint256 k = asks.length;
        Order[] memory os = new Order[](k);
        bytes[] memory sigs = new bytes[](k);
        for (uint256 s; s < k; s++) {
            os[s] = o;
            sigs[s] = sig;
        }
        _snapshot();
        vm.prank(solver);
        (uint256[][] memory outs, bool[] memory ok) = settlement.batchFill(os, sigs, asks, true);
        for (uint256 s; s < k; s++) {
            assertTrue(ok[s], "batch slice filled");
            _F += asks[s];
            _m++;
            for (uint256 j; j < _out.length; j++) {
                _cumOut[j] += outs[s][j];
            }
            _checkOut();
        }
        // Balances over the whole batch must agree with the per-slice returns.
        uint256[] memory totals = _cumOut;
        for (uint256 j; j < _out.length; j++) _cumOut[j] = 0;
        _absorb(totals, true);
        _checkPrefix();
    }

    // ═══════════════════════════ P1 — SELL ═══════════════════════════

    /// P1, SELL, all legs fixed: a fee output leg and a secondary input leg alongside
    /// the anchor, fuzzed amounts spread over ~60 orders of magnitude of ratio.
    function testFuzz_prefix_sell_multiLeg(uint96[12] memory raw, uint8 kRaw, uint256 seed) public {
        uint256 k = _k(kRaw);
        uint256 A = _lg(_r(seed, 0), k, 1e30);
        _sellLegs(seed, A, false);
        Order memory o = _order(1);
        _run(o, _partition(raw, k, A), E_FILL, 0);
    }

    /// P1, SELL, DECAYING ticks read at a fixed warped time: both outputs fall, the
    /// secondary input rises (relayer-fee shape). outTick rounds up, inTick down.
    function testFuzz_prefix_sell_decayingTick(uint96[12] memory raw, uint8 kRaw, uint256 seed) public {
        uint256 k = _k(kRaw);
        uint256 A = _lg(_r(seed, 0), k, 1e30);
        _sellLegs(seed, A, true);
        Order memory o = _order(2);
        uint256 elapsed = _decay(o, seed);
        vm.warp(block.timestamp + elapsed);
        _run(o, _partition(raw, k, A), E_FILL, 0);
    }

    /// P1, SELL, SOFT-EXCLUSIVITY override on top of the decaying order: the maker's
    /// own output is lifted by ceil(·(1+ov)) ({Pricing} ~:82), the fee leg is not, and
    /// the rising input is lowered by floor(·(1−ov)) (~:149).
    function testFuzz_prefix_sell_softExclusivityOverride(uint96[12] memory raw, uint8 kRaw, uint256 seed) public {
        uint256 k = _k(kRaw);
        uint256 A = _lg(_r(seed, 0), k, 1e30);
        _sellLegs(seed, A, true);
        Order memory o = _order(3);
        _soft(o, _bound(_r(seed, 30), 1, BPS));
        uint256 elapsed = _decay(o, seed);
        vm.warp(block.timestamp + elapsed);
        _run(o, _partition(raw, k, A), E_FILL, 0);
    }

    /// P1, SELL, bump from an external PRICE MODULE (pinned once per fill), including
    /// module answers above 100% that the core must clamp.
    function testFuzz_prefix_sell_priceModuleBump(uint96[12] memory raw, uint8 kRaw, uint256 seed) public {
        uint256 k = _k(kRaw);
        uint256 A = _lg(_r(seed, 0), k, 1e30);
        _sellLegs(seed, A, true);
        uint256 bps = _bound(_r(seed, 31), 0, 2 * BPS);
        Order memory o = _order(4);
        o.pricingModule = address(new FixedBumpModule(bps));
        _bump = bps > BPS ? BPS : bps;
        _run(o, _partition(raw, k, A), E_FILL, 0);
    }

    /// P1 + P3, SELL, `fillTotal` ≠ `legsIn[0].start`: every leg (anchor included) is
    /// priced against a foreign denominator, identity or through a clamping fill
    /// module (the module path also takes an over-asked final proposal).
    function testFuzz_prefix_sell_fillTotalDenominator(uint96[12] memory raw, uint8 kRaw, uint256 seed) public {
        uint256 k = _k(kRaw);
        uint256 A = _lg(_r(seed, 0), 1, 1e30);
        _sellLegs(seed, A, true);
        Order memory o = _order(5);
        uint256 T = _lg(_r(seed, 40), k, 1e30);
        bool viaModule = _r(seed, 41) & 1 == 1;
        _withFillTotal(o, T, viaModule);
        uint256 elapsed = _decay(o, seed);
        vm.warp(block.timestamp + elapsed);
        _run(o, _partition(raw, k, T), E_FILL, viaModule ? _bound(_r(seed, 42), 0, 1e30) : 0);
    }

    /// P1 + P3, SELL through `fillUpTo`: every slice via the clamp entry, the last one
    /// over-asked; receipts are checked against real balances each step.
    function testFuzz_prefix_sell_fillUpTo(uint96[12] memory raw, uint8 kRaw, uint256 seed) public {
        uint256 k = _k(kRaw);
        uint256 A = _lg(_r(seed, 0), k, 1e30);
        _sellLegs(seed, A, true);
        Order memory o = _order(6);
        if (_r(seed, 50) & 1 == 1) _soft(o, _bound(_r(seed, 51), 1, BPS));
        uint256 elapsed = _decay(o, seed);
        vm.warp(block.timestamp + elapsed);
        _run(o, _partition(raw, k, A), E_UPTO, _bound(_r(seed, 52), 0, 1e30));
    }

    /// P1, SELL, the whole uneven partition inside ONE `batchFill` — the batching
    /// amplifier of the Balancer exploit, on the decaying multi-leg order.
    function testFuzz_prefix_sell_batchFill(uint96[12] memory raw, uint8 kRaw, uint256 seed) public {
        uint256 k = _k(kRaw);
        uint256 A = _lg(_r(seed, 0), k, 1e30);
        _sellLegs(seed, A, true);
        Order memory o = _order(7);
        if (_r(seed, 60) & 1 == 1) _soft(o, _bound(_r(seed, 61), 1, BPS));
        uint256 elapsed = _decay(o, seed);
        vm.warp(block.timestamp + elapsed);
        _run(o, _partition(raw, k, A), E_BATCH, 0);
    }

    /// P1, SELL, MISMATCHED DECIMALS (6 vs 18) in both directions. 18→6 is the
    /// dangerous one: a dust slice of the 18-dec anchor prices every 6-dec leg below one
    /// unit, so outputs must ceil to ≥ 1 and fixed inputs must floor to 0 and catch up.
    function testFuzz_prefix_sell_mismatchedDecimals(uint96[12] memory raw, uint8 kRaw, uint256 seed) public {
        uint256 k = _k(kRaw);
        bool sixToEighteen = _r(seed, 70) & 1 == 1;
        uint256 A = sixToEighteen ? _bound(_r(seed, 0), k, 1e12) : _bound(_r(seed, 0), 1e15, 1e24);
        _reset(false, A);
        _in.push(LegIn(address(tk[0]), A, 0));
        uint256 s2 = sixToEighteen ? _bound(_r(seed, 71), 1e15, 1e24) : _bound(_r(seed, 71), 1, 1e8);
        _in.push(LegIn(address(tk[1]), s2, s2 + s2 / 3));
        uint256 o0 = sixToEighteen ? _bound(_r(seed, 72), 1e15, 1e24) : _bound(_r(seed, 72), 1, 1e12);
        _out.push(LegOut(address(tk[2]), o0, o0 - o0 / 7, address(0)));
        uint256 f0 = sixToEighteen ? _bound(_r(seed, 73), 1e12, 1e20) : _bound(_r(seed, 73), 1, 1e4);
        _out.push(LegOut(address(tk[3]), f0, 0, FEE_TO));
        Order memory o = _order(8);
        uint256 elapsed = _decay(o, seed);
        vm.warp(block.timestamp + elapsed);
        _run(o, _partition(raw, k, A), E_FILL, 0);
    }

    // ═══════════════════════════ P1 — BUY ═══════════════════════════

    /// P1, BUY, multi-leg: fixed anchor output + fixed fee output (cumulative ceil,
    /// EXACT at every prefix), a rising conversion input at a warped tick and a
    /// secondary input (per-slice floor, never above floor(tick·F/A)).
    function testFuzz_prefix_buy_multiLeg(uint96[12] memory raw, uint8 kRaw, uint256 seed) public {
        uint256 k = _k(kRaw);
        uint256 A = _lg(_r(seed, 0), k, 1e30);
        _buyLegs(seed, A, true);
        Order memory o = _order(20);
        uint256 elapsed = _decay(o, seed);
        vm.warp(block.timestamp + elapsed);
        _run(o, _partition(raw, k, A), E_FILL, 0);
    }

    /// P1, BUY, soft-exclusivity override and a price-module bump together, through a
    /// mixed sequence of fill / fillUpTo / single-order batchFill.
    function testFuzz_prefix_buy_overrideAndPriceModule(uint96[12] memory raw, uint8 kRaw, uint256 seed) public {
        uint256 k = _k(kRaw);
        uint256 A = _lg(_r(seed, 0), k, 1e30);
        _buyLegs(seed, A, true);
        Order memory o = _order(21);
        _soft(o, _bound(_r(seed, 80), 1, BPS));
        uint256 bps = _bound(_r(seed, 81), 0, 2 * BPS);
        o.pricingModule = address(new FixedBumpModule(bps));
        _bump = bps > BPS ? BPS : bps;
        _run(o, _partition(raw, k, A), E_MIXED, 0);
    }

    /// P1 + P3, BUY, `fillTotal` ≠ `legsOut[0].start` (identity or clamping module),
    /// driven through fillUpTo with an over-asked tail.
    function testFuzz_prefix_buy_fillTotalDenominator(uint96[12] memory raw, uint8 kRaw, uint256 seed) public {
        uint256 k = _k(kRaw);
        uint256 A = _lg(_r(seed, 0), 1, 1e30);
        _buyLegs(seed, A, true);
        Order memory o = _order(22);
        uint256 T = _lg(_r(seed, 90), k, 1e30);
        _withFillTotal(o, T, _r(seed, 91) & 1 == 1);
        uint256 elapsed = _decay(o, seed);
        vm.warp(block.timestamp + elapsed);
        _run(o, _partition(raw, k, T), E_UPTO, _bound(_r(seed, 92), 0, 1e30));
    }

    /// P1, BUY, MISMATCHED DECIMALS: an 18-dec anchor output paid for in a 6-dec input
    /// (dust slices price the input at 0 — must never be charged above the floor), and
    /// the reverse.
    function testFuzz_prefix_buy_mismatchedDecimals(uint96[12] memory raw, uint8 kRaw, uint256 seed) public {
        uint256 k = _k(kRaw);
        bool eighteenOut = _r(seed, 100) & 1 == 1;
        uint256 A = eighteenOut ? _bound(_r(seed, 0), 1e15, 1e24) : _bound(_r(seed, 0), k, 1e12);
        _reset(true, A);
        uint256 p = eighteenOut ? _bound(_r(seed, 101), 1, 1e12) : _bound(_r(seed, 101), 1e15, 1e24);
        _in.push(LegIn(address(tk[0]), p, p + p / 5));
        _in.push(LegIn(address(tk[1]), eighteenOut ? _bound(_r(seed, 102), 1, 1e4) : _bound(_r(seed, 102), 1e12, 1e20), 0));
        _out.push(LegOut(address(tk[2]), A, 0, address(0)));
        _out.push(
            LegOut(address(tk[3]), eighteenOut ? _bound(_r(seed, 103), 1, 1e6) : _bound(_r(seed, 103), 1e12, 1e20), 0, FEE_TO)
        );
        Order memory o = _order(23);
        uint256 elapsed = _decay(o, seed);
        vm.warp(block.timestamp + elapsed);
        _run(o, _partition(raw, k, A), E_FILL, 0);
    }

    // ═══════════════════════════ P3 — filled[] binding ═══════════════════════════

    /// P3 on its own axis: SELL or BUY, leg-anchored or `fillTotal`-denominated (with
    /// or without a clamping module), each slice through a randomly chosen entry point
    /// and the tail over-asked. After every fill `filled[h]` rose by exactly the
    /// resolved delta, equals the anchor units charged/delivered, and the outputs
    /// delivered cover it at the signed rate (the P1 bounds, re-checked here).
    function testFuzz_filledBinding_mixedEntryPoints(uint96[12] memory raw, uint8 kRaw, uint256 seed) public {
        uint256 k = _k(kRaw);
        bool buy = _r(seed, 110) & 1 == 1;
        uint256 shape = _r(seed, 111) % 3; // 0 leg anchor, 1 fillTotal identity, 2 fillTotal + module
        uint256 A = _lg(_r(seed, 0), shape == 0 ? k : 1, 1e30);
        if (buy) _buyLegs(seed, A, true);
        else _sellLegs(seed, A, true);
        Order memory o = _order(30);
        if (shape != 0) _withFillTotal(o, _lg(_r(seed, 112), k, 1e30), shape == 2);
        if (_r(seed, 113) & 1 == 1) _soft(o, _bound(_r(seed, 114), 1, BPS));
        uint256 elapsed = _decay(o, seed);
        vm.warp(block.timestamp + elapsed);
        _run(o, _partition(raw, k, _den), E_MIXED, _bound(_r(seed, 115), 0, 1e30));
    }

    // ═══════════════════════════ P2 — item round-trip ═══════════════════════════

    SeqPreFundMake internal pfMake;
    SeqPullMake internal pullMake;
    SeqTaker internal taker;
    SeqTakeFor internal pfTakeFor;
    SeqTakeFor internal litTakeFor;

    uint256 internal _X; // TAKE amount (ratio to A fuzzed far from 1)
    uint256 internal _Y; // pull-MAKE amount
    uint256 internal _L; // literal TAKE_FOR funding total (≥ A — see below)

    function _deployItemModules() internal {
        pfMake = new SeqPreFundMake(address(settlement));
        pullMake = new SeqPullMake(address(permit3), address(settlement));
        taker = new SeqTaker(address(permit3));
        pfTakeFor = new SeqTakeFor(address(permit3));
        litTakeFor = new SeqTakeFor(address(permit3));
    }

    /// @dev `(5 << 253) | token << 16 | j` — pre-fund leg reference to `legsOut[j]`.
    function _preFundDesc(uint256 j, address token) internal pure returns (uint256) {
        return (uint256(5) << 253) | (uint256(uint160(token)) << 16) | j;
    }

    /// @dev Token map for the item order:
    ///        tk0 in0  anchor, funded ENTIRELY by the pre-fund TAKE_FOR's proceeds
    ///        tk1 in1  secondary, from the maker's wallet
    ///        tk2 out0 maker · tk3 out1 → pre-fund MAKE · tk4 out2 → pre-fund TAKE_FOR
    ///        tk5 out3 fee leg
    ///        tk6 TAKE proceeds → maker · tk7 pull-MAKE drawn from maker
    ///        tk8 literal TAKE_FOR proceeds → maker · tk9 literal TAKE_FOR funding
    ///      tk6..tk9 are ITEM-ONLY tokens: the filler never holds or touches them.
    function _itemItems(uint256 A) internal view returns (Item[] memory items) {
        items = new Item[](5);
        items[0] = Item({
            op: ItemOp.TAKE_FOR,
            module: address(pfTakeFor),
            amount: A, // == legsIn[0].start, so each slice funds leg 0 exactly
            recipient: address(0),
            data: abi.encode(_preFundDesc(2, address(tk[4])), address(tk[4]), address(tk[0]), false)
        });
        items[1] = Item({
            op: ItemOp.MAKE,
            module: address(pfMake),
            amount: 0, // unread: the pre-fund descriptor is the amount
            recipient: address(0),
            data: abi.encode(_preFundDesc(1, address(tk[3])), address(tk[3]))
        });
        items[2] = Item({
            op: ItemOp.TAKE, module: address(taker), amount: _X, recipient: maker, data: abi.encode(address(tk[6]))
        });
        items[3] = Item({
            op: ItemOp.MAKE, module: address(pullMake), amount: _Y, recipient: address(0), data: abi.encode(address(tk[7]))
        });
        items[4] = Item({
            op: ItemOp.TAKE_FOR,
            module: address(litTakeFor),
            amount: A,
            recipient: maker,
            data: abi.encode(_L, address(tk[9]), address(tk[8]), true)
        });
    }

    function _authoriseItems(Item[] memory items, uint256 A) internal {
        vm.startPrank(maker);
        uint48 exp = uint48(block.timestamp + 30 days);
        // Taker caps set to EXACTLY the signed totals: any slice sum that overshot the
        // item amount would revert in Permit3's book.
        permit3.approveTaker(address(settlement), address(pfTakeFor), keccak256(items[0].data), uint160(A), exp);
        permit3.approveTaker(address(settlement), address(taker), keccak256(items[2].data), uint160(_X), exp);
        permit3.approveTaker(address(settlement), address(litTakeFor), keccak256(items[4].data), uint160(A), exp);
        vm.stopPrank();
        tk[7].mint(maker, _Y);
        _makerApprove(address(pullMake), address(tk[7]), _Y); // exact: no slack for drift
        tk[9].mint(maker, _L);
        _makerApprove(address(litTakeFor), address(tk[9]), _L);
        tk[0].mint(address(pfTakeFor), A); // borrow inventory
        tk[8].mint(address(litTakeFor), A);
        tk[6].mint(address(taker), _X);
    }

    /// P2: across any uneven partition, every item's slices sum EXACTLY to its signed
    /// amount (taker/token caps are exact, so an overshoot would revert), both
    /// pre-funded legs fund exactly what was delivered (≥ ceil(tick·F/A) at every
    /// prefix), the literal TAKE_FOR funds exactly floor(L·F/A), the filler's balance
    /// in every item-only token never moves, the TAKE_FOR proceeds cover leg 0 so the
    /// maker's wallet is never touched for it, and Settlement ends each fill empty.
    ///
    /// @dev The literal funding total is bounded ≥ A on purpose: below that a dust
    ///      slice prorates the funding side to 0 and the core refuses the fill
    ///      ({Base.ForBalanceInvalid} — zero funding against a non-zero draw). That
    ///      fail-closed is the designed behaviour, not a rounding leak.
    function testFuzz_items_roundTrip(uint96[12] memory raw, uint8 kRaw, uint256 seed) public {
        uint256 k = _k(kRaw);
        uint256 A = _lg(_r(seed, 0), k, 1e30);
        bool decay = _r(seed, 120) & 1 == 1;
        _X = _lg(_r(seed, 121), 1, 1e30);
        _Y = _lg(_r(seed, 122), 1, 1e30);
        _L = _lg(_r(seed, 123), A, 1e30);
        _deployItemModules();

        _reset(false, A);
        _in.push(LegIn(address(tk[0]), A, 0));
        _in.push(LegIn(address(tk[1]), _lg(_r(seed, 124), 1, 1e30), 0));
        for (uint256 j; j < 4; j++) {
            uint256 s = _lg(_r(seed, 130 + j), 1, 1e30);
            address to = j == 1 ? address(pfMake) : j == 2 ? address(pfTakeFor) : j == 3 ? FEE_TO : address(0);
            _out.push(LegOut(address(tk[2 + j]), s, decay ? _bound(_r(seed, 140 + j), 1, s) : 0, to));
        }
        Item[] memory items = _itemItems(A);
        Order memory o = _order(40);
        o.items = PackedEncode.items(items);
        if (decay) {
            uint256 elapsed = _decay(o, seed);
            vm.warp(block.timestamp + elapsed);
        }
        _fund();
        _authoriseItems(items, A);
        _runItems(o, _partition(raw, k, A));
    }

    function _itemTokenBals(address who) internal view returns (uint256[4] memory b) {
        for (uint256 t; t < 4; t++) {
            b[t] = tk[6 + t].balanceOf(who);
        }
    }

    function _runItems(Order memory o, uint256[] memory asks) internal {
        bytes memory sig = _sign(o);
        _h = _hashOrder(o);
        delete _cumIn;
        delete _cumOut;
        for (uint256 i; i < 2; i++) _cumIn.push(0);
        for (uint256 j; j < 4; j++) _cumOut.push(0);
        _F = 0;
        _m = 0;
        uint256[4] memory solverItem0 = _itemTokenBals(solver);
        uint256 makerAnchor0 = tk[0].balanceOf(maker);

        for (uint256 s; s < asks.length; s++) {
            _snapshot();
            vm.prank(solver);
            uint256[] memory ret = settlement.fill(o, sig, asks[s]);
            _F += asks[s];
            _m++;
            _absorbItems(ret);
            _checkOut();
            _checkIn();
            _checkFilledItems();
            _checkItemSums(solverItem0, makerAnchor0);
        }
        // Full round trip: every signed item total reconstructed exactly.
        assertEq(taker.total(), _X, "TAKE slices sum to item.amount");
        assertEq(pullMake.total(), _Y, "MAKE slices sum to item.amount");
        assertEq(litTakeFor.totalFor(), _L, "literal TAKE_FOR funding sums to its signed total");
        assertEq(pfTakeFor.totalAmount(), _den, "TAKE_FOR draw sums to item.amount");
    }

    /// @dev Item orders move the anchor leg from TAKE proceeds, not the maker's wallet,
    ///      so inputs are measured at the FILLER (what it was paid).
    function _absorbItems(uint256[] memory ret) internal {
        for (uint256 j; j < 4; j++) {
            uint256 d = IERC20(_out[j].token).balanceOf(_outTo(j)) - _snapOut[j];
            assertEq(d, ret[j], "returned per-leg output == what the recipient received");
            _cumOut[j] += d;
        }
        for (uint256 i; i < 2; i++) {
            _cumIn[i] += IERC20(_in[i].token).balanceOf(solver) - _snapSolverIn[i];
        }
    }

    function _checkFilledItems() internal view {
        assertEq(settlement.filled(_h), _F, "filled[h] != sum of deltas");
        assertEq(_cumIn[0], _F, "SELL: filled[h] != anchor units paid to the filler");
    }

    function _checkItemSums(uint256[4] memory solverItem0, uint256 makerAnchor0) internal view {
        // Cumulative-floor items: exact at every prefix.
        assertEq(taker.total(), (_X * _F) / _den, "TAKE prefix != floor(X*F/A)");
        assertEq(pullMake.total(), (_Y * _F) / _den, "MAKE prefix != floor(Y*F/A)");
        assertEq(pfTakeFor.totalAmount(), _F, "TAKE_FOR draw prefix != floor(A*F/A)");
        assertEq(litTakeFor.totalAmount(), _F, "literal TAKE_FOR draw prefix != F");
        assertEq(litTakeFor.totalFor(), (_L * _F) / _den, "literal funding prefix != floor(L*F/A)");
        // Pre-funded legs: funded == delivered, and delivered ≥ ceil(tick*F/A) (via _checkOut).
        assertEq(pfMake.total(), _cumOut[1], "pre-fund MAKE funded != delivered to it");
        assertEq(pfTakeFor.totalFor(), _cumOut[2], "pre-fund TAKE_FOR funded != delivered to it");
        // Filler never touches an item-only token.
        uint256[4] memory now_ = _itemTokenBals(solver);
        for (uint256 t; t < 4; t++) {
            assertEq(now_[t], solverItem0[t], "filler balance moved in an item-only token");
        }
        // The draw funds leg 0 exactly: the maker's wallet never pays the anchor.
        assertEq(tk[0].balanceOf(maker), makerAnchor0, "maker wallet charged for a leg its TAKE_FOR fully funded");
        // Nothing stranded in the pool.
        for (uint256 t; t < 10; t++) {
            assertEq(tk[t].balanceOf(address(settlement)), 0, "Settlement holds a residue after the fill");
        }
    }
}
