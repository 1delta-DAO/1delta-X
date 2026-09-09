// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {Order, Item, ItemOp, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";
import {PositionFillModule} from "@lib/PositionFillModule.sol";

import {IAaveV3Pool} from "../../src/interfaces/IAaveV3.sol";
import {AaveModulesBase} from "../shared/AaveModulesBase.t.sol";

/// @dev NETTING A POSITION-SIZED EXIT — the case that decides whether `fillModule`
/// belongs on the batch path at all.
///
///   Alice: position-sized exit. Sells her whole live aWETH position for USDC.
///   Bob:   a plain limit order. Buys WETH, pays USDC.
///
/// There is a coincidence of wants, so `matchSettle` should clear it with **zero
/// solver capital**: Alice's withdraw item puts WETH in the pool, Bob's USDC pull
/// funds Alice's payout, and each side is delivered out of the other's contribution.
///
/// ⚠ THE ASYMMETRY THAT MAKES THIS DELICATE. Alice's size is resolved on-chain at
/// fill time; Bob's is a signed constant. They can only net if Alice's resolved
/// delta is at least what Bob is being delivered. So the recipe is:
///
///   • size the FIXED side at or below the floor you will accept from the dynamic
///     one, never at the expectation — a surplus is solver profit, a shortfall is a
///     late revert;
///   • pass the QUOTED delta in `fillAmounts[i]` for the dynamic order, which is the
///     only staleness bound on this path (`filled[hash]` does not move when a
///     lending index ticks, so a `MatchRaceGuard` equality check cannot see it).
///
/// Both drift directions then fail at OPEN rather than mid-plan: growth trips the
/// solver's `PositionExceedsQuote`, and a shrink below the maker's `minFillAnchor`
/// trips the core's `FillTooSmall`.
contract PositionSizedMatchTest is AaveModulesBase {
    PositionFillModule internal fillModule;

    uint256 internal bobPk = 0xB0B;
    address internal bob = vm.addr(bobPk);

    uint256 internal constant POSITION = 1.3 ether; //   Alice's live aWETH
    uint256 internal constant CAP = 1.5 ether; //        her signed ceiling
    uint256 internal constant ALICE_USDC = 3_000e6; //   what the cap is worth to her
    uint256 internal constant BOB_WETH = 1.2 ether; //   sized BELOW Alice's floor
    uint256 internal constant BOB_USDC = 2_700e6; //     what Bob pays for it

    uint256 internal atOpenGas; //                       recorded for the A/B below

    function setUp() public override {
        super.setUp();
        fillModule = new PositionFillModule();
        vm.label(address(fillModule), "positionFillModule");
        vm.label(bob, "bob");
    }

    // ──────────────────── Orders ────────────────────

    function _aliceExit(uint256 nonce, uint256 floor) internal view returns (Order memory order) {
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.TAKE,
            module: address(withdrawModule),
            amount: CAP,
            recipient: address(0), //           into the shared pool
            data: abi.encode(AAVE_POOL, WETH, aWETH)
        });
        order = _order(maker, nonce, WETH, USDC, CAP, ALICE_USDC, items);
        order.fillModule = address(fillModule);
        order.fillTotal = CAP;
        order.minFillAnchor = floor; //         the maker's own shrink bound
    }

    function _bobBuy(uint256 nonce) internal view returns (Order memory order) {
        // Plain order, no items: Bob pays USDC in, takes WETH out.
        order = _order(bob, nonce, USDC, WETH, BOB_USDC, BOB_WETH, new Item[](0));
    }

    function _signAs(Order memory o, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), _hashOrder(o)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _approveAlice() internal {
        bytes memory wd = abi.encode(AAVE_POOL, WETH, aWETH);
        vm.startPrank(maker);
        IERC20(aWETH).approve(address(withdrawModule), type(uint256).max);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), WETH, uint160(CAP), 0);
        permit3.approveTaker(address(settlement), address(withdrawModule), keccak256(wd), uint160(CAP), 0);
        vm.stopPrank();
    }

    function _approveBob() internal {
        deal(USDC, bob, BOB_USDC);
        vm.startPrank(bob);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDC, uint160(BOB_USDC), 0);
        vm.stopPrank();
    }

    /// @dev Alice's withdraw feeds the pool; Bob's pull funds Alice's payout; then
    /// each is delivered out of the other's contribution. No solver capital, and no
    /// ordering of whole orders would work — Alice cannot be paid before Bob pays,
    /// and Bob cannot be delivered before Alice withdraws.
    function _schedule() internal pure returns (uint256[] memory s) {
        s = new uint256[](4);
        s[0] = MatchStep.pack(MatchStep.ITEM, 0, 0); //  Alice: withdraw WETH → pool
        s[1] = MatchStep.pack(MatchStep.PULL, 1, 0); //  Bob:   USDC → pool
        s[2] = MatchStep.pack(MatchStep.DELIVER, 0, 0); // pool → Alice: USDC
        s[3] = MatchStep.pack(MatchStep.DELIVER, 1, 0); // pool → Bob:   WETH
    }

    function _plan(Order memory a, Order memory b, uint256 aFill, address profit)
        internal
        view
        returns (MatchPlan memory)
    {
        Order[] memory orders = new Order[](2);
        (orders[0], orders[1]) = (a, b);
        bytes[] memory sigs = new bytes[](2);
        (sigs[0], sigs[1]) = (_signAs(a, makerPk), _signAs(b, bobPk));
        uint256[] memory fills = new uint256[](2);
        (fills[0], fills[1]) = (aFill, BOB_USDC);
        return MatchPlan({
            orders: orders,
            sigs: sigs,
            fillAmounts: fills,
            takerDatas: new bytes[](2),
            schedule: _schedule(),
            callTargets: new address[](0),
            callDatas: new bytes[](0),
            profitRecipient: profit
        });
    }

    // ──────────────────── The netted match ────────────────────

    function test_match_positionSizedExit_netsAgainstAPlainBuy_zeroSolverCapital() public {
        _seedAWethPosition(POSITION);
        _approveAlice();
        _approveBob();

        Order memory a = _aliceExit(1, BOB_WETH); // floor = what Bob needs
        Order memory b = _bobBuy(2);

        // Quote the dynamic side, then bound it with its own resolved size.
        (uint256 delta,,) = lens.previewFill(a, a.fillTotal, solver, "");
        uint256 live = IERC20(aWETH).balanceOf(maker);
        assertEq(delta, live, "Alice's size comes from her live position");
        assertGe(delta, BOB_WETH, "and it covers what Bob is delivered");

        assertEq(IERC20(WETH).balanceOf(solver), 0, "solver starts flat");
        assertEq(IERC20(USDC).balanceOf(solver), 0, "solver starts flat");
        uint256 aliceUsdcBefore = IERC20(USDC).balanceOf(maker);

        vm.prank(solver);
        uint256 g0 = gasleft();
        settlement.matchSettle(_plan(a, b, delta, solver));
        uint256 matchGas = g0 - gasleft();

        // Alice: position fully exited, paid pro rata for ALL of it.
        uint256 alicePaid = (delta * ALICE_USDC + CAP - 1) / CAP; // ceilDiv, as Pricing does
        assertLe(IERC20(aWETH).balanceOf(maker), 1, "Alice's position fully exited");
        assertEq(IERC20(USDC).balanceOf(maker) - aliceUsdcBefore, alicePaid, "Alice paid pro rata");
        assertEq(IERC20(WETH).balanceOf(maker), 0, "and nothing came back unconverted");

        // Bob: got exactly his signed amount.
        assertEq(IERC20(WETH).balanceOf(bob), BOB_WETH, "Bob bought his signed WETH");
        assertEq(IERC20(USDC).balanceOf(bob), 0, "Bob paid his signed USDC");

        // The solver never fronted a token — its P&L is the spread, in both assets.
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "pool flat in WETH");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "pool flat in USDC");

        console2.log("=== netted position-sized exit vs plain buy ===");
        console2.log("  Alice sold (live position) :", delta);
        console2.log("  Alice received USDC        :", alicePaid);
        console2.log("  Bob   received WETH        :", BOB_WETH);
        console2.log("  Bob   paid USDC            :", BOB_USDC);
        console2.log("  solver WETH surplus        :", IERC20(WETH).balanceOf(solver));
        console2.log("  solver USDC balance        :", IERC20(USDC).balanceOf(solver));
        console2.log("  gas, whole match           :", matchGas);
    }

    /// @dev THE SHRINK DIRECTION, which `fillAmounts` does NOT bound — it is a
    /// ceiling, not a floor. The maker's `minFillAnchor` is what closes it, and it
    /// reverts at OPEN (phase 1) rather than leaving Bob's delivery unfunded halfway
    /// through the plan. Without it the plan would proceed and fail late.
    function test_match_positionBelowTheFloor_revertsAtOpen() public {
        _seedAWethPosition(1.0 ether); // below Bob's 1.2 requirement
        _approveAlice();
        _approveBob();

        Order memory a = _aliceExit(3, BOB_WETH); // floor = 1.2
        Order memory b = _bobBuy(4);
        uint256 live = IERC20(aWETH).balanceOf(maker);
        assertLt(live, BOB_WETH, "the position cannot cover Bob");

        // Build the plan BEFORE `expectRevert`: `_plan` signs, and signing reads
        // `settlement.DOMAIN_SEPARATOR()` — an external call that would otherwise be
        // the "next call" the cheatcode latches onto.
        MatchPlan memory plan = _plan(a, b, live, solver);
        vm.prank(solver);
        vm.expectRevert(); // FillTooSmall — the core checks minFillAnchor on the delta
        uint256 g0 = gasleft();
        settlement.matchSettle(plan);
        atOpenGas = g0 - gasleft();

        assertEq(IERC20(aWETH).balanceOf(maker), live, "nothing moved");
        assertEq(IERC20(USDC).balanceOf(bob), BOB_USDC, "Bob's funds untouched");
    }

    /// @dev The two failure modes, measured side by side from the same state. Both
    /// are atomic, so the MAKERS are indifferent — this number is entirely the
    /// solver's, and it is the whole argument for `minFillAnchor` on an order
    /// intended for netting.
    function test_gas_failAtOpen_vs_failLate() public {
        test_match_positionBelowTheFloor_revertsAtOpen();
        uint256 atOpen = atOpenGas;

        // Same drift and the same plan shape, from the state the first half left —
        // it reverted, so nothing was consumed. The only change is the floor.
        Order memory a = _aliceExit(7, 0);
        Order memory b = _bobBuy(8);
        uint256 live = IERC20(aWETH).balanceOf(maker);
        MatchPlan memory plan = _plan(a, b, live, solver);

        vm.prank(solver);
        vm.expectRevert();
        uint256 g0 = gasleft();
        settlement.matchSettle(plan);
        uint256 late = g0 - gasleft();

        console2.log("=== cost of the same drift, to the SOLVER ===");
        console2.log("  fail at open (minFillAnchor) :", atOpen);
        console2.log("  fail late  (no floor)        :", late);
        assertGt(late, atOpen, "failing late costs the solver strictly more");
    }

    /// @dev And the same shape WITHOUT a floor is exactly the trap: it opens fine and
    /// dies in phase 2 when Bob's delivery finds the pool short. Same outcome for the
    /// makers (nothing moves), but the solver has paid for signatures, the venue read
    /// and a real `pool.withdraw` before finding out. This is the case
    /// `MatchRaceGuard` cannot pre-empt, and the reason `minFillAnchor` is not
    /// optional on an order intended for netting.
    function test_match_noFloor_failsLateInsteadOfAtOpen() public {
        _seedAWethPosition(1.0 ether);
        _approveAlice();
        _approveBob();

        Order memory a = _aliceExit(5, 0); //  no floor
        Order memory b = _bobBuy(6);
        uint256 live = IERC20(aWETH).balanceOf(maker);

        MatchPlan memory plan = _plan(a, b, live, solver);
        vm.prank(solver);
        vm.expectRevert(); // the pool is short when DELIVER(Bob) runs
        settlement.matchSettle(plan);

        assertEq(IERC20(aWETH).balanceOf(maker), live, "still atomic: nothing moved");
    }
}
