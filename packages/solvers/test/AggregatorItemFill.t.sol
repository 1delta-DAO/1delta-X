// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Order, Item, ItemOp, ItemPolicy} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {SolverCallbackExecutor} from "@core/settlement/SolverCallbackExecutor.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {
    AggregatorFillSolver, RoutePlan, FillRoute, SurplusPolicy, NO_PATCH
} from "@solvers/aggregator/AggregatorFillSolver.sol";

import {MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";
import {AggregatorFillSolverTest, MockRouter} from "./AggregatorFillSolver.t.sol";

/// @dev The item-fill entry, declared here rather than called through the
///      contract type so this file compiles against the PRE-fix solver too — the
///      "fails before" run then fails at runtime (no such function) instead of at
///      compile time.
interface IAggregatorItemFill {
    function executeItemFill(
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmount,
        RoutePlan calldata plan,
        bytes calldata takerData,
        uint256 lateItems
    ) external returns (uint256[] memory);
}

/// @dev TAKE = a withdraw / borrow: hands `produce` of `token` (both in `data`) from
///      its own stash to the receiver Settlement names.
contract ItemFillTaker is ITakerModule {
    address public immutable permit3;

    constructor(address _permit3) {
        permit3 = _permit3;
    }

    function takeOnBehalf(address, uint256, address receiver, bytes calldata data) external override {
        require(msg.sender == permit3, "only permit3");
        (address token, uint256 produce) = abi.decode(data, (address, uint256));
        SafeTransferLib.safeTransfer(token, receiver, produce);
    }
}

/// @dev MAKE = a wallet-funded deposit: pulls `amount` of `token` from the maker via
///      Permit3 into itself (the "lender").
contract ItemFillDeposit is IMakerModule {
    IPermit3 public immutable permit3;
    address public immutable settlement;

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        require(msg.sender == settlement, "only settlement");
        address token = abi.decode(data, (address));
        permit3.transferFrom(onBehalfOf, address(this), token, uint160(amount));
    }
}

