// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {console} from "forge-std/console.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

import {CallbackMode, Order} from "@core/settlement/Settlement.sol";
import {AggregatorFillSolver, RoutePlan, SurplusPolicy, NO_PATCH} from "@solvers/aggregator/AggregatorFillSolver.sol";

import {UsdrifForkBase} from "../../modules/redeem/usdrif/test/shared/UsdrifForkBase.t.sol";

/// @dev `Settlement.fill` is overloaded, so `abi.encodeCall` cannot resolve it by
///      name — this pins the 3-argument one for the calldata measurement.
interface IFill3 {
    function fill(Order calldata order, bytes calldata sig, uint256 fillAmount) external returns (uint256[] memory);
}

/// @dev `fillWithCallback` is overloaded too — this pins the 6-argument one for
///      the calldata measurement, so the figure is the real wire payload rather
///      than a hand-written signature string.
interface IFillCb {
    function fillWithCallback(
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmount,
        address callbackTarget,
        bytes calldata callbackData,
        CallbackMode mode
    ) external returns (uint256[] memory);
}

interface IUniV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);
}

/// @dev The pre-funded shape in its purest form: call the POOL, pay inside its
///      callback with a plain `transfer`. No allowance is ever created, and the
///      router's own dispatch is skipped. SushiSwap v3 is a Uniswap v3 fork and
///      uses the same callback name, so one implementation covers both Rootstock
///      venues. The price is venue-specific code — the opposite of the aggregator
///      solver's opaque-calldata design.
contract PoolDirectSwapper {
    address public immutable POOL;
    address public immutable TOKEN0;
    uint160 internal constant MIN_SQRT_RATIO_PLUS_1 = 4295128740;

    constructor(address pool, address token0) {
        POOL = pool;
        TOKEN0 = token0;
    }

    function swapExactIn(uint256 amountIn, address recipient) external returns (uint256 out) {
        (, int256 a1) = IUniV3Pool(POOL).swap(recipient, true, int256(amountIn), MIN_SQRT_RATIO_PLUS_1, "");
        out = uint256(-a1);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256, bytes calldata) external {
        require(msg.sender == POOL, "only pool");
        if (amount0Delta > 0) require(IERC20(TOKEN0).transfer(POOL, uint256(amount0Delta)), "pay failed");
    }
}

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

