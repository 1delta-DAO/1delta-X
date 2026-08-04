// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "@core/settlement/Base.sol";
import {OrderState} from "@core/settlement/OrderState.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {
    Settlement, Order, Item, ItemOp, MatchPlan, MatchStep, OrderSide, Validator
} from "@core/settlement/Settlement.sol";
import {IOrderValidator} from "@core/interfaces/IOrderValidator.sol";
import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

/// @dev A contract solver for the imbalanced case: it calls `matchSettle` (so it is
///      the `msg.sender` the surplus is swept to) and, during a `CALL` step,
///      deposits its own inventory of the net-deficit token INTO Settlement. It
///      holds no Permit3 allowance — deliveries come from the pool, so the solver
///      only ever PUSHES the residual in.
contract MockSolver {
    Settlement immutable settlement;

    constructor(Settlement s) {
        settlement = s;
    }

    /// @dev Ignores the return — as a real solver that only cares about the token
    ///      balances it ends up holding would. Forwarding all three arrays instead
    ///      would make this mock ~300 bytes larger for no behavioural gain.
    function run(MatchPlan calldata p) external {
        settlement.matchSettle(p);
    }

    /// @dev Called via the allowance-less EXECUTOR mid-schedule: front the deficit.
    function cover(address token, uint256 amount) external {
        IERC20(token).transfer(address(settlement), amount);
    }
}

/// @dev A mock DEX with output-token stock: pulls `amtIn` of `tokenIn` from the
///      caller and pays `amtOut` of `tokenOut` back — models the solver converting
///      the pre-sent surplus into the deficit it must return.
contract MockDex {
    function swap(address tokenIn, uint256 amtIn, address tokenOut, uint256 amtOut) external {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amtIn);
        IERC20(tokenOut).transfer(msg.sender, amtOut);
    }
}

/// @dev A ZERO-CAPITAL solver: it holds no inventory. A `PRESEND` step hands it the
///      net surplus, it swaps that into the deficit via `dex` in the following
///      `CALL` step, and deposits the deficit into Settlement — never fronting a
///      cent of its own.
contract PresendSolver {
    Settlement immutable settlement;
    MockDex immutable dex;

    constructor(Settlement s, MockDex d) {
        settlement = s;
        dex = d;
    }

    /// @dev Ignores the return — as a real solver that only cares about the token
    ///      balances it ends up holding would. Forwarding all three arrays instead
    ///      would make this mock ~300 bytes larger for no behavioural gain.
    function run(MatchPlan calldata p) external {
        settlement.matchSettle(p);
    }

    /// @dev The pre-sent `surplusToken` sits in THIS contract; swap it for the
    ///      `deficitToken` and deposit the deficit into Settlement.
    function swapAndCover(address surplusToken, uint256 surplusAmt, address deficitToken, uint256 deficitAmt)
        external
    {
        IERC20(surplusToken).approve(address(dex), surplusAmt);
        dex.swap(surplusToken, surplusAmt, deficitToken, deficitAmt);
        IERC20(deficitToken).transfer(address(settlement), deficitAmt);
    }
}

/// @dev A validator that gates on the filler-supplied `takerData` — passes iff the
///      blob decodes to the sentinel. Proves `MatchPlan.takerDatas` threads the
///      per-order blob into each order's validators.
contract TakerDataValidator is IOrderValidator {
    uint256 constant SENTINEL = 42;

    function validate(Order calldata, address, bytes calldata, bytes calldata takerData)
        external
        pure
        returns (bool)
    {
        return takerData.length == 32 && abi.decode(takerData, (uint256)) == SENTINEL;
    }
}

