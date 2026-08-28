// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order, LegIn, LegOut, MatchPlan, MatchStep, Settlement} from "@core/settlement/Settlement.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {MockSettlementBase, MockERC20} from "./MockSettlementBase.t.sol";
import {PackedEncode} from "./PackedEncode.sol";

contract PadFiller {
    Settlement immutable settlement;

    constructor(Settlement s) {
        settlement = s;
    }

    function run(MatchPlan calldata p) external {
        settlement.matchSettle(p);
    }

    function pad(address t0, address t1, address t2, uint256 amt) external {
        IERC20(t0).transfer(address(settlement), amt);
        IERC20(t1).transfer(address(settlement), amt);
        IERC20(t2).transfer(address(settlement), amt);
    }
}

/// @title MatchShapes
/// @notice The MATCHABLE ORDER SHAPE catalogue, shared by every `matchSettle`
///         combination sweep: the eight shapes, their builders, the funding they
///         need, the ledger snapshot the sweeps compare, and the two bounds that
///         hold with no baseline at all.
///
///  It lives here rather than in one of the sweeps because there is more than one
///  axis to cross a shape WITH — shape × shape
///  ([`MatchComboMatrix`](../swaps/MatchComboMatrix.t.sol)) and shape × item
///  configuration ([`MatchItemMatrix`](../swaps/MatchItemMatrix.t.sol)) — and a
///  second copy of the catalogue is a second thing that can silently disagree
///  with the first about what "a decaying output" means.
///
///  The shapes deliberately use coprime-ish amounts: round pairs divide evenly and
///  the rounding goes untested (`docs/edge-case-matrix.md`: "round numbers mask
///  rounding"). See `docs/match-combinations.md` for the rendered matrices.
abstract contract MatchShapes is MockSettlementBase {
    /// @dev The matchable shape catalogue. Each is expressible on either side of a
    ///      match (the builder mirrors the token direction), so the sweep below is
    ///      the full cross product.
    enum Shape {
        FIXED, //        fixed input  → fixed output                       (SELL)
        DECAY_OUT, //    fixed input  → DECAYING output, mid-auction       (SELL)
        FEE_OUT, //      fixed input  → maker leg + third-party fee leg    (SELL)
        MULTI_IN, //     two fixed inputs → one fixed output               (SELL)
        RISING_IN, //    fixed input + RISING second input → fixed output  (SELL)
        PROPORTIONAL, // balance-relative input → fixed output   (SELL, full fill only)
        BUY_FIXED, //    fixed input  → fixed output, exact-output anchor  (BUY)
        BUY_RISING //    RISING input → fixed output, exact-output anchor  (BUY)
    }

    uint256 constant SHAPES = 8;

    // Coprime-ish on purpose: round pairs divide evenly and the rounding goes
    // untested (`docs/edge-case-matrix.md`: "round numbers mask rounding").
    uint256 constant GIVE = 1_000_000_000_000_000_007;
    uint256 constant GET = 3_000_000_000_000_000_001;
    uint256 constant SIDE_IN = 500_000_000_000_000_003; // the MULTI_IN / RISING_IN second leg

    uint256 alicePk = 0xA11CE_2;
    address alice = vm.addr(alicePk);
    uint256 bobPk = 0xB0B_2;
    address bob = vm.addr(bobPk);
    address feeSink = address(0xFEE5);

    PadFiller filler;
    uint256 nonceSeq;

    function setUp() public virtual override {
        super.setUp();
        // A real clock: `DECAY_OUT` warps to the middle of its window, and
        // `_blank`'s relative expiry needs room underneath it.
        vm.warp(1_800_000_000);
        vm.label(alice, "alice");
        vm.label(bob, "bob");
        vm.label(feeSink, "feeSink");
        filler = new PadFiller(settlement);
        vm.label(address(filler), "padFiller");

        // A pre-existing pool balance. `_sweepSurplus` floors every token at its
        // pre-context balance, so this must survive every combination — a donation
        // is not the filler's to take, on any schedule.
        tA.mint(address(settlement), 7e18);
        tB.mint(address(settlement), 7e18);
        tC.mint(address(settlement), 7e18);
    }

    // ──────────────────── shape builders ────────────────────

    /// @dev Build `shape` for `who`. `mirrored` flips the token direction (and the
    ///      amounts with it), so shape × shape covers both sides of a real match.
    function _build(Shape shape, address who, bool mirrored) internal returns (Order memory o) {
        address give = mirrored ? address(tB) : address(tA);
        address get = mirrored ? address(tA) : address(tB);
        uint256 giveAmt = mirrored ? GET : GIVE;
        uint256 getAmt = mirrored ? GIVE : GET;

        o = _blank(++nonceSeq);
        o.maker = who;

        if (shape == Shape.FIXED) {
            o.legsIn = PackedEncode.oneLegIn(give, giveAmt, 0);
            o.legsOut = PackedEncode.oneLegOut(get, getAmt, 0, address(0));
        } else if (shape == Shape.DECAY_OUT) {
            o.legsIn = PackedEncode.oneLegIn(give, giveAmt, 0);
            // Falls to 90% over the window; the warp below sits mid-decay, so the
            // tick is live rather than pinned at either endpoint.
            o.legsOut = PackedEncode.oneLegOut(get, getAmt, (getAmt * 90) / 100, address(0));
            _setDecayStart(o, block.timestamp - 500);
            _setDecayDuration(o, 1000);
        } else if (shape == Shape.FEE_OUT) {
            o.legsIn = PackedEncode.oneLegIn(give, giveAmt, 0);
            LegOut[] memory lo = new LegOut[](2);
            lo[0] = LegOut(get, (getAmt * 99) / 100, 0, address(0)); // the maker's own
            lo[1] = LegOut(get, getAmt / 100, 0, feeSink); //           a sourcing fee
            o.legsOut = PackedEncode.legsOut(lo);
        } else if (shape == Shape.MULTI_IN) {
            LegIn[] memory li = new LegIn[](2);
            li[0] = LegIn(give, giveAmt, 0);
            li[1] = LegIn(address(tC), SIDE_IN, 0);
            o.legsIn = PackedEncode.legsIn(li);
            o.legsOut = PackedEncode.oneLegOut(get, getAmt, 0, address(0));
        } else if (shape == Shape.RISING_IN) {
            // A rising SECOND input — the sourcing-fee shape, priced off the same
            // clock as a decaying output and floored per fill rather than cumulated.
            LegIn[] memory li = new LegIn[](2);
            li[0] = LegIn(give, giveAmt, 0);
            li[1] = LegIn(address(tC), SIDE_IN, (SIDE_IN * 120) / 100);
            o.legsIn = PackedEncode.legsIn(li);
            o.legsOut = PackedEncode.oneLegOut(get, getAmt, 0, address(0));
            _setDecayStart(o, block.timestamp - 500);
            _setDecayDuration(o, 1000);
        } else if (shape == Shape.PROPORTIONAL) {
            // "Sell my whole balance of `give`, capped." The anchor resolves against
            // the maker's live balance at open, so the funding below is what sets it.
            o.legsIn = PackedEncode.oneLegIn(give, _proportionalMarker(), giveAmt);
            o.legsOut = PackedEncode.oneLegOut(get, getAmt, 0, address(0));
        } else if (shape == Shape.BUY_FIXED) {
            o.timing |= uint256(1) << 101; // BUY — anchor becomes legsOut[0]
            o.legsIn = PackedEncode.oneLegIn(give, giveAmt, 0);
            o.legsOut = PackedEncode.oneLegOut(get, getAmt, 0, address(0));
        } else {
            o.timing |= uint256(1) << 101; // BUY_RISING
            o.legsIn = PackedEncode.oneLegIn(give, giveAmt, (giveAmt * 120) / 100);
            o.legsOut = PackedEncode.oneLegOut(get, getAmt, 0, address(0));
            _setDecayStart(o, block.timestamp - 500);
            _setDecayDuration(o, 1000);
        }
    }

    /// @dev The {Proportional} "100% of my balance" marker. Mirrors the library's
    ///      encoding — `type(uint256).max - (BPS - bps)`, so 100% is exactly
    ///      `type(uint256).max` — rather than guessing at a flag bit; anything at or
    ///      below {Proportional.SENTINEL_FLOOR} is read as an ordinary amount.
    function _proportionalMarker() internal pure returns (uint256) {
        return type(uint256).max;
    }

    /// @dev Mirror of `Proportional.isProportional`: STRICTLY above the floor.
    function _isMarker(uint256 start) internal pure returns (bool) {
        return start > type(uint256).max - 10_000;
    }

    function _isProportional(Shape s) internal pure returns (bool) {
        return s == Shape.PROPORTIONAL;
    }

    /// @dev The order's fill denominator, exactly as {OrderGates.anchorTotal}
    ///      resolves it: `legsOut[0]` for a BUY, `legsIn[0]` otherwise — and for a
    ///      proportional leg, the maker's live balance capped at `end`.
    function _anchor(Order memory o, address who) internal view returns (uint256) {
        if (o.timing & (uint256(1) << 101) != 0) return PackedEncode.getLegOutStart(o.legsOut, 0);
        uint256 start = PackedEncode.getLegInStart(o.legsIn, 0);
        if (_isMarker(start)) {
            uint256 cap = PackedEncode.getLegInEnd(o.legsIn, 0);
            uint256 bal = IERC20(PackedEncode.getLegInToken(o.legsIn, 0)).balanceOf(who);
            return bal < cap ? bal : cap;
        }
        return start;
    }

    // ──────────────────── funding ────────────────────

    /// @dev Mint every input leg's worst-case charge (`max(start, end)`) to the
    ///      maker and grant it through Permit3. A proportional leg is funded at its
    ///      cap, which is what then resolves as the anchor.
    function _fundMaker(Order memory o, address who) internal {
        uint256 n = PackedEncode.count(o.legsIn);
        for (uint256 i; i < n; ++i) {
            address token = PackedEncode.getLegInToken(o.legsIn, i);
            uint256 start = PackedEncode.getLegInStart(o.legsIn, i);
            uint256 end = PackedEncode.getLegInEnd(o.legsIn, i);
            uint256 worst = _isMarker(start) ? end : (end > start ? end : start);
            MockERC20(token).mint(who, worst);
            _grant(who, token);
        }
    }

    /// @dev Permit3 allowance, generous but FINITE. `uint160.max` is a sentinel
    ///      Permit3 never decrements, which would mask any double-spend of the
    ///      allowance a schedule might cause.
    function _grant(address who, address token) internal {
        vm.startPrank(who);
        MockERC20(token).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), token, uint160(1e30), 0);
        vm.stopPrank();
    }

    /// @dev The single-order baseline's counterparty: the solver delivers outputs
    ///      out of its own inventory through Permit3.
    function _fundSolver() internal {
        tA.mint(solver, 1e24);
        tB.mint(solver, 1e24);
        tC.mint(solver, 1e24);
        _grant(solver, address(tA));
        _grant(solver, address(tB));
        _grant(solver, address(tC));
    }

    function _fundFiller() internal {
        tA.mint(address(filler), 1e24);
        tB.mint(address(filler), 1e24);
        tC.mint(address(filler), 1e24);
    }

    // ──────────────────── ledgers ────────────────────

    /// @dev One account's balance in all three tokens. Deltas of this are the
    ///      "realised ledger" the two paths must agree on.
    function _snap(address who) internal view returns (uint256[3] memory b) {
        b = [tA.balanceOf(who), tB.balanceOf(who), tC.balanceOf(who)];
    }

    function _delta(uint256[3] memory before, uint256[3] memory afterB)
        internal
        pure
        returns (int256[3] memory d)
    {
        for (uint256 k; k < 3; ++k) {
            d[k] = int256(afterB[k]) - int256(before[k]);
        }
    }

    function _assertSameLedger(int256[3] memory x, int256[3] memory y, string memory what) internal pure {
        for (uint256 k; k < 3; ++k) {
            assertEq(x[k], y[k], what);
        }
    }

    // ──────────────────── the generic bounds ────────────────────

    /// @dev No input leg may ever have charged the maker more than the worst tick
    ///      they signed — `end` on a rising leg, `start` on a fixed one. Derived from
    ///      the legs, so it holds for any shape added to the enum later.
    ///
    ///      Aggregated per TOKEN, because a maker can sign two legs in one token and
    ///      per-leg deltas are not observable from balances.
    function _assertInputsWithinSignedCeiling(Order memory o, int256[3] memory d) internal view {
        uint256 n = PackedEncode.count(o.legsIn);
        for (uint256 t; t < 3; ++t) {
            address token = t == 0 ? address(tA) : t == 1 ? address(tB) : address(tC);
            uint256 ceiling;
            bool isInput;
            for (uint256 i; i < n; ++i) {
                if (PackedEncode.getLegInToken(o.legsIn, i) != token) continue;
                isInput = true;
                uint256 start = PackedEncode.getLegInStart(o.legsIn, i);
                uint256 end = PackedEncode.getLegInEnd(o.legsIn, i);
                // A proportional leg's ceiling IS its cap; the marker is not an amount.
                ceiling += _isMarker(start) ? end : (end > start ? end : start);
            }
            if (!isInput) continue;
            // Only a leg the maker also RECEIVES could make this positive, and none
            // of the shapes here pays a maker in a token it also spends.
            if (d[t] >= 0) continue;
            assertLe(uint256(-d[t]), ceiling, "input charged above the signed ceiling");
        }
    }

    /// @dev At FULL fill, every output leg addressed at the maker must have paid at
    ///      least the floor they signed — `end` on a decaying leg, `start` on a
    ///      fixed one. Fee legs are excluded: they are not the maker's money.
    function _assertOutputsAboveSignedFloor(Order memory o, address who, int256[3] memory d) internal view {
        uint256 n = PackedEncode.count(o.legsOut);
        for (uint256 t; t < 3; ++t) {
            address token = t == 0 ? address(tA) : t == 1 ? address(tB) : address(tC);
            uint256 floorAmt;
            bool isOutput;
            for (uint256 j; j < n; ++j) {
                if (PackedEncode.getLegOutToken(o.legsOut, j) != token) continue;
                address to = PackedEncode.getLegOutRecipient(o.legsOut, j);
                if (to != address(0) && to != who) continue; // a fee leg, not the maker's
                isOutput = true;
                uint256 start = PackedEncode.getLegOutStart(o.legsOut, j);
                uint256 end = PackedEncode.getLegOutEnd(o.legsOut, j);
                floorAmt += end != 0 ? end : start;
            }
            if (!isOutput) continue;
            assertGe(d[t], int256(floorAmt), "output delivered below the signed floor");
        }
    }

    // ──────────────────── plan assembly ────────────────────

    function _step(uint256 kind, uint256 a, uint256 b) internal pure returns (uint256) {
        return kind | (a << 8) | (b << 24);
    }

    /// @dev PULL every input leg of both orders → pad the pool → deliver both.
    ///      Pads AFTER the pulls so a shape whose inputs cannot cover the other
    ///      side's outputs still settles, and the pad's remainder is swept back.
    function _schedule(uint256 nInA, uint256 nInB) internal pure returns (uint256[] memory s) {
        s = new uint256[](nInA + nInB + 3);
        uint256 k;
        for (uint256 i; i < nInA; ++i) s[k++] = _step(MatchStep.PULL, 0, i);
        for (uint256 i; i < nInB; ++i) s[k++] = _step(MatchStep.PULL, 1, i);
        s[k++] = _step(MatchStep.CALL, 0, 0);
        s[k++] = _step(MatchStep.DELIVER, 0, 0);
        s[k] = _step(MatchStep.DELIVER, 1, 0);
    }

    function _plan(Order memory a, Order memory b, uint256 fillA, uint256 fillB)
        internal
        view
        returns (MatchPlan memory)
    {
        return _planWith(a, b, fillA, fillB, _schedule(PackedEncode.count(a.legsIn), PackedEncode.count(b.legsIn)));
    }

    /// @dev The same plan with a caller-supplied schedule — the item sweeps need
    ///      ITEM steps interleaved with the pulls and deliveries, which the
    ///      item-free `_schedule` above cannot express.
    function _planWith(
        Order memory a,
        Order memory b,
        uint256 fillA,
        uint256 fillB,
        uint256[] memory schedule
    ) internal view returns (MatchPlan memory p) {
        Order[] memory orders = new Order[](2);
        (orders[0], orders[1]) = (a, b);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signWith(a, alicePk);
        sigs[1] = _signWith(b, bobPk);
        uint256[] memory fills = new uint256[](2);
        (fills[0], fills[1]) = (fillA, fillB);
        address[] memory targets = new address[](1);
        targets[0] = address(filler);
        bytes[] memory datas = new bytes[](1);
        datas[0] =
            abi.encodeCall(PadFiller.pad, (address(tA), address(tB), address(tC), 5e18));
        p = MatchPlan({
            orders: orders,
            sigs: sigs,
            fillAmounts: fills,
            takerDatas: new bytes[](0),
            schedule: schedule,
            callTargets: targets,
            callDatas: datas,
            profitRecipient: address(0)
        });
    }


    /// @dev Fill one order alone in `slices` parts, remainder on the last.
    function _sliceFill(Order memory o, bytes memory sig, uint256 anchor, uint256 slices) internal {
        uint256 done;
        for (uint256 k; k < slices; ++k) {
            uint256 d = k + 1 == slices ? anchor - done : anchor / slices;
            if (d == 0) continue;
            vm.prank(solver);
            settlement.fill(o, sig, d);
            done += d;
        }
    }


    /// @dev The pre-existing pool balance is not a filler's to take, on ANY
    ///      schedule: `_sweepSurplus` floors every touched token at its pre-context
    ///      value, so a donation must survive every cell of every sweep.
    function _assertPoolFloor(uint256[3] memory before) internal view {
        uint256[3] memory nowBal = _snap(address(settlement));
        for (uint256 t; t < 3; ++t) {
            assertGe(nowBal[t], before[t], "a donated pool balance was reachable");
        }
    }
}