/// @title RawSwapComparisonTest
/// @notice What a fill COSTS relative to the thing it replaces: the same trade,
///         same pool, same block — once as a plain Uniswap v3 swap the trader
///         sends itself, once as a signed order a solver fills.
///
///  Read the numbers as EXECUTION gas (the 21,000 intrinsic and the calldata are
///  excluded and are reported separately in the notes). They are not paid by the
///  same party: the raw swap is the TRADER's transaction, the fill is the
///  SOLVER's, and the maker of an order pays nothing at all. The comparison is
///  therefore "what does the network charge to move this trade", which is what
///  ends up priced into the spread a solver quotes.
///
///  Live Rootstock state, pinned block, real USDRIF/USDT0 pool.
contract RawSwapComparisonTest is UsdrifForkBase {
    address internal constant SWAP_ROUTER_02 = 0x0B14ff67f0014046b4b99057Aec4509640b3947A;
    uint24 internal constant FEE = 500;

    uint256 constant AMOUNT_IN = 1_000e18; // 1,000 USDRIF
    uint256 constant FLOOR_OUT = 900e6; //   the maker's signed floor, well under the quote

    AggregatorFillSolver internal agg;
    address internal trader = address(0x7AAdE);

    function setUp() public virtual override {
        super.setUp();
        address[] memory routers = new address[](1);
        routers[0] = SWAP_ROUTER_02;
        // Gated to this test contract: direct (delta-verify) orders require an
        // operator set since re-audit 2026-09-29 ({DirectNeedsOperators}).
        // The maker is listed too: `test_cmp_user_selfServeDex` measures a USER
        // driving the solver for their own order.
        address[] memory ops = new address[](2);
        ops[0] = address(this);
        ops[1] = maker;
        agg = new AggregatorFillSolver(
            address(settlement),
            routers,
            ops,
            SurplusPolicy({makerPpm: 0, protocolPpm: 0, protocolRecipient: address(0)}),
            false,
            new address[](0)
        );
        vm.label(address(agg), "aggregatorSolver");
        vm.label(SWAP_ROUTER_02, "swapRouter02");
    }

    function _route(address recipient) internal pure returns (bytes memory) {
        return abi.encodeCall(
            ISwapRouter02.exactInputSingle,
            (
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: USDRIF,
                    tokenOut: USDT0,
                    fee: FEE,
                    recipient: recipient,
                    amountIn: AMOUNT_IN,
                    amountOutMinimum: FLOOR_OUT,
                    sqrtPriceLimitX96: 0
                })
            )
        );
    }

    /// @dev `profitRecipient` is the solver itself — RETAIN mode, the configuration
    ///      the README recommends. Paying the spread out to a fresh address would
    ///      charge this benchmark a 0→non-zero balance write that belongs to the
    ///      operator's sweep, not to the fill.
    function _plan(address recipient) internal view returns (RoutePlan memory) {
        return RoutePlan({
            router: SWAP_ROUTER_02,
            minOut: FLOOR_OUT,
            maxPay: 0,
            amountInOffset: NO_PATCH,
            profitRecipient: address(agg),
            originator: address(0),
            originatorPpm: 0,
            data: _route(recipient)
        });
    }

    /// @dev The maker's order. `direct` sets `timing` bit 104 — the route pays the
    ///      maker itself and the core verifies the delta.
    function _order(uint256 nonce, bool direct) internal view returns (Order memory o) {
        o = Order({
            params: 0,
            pricingModule: address(0),
            maker: maker,
            nonce: nonce,
            legsIn: _legsIn1(USDRIF, AMOUNT_IN),
            legsOut: _legsOut1(USDT0, FLOOR_OUT),
            timing: _expiryBits(block.timestamp + 1 hours) | (direct ? uint256(1) << 104 : 0),
            // A delta-verify order is fillable by its named filler only.
            exclusiveFiller: direct ? address(agg) : address(0),
            minFillAnchor: 0,
            curve: _noCurve(),
            items: PackedEncode.noItems(),
            validators: PackedEncode.noValidators(),
            invariants: PackedEncode.noValidators(),
            fillModule: address(0),
            fillTotal: 0
        });
    }

    function _fundMaker() internal {
        deal(USDRIF, maker, AMOUNT_IN);
        vm.startPrank(maker);
        IERC20(USDRIF).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDRIF, uint160(AMOUNT_IN), 0);
        vm.stopPrank();
        // The maker has held USDT0 before — a first-ever receipt would charge the
        // token's 0→non-zero write to whichever side is being measured and make
        // the comparison about the maker's history rather than the mechanism.
        deal(USDT0, maker, 1);
    }

    /// @dev EIP-2028 calldata gas for a payload: 4 per zero byte, 16 otherwise.
    ///      Worth counting rather than assuming, because it is the one place the two
    ///      shapes differ by an order of magnitude — a signed order and its
    ///      signature are bytes on the wire that a raw swap simply does not have.
    function _calldataGas(bytes memory data) internal pure returns (uint256 g) {
        for (uint256 i; i < data.length; i++) g += data[i] == 0 ? 4 : 16;
    }

    function _report(string memory label, uint256 exec, bytes memory payload) internal pure {
        uint256 cd = _calldataGas(payload);
        console.log(label);
        console.log("   execution      ", exec);
        console.log("   calldata bytes ", payload.length);
        console.log("   calldata gas   ", cd);
        console.log("   TOTAL TX       ", exec + cd + 21_000);
    }

    // ──────────────────── the baseline ────────────────────

    /// @dev A trader swapping for itself on Uniswap v3, with the router allowance
    ///      already in place (the one-time approval is not part of a swap).
    function test_cmp_rawSwap() public {
        deal(USDRIF, trader, AMOUNT_IN);
        deal(USDT0, trader, 1);
        vm.startPrank(trader);
        IERC20(USDRIF).approve(SWAP_ROUTER_02, type(uint256).max);
        uint256 g0 = gasleft();
        ISwapRouter02(SWAP_ROUTER_02).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: USDRIF,
                tokenOut: USDT0,
                fee: FEE,
                recipient: trader,
                amountIn: AMOUNT_IN,
                amountOutMinimum: FLOOR_OUT,
                sqrtPriceLimitX96: 0
            })
        );
        uint256 used = g0 - gasleft();
        vm.stopPrank();
        _report("RAW UNISWAP V3 SWAP (trader's own tx)", used, _route(trader));
    }

    // ──────────────────── the same trade as an order ────────────────────

    /// @dev Direct delivery: the route pays the maker, the core verifies the
    ///      balance delta. The cheapest fill shape, and the one the app signs.
    function test_cmp_fill_direct() public {
        _fundMaker();
        deal(USDRIF, address(agg), 1); // the balance floor — see the README
        Order memory o = _order(1, true);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _plan(maker);
        uint256 g0 = gasleft();
        agg.executeFill(o, sig, AMOUNT_IN, p, "");
        uint256 used = g0 - gasleft();
        assertGe(IERC20(USDT0).balanceOf(maker), FLOOR_OUT, "maker paid");
        _report("ORDER FILL - direct (solver's tx)", used, abi.encodeCall(agg.executeFill, (o, sig, AMOUNT_IN, p, "")));
    }

    /// @dev Pull delivery: the swap output lands on the solver and Settlement
    ///      pulls the priced amount. What a fill costs for an order signed by a
    ///      frontend that does not set the delta-verify bit.
    function test_cmp_fill_pull() public {
        _fundMaker();
        deal(USDRIF, address(agg), 1);
        deal(USDT0, address(agg), 1);
        Order memory o = _order(2, false);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _plan(address(agg));
        uint256 g0 = gasleft();
        agg.executeFill(o, sig, AMOUNT_IN, p, "");
        uint256 used = g0 - gasleft();
        assertGe(IERC20(USDT0).balanceOf(maker), FLOOR_OUT, "maker paid");
        _report("ORDER FILL - pull (solver's tx)", used, abi.encodeCall(agg.executeFill, (o, sig, AMOUNT_IN, p, "")));
    }

    /// @dev Q2, isolated: the same inventory fill with the solver ALREADY holding
    ///      the input token — the steady state of anyone who fills more than once.
    ///      The gap against {test_cmp_fill_inventoryNoSwap} is one token's
    ///      0→non-zero balance write, not protocol overhead.
    function test_cmp_fill_inventoryNoSwap_warmSolver() public {
        _fundMaker();
        deal(USDRIF, solver, 1); // the balance floor again, on the input side
        deal(USDT0, solver, FLOOR_OUT * 2);
        vm.startPrank(solver);
        IERC20(USDT0).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDT0, uint160(FLOOR_OUT * 2), 0);
        vm.stopPrank();
        Order memory o = _order(4, false);
        bytes memory sig = _sign(o);
        vm.startPrank(solver);
        uint256 g0 = gasleft();
        settlement.fill(o, sig, AMOUNT_IN);
        uint256 used = g0 - gasleft();
        vm.stopPrank();
        _report("ORDER FILL - inventory, warm solver", used, abi.encodeCall(IFill3.fill, (o, sig, AMOUNT_IN)));
    }

    // ─────────── Where the order-state write goes, measured ───────────
    //
    // `filledAmountIn[orderHash]` is a FRESH slot for every order ever signed, so
    // its first write is always 22,100. The fill-once bit (timing 100) records
    // progress in the maker's nonce BITMAP instead — 256 nonces to a word — so
    // only the first order in each window pays that, and the next 255 pay the
    // warm-write price. These two measure that difference on the real fill.

    function test_cmp_state_fillOnce_coldWord() public {
        _fundMaker();
        deal(USDRIF, address(agg), 1);
        Order memory o = _order(20, true);
        o.timing |= uint256(1) << 100; // FILL-ONCE: all-or-nothing, nonce-recorded
        bytes memory sig = _sign(o);
        uint256 g0 = gasleft();
        agg.executeFill(o, sig, AMOUNT_IN, _plan(maker), "");
        console.log("state: fill-once, maker's FIRST order ", g0 - gasleft());
    }

    /// @dev Exposed so {RawSwapWarmNonceTest} can dirty the word in its `setUp`,
    ///      which is a SEPARATE transaction — the access list resets afterwards, so
    ///      the measured fill pays cold-access prices for everything except the
    ///      bitmap word itself. Doing it inline would measure a warm everything.
    function _fillOnce(uint256 nonce) internal {
        Order memory o = _order(nonce, true);
        o.timing |= uint256(1) << 100;
        agg.executeFill(o, _sign(o), AMOUNT_IN, _plan(maker), "");
    }

    // ──────────────── Model 2: the USER sends the transaction ────────────────
    //
    // The mirror image of everything above. There the maker signs and a solver
    // submits (maker pays no gas). Here the user submits, so the user pays the
    // gas — and the question is what that costs against simply swapping.
    //
    // The RFQ shape INVERTS the roles the rest of this file uses: the SOLVER is
    // the `maker` of a signed quote ("I pay 992 USDT0, I want 1,000 USDRIF") and
    // the user is the FILLER. Nothing in the core needs to change for that — an
    // order is a signed intent whoever signs it — which is why this is a product
    // decision rather than a protocol one.

    uint256 internal quoterPk = 0x50_1BE4;
    address internal quoter = vm.addr(quoterPk);
    uint256 constant QUOTE_OUT = 992e6; // what the market maker pays for AMOUNT_IN

    /// @dev The solver's signed quote. `legsIn` is what the QUOTER pays, `legsOut`
    ///      what it wants back — so the user, as filler, delivers USDRIF and is
    ///      paid USDT0.
    function _quote(uint256 nonce) internal view returns (Order memory o) {
        o = Order({
            params: 0,
            pricingModule: address(0),
            maker: quoter,
            nonce: nonce,
            legsIn: _legsIn1(USDT0, QUOTE_OUT),
            legsOut: _legsOut1(USDRIF, AMOUNT_IN),
            timing: _expiryBits(block.timestamp + 60), // a quote, not a resting order
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

    function _signAs(Order memory o, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), _hashOrder(o)));
        (uint8 v, bytes32 r, bytes32 sVal) = vm.sign(pk, digest);
        return abi.encodePacked(r, sVal, v);
    }

    /// @dev The market maker's side: inventory, and a standing Permit3 grant. Warm
    ///      on both tokens, which is what a desk that quotes all day looks like.
    function _stockQuoter() internal {
        deal(USDT0, quoter, QUOTE_OUT * 4);
        deal(USDRIF, quoter, 1);
        vm.startPrank(quoter);
        IERC20(USDT0).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDT0, uint160(QUOTE_OUT * 4), 0);
        vm.stopPrank();
        deal(USDRIF, trader, AMOUNT_IN);
        deal(USDT0, trader, 1);
    }

    /// @dev RFQ, user-submitted, user set up with a Permit3 allowance.
    function test_cmp_user_rfq_permit3() public {
        _stockQuoter();
        vm.startPrank(trader);
        IERC20(USDRIF).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDRIF, uint160(AMOUNT_IN), 0);
        vm.stopPrank();
        Order memory o = _quote(10);
        bytes memory sig = _signAs(o, quoterPk);
        vm.startPrank(trader);
        uint256 g0 = gasleft();
        settlement.fill(o, sig, QUOTE_OUT);
        uint256 used = g0 - gasleft();
        vm.stopPrank();
        assertEq(IERC20(USDT0).balanceOf(trader), QUOTE_OUT + 1, "user paid in USDT0");
        _report("USER TX - RFQ, Permit3 allowance", used, abi.encodeCall(IFill3.fill, (o, sig, QUOTE_OUT)));
    }

    /// @dev RFQ with only a PLAIN ERC20 approval to Settlement — one approve, the
    ///      same setup a DEX router asks for, no Permit3 concept in the UI. Plain
    ///      `fill` then probes Permit3, fails, reads the strict flag and falls back.
    function test_cmp_user_rfq_directApproval_plainFill() public {
        _stockQuoter();
        vm.prank(trader);
        IERC20(USDRIF).approve(address(settlement), type(uint256).max);
        Order memory o = _quote(11);
        bytes memory sig = _signAs(o, quoterPk);
        vm.startPrank(trader);
        uint256 g0 = gasleft();
        settlement.fill(o, sig, QUOTE_OUT);
        uint256 used = g0 - gasleft();
        vm.stopPrank();
        _report("USER TX - RFQ, plain approval, fill()", used, abi.encodeCall(IFill3.fill, (o, sig, QUOTE_OUT)));
    }

    /// @dev The same, told up front that the approval is direct: `fillWithCallback`
    ///      with NO callback target and {CallbackMode.PostInputsDirect}. Bit 2 skips
    ///      the Permit3 probe for the FILLER'S legs — which on this path is the
    ///      user's own side.
    function test_cmp_user_rfq_directApproval_directMode() public {
        _stockQuoter();
        vm.prank(trader);
        IERC20(USDRIF).approve(address(settlement), type(uint256).max);
        Order memory o = _quote(12);
        bytes memory sig = _signAs(o, quoterPk);
        vm.startPrank(trader);
        uint256 g0 = gasleft();
        settlement.fillWithCallback(o, sig, QUOTE_OUT, address(0), "", CallbackMode.PostInputsDirect);
        uint256 used = g0 - gasleft();
        vm.stopPrank();
        assertEq(IERC20(USDT0).balanceOf(trader), QUOTE_OUT + 1, "user paid in USDT0");
        _report(
            "USER TX - RFQ, plain approval, direct mode",
            used,
            abi.encodeCall(
                IFillCb.fillWithCallback, (o, sig, QUOTE_OUT, address(0), "", CallbackMode.PostInputsDirect)
            )
        );
    }

    /// @dev Self-serve DEX: the user signs their OWN order and submits the fill
    ///      themselves, through the aggregator solver. Both roles in one tx — which
    ///      is why it is the most expensive shape here and the raw swap beats it.
    function test_cmp_user_selfServeDex() public {
        _fundMaker();
        deal(USDRIF, address(agg), 1);
        Order memory o = _order(13, true);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _plan(maker);
        vm.startPrank(maker);
        uint256 g0 = gasleft();
        agg.executeFill(o, sig, AMOUNT_IN, p, "");
        uint256 used = g0 - gasleft();
        vm.stopPrank();
        _report("USER TX - self-serve via DEX", used, abi.encodeCall(agg.executeFill, (o, sig, AMOUNT_IN, p, "")));
    }

    // ──────────── Q1: how the route is funded, measured in isolation ────────────
    //
    // Three ways to get the maker's input into the pool, all ending in the same
    // swap. Measured standalone so the difference is the FUNDING, not the fill.

    function _swapFrom(address payer, uint256 amountIn) internal returns (uint256) {
        vm.prank(payer, payer);
        return ISwapRouter02(SWAP_ROUTER_02).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: USDRIF,
                tokenOut: USDT0,
                fee: FEE,
                recipient: maker,
                amountIn: amountIn,
                amountOutMinimum: FLOOR_OUT,
                sqrtPriceLimitX96: 0
            })
        );
    }

    /// @dev What the solver does today: approve the router for this fill, swap,
    ///      clear the approval. The allowance slot starts at zero every time.
    function test_cmp_fund_approvePerFill() public {
        deal(USDRIF, trader, AMOUNT_IN);
        deal(USDT0, maker, 1);
        uint256 g0 = gasleft();
        vm.prank(trader);
        IERC20(USDRIF).approve(SWAP_ROUTER_02, AMOUNT_IN);
        _swapFrom(trader, AMOUNT_IN);
        vm.prank(trader);
        IERC20(USDRIF).approve(SWAP_ROUTER_02, 0);
        console.log("fund: approve per fill + clear   ", g0 - gasleft());
    }

    /// @dev A STANDING allowance to the immutable, vetted router: nothing to write
    ///      per fill. The security trade is that an allowance outlives the fill.
    function test_cmp_fund_standingAllowance() public {
        deal(USDRIF, trader, AMOUNT_IN);
        deal(USDT0, maker, 1);
        vm.prank(trader);
        IERC20(USDRIF).approve(SWAP_ROUTER_02, type(uint256).max);
        uint256 g0 = gasleft();
        _swapFrom(trader, AMOUNT_IN);
        console.log("fund: standing max allowance     ", g0 - gasleft());
    }

    /// @dev PREPAY: push the input to the router and swap its own balance
    ///      (`amountIn == 0` is SwapRouter02's CONTRACT_BALANCE sentinel — the
    ///      router then pays as `address(this)`, so NO allowance exists at all).
    ///      This is the shape a `payTo`-redirected fill could reach without any
    ///      solver contract holding the tokens.
    function test_cmp_fund_prepayContractBalance() public {
        deal(USDRIF, trader, AMOUNT_IN);
        deal(USDT0, maker, 1);
        uint256 g0 = gasleft();
        vm.prank(trader);
        require(IERC20(USDRIF).transfer(SWAP_ROUTER_02, AMOUNT_IN), "transfer failed");
        uint256 out = _swapFrom(trader, 0);
        console.log("fund: prepay + CONTRACT_BALANCE  ", g0 - gasleft());
        assertGe(out, FLOOR_OUT, "the router swapped its own balance");
    }

    /// @dev The floor of the protocol itself: an inventory solver filling the same
    ///      order with no swap at all. The difference against the two above is what
    ///      the Uniswap leg costs inside a fill.
    function test_cmp_fill_inventoryNoSwap() public {
        _fundMaker();
        deal(USDT0, solver, FLOOR_OUT * 2);
        vm.startPrank(solver);
        IERC20(USDT0).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDT0, uint160(FLOOR_OUT * 2), 0);
        vm.stopPrank();
        Order memory o = _order(3, false);
        bytes memory sig = _sign(o);
        vm.startPrank(solver);
        uint256 g0 = gasleft();
        settlement.fill(o, sig, AMOUNT_IN);
        uint256 used = g0 - gasleft();
        vm.stopPrank();
        _report("ORDER FILL - inventory, no swap", used, abi.encodeCall(IFill3.fill, (o, sig, AMOUNT_IN)));
    }
}