/// @dev `matchSettle` as a plain coincidence-of-wants engine — the behaviours the
/// dedicated `batchSettle` entry point used to own, now expressed as the schedule
/// `[PULL…, PRESEND…, CALL, DELIVER…]`. Two mirror makers clear against each other
/// with no AMM: Alice sells WETH→USDC, Bob sells USDC→WETH. Balanced ⇒ the solver
/// needs ZERO inventory; imbalanced ⇒ it either fronts the net residual (and keeps
/// the surplus) or, with a `PRESEND` step, fronts nothing at all.
///
/// The item-bearing and deferred-check behaviours live in `MatchSettle.t.sol`.
contract MatchSettleCoWTest is CoreSettlementBase {
    uint256 bobPk = 0xB0B;
    address bob = vm.addr(bobPk);
    uint256 carolPk = 0xCA401;
    address carol = vm.addr(carolPk);

    uint256 constant WETH_AMT = 1 ether; //     Alice sells 1 WETH
    uint256 constant USDC_AMT = 2_000e6; //     …for 2000 USDC (rate 2000)

    // Deployed in setUp, not in the test bodies: a contract that references
    // `matchSettle` carries the decoder for its return, so constructing one inside
    // a measured body puts ~37k of one-time codesize into the gas snapshot and
    // swamps the settlement it is supposed to measure.
    MockSolver mockSolver;
    MockDex dex;
    PresendSolver presendSolver;

    function setUp() public override {
        super.setUp();
        vm.label(bob, "bob");
        vm.label(carol, "carol");
        mockSolver = new MockSolver(settlement);
        dex = new MockDex();
        presendSolver = new PresendSolver(settlement, dex);
        vm.label(address(mockSolver), "mockSolver");
        vm.label(address(dex), "mockDex");
        vm.label(address(presendSolver), "presendSolver");
        vm.startPrank(bob);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(carol);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        vm.stopPrank();
    }

    // ──────────────────── Builders ────────────────────

    // Alice = the base `maker`: SELL WETH → USDC.
    function _aliceOrder(uint256 nonce, uint256 wethIn, uint256 usdcOut) internal view returns (Order memory o) {
        o = _order(maker, nonce, WETH, USDC, wethIn, usdcOut, new Item[](0));
    }

    // Bob: SELL USDC → WETH.
    function _bobOrder(uint256 nonce, uint256 usdcIn, uint256 wethOut) internal view returns (Order memory o) {
        o = _order(bob, nonce, USDC, WETH, usdcIn, wethOut, new Item[](0));
    }

    function _signAs(Order memory o, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), _hashOrder(o)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _approveToSettlement(address who, address token, uint256 cap) internal {
        vm.startPrank(who);
        IERC20(token).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), token, uint160(cap), 0);
        vm.stopPrank();
    }

    /// @dev Mirror of {MatchStep.pack}.
    function _step(uint256 kind, uint256 a, uint256 b) internal pure returns (uint256) {
        return kind | (a << 8) | (b << 24);
    }

    /// @dev The item-free CoW schedule: pool both inputs, then deliver both outputs
    ///      — exactly the fixed phases the old `batchSettle` hard-coded.
    function _cowSchedule() internal pure returns (uint256[] memory s) {
        s = new uint256[](4);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 1, 0);
        s[2] = _step(MatchStep.DELIVER, 0, 0);
        s[3] = _step(MatchStep.DELIVER, 1, 0);
    }

    function _plan(
        Order memory a,
        Order memory b,
        uint256[] memory schedule,
        bytes[] memory takerDatas,
        address callTarget,
        bytes memory callData
    ) internal view returns (MatchPlan memory) {
        Order[] memory orders = new Order[](2);
        orders[0] = a;
        orders[1] = b;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signAs(a, makerPk);
        sigs[1] = _signAs(b, bobPk);
        uint256[] memory fills = new uint256[](2);
        fills[0] = a.legsIn[0].start; // Alice anchor = WETH in
        fills[1] = b.legsIn[0].start; // Bob anchor   = USDC in
        address[] memory targets = new address[](callTarget == address(0) ? 0 : 1);
        bytes[] memory datas = new bytes[](callTarget == address(0) ? 0 : 1);
        if (callTarget != address(0)) {
            targets[0] = callTarget;
            datas[0] = callData;
        }
        return MatchPlan({
            orders: orders,
            sigs: sigs,
            fillAmounts: fills,
            takerDatas: takerDatas,
            schedule: schedule,
            callTargets: targets,
            callDatas: datas,
            profitRecipient: address(0)
        });
    }

    function _plain(Order memory a, Order memory b, uint256[] memory schedule)
        internal
        view
        returns (MatchPlan memory)
    {
        return _plan(a, b, schedule, new bytes[](0), address(0), "");
    }

    /// @dev N-order plan with no takerDatas and no CALL steps. `pks[i]` signs
    ///      `orders[i]`; `fills[i]` is that order's requested fill in its own anchor
    ///      units (so a value below the anchor is a PARTIAL fill).
    function _planN(
        Order[] memory orders,
        uint256[] memory pks,
        uint256[] memory fills,
        uint256[] memory schedule
    ) internal view returns (MatchPlan memory) {
        bytes[] memory sigs = new bytes[](orders.length);
        for (uint256 i; i < orders.length; i++) {
            sigs[i] = _signAs(orders[i], pks[i]);
        }
        return MatchPlan({
            orders: orders,
            sigs: sigs,
            fillAmounts: fills,
            takerDatas: new bytes[](0),
            schedule: schedule,
            callTargets: new address[](0),
            callDatas: new bytes[](0),
            profitRecipient: address(0)
        });
    }

    function _u3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory x) {
        x = new uint256[](3);
        (x[0], x[1], x[2]) = (a, b, c);
    }

    // ── A balanced CoW: the two orders fund each other exactly. No AMM, no
    //    interaction, and the solver (a plain EOA) needs and ends with NOTHING. ──
    function test_balancedCoW_zeroInventory() public {
        Order memory a = _aliceOrder(1, WETH_AMT, USDC_AMT);
        Order memory b = _bobOrder(2, USDC_AMT, WETH_AMT);

        deal(WETH, maker, WETH_AMT);
        deal(USDC, bob, USDC_AMT);
        _approveToSettlement(maker, WETH, WETH_AMT);
        _approveToSettlement(bob, USDC, USDC_AMT);

        // The solver holds nothing on either side.
        assertEq(IERC20(WETH).balanceOf(solver), 0, "solver starts with no WETH");
        assertEq(IERC20(USDC).balanceOf(solver), 0, "solver starts with no USDC");

        MatchPlan memory p = _plain(a, b, _cowSchedule());
        vm.prank(solver);
        settlement.matchSettle(p);

        // Cross-delivered: each maker got the other's asset.
        assertEq(IERC20(USDC).balanceOf(maker), USDC_AMT, "Alice received USDC");
        assertEq(IERC20(WETH).balanceOf(bob), WETH_AMT, "Bob received WETH");
        assertEq(IERC20(WETH).balanceOf(maker), 0, "Alice's WETH fully spent");
        assertEq(IERC20(USDC).balanceOf(bob), 0, "Bob's USDC fully spent");
        // Solver is flat and nothing is stranded in Settlement.
        assertEq(IERC20(WETH).balanceOf(solver), 0, "solver flat WETH");
        assertEq(IERC20(USDC).balanceOf(solver), 0, "solver flat USDC");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "no WETH pooled");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "no USDC pooled");
    }

    // ── An imbalanced batch: Bob only brings 1500 USDC / wants 0.75 WETH, so the
    //    batch is 500 USDC short and 0.25 WETH long. The solver deposits the 500
    //    USDC residual in a CALL step and is swept the 0.25 WETH surplus. ──
    function test_imbalanced_solverCoversResidual() public {
        uint256 bobUsdc = 1_500e6;
        uint256 bobWethOut = 0.75 ether;
        uint256 residual = USDC_AMT - bobUsdc; // 500 USDC the solver must front
        uint256 surplus = WETH_AMT - bobWethOut; // 0.25 WETH the solver keeps

        Order memory a = _aliceOrder(1, WETH_AMT, USDC_AMT); //   1 WETH → 2000 USDC
        Order memory b = _bobOrder(2, bobUsdc, bobWethOut); //    1500 USDC → 0.75 WETH

        deal(WETH, maker, WETH_AMT);
        deal(USDC, bob, bobUsdc);
        deal(USDC, address(mockSolver), residual); // the solver's only capital
        _approveToSettlement(maker, WETH, WETH_AMT);
        _approveToSettlement(bob, USDC, bobUsdc);

        uint256[] memory s = new uint256[](5);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 1, 0);
        s[2] = _step(MatchStep.CALL, 0, 0); // cover the deficit
        s[3] = _step(MatchStep.DELIVER, 0, 0);
        s[4] = _step(MatchStep.DELIVER, 1, 0);

        mockSolver.run(
            _plan(a, b, s, new bytes[](0), address(mockSolver), abi.encodeCall(MockSolver.cover, (USDC, residual)))
        );

        // Both makers made whole at their own signed prices.
        assertEq(IERC20(USDC).balanceOf(maker), USDC_AMT, "Alice received her full 2000 USDC");
        assertEq(IERC20(WETH).balanceOf(bob), bobWethOut, "Bob received 0.75 WETH");
        // Solver: fronted 500 USDC, swept the 0.25 WETH surplus.
        assertEq(IERC20(USDC).balanceOf(address(mockSolver)), 0, "solver's residual USDC consumed");
        assertEq(IERC20(WETH).balanceOf(address(mockSolver)), surplus, "solver swept the WETH surplus");
        // Nothing stranded.
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "no WETH pooled");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "no USDC pooled");
    }

    // ── Whole-ness guard: if the solver under-covers, the settlement must NOT be
    //    able to silently draw down a pre-existing (donated) Settlement balance.
    //    Here 1000 USDC is donated, the solver covers nothing, and delivery would
    //    eat 500 of the donation — the final delta check catches it and reverts. ──
    function test_underCover_donatedBalanceProtected() public {
        uint256 bobUsdc = 1_500e6;
        uint256 bobWethOut = 0.75 ether;

        Order memory a = _aliceOrder(1, WETH_AMT, USDC_AMT);
        Order memory b = _bobOrder(2, bobUsdc, bobWethOut);

        deal(WETH, maker, WETH_AMT);
        deal(USDC, bob, bobUsdc);
        deal(USDC, address(settlement), 1_000e6); // pre-existing / donated balance
        _approveToSettlement(maker, WETH, WETH_AMT);
        _approveToSettlement(bob, USDC, bobUsdc);

        // No CALL step ⇒ the 500 USDC deficit is uncovered. Delivery succeeds by
        // eating the donation, but the whole-check reverts the tx.
        MatchPlan memory p = _plain(a, b, _cowSchedule());
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.BatchNotWhole.selector, USDC));
        settlement.matchSettle(p);

        // The donation is untouched (tx reverted atomically).
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 1_000e6, "donated balance intact");
    }

    // ── The pre-send unlock: an IMBALANCED batch settled with a solver holding
    //    ZERO capital. A PRESEND step hands it the 0.25 WETH surplus (bounded by
    //    the 0.75 WETH still owed to Bob), it swaps that into the 500 USDC deficit
    //    via a DEX in the CALL step, and deposits it — no inventory fronted. ──
    function test_imbalanced_zeroCapital_presend() public {
        uint256 bobUsdc = 1_500e6;
        uint256 bobWethOut = 0.75 ether;
        uint256 surplus = WETH_AMT - bobWethOut; // 0.25 WETH pre-sent to the solver
        uint256 deficit = USDC_AMT - bobUsdc; //   500 USDC the solver must return

        Order memory a = _aliceOrder(1, WETH_AMT, USDC_AMT); //  1 WETH → 2000 USDC
        Order memory b = _bobOrder(2, bobUsdc, bobWethOut); //   1500 USDC → 0.75 WETH

        deal(WETH, maker, WETH_AMT);
        deal(USDC, bob, bobUsdc);
        deal(USDC, address(dex), deficit); // the DEX's output stock — NOT the solver's
        _approveToSettlement(maker, WETH, WETH_AMT);
        _approveToSettlement(bob, USDC, bobUsdc);

        // The solver holds absolutely nothing.
        assertEq(IERC20(WETH).balanceOf(address(presendSolver)), 0, "solver starts with no WETH");
        assertEq(IERC20(USDC).balanceOf(address(presendSolver)), 0, "solver starts with no USDC");

        // Token universe is the on-chain-derived union in leg order: [WETH, USDC].
        uint256[] memory s = new uint256[](6);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 1, 0);
        s[2] = _step(MatchStep.PRESEND, 0, 0); // WETH: pooled 1.0 − owed 0.75 = 0.25
        s[3] = _step(MatchStep.CALL, 0, 0); //    swap it into the USDC deficit
        s[4] = _step(MatchStep.DELIVER, 0, 0);
        s[5] = _step(MatchStep.DELIVER, 1, 0);

        presendSolver.run(
            _plan(
                a,
                b,
                s,
                new bytes[](0),
                address(presendSolver),
                abi.encodeCall(PresendSolver.swapAndCover, (WETH, surplus, USDC, deficit))
            )
        );

        // Both makers whole at their own prices.
        assertEq(IERC20(USDC).balanceOf(maker), USDC_AMT, "Alice received her full 2000 USDC");
        assertEq(IERC20(WETH).balanceOf(bob), bobWethOut, "Bob received 0.75 WETH");
        // The solver is a pure pass-through — zero capital in, zero out.
        assertEq(IERC20(WETH).balanceOf(address(presendSolver)), 0, "solver ends with no WETH");
        assertEq(IERC20(USDC).balanceOf(address(presendSolver)), 0, "solver ends with no USDC");
        // The DEX absorbed exactly the swap: +0.25 WETH, −500 USDC.
        assertEq(IERC20(WETH).balanceOf(address(dex)), surplus, "DEX took the WETH surplus");
        assertEq(IERC20(USDC).balanceOf(address(dex)), 0, "DEX paid out its USDC stock");
        // Nothing stranded.
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "no WETH pooled");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "no USDC pooled");
    }

    // ── A PRESEND that would dip into an obligation still owed reverts rather than
    //    paying the solver out of another maker's delivery: here nothing has been
    //    delivered yet, so the whole pooled WETH is encumbered. ──
    function test_presend_cannotTakeOwedFunds() public {
        Order memory a = _aliceOrder(1, WETH_AMT, USDC_AMT);
        Order memory b = _bobOrder(2, USDC_AMT, WETH_AMT); // owed the FULL 1 WETH

        deal(WETH, maker, WETH_AMT);
        deal(USDC, bob, USDC_AMT);
        _approveToSettlement(maker, WETH, WETH_AMT);
        _approveToSettlement(bob, USDC, USDC_AMT);

        uint256[] memory s = new uint256[](5);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 1, 0);
        s[2] = _step(MatchStep.PRESEND, 0, 0); // pooled 1.0 − owed 1.0 = 0 → no-op
        s[3] = _step(MatchStep.DELIVER, 0, 0);
        s[4] = _step(MatchStep.DELIVER, 1, 0);

        MatchPlan memory p = _plain(a, b, s);
        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(IERC20(WETH).balanceOf(solver), 0, "pre-send took nothing: it was all owed");
        assertEq(IERC20(WETH).balanceOf(bob), WETH_AMT, "Bob still received his full WETH");
    }

    // ──────────────── One order matched against two counterparties ────────────────
    //
    // Alice's single large sell is filled by TWO smaller counter-orders at once —
    // the shape an orderbook actually produces, and the case a single-order `fill`
    // cannot express without the solver bridging the two halves with inventory.
    // Three fill fractions run in the same context:
    //
    //   A  Alice  SELL 2 WETH → 4000 USDC     filled 1.5 WETH   PARTIAL (75%)
    //   B  Bob    SELL 2000 USDC → 1 WETH     filled 2000 USDC  FULL
    //   C  Carol  SELL 2000 USDC → 1 WETH     filled 1000 USDC  PARTIAL (50%)
    //
    // and the pool nets to zero on both tokens:
    //   WETH  in 1.5 (A)            out 1.0 (B) + 0.5 (C) = 1.5
    //   USDC  in 2000 (B) + 1000 (C) = 3000    out 3000 (A)

    uint256 constant A_SIZE = 2 ether; //     Alice's full order
    uint256 constant A_OUT = 4_000e6;
    uint256 constant A_FILL = 1.5 ether; //   …filled 75%
    uint256 constant C_FILL = 1_000e6; //     Carol filled 50%

    /// @dev Build + fund the three orders. Balances and Permit3 caps are set to each
    ///      order's FULL size, so the untouched remainders stay fillable afterwards.
    function _threeWayOrders() internal returns (Order[] memory orders) {
        orders = new Order[](3);
        orders[0] = _order(maker, 1, WETH, USDC, A_SIZE, A_OUT, new Item[](0)); // Alice
        orders[1] = _order(bob, 2, USDC, WETH, USDC_AMT, WETH_AMT, new Item[](0)); // Bob
        orders[2] = _order(carol, 3, USDC, WETH, USDC_AMT, WETH_AMT, new Item[](0)); // Carol

        deal(WETH, maker, A_SIZE);
        deal(USDC, bob, USDC_AMT);
        deal(USDC, carol, USDC_AMT);
        _approveToSettlement(maker, WETH, A_SIZE);
        _approveToSettlement(bob, USDC, USDC_AMT);
        _approveToSettlement(carol, USDC, USDC_AMT);
    }

    /// @dev Pool all three inputs, then deliver all three outputs.
    function _threeWaySchedule() internal pure returns (uint256[] memory s) {
        s = new uint256[](6);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 1, 0);
        s[2] = _step(MatchStep.PULL, 2, 0);
        s[3] = _step(MatchStep.DELIVER, 0, 0); // pool → Alice: 3000 USDC
        s[4] = _step(MatchStep.DELIVER, 1, 0); // pool → Bob:   1.0 WETH
        s[5] = _step(MatchStep.DELIVER, 2, 0); // pool → Carol: 0.5 WETH
    }

    // ── One order against two, mixing partial and full fills in a single context.
    //    Every maker is charged and paid its OWN signed price at its OWN fraction;
    //    the solver bridges nothing. ──
    function test_oneAgainstTwo_mixedPartialAndFullFills() public {
        Order[] memory orders = _threeWayOrders();

        assertEq(IERC20(WETH).balanceOf(solver), 0, "solver starts flat");
        assertEq(IERC20(USDC).balanceOf(solver), 0, "solver starts flat");

        MatchPlan memory p = _planN(
            orders,
            _u3(makerPk, bobPk, carolPk),
            _u3(A_FILL, USDC_AMT, C_FILL), // partial, FULL, partial
            _threeWaySchedule()
        );
        vm.prank(solver);
        settlement.matchSettle(p);

        // Alice (partial): paid 1.5 of her 2 WETH, received the pro-rata 3000 USDC.
        assertEq(IERC20(WETH).balanceOf(maker), A_SIZE - A_FILL, "Alice keeps her unfilled 0.5 WETH");
        assertEq(IERC20(USDC).balanceOf(maker), 3_000e6, "Alice received 3000 USDC (75% of 4000)");
        // Bob (full): whole order cleared.
        assertEq(IERC20(USDC).balanceOf(bob), 0, "Bob's USDC fully spent");
        assertEq(IERC20(WETH).balanceOf(bob), WETH_AMT, "Bob received his full 1 WETH");
        // Carol (partial): half in, half out.
        assertEq(IERC20(USDC).balanceOf(carol), USDC_AMT - C_FILL, "Carol keeps her unfilled 1000 USDC");
        assertEq(IERC20(WETH).balanceOf(carol), WETH_AMT / 2, "Carol received 0.5 WETH (50% of 1)");

        // The fill counters record exactly the three fractions.
        assertEq(settlement.filled(_hashOrder(orders[0])), A_FILL, "A: 1.5/2 WETH");
        assertEq(settlement.filled(_hashOrder(orders[1])), USDC_AMT, "B: fully filled");
        assertEq(settlement.filled(_hashOrder(orders[2])), C_FILL, "C: 1000/2000 USDC");

        // Solver bridged nothing; pool left flat.
        assertEq(IERC20(WETH).balanceOf(solver), 0, "solver flat WETH");
        assertEq(IERC20(USDC).balanceOf(solver), 0, "solver flat USDC");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "no WETH pooled");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "no USDC pooled");

        // Bob's order is exhausted — a further fill cannot over-draw it.
        Order[] memory again = new Order[](1);
        again[0] = orders[1];
        uint256[] memory pks = new uint256[](1);
        pks[0] = bobPk;
        uint256[] memory fills = new uint256[](1);
        fills[0] = 1;
        uint256[] memory s = new uint256[](2);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.DELIVER, 0, 0);
        MatchPlan memory overfill = _planN(again, pks, fills, s);
        vm.prank(solver);
        vm.expectRevert(OrderState.OverFill.selector);
        settlement.matchSettle(overfill);
    }

    // ── The two partial remainders clear against each other in a SECOND match, and
    //    the cumulative slices sum to exactly each maker's signed order — no dust
    //    lost, no rounding leak, across two separate settlements. ──
    function test_oneAgainstTwo_remaindersClearExactly() public {
        Order[] memory orders = _threeWayOrders();

        MatchPlan memory first =
            _planN(orders, _u3(makerPk, bobPk, carolPk), _u3(A_FILL, USDC_AMT, C_FILL), _threeWaySchedule());
        vm.prank(solver);
        settlement.matchSettle(first);

        // Remainders: Alice 0.5 WETH (→ 1000 USDC), Carol 1000 USDC (→ 0.5 WETH).
        // They mirror each other exactly, so the second match needs no third party.
        Order[] memory rest = new Order[](2);
        rest[0] = orders[0];
        rest[1] = orders[2];
        uint256[] memory pks = new uint256[](2);
        (pks[0], pks[1]) = (makerPk, carolPk);
        uint256[] memory fills = new uint256[](2);
        (fills[0], fills[1]) = (A_SIZE - A_FILL, USDC_AMT - C_FILL);

        MatchPlan memory second = _planN(rest, pks, fills, _cowSchedule());
        vm.prank(solver);
        settlement.matchSettle(second);

        // Conservation across BOTH matches: each maker's cumulative slices sum to
        // exactly the order they signed.
        assertEq(IERC20(WETH).balanceOf(maker), 0, "Alice sold exactly her 2 WETH");
        assertEq(IERC20(USDC).balanceOf(maker), A_OUT, "Alice received exactly 4000 USDC");
        assertEq(IERC20(USDC).balanceOf(carol), 0, "Carol sold exactly her 2000 USDC");
        assertEq(IERC20(WETH).balanceOf(carol), WETH_AMT, "Carol received exactly 1 WETH");

        assertEq(settlement.filled(_hashOrder(orders[0])), A_SIZE, "A now fully filled");
        assertEq(settlement.filled(_hashOrder(orders[2])), USDC_AMT, "C now fully filled");

        assertEq(IERC20(WETH).balanceOf(solver), 0, "solver flat WETH");
        assertEq(IERC20(USDC).balanceOf(solver), 0, "solver flat USDC");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "no WETH pooled");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "no USDC pooled");
    }

    // ── `takerDatas` threads a per-order blob into each order's validators.
    //    Alice's order gates on takerData == 42. ──
    function test_takerData_threadsToValidator() public {
        TakerDataValidator v = new TakerDataValidator();
        Validator[] memory vals = new Validator[](1);
        vals[0] = Validator({target: address(v), data: ""});

        // Alice's order carries the validator; Bob's is the plain mirror.
        Order memory a = _orderWithValidators(1, WETH, USDC, WETH_AMT, USDC_AMT, new Item[](0), vals);
        Order memory b = _bobOrder(2, USDC_AMT, WETH_AMT);

        deal(WETH, maker, WETH_AMT);
        deal(USDC, bob, USDC_AMT);
        _approveToSettlement(maker, WETH, WETH_AMT);
        _approveToSettlement(bob, USDC, USDC_AMT);

        // Wrong blob → the validator rejects order 0, in the contract-owned OPEN
        // phase, before any schedule step runs.
        bytes[] memory badTd = new bytes[](2);
        badTd[0] = abi.encode(uint256(1));
        badTd[1] = "";
        MatchPlan memory bad = _plan(a, b, _cowSchedule(), badTd, address(0), "");
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.ValidationFailed.selector, uint256(0)));
        settlement.matchSettle(bad);

        // Correct blob (42) → the match clears.
        bytes[] memory goodTd = new bytes[](2);
        goodTd[0] = abi.encode(uint256(42));
        goodTd[1] = "";
        MatchPlan memory good = _plan(a, b, _cowSchedule(), goodTd, address(0), "");
        vm.prank(solver);
        settlement.matchSettle(good);

        assertEq(IERC20(USDC).balanceOf(maker), USDC_AMT, "Alice received USDC (validator passed)");
        assertEq(IERC20(WETH).balanceOf(bob), WETH_AMT, "Bob received WETH");
    }
}
