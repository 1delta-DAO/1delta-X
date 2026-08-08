// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "../shared/PackedEncode.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {Order, Item, ItemOp, LegIn, LegOut, Validator, OrderSide} from "@core/settlement/Settlement.sol";

import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

/// @dev TAKE mock: simulates a borrow/withdraw. On dispatch it transfers a
///      pre-configured `produce` amount of `token` (both encoded in `data`)
///      from its own stash to `receiver` — decoupled from the gated `amount`
///      so tests can drive exact / surplus / shortfall proceeds paths.
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

/// @dev MAKE mock: simulates a deposit. Pulls `amount` of `token` (encoded in
///      `data`) from the maker via Permit3 into itself.
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

/// @dev Lending-item constellations for the multi-asset conversion leg,
///      exercising Settlement's per-input proceeds accounting directly with
///      mock modules (no real lender): exact proceeds, surplus→maker,
///      shortfall→maker-pull, anti-donation, recipient routing, MAKE pull, and
///      a multi-input order funded partly by a TAKE and partly from the maker.
contract MultiAssetItemsTest is CoreSettlementBase {
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    MockFundingTaker taker;
    MockDepositMaker depositor;

    function setUp() public override {
        super.setUp();
        vm.label(DAI, "DAI");
        taker = new MockFundingTaker(address(permit3));
        depositor = new MockDepositMaker(address(permit3), address(settlement));
        vm.startPrank(maker);
        IERC20(DAI).approve(address(permit3), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(solver);
        IERC20(DAI).approve(address(permit3), type(uint256).max);
        vm.stopPrank();
    }

    // ──────────────────── helpers ────────────────────

    function _orderItems(
        uint256 nonce,
        address[] memory tokenIn,
        uint256[] memory amountIn,
        address[] memory tokenOut,
        uint256[] memory amountOut,
        Item[] memory items
    ) internal view returns (Order memory) {
        LegIn[] memory legsIn = new LegIn[](tokenIn.length);
        for (uint256 i; i < tokenIn.length; i++) {
            legsIn[i] = LegIn(tokenIn[i], amountIn[i], 0);
        }
        LegOut[] memory legsOut = new LegOut[](tokenOut.length);
        for (uint256 j; j < tokenOut.length; j++) {
            legsOut[j] = LegOut(tokenOut[j], amountOut[j], 0, address(0));
        }
        return Order({
            maker: maker,
            nonce: nonce,
            deadline: block.timestamp + 1 hours,
            legsIn: PackedEncode.legsIn(legsIn),
            legsOut: PackedEncode.legsOut(legsOut),
            timing: 0,
            exclusiveFiller: address(0),
            minFillAnchor: 0,
            exclusivityOverrideBps: 0,
            curve: PackedEncode.noCurve(),
            gasBumpBps: 0,
            gasPriceRef: 0,
            items: PackedEncode.items(items),
            validators: PackedEncode.noValidators(),
            invariants: PackedEncode.noValidators(),
            fillModule: address(0),
            fillTotal: 0
        });
    }

    /// @dev Approve the TAKE gate: maker lets Settlement consume up to `amount`
    ///      on the (spender=Settlement, ref=keccak256(data)) taker allowance.
    function _approveTake(bytes memory data, uint256 amount) internal {
        vm.prank(maker);
        permit3.approveTaker(address(settlement), keccak256(data), uint160(amount), uint48(block.timestamp + 1 hours));
    }

    function _takeItem(uint256 amount, address recipient, address token, uint256 produce)
        internal
        view
        returns (Item memory)
    {
        return Item({
            op: ItemOp.TAKE,
            module: address(taker),
            amount: amount,
            recipient: recipient,
            data: abi.encode(token, produce)
        });
    }

    function _one(Item memory it) internal pure returns (Item[] memory arr) {
        arr = new Item[](1);
        arr[0] = it;
    }

    // ──────────────────── TAKE funds the input leg ────────────────────

    /// @dev Borrow flow: the input USDC is produced by a TAKE (recipient =
    ///      Settlement) exactly equal to what's owed. Solver is paid from the
    ///      proceeds; the maker's own USDC is never touched.
    function test_take_fundsInput_exact() public {
        uint256 usdcIn = 1_500e6;
        uint256 wethOut = 1 ether;

        deal(WETH, solver, wethOut);
        deal(USDC, address(taker), usdcIn); // borrow inventory
        _approveSolverSide(wethOut, WETH);

        Item memory it = _takeItem(usdcIn, address(0), USDC, usdcIn);
        _approveTake(it.data, usdcIn);
        Order memory order = _orderItems(0, _a1(USDC), _u1(usdcIn), _a1(WETH), _u1(wethOut), _one(it));
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, usdcIn);

        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver paid from borrow proceeds");
        assertEq(IERC20(WETH).balanceOf(maker), wethOut, "maker received WETH");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "maker USDC untouched");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement drained");
    }

    /// @dev TAKE produces MORE than owed → the surplus is returned to the maker.
    function test_take_surplus_returnedToMaker() public {
        uint256 usdcIn = 1_500e6;
        uint256 produce = 1_600e6;
        uint256 wethOut = 1 ether;

        deal(WETH, solver, wethOut);
        deal(USDC, address(taker), produce);
        _approveSolverSide(wethOut, WETH);

        Item memory it = _takeItem(usdcIn, address(0), USDC, produce);
        _approveTake(it.data, usdcIn);
        Order memory order = _orderItems(1, _a1(USDC), _u1(usdcIn), _a1(WETH), _u1(wethOut), _one(it));
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, usdcIn);

        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver paid exactly owed");
        assertEq(IERC20(USDC).balanceOf(maker), produce - usdcIn, "surplus to maker");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement drained");
    }

    /// @dev TAKE produces LESS than owed → the shortfall is pulled from the maker.
    function test_take_shortfall_pulledFromMaker() public {
        uint256 usdcIn = 1_500e6;
        uint256 produce = 1_400e6;
        uint256 shortfall = usdcIn - produce;
        uint256 wethOut = 1 ether;

        deal(WETH, solver, wethOut);
        deal(USDC, address(taker), produce);
        deal(USDC, maker, shortfall);
        _approveMakerToSettlement(USDC, shortfall); // gate for the shortfall pull
        _approveSolverSide(wethOut, WETH);

        Item memory it = _takeItem(usdcIn, address(0), USDC, produce);
        _approveTake(it.data, usdcIn);
        Order memory order = _orderItems(2, _a1(USDC), _u1(usdcIn), _a1(WETH), _u1(wethOut), _one(it));
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, usdcIn);

        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver still receives full owed");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "maker's shortfall was pulled");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement drained");
    }

    /// @dev A pre-existing (donated) Settlement balance is NOT redirected to the
    ///      solver — only THIS fill's TAKE proceeds are, measured as a delta.
    function test_take_antiDonation() public {
        uint256 usdcIn = 1_500e6;
        uint256 donation = 500e6;
        uint256 wethOut = 1 ether;

        deal(WETH, solver, wethOut);
        deal(USDC, address(taker), usdcIn);
        deal(USDC, address(settlement), donation); // stray/donated balance
        _approveSolverSide(wethOut, WETH);

        Item memory it = _takeItem(usdcIn, address(0), USDC, usdcIn);
        _approveTake(it.data, usdcIn);
        Order memory order = _orderItems(3, _a1(USDC), _u1(usdcIn), _a1(WETH), _u1(wethOut), _one(it));
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, usdcIn);

        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver got only this-fill proceeds");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), donation, "donation retained, not paid out");
    }

    /// @dev recipient = maker routes the withdrawn proceeds to the maker's wallet;
    ///      Settlement then sees no proceeds and pulls the owed input from the
    ///      maker — the output has flowed through the maker's own balance.
    function test_take_recipientRouting_toMaker() public {
        uint256 usdcIn = 1_500e6;
        uint256 wethOut = 1 ether;

        deal(WETH, solver, wethOut);
        deal(USDC, address(taker), usdcIn);
        _approveMakerToSettlement(USDC, usdcIn); // Settlement pulls the owed input from maker
        _approveSolverSide(wethOut, WETH);

        Item memory it = _takeItem(usdcIn, maker, USDC, usdcIn); // recipient = maker
        _approveTake(it.data, usdcIn);
        Order memory order = _orderItems(4, _a1(USDC), _u1(usdcIn), _a1(WETH), _u1(wethOut), _one(it));
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, usdcIn);

        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver received the owed input");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "maker net-neutral (received then paid)");
        assertEq(IERC20(WETH).balanceOf(maker), wethOut, "maker received WETH output");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement drained");
    }

    // ──────────────────── MAKE deposit ────────────────────

    /// @dev A MAKE leg funded by the output: solver pays WETH to the maker, then
    ///      a deposit module pulls part of it back out of the maker's wallet.
    function test_make_depositFromOutput() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;
        uint256 deposit = 0.9 ether;

        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);
        _approveMakerToSettlement(USDC, usdcIn);
        _approveSolverSide(wethOut, WETH);
        // Maker lets the deposit module pull WETH.
        vm.prank(maker);
        permit3.approveToken(address(depositor), WETH, uint160(deposit), uint48(block.timestamp + 1 hours));

        Item memory it = Item({
            op: ItemOp.MAKE, module: address(depositor), amount: deposit, recipient: address(0), data: abi.encode(WETH)
        });
        Order memory order = _orderItems(5, _a1(USDC), _u1(usdcIn), _a1(WETH), _u1(wethOut), _one(it));
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, usdcIn);

        assertEq(IERC20(WETH).balanceOf(address(depositor)), deposit, "module received the deposit");
        assertEq(IERC20(WETH).balanceOf(maker), wethOut - deposit, "maker kept the remainder");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver received USDC");
    }

    // ──────────────────── multi-input mixed funding ────────────────────

    /// @dev Two inputs: USDC comes from a TAKE (borrow proceeds), DAI is pulled
    ///      straight from the maker. Both land with the solver; only the DAI leg
    ///      debits the maker.
    function test_multiIn_mixedFunding_takeAndMaker() public {
        uint256 usdcIn = 1_500e6; // amountIn[0], funded by TAKE
        uint256 daiIn = 500e18; //   amountIn[1], funded by maker
        uint256 wethOut = 1 ether;

        deal(WETH, solver, wethOut);
        deal(USDC, address(taker), usdcIn);
        deal(DAI, maker, daiIn);
        _approveMakerToSettlement(DAI, daiIn);
        _approveSolverSide(wethOut, WETH);

        Item memory it = _takeItem(usdcIn, address(0), USDC, usdcIn);
        _approveTake(it.data, usdcIn);
        Order memory order = _orderItems(6, _a2(USDC, DAI), _u2(usdcIn, daiIn), _a1(WETH), _u1(wethOut), _one(it));
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, usdcIn);

        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver got USDC from TAKE");
        assertEq(IERC20(DAI).balanceOf(solver), daiIn, "solver got DAI from maker");
        assertEq(IERC20(DAI).balanceOf(maker), 0, "maker debited only the DAI leg");
        assertEq(IERC20(WETH).balanceOf(maker), wethOut, "maker received WETH");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(DAI).balanceOf(address(settlement)), 0, "settlement DAI drained");
    }

    /// @dev A tokenIn leg whose `owed` floors to 0 on a partial fill, while a
    ///      TAKE produced that same token into Settlement. The zero-owed leg must
    ///      REFUND those proceeds to the maker — never strand them (there is no
    ///      sweep). Regression guard for the `owed == 0` proceeds-refund fix.
    function test_take_dustOwedZeroLeg_refundsProceedsNotStranded() public {
        uint256 usdcAnchor = 1_000e6; // tokenIn[0] anchor
        uint256 daiDust = 1; //         tokenIn[1] = 1 wei ⇒ owed floors to 0 on a half fill
        uint256 wethOut = 0.1 ether;
        uint256 daiProduced = 50e18; //  the DAI leg's TAKE proceeds

        deal(WETH, solver, wethOut);
        deal(DAI, address(taker), daiProduced); // TAKE inventory
        deal(USDC, maker, usdcAnchor / 2); //     maker funds the anchor half-slice
        _approveMakerToSettlement(USDC, usdcAnchor / 2);
        _approveSolverSide(wethOut, WETH);

        // TAKE deposits DAI → Settlement: the proceeds attributed to the DAI leg.
        Item memory it = _takeItem(100e18, address(0), DAI, daiProduced);
        _approveTake(it.data, 100e18);

        Order memory order = _orderItems(9, _a2(USDC, DAI), _u2(usdcAnchor, daiDust), _a1(WETH), _u1(wethOut), _one(it));
        bytes memory sig = _sign(order);

        uint256 makerDaiBefore = IERC20(DAI).balanceOf(maker);

        // Half fill ⇒ DAI leg owed = floor(1 * 500e6 / 1000e6) = 0.
        vm.prank(solver);
        settlement.fill(order, sig, usdcAnchor / 2);

        assertEq(IERC20(DAI).balanceOf(maker) - makerDaiBefore, daiProduced, "zero-owed leg proceeds refunded to maker");
        assertEq(IERC20(DAI).balanceOf(address(settlement)), 0, "no DAI stranded in settlement");
        assertEq(IERC20(USDC).balanceOf(solver), usdcAnchor / 2, "solver paid the anchor half-slice");
    }

    function _a2(address a, address b) internal pure returns (address[] memory r) {
        r = new address[](2);
        r[0] = a;
        r[1] = b;
    }

    function _u2(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }
}