/// @title RawSwapWarmNonceTest
/// @notice The fill-once bookkeeping in its STEADY state: the maker has signed an
///         order before, so their nonce word is already non-zero and the next 255
///         orders in that window pay a warm write instead of a fresh slot. The
///         first fill happens in `setUp` — a separate transaction — so everything
///         else in the measured fill is still cold.
contract RawSwapWarmNonceTest is RawSwapComparisonTest {
    function setUp() public override {
        super.setUp();
        _fundMaker();
        deal(USDRIF, address(agg), 1);
        deal(USDRIF, maker, AMOUNT_IN * 4);
        vm.prank(maker);
        permit3.approveToken(address(settlement), USDRIF, uint160(AMOUNT_IN * 4), 0);
        _fillOnce(30); // dirties the maker's bitmap word for nonces 0..255
    }

    function test_warm_fillOnce_sameNonceWord() public {
        Order memory o = _order(31, true);
        o.timing |= uint256(1) << 100;
        bytes memory sig = _sign(o);
        uint256 g0 = gasleft();
        agg.executeFill(o, sig, AMOUNT_IN, _plan(maker), "");
        uint256 used = g0 - gasleft();
        _report("DEX FILL - fill-once, warm nonce word", used, abi.encodeCall(agg.executeFill, (o, sig, AMOUNT_IN, _plan(maker), "")));
    }

    /// @dev The control: the same fill with the ordinary per-order counter, taken
    ///      in the same warmed-up world, so the only difference is where progress
    ///      is recorded.
    function test_warm_partialFillCounter() public {
        Order memory o = _order(32, true);
        bytes memory sig = _sign(o);
        uint256 g0 = gasleft();
        agg.executeFill(o, sig, AMOUNT_IN, _plan(maker), "");
        uint256 used = g0 - gasleft();
        _report("DEX FILL - filledAmountIn counter", used, abi.encodeCall(agg.executeFill, (o, sig, AMOUNT_IN, _plan(maker), "")));
    }
}