/// @title AggregatorItemFillTest
/// @notice Audit 2026-09-30 AGG-6 (the item-order half): {AggregatorFillSolver}
///         could not fill ANY item-bearing order — its only entry fills through the
///         core's item-free `PostInputs` mode — so a "withdraw my collateral and
///         sell it" or "borrow, swap, deposit" order had no zero-inventory DEX
///         filler. {AggregatorFillSolver.executeItemFill} drives a one-order
///         `matchSettle` plan instead (TAKE items → pull → pre-send → route →
///         deliver → MAKE items), with zero inventory and zero Settlement bytes.
contract AggregatorItemFillTest is AggregatorFillSolverTest {
    ItemFillTaker taker;
    ItemFillDeposit depositor;

    uint256 constant LATE_DEPOSIT = 1 << 1; // item 1 (the deposit) runs after delivery

    function setUp() public override {
        super.setUp();
        taker = new ItemFillTaker(address(permit3));
        depositor = new ItemFillDeposit(address(permit3), address(settlement));
        // The "lender" holds what the maker withdraws / borrows.
        tA.mint(address(taker), 1_000e18);
    }

    /// @dev Leverage-shaped order: TAKE (borrow `AMOUNT_IN` tA) → sold for tB →
    ///      MAKE (deposit the delivered `AMOUNT_OUT` tB). The maker's wallet never
    ///      funds the input.
    function _itemOrder(uint256 nonce, uint256 policy) internal returns (Order memory o) {
        Item[] memory items = new Item[](2);
        items[0] = Item({
            op: ItemOp.TAKE,
            module: address(taker),
            amount: AMOUNT_IN,
            recipient: address(0),
            data: abi.encode(address(tA), AMOUNT_IN)
        });
        items[1] =
            Item({op: ItemOp.MAKE, module: address(depositor), amount: AMOUNT_OUT, recipient: address(0), data: abi.encode(address(tB))});
        o = _order(nonce);
        o.items = PackedEncode.items(items);
        o.timing = ItemPolicy.pack(o.timing, policy);
        _authItems(o, items[0].data);
    }

    function _authItems(Order memory, bytes memory takeData) internal {
        vm.startPrank(maker);
        tB.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(depositor), address(tB), uint160(AMOUNT_OUT), 0);
        permit3.approveTaker(
            address(settlement), address(taker), keccak256(takeData), uint160(AMOUNT_IN), uint48(block.timestamp + 1 hours)
        );
        vm.stopPrank();
    }

    function _itemFill(Order memory o, uint256 lateItems) internal returns (bool ok, bytes memory ret) {
        bytes memory sig = _sign(o);
        (ok, ret) = address(aggSolver).call(
            abi.encodeCall(
                IAggregatorItemFill.executeItemFill,
                (o, sig, AMOUNT_IN, _plan(address(aggSolver), AMOUNT_OUT), bytes(""), lateItems)
            )
        );
    }

    /// AGG-6: a borrow → swap → deposit order fills through the aggregator with zero
    /// inventory. Fails on the pre-fix solver (no item-capable entry; `executeFill`
    /// reverts `ReverseModeRequiresNoItems`).
    function test_audit_AGG_6_itemOrderFillsZeroInventory() public {
        Order memory o = _itemOrder(1, ItemPolicy.ANY);
        uint256 makerA = tA.balanceOf(maker);
        uint256 makerB = tB.balanceOf(maker);

        (bool ok, bytes memory ret) = _itemFill(o, LATE_DEPOSIT);
        assertTrue(ok, string(ret));

        assertEq(tA.balanceOf(maker), makerA, "the input came from the TAKE item, not the wallet");
        assertEq(tB.balanceOf(maker), makerB, "the delivery was deposited straight on");
        assertEq(tB.balanceOf(address(depositor)), AMOUNT_OUT, "the MAKE item deposited the delivered output");
        assertEq(tA.balanceOf(address(router)), AMOUNT_IN, "the route sold the borrowed input");
        assertEq(tB.balanceOf(address(this)), AMOUNT_IN - AMOUNT_OUT, "caller keeps the spread");
        assertEq(tA.balanceOf(address(aggSolver)), 0, "zero inventory: no input residue");
        assertEq(tB.balanceOf(address(aggSolver)), 0, "zero inventory: no output residue");
        assertEq(tA.balanceOf(address(settlement)), 0, "pool flat");
        assertEq(tB.balanceOf(address(settlement)), 0, "pool flat");
        assertEq(settlement.filled(_hashOrder(o)), AMOUNT_IN, "order fully filled");
    }

    /// AGG-6: the item-free entry still refuses the same order — the core's
    /// `PostInputs` mode is item-free — which is why the second entry exists.
    function test_audit_AGG_6_executeFillStillRefusesItems() public {
        Order memory o = _itemOrder(2, ItemPolicy.ANY);
        bytes memory sig = _sign(o);
        RoutePlan memory plan = _plan(address(aggSolver), AMOUNT_OUT);
        vm.expectRevert(Base.ReverseModeRequiresNoItems.selector);
        aggSolver.executeFill(o, sig, AMOUNT_IN, plan, "");
    }

    /// AGG-6: the maker's item policy is the core's to enforce — a caller-chosen
    /// placement that runs item 1 ahead of item 0 on an ORDERED order reverts.
    function test_audit_AGG_6_itemPolicyStillEnforcedByCore() public {
        Order memory o = _itemOrder(3, ItemPolicy.ORDERED);
        // Running BOTH items early puts the deposit (item 1) BEFORE delivery, which
        // ORDERED allows; but flagging item 0 late runs item 1 first, which it does not.
        (bool ok, bytes memory ret) = _itemFill(o, 1 << 0);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(Base.ItemPolicyViolated.selector, uint256(0), uint256(1)));

        // The honest placement fills the same ORDERED order.
        (ok, ret) = _itemFill(o, LATE_DEPOSIT);
        assertTrue(ok, string(ret));
        assertEq(tB.balanceOf(address(depositor)), AMOUNT_OUT);
    }

    /// AGG-6: an out-of-range `lateItems` bit is refused before anything moves.
    function test_audit_AGG_6_lateItemsOutOfRangeReverts() public {
        Order memory o = _itemOrder(4, ItemPolicy.ANY);
        (bool ok, bytes memory ret) = _itemFill(o, 1 << 2);
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(AggregatorFillSolver.BadItemSchedule.selector));
    }

    /// AGG-6: the route's own floor still binds on the netted path.
    function test_audit_AGG_6_itemFillHonoursMinOut() public {
        Order memory o = _itemOrder(5, ItemPolicy.ANY);
        bytes memory sig = _sign(o);
        RoutePlan memory plan = _plan(address(aggSolver), AMOUNT_IN + 1);
        vm.expectRevert(
            _wrapped(abi.encodeWithSelector(AggregatorFillSolver.InsufficientOutput.selector, AMOUNT_IN, AMOUNT_IN + 1))
        );
        aggSolver.executeItemFill(o, sig, AMOUNT_IN, plan, "", LATE_DEPOSIT);
    }

    /// AGG-6: an item-free order is a valid (if unneeded) shape for the new entry.
    function test_audit_AGG_6_itemFreeOrderAlsoFillsViaMatch() public {
        Order memory o = _order(6);
        bytes memory sig = _sign(o);
        aggSolver.executeItemFill(o, sig, AMOUNT_IN, _plan(address(aggSolver), AMOUNT_OUT), "", 0);
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "maker paid");
        assertEq(tB.balanceOf(address(this)), AMOUNT_IN - AMOUNT_OUT, "spread to the caller");
        assertEq(tB.balanceOf(address(aggSolver)), 0);
    }

    /// AGG-6: the new callback is bound like {onFill} — only the EXECUTOR, only
    /// while armed by {executeItemFill}; and neither entry's arming opens the other's
    /// callback.
    function test_audit_AGG_6_onMatchRouteIsGated() public {
        FillRoute memory r = _anyRoute();
        vm.expectRevert(AggregatorFillSolver.OnlyExecutor.selector);
        aggSolver.onMatchRoute(r);

        vm.prank(address(settlement.EXECUTOR()));
        vm.expectRevert(AggregatorFillSolver.NotArmed.selector);
        aggSolver.onMatchRoute(r);
    }

    /// AGG-6: the netted path keeps the delta discipline — a self-signed order on an
    /// open instance cannot make the plan pay its maker out of what the solver
    /// already holds (only this fill's proceeds are ever pushed to the pool).
    function test_audit_AGG_6_itemFillCannotReachResidue() public {
        tB.mint(address(aggSolver), 50e18); // a balance floor / stranded leg
        uint256 pk = 0xA77;
        address attacker = vm.addr(pk);
        tA.mint(attacker, 1e18);
        vm.startPrank(attacker);
        tA.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(tA), type(uint160).max, 0);
        vm.stopPrank();

        Order memory o = _plainOrder(77, address(tA), address(tB), 1e18, 50e18);
        o.maker = attacker;
        bytes memory sig = _signWith(o, pk);
        RoutePlan memory plan = _planFor(1e18, address(aggSolver), 0, NO_PATCH);
        // A stranger cannot drive the instance at all (gated-only since 2026-10)…
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(AggregatorFillSolver.NotOperator.selector, attacker));
        aggSolver.executeItemFill(o, sig, 1e18, plan, "", 0);
        // …and an OPERATOR submitting the attacker's hostile order still cannot
        // pay it out of the parked balance: the delta bound holds.
        vm.expectRevert();
        aggSolver.executeItemFill(o, sig, 1e18, plan, "", 0);
        assertEq(tB.balanceOf(address(aggSolver)), 50e18, "residue untouched");
        assertEq(tB.balanceOf(attacker), 0);
    }

    /// AGG-6: a delta-verify order is refused up front — the netted path cannot
    /// verify a recipient delta.
    function test_audit_AGG_6_directOrderRefusedOnItemPath() public {
        address[] memory ops = new address[](1);
        ops[0] = address(this);
        AggregatorFillSolver g =
            new AggregatorFillSolver(address(settlement), ops, _noSplit());
        Order memory o = _order(7);
        o.timing |= uint256(1) << 104;
        o.exclusiveFiller = address(g);
        bytes memory sig = _sign(o);
        RoutePlan memory plan = _plan(address(g), AMOUNT_OUT);
        vm.expectRevert(AggregatorFillSolver.DirectNotMatchable.selector);
        g.executeItemFill(o, sig, AMOUNT_IN, plan, "", 0);
    }
}
