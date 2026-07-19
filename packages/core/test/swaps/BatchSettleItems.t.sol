// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {UniversalSettlement, Order, Item, ItemOp, OrderSide, Validator} from "@core/settlement/UniversalSettlement.sol";
import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

/// @dev TAKE mock = a borrow/withdraw: on dispatch it transfers a pre-set `produce`
///      amount of `token` (both in `data`) from its own stash to `receiver`.
///      Decoupled from the gated amount so tests can drive the under-funded path.
contract MockFundingTaker is ITakerModule {
    address public immutable permit3;

    constructor(address _permit3) {
        permit3 = _permit3;
    }

    function takeOnBehalf(address, uint256, address receiver, bytes calldata data) external override {
        require(msg.sender == permit3, "only permit3");
        (address token, uint256 produce) = abi.decode(data, (address, uint256));
        IERC20(token).transfer(receiver, produce);
    }
}

/// @dev MAKE mock = a deposit: pulls `amount` of `token` (in `data`) from the maker
///      via Permit3 into itself (stands in for the collateral now held by a lender).
contract MockDepositMaker is IMakerModule {
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

/// @dev `batchSettleItems` — the item-aware netted settle. A SPOT order's pooled
/// liquidity funds a LEVERAGE order's conversion with ZERO solver capital, no
/// callback, and no flash:
///
///   Alice (spot):     SELL 1 WETH → 2000 USDC
///   Bob   (leverage): SELL, tokenIn=[2000 USDC borrowed], tokenOut=[1 WETH],
///                     items=[MAKE deposit 1 WETH, TAKE borrow 2000 USDC → pool]
///
/// Sequence [Bob, Alice]: Bob's WETH is delivered from Alice's pooled WETH and
/// deposited as collateral BEFORE the borrow (the pool bootstraps it, no flash);
/// Bob's borrow lands 2000 USDC in the pool, which pays Alice. The solver holds
/// nothing throughout.
contract BatchSettleItemsTest is CoreSettlementBase {
    uint256 bobPk = 0xB0B;
    address bob = vm.addr(bobPk);

    MockFundingTaker taker; //     the "borrow"
    MockDepositMaker depositor; // the "deposit"

    uint256 constant WETH_AMT = 1 ether; //  Alice sells / Bob's collateral
    uint256 constant USDC_AMT = 2_000e6; //  Alice buys / Bob borrows

    function setUp() public override {
        super.setUp();
        vm.label(bob, "bob");
        taker = new MockFundingTaker(address(permit3));
        depositor = new MockDepositMaker(address(permit3), address(settlement));
        vm.label(address(taker), "borrowModule");
        vm.label(address(depositor), "depositModule");

        vm.startPrank(bob);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        vm.stopPrank();
    }

    // ──────────────────── builders ────────────────────

    function _spotOrder(uint256 nonce) internal view returns (Order memory o) {
        o = _order(maker, nonce, WETH, USDC, WETH_AMT, USDC_AMT, new Item[](0));
    }

    /// @dev Bob's leverage order. `produce` = what the TAKE mock actually mints
    ///      (== `borrowOwed` on the happy path; less drives the under-funded path).
    function _leverageOrder(uint256 nonce, uint256 collateral, uint256 borrowOwed, uint256 produce)
        internal
        view
        returns (Order memory o)
    {
        Item[] memory items = new Item[](2);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(depositor),
            amount: collateral,
            recipient: address(0),
            data: abi.encode(WETH)
        });
        items[1] = Item({
            op: ItemOp.TAKE,
            module: address(taker),
            amount: borrowOwed,
            recipient: address(0), // proceeds → Settlement (the pool)
            data: abi.encode(USDC, produce)
        });
        o = Order({
            maker: bob,
            side: OrderSide.SELL,
            nonce: nonce,
            deadline: block.timestamp + 1 hours,
            tokenIn: _a1(USDC),
            startAmountIn: _u1(borrowOwed),
            endAmountIn: _u1(borrowOwed),
            decayStartTime: 0,
            decayDuration: 0,
            tokenOut: _a1(WETH),
            startAmountOut: _u1(collateral),
            endAmountOut: _u1(collateral),
            recipientOut: new address[](1),
            exclusiveFiller: address(0),
            exclusivityEndTime: 0,
            minFillAnchor: 0,
            exclusivityOverrideBps: 0,
            curve: _noCurve(),
            gasBumpBps: 0,
            gasPriceRef: 0,
            items: items,
            validators: new Validator[](0),
            invariants: new Validator[](0),
            fillModule: address(0),
            fillTotal: 0
        });
    }

    function _signAs(Order memory o, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), _hashOrder(o)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Fund + authorise both makers. Bob's WETH collateral comes from the pool
    ///      (Alice), so Bob is dealt NOTHING — he only approves the deposit pull and
    ///      the borrow gate. `produce` is the taker's USDC stash to lend out.
    function _fund(Order memory lev, uint256 produce) internal {
        // Alice supplies the WETH; Settlement may pull it (the pull-set seed).
        deal(WETH, maker, WETH_AMT);
        _approveMakerToSettlement(WETH, WETH_AMT);

        // Bob: deposit module may pull his (just-delivered) WETH; Settlement may
        // consume his borrow gate. The taker holds the USDC it "borrows".
        vm.startPrank(bob);
        permit3.approveToken(address(depositor), WETH, uint160(WETH_AMT), 0);
        permit3.approveTaker(
            address(settlement), keccak256(lev.items[1].data), uint160(lev.startAmountIn[0]), uint48(block.timestamp + 1 hours)
        );
        vm.stopPrank();
        deal(USDC, address(taker), produce);
    }

    function _batch(Order memory a, Order memory b, uint256[] memory pullMask, uint256[] memory sequence)
        internal
        view
        returns (UniversalSettlement.ItemsBatch memory bat)
    {
        Order[] memory orders = new Order[](2);
        orders[0] = a;
        orders[1] = b;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(a);
        sigs[1] = _signAs(b, bobPk);
        uint256[] memory fills = new uint256[](2);
        fills[0] = a.startAmountIn[0]; // Alice anchor = WETH
        fills[1] = b.startAmountIn[0]; // Bob anchor   = USDC borrow
        bat = UniversalSettlement.ItemsBatch({
            orders: orders,
            sigs: sigs,
            fillAmounts: fills,
            pullMask: pullMask,
            sequence: sequence,
            interactionTarget: address(0),
            interactionData: ""
        });
    }

    function _mask(uint256 m0, uint256 m1) internal pure returns (uint256[] memory m) {
        m = new uint256[](2);
        m[0] = m0;
        m[1] = m1;
    }

    function _seq(uint256 s0, uint256 s1) internal pure returns (uint256[] memory s) {
        s = new uint256[](2);
        s[0] = s0;
        s[1] = s1;
    }

    // ── The headline: spot funds leverage, ZERO solver capital, no callback/flash. ──
    function test_spotFundsLeverage_zeroSolverCapital() public {
        Order memory a = _spotOrder(1);
        Order memory b = _leverageOrder(2, WETH_AMT, USDC_AMT, USDC_AMT);
        _fund(b, USDC_AMT);

        // Solver holds nothing and never will.
        assertEq(IERC20(WETH).balanceOf(solver), 0, "solver: no WETH");
        assertEq(IERC20(USDC).balanceOf(solver), 0, "solver: no USDC");

        // pullMask: pull Alice's WETH (seed); Bob's USDC is item-funded (borrow).
        // sequence: Bob first (borrow lands USDC), then Alice (paid from it).
        UniversalSettlement.ItemsBatch memory bat = _batch(a, b, _mask(1, 0), _seq(1, 0));

        vm.prank(solver);
        settlement.batchSettleItems(bat);

        // Spot Alice: sold 1 WETH, received 2000 USDC.
        assertEq(IERC20(WETH).balanceOf(maker), 0, "Alice's WETH spent");
        assertEq(IERC20(USDC).balanceOf(maker), USDC_AMT, "Alice received 2000 USDC");
        // Leverage Bob: 1 WETH now collateral (held by the deposit module); the
        // borrowed USDC funded Alice, so Bob's wallet is flat.
        assertEq(IERC20(WETH).balanceOf(address(depositor)), WETH_AMT, "Bob's 1 WETH deposited as collateral");
        assertEq(IERC20(WETH).balanceOf(bob), 0, "Bob holds no loose WETH");
        assertEq(IERC20(USDC).balanceOf(bob), 0, "Bob's borrow went to the pool, not his wallet");
        // Solver: pure orchestrator — zero capital, zero residue.
        assertEq(IERC20(WETH).balanceOf(solver), 0, "solver flat WETH");
        assertEq(IERC20(USDC).balanceOf(solver), 0, "solver flat USDC");
        // Nothing stranded in the pool.
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "no WETH pooled");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "no USDC pooled");
    }

    // ── Liveness/ordering (S7): a wrong sequence can only REVERT, never mis-settle.
    //    Alice-before-Bob delivers Alice's USDC before the borrow produced it. ──
    function test_wrongSequence_reverts() public {
        Order memory a = _spotOrder(1);
        Order memory b = _leverageOrder(2, WETH_AMT, USDC_AMT, USDC_AMT);
        _fund(b, USDC_AMT);

        UniversalSettlement.ItemsBatch memory bat = _batch(a, b, _mask(1, 0), _seq(0, 1)); // Alice first

        vm.prank(solver);
        vm.expectRevert(); // pool has no USDC yet → Alice's delivery transfer reverts
        settlement.batchSettleItems(bat);
    }

    // ── `sequence` must be a permutation of [0,n): a duplicate reverts. ──
    function test_badSequence_duplicate_reverts() public {
        Order memory a = _spotOrder(1);
        Order memory b = _leverageOrder(2, WETH_AMT, USDC_AMT, USDC_AMT);
        _fund(b, USDC_AMT);

        UniversalSettlement.ItemsBatch memory bat = _batch(a, b, _mask(1, 0), _seq(1, 1)); // dup

        vm.prank(solver);
        vm.expectRevert(UniversalSettlement.BatchItemsBadSequence.selector);
        settlement.batchSettleItems(bat);
    }

    // ── An item-funded leg that under-produces (borrow < owed) reverts cleanly at
    //    the input settlement, before it can shortchange the counterparty. ──
    function test_itemLeg_underfunded_reverts() public {
        Order memory a = _spotOrder(1);
        // Bob owes 2000 USDC in but the borrow only mints 1500.
        Order memory b = _leverageOrder(2, WETH_AMT, USDC_AMT, 1_500e6);
        _fund(b, 1_500e6);

        UniversalSettlement.ItemsBatch memory bat = _batch(a, b, _mask(1, 0), _seq(1, 0));

        vm.prank(solver);
        vm.expectRevert(UniversalSettlement.BatchItemsInputUnfunded.selector);
        settlement.batchSettleItems(bat);
    }

    // ── Audit F2: SETTLE items are out of scope (they route to the filler, not the
    //    pool). An order carrying one is rejected at open. ──
    function test_settleItem_reverts() public {
        Order memory a = _spotOrder(1);
        Order memory b = _leverageOrder(2, WETH_AMT, USDC_AMT, USDC_AMT);
        // Splice a SETTLE item onto Bob's order (module addr irrelevant — the guard
        // fires before dispatch).
        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.SETTLE, module: address(0x5E7), amount: 1, recipient: address(0), data: ""});
        b.items = items;
        _fund(_leverageOrder(2, WETH_AMT, USDC_AMT, USDC_AMT), USDC_AMT); // approvals harmless

        UniversalSettlement.ItemsBatch memory bat = _batch(a, b, _mask(1, 0), _seq(1, 0));

        vm.prank(solver);
        vm.expectRevert(UniversalSettlement.BatchItemsSettleUnsupported.selector);
        settlement.batchSettleItems(bat);
    }

    // ── Audit F1: a repeated input token would corrupt the per-token pooled
    //    proceeds attribution, so it is rejected at open. ──
    function test_duplicateInput_reverts() public {
        Order memory a = _spotOrder(1);
        Order memory b = _leverageOrder(2, WETH_AMT, USDC_AMT, USDC_AMT);
        // Give Bob two USDC input legs (the corrupting shape).
        b.tokenIn = new address[](2);
        b.tokenIn[0] = USDC;
        b.tokenIn[1] = USDC;
        b.startAmountIn = new uint256[](2);
        b.startAmountIn[0] = USDC_AMT;
        b.startAmountIn[1] = 1;
        b.endAmountIn = b.startAmountIn;
        _fund(_leverageOrder(2, WETH_AMT, USDC_AMT, USDC_AMT), USDC_AMT);

        UniversalSettlement.ItemsBatch memory bat = _batch(a, b, _mask(1, 0), _seq(1, 0));

        vm.prank(solver);
        vm.expectRevert(UniversalSettlement.BatchItemsDuplicateInput.selector);
        settlement.batchSettleItems(bat);
    }
}