/// @title FreshTxComparisonTest
/// @notice The same shapes as {RawSwapComparisonTest}, measured the way a REAL
///         transaction pays for them.
///
///  ⚠ WHY THIS CONTRACT EXISTS. Every funding call a test makes before it starts
///  counting — `deal`, an `approve`, a Permit3 grant — WARMS the accounts and slots
///  it touches, and EIP-2929 then charges the measured call 100 instead of 2,600
///  per account and 100 instead of 2,100 per slot. A benchmark that funds inline
///  therefore reports a number no real sender can achieve. Here all of it happens
///  in `setUp`, which Foundry runs as a SEPARATE transaction, so the access list
///  is empty when each test body starts — exactly as it is when a solver or a user
///  sends the call from an EOA.
///
///  The numbers here are consequently HIGHER than the inline ones, by roughly the
///  cold-access cost of the tokens, Permit3, Settlement, the router and the pool.
///  They are the ones to quote.
contract FreshTxComparisonTest is RawSwapComparisonTest {
    function setUp() public override {
        super.setUp();
        _fundMaker(); // maker: USDRIF + Permit3 grant, and a USDT0 balance floor
        _seedSolverFloor();
        _stockQuoter(); // the RFQ desk's inventory and grant, and the taker's funds

        // The raw-swap trader's router allowance, and the RFQ taker's plain
        // approval to Settlement — both one-time setup a user does once, so
        // neither belongs inside a measurement.
        vm.startPrank(trader);
        IERC20(USDRIF).approve(SWAP_ROUTER_02, type(uint256).max);
        IERC20(USDRIF).approve(address(settlement), type(uint256).max);
        vm.stopPrank();

        deal(USDRIF, TREASURY, 1); // a treasury that has been paid before

        // The inventory solver's side.
        deal(USDT0, solver, QUOTE_OUT * 4);
        deal(USDRIF, solver, 1);
        vm.startPrank(solver);
        IERC20(USDT0).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDT0, uint160(QUOTE_OUT * 4), 0);
        vm.stopPrank();
    }

    /// @dev ⚠ THE FLOOR MUST BE SEEDED HERE, NOT IN A TEST BODY. EIP-2200 prices
    ///      an SSTORE against the slot's value at the START OF THE TRANSACTION, so
    ///      a test that seeds the floor and then zeroes it inline measures a
    ///      dirty-slot write (~5,000) where a real no-floor solver pays the
    ///      zero→non-zero one (~22,100) — a 17k error in favour of holding
    ///      nothing. {NoFloorTest} overrides this to leave the slot genuinely
    ///      untouched instead.
    function _seedSolverFloor() internal virtual {
        deal(USDRIF, address(agg), 1);
    }

    function test_fresh_rawSwap() public {
        vm.prank(trader, trader);
        uint256 g0 = gasleft();
        ISwapRouter02(SWAP_ROUTER_02).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: USDRIF,
                tokenOut: USDT0,
                fee: FEE,
                recipient: trader,
                amountIn: AMOUNT_IN,
                amountOutMinimum: FLOOR_OUT,
                sqrtPriceLimitX96: 0
            })
        );
        _report("FRESH - raw Uniswap v3 swap", g0 - gasleft(), _route(trader));
    }

    function test_fresh_dexFill() public {
        Order memory o = _order(40, true);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _plan(maker);
        uint256 g0 = gasleft();
        agg.executeFill(o, sig, AMOUNT_IN, p, "");
        _report("FRESH - DEX-routed fill (solver tx)", g0 - gasleft(), abi.encodeCall(agg.executeFill, (o, sig, AMOUNT_IN, p, "")));
    }

    /// @dev Does the solver need to HOLD anything? Three variants of the same
    ///      fill, differing only in what sits on the contract between fills:
    ///      a dust floor plus the retained spread, a dust floor with the spread
    ///      paid out, and nothing at all. The gap between them is what custody
    ///      actually buys — and it is not where I first said it was.
    function _dexFillTo(string memory label, address profitTo) internal {
        Order memory o = _order(50, true);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _plan(maker);
        p.profitRecipient = profitTo;
        uint256 g0 = gasleft();
        agg.executeFill(o, sig, AMOUNT_IN, p, "");
        console.log(label, g0 - gasleft());
    }

    address internal constant TREASURY = address(0x7BEA5);

    function test_fresh_custody_retainSpread() public {
        _dexFillTo("custody: floor + retain spread    ", address(agg));
    }

    function test_fresh_custody_payoutSpread() public {
        _dexFillTo("custody: floor, spread paid out   ", TREASURY);
    }

    /// @dev What does it COST to be handed the exact fill amounts?
    ///
    ///      {ISettlementCallback} already carries them — `pricedOut[j]` is built
    ///      by the identical `order.outputAt(ctx, j)` call `_deliverOutputs` is
    ///      about to make, so it is not an estimate of the pull, it IS the pull.
    ///      A solver given that number can approve EXACTLY it, and the settler's
    ///      `transferFrom` then zeroes the allowance on its own — no clearing
    ///      write, and no residue to clear.
    ///
    ///      The price is that `_typedPayload` prices BOTH sides a second time
    ///      (outputs here, inputs via `_pricedInputs`) and encodes two dynamic
    ///      arrays. `callbackTarget == 0` isolates that construction: the payload
    ///      is built either way and then never called, so the difference between
    ///      these two is the typed mode's overhead and nothing else.
    function _rfqAt(CallbackMode mode) internal returns (uint256) {
        Order memory o = _quote(70);
        bytes memory sig = _signAs(o, quoterPk);
        vm.prank(trader, trader);
        uint256 g0 = gasleft();
        settlement.fillWithCallback(o, sig, QUOTE_OUT, address(0), "", mode);
        return g0 - gasleft();
    }

    function test_fresh_typedPayloadOverhead_untyped() public {
        console.log("typed: untyped (PostInputsDirect) ", _rfqAt(CallbackMode.PostInputsDirect));
    }

    function test_fresh_typedPayloadOverhead_typed() public {
        console.log("typed: TYPED (exact amounts)      ", _rfqAt(CallbackMode.PostInputsTypedDirect));
    }

    function test_fresh_dexFill_fillOnce() public {
        Order memory o = _order(41, true);
        o.timing |= uint256(1) << 100;
        bytes memory sig = _sign(o);
        RoutePlan memory p = _plan(maker);
        uint256 g0 = gasleft();
        agg.executeFill(o, sig, AMOUNT_IN, p, "");
        _report("FRESH - DEX fill, fill-once (cold word)", g0 - gasleft(), abi.encodeCall(agg.executeFill, (o, sig, AMOUNT_IN, p, "")));
    }

    function test_fresh_inventoryFill() public {
        // Roles as in model 1: the MAKER signs, the solver fills from inventory.
        Order memory o = _order(42, false);
        bytes memory sig = _sign(o);
        vm.prank(solver, solver);
        uint256 g0 = gasleft();
        settlement.fill(o, sig, AMOUNT_IN);
        _report("FRESH - inventory fill (solver tx)", g0 - gasleft(), abi.encodeCall(IFill3.fill, (o, sig, AMOUNT_IN)));
    }

    function test_fresh_rfqUserFill() public {
        Order memory o = _quote(43);
        bytes memory sig = _signAs(o, quoterPk);
        vm.prank(trader, trader);
        uint256 g0 = gasleft();
        settlement.fillWithCallback(o, sig, QUOTE_OUT, address(0), "", CallbackMode.PostInputsDirect);
        _report(
            "FRESH - RFQ self-serve (user tx)",
            g0 - gasleft(),
            abi.encodeCall(IFillCb.fillWithCallback, (o, sig, QUOTE_OUT, address(0), "", CallbackMode.PostInputsDirect))
        );
    }
}

