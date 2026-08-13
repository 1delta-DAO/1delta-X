// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Base} from "@core/settlement/Base.sol";
import {Settlement, CallbackMode, Order, Item, LegOut} from "@core/settlement/Settlement.sol";
import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";
import {PackedEncode} from "../shared/PackedEncode.sol";

/// @dev A fee-on-transfer ERC20 (recipient credited `amount − fee`, fee burned).
contract MockFoT {
    string public name = "FoT";
    string public symbol = "FOT";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    uint256 public immutable feeBps;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint256 _feeBps) {
        feeBps = _feeBps;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        _xfer(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address f, address to, uint256 amt) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - amt;
        _xfer(f, to, amt);
        return true;
    }

    function _xfer(address f, address t, uint256 amt) internal {
        balanceOf[f] -= amt;
        uint256 fee = amt * feeBps / 10_000;
        balanceOf[t] += amt - fee;
        totalSupply -= fee;
    }
}

/// @dev A stand-in for a Uniswap-V2-style pool the solver routes through in the
///      PostInputs callback: it holds the FoT output stock, pulls the solver's
///      just-received `tokenIn`, and sends the FoT output DIRECTLY to the maker —
///      one FoT fee, no intermediate hop. `grossOut` is what the pool sends; the
///      maker nets `grossOut · (1 − fee)`.
contract DeltaPool {
    function swapToMaker(address who, address tokenIn, uint256 amtIn, address fot, address maker, uint256 grossOut)
        external
    {
        IERC20(tokenIn).transferFrom(who, address(this), amtIn);
        MockFoT(fot).transfer(maker, grossOut); // FoT fee applied here, on the pool → maker hop
    }

    /// @dev Two deliveries in one callback — for multi-leg orders (two tokens, or one
    ///      token to two different recipients).
    function deliverTwo(address t1, address r1, uint256 a1, address t2, address r2, uint256 a2) external {
        IERC20(t1).transfer(r1, a1);
        IERC20(t2).transfer(r2, a2);
    }

    /// @dev One delivery, no input pull — for partial fills / BUY shapes.
    function deliverOne(address token, address to, uint256 amount) external {
        IERC20(token).transfer(to, amount);
    }
}

