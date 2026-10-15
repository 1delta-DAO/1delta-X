// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "../shared/PackedEncode.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ISettlementModule} from "@core/interfaces/ISettlementModule.sol";
import {Order, Item, ItemOp, LegIn, LegOut, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";

import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";
import {MockDex, PresendSolver} from "./MatchSettleCoW.t.sol";

/// @dev A pre-funded MAKE with the production floor: it spends exactly the core-sized
///      `amount` out of its own balance and must end at `balance − amount` — the
///      {PreFundGuard.floorOf} shape every shipped pre-fund module uses. "Supplying"
///      is modelled as crediting `supplied[onBehalfOf]` and moving the tokens to a
///      sink, so a wrong `amount` or a mis-attributed delivery shows up in both.
contract MockPreFundSupply is IMakerModule {
    address public immutable settlement;
    address public constant SINK = address(0x5171);
    mapping(address => uint256) public supplied;

    constructor(address _settlement) {
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        require(msg.sender == settlement, "only settlement");
        require(uint256(bytes32(data[0:32])) >> 253 == 5, "pre-fund descriptor required");
        (, address token) = abi.decode(data, (uint256, address));
        // Underflows unless at least `amount` sits here — and `amount` is the core's.
        uint256 floor = IERC20(token).balanceOf(address(this)) - amount;
        IERC20(token).transfer(SINK, amount);
        require(IERC20(token).balanceOf(address(this)) == floor, "spent past the floor");
        supplied[onBehalfOf] += amount;
    }
}

/// @dev A SETTLE module that records who it was told the filler is.
contract RecordingSettle is ISettlementModule {
    address public immutable settlement;
    address public lastFiller;
    uint256 public calls;

    constructor(address _settlement) {
        settlement = _settlement;
    }

    function settle(address, address filler, uint256, bytes calldata) external override {
        require(msg.sender == settlement, "only settlement");
        lastFiller = filler;
        calls++;
    }
}

/// @title MatchSettleDeliveryFundedTest
/// @notice Task 31 (docs/fill-ordering-capital-plan.md): orders whose items CONSUME
///         the fill's own delivery, and SETTLE orders, fill through `matchSettle`
///         with ZERO solver capital — `PULL → PRESEND → CALL (convert) → DELIVER →
///         ITEM`. Before task 31 the shape guard refused them, and the single-order
///         path runs items only after the filler has fronted the outputs, so every
///         such fill needed inventory or a flash loan.
///
///         What keeps it sound is the delivery LEDGER `_stepDeliver` writes: a
///         leg-reference item scheduled before its order's DELIVER finds it empty and
///         fails closed, and one scheduled after it spends exactly what was
///         delivered. Pinned below with residue and a second order's in-flight
///         delivery sitting in the same singleton.
contract MatchSettleDeliveryFundedTest is CoreSettlementBase {
    uint256 bobPk = 0xB0B;
    address bob = vm.addr(bobPk);

    uint256 constant USDC_IN = 2_000e6;
    uint256 constant WETH_OUT = 1 ether;
    uint256 constant BOB_USDC_IN = 1_000e6;
    uint256 constant BOB_WETH_OUT = 0.5 ether;

    MockPreFundSupply supply;
    RecordingSettle recorder;
    MockDex dex;
    PresendSolver solverC; // zero inventory; PRESEND hands it the input, CALL converts

    function setUp() public override {
        super.setUp();
        supply = new MockPreFundSupply(address(settlement));
        recorder = new RecordingSettle(address(settlement));
        dex = new MockDex();
        solverC = new PresendSolver(settlement, dex);
        deal(WETH, address(dex), 10 ether); // the DEX's stock — never the solver's

        deal(USDC, maker, USDC_IN);
        _approveMakerToSettlement(USDC, USDC_IN);
        deal(USDC, bob, BOB_USDC_IN);
        vm.startPrank(bob);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDC, uint160(BOB_USDC_IN), 0);
        vm.stopPrank();
    }

    // ──────────────────── builders ────────────────────

    function _preFundLeg(uint256 index) internal view returns (uint256) {
        return (uint256(5) << 253) | (uint256(uint160(WETH)) << 16) | index;
    }

    /// @dev SELL `usdcIn` USDC for `wethOut` WETH delivered to `legTo`, plus `items`.
    function _buy(address who, uint256 nonce, uint256 usdcIn, uint256 wethOut, address legTo, Item[] memory items)
        internal
        view
        returns (Order memory o)
    {
        LegIn[] memory legsIn = new LegIn[](1);
        legsIn[0] = LegIn(USDC, usdcIn, 0);
        LegOut[] memory legsOut = new LegOut[](1);
        legsOut[0] = LegOut(WETH, wethOut, 0, legTo);
        o = Order({
            params: 0,
            pricingModule: address(0),
            maker: who,
            nonce: nonce,
            legsIn: PackedEncode.legsIn(legsIn),
            legsOut: PackedEncode.legsOut(legsOut),
            timing: _expiryBits(block.timestamp + 1 hours),
            exclusiveFiller: address(0),
            minFillAnchor: 0,
            curve: PackedEncode.noCurve(),
            items: PackedEncode.items(items),
            validators: PackedEncode.noValidators(),
            invariants: PackedEncode.noValidators(),
            fillModule: address(0),
            fillTotal: 0
        });
    }

    /// @dev Swap-and-supply: the WETH leg is delivered to the module, one pre-funded
    ///      MAKE supplies it for the maker. `item.amount` is 0 — the ledger sizes it.
    function _swapAndSupply(address who, uint256 nonce, uint256 usdcIn, uint256 wethOut)
        internal
        view
        returns (Order memory)
    {
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.MAKE, module: address(supply), amount: 0, recipient: address(0), data: abi.encode(_preFundLeg(0), WETH)
        });
        return _buy(who, nonce, usdcIn, wethOut, address(supply), items);
    }

    function _signAs(Order memory o, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), _hashOrder(o)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _plan(Order[] memory orders, uint256[] memory pks, uint256[] memory schedule, uint256 usdcIn, uint256 wethOut)
        internal
        view
        returns (MatchPlan memory)
    {
        uint256 n = orders.length;
        bytes[] memory sigs = new bytes[](n);
        uint256[] memory fills = new uint256[](n);
        for (uint256 i; i < n; i++) {
            sigs[i] = _signAs(orders[i], pks[i]);
            fills[i] = PackedEncode.getLegInStart(orders[i].legsIn, 0);
        }
        address[] memory targets = new address[](1);
        targets[0] = address(solverC);
        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodeCall(PresendSolver.swapAndCover, (USDC, usdcIn, WETH, wethOut));
        return MatchPlan({
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

    function _one(Order memory o) internal view returns (Order[] memory orders, uint256[] memory pks) {
        orders = new Order[](1);
        orders[0] = o;
        pks = new uint256[](1);
        pks[0] = makerPk;
    }

    /// @dev The universe is `[USDC, WETH]` (inputs first): PRESEND index 0 = USDC.
    function _zeroCapitalSchedule() internal pure returns (uint256[] memory s) {
        s = new uint256[](5);
        s[0] = MatchStep.pack(MatchStep.PULL, 0, 0);
        s[1] = MatchStep.pack(MatchStep.PRESEND, 0, 0);
        s[2] = MatchStep.pack(MatchStep.CALL, 0, 0);
        s[3] = MatchStep.pack(MatchStep.DELIVER, 0, 0);
        s[4] = MatchStep.pack(MatchStep.ITEM, 0, 0);
    }

    // ──────────────── pre-funded MAKE: zero capital ────────────────

    /// The headline. Swap 2000 USDC → 1 WETH and supply it, filled by a solver that
    /// holds NOTHING: the maker's input is pulled and pre-sent, converted in the CALL
    /// step, delivered to the module, and the item supplies exactly the delivery.
    function test_preFundMake_zeroCapital_oneOrderPlan() public {
        (Order[] memory orders, uint256[] memory pks) = _one(_swapAndSupply(maker, 1, USDC_IN, WETH_OUT));
        assertEq(IERC20(WETH).balanceOf(address(solverC)), 0, "solver holds no WETH");
        assertEq(IERC20(USDC).balanceOf(address(solverC)), 0, "solver holds no USDC");

        solverC.run(_plan(orders, pks, _zeroCapitalSchedule(), USDC_IN, WETH_OUT));

        assertEq(supply.supplied(maker), WETH_OUT, "the delivered leg was supplied for the maker");
        assertEq(IERC20(WETH).balanceOf(address(supply)), 0, "module ends where it started");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "the maker paid its input");
        assertEq(IERC20(WETH).balanceOf(maker), 0, "the maker's wallet never held WETH");
        assertEq(IERC20(WETH).balanceOf(address(solverC)), 0, "solver fronted nothing");
        assertEq(IERC20(USDC).balanceOf(address(solverC)), 0, "solver ends flat");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "nothing pooled");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "nothing pooled");
    }

    /// Scheduled before its DELIVER, the item finds no ledger and fails closed — even
    /// with more than enough RESIDUE in the module to have "funded" it, which is the
    /// exact balance the old refusal existed to protect.
    function test_preFundMake_itemBeforeDeliver_failsClosed_overResidue() public {
        deal(WETH, address(supply), 5 ether);
        (Order[] memory orders, uint256[] memory pks) = _one(_swapAndSupply(maker, 2, USDC_IN, WETH_OUT));
        uint256[] memory s = new uint256[](5);
        s[0] = MatchStep.pack(MatchStep.PULL, 0, 0);
        s[1] = MatchStep.pack(MatchStep.PRESEND, 0, 0);
        s[2] = MatchStep.pack(MatchStep.CALL, 0, 0);
        s[3] = MatchStep.pack(MatchStep.ITEM, 0, 0); //    hoisted ahead of its delivery
        s[4] = MatchStep.pack(MatchStep.DELIVER, 0, 0);

        MatchPlan memory p = _plan(orders, pks, s, USDC_IN, WETH_OUT);
        vm.expectRevert(Base.ForLegInvalid.selector);
        solverC.run(p);
    }

    /// Two makers, ONE shared singleton, deliveries interleaved ahead of both items:
    /// DELIVER A, DELIVER B, ITEM A, ITEM B, with residue already in the module. Each
    /// item spends exactly its own order's ledger amount; the floor leaves the other
    /// order's in-flight delivery and the residue untouched.
    function test_preFundMake_interleavedTwoOrders_sameModule() public {
        uint256 residue = 0.3 ether;
        deal(WETH, address(supply), residue);

        Order[] memory orders = new Order[](2);
        orders[0] = _swapAndSupply(maker, 3, USDC_IN, WETH_OUT);
        orders[1] = _swapAndSupply(bob, 4, BOB_USDC_IN, BOB_WETH_OUT);
        uint256[] memory pks = new uint256[](2);
        (pks[0], pks[1]) = (makerPk, bobPk);

        uint256[] memory s = new uint256[](8);
        s[0] = MatchStep.pack(MatchStep.PULL, 0, 0);
        s[1] = MatchStep.pack(MatchStep.PULL, 1, 0);
        s[2] = MatchStep.pack(MatchStep.PRESEND, 0, 0);
        s[3] = MatchStep.pack(MatchStep.CALL, 0, 0);
        s[4] = MatchStep.pack(MatchStep.DELIVER, 0, 0);
        s[5] = MatchStep.pack(MatchStep.DELIVER, 1, 0);
        s[6] = MatchStep.pack(MatchStep.ITEM, 0, 0);
        s[7] = MatchStep.pack(MatchStep.ITEM, 1, 0);

        solverC.run(_plan(orders, pks, s, USDC_IN + BOB_USDC_IN, WETH_OUT + BOB_WETH_OUT));

        assertEq(supply.supplied(maker), WETH_OUT, "A supplied exactly A's delivery");
        assertEq(supply.supplied(bob), BOB_WETH_OUT, "B supplied exactly B's delivery");
        assertEq(IERC20(WETH).balanceOf(address(supply)), residue, "residue untouched");
        assertEq(IERC20(WETH).balanceOf(address(solverC)), 0, "solver fronted nothing");
    }

    /// One delivered leg, two pre-funded items referencing it: the second claim
    /// reverts — the ledger's consume bit survives across schedule steps, because it
    /// lives in the order's own `FillCtx`.
    function test_preFundMake_secondClaimOnOneLeg_reverts() public {
        Item[] memory items = new Item[](2);
        bytes memory data = abi.encode(_preFundLeg(0), WETH);
        items[0] = Item({op: ItemOp.MAKE, module: address(supply), amount: 0, recipient: address(0), data: data});
        items[1] = Item({op: ItemOp.MAKE, module: address(supply), amount: 0, recipient: address(0), data: data});
        deal(WETH, address(supply), 5 ether); // enough for a second spend, were it allowed
        (Order[] memory orders, uint256[] memory pks) = _one(_buy(maker, 5, USDC_IN, WETH_OUT, address(supply), items));

        uint256[] memory s = new uint256[](6);
        s[0] = MatchStep.pack(MatchStep.PULL, 0, 0);
        s[1] = MatchStep.pack(MatchStep.PRESEND, 0, 0);
        s[2] = MatchStep.pack(MatchStep.CALL, 0, 0);
        s[3] = MatchStep.pack(MatchStep.DELIVER, 0, 0);
        s[4] = MatchStep.pack(MatchStep.ITEM, 0, 0);
        s[5] = MatchStep.pack(MatchStep.ITEM, 0, 1);

        MatchPlan memory p = _plan(orders, pks, s, USDC_IN, WETH_OUT);
        vm.expectRevert(Base.ForLegInvalid.selector);
        solverC.run(p);
    }

    // ──────────────── SETTLE: admitted, pays `msg.sender` ────────────────

    /// A swap with a SETTLE item (the OCO bracket-leg shape) fills with zero capital,
    /// and the module is told the filler is the context's `msg.sender` — the solver
    /// that owed the delivery. Run with the item first and last: SETTLE carries no
    /// leg reference, so either position is valid.
    function test_settleItem_zeroCapital_eitherPosition() public {
        for (uint256 late; late < 2; late++) {
            deal(USDC, maker, USDC_IN);
            _approveMakerToSettlement(USDC, USDC_IN);
            Item[] memory items = new Item[](1);
            items[0] = Item({op: ItemOp.SETTLE, module: address(recorder), amount: 1, recipient: address(0), data: ""});
            (Order[] memory orders, uint256[] memory pks) = _one(_buy(maker, 10 + late, USDC_IN, WETH_OUT, address(0), items));

            uint256[] memory s = new uint256[](5);
            uint256 k;
            if (late == 0) s[k++] = MatchStep.pack(MatchStep.ITEM, 0, 0);
            s[k++] = MatchStep.pack(MatchStep.PULL, 0, 0);
            s[k++] = MatchStep.pack(MatchStep.PRESEND, 0, 0);
            s[k++] = MatchStep.pack(MatchStep.CALL, 0, 0);
            s[k++] = MatchStep.pack(MatchStep.DELIVER, 0, 0);
            if (late == 1) s[k++] = MatchStep.pack(MatchStep.ITEM, 0, 0);

            uint256 wethBefore = IERC20(WETH).balanceOf(maker);
            solverC.run(_plan(orders, pks, s, USDC_IN, WETH_OUT));

            assertEq(recorder.calls(), late + 1, "the SETTLE item ran");
            assertEq(recorder.lastFiller(), address(solverC), "filler = matchSettle's caller");
            assertEq(IERC20(WETH).balanceOf(maker) - wethBefore, WETH_OUT, "maker paid its output");
            assertEq(IERC20(WETH).balanceOf(address(solverC)), 0, "solver fronted nothing");
        }
    }
}