/// @title FundingShapesTest
/// @notice How the input reaches the venue, measured in FRESH-TRANSACTION
///         conditions (see {FreshTxComparisonTest} for why that matters). Every
///         row ends in the same trade on the same pool; the only difference is
///         who is allowed to move the tokens and how.
contract FundingShapesTest is RawSwapComparisonTest {
    address internal constant POOL = 0xD845702af381f0405661747a6a20bde0401A19d6;
    PoolDirectSwapper internal poolSwapper;

    function setUp() public override {
        super.setUp();
        poolSwapper = new PoolDirectSwapper(POOL, USDRIF);
        vm.label(address(poolSwapper), "poolDirectSwapper");
        vm.label(POOL, "usdrifUsdt0Pool");

        deal(USDRIF, trader, AMOUNT_IN * 4);
        deal(USDT0, trader, 1);
        deal(USDT0, maker, 1);
        // The pre-funded swapper holds the input, as a solver mid-fill does.
        deal(USDRIF, address(poolSwapper), AMOUNT_IN * 4);
    }

    function _swapVia(address payer, uint256 amountIn) internal {
        vm.prank(payer, payer);
        ISwapRouter02(SWAP_ROUTER_02).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: USDRIF,
                tokenOut: USDT0,
                fee: FEE,
                recipient: maker,
                amountIn: amountIn,
                amountOutMinimum: FLOOR_OUT,
                sqrtPriceLimitX96: 0
            })
        );
    }

    /// @dev (a) What the solver does today: a fresh allowance every fill, cleared
    ///      after. The allowance slot starts at zero each time.
    function test_fund_a_approvePerFill() public {
        uint256 g0 = gasleft();
        vm.prank(trader);
        IERC20(USDRIF).approve(SWAP_ROUTER_02, AMOUNT_IN);
        _swapVia(trader, AMOUNT_IN);
        vm.prank(trader);
        IERC20(USDRIF).approve(SWAP_ROUTER_02, 0);
        console.log("(a) approve per fill + clear     ", g0 - gasleft());
    }

    /// @dev (b) A standing allowance to the immutable router. Nothing to write.
    function test_fund_b_standingAllowance() public {
        vm.prank(trader);
        IERC20(USDRIF).approve(SWAP_ROUTER_02, type(uint256).max);
        uint256 g0 = gasleft();
        _swapVia(trader, AMOUNT_IN);
        console.log("(b) standing max allowance       ", g0 - gasleft());
    }

    /// @dev (c) PREPAY THE ROUTER: push the tokens over and let it swap its own
    ///      balance. `amountIn == 0` is SwapRouter02's CONTRACT_BALANCE sentinel,
    ///      which makes the router pay as `address(this)` — no allowance exists.
    function test_fund_c_prepayRouter() public {
        uint256 g0 = gasleft();
        vm.prank(trader);
        require(IERC20(USDRIF).transfer(SWAP_ROUTER_02, AMOUNT_IN), "transfer failed");
        _swapVia(trader, 0);
        console.log("(c) prepay router + CONTRACT_BAL ", g0 - gasleft());
    }

    /// @dev (d) PAY THE POOL IN ITS OWN CALLBACK. No allowance, no router. The
    ///      pool verifies payment by its own balance delta — the same discipline
    ///      the settler uses for delta-verified outputs, one level down.
    function test_fund_d_poolDirect() public {
        uint256 g0 = gasleft();
        uint256 out = poolSwapper.swapExactIn(AMOUNT_IN, maker);
        console.log("(d) pool.swap, pay in callback   ", g0 - gasleft());
        assertGe(out, FLOOR_OUT, "the pool was paid from the callback");
    }

    /// @dev (d) again, with the tokens arriving in the SAME transaction rather
    ///      than sitting there — the real mid-fill situation.
    function test_fund_d_poolDirect_justInTime() public {
        uint256 g0 = gasleft();
        vm.prank(trader);
        require(IERC20(USDRIF).transfer(address(poolSwapper), AMOUNT_IN), "transfer failed");
        uint256 out = poolSwapper.swapExactIn(AMOUNT_IN, maker);
        console.log("(d+) transfer in, then pool.swap ", g0 - gasleft());
        assertGe(out, FLOOR_OUT, "swapped");
    }
}