/// @notice The DELTA-VERIFY delivery primitive ({DutchAuction.deltaVerifyOutputs},
///         `timing` bit 104). The filler delivers the output leg out-of-band (pool →
///         maker) and the core verifies the maker's MEASURED balance delta ≥ the
///         priced amount instead of pushing a nominal amount. This makes a
///         fee-on-transfer OUTPUT safe (the maker is guaranteed their signed amount
///         NET of the fee) and composes with every pricing mode — proven here across
///         a fixed and a dutch-decay order.
contract DeltaVerifyDeliveryTest is CoreSettlementBase {
    MockFoT fot;
    DeltaPool pool;

    uint256 constant FEE_BPS = 100; // 1%
    uint256 constant USDC_IN = 1_500e6;
    uint256 constant FOT_OUT = 1_000 ether;

    function setUp() public override {
        super.setUp();
        fot = new MockFoT(FEE_BPS);
        pool = new DeltaPool();
        vm.label(address(fot), "FoT");
        vm.label(address(pool), "DeltaPool");
        // The pool is the liquidity — the solver holds NO FoT inventory.
        fot.mint(address(pool), 1_000_000 ether);
        // Solver lets the pool pull its just-received USDC in reverse mode.
        vm.prank(solver);
        IERC20(USDC).approve(address(pool), type(uint256).max);
    }

    /// @dev Set the delta-verify bit (104) on an already-built order.
    function _markDeltaVerify(Order memory o) internal pure {
        o.timing |= uint256(1) << 104;
    }

    function _fund() internal {
        deal(USDC, maker, USDC_IN);
        _approveMakerToSettlement(USDC, USDC_IN);
    }

    // ── Zero-inventory FoT buy: pool delivers straight to the maker, one fee, and
    //    the core verifies the maker NET-received at least the signed output. ──
    function test_deltaVerify_fotOutput_settlesNetOfFee() public {
        _fund();

        Order memory o = _order(maker, 1, USDC, address(fot), USDC_IN, FOT_OUT, new Item[](0));
        _markDeltaVerify(o);
        bytes memory sig = _sign(o);

        // Gross up so the maker nets ≥ FOT_OUT after the 1% fee.
        uint256 grossOut = FOT_OUT * 10_000 / (10_000 - FEE_BPS) + 1;
        bytes memory cb = abi.encodeCall(DeltaPool.swapToMaker, (solver, USDC, USDC_IN, address(fot), maker, grossOut));

        assertEq(fot.balanceOf(solver), 0, "solver holds no output inventory");

        vm.prank(solver);
        settlement.fillWithCallback(o, sig, USDC_IN, address(pool), cb, CallbackMode.PostInputs);

        assertGe(fot.balanceOf(maker), FOT_OUT, "maker net-received at least the signed output");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "maker paid the full USDC input");
        assertEq(fot.balanceOf(solver), 0, "solver kept no output");
    }

    // ── If the fee eats past the signed output (pool sends only the nominal), the
    //    delta check reverts — the maker is never silently underpaid. ──
    function test_deltaVerify_shortReceipt_reverts() public {
        _fund();

        Order memory o = _order(maker, 2, USDC, address(fot), USDC_IN, FOT_OUT, new Item[](0));
        _markDeltaVerify(o);
        bytes memory sig = _sign(o);

        // Sends exactly the nominal — the maker would net FOT_OUT·(1−fee) < FOT_OUT.
        bytes memory cb = abi.encodeCall(DeltaPool.swapToMaker, (solver, USDC, USDC_IN, address(fot), maker, FOT_OUT));

        vm.prank(solver);
        vm.expectRevert(Base.DeltaTooLow.selector);
        settlement.fillWithCallback(o, sig, USDC_IN, address(pool), cb, CallbackMode.PostInputs);

        assertEq(IERC20(USDC).balanceOf(maker), USDC_IN, "maker kept its input - fill unwound");
    }

    // ── Composes with a DUTCH auction: the verified floor is the CURRENT tick, not
    //    the auction floor. Mid-auction, a delivery at the floor reverts; one at the
    //    current tick passes. Proves the primitive reuses the existing pricing. ──
    function test_deltaVerify_dutchOutput_tracksCurrentTick() public {
        _fund();

        uint256 start = 1_200 ether;
        uint256 end = 1_000 ether;
        uint32 duration = 1_000;

        Order memory o = _order(maker, 3, USDC, address(fot), USDC_IN, FOT_OUT, new Item[](0));
        o.legsOut = PackedEncode.oneLegOut(address(fot), start, end, address(0)); // decaying output
        o.timing = _packTiming(uint32(block.timestamp), duration, 0);
        _markDeltaVerify(o);
        bytes memory sig = _sign(o);

        // Halfway through the decay: tick = start − (start−end)/2 = 1100.
        vm.warp(block.timestamp + duration / 2);
        uint256 tick = start - (start - end) / 2;

        // Delivering the FLOOR (net 1000) is below the current tick (1100) → revert.
        uint256 grossFloor = end * 10_000 / (10_000 - FEE_BPS) + 1;
        bytes memory cbFloor =
            abi.encodeCall(DeltaPool.swapToMaker, (solver, USDC, USDC_IN, address(fot), maker, grossFloor));
        vm.prank(solver);
        vm.expectRevert(Base.DeltaTooLow.selector);
        settlement.fillWithCallback(o, sig, USDC_IN, address(pool), cbFloor, CallbackMode.PostInputs);

        // Delivering net ≥ the current tick (1100) passes.
        uint256 grossTick = tick * 10_000 / (10_000 - FEE_BPS) + 1;
        bytes memory cbTick =
            abi.encodeCall(DeltaPool.swapToMaker, (solver, USDC, USDC_IN, address(fot), maker, grossTick));
        vm.prank(solver);
        settlement.fillWithCallback(o, sig, USDC_IN, address(pool), cbTick, CallbackMode.PostInputs);

        assertGe(fot.balanceOf(maker), tick, "maker net-received at least the current dutch tick");
    }

    // ── Regression: an unmarked order still delivers NOMINALLY (the maker nets less
    //    on a FoT output, exactly as before). The bit is strictly opt-in. ──
    function test_unmarked_fotOutput_deliversNominally() public {
        _fund();
        // A plain (nominal-delivery) FoT buy: solver holds the FoT and delivers it.
        fot.mint(solver, FOT_OUT);
        vm.startPrank(solver);
        fot.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(fot), uint160(FOT_OUT), 0);
        vm.stopPrank();

        Order memory o = _order(maker, 4, USDC, address(fot), USDC_IN, FOT_OUT, new Item[](0));
        bytes memory sig = _sign(o);

        vm.prank(solver);
        settlement.fill(o, sig, USDC_IN);

        // Nominal path: the maker nets FOT_OUT - fee (documented silent underpay).
        assertEq(fot.balanceOf(maker), FOT_OUT - FOT_OUT * FEE_BPS / 10_000, "unmarked order: nominal delivery, maker nets less");
    }

    // ══════════════════ Shape guards (the soundness conditions) ══════════════════

    /// @dev THE attack the duplicate-leg guard exists for: two output legs sharing a
    ///      (token, recipient) would each verify their own amount against the SAME
    ///      starting balance, so ONE delivery of max(a1,a2) satisfies both and the
    ///      maker is underpaid. Rejected up front.
    function test_deltaVerify_duplicateTokenRecipient_reverts() public {
        _fund();

        LegOut[] memory legs = new LegOut[](2);
        legs[0] = LegOut(address(fot), FOT_OUT, 0, address(0)); // → maker
        legs[1] = LegOut(address(fot), FOT_OUT, 0, maker); // → maker again, same token
        Order memory o = _order(maker, 10, USDC, address(fot), USDC_IN, FOT_OUT, new Item[](0));
        o.legsOut = PackedEncode.legsOut(legs);
        _markDeltaVerify(o);
        bytes memory sig = _sign(o);

        // A single delivery covering only the larger leg would pass both checks
        // without the guard; with it the fill is refused before anything moves.
        uint256 gross = FOT_OUT * 10_000 / (10_000 - FEE_BPS) + 1;
        bytes memory cb = abi.encodeCall(DeltaPool.deliverOne, (address(fot), maker, gross));

        vm.prank(solver);
        vm.expectRevert(Base.DeltaVerifyDuplicateLeg.selector);
        settlement.fillWithCallback(o, sig, USDC_IN, address(pool), cb, CallbackMode.PostInputs);
    }

    /// @dev A maker-bound output token that is ALSO an input token would measure
    ///      net-of-input rather than gross output (the input is pulled between the
    ///      snapshot and the check). Rejected.
    function test_deltaVerify_sameTokenInAndOut_reverts() public {
        uint256 amtIn = 100 ether;
        fot.mint(maker, amtIn);
        vm.startPrank(maker);
        fot.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(fot), uint160(amtIn), 0);
        vm.stopPrank();

        Order memory o = _order(maker, 11, address(fot), address(fot), amtIn, FOT_OUT, new Item[](0));
        _markDeltaVerify(o);
        bytes memory sig = _sign(o);
        bytes memory cb = abi.encodeCall(DeltaPool.deliverOne, (address(fot), maker, FOT_OUT));

        vm.prank(solver);
        vm.expectRevert(Base.DeltaVerifySameToken.selector);
        settlement.fillWithCallback(o, sig, amtIn, address(pool), cb, CallbackMode.PostInputs);
    }

    // ══════════════════ Multi-leg / other order shapes ══════════════════

    /// @dev MULTI-TOKEN: two output legs in DIFFERENT tokens verify independently —
    ///      each leg's own (token, recipient) balance moves for that leg alone.
    function test_deltaVerify_multiToken_verifiesEachLegIndependently() public {
        _fund();
        deal(USDC, address(pool), 10_000e6);

        uint256 usdcLeg = 100e6;
        LegOut[] memory legs = new LegOut[](2);
        legs[0] = LegOut(address(fot), FOT_OUT, 0, address(0)); // FoT → maker
        legs[1] = LegOut(USDC, usdcLeg, 0, address(0)); // USDC → maker
        // Input must not collide with an output token paid to the maker, so sell WETH.
        deal(WETH, maker, 1 ether);
        _approveMakerToSettlement(WETH, 1 ether);

        Order memory o = _order(maker, 13, WETH, address(fot), 1 ether, FOT_OUT, new Item[](0));
        o.legsOut = PackedEncode.legsOut(legs);
        _markDeltaVerify(o);
        bytes memory sig = _sign(o);

        uint256 grossFot = FOT_OUT * 10_000 / (10_000 - FEE_BPS) + 1;
        bytes memory cb =
            abi.encodeCall(DeltaPool.deliverTwo, (address(fot), maker, grossFot, USDC, maker, usdcLeg));

        uint256 usdcBefore = IERC20(USDC).balanceOf(maker);
        vm.prank(solver);
        settlement.fillWithCallback(o, sig, 1 ether, address(pool), cb, CallbackMode.PostInputs);

        assertGe(fot.balanceOf(maker), FOT_OUT, "FoT leg verified net-of-fee");
        assertEq(IERC20(USDC).balanceOf(maker) - usdcBefore, usdcLeg, "USDC leg verified independently");
    }

    /// @dev FEE LEG: the same token to two DIFFERENT recipients (maker leg + fee leg)
    ///      is the documented fee shape and is sound — the balances are distinct.
    function test_deltaVerify_sameTokenDifferentRecipients_ok() public {
        _fund();
        address originator = address(0x0F0F);

        uint256 feeAmt = 10 ether;
        LegOut[] memory legs = new LegOut[](2);
        legs[0] = LegOut(address(fot), FOT_OUT, 0, address(0)); // → maker
        legs[1] = LegOut(address(fot), feeAmt, 0, originator); // → originator
        Order memory o = _order(maker, 14, USDC, address(fot), USDC_IN, FOT_OUT, new Item[](0));
        o.legsOut = PackedEncode.legsOut(legs);
        _markDeltaVerify(o);
        bytes memory sig = _sign(o);

        uint256 grossMaker = FOT_OUT * 10_000 / (10_000 - FEE_BPS) + 1;
        uint256 grossFee = feeAmt * 10_000 / (10_000 - FEE_BPS) + 1;
        bytes memory cb = abi.encodeCall(
            DeltaPool.deliverTwo, (address(fot), maker, grossMaker, address(fot), originator, grossFee)
        );

        vm.prank(solver);
        settlement.fillWithCallback(o, sig, USDC_IN, address(pool), cb, CallbackMode.PostInputs);

        assertGe(fot.balanceOf(maker), FOT_OUT, "maker leg net-verified");
        assertGe(fot.balanceOf(originator), feeAmt, "fee leg net-verified");
    }

    /// @dev PARTIAL FILL: the verified requirement is the leg's PRO-RATA slice, not the
    ///      whole leg — `outputAt` scaling flows through unchanged.
    function test_deltaVerify_partialFill_requiresOnlyTheSlice() public {
        _fund();

        Order memory o = _order(maker, 15, USDC, address(fot), USDC_IN, FOT_OUT, new Item[](0));
        _markDeltaVerify(o);
        bytes memory sig = _sign(o);

        uint256 half = USDC_IN / 2;
        uint256 sliceOut = FOT_OUT / 2; // pro-rata output for half the anchor
        uint256 grossHalf = sliceOut * 10_000 / (10_000 - FEE_BPS) + 1;
        bytes memory cb = abi.encodeCall(DeltaPool.deliverOne, (address(fot), maker, grossHalf));

        vm.prank(solver);
        settlement.fillWithCallback(o, sig, half, address(pool), cb, CallbackMode.PostInputs);

        assertGe(fot.balanceOf(maker), sliceOut, "half-fill verified against the half slice");
        assertEq(settlement.filled(_hashOrder(o)), half, "order half filled");
    }

    /// @dev BUY side: outputs are the FIXED exact-output slice; delta-verify measures
    ///      that same amount, so the mode composes with the BUY shape too.
    function test_deltaVerify_buyOrder_fixedOutput() public {
        deal(USDC, maker, USDC_IN);
        _approveMakerToSettlement(USDC, USDC_IN);

        Order memory o = _order(maker, 16, USDC, address(fot), USDC_IN, FOT_OUT, new Item[](0));
        o.timing |= uint256(1) << 101; // BUY (side lives in timing bit 101)
        _markDeltaVerify(o);
        bytes memory sig = _sign(o);

        uint256 gross = FOT_OUT * 10_000 / (10_000 - FEE_BPS) + 1;
        bytes memory cb = abi.encodeCall(DeltaPool.deliverOne, (address(fot), maker, gross));

        // BUY fills are denominated in legsOut[0] units.
        vm.prank(solver);
        settlement.fillWithCallback(o, sig, FOT_OUT, address(pool), cb, CallbackMode.PostInputs);

        assertGe(fot.balanceOf(maker), FOT_OUT, "BUY: fixed output verified net-of-fee");
    }
}
