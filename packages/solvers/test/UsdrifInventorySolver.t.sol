// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, OrderSide, Item, Validator, LegIn, LegOut} from "@core/settlement/Settlement.sol";
import {UsdrifInventorySolver} from "@solvers/inventory/UsdrifInventorySolver.sol";

import {IMocQueue} from "../../modules/redeem/usdrif/src/interfaces/IMoc.sol";
import {UsdrifForkBase} from "../../modules/redeem/usdrif/test/shared/UsdrifForkBase.t.sol";

/// @dev Uniswap v3 SwapRouter02 `exactInputSingle` shape — NOTE: the 02 struct
///      has NO `deadline` field (Rootstock's Oku deployment only ships 02). Only
///      tests need this now; the solver treats venues as opaque calldata.
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256);
}

/// @dev A malicious "venue": consumes the granted allowance and delivers nothing
///      back — exercises the solver's balance-delta output floor.
contract RugVenue {
    function take(address token, address from, uint256 amount) external {
        IERC20(token).transferFrom(from, address(0xdead), amount);
    }
}

/// @dev A deterministic, well-behaved venue: pulls `amountIn` of `tokenIn` from
///      the caller and pays `amountOut` of `tokenOut` from its own float to
///      `recipient`. Lets the route checks be exercised at exact amounts (and
///      with an operator-chosen recipient or output token).
contract MockVenue {
    function swap(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut, address recipient) external {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).transfer(recipient, amountOut);
    }
}