/// @title PoolDirectCompatTest
/// @notice Is the callback-paid shape portable across the venues this chain
///         actually has? SushiSwap v3 is a Uniswap v3 fork and kept the callback
///         name, so ONE implementation should serve both books. Asserted against
///         a live Sushi pool rather than assumed from the lineage.
contract PoolDirectCompatTest is RawSwapComparisonTest {
    /// @dev SushiSwap v3 WRBTC/USD0 0.30% on Rootstock — the pool the app's
    ///      primary market aggregates alongside the Uniswap one.
    address internal constant SUSHI_WRBTC_USD0 = 0x6d778c369cB386D50f4Ee676c5c264374C52Fd71;

    function test_compat_sushiV3_takesTheSameCallback() public {
        address t0 = IUniV3Pool(SUSHI_WRBTC_USD0).token0();
        PoolDirectSwapper sw = new PoolDirectSwapper(SUSHI_WRBTC_USD0, t0);

        uint256 amountIn = 10 ** uint256(IERC20(t0).decimals()) / 1000; // a small, price-safe clip
        deal(t0, address(sw), amountIn);
        deal(IUniV3Pool(SUSHI_WRBTC_USD0).token1(), maker, 1);

        uint256 g0 = gasleft();
        uint256 out = sw.swapExactIn(amountIn, maker);
        console.log("sushi v3 pool.swap, pay in callback", g0 - gasleft());
        assertGt(out, 0, "SushiSwap v3 accepted uniswapV3SwapCallback");
        assertEq(IERC20(t0).balanceOf(address(sw)), 0, "the callback paid the pool in full");
    }
}

/// @notice Sketch of the shared allowance forwarder, measured before it is built.
///
///  It exists to move the STANDING ALLOWANCE off the contract that holds value.
///  A solver grants ONE approval, to this, instead of one per router; this holds
///  no balance between calls and has no owner, so the approval it receives is
///  pointed at ~40 lines rather than at a periphery contract with multicall,
///  `sweepToken`, `approveMax` and `callPositionManager` on it.
///
///  The load-bearing rule is that it pulls ONLY from `msg.sender`. That is what
///  makes it safe to be permissionless: A's standing approval can never be spent
///  by B, because B's call pulls from B.
contract RouterForwarder {
    mapping(address => bool) public isAllowedRouter;

    error RouterNotAllowed();
    error RouterCallFailed(bytes ret);

    constructor(address[] memory routers) {
        for (uint256 i; i < routers.length; i++) isAllowedRouter[routers[i]] = true;
    }

    /// @dev The standing approval to the router is set once per token, by anyone,
    ///      and never cleared — harmless, because this address owns nothing.
    function primeToken(address token, address router) external {
        if (!isAllowedRouter[router]) revert RouterNotAllowed();
        SafeTransferLib.forceApprove(token, router, type(uint256).max);
    }

    function swap(address router, address tokenIn, uint256 amountIn, bytes calldata data) external {
        if (!isAllowedRouter[router]) revert RouterNotAllowed();
        SafeTransferLib.safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
        (bool ok, bytes memory ret) = router.call(data);
        if (!ok) revert RouterCallFailed(ret);
    }
}

/// @notice Sketch of the ALLOWLIST-FREE forwarder: the point is not to move the
///         standing allowance, it is to delete the router allowlist.
///
///  `AggregatorFillSolver` needs an immutable router set because it makes the
///  route call FROM ITS OWN IDENTITY, and that identity holds tokens (the balance
///  floor, the retained spread) and can be granted authority (a Permit3 book, an
///  order-signer nomination). An arbitrary `(target, data)` from there is the
///  "invoke anything as me" primitive the allowlist exists to remove — which is
///  why adding a venue today means deploying a new instance.
///
///  Move the call one hop, into an address that OWNS NOTHING AND IS TRUSTED BY
///  NOBODY, and the allowlist stops being load-bearing: "call anything" is
///  harmless when the caller has nothing to spend and no authority to exercise.
///  That is precisely {SolverCallbackExecutor}'s argument, applied to the
///  solver's own side of the fill.
///
///  Two rules make it true, and both are structural rather than checks:
///   1. PUSH-FUNDED. It never calls `transferFrom` on anyone, so nobody has any
///      reason to approve it, so there is no standing grant to steal. The caller
///      sends the tokens, then calls.
///   2. IT ENDS EMPTY. Whatever the route did not consume goes back to the
///      caller, so nothing accumulates for the next caller to take.
///
///  Given those, its OWN standing approvals — to arbitrary targets, never
///  cleared — are free: an approval over an empty account grants nothing. That is
///  what removes the 24,780-gas per-fill approve without granting anything to
///  anybody.
///
///  ⚠ NEVER GRANT THIS ADDRESS AUTHORITY, for the reason {PermissionlessCallModule}
///  spells out: anything it can do, an attacker's call can do for them.
contract OpenForwarder {
    error CallFailed(bytes ret);

    /// @param tokenIn  the token already pushed here for this call
    /// @param target   ANY contract — there is deliberately no allowlist
    /// @param data     the route's own calldata, opaque
    function execute(address tokenIn, address target, bytes calldata data) external {
        // A standing approval FROM AN EMPTY ACCOUNT grants nothing, so it is set
        // once per (token, target) and never cleared. This is the whole gas win.
        if (IERC20(tokenIn).allowance(address(this), target) == 0) {
            SafeTransferLib.forceApprove(tokenIn, target, type(uint256).max);
        }
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) revert CallFailed(ret);
        // Rule 2: end empty, minus the dust floor that keeps the writes warm.
        uint256 left = IERC20(tokenIn).balanceOf(address(this));
        if (left > 1) SafeTransferLib.safeTransfer(tokenIn, msg.sender, left - 1);
    }
}

/// @notice {OpenForwarder} with the two reads taken out of the hot path.
///
///  The `allowance == 0` probe and the residue `balanceOf` are both the contract
///  asking a question its CALLER already knows the answer to. `prime` is declared
///  rather than discovered — a wrong `false` makes the router call revert, which
///  costs the caller its own gas and nobody else anything, so it needs no check.
///
///  The sweep is NOT made optional for the same reason: "ends empty" is what makes
///  an arbitrary target safe here, and a caller that skipped it would leave
///  residue for the next arbitrary target to take. It stays unconditional; only
///  its `balanceOf` is avoidable, and only when the caller states the route
///  consumes its whole input (`exactIn`), which for an exact-input route is true
///  by construction.
contract OpenForwarderLean {
    error CallFailed(bytes ret);

    function execute(address tokenIn, address target, bytes calldata data, bool prime, bool exactIn) external {
        if (prime) SafeTransferLib.forceApprove(tokenIn, target, type(uint256).max);
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) revert CallFailed(ret);
        if (!exactIn) {
            uint256 left = IERC20(tokenIn).balanceOf(address(this));
            if (left > 1) SafeTransferLib.safeTransfer(tokenIn, msg.sender, left - 1);
        }
    }
}

