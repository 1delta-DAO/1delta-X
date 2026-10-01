// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {UsdrifInventorySolver} from "@solvers/inventory/UsdrifInventorySolver.sol";

import {IMocQueue} from "../../modules/redeem/usdrif/src/interfaces/IMoc.sol";
import {UsdrifInventorySolverTest} from "./UsdrifInventorySolver.t.sol";

/// @dev The permissionless MoC guard entry the 2026-09-30 RIF findings rely on:
///      `execute()` is `external notPaused nonReentrant` with no access control,
///      and as the guard is the caller of `MocQueue.execute`, the queue's
///      `onlyMocMultiCollateralGuard` gate is satisfied for ANY caller.
interface IMocGuardExecute {
    function execute() external;
}

/// @dev RIF-1 venue: models a whitelisted router driven along an attacker pool
///      whose hook token runs inside `sell`'s window. It runs the REAL guard (MoC
///      delivers the solver's own redemption RIF) and pulls that RIF out through the
///      just-granted allowance. Only the venue wrapper is modelled.
contract AuditQueueOffsetVenue {
    address public immutable guard;
    address public immutable rif;

    constructor(address _guard, address _rif) {
        guard = _guard;
        rif = _rif;
    }

    function run(address solver, address attacker) external {
        IMocGuardExecute(guard).execute();
        IERC20(rif).transferFrom(solver, attacker, IERC20(rif).balanceOf(solver));
    }

    /// @dev RIF-1.v1 / RIF-2.v1 shape: take `amountIn` of `tokenIn` to the attacker
    ///      and let the queue pay the solver its own proceeds in `tokenOut` instead.
    function divert(address tokenIn, uint256 amountIn, address solver, address attacker) external {
        IERC20(tokenIn).transferFrom(solver, attacker, amountIn);
        IMocGuardExecute(guard).execute();
    }
}

/// @dev RIF-2: a maker-chosen MAKE module. The core calls `makeOnBehalf` on it;
///      the fallback ignores the arguments and runs MoC's queue mid-fill.
contract AuditGuardKickerModule {
    address public immutable guard;

    constructor(address _guard) {
        guard = _guard;
    }

    fallback() external {
        IMocGuardExecute(guard).execute();
    }
}

/// @dev A received token with a transfer hook that runs MoC's queue — the
///      defence-in-depth case for the fill bracket: no item, yet code runs inside
///      the measured fill.
contract AuditQueueHookToken {
    string public constant name = "HOOK";
    string public constant symbol = "HOOK";
    uint8 public constant decimals = 18;
    address public immutable guard;
    bool public armed;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(address _guard) {
        guard = _guard;
    }

    function arm(bool on) external {
        armed = on;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        if (armed) IMocGuardExecute(guard).execute();
        return true;
    }
}

