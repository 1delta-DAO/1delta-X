// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Order, Item, ItemOp, LegOut, Validator} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";
import {Proportional} from "@core/settlement/Proportional.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {NativeUnwrapModule} from "@modules/transfer/src/NativeUnwrapModule.sol";
import {ProportionalSweepModule} from "@modules/transfer/src/ProportionalSweepModule.sol";
import {OcoGroupModule} from "@modules/oco/src/OcoGroupModule.sol";
import {AggregatorFillSolver, RoutePlan, NO_PATCH, Permit2612} from "@solvers/aggregator/AggregatorFillSolver.sol";

import {MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";
import {AggregatorFillSolverTest, MockRouter} from "./AggregatorFillSolver.t.sol";
import {MockWNative} from "./AggregatorNative.t.sol";
import {noGuard} from "./shared/AggDeploy.sol";

/// @dev A PRE-FUNDED lending-style sink: the fill delivers the leg straight to this
///      module, and the item "supplies" exactly that delivery (the ledger amount the
///      core passes) to a pool on the maker's behalf. {PreFundGuard} proves the
///      delivery landed here first — the shape of the 15 pre-fund lending modules.
contract MockPreFundSupply is IMakerModule {
    address public immutable settlement;
    address public immutable pool;
    mapping(address => uint256) public supplied;

    constructor(address settlement_, address pool_) {
        (settlement, pool) = (settlement_, pool_);
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        require(msg.sender == settlement, "only settlement");
        PreFundGuard.requireLegRef(data);
        address asset = PreFundGuard.fundingToken(data);
        PreFundGuard.requireDelivered(data, asset, amount);
        supplied[onBehalfOf] += amount;
        SafeTransferLib.safeTransfer(asset, pool, amount);
    }
}

/// @dev An opaque route that produces TWO output tokens from one input.
contract TwoOutRouter {
    address public immutable TOKEN_IN;
    address public immutable OUT_A;
    address public immutable OUT_B;

    constructor(address tokenIn, address outA, address outB) {
        (TOKEN_IN, OUT_A, OUT_B) = (tokenIn, outA, outB);
    }

    function swap(uint256 amountIn, uint256 a, uint256 b, address recipient) external {
        SafeTransferLib.safeTransferFrom(TOKEN_IN, msg.sender, address(this), amountIn);
        SafeTransferLib.safeTransfer(OUT_A, recipient, a);
        SafeTransferLib.safeTransfer(OUT_B, recipient, b);
    }
}

/// @title AggregatorZeroCapitalItemsTest
/// @notice Task 31 on the solver side: with the core's `matchSettle` admitting
///         pre-funded MAKE, TAKE_FOR and SETTLE items (the delivery ledger is handed
///         to an order only at its DELIVER step), {AggregatorFillSolver.executeItemFill}'s
///         one-order plan — early items → PULL → PRESEND → CALL (route) → DELIVER →
///         late items — fills the delivery-consuming shapes with ZERO solver
///         inventory. Real Settlement + Permit3 from core.
contract AggregatorZeroCapitalItemsTest is AggregatorFillSolverTest {
    MockWNative wn;
    MockRouter wnRouter;
    uint256 constant LATE0 = 1; // item 0 runs after DELIVER

    function setUp() public virtual override {
        super.setUp();
        wn = new MockWNative();
        wnRouter = new MockRouter(address(tA), address(wn));
        vm.deal(address(this), 1_000e18);
        wn.deposit{value: 1_000e18}();
        wn.transfer(address(wnRouter), 1_000e18);
    }

    function _np() internal pure returns (Permit2612[] memory) {
        return new Permit2612[](0);
    }

    /// @dev `forLegPreFund(j, token)`: bit 255 (leg reference) | bit 253 (pre-fund) |
    ///      token at [16, 176) | leg index j.
    function _preFund(uint256 j, address token) internal pure returns (uint256) {
        return (uint256(5) << 253) | (uint256(uint160(token)) << 16) | j;
    }

    function _oneItem(Order memory o, Item memory it) internal pure {
        Item[] memory items = new Item[](1);
        items[0] = it;
        o.items = PackedEncode.items(items);
    }

    function _assertZeroInventory(address token) internal view {
        assertLe(MockERC20(token).balanceOf(address(aggSolver)), 1, "solver ends with at most its 1-wei floor");
        assertEq(MockERC20(token).balanceOf(address(settlement)), 0, "pool flat");
    }

    // ═══════════════ (a) native-out through NativeUnwrapModule ═══════════════

    function _unwrapOrder(uint256 nonce, NativeUnwrapModule m) internal view returns (Order memory o) {
        o = _order(nonce);
        o.legsOut = PackedEncode.oneLegOut(address(wn), AMOUNT_OUT, 0, address(m));
        _oneItem(
            o,
            Item({
                op: ItemOp.MAKE,
                module: address(m),
                amount: 0,
                recipient: address(0),
                data: abi.encode(_preFund(0, address(wn)), address(0))
            })
        );
    }

    /// A USD-for-native order through the deployed-shape unwrap module: WNATIVE leg to
    /// the module + pre-funded MAKE item, flagged LATE. Zero inventory.
    function test_itemFill_nativeUnwrapModule_zeroInventory() public {
        NativeUnwrapModule m = new NativeUnwrapModule(address(wn), address(settlement), 100_000);
        Order memory o = _unwrapOrder(1, m);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _planFor(AMOUNT_IN, address(aggSolver), AMOUNT_OUT, NO_PATCH);
        p.router = address(wnRouter);
        uint256 before = maker.balance;
        aggSolver.executeItemFill(o, sig, AMOUNT_IN, p, "", LATE0, _np(), noGuard());
        assertEq(maker.balance - before, AMOUNT_OUT, "raw native in the maker's wallet");
        assertEq(wn.balanceOf(address(m)), 0, "module holds nothing");
        assertEq(wn.balanceOf(address(this)), AMOUNT_IN - AMOUNT_OUT - 1, "WNATIVE spread to the caller");
        assertEq(wn.balanceOf(address(aggSolver)), 1, "only the self-seeded floor");
        assertEq(tA.balanceOf(address(aggSolver)), 0, "zero inventory");
    }

    /// The same order with the item scheduled EARLY (before its DELIVER) fails closed
    /// in the core: the delivery ledger is empty until DELIVER (`ForLegInvalid`).
    function test_itemFill_nativeUnwrapModule_earlyItemFailsClosed() public {
        NativeUnwrapModule m = new NativeUnwrapModule(address(wn), address(settlement), 100_000);
        Order memory o = _unwrapOrder(2, m);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _planFor(AMOUNT_IN, address(aggSolver), AMOUNT_OUT, NO_PATCH);
        p.router = address(wnRouter);
        vm.expectRevert(Base.ForLegInvalid.selector);
        aggSolver.executeItemFill(o, sig, AMOUNT_IN, p, "", 0, _np(), noGuard());
    }

    // ═══════════════ (b) swap → supply (pre-funded lending MAKE) ═══════════════

    function _supplyOrder(uint256 nonce, MockPreFundSupply m) internal view returns (Order memory o) {
        o = _order(nonce);
        o.legsOut = PackedEncode.oneLegOut(address(tB), AMOUNT_OUT, 0, address(m));
        _oneItem(
            o,
            Item({op: ItemOp.MAKE, module: address(m), amount: 0, recipient: address(0), data: abi.encode(_preFund(0, address(tB)))})
        );
    }

    function test_itemFill_preFundSupply_zeroInventory() public {
        address lendingPool = address(0x9001);
        MockPreFundSupply m = new MockPreFundSupply(address(settlement), lendingPool);
        Order memory o = _supplyOrder(3, m);
        bytes memory sig = _sign(o);
        aggSolver.executeItemFill(o, sig, AMOUNT_IN, _plan(address(aggSolver), AMOUNT_OUT), "", LATE0, _np(), noGuard());
        assertEq(m.supplied(maker), AMOUNT_OUT, "supplied exactly the delivery, for the maker");
        assertEq(tB.balanceOf(lendingPool), AMOUNT_OUT);
        assertEq(tB.balanceOf(maker), 0, "the maker's wallet never held tB (no receive-side approval)");
        _assertZeroInventory(address(tB));
        assertEq(tA.balanceOf(address(aggSolver)), 0);
    }

    function test_itemFill_preFundSupply_earlyItemFailsClosed() public {
        MockPreFundSupply m = new MockPreFundSupply(address(settlement), address(0x9001));
        tB.mint(address(m), 500e18); // residue on the shared module must NOT fund it
        Order memory o = _supplyOrder(4, m);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _plan(address(aggSolver), AMOUNT_OUT);
        vm.expectRevert(Base.ForLegInvalid.selector);
        aggSolver.executeItemFill(o, sig, AMOUNT_IN, p, "", 0, _np(), noGuard());
    }

    // ═══════════════ (c) an OCO bracket leg (SETTLE claim) ═══════════════

    function _ocoLeg(uint256 nonce, OcoGroupModule oco, uint256 groupId) internal view returns (Order memory o) {
        o = _order(nonce);
        _oneItem(
            o,
            Item({
                op: ItemOp.SETTLE,
                module: address(oco),
                amount: AMOUNT_IN, // the anchor
                recipient: address(0),
                data: abi.encode(groupId, nonce, AMOUNT_IN)
            })
        );
        Validator[] memory vs = new Validator[](1);
        vs[0] = Validator({target: address(oco), data: abi.encode(groupId)});
        o.validators = PackedEncode.validators(vs);
    }

    function _ocoRun(uint256 lateItems) internal {
        OcoGroupModule oco = new OcoGroupModule(address(settlement));
        uint256 groupId = 0xB4AC + lateItems;
        Order memory tp = _ocoLeg(10 + lateItems * 2, oco, groupId); // the take-profit leg
        Order memory sl = _ocoLeg(11 + lateItems * 2, oco, groupId); // its stop-loss sibling
        bytes memory sig = _sign(tp);
        uint256 makerB = tB.balanceOf(maker);
        aggSolver.executeItemFill(tp, sig, AMOUNT_IN, _plan(address(aggSolver), AMOUNT_OUT), "", lateItems, _np(), noGuard());
        assertEq(tB.balanceOf(maker) - makerB, AMOUNT_OUT, "bracket leg filled with zero inventory");
        assertEq(oco.claim(maker, groupId), tp.nonce + 1, "group claimed by the filled leg");
        _assertZeroInventory(address(tB));

        // The sibling is now dead: its validator fails at open.
        bytes memory sig2 = _sign(sl);
        RoutePlan memory p = _plan(address(aggSolver), AMOUNT_OUT);
        vm.expectRevert(abi.encodeWithSelector(Base.ValidationFailed.selector, uint256(0)));
        aggSolver.executeItemFill(sl, sig2, AMOUNT_IN, p, "", lateItems, _np(), noGuard());
    }

    function test_itemFill_ocoBracketLeg_claimEarly() public {
        _ocoRun(0);
    }

    function test_itemFill_ocoBracketLeg_claimLate() public {
        _ocoRun(LATE0);
    }

    // ═══════════════ (d) two output tokens from one opaque route ═══════════════

    /// `onMatchRoute` pushes EVERY output token's proceeds of this fill to the pool
    /// (`_pushOutputs` walks `outMask`), so a route producing two tokens funds both
    /// deliveries. (A POOL route stays single-output: its path ends in the anchor.)
    function test_itemFill_twoOutputTokens() public {
        TwoOutRouter r2 = new TwoOutRouter(address(tA), address(tB), address(tC));
        tB.mint(address(r2), 1_000e18);
        tC.mint(address(r2), 1_000e18);
        LegOut[] memory lo = new LegOut[](2);
        lo[0] = LegOut(address(tB), 80e18, 0, address(0));
        lo[1] = LegOut(address(tC), 5e18, 0, address(0));
        Order memory o = _order(20);
        o.legsOut = PackedEncode.legsOut(lo);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _plan(address(aggSolver), 80e18);
        p.router = address(r2);
        p.data = abi.encodeCall(TwoOutRouter.swap, (AMOUNT_IN, 85e18, 6e18, address(aggSolver)));
        aggSolver.executeItemFill(o, sig, AMOUNT_IN, p, "", 0, _np(), noGuard());
        assertEq(tB.balanceOf(maker), 80e18);
        assertEq(tC.balanceOf(maker), 5e18);
        assertEq(tB.balanceOf(address(this)), 5e18 - 1, "tB spread back through the pool sweep");
        assertEq(tC.balanceOf(address(this)), 1e18 - 1, "tC spread too");
        _assertZeroInventory(address(tB));
        _assertZeroInventory(address(tC));

        // The single-order pull path takes the same two-output route.
        o = _order(21);
        o.legsOut = PackedEncode.legsOut(lo);
        sig = _sign(o);
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
        assertEq(tB.balanceOf(maker), 160e18);
        assertEq(tC.balanceOf(maker), 10e18);
    }

    // ═══════════════ (e) a SETTLE item that pays the SOLVER an ERC20 ═══════════════

    /// A `ProportionalSweepModule` SETTLE in a token OUTSIDE the order's legs: the core
    /// pays it to the filler (this solver). It is NOT routed (only `legsIn[0]`'s delta
    /// is pushed to the route) and NOT split (only the leg tokens are): it stays here
    /// as retained value — out of every later fill's reach (delta rule) — and the
    /// operators move it with {sweep}. The fill itself must be funded by the legs.
    function test_itemFill_settleReceiptInForeignTokenIsRetained() public {
        ProportionalSweepModule sweepMod = new ProportionalSweepModule(address(settlement), address(permit3));
        tC.mint(maker, 50e18);
        vm.startPrank(maker);
        tC.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(sweepMod), address(tC), type(uint160).max, 0);
        vm.stopPrank();
        Order memory o = _order(30);
        _oneItem(
            o,
            Item({
                op: ItemOp.SETTLE,
                module: address(sweepMod),
                amount: 50e18,
                recipient: address(0),
                data: abi.encode(address(tC), Proportional.encode(10_000))
            })
        );
        bytes memory sig = _sign(o);
        aggSolver.executeItemFill(o, sig, AMOUNT_IN, _plan(address(aggSolver), AMOUNT_OUT), "", 0, _np(), noGuard());
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "legs settled from the route");
        assertEq(tC.balanceOf(maker), 0, "swept");
        assertEq(tC.balanceOf(address(aggSolver)), 50e18, "the SETTLE receipt is retained, not routed / split");
        aggSolver.sweep(address(tC), address(this), 50e18);
        assertEq(tC.balanceOf(address(this)), 50e18, "operators recover it");
    }
}