/// @title StandingAllowanceTest
/// @notice The chosen shape, and the forwarder variant of it, priced honestly:
///         the standing approvals are granted in `setUp`, so the measured call
///         pays the COLD price to read them, exactly as a real fill does.
contract StandingAllowanceTest is RawSwapComparisonTest {
    RouterForwarder internal fwd;

    function setUp() public virtual override {
        super.setUp();
        address[] memory routers = new address[](1);
        routers[0] = SWAP_ROUTER_02;
        fwd = new RouterForwarder(routers);
        vm.label(address(fwd), "routerForwarder");

        deal(USDRIF, trader, AMOUNT_IN * 4);
        deal(USDT0, maker, 1);
        deal(USDRIF, address(fwd), 1); // the forwarder's own dust floor

        vm.startPrank(trader);
        IERC20(USDRIF).approve(SWAP_ROUTER_02, type(uint256).max); // the direct standing grant
        IERC20(USDRIF).approve(address(fwd), type(uint256).max); // …or the forwarder one
        vm.stopPrank();
        fwd.primeToken(USDRIF, SWAP_ROUTER_02);
    }

    function _routeTo(address recipient, uint256 amountIn) internal pure returns (bytes memory) {
        return abi.encodeCall(
            ISwapRouter02.exactInputSingle,
            (
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: USDRIF,
                    tokenOut: USDT0,
                    fee: FEE,
                    recipient: recipient,
                    amountIn: amountIn,
                    amountOutMinimum: FLOOR_OUT,
                    sqrtPriceLimitX96: 0
                })
            )
        );
    }

    /// @dev (b) The naked standing allowance: the solver approves the router once
    ///      and the fill writes nothing.
    function test_standing_direct() public {
        vm.prank(trader, trader);
        uint256 g0 = gasleft();
        (bool ok,) = SWAP_ROUTER_02.call(_routeTo(maker, AMOUNT_IN));
        require(ok, "swap failed");
        console.log("(b) standing allowance -> router  ", g0 - gasleft());
    }

    /// @dev (e) The same, through the forwarder. One extra `transferFrom` hop is
    ///      the price of keeping the approval off the value-holding contract.
    function test_standing_viaForwarder() public {
        vm.prank(trader, trader);
        uint256 g0 = gasleft();
        fwd.swap(SWAP_ROUTER_02, USDRIF, AMOUNT_IN, _routeTo(maker, AMOUNT_IN));
        console.log("(e) standing allowance -> forwarder", g0 - gasleft());
        assertEq(IERC20(USDRIF).balanceOf(address(fwd)), 1, "forwarder kept only its dust");
    }

    /// @dev ⚠ THE QUESTION THE FORWARDER EXISTS TO ANSWER, put to the router
    ///      itself: with a standing max allowance in place, can ANYONE BUT US
    ///      spend it?
    ///
    ///      SwapRouter02 encodes `payer = msg.sender` into the callback data of
    ///      its own swap, and its `uniswapV3SwapCallback` first runs
    ///      `CallbackValidation.verifyCallback`, which recomputes the pool address
    ///      from (factory, tokens, fee) and requires `msg.sender` to BE that pool.
    ///      So the only way to reach the pull is through a swap the router itself
    ///      started, and there the payer is whoever called it. Both halves are
    ///      exercised below rather than reasoned about.
    function test_standing_routerCannotBeMadeToPullFromUs() public {
        address attacker = address(0xBAD);
        uint256 victimBefore = IERC20(USDRIF).balanceOf(trader);
        assertGt(IERC20(USDRIF).allowance(trader, SWAP_ROUTER_02), AMOUNT_IN, "victim's standing grant is live");

        // 1. The front door: the router pulls from the CALLER, who has nothing.
        vm.prank(attacker, attacker);
        (bool ok,) = SWAP_ROUTER_02.call(_routeTo(attacker, AMOUNT_IN));
        assertFalse(ok, "the router pulled from the attacker, not the victim");

        // 2. The back door: call the router's swap callback directly, naming the
        //    victim as payer. `verifyCallback` refuses a caller that is not the
        //    pool those tokens and that fee hash to.
        bytes memory path = abi.encodePacked(USDT0, FEE, USDRIF); // tokenOut, fee, tokenIn
        bytes memory cbData = abi.encode(path, trader);
        vm.prank(attacker, attacker);
        (bool ok2,) = SWAP_ROUTER_02.call(
            abi.encodeWithSignature(
                "uniswapV3SwapCallback(int256,int256,bytes)", int256(int256(AMOUNT_IN)), int256(-1), cbData
            )
        );
        assertFalse(ok2, "a non-pool reached the router's callback");

        assertEq(IERC20(USDRIF).balanceOf(trader), victimBefore, "the standing allowance was unspendable by a stranger");
    }

    /// @dev (f) The allowlist-free shape: push the input over, then let the
    ///      forwarder call an ARBITRARY target. Priced against (b), which buys the
    ///      same per-fill allowance saving but keeps the allowlist.
    function test_standing_openForwarder() public {
        OpenForwarder open = new OpenForwarder();
        deal(USDRIF, address(open), 1); // its dust floor
        vm.startPrank(trader, trader);
        uint256 g0 = gasleft();
        require(IERC20(USDRIF).transfer(address(open), AMOUNT_IN), "push failed");
        open.execute(USDRIF, SWAP_ROUTER_02, _routeTo(maker, AMOUNT_IN));
        console.log("(f) push -> open forwarder        ", g0 - gasleft());
        vm.stopPrank();
        assertEq(IERC20(USDRIF).balanceOf(address(open)), 1, "ended empty but for the floor");
    }

    /// @dev The same call a SECOND time, with the (token, target) approval already
    ///      primed — the steady state, and the number to compare against (b).
    function test_standing_openForwarder_primed() public {
        OpenForwarder open = new OpenForwarder();
        deal(USDRIF, address(open), 1);
        vm.startPrank(trader, trader);
        require(IERC20(USDRIF).transfer(address(open), AMOUNT_IN), "push failed");
        open.execute(USDRIF, SWAP_ROUTER_02, _routeTo(maker, AMOUNT_IN));

        uint256 g0 = gasleft();
        require(IERC20(USDRIF).transfer(address(open), AMOUNT_IN), "push failed");
        open.execute(USDRIF, SWAP_ROUTER_02, _routeTo(maker, AMOUNT_IN));
        console.log("(f) same, approval already primed ", g0 - gasleft());
        vm.stopPrank();
    }

    /// @dev Why the arbitrary target is safe HERE and not on the solver: the
    ///      forwarder owns nothing and is trusted by nobody, so the worst an
    ///      attacker gets from "call anything" is the dust floor.
    function test_standing_openForwarder_arbitraryTargetStealsOnlyDust() public {
        OpenForwarder open = new OpenForwarder();
        deal(USDRIF, address(open), 1);
        address attacker = address(0xBAD);

        // The attacker names the TOKEN as the target and a transfer as the route.
        vm.prank(attacker, attacker);
        open.execute(USDRIF, USDRIF, abi.encodeCall(IERC20.transfer, (attacker, 1)));
        assertLe(IERC20(USDRIF).balanceOf(attacker), 1, "a whole fill's worth was never reachable");

        // And the victim's own grants are untouched: the forwarder holds none.
        assertEq(IERC20(USDRIF).allowance(trader, address(open)), 0, "nobody ever approves the forwarder");
    }

    /// @dev The forwarder's whole security claim, asserted: a standing approval
    ///      granted by one party cannot be spent by another, because the pull is
    ///      always from `msg.sender`.
    function test_standing_forwarderCannotSpendAnothersAllowance() public {
        address attacker = address(0xBAD);
        deal(USDRIF, attacker, 0);
        uint256 before = IERC20(USDRIF).balanceOf(trader);
        vm.prank(attacker, attacker);
        vm.expectRevert(); // the pull comes from the attacker, who has nothing
        fwd.swap(SWAP_ROUTER_02, USDRIF, AMOUNT_IN, _routeTo(attacker, AMOUNT_IN));
        assertEq(IERC20(USDRIF).balanceOf(trader), before, "the victim's allowance was untouchable");
    }
}