/// @dev End-to-end inventory-solver exit on a Rootstock fork — the one-signature
/// variant of the USDRIF→USDT0 flow (`packages/modules/redeem/usdrif` implements
/// the two-phase variant 1 where the USER redeems first):
///
///   fill     operator fills the maker's USDRIF→USDT0 order from the solver's
///            USDT0 inventory and, same tx, escrows the USDRIF into a MoC
///            redemption (recipient == the solver itself — allowed, unlike a
///            user-side wrapper).
///   settle   the MoC queue executes and delivers RIF to the solver.
///   recycle  the operator sells the RIF → USDT0 on the real Uni v3 pool.
///
/// Verified routing facts at the pinned block (8_920_000): SwapRouter02 (Oku
/// deployment, factory 0xaF37...aD82) and a direct RIF/USDT0 0.3% pool that
/// quotes ~956 USDT0 for the ~14.6k RIF a $1000 redemption yields.
contract UsdrifInventorySolverTest is UsdrifForkBase {
    /// @dev Uniswap v3 SwapRouter02 on Rootstock (verified: factory() matches the
    ///      plan's QuoterV2). The 02 variant — its params carry no deadline.
    address internal constant SWAP_ROUTER_02 = 0x0B14ff67f0014046b4b99057Aec4509640b3947A;
    uint24 internal constant RIF_USDT0_FEE = 3000;

    uint256 constant USDRIF_IN = 1_000e18; // maker exits $1000 of USDRIF
    uint256 constant USDT0_OUT = 935e6; //   maker's floor: ~6.5% discount clears redeem + DEX costs
    uint256 constant INVENTORY = 2_000e6; // solver's USDT0 float
    uint256 constant QAC_MIN = 13_000e18; // RIF floor ~11% under the ~14.6k expected
    /// @dev `maxSpent` sentinel: no operator price bound (the owner floor still applies).
    uint256 constant NO_BOUND = type(uint256).max;

    /// @dev RIF→USDT0 route floor in raw units, WAD-scaled: $0.06/RIF =
    ///      0.06e6 USDT0-wei per 1e18 RIF-wei → 6e4 (pool quotes ~0.0655 at the
    ///      pinned block). Budget covers one ~14.6k-RIF redemption.
    uint128 constant RIF_USDT0_MIN_RATE = 6e4;
    uint128 constant RIF_SELL_BUDGET = 20_000e18;
    /// @dev USDT0→USDRIF fill floor: ≥ 1 USDRIF (18 dec) per USDT0 (6 dec) paid.
    uint256 constant USDT0_USDRIF_MIN_RATE = 1e30;

    UsdrifInventorySolver inv;
    address operator = makeAddr("operator");

    receive() external payable {} // for the RBTC withdraw test

    function setUp() public override {
        super.setUp();

        inv = new UsdrifInventorySolver(
            address(permit3), address(settlement), SWAP_ROUTER_02, MOC_CORE, MOC_QUEUE, USDRIF, USDT0
        );
        inv.setOperator(operator, true);
        // Per-call inventory budget. Defaults to 0 (fail closed), so a real
        // deployment must set this before any operator can fill — it is what stops
        // an operator self-signing an order that takes the whole inventory.
        inv.setMaxOutflowPerFill(USDT0, INVENTORY);
        // Fills are closed until the owner prices a FILL route: pay USDT0, receive
        // at least 1 USDRIF per USDT0 (raw units, WAD-scaled — see {fillMinRate}).
        inv.setFillRoute(USDT0, USDRIF, USDT0_USDRIF_MIN_RATE);
        // `sell` is closed until the owner prices a route: the recycle leg only.
        inv.setSellRoute(RIF, USDT0, RIF_USDT0_MIN_RATE, RIF_SELL_BUDGET);
        // Cumulative per-window budgets, shared by fills and `sell` (fail closed).
        inv.setOutflowLimit(USDT0, INVENTORY);
        inv.setOutflowLimit(RIF, RIF_SELL_BUDGET);
        vm.label(address(inv), "inventorySolver");
        vm.label(operator, "operator");
        vm.label(SWAP_ROUTER_02, "swapRouter02");

        deal(USDT0, address(inv), INVENTORY);
        vm.deal(address(inv), 1 ether); // RBTC float for MoC exec fees

        // Maker holds USDRIF and lets Settlement pull it — the maker's ONLY
        // on-chain footprint besides the signature.
        deal(USDRIF, maker, USDRIF_IN);
        vm.startPrank(maker);
        IERC20(USDRIF).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDRIF, uint160(USDRIF_IN), 0);
        vm.stopPrank();
    }

    /// @dev SwapRouter02 exactInputSingle calldata for a tokenIn→tokenOut sale to
    ///      the solver. Router-side minOut is 0 on purpose: the solver's own
    ///      balance-delta floor is the check under test.
    function _uniV3SellData(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(
            ISwapRouter02.exactInputSingle,
            (ISwapRouter02.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: fee,
                    recipient: address(inv),
                    amountIn: amountIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                }))
        );
    }

    /// @dev Plain USDRIF→USDT0 exit order (fixed price, no validators) — the
    ///      inventory-solver variant needs no order-side machinery at all.
    function _usdrifOrder(uint256 nonce) internal view returns (Order memory) {
        return Order({
            params: 0,
            pricingModule: address(0),
            maker: maker,
            nonce: nonce,
            legsIn: _legsIn1(USDRIF, USDRIF_IN),
            legsOut: _legsOut1(USDT0, USDT0_OUT),
            timing: _expiryBits(block.timestamp + 1 hours),
            exclusiveFiller: address(0),
            minFillAnchor: 0,
            curve: _noCurve(),
            items: PackedEncode.noItems(),
            validators: PackedEncode.noValidators(),
            invariants: PackedEncode.noValidators(),
            fillModule: address(0),
            fillTotal: 0
        });
    }

    // ──────────────────── Tests ────────────────────

    /// The maker exits in one fill: USDT0 lands instantly, the solver takes the
    /// USDRIF onto its book.
    function test_fill_makerExitsInstantly() public {
        Order memory order = _usdrifOrder(1);
        bytes memory sig = _sign(order);

        vm.prank(operator);
        uint256 paid = inv.executeFill(order, sig, USDRIF_IN, NO_BOUND)[0];

        assertEq(paid, USDT0_OUT, "maker paid their USDT0 floor");
        assertEq(IERC20(USDT0).balanceOf(maker), USDT0_OUT, "maker exited to USDT0");
        assertEq(IERC20(USDRIF).balanceOf(maker), 0, "maker's USDRIF fully sold");
        assertEq(IERC20(USDRIF).balanceOf(address(inv)), USDRIF_IN, "solver holds the USDRIF");
        assertEq(IERC20(USDT0).balanceOf(address(inv)), INVENTORY - USDT0_OUT, "inventory drawn down");
    }

    /// Fused fill+redeem: the USDRIF goes straight from the fill into MoC's
    /// escrow (zero long-USDRIF window), the exec fee comes out of the solver's
    /// own RBTC float, and the queue later delivers RIF above the floor.
    function test_fillAndRedeem_zeroUsdrifWindow() public {
        Order memory order = _usdrifOrder(2);
        bytes memory sig = _sign(order);

        // MoC's exec fee is execCost × block.basefee (RSK's minimumGasPrice via
        // RSKIP-412 BASEFEE) — forge forks default basefee to 0, so pin the real
        // ~0.024 gwei minimum to make the fee non-zero.
        vm.fee(0.024 gwei);
        uint256 rbtcBefore = address(inv).balance;

        vm.prank(operator);
        (uint256[] memory paid, uint256 opId) = inv.executeFillAndRedeem(order, sig, USDRIF_IN, NO_BOUND, QAC_MIN);

        assertEq(paid[0], USDT0_OUT, "maker paid their USDT0 floor");
        assertEq(IERC20(USDRIF).balanceOf(address(inv)), 0, "USDRIF escrowed into MoC in the same tx");
        assertLt(address(inv).balance, rbtcBefore, "exec fee funded from the solver's RBTC float");
        assertLe(IMocQueue(MOC_QUEUE).firstOperId(), opId, "op still pending");

        _executeQueue();

        assertGt(IMocQueue(MOC_QUEUE).firstOperId(), opId, "op settled (dequeued)");
        assertGe(IERC20(RIF).balanceOf(address(inv)), QAC_MIN, "RIF delivered above the floor");
    }

    /// The full cycle ends with MORE USDT0 than it started: pay the maker 935,
    /// redeem the USDRIF at MoC's oracle price, sell the RIF on the real pool.
    function test_fullCycle_roundTripProfitable() public {
        Order memory order = _usdrifOrder(3);
        bytes memory sig = _sign(order);

        vm.fee(0.024 gwei);
        vm.prank(operator);
        (, uint256 opId) = inv.executeFillAndRedeem(order, sig, USDRIF_IN, NO_BOUND, QAC_MIN);

        _executeQueue();
        assertGt(IMocQueue(MOC_QUEUE).firstOperId(), opId, "op settled");

        uint256 rifBal = IERC20(RIF).balanceOf(address(inv));
        vm.prank(operator);
        uint256 proceeds = inv.sell(
            SWAP_ROUTER_02, RIF, USDT0, type(uint256).max, 930e6, _uniV3SellData(RIF, USDT0, RIF_USDT0_FEE, rifBal)
        );

        assertEq(IERC20(RIF).balanceOf(address(inv)), 0, "RIF fully recycled");
        assertEq(IERC20(RIF).allowance(address(inv), SWAP_ROUTER_02), 0, "venue allowance revoked");
        uint256 finalInventory = IERC20(USDT0).balanceOf(address(inv));
        assertEq(finalInventory, INVENTORY - USDT0_OUT + proceeds, "inventory accounting");
        assertGt(finalInventory, INVENTORY, "round trip is profitable at the signed discount");
    }

    /// A redemption whose qACmin can't be met errors at queue execution and MoC
    /// refunds the escrowed USDRIF to the solver — retry is just re-initiating.
    function test_failedRedemption_refundsUsdrif() public {
        deal(USDRIF, address(inv), USDRIF_IN);

        vm.fee(0.024 gwei);
        vm.prank(operator);
        uint256 opId = inv.initiateRedemption(type(uint256).max, 1e30); // impossible RIF floor

        assertEq(IERC20(USDRIF).balanceOf(address(inv)), 0, "USDRIF escrowed");

        _executeQueue();

        assertGt(IMocQueue(MOC_QUEUE).firstOperId(), opId, "op dequeued (errored, not stuck)");
        assertEq(IERC20(USDRIF).balanceOf(address(inv)), USDRIF_IN, "escrowed USDRIF refunded on failure");
    }

    /// Strangers can't touch the inventory; operators can't reach owner custody.
    function test_accessControl() public {
        Order memory order = _usdrifOrder(4);
        bytes memory sig = _sign(order);
        address stranger = makeAddr("stranger");

        vm.startPrank(stranger);
        vm.expectRevert(UsdrifInventorySolver.NotOperator.selector);
        inv.executeFill(order, sig, USDRIF_IN, NO_BOUND);
        vm.expectRevert(UsdrifInventorySolver.NotOperator.selector);
        inv.initiateRedemption(1e18, 1);
        vm.expectRevert(UsdrifInventorySolver.NotOperator.selector);
        inv.sell(SWAP_ROUTER_02, RIF, USDT0, 1e18, 0, "");
        vm.stopPrank();

        vm.startPrank(operator);
        vm.expectRevert(UsdrifInventorySolver.NotOwner.selector);
        inv.withdraw(USDT0, 1, operator);
        vm.expectRevert(UsdrifInventorySolver.NotOwner.selector);
        inv.setOperator(stranger, true);
        vm.expectRevert(UsdrifInventorySolver.NotOwner.selector);
        inv.setAggregator(stranger, true);
        vm.expectRevert(UsdrifInventorySolver.NotOwner.selector);
        inv.execute(USDT0, "");
        vm.stopPrank();
    }

    /// `sell` refuses non-whitelisted call targets — the guard that stops an
    /// operator from driving arbitrary contracts (e.g. Permit3) with crafted
    /// calldata from the solver's identity.
    function test_sell_blocksNonWhitelistedVenue() public {
        vm.prank(operator);
        vm.expectRevert(UsdrifInventorySolver.AggregatorNotAllowed.selector);
        inv.sell(address(permit3), RIF, USDT0, 1e18, 0, "");

        // Whitelisting is what flips the switch (owner-gated, tested above).
        RugVenue venue = new RugVenue();
        inv.setAggregator(address(venue), true);
        inv.setAggregator(address(venue), false);
        vm.prank(operator);
        vm.expectRevert(UsdrifInventorySolver.AggregatorNotAllowed.selector);
        inv.sell(address(venue), RIF, USDT0, 1e18, 0, "");
    }

    /// The output floors are enforced by measured balances, not by trusting the
    /// venue: a venue that consumes the allowance and delivers nothing reverts
    /// the whole sale atomically (its transferFrom unwinds too) — and since the
    /// owner's route rate applies regardless, `minOut = 0` no longer means
    /// "accept any outcome".
    function test_sell_enforcesMinOutByBalanceDelta() public {
        RugVenue venue = new RugVenue();
        inv.setAggregator(address(venue), true);
        deal(RIF, address(inv), 1_000e18);

        bytes memory rugData = abi.encodeCall(RugVenue.take, (RIF, address(inv), 1_000e18));
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                UsdrifInventorySolver.RateTooLow.selector, 0, uint256(1_000e18), uint256(RIF_USDT0_MIN_RATE)
            )
        );
        inv.sell(address(venue), RIF, USDT0, 1_000e18, 1, rugData);

        assertEq(IERC20(RIF).balanceOf(address(inv)), 1_000e18, "revert unwound the venue's pull");

        // Same venue, minOut 0: the route rate still refuses a zero-output sale.
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                UsdrifInventorySolver.RateTooLow.selector, 0, uint256(1_000e18), uint256(RIF_USDT0_MIN_RATE)
            )
        );
        inv.sell(address(venue), RIF, USDT0, 1_000e18, 0, rugData);
        assertEq(IERC20(RIF).balanceOf(address(inv)), 1_000e18, "minOut 0 no longer lets a rug through");

        // The operator's own `minOut` still binds ON TOP of the rate: a fair
        // 1000 RIF → 65 USDT0 fill clears the $0.06 floor but not a 70 minOut.
        MockVenue fair = _fairVenue();
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(UsdrifInventorySolver.InsufficientOutput.selector, uint256(65e6), uint256(70e6))
        );
        inv.sell(address(fair), RIF, USDT0, 1_000e18, 70e6, _mockSwap(RIF, 1_000e18, USDT0, 65e6, address(inv)));
    }

    /// Owner custody: withdraw ERC20 + native, and the raw-call escape hatch.
    function test_ownerCustody() public {
        inv.withdraw(USDT0, 500e6, address(this));
        assertEq(IERC20(USDT0).balanceOf(address(this)), 500e6, "ERC20 withdrawn");

        uint256 nativeBefore = address(this).balance;
        inv.withdraw(address(0), 0.5 ether, address(this));
        assertEq(address(this).balance, nativeBefore + 0.5 ether, "RBTC withdrawn");

        inv.execute(USDT0, abi.encodeCall(IERC20.transfer, (address(this), 100e6)));
        assertEq(IERC20(USDT0).balanceOf(address(this)), 600e6, "escape hatch moved funds");
    }

    // ──────────────── Operator outflow cap ────────────────

    /// The drain: an operator (a lower trust tier than owner — the aggregator
    /// whitelist on `sell` exists precisely to keep it that way) signs their OWN
    /// order taking the entire inventory for a token amount in. `executeFill`
    /// accepts an arbitrary `(order, sig)` and the contract holds a max Permit3
    /// allowance to Settlement, so nothing about the order itself stops this.
    /// The per-call budget is what bounds it.
    function test_operator_cannotDrainInventoryPastTheCap() public {
        // Owner budgets a normal-sized fill, not the whole float.
        inv.setMaxOutflowPerFill(USDT0, 1_000e6);

        // Operator's self-signed order: pay out the FULL inventory.
        Order memory rug = _usdrifOrder(99);
        rug.legsOut = _legsOut1(USDT0, INVENTORY);
        bytes memory sig = _sign(rug);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                UsdrifInventorySolver.OutflowCapExceeded.selector, USDT0, INVENTORY, uint256(1_000e6)
            )
        );
        inv.executeFill(rug, sig, USDRIF_IN, NO_BOUND);

        assertEq(IERC20(USDT0).balanceOf(address(inv)), INVENTORY, "inventory untouched");
    }

    /// A fill inside the budget still works — the cap is a bound, not a block.
    function test_fillWithinCap_succeeds() public {
        inv.setMaxOutflowPerFill(USDT0, USDT0_OUT);

        Order memory order = _usdrifOrder(7);
        bytes memory sig = _sign(order);

        vm.prank(operator);
        inv.executeFill(order, sig, USDRIF_IN, NO_BOUND);

        assertEq(IERC20(USDT0).balanceOf(address(inv)), INVENTORY - USDT0_OUT, "normal fill unaffected");
    }

    // ──────────── Fill routes + window budget (re-audit F30) ────────────

    /// @dev Top the maker up and re-grant Settlement for another fill.
    function _refundMaker(uint256 amount) internal {
        deal(USDRIF, maker, amount);
        vm.prank(maker);
        permit3.approveToken(address(settlement), USDRIF, uint160(amount), 0);
    }

    /// THE FINDING. The per-call cap measured only what LEFT; a self-signed order
    /// paying the cap for a token nobody priced passed. Now a fill must return an
    /// owner-priced token: RIF has a sell route but no FILL route from USDT0.
    function test_fill_inventoryForAnUnpricedToken_reverts() public {
        Order memory rug = _usdrifOrder(90);
        rug.legsIn = _legsIn1(RIF, 1);
        deal(RIF, maker, 1);
        vm.prank(maker);
        IERC20(RIF).approve(address(permit3), type(uint256).max);
        bytes memory sig = _sign(rug);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(UsdrifInventorySolver.FillRouteNotAllowed.selector, USDT0, RIF));
        inv.executeFill(rug, sig, 1, NO_BOUND);
        assertEq(IERC20(USDT0).balanceOf(address(inv)), INVENTORY, "inventory untouched");
    }

    /// The priced token, at a junk price: 1 USDRIF-wei for the full fill.
    function test_fill_belowTheOwnersRate_reverts() public {
        Order memory rug = _usdrifOrder(91);
        rug.legsIn = _legsIn1(USDRIF, 1);
        bytes memory sig = _sign(rug);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                UsdrifInventorySolver.FillRateTooLow.selector, uint256(1), USDT0_OUT, USDT0_USDRIF_MIN_RATE
            )
        );
        inv.executeFill(rug, sig, 1, NO_BOUND);
    }

    /// Two output tokens (or two input tokens) cannot be priced by one route.
    function test_fill_mixedTokenShape_reverts() public {
        Order memory o = _usdrifOrder(92);
        LegOut[] memory outs = new LegOut[](2);
        outs[0] = LegOut(USDT0, USDT0_OUT, 0, address(0));
        outs[1] = LegOut(RIF, 1, 0, address(0));
        o.legsOut = PackedEncode.legsOut(outs);
        bytes memory sig = _sign(o);

        vm.prank(operator);
        vm.expectRevert(UsdrifInventorySolver.UnsupportedFillShape.selector);
        inv.executeFill(o, sig, USDRIF_IN, NO_BOUND);
    }

    /// The per-call cap had no memory, so a CONTRACT operator could loop it in one
    /// transaction. The window budget is cumulative: the second in-tx fill that
    /// would cross it reverts, and the budget refills only in the next window.
    function test_fill_loopInOneTxHitsTheWindowBudget() public {
        inv.setOutflowLimit(USDT0, USDT0_OUT + USDT0_OUT / 2); // room for 1.5 fills
        LoopOperator looper = new LoopOperator(inv);
        inv.setOperator(address(looper), true);

        _refundMaker(2 * USDRIF_IN);
        Order memory a = _usdrifOrder(93);
        Order memory b = _usdrifOrder(94);
        bytes memory sigA = _sign(a);
        bytes memory sigB = _sign(b);

        vm.expectRevert(
            abi.encodeWithSelector(
                UsdrifInventorySolver.OutflowWindowExceeded.selector,
                USDT0,
                2 * USDT0_OUT,
                USDT0_OUT + USDT0_OUT / 2
            )
        );
        looper.fillTwice(a, sigA, b, sigB, USDRIF_IN);

        // One fill fits; the second waits for the next window.
        vm.prank(operator);
        inv.executeFill(a, sigA, USDRIF_IN, NO_BOUND);
        vm.prank(operator);
        vm.expectRevert();
        inv.executeFill(b, sigB, USDRIF_IN, NO_BOUND);
        vm.warp(block.timestamp + inv.OUTFLOW_WINDOW());
        vm.prank(operator);
        inv.executeFill(b, sigB, USDRIF_IN, NO_BOUND);
        assertEq(IERC20(USDT0).balanceOf(address(inv)), INVENTORY - 2 * USDT0_OUT, "two windows, two fills");
    }

    /// Fail closed: with no window budget nothing leaves, whatever the per-call cap.
    function test_fill_zeroWindowBudget_refusesEverything() public {
        inv.setOutflowLimit(USDT0, 0);
        Order memory o = _usdrifOrder(95);
        bytes memory sig = _sign(o);
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(UsdrifInventorySolver.OutflowWindowExceeded.selector, USDT0, USDT0_OUT, uint256(0))
        );
        inv.executeFill(o, sig, USDRIF_IN, NO_BOUND);
    }

    /// The limit shares a slot with the usage, so it is 96 bits wide — an oversized
    /// limit is refused rather than silently capped.
    function test_outflowLimit_aboveUint96_reverts() public {
        uint256 tooBig = uint256(type(uint96).max) + 1;
        vm.expectRevert(abi.encodeWithSelector(UsdrifInventorySolver.OutflowLimitTooLarge.selector, tooBig));
        inv.setOutflowLimit(USDT0, tooBig);
        inv.setOutflowLimit(USDT0, type(uint96).max);
        assertEq(inv.outflowLimit(USDT0), type(uint96).max, "max representable limit accepted");
    }

    /// Changing the limit mid-window keeps what the window already spent: lowering
    /// it below the spend blocks the next fill; it is not a reset.
    function test_outflowLimit_changeMidWindowKeepsTheSpend() public {
        _refundMaker(2 * USDRIF_IN);
        Order memory a = _usdrifOrder(96);
        Order memory b = _usdrifOrder(97);
        bytes memory sigA = _sign(a);
        bytes memory sigB = _sign(b);

        vm.prank(operator);
        inv.executeFill(a, sigA, USDRIF_IN, NO_BOUND);
        (, uint96 used,) = inv.outflowBudget(USDT0);
        assertEq(used, USDT0_OUT, "spend recorded");

        inv.setOutflowLimit(USDT0, USDT0_OUT + 1); // re-set mid-window
        (, used,) = inv.outflowBudget(USDT0);
        assertEq(used, USDT0_OUT, "re-setting the limit did not reset the spend");

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                UsdrifInventorySolver.OutflowWindowExceeded.selector, USDT0, 2 * USDT0_OUT, USDT0_OUT + 1
            )
        );
        inv.executeFill(b, sigB, USDRIF_IN, NO_BOUND);
    }

    function test_fillRouteAndWindow_ownerOnly() public {
        vm.startPrank(operator);
        vm.expectRevert(UsdrifInventorySolver.NotOwner.selector);
        inv.setFillRoute(USDT0, USDRIF, 1);
        vm.expectRevert(UsdrifInventorySolver.NotOwner.selector);
        inv.setOutflowLimit(USDT0, type(uint256).max);
        vm.stopPrank();
    }

    /// Operators cannot raise their own ceiling.
    function test_operator_cannotRaiseTheCap() public {
        vm.prank(operator);
        vm.expectRevert(UsdrifInventorySolver.NotOwner.selector);
        inv.setMaxOutflowPerFill(USDT0, type(uint256).max);
    }

    // ──────────────── Sell routes (operator cannot redirect inventory) ────────────────

    function _fairVenue() internal returns (MockVenue venue) {
        venue = new MockVenue();
        inv.setAggregator(address(venue), true);
        deal(USDT0, address(venue), 10_000e6);
        deal(RIF, address(venue), 100_000e18);
        deal(USDRIF, address(venue), 10_000e18);
    }

    function _mockSwap(address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut, address recipient)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(MockVenue.swap, (tokenIn, amountIn, tokenOut, amountOut, recipient));
    }

    /// The finding's exact drain: through the WHITELISTED SwapRouter02, the
    /// operator sells the USDT0 inventory with `recipient = operator` and
    /// declares `tokenOut = RIF, minOut = 0`. The solver's RIF delta is 0 ≥ 0, so
    /// before routes this shipped the whole float to the operator in one call,
    /// around {maxOutflowPerFill}. Now: no USDT0→RIF route → refused; and even
    /// with one priced by the owner, the zero RIF delta fails the rate.
    function test_sell_drainPoC_reverts() public {
        bytes memory drain = abi.encodeCall(
            ISwapRouter02.exactInputSingle,
            (ISwapRouter02.ExactInputSingleParams({
                    tokenIn: USDT0,
                    tokenOut: RIF,
                    fee: RIF_USDT0_FEE,
                    recipient: operator,
                    amountIn: INVENTORY,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                }))
        );

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(UsdrifInventorySolver.RouteNotAllowed.selector, USDT0, RIF));
        inv.sell(SWAP_ROUTER_02, USDT0, RIF, type(uint256).max, 0, drain);

        // Owner opens USDT0→RIF (≥ 10 RIF per USDT0: 10e18 * 1e18 / 1e6 = 1e31)
        // with a 500-USDT0 budget. The full-inventory route now exceeds the
        // capped allowance, and a budget-sized redirect fails the rate.
        inv.setSellRoute(USDT0, RIF, 1e31, 500e6);

        vm.prank(operator);
        vm.expectRevert(); // router's transferFrom: allowance clamped to the 500e6 budget
        inv.sell(SWAP_ROUTER_02, USDT0, RIF, type(uint256).max, 0, drain);

        bytes memory drainBudget = abi.encodeCall(
            ISwapRouter02.exactInputSingle,
            (ISwapRouter02.ExactInputSingleParams({
                    tokenIn: USDT0,
                    tokenOut: RIF,
                    fee: RIF_USDT0_FEE,
                    recipient: operator,
                    amountIn: 500e6,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                }))
        );
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(UsdrifInventorySolver.RateTooLow.selector, 0, uint256(500e6), uint256(1e31))
        );
        inv.sell(SWAP_ROUTER_02, USDT0, RIF, type(uint256).max, 0, drainBudget);

        assertEq(IERC20(USDT0).balanceOf(address(inv)), INVENTORY, "inventory untouched");
        assertEq(IERC20(RIF).balanceOf(operator), 0, "operator received nothing");
        assertEq(IERC20(USDT0).allowance(address(inv), SWAP_ROUTER_02), 0, "no lingering allowance");
    }

    /// Junk output: an unrouted `tokenOut` is refused outright; a routed
    /// `tokenOut` with calldata that actually pays some OTHER token (here
    /// USDRIF) measures a zero delta and fails the rate.
    function test_sell_junkTokenOut_reverts() public {
        MockVenue venue = _fairVenue();
        deal(RIF, address(inv), 1_000e18);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(UsdrifInventorySolver.RouteNotAllowed.selector, RIF, USDRIF));
        inv.sell(address(venue), RIF, USDRIF, 1_000e18, 0, _mockSwap(RIF, 1_000e18, USDRIF, 1e18, address(inv)));

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                UsdrifInventorySolver.RateTooLow.selector, 0, uint256(1_000e18), uint256(RIF_USDT0_MIN_RATE)
            )
        );
        inv.sell(address(venue), RIF, USDT0, 1_000e18, 0, _mockSwap(RIF, 1_000e18, USDRIF, 1e18, address(inv)));

        // Output to the operator instead of the solver: same zero delta.
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                UsdrifInventorySolver.RateTooLow.selector, 0, uint256(1_000e18), uint256(RIF_USDT0_MIN_RATE)
            )
        );
        inv.sell(address(venue), RIF, USDT0, 1_000e18, 0, _mockSwap(RIF, 1_000e18, USDT0, 65e6, operator));
    }

    /// A sale below the owner's floor reverts even with `minOut = 0`; one wei
    /// of output at the floor passes (the check is `out * 1e18 >= spent * rate`).
    function test_sell_rateViolation_reverts() public {
        MockVenue venue = _fairVenue();
        deal(RIF, address(inv), 2_000e18);

        // 1000 RIF at the $0.06 floor = exactly 60 USDT0; 1 wei less fails.
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                UsdrifInventorySolver.RateTooLow.selector,
                uint256(60e6 - 1),
                uint256(1_000e18),
                uint256(RIF_USDT0_MIN_RATE)
            )
        );
        inv.sell(address(venue), RIF, USDT0, 1_000e18, 0, _mockSwap(RIF, 1_000e18, USDT0, 60e6 - 1, address(inv)));

        vm.prank(operator);
        uint256 out =
            inv.sell(address(venue), RIF, USDT0, 1_000e18, 0, _mockSwap(RIF, 1_000e18, USDT0, 60e6, address(inv)));
        assertEq(out, 60e6, "sale exactly at the floor clears");
    }

    /// Per-call spend budget: an explicit `amountIn` above it reverts, the
    /// `max` sentinel clamps the venue's allowance to it (so a route that pulls
    /// the full balance cannot execute), and a budget-sized sale goes through.
    function test_sell_spendAboveBudget_reverts() public {
        inv.setSellRoute(RIF, USDT0, RIF_USDT0_MIN_RATE, 400e18);
        MockVenue venue = _fairVenue();
        deal(RIF, address(inv), 1_000e18);

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                UsdrifInventorySolver.SellCapExceeded.selector, RIF, uint256(1_000e18), uint256(400e18)
            )
        );
        inv.sell(address(venue), RIF, USDT0, 1_000e18, 0, _mockSwap(RIF, 1_000e18, USDT0, 65e6, address(inv)));

        vm.prank(operator);
        vm.expectRevert(); // RIF transferFrom: allowance clamped to 400e18
        inv.sell(address(venue), RIF, USDT0, type(uint256).max, 0, _mockSwap(RIF, 1_000e18, USDT0, 65e6, address(inv)));

        vm.prank(operator);
        inv.sell(address(venue), RIF, USDT0, type(uint256).max, 0, _mockSwap(RIF, 400e18, USDT0, 26e6, address(inv)));
        assertEq(IERC20(RIF).balanceOf(address(inv)), 600e18, "exactly the budget left");
        assertEq(IERC20(RIF).allowance(address(inv), address(venue)), 0, "allowance revoked");
    }

    /// Happy path on the deterministic venue: in-budget, above-rate sale lands,
    /// `Sold` reports the MEASURED spend.
    function test_sell_happyPath_routedSale() public {
        MockVenue venue = _fairVenue();
        deal(RIF, address(inv), 1_000e18);

        vm.expectEmit(address(inv));
        emit UsdrifInventorySolver.Sold(address(venue), RIF, USDT0, 1_000e18, 65e6);
        vm.prank(operator);
        uint256 out = inv.sell(
            address(venue), RIF, USDT0, type(uint256).max, 64e6, _mockSwap(RIF, 1_000e18, USDT0, 65e6, address(inv))
        );

        assertEq(out, 65e6, "proceeds measured");
        assertEq(IERC20(RIF).balanceOf(address(inv)), 0, "RIF sold");
        assertEq(IERC20(USDT0).balanceOf(address(inv)), INVENTORY + 65e6, "USDT0 credited");
    }

    /// Closing a route (rate 0) re-closes `sell` for that pair; routes are
    /// owner-only.
    function test_sellRoute_closeAndAccess() public {
        vm.prank(operator);
        vm.expectRevert(UsdrifInventorySolver.NotOwner.selector);
        inv.setSellRoute(USDT0, RIF, 1, type(uint128).max);

        inv.setSellRoute(RIF, USDT0, 0, RIF_SELL_BUDGET);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(UsdrifInventorySolver.RouteNotAllowed.selector, RIF, USDT0));
        inv.sell(SWAP_ROUTER_02, RIF, USDT0, 1, 0, "");
    }

    /// `setAggregator` refuses every target that would make `sell` an
    /// arbitrary-call primitive from this identity; the constructor applies the
    /// same rule; revocation is always allowed; and token/aggregator sets can't
    /// overlap from the other direction either.
    function test_setAggregator_refusals() public {
        address[8] memory forbidden =
            [address(0), address(inv), address(permit3), address(settlement), MOC_CORE, MOC_QUEUE, USDRIF, USDT0];
        for (uint256 i; i < forbidden.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(UsdrifInventorySolver.ForbiddenAggregator.selector, forbidden[i]));
            inv.setAggregator(forbidden[i], true);
            inv.setAggregator(forbidden[i], false); // revocation never refused
        }
        // RIF became a known token through its sell route.
        vm.expectRevert(abi.encodeWithSelector(UsdrifInventorySolver.ForbiddenAggregator.selector, RIF));
        inv.setAggregator(RIF, true);

        // Other direction: a whitelisted venue can't become a route token or
        // fill inventory, and a pair must be two distinct tokens.
        vm.expectRevert(abi.encodeWithSelector(UsdrifInventorySolver.ForbiddenToken.selector, SWAP_ROUTER_02));
        inv.setSellRoute(RIF, SWAP_ROUTER_02, 1, 1);
        vm.expectRevert(abi.encodeWithSelector(UsdrifInventorySolver.ForbiddenToken.selector, SWAP_ROUTER_02));
        inv.setupTokenApproval(SWAP_ROUTER_02);
        vm.expectRevert(abi.encodeWithSelector(UsdrifInventorySolver.ForbiddenToken.selector, RIF));
        inv.setSellRoute(RIF, RIF, 1, 1);

        vm.expectRevert(abi.encodeWithSelector(UsdrifInventorySolver.ForbiddenAggregator.selector, address(permit3)));
        new UsdrifInventorySolver(
            address(permit3), address(settlement), address(permit3), MOC_CORE, MOC_QUEUE, USDRIF, USDT0
        );
    }

    /// Two-step ownership: nomination changes nothing until the nominee
    /// accepts; only the nominee can accept; the old owner is out afterwards.
    /// `sell` draws on the SAME window budget as fills, keyed by the token spent.
    function test_sell_drawsOnTheWindowBudget() public {
        MockVenue venue = _fairVenue();
        inv.setOutflowLimit(RIF, 100e18);
        deal(RIF, address(inv), 1_000e18);
        bytes memory data =
            abi.encodeCall(MockVenue.swap, (RIF, 150e18, USDT0, 10e6, address(inv)));
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(UsdrifInventorySolver.OutflowWindowExceeded.selector, RIF, 150e18, uint256(100e18))
        );
        inv.sell(address(venue), RIF, USDT0, 150e18, 0, data);
    }

    function test_ownership_twoStep() public {
        address nominee = makeAddr("nominee");

        vm.prank(operator);
        vm.expectRevert(UsdrifInventorySolver.NotOwner.selector);
        inv.transferOwnership(operator);

        vm.expectEmit(address(inv));
        emit UsdrifInventorySolver.OwnershipTransferStarted(address(this), nominee);
        inv.transferOwnership(nominee);
        assertEq(inv.owner(), address(this), "owner unchanged until accepted");
        assertEq(inv.pendingOwner(), nominee, "nominee pending");

        vm.prank(operator);
        vm.expectRevert(UsdrifInventorySolver.NotPendingOwner.selector);
        inv.acceptOwnership();

        vm.expectEmit(address(inv));
        emit UsdrifInventorySolver.OwnershipTransferred(address(this), nominee);
        vm.prank(nominee);
        inv.acceptOwnership();
        assertEq(inv.owner(), nominee, "nominee is owner");
        assertEq(inv.pendingOwner(), address(0), "nomination consumed");

        vm.expectRevert(UsdrifInventorySolver.NotOwner.selector);
        inv.setOperator(address(this), true);
    }
}

/// @dev A contract operator — the shape that let a per-call cap be looped inside
///      one transaction.
contract LoopOperator {
    UsdrifInventorySolver internal immutable inv;

    constructor(UsdrifInventorySolver inv_) {
        inv = inv_;
    }

    function fillTwice(Order calldata a, bytes calldata sigA, Order calldata b, bytes calldata sigB, uint256 amt)
        external
    {
        inv.executeFill(a, sigA, amt, type(uint256).max);
        inv.executeFill(b, sigB, amt, type(uint256).max);
    }
}
