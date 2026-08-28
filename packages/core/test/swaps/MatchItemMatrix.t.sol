// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order, Item, ItemOp, MatchStep} from "@core/settlement/Settlement.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {MatchShapes} from "../shared/MatchShapes.t.sol";
import {MockERC20} from "../shared/MockSettlementBase.t.sol";
import {PackedEncode} from "../shared/PackedEncode.sol";

/// @dev TAKE mock: a borrow/withdraw that hands over EXACTLY the slice the settler
///      priced. Deliberately different from `MatchSettle.t.sol`'s
///      `MockFundingTaker`, which decouples what it produces from the gated amount
///      in order to drive the UNDER-funded path — here the produce must track the
///      slice, because these sweeps compare a whole fill against three partial ones
///      and a constant produce would make the two disagree for a reason that has
///      nothing to do with matching.
contract SliceTaker is ITakerModule {
    address public immutable permit3;

    constructor(address _permit3) {
        permit3 = _permit3;
    }

    function takeOnBehalf(address, uint256 amount, address receiver, bytes calldata data) external override {
        require(msg.sender == permit3, "only permit3");
        IERC20(abi.decode(data, (address))).transfer(receiver, amount);
    }
}

/// @dev MAKE mock: a deposit. Pulls the slice from the maker through Permit3 into
///      itself, standing in for collateral now held by a lender. One instance per
///      side of a match, so "what the maker put into their position" stays
///      attributable to one maker.
contract SliceMaker is IMakerModule {
    IPermit3 public immutable permit3;
    address public immutable settlement;

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        require(msg.sender == settlement, "only settlement");
        permit3.transferFrom(onBehalfOf, address(this), abi.decode(data, (address)), uint160(amount));
    }
}

