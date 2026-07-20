// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, OrderSide, Item, Validator} from "@core/settlement/Settlement.sol";
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

    UsdrifInventorySolver inv;
    address operator = makeAddr("operator");

    receive() external payable {} // for the RBTC withdraw test

    function setUp() public override {
        super.setUp();

        inv = new UsdrifInventorySolver(
            address(permit3), address(settlement), SWAP_ROUTER_02, MOC_CORE, MOC_QUEUE, USDRIF, USDT0
        );
        inv.setOperator(operator, true);
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
            (
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: fee,
                    recipient: address(inv),
                    amountIn: amountIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            )
        );
    }

    /// @dev Plain USDRIF→USDT0 exit order (fixed price, no validators) — the
    ///      inventory-solver variant needs no order-side machinery at all.
    function _usdrifOrder(uint256 nonce) internal view returns (Order memory) {
        return Order({
            maker: maker,
            side: OrderSide.SELL,
            nonce: nonce,
            deadline: block.timestamp + 1 hours,
            tokenIn: _a1(USDRIF),
            tokenOut: _a1(USDT0),
            startAmountIn: _u1(USDRIF_IN),
            endAmountIn: _u1(USDRIF_IN),
            decayStartTime: 0,
            decayDuration: 0,
            startAmountOut: _u1(USDT0_OUT),
            endAmountOut: _u1(USDT0_OUT),
            recipientOut: new address[](1),
            exclusiveFiller: address(0),
            exclusivityEndTime: 0,
            minFillAnchor: 0,
            exclusivityOverrideBps: 0,
            curve: _noCurve(),
            gasBumpBps: 0,
            gasPriceRef: 0,
            items: new Item[](0),
            validators: new Validator[](0),
            invariants: new Validator[](0),
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
        uint256 paid = inv.executeFill(order, sig, USDRIF_IN)[0];

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
        (uint256[] memory paid, uint256 opId) = inv.executeFillAndRedeem(order, sig, USDRIF_IN, QAC_MIN);

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
        (, uint256 opId) = inv.executeFillAndRedeem(order, sig, USDRIF_IN, QAC_MIN);

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
        inv.executeFill(order, sig, USDRIF_IN);
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

    /// The output floor is enforced by measured balances, not by trusting the
    /// venue: a venue that consumes the allowance and delivers nothing reverts
    /// the whole sale atomically (its transferFrom unwinds too).
    function test_sell_enforcesMinOutByBalanceDelta() public {
        RugVenue venue = new RugVenue();
        inv.setAggregator(address(venue), true);
        deal(RIF, address(inv), 1_000e18);

        bytes memory rugData = abi.encodeCall(RugVenue.take, (RIF, address(inv), 1_000e18));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(UsdrifInventorySolver.InsufficientOutput.selector, 0, 1));
        inv.sell(address(venue), RIF, USDT0, 1_000e18, 1, rugData);

        assertEq(IERC20(RIF).balanceOf(address(inv)), 1_000e18, "revert unwound the venue's pull");

        // Same venue, minOut 0: the operator explicitly accepted any outcome.
        vm.prank(operator);
        inv.sell(address(venue), RIF, USDT0, 1_000e18, 0, rugData);
        assertEq(IERC20(RIF).balanceOf(address(inv)), 0, "minOut 0 lets the sale through");
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
}
