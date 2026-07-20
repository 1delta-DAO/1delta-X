// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "@core/settlement/Base.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Settlement, Order, Item, ItemOp, OrderSide, Validator} from "@core/settlement/Settlement.sol";
import {IOrderValidator} from "@core/interfaces/IOrderValidator.sol";
import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

/// @dev A contract solver for the imbalanced case: it calls `batchSettle` (so it is
///      the `msg.sender` the surplus is swept to) and, during the single interaction,
///      deposits its own inventory of the net-deficit token INTO Settlement. It
///      holds no Permit3 allowance — batch deliveries come from the pool, so the
///      solver only ever PUSHES the residual in.
contract MockSolver {
    Settlement immutable settlement;

    constructor(Settlement s) {
        settlement = s;
    }

    function run(
        Order[] calldata orders,
        bytes[] calldata sigs,
        uint256[] calldata fills,
        address target,
        bytes calldata data
    ) external returns (uint256[][] memory) {
        return settlement.batchSettle(orders, sigs, fills, target, data);
    }

    /// @dev Called via the allowance-less EXECUTOR mid-batch: front the deficit.
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

/// @dev A ZERO-CAPITAL solver: it holds no inventory. Mid-batch it is handed the
///      net surplus (pre-send), swaps that surplus into the deficit via `dex`, and
///      deposits the deficit into Settlement — never fronting a cent of its own.
contract PresendSolver {
    Settlement immutable settlement;
    MockDex immutable dex;

    constructor(Settlement s, MockDex d) {
        settlement = s;
        dex = d;
    }

    function run(
        Order[] calldata orders,
        bytes[] calldata sigs,
        uint256[] calldata fills,
        bytes calldata data
    ) external returns (uint256[][] memory) {
        return settlement.batchSettle(orders, sigs, fills, address(this), data);
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
///      blob decodes to the sentinel. Proves `batchSettle`'s `takerDatas` overload
///      threads the per-order blob into each order's validators.
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

/// @dev `batchSettle` — coincidence-of-wants netting. Two mirror makers clear
/// against each other with no AMM: Alice sells WETH→USDC, Bob sells USDC→WETH.
/// For a balanced batch the solver needs ZERO inventory; for an imbalanced batch
/// the solver deposits only the net residual and keeps the surplus.
contract BatchSettleTest is CoreSettlementBase {
    uint256 bobPk = 0xB0B;
    address bob = vm.addr(bobPk);

    uint256 constant WETH_AMT = 1 ether; //     Alice sells 1 WETH
    uint256 constant USDC_AMT = 2_000e6; //     …for 2000 USDC (rate 2000)

    function setUp() public override {
        super.setUp();
        vm.label(bob, "bob");
        vm.startPrank(bob);
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

    function _two(Order memory a, Order memory b) internal pure returns (Order[] memory os) {
        os = new Order[](2);
        os[0] = a;
        os[1] = b;
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

        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(a); //          Alice = base maker key
        sigs[1] = _signAs(b, bobPk);
        uint256[] memory fills = new uint256[](2);
        fills[0] = WETH_AMT; //         Alice anchor = tokenIn[0] (WETH)
        fills[1] = USDC_AMT; //         Bob anchor   = tokenIn[0] (USDC)

        vm.prank(solver);
        settlement.batchSettle(_two(a, b), sigs, fills, address(0), "");

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
    //    USDC residual in the interaction and is swept the 0.25 WETH surplus. ──
    function test_imbalanced_solverCoversResidual() public {
        MockSolver mockSolver = new MockSolver(settlement);
        vm.label(address(mockSolver), "mockSolver");

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

        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(a);
        sigs[1] = _signAs(b, bobPk);
        uint256[] memory fills = new uint256[](2);
        fills[0] = WETH_AMT;
        fills[1] = bobUsdc;

        bytes memory interaction = abi.encodeCall(MockSolver.cover, (USDC, residual));
        mockSolver.run(_two(a, b), sigs, fills, address(mockSolver), interaction);

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

    // ── batchSettle is item-free (like PostInputs): an order carrying an item
    //    reverts before any funds move. ──
    function test_itemOrder_reverts() public {
        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.MAKE, module: address(0xDEAD), amount: 1, recipient: address(0), data: ""});
        Order memory a = _order(maker, 1, WETH, USDC, WETH_AMT, USDC_AMT, items);

        deal(WETH, maker, WETH_AMT);
        _approveToSettlement(maker, WETH, WETH_AMT);

        Order[] memory os = new Order[](1);
        os[0] = a;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(a);
        uint256[] memory fills = new uint256[](1);
        fills[0] = WETH_AMT;

        vm.prank(solver);
        vm.expectRevert(Base.BatchSettleNoItems.selector);
        settlement.batchSettle(os, sigs, fills, address(0), "");
    }

    // ── Whole-ness guard: if the solver under-covers, the batch must NOT be able
    //    to silently draw down a pre-existing (donated) Settlement balance. Here
    //    1000 USDC is donated, the solver covers nothing, and delivery would eat
    //    500 of the donation — the Phase-4 delta check catches it and reverts. ──
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

        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(a);
        sigs[1] = _signAs(b, bobPk);
        uint256[] memory fills = new uint256[](2);
        fills[0] = WETH_AMT;
        fills[1] = bobUsdc;

        // No interaction ⇒ the 500 USDC deficit is uncovered. Delivery succeeds by
        // eating the donation, but the delta check reverts the whole tx.
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.BatchNotWhole.selector, USDC));
        settlement.batchSettle(_two(a, b), sigs, fills, address(0), "");

        // The donation is untouched (tx reverted atomically).
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 1_000e6, "donated balance intact");
    }

    // ── The pre-send unlock: an IMBALANCED batch settled with a solver holding
    //    ZERO capital. It is handed the 0.25 WETH surplus (pre-send), swaps it to
    //    the 500 USDC deficit via a DEX in the interaction, and deposits that — no
    //    inventory fronted at any point. ──
    function test_imbalanced_zeroCapital_presend() public {
        MockDex dex = new MockDex();
        PresendSolver solver_ = new PresendSolver(settlement, dex);
        vm.label(address(dex), "mockDex");
        vm.label(address(solver_), "presendSolver");

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
        assertEq(IERC20(WETH).balanceOf(address(solver_)), 0, "solver starts with no WETH");
        assertEq(IERC20(USDC).balanceOf(address(solver_)), 0, "solver starts with no USDC");

        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(a);
        sigs[1] = _signAs(b, bobPk);
        uint256[] memory fills = new uint256[](2);
        fills[0] = WETH_AMT;
        fills[1] = bobUsdc;

        bytes memory interaction = abi.encodeCall(PresendSolver.swapAndCover, (WETH, surplus, USDC, deficit));
        solver_.run(_two(a, b), sigs, fills, interaction);

        // Both makers whole at their own prices.
        assertEq(IERC20(USDC).balanceOf(maker), USDC_AMT, "Alice received her full 2000 USDC");
        assertEq(IERC20(WETH).balanceOf(bob), bobWethOut, "Bob received 0.75 WETH");
        // The solver is a pure pass-through — zero capital in, zero out.
        assertEq(IERC20(WETH).balanceOf(address(solver_)), 0, "solver ends with no WETH");
        assertEq(IERC20(USDC).balanceOf(address(solver_)), 0, "solver ends with no USDC");
        // The DEX absorbed exactly the swap: +0.25 WETH, −500 USDC.
        assertEq(IERC20(WETH).balanceOf(address(dex)), surplus, "DEX took the WETH surplus");
        assertEq(IERC20(USDC).balanceOf(address(dex)), 0, "DEX paid out its USDC stock");
        // Nothing stranded.
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "no WETH pooled");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "no USDC pooled");
    }

    // ── The takerDatas overload threads a per-order blob into each order's
    //    validators. Alice's order gates on takerData == 42. ──
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

        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(a);
        sigs[1] = _signAs(b, bobPk);
        uint256[] memory fills = new uint256[](2);
        fills[0] = WETH_AMT;
        fills[1] = USDC_AMT;

        // Wrong blob → the validator rejects order 0.
        bytes[] memory badTd = new bytes[](2);
        badTd[0] = abi.encode(uint256(1));
        badTd[1] = "";
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.ValidationFailed.selector, uint256(0)));
        settlement.batchSettle(_two(a, b), sigs, fills, badTd, address(0), "");

        // Correct blob (42) → the batch clears.
        bytes[] memory goodTd = new bytes[](2);
        goodTd[0] = abi.encode(uint256(42));
        goodTd[1] = "";
        vm.prank(solver);
        settlement.batchSettle(_two(a, b), sigs, fills, goodTd, address(0), "");

        assertEq(IERC20(USDC).balanceOf(maker), USDC_AMT, "Alice received USDC (validator passed)");
        assertEq(IERC20(WETH).balanceOf(bob), WETH_AMT, "Bob received WETH");
    }
}