/// @title MatchItemMatrix
/// @notice The ITEM axis of the matching matrix — `MatchComboMatrix.t.sol` crosses
///         order shape with order shape while both sides stay item-free, and items
///         are exactly the feature that makes a netted match interesting: a `TAKE`
///         PRODUCES value into the pool mid-schedule, so unlike a pull it cannot be
///         priced in advance and has to be MEASURED. That measurement, not the
///         pricing, is where a netted-only leak would live.
///
///  Two sub-matrices, both scored in `docs/match-combinations.md`:
///
///    N1  item configuration × order shape — one side carries items, the other is
///        the plain fixed/fixed control, so a failure names the shape.
///    N2  item configuration × item configuration — BOTH sides carry items, which
///        is where attribution can cross: two orders producing into the same pool
///        in the same context, with the filler choosing the interleaving.
///
///  ── WHAT EACH CELL ASSERTS ─────────────────────────────────────────────────
///  The same rule as the shape matrix: the maker's realised ledger under
///  `matchSettle` must equal their ledger under the single-order `fill` path at the
///  same fill amounts. The ledger is widened to the maker's ECONOMIC position —
///  their wallet PLUS their own deposit module — because a `MAKE` moves value from
///  the first into the second, and a check that only watched the wallet would read
///  a deposit as a loss.
///
///  ── THE ONE DELIBERATE DIVERGENCE ──────────────────────────────────────────
///  `TAKE_STRAY` — a `TAKE` whose proceeds token is NOT one of the order's input
///  legs — is the cell where the two paths legitimately differ, and it is scored
///  that way rather than skipped:
///
///    • single-order `fill` STRANDS the proceeds in Settlement. Nothing sweeps
///      there, so they are lost to everyone, which is what
///      `Base._executeItems` documents.
///    • `matchSettle` REFUNDS them to the maker (`_creditItemProceeds`), and must:
///      the netted path floors every touched token at its PRE-context balance, so
///      proceeds arriving mid-context sit above that floor and `_sweepSurplus`
///      would otherwise hand a mis-authored order's money to the FILLER — who then
///      has positive-EV reason to hunt such orders and bundle them with anything
///      touching the same token.
///
///  So the netted ledger here is the baseline PLUS the strayed amount, and that is
///  asserted exactly — an equality, not a bound, so a regression in either
///  direction fails. The proceeds token is chosen to be in the match's token
///  UNIVERSE (it is the counterparty's input leg) but not in this order's `legsIn`,
///  which is the only configuration where the hazard is reachable at all.
contract MatchItemMatrixTest is MatchShapes {
    /// @dev The item configurations an order can carry into a match. `SETTLE` and
    ///      `TAKE_FOR` are absent because `matchSettle` refuses them outright
    ///      ({MatchSettleItemUnsupported}); that refusal is pinned in
    ///      `MatchSettle.t.sol` rather than duplicated here.
    enum Items {
        NONE, //           no items — the control row/column
        TAKE_LEG, //       TAKE producing into the order's OWN legsIn[0] token
        TAKE_STRAY, //     TAKE producing a universe token that is NOT an input leg
        MAKE, //           MAKE pulling the maker's funds into their position
        MAKE_THEN_TAKE //  both, so the per-item bits and free scheduling are live
    }

    uint256 constant CONFIGS = 5;

    SliceTaker takerA;
    SliceTaker takerB;
    SliceMaker depositA;
    SliceMaker depositB;

    function setUp() public override {
        super.setUp();
        takerA = new SliceTaker(address(permit3));
        takerB = new SliceTaker(address(permit3));
        depositA = new SliceMaker(address(permit3), address(settlement));
        depositB = new SliceMaker(address(permit3), address(settlement));
        vm.label(address(takerA), "takerA");
        vm.label(address(takerB), "takerB");
        vm.label(address(depositA), "depositA");
        vm.label(address(depositB), "depositB");
    }

    // ──────────────────── item construction ────────────────────

    /// @dev The three amounts an item configuration is sized from, read back off the
    ///      BUILT order rather than from constants — so a shape that changes its
    ///      legs cannot leave the items pointing at a stale number.
    function _dims(Order memory o)
        internal
        pure
        returns (address give, address get, uint256 giveAmt, uint256 getAmt)
    {
        give = PackedEncode.getLegInToken(o.legsIn, 0);
        get = PackedEncode.getLegOutToken(o.legsOut, 0);
        uint256 start = PackedEncode.getLegInStart(o.legsIn, 0);
        // A proportional marker is not an amount; the leg's CAP is the size.
        giveAmt = _isMarker(start) ? PackedEncode.getLegInEnd(o.legsIn, 0) : start;
        getAmt = PackedEncode.getLegOutStart(o.legsOut, 0);
    }

    /// @dev Attach `cfg`'s items to a built order. Kept small on purpose: every
    ///      amount is a quarter (or a fiftieth) of a leg, so no cell can fail
    ///      because an item outgrew the order it rides on.
    function _withItems(Order memory o, Items cfg, address taker, address depositor)
        internal
        pure
        returns (Order memory)
    {
        (address give, address get, uint256 giveAmt, uint256 getAmt) = _dims(o);
        if (cfg == Items.NONE) return o;

        Item memory take_ = cfg == Items.TAKE_STRAY
            // The hazard cell: proceeds in the order's OUTPUT token — present in the
            // match's universe (it is the counterparty's input) but not in THIS
            // order's `legsIn`, so it must be refunded rather than swept.
            ? Item({op: ItemOp.TAKE, module: taker, amount: getAmt / 50, recipient: address(0), data: abi.encode(get)})
            // The ordinary leverage shape: the borrow funds the order's own input.
            : Item({op: ItemOp.TAKE, module: taker, amount: giveAmt / 4, recipient: address(0), data: abi.encode(give)});
        Item memory make_ =
            Item({op: ItemOp.MAKE, module: depositor, amount: getAmt / 4, recipient: address(0), data: abi.encode(get)});

        Item[] memory items;
        if (cfg == Items.MAKE) {
            items = new Item[](1);
            items[0] = make_;
        } else if (cfg == Items.MAKE_THEN_TAKE) {
            items = new Item[](2);
            items[0] = make_; //  index 0 — the deposit
            items[1] = take_; //  index 1 — the borrow
        } else {
            items = new Item[](1);
            items[0] = take_;
        }
        o.items = PackedEncode.items(items);
        return o;
    }

    /// @dev The item index of `cfg`'s TAKE, if it has one. `hasTake == false` means
    ///      the schedule emits no pre-pull ITEM step for this order.
    function _takeAt(Items cfg) internal pure returns (bool hasTake, uint256 idx) {
        if (cfg == Items.TAKE_LEG || cfg == Items.TAKE_STRAY) return (true, 0);
        if (cfg == Items.MAKE_THEN_TAKE) return (true, 1);
    }

    function _makeAt(Items cfg) internal pure returns (bool hasMake, uint256 idx) {
        if (cfg == Items.MAKE || cfg == Items.MAKE_THEN_TAKE) return (true, 0);
    }

    // ──────────────────── authority + stock ────────────────────

    /// @dev Everything `cfg` needs to actually run: the maker's Permit3 TAKER
    ///      allowance (spender-keyed at Settlement, module-bound, `ref` = the item
    ///      data hash), the maker's token allowance to their own deposit module, and
    ///      the lender's stock of whatever it is about to hand over.
    ///
    ///      Re-granted before each phase because Permit3 DECREMENTS a finite
    ///      allowance — the baseline run would otherwise eat the budget the match
    ///      run needs, and a `uint160.max` grant (which Permit3 never decrements)
    ///      would mask exactly the double-spend these sweeps want to see.
    function _authorize(Order memory o, address who, Items cfg, address taker, address depositor) internal {
        (bool hasTake, uint256 ti) = _takeAt(cfg);
        (bool hasMake, uint256 mi) = _makeAt(cfg);
        if (hasTake) {
            bytes memory data = PackedEncode.getItemData(o.items, ti);
            address token = abi.decode(data, (address));
            vm.prank(who);
            permit3.approveTaker(
                address(settlement), taker, keccak256(data), uint160(1e30), uint48(block.timestamp + 1 hours)
            );
            MockERC20(token).mint(taker, 1e24); // the lender's book
        }
        if (hasMake) {
            address token = abi.decode(PackedEncode.getItemData(o.items, mi), (address));
            vm.startPrank(who);
            MockERC20(token).approve(address(permit3), type(uint256).max);
            permit3.approveToken(depositor, token, uint160(1e30), 0);
            vm.stopPrank();
        }
    }

    // ──────────────────── the economic ledger ────────────────────

    /// @dev The maker's ECONOMIC position: wallet plus their own deposit module. A
    ///      `MAKE` moves value between the two, so a wallet-only ledger would read a
    ///      deposit as a loss and the signed output floor would fail on every
    ///      MAKE-bearing cell for no reason. The taker module is deliberately
    ///      OUTSIDE the boundary — it is the lender, not the maker.
    function _econ(address who, address depositor) internal view returns (uint256[3] memory b) {
        uint256[3] memory w = _snap(who);
        uint256[3] memory d = _snap(depositor);
        for (uint256 k; k < 3; ++k) {
            b[k] = w[k] + d[k];
        }
    }

    /// @dev Token index of `t` in the `_snap` ordering (tA, tB, tC).
    function _idx(address t) internal view returns (uint256) {
        if (t == address(tA)) return 0;
        if (t == address(tB)) return 1;
        return 2;
    }

    /// @dev What `cfg` adds to the maker's netted ledger ON TOP of the single-order
    ///      baseline: nothing, except for `TAKE_STRAY`, where the netted path
    ///      refunds proceeds the single-order path strands. Returned as an explicit
    ///      expected DIFFERENCE so the assertion stays an equality.
    function _strayCredit(Order memory o, Items cfg) internal view returns (uint256 tokenIndex, int256 amount) {
        if (cfg != Items.TAKE_STRAY) return (0, 0);
        (bool hasTake, uint256 ti) = _takeAt(cfg);
        require(hasTake, "config has no take");
        (, address get,, uint256 getAmt) = _dims(o);
        // Mirrors `_withItems`: the strayed TAKE is sized `getAmt / 50` in `get`.
        // Recomputed from the legs rather than read back off the packed item, so the
        // expectation and the item cannot drift apart without this line changing too.
        require(abi.decode(PackedEncode.getItemData(o.items, ti), (address)) == get, "stray token moved");
        return (_idx(get), int256(getAmt / 50));
    }

    // ──────────────────── schedule ────────────────────

    /// @dev The generic item-bearing schedule:
    ///
    ///        every TAKE  →  every PULL  →  pad  →  both DELIVERs  →  every MAKE
    ///
    ///      TAKEs run FIRST because their proceeds credit an input leg, and
    ///      `_stepPull` draws only the shortfall — running the pull first would move
    ///      the maker's own tokens for value the item was about to produce. MAKEs run
    ///      LAST because a deposit spends what the delivery just paid the maker.
    ///      Both orders' items are interleaved into one context, which is the
    ///      attribution question sub-matrix N2 exists to ask.
    function _itemSchedule(Order memory a, Order memory b, Items ca, Items cb)
        internal
        pure
        returns (uint256[] memory s)
    {
        (bool takeA, uint256 tia) = _takeAt(ca);
        (bool takeB, uint256 tib) = _takeAt(cb);
        (bool makeA, uint256 mia) = _makeAt(ca);
        (bool makeB, uint256 mib) = _makeAt(cb);
        uint256 nInA = PackedEncode.count(a.legsIn);
        uint256 nInB = PackedEncode.count(b.legsIn);

        uint256 n = nInA + nInB + 3;
        if (takeA) ++n;
        if (takeB) ++n;
        if (makeA) ++n;
        if (makeB) ++n;
        s = new uint256[](n);

        uint256 k;
        if (takeA) s[k++] = _step(MatchStep.ITEM, 0, tia);
        if (takeB) s[k++] = _step(MatchStep.ITEM, 1, tib);
        for (uint256 i; i < nInA; ++i) s[k++] = _step(MatchStep.PULL, 0, i);
        for (uint256 i; i < nInB; ++i) s[k++] = _step(MatchStep.PULL, 1, i);
        s[k++] = _step(MatchStep.CALL, 0, 0);
        s[k++] = _step(MatchStep.DELIVER, 0, 0);
        s[k++] = _step(MatchStep.DELIVER, 1, 0);
        if (makeA) s[k++] = _step(MatchStep.ITEM, 0, mia);
        if (makeB) s[k] = _step(MatchStep.ITEM, 1, mib);
    }

    // ──────────────────── N1: item configuration × order shape ────────────────────

    /// @notice One side carries every item configuration against every shape; the
    ///         other side is the plain fixed/fixed control, so a failure names the
    ///         shape that broke rather than a pair.
    function test_itemMatrix_shapes_fullFill() public {
        for (uint256 c; c < CONFIGS; ++c) {
            for (uint256 x; x < SHAPES; ++x) {
                _runCell(Items(c), Shape(x), Items.NONE, Shape.FIXED, 1);
            }
        }
    }

    /// @notice The same crossing, sliced into three fills. Item slices pro-rate off
    ///         the same `newFilled`/`prevFilled` the legs do, so this is where a
    ///         cumulative-vs-per-fill mismatch between an item and its order would
    ///         surface. `PROPORTIONAL` is excluded — it reverts on anything but a
    ///         full fill by construction.
    function test_itemMatrix_shapes_sliced() public {
        for (uint256 c; c < CONFIGS; ++c) {
            for (uint256 x; x < SHAPES; ++x) {
                if (Shape(x) == Shape.PROPORTIONAL) continue;
                _runCell(Items(c), Shape(x), Items.NONE, Shape.FIXED, 3);
            }
        }
    }

    // ──────────────────── N2: item configuration × item configuration ────────────────────

    /// @notice BOTH sides carry items, shapes held fixed. This is the attribution
    ///         question: two orders producing into one pool in one context, with the
    ///         filler choosing the interleaving. `_creditItemProceeds` measures each
    ///         item's window individually, so order A's borrow must never be
    ///         credited to order B's leg however the steps are arranged.
    function test_itemMatrix_crossOrder_fullFill() public {
        for (uint256 ca; ca < CONFIGS; ++ca) {
            for (uint256 cb; cb < CONFIGS; ++cb) {
                _runCell(Items(ca), Shape.FIXED, Items(cb), Shape.FIXED, 1);
            }
        }
    }

    /// @notice And sliced, because the cross-order case is the one where a per-fill
    ///         item slice and a per-fill leg slice have to stay in step across two
    ///         orders at once.
    function test_itemMatrix_crossOrder_sliced() public {
        for (uint256 ca; ca < CONFIGS; ++ca) {
            for (uint256 cb; cb < CONFIGS; ++cb) {
                _runCell(Items(ca), Shape.FIXED, Items(cb), Shape.FIXED, 3);
            }
        }
    }

    // ──────────────────── one cell ────────────────────

    /// @dev Build the pair twice — settled alone, then settled against each other —
    ///      at the same amounts and the same timestamp, and compare. Split across
    ///      two helpers because one frame cannot hold both runs' state.
    function _runCell(Items ca, Shape sa, Items cb, Shape sb, uint256 slices) internal {
        (int256[3] memory aBase, int256[3] memory bBase) = _itemBaseline(ca, sa, cb, sb, slices);
        _itemMatched(ca, sa, cb, sb, slices, aBase, bBase);
    }

    /// @dev The reference: each order settled ALONE through `fill`, items and all.
    function _itemBaseline(Items ca, Shape sa, Items cb, Shape sb, uint256 slices)
        internal
        returns (int256[3] memory aOut, int256[3] memory bOut)
    {
        Order memory a = _prepare(sa, ca, alice, false, address(takerA), address(depositA));
        Order memory b = _prepare(sb, cb, bob, true, address(takerB), address(depositB));
        _fundSolver();

        uint256[3] memory aBefore = _econ(alice, address(depositA));
        uint256[3] memory bBefore = _econ(bob, address(depositB));
        _sliceFill(a, _signWith(a, alicePk), _anchor(a, alice), slices);
        _sliceFill(b, _signWith(b, bobPk), _anchor(b, bob), slices);
        aOut = _delta(aBefore, _econ(alice, address(depositA)));
        bOut = _delta(bBefore, _econ(bob, address(depositB)));
    }

    /// @dev The same two orders, netted — and every assertion the cell owns.
    function _itemMatched(
        Items ca,
        Shape sa,
        Items cb,
        Shape sb,
        uint256 slices,
        int256[3] memory aBase,
        int256[3] memory bBase
    ) internal {
        Order memory a = _prepare(sa, ca, alice, false, address(takerA), address(depositA));
        Order memory b = _prepare(sb, cb, bob, true, address(takerB), address(depositB));
        _fundFiller();

        uint256[3] memory pool = _snap(address(settlement));
        uint256[3] memory aBefore = _econ(alice, address(depositA));
        uint256[3] memory bBefore = _econ(bob, address(depositB));
        _sliceMatchItems(a, b, ca, cb, slices);

        _assertItemCell(a, alice, ca, _delta(aBefore, _econ(alice, address(depositA))), aBase, slices);
        _assertItemCell(b, bob, cb, _delta(bBefore, _econ(bob, address(depositB))), bBase, slices);
        _assertPoolFloor(pool);
    }

    /// @dev Build, fund and authorize one side in one call, so the baseline and the
    ///      matched run cannot drift apart in their setup.
    function _prepare(Shape shape, Items cfg, address who, bool mirrored, address taker, address depositor)
        internal
        returns (Order memory o)
    {
        o = _withItems(_build(shape, who, mirrored), cfg, taker, depositor);
        _fundMaker(o, who);
        _authorize(o, who, cfg, taker, depositor);
    }

    /// @dev The cell's verdict. Identical to the shape matrix's, plus the one
    ///      documented divergence: `TAKE_STRAY`'s refund is expected as an EXACT
    ///      credit on top of the baseline, never as slack.
    function _assertItemCell(
        Order memory o,
        address who,
        Items cfg,
        int256[3] memory got,
        int256[3] memory base,
        uint256 slices
    ) internal view {
        (uint256 t, int256 credit) = _strayCredit(o, cfg);
        int256[3] memory expected = base;
        expected[t] += credit; // zero for every configuration but TAKE_STRAY

        assertTrue(got[0] != 0 || got[1] != 0 || got[2] != 0, "vacuous cell: the maker's ledger never moved");
        _assertSameLedger(got, expected, "maker: netted item ledger differs from the single-order path");
        _assertInputsWithinSignedCeiling(o, got);
        if (slices == 1) _assertOutputsAboveSignedFloor(o, who, got);
    }

    /// @dev Settle the pair as a match in `slices` parts, on the item schedule.
    function _sliceMatchItems(Order memory a, Order memory b, Items ca, Items cb, uint256 slices) internal {
        uint256[] memory schedule = _itemSchedule(a, b, ca, cb);
        uint256 anchorA = _anchor(a, alice);
        uint256 anchorB = _anchor(b, bob);
        uint256 doneA;
        uint256 doneB;
        for (uint256 k; k < slices; ++k) {
            uint256 dA = k + 1 == slices ? anchorA - doneA : anchorA / slices;
            uint256 dB = k + 1 == slices ? anchorB - doneB : anchorB / slices;
            if (dA == 0 || dB == 0) continue;
            filler.run(_planWith(a, b, dA, dB, schedule));
            doneA += dA;
            doneB += dB;
        }
    }
}