/// @title UsdrifInventorySolverAudit20260930Test
/// @notice Regression tests for the 2026-09-30 audit findings on
///         {UsdrifInventorySolver}: RIF-1 (and its tokenOut variants), RIF-2,
///         PERIPH-1.v2 and RIF-4. Each asserts the SAFE end state, and each fails
///         on the pre-fix source (the exploit succeeds, or — for the new operator
///         bound and the delta-verify path — the entry the test drives did not
///         exist / reverted `DeltaTooLow`).
contract UsdrifInventorySolverAudit20260930Test is UsdrifInventorySolverTest {
    address internal attacker = makeAddr("attacker");

    /// @dev Queue a redemption of the solver's USDRIF and make it executable.
    function _queueOwnRedemption(uint256 usdrifAmount, uint256 qACmin) internal returns (uint256 opId) {
        deal(USDRIF, address(inv), usdrifAmount);
        vm.fee(0.024 gwei);
        vm.prank(operator);
        opId = inv.initiateRedemption(type(uint256).max, qACmin);
        // Executable at queuedBlk + 1; roll without warping so MoC's oracle stays fresh.
        vm.roll(block.number + 2);
    }

    // ═══════════════════════════ RIF-1 ═══════════════════════════

    /// RIF-1: the PoC. A venue hook runs the permissionless guard inside `sell`,
    /// MoC delivers the solver's own redemption RIF, the venue pulls it out, and
    /// the measured spend nets to zero — no rate floor, no window charge. The
    /// queue-head bracket now refuses the call, and nothing leaves.
    function test_audit_RIF_1_sellOffsetByInWindowQueueDelivery_reverts() public {
        uint256 opId = _queueOwnRedemption(1_000e18, 0);
        AuditQueueOffsetVenue venue = new AuditQueueOffsetVenue(MOC_GUARD, RIF);
        inv.setAggregator(address(venue), true);

        bytes memory data = abi.encodeCall(AuditQueueOffsetVenue.run, (address(inv), attacker));
        vm.prank(operator);
        vm.expectRevert(UsdrifInventorySolver.QueueMovedDuringMeasurement.selector);
        inv.sell(address(venue), RIF, USDT0, RIF_SELL_BUDGET, 0, data);

        assertEq(IERC20(RIF).balanceOf(attacker), 0, "no RIF left the solver");
        assertLe(IMocQueue(MOC_QUEUE).firstOperId(), opId, "the redemption is still queued");
        (, uint96 used,) = inv.outflowBudget(RIF);
        assertEq(used, 0, "nothing was spent");
    }

    /// RIF-1.v1: the tokenOut side of the same window. On a USDT0→RIF route, a
    /// venue sends the solver's USDT0 to the attacker and lets the queue pay the
    /// solver its OWN redemption RIF, which would pass the route rate as "sale
    /// proceeds". Refused.
    function test_audit_RIF_1_v1_sellTokenOutInflatedByQueueDelivery_reverts() public {
        _queueOwnRedemption(1_000e18, 0); // ~15k RIF due to the solver
        inv.setSellRoute(USDT0, RIF, 1e31, 500e6); // ≥ 10 RIF per USDT0
        AuditQueueOffsetVenue venue = new AuditQueueOffsetVenue(MOC_GUARD, RIF);
        inv.setAggregator(address(venue), true);

        bytes memory data =
            abi.encodeCall(AuditQueueOffsetVenue.divert, (USDT0, uint256(500e6), address(inv), attacker));
        vm.prank(operator);
        vm.expectRevert(UsdrifInventorySolver.QueueMovedDuringMeasurement.selector);
        inv.sell(address(venue), USDT0, RIF, 500e6, 0, data);

        assertEq(IERC20(USDT0).balanceOf(attacker), 0, "no USDT0 left for the solver's own RIF");
        assertEq(IERC20(USDT0).balanceOf(address(inv)), INVENTORY, "inventory intact");
    }

    /// RIF-2.v1: the refund variant — a deliberately failing redemption refunds
    /// the solver's USDRIF inside a USDT0→USDRIF sell and would count as proceeds.
    function test_audit_RIF_2_v1_sellTokenOutInflatedByFailedOpRefund_reverts() public {
        _queueOwnRedemption(1_000e18, 1e30); // unmeetable floor: the op fails and refunds
        inv.setSellRoute(USDT0, USDRIF, 1e30, 500e6); // ≥ 1 USDRIF per USDT0
        AuditQueueOffsetVenue venue = new AuditQueueOffsetVenue(MOC_GUARD, RIF);
        inv.setAggregator(address(venue), true);

        bytes memory data =
            abi.encodeCall(AuditQueueOffsetVenue.divert, (USDT0, uint256(500e6), address(inv), attacker));
        vm.prank(operator);
        vm.expectRevert(UsdrifInventorySolver.QueueMovedDuringMeasurement.selector);
        inv.sell(address(venue), USDT0, USDRIF, 500e6, 0, data);

        assertEq(IERC20(USDT0).balanceOf(attacker), 0, "no USDT0 left for the refunded escrow");
    }

    /// The bracket costs honest sells nothing: a real SwapRouter02 recycle with a
    /// redemption still queued (but not executed in-window) goes through.
    function test_audit_RIF_1_honestSellWithQueuedOpStillWorks() public {
        deal(RIF, address(inv), 10_000e18);
        uint256 opId = _queueOwnRedemption(1_000e18, 0);
        vm.prank(operator);
        uint256 out =
            inv.sell(SWAP_ROUTER_02, RIF, USDT0, 10_000e18, 0, _uniV3SellData(RIF, USDT0, RIF_USDT0_FEE, 10_000e18));
        assertGt(out, 0, "sold");
        assertLe(IMocQueue(MOC_QUEUE).firstOperId(), opId, "queue untouched by the honest sale");
    }

    // ═══════════════════════════ RIF-2 ═══════════════════════════

    /// RIF-2: the PoC shape. A self-signed 1-wei USDRIF order carries a MAKE item
    /// whose module runs the queue; a queued failing redemption refunds ~2000
    /// USDRIF to the solver inside the fill, and `got` would count it, clearing
    /// fillMinRate while the whole USDT0 inventory leaves. Item-bearing orders are
    /// now refused before anything moves.
    function test_audit_RIF_2_itemOrderCannotTriggerQueueRefundInsideFill() public {
        _queueOwnRedemption(2_000e18, 1e30);
        AuditGuardKickerModule kicker = new AuditGuardKickerModule(MOC_GUARD);

        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.MAKE, module: address(kicker), amount: 1, recipient: address(0), data: ""});

        // The compromised operator signs as its own maker: 1 wei of USDRIF in,
        // the whole inventory out.
        Order memory rug = _usdrifOrder(77);
        rug.legsIn = _legsIn1(USDRIF, 1);
        rug.legsOut = _legsOut1(USDT0, INVENTORY);
        rug.items = PackedEncode.items(items);
        bytes memory sig = _sign(rug);

        vm.prank(operator);
        vm.expectRevert(UsdrifInventorySolver.UnsupportedFillShape.selector);
        inv.executeFill(rug, sig, 1, NO_BOUND);

        assertEq(IERC20(USDT0).balanceOf(address(inv)), INVENTORY, "inventory intact");
    }

    /// RIF-2 defence in depth: even with NO item, any code that runs inside the
    /// fill (here a hook on the received token) and executes MoC's queue makes the
    /// measurement non-exclusive — the fill is refused.
    function test_audit_RIF_2_fillRefusedWhenQueueMovesInsideIt() public {
        _queueOwnRedemption(1_000e18, 1e30);
        AuditQueueHookToken hook = new AuditQueueHookToken(MOC_GUARD);
        inv.setFillRoute(USDT0, address(hook), 1e30);

        hook.mint(maker, USDRIF_IN);
        vm.startPrank(maker);
        hook.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(hook), type(uint160).max, 0);
        vm.stopPrank();
        hook.arm(true);

        Order memory o = _usdrifOrder(78);
        o.legsIn = _legsIn1(address(hook), USDRIF_IN);
        bytes memory sig = _sign(o);

        vm.prank(operator);
        vm.expectRevert(UsdrifInventorySolver.QueueMovedDuringMeasurement.selector);
        inv.executeFill(o, sig, USDRIF_IN, NO_BOUND);
    }

    // ═══════════════════════════ PERIPH-1.v2 ═══════════════════════════

    /// PERIPH-1.v2: the operator's own price bound. A fill that would move more
    /// inventory out than the operator quoted reverts — on both fill entries — and
    /// one within the bound fills.
    function test_audit_PERIPH_1_v2_operatorMaxSpentBoundsTheFill() public {
        Order memory order = _usdrifOrder(79);
        bytes memory sig = _sign(order);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(UsdrifInventorySolver.SpentAboveOperatorBound.selector, USDT0_OUT, USDT0_OUT - 1)
        );
        inv.executeFill(order, sig, USDRIF_IN, USDT0_OUT - 1);

        vm.fee(0.024 gwei);
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(UsdrifInventorySolver.SpentAboveOperatorBound.selector, USDT0_OUT, USDT0_OUT - 1)
        );
        inv.executeFillAndRedeem(order, sig, USDRIF_IN, USDT0_OUT - 1, QAC_MIN);

        vm.prank(operator);
        uint256 paid = inv.executeFill(order, sig, USDRIF_IN, USDT0_OUT)[0];
        assertEq(paid, USDT0_OUT, "fills at exactly the quoted bound");
    }

    // ═══════════════════════════ RIF-4 ═══════════════════════════

    /// RIF-4: the app signs delta-verify orders (`timing` bit 104) exclusive to a
    /// named solver. Naming the inventory solver used to make every order revert
    /// `DeltaTooLow` (it only filled through the pull path); it now delivers by its
    /// own callback, measured and capped exactly like a pull.
    function test_audit_RIF_4_deltaVerifyOrderNamingTheSolverFills() public {
        Order memory order = _usdrifOrder(80);
        order.timing |= uint256(1) << 104;
        order.exclusiveFiller = address(inv);
        bytes memory sig = _sign(order);

        vm.prank(operator);
        uint256 paid = inv.executeFill(order, sig, USDRIF_IN, USDT0_OUT)[0];

        assertEq(paid, USDT0_OUT, "priced amount delivered");
        assertEq(IERC20(USDT0).balanceOf(maker), USDT0_OUT, "maker received USDT0 directly");
        assertEq(IERC20(USDRIF).balanceOf(address(inv)), USDRIF_IN, "solver received the USDRIF");
        assertEq(IERC20(USDT0).balanceOf(address(inv)), INVENTORY - USDT0_OUT, "inventory drawn by exactly the leg");
        (, uint96 used,) = inv.outflowBudget(USDT0);
        assertEq(used, USDT0_OUT, "the callback delivery is charged to the window like a pull");
    }

    /// RIF-4: the delivery callback is not a payout primitive — only the executor,
    /// only while a fill this contract started is in flight.
    function test_audit_RIF_4_deliveryCallbackIsGated() public {
        uint256[] memory amts = new uint256[](1);
        amts[0] = 1_000e6;
        address[] memory to = new address[](1);
        to[0] = attacker;
        bytes memory data = abi.encode(USDT0, to);

        vm.expectRevert(UsdrifInventorySolver.OnlyExecutor.selector);
        inv.onSettlementFill(bytes32(0), 0, 0, 0, amts, amts, data);

        vm.prank(address(settlement.EXECUTOR()));
        vm.expectRevert(UsdrifInventorySolver.NotArmed.selector);
        inv.onSettlementFill(bytes32(0), 0, 0, 0, amts, amts, data);

        assertEq(IERC20(USDT0).balanceOf(attacker), 0, "nothing paid out");
    }
}
