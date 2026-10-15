// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MockSettlementBase, MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Settlement, Order, Item, ItemOp, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";
import {Proportional} from "@core/settlement/Proportional.sol";

import {ProportionalSweepModule} from "../src/ProportionalSweepModule.sol";

/// @dev A contract solver for the netted path: it calls `matchSettle` (so it is the
///      `filler` a SETTLE item pays) and, in a CALL step, pushes its own inventory
///      into the pool. Authenticated as a real fund-releasing CALL target must be
///      (executor AND a flag only its own entrypoint arms — audit 2026-09-30
///      CORE-FILLER-4).
contract SweepCoverSolver {
    Settlement immutable settlement;
    uint256 armed = 1;

    constructor(Settlement s) {
        settlement = s;
    }

    function run(MatchPlan calldata p) external {
        armed = 2;
        settlement.matchSettle(p);
        armed = 1;
    }

    function cover(address[] calldata tokens, uint256[] calldata amounts) external {
        require(msg.sender == address(settlement.EXECUTOR()) && armed == 2, "not my plan");
        for (uint256 i; i < tokens.length; i++) {
            MockERC20(tokens[i]).transfer(address(settlement), amounts[i]);
        }
    }
}

/// @title NettedProportionalSweepTest
/// @notice {ProportionalSweepModule} on the NETTED path. The sweep sizes itself from
///         the maker's LIVE balance, and `matchSettle` lets the solver put any of the
///         plan's DELIVER steps before or after it — including a delivery of the
///         swept token to the same maker by another of its orders. The question the
///         plan (§4.2) asked: does that open a hole the forward path does not have?
///
///         It does not, and these tests pin WHY rather than just the numbers: every
///         netted ordering of {X's delivery, Y's sweep} produces exactly the state a
///         FORWARD sequence of the same two orders produces —
///
///           DELIVER X → ITEM Y   ≡   fill(X); fill(Y)   (sweep includes X's proceeds)
///           ITEM Y → DELIVER X   ≡   fill(Y); fill(X)   (sweep excludes them)
///
///         The filler already chooses that order on the forward path (two fills, or
///         one `batchFill`), and the maker-signed item `amount` caps the sweep on
///         both. So the netted path widens nothing the maker did not already sign
///         away; no module-side guard is needed.
contract NettedProportionalSweepTest is MockSettlementBase {
    ProportionalSweepModule sweep;
    SweepCoverSolver coverSolver;
    MockERC20 tD;

    // Order Y: sell 100 tA for 100 tB, and sweep 100% of tC (cap CAP) to the filler.
    uint256 constant Y_IN = 100e18;
    uint256 constant Y_OUT = 100e18;
    uint256 constant CAP = 1_000e18;
    // Order X (same maker): sell 50 tD for 40 tC — a delivery IN THE SWEPT TOKEN.
    uint256 constant X_IN = 50e18;
    uint256 constant X_OUT = 40e18;
    // What the maker already holds in the swept token.
    uint256 constant HELD = 300e18;

    function setUp() public override {
        super.setUp();
        sweep = new ProportionalSweepModule(address(settlement), address(permit3));
        coverSolver = new SweepCoverSolver(settlement);
        tD = new MockERC20("tD");

        tA.mint(maker, Y_IN);
        tD.mint(maker, X_IN);
        tC.mint(maker, HELD);
        _makerApprove(address(settlement), address(tA), type(uint160).max);
        _makerApprove(address(settlement), address(tD), type(uint160).max);
        _makerApprove(address(sweep), address(tC), type(uint160).max); // the sweep's own grant

        // Both fillers get the same inventory: the outputs the two orders owe.
        tB.mint(address(coverSolver), Y_OUT);
        tC.mint(address(coverSolver), X_OUT);
        tB.mint(solver, Y_OUT);
        tC.mint(solver, X_OUT);
        _solverApprove(address(settlement), address(tB), type(uint160).max);
        _solverApprove(address(settlement), address(tC), type(uint160).max);
    }

    function _orderY() internal view returns (Order memory o) {
        o = _plainOrder(1, address(tA), address(tB), Y_IN, Y_OUT);
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.SETTLE,
            module: address(sweep),
            amount: CAP, // the cap; sliced pro rata, == CAP on this full fill
            recipient: address(0),
            data: abi.encode(address(tC), Proportional.encode(10_000))
        });
        o.items = PackedEncode.items(items);
    }

    function _orderX() internal view returns (Order memory o) {
        o = _plainOrder(2, address(tD), address(tC), X_IN, X_OUT);
    }

    function _step(uint256 kind, uint256 a, uint256 b) internal pure returns (uint256) {
        return MatchStep.pack(kind, a, b);
    }

    /// @dev [Y, X], both full. Schedule: PULL Y, PULL X, CALL cover(tB, tC), then
    ///      `deliverXFirst` decides whether X's tC reaches the maker before Y's sweep.
    function _netted(bool deliverXFirst) internal view returns (MatchPlan memory p) {
        Order[] memory orders = new Order[](2);
        orders[0] = _orderY();
        orders[1] = _orderX();
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(orders[0]);
        sigs[1] = _sign(orders[1]);
        uint256[] memory fills = new uint256[](2);
        fills[0] = Y_IN;
        fills[1] = X_IN;

        uint256[] memory s = new uint256[](6);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 1, 0);
        s[2] = _step(MatchStep.CALL, 0, 0);
        if (deliverXFirst) {
            s[3] = _step(MatchStep.DELIVER, 1, 0);
            s[4] = _step(MatchStep.ITEM, 0, 0);
        } else {
            s[3] = _step(MatchStep.ITEM, 0, 0);
            s[4] = _step(MatchStep.DELIVER, 1, 0);
        }
        s[5] = _step(MatchStep.DELIVER, 0, 0);

        address[] memory toks = new address[](2);
        toks[0] = address(tB);
        toks[1] = address(tC);
        uint256[] memory amts = new uint256[](2);
        amts[0] = Y_OUT;
        amts[1] = X_OUT;
        address[] memory targets = new address[](1);
        targets[0] = address(coverSolver);
        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodeCall(SweepCoverSolver.cover, (toks, amts));

        p = MatchPlan({
            orders: orders,
            sigs: sigs,
            fillAmounts: fills,
            takerDatas: new bytes[](0),
            schedule: s,
            callTargets: targets,
            callDatas: datas,
            profitRecipient: address(0)
        });
    }

    /// @dev The forward reference: two single-order fills by the EOA solver, in the
    ///      given order. Returns (maker's final tC, filler's tC gain).
    function _forward(bool xFirst) internal returns (uint256 makerTc, uint256 fillerTcGain) {
        Order memory y = _orderY();
        Order memory x = _orderX();
        bytes memory sy = _sign(y);
        bytes memory sx = _sign(x);
        uint256 before = tC.balanceOf(solver);
        vm.startPrank(solver);
        if (xFirst) {
            settlement.fill(x, sx, X_IN);
            settlement.fill(y, sy, Y_IN);
        } else {
            settlement.fill(y, sy, Y_IN);
            settlement.fill(x, sx, X_IN);
        }
        vm.stopPrank();
        return (tC.balanceOf(maker), tC.balanceOf(solver) + X_OUT - before);
    }

    /// DELIVER X → ITEM Y: the sweep takes the 40 tC X just delivered along with the
    /// 300 held — exactly what `fill(X); fill(Y)` does on the forward path.
    function test_netted_sweepAfterSiblingDelivery_equalsForwardXthenY() public {
        uint256 snap = vm.snapshotState();
        (uint256 fwdMakerTc, uint256 fwdFillerTc) = _forward(true);
        vm.revertToState(snap);

        MatchPlan memory p = _netted(true);
        coverSolver.run(p);

        uint256 swept = tC.balanceOf(address(coverSolver)); // inventory 40 went into the pool
        assertEq(swept, HELD + X_OUT, "netted: sweep included X's delivered proceeds");
        assertEq(tC.balanceOf(maker), fwdMakerTc, "maker's tC identical to the forward X-then-Y fills");
        assertEq(swept, fwdFillerTc, "filler's sweep identical to the forward X-then-Y fills");
        assertEq(tB.balanceOf(maker), Y_OUT, "Y's output delivered");
    }

    /// ITEM Y → DELIVER X: the sweep runs before X's tC lands — exactly
    /// `fill(Y); fill(X)`. The maker keeps X's proceeds.
    function test_netted_sweepBeforeSiblingDelivery_equalsForwardYthenX() public {
        uint256 snap = vm.snapshotState();
        (uint256 fwdMakerTc, uint256 fwdFillerTc) = _forward(false);
        vm.revertToState(snap);

        MatchPlan memory p = _netted(false);
        coverSolver.run(p);

        uint256 swept = tC.balanceOf(address(coverSolver));
        assertEq(swept, HELD, "netted: sweep took only the pre-plan balance");
        assertEq(tC.balanceOf(maker), X_OUT, "maker kept X's proceeds");
        assertEq(tC.balanceOf(maker), fwdMakerTc, "maker's tC identical to the forward Y-then-X fills");
        assertEq(swept, fwdFillerTc, "filler's sweep identical to the forward Y-then-X fills");
    }

    /// The maker-signed cap bounds the sweep on the netted path exactly as on the
    /// forward one: with a cap below the raised balance, only the cap moves.
    function test_netted_capBoundsTheSweepWhateverTheSchedule() public {
        uint256 cap = 320e18; // between HELD (300) and HELD + X_OUT (340)
        MatchPlan memory p = _netted(true);
        Order memory y = p.orders[0];
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.SETTLE,
            module: address(sweep),
            amount: cap,
            recipient: address(0),
            data: abi.encode(address(tC), Proportional.encode(10_000))
        });
        y.items = PackedEncode.items(items);
        p.orders[0] = y;
        p.sigs[0] = _sign(y);

        coverSolver.run(p);

        assertEq(tC.balanceOf(address(coverSolver)), cap, "sweep capped at the signed amount");
        assertEq(tC.balanceOf(maker), HELD + X_OUT - cap, "the rest stays with the maker");
    }
}