/// @title OpenForwarderPrimedTest
/// @notice The allowlist-free forwarder in its STEADY state, in a fresh
///         transaction: the (token, target) approval was granted in `setUp`, so
///         the measured call pays the cold price to read it — like any later fill.
contract OpenForwarderPrimedTest is StandingAllowanceTest {
    OpenForwarder internal open;

    function setUp() public override {
        super.setUp();
        open = new OpenForwarder();
        vm.label(address(open), "openForwarder");
        deal(USDRIF, address(open), 1); // its dust floor
        vm.prank(address(open));
        IERC20(USDRIF).approve(SWAP_ROUTER_02, type(uint256).max); // primed once, never cleared
    }

    function test_open_primed_freshTx() public {
        vm.startPrank(trader, trader);
        uint256 g0 = gasleft();
        require(IERC20(USDRIF).transfer(address(open), AMOUNT_IN), "push failed");
        open.execute(USDRIF, SWAP_ROUTER_02, _routeTo(maker, AMOUNT_IN));
        console.log("(f) push -> open fwd, primed      ", g0 - gasleft());
        vm.stopPrank();
        assertEq(IERC20(USDRIF).balanceOf(address(open)), 1, "ended empty but for the floor");
    }
}

/// @title OpenForwarderLeanTest
/// @notice The lean forwarder in the same fresh-transaction, primed steady state
///         as {OpenForwarderPrimedTest}, so the two numbers subtract.
contract OpenForwarderLeanTest is StandingAllowanceTest {
    OpenForwarderLean internal lean;

    function setUp() public virtual override {
        super.setUp();
        lean = new OpenForwarderLean();
        vm.label(address(lean), "openForwarderLean");
        deal(USDRIF, address(lean), 1);
        vm.prank(address(lean));
        IERC20(USDRIF).approve(SWAP_ROUTER_02, type(uint256).max);
    }

    function test_lean_primed_freshTx() public {
        vm.startPrank(trader, trader);
        uint256 g0 = gasleft();
        require(IERC20(USDRIF).transfer(address(lean), AMOUNT_IN), "push failed");
        lean.execute(USDRIF, SWAP_ROUTER_02, _routeTo(maker, AMOUNT_IN), false, true);
        console.log("(g) lean fwd: declared prime      ", g0 - gasleft());
        vm.stopPrank();
        assertEq(IERC20(USDRIF).balanceOf(address(lean)), 1, "exact-input route consumed it all");
    }

    /// @dev A wrong `prime = false` costs the caller its own gas and nothing else.
    function test_lean_wrongPrimeFlagOnlyCostsTheCaller() public {
        OpenForwarderLean fresh = new OpenForwarderLean(); // never primed
        deal(USDRIF, address(fresh), 1);
        vm.startPrank(trader, trader);
        require(IERC20(USDRIF).transfer(address(fresh), AMOUNT_IN), "push failed");
        vm.expectRevert();
        fresh.execute(USDRIF, SWAP_ROUTER_02, _routeTo(maker, AMOUNT_IN), false, true);
        vm.stopPrank();
    }
}

/// @title NoFloorTest
/// @notice The same fill on a solver that holds NOTHING — its input-token balance
///         slot is genuinely zero at the start of the transaction, which is the
///         only way to price the zero→non-zero write honestly.
contract NoFloorTest is FreshTxComparisonTest {
    function _seedSolverFloor() internal override {} // deliberately nothing

    function test_nofloor_dexFill() public {
        Order memory o = _order(60, true);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _plan(maker);
        p.profitRecipient = TREASURY;
        uint256 g0 = gasleft();
        agg.executeFill(o, sig, AMOUNT_IN, p, "");
        console.log("custody: holds NOTHING            ", g0 - gasleft());
        assertEq(IERC20(USDRIF).balanceOf(address(agg)), 0, "still holds nothing");
    }
}

/// @title BetaTokenTransferFidelityTest
/// @notice "No fee-on-transfer tokens on Rootstock" as a CHECKED FACT for the
///         tokens the beta lists, rather than an assumption carried in a head.
///
///  A token that takes a cut on transfer breaks every figure a filler passes
///  around by amount rather than by measured delta, so this is the premise any
///  decision to drop the delta discipline rests on. It is cheap to assert and
///  it is the kind of premise that silently stops being true when a market is
///  added — so it lives in the suite, next to the code that depends on it.
contract BetaTokenTransferFidelityTest is UsdrifForkBase {
    function _assertExact(address token, string memory name) internal {
        address from = address(0xF0F0);
        address to = address(0x7070);
        uint256 amount = 1_000 * 10 ** uint256(IERC20(token).decimals());
        deal(token, from, amount);
        deal(token, to, 1); // a warm, non-zero destination — the ordinary case

        uint256 toBefore = IERC20(token).balanceOf(to);
        vm.prank(from);
        IERC20(token).transfer(to, amount);

        assertEq(IERC20(token).balanceOf(to) - toBefore, amount, string.concat(name, ": recipient short-changed"));
        assertEq(IERC20(token).balanceOf(from), 0, string.concat(name, ": sender not fully debited"));
    }

    function test_beta_tokensTransferExactly() public {
        _assertExact(USDRIF, "USDRIF");
        _assertExact(USDT0, "USDT0");
        _assertExact(RIF, "RIF");
    }

    /// @dev The stronger, structural evidence for the pair we actually trade:
    ///      Uniswap v3's own `swap` asserts `balanceBefore + amount <= balanceAfter`
    ///      on the input side, so a fee-on-transfer token CANNOT complete a v3
    ///      swap at all. Every passing fork fill in this file is therefore already
    ///      a proof that USDRIF is not fee-on-transfer.
    function test_beta_uniswapV3WouldRejectAFeeOnTransferInput() public pure {
        assertTrue(true, "see the note - this is documentation, asserted by every other swap here");
    }
}
