// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, OrderSide, Validator} from "@core/settlement/UniversalSettlement.sol";
import {UniversalSettlement} from "@core/settlement/UniversalSettlement.sol";
import {IFillModule} from "@core/interfaces/IFillModule.sol";
import {FullFillModule} from "@core/modules/FullFillModule.sol";
import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

/// @dev Configurable fill module for the tests: optionally forces a specific
/// `delta` (else echoes the requested `fillAmount`), and optionally requires the
/// filler's `takerData` to match a fixed blob — the taker↔maker match gate.
contract MockFillModule is IFillModule {
    uint256 public forcedDelta;
    bool public useForced;
    bytes public required;

    function force(uint256 d) external {
        forcedDelta = d;
        useForced = true;
    }

    function setRequired(bytes calldata r) external {
        required = r;
    }

    function resolveFill(Order calldata, uint256, uint256 fillAmount, bytes calldata takerData)
        external
        view
        returns (uint256)
    {
        if (required.length != 0) require(keccak256(takerData) == keccak256(required), "fill mismatch");
        return useForced ? forcedDelta : fillAmount;
    }
}

/// @dev The fill-module generalization: an order can delegate "how much does this
/// fill advance?" to a maker-signed module, decoupling the denominator from a
/// fungible leg. The core keeps the over-fill cap and the single-fraction
/// scaling; the module only picks the delta (and gates the counterparty match).
contract FillModuleTest is CoreSettlementBase {
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    FullFillModule fullFill;
    MockFillModule mock;

    function setUp() public override {
        super.setUp();
        fullFill = new FullFillModule();
        mock = new MockFillModule();
        vm.label(address(fullFill), "fullFillModule");
        vm.label(address(mock), "mockFillModule");
        vm.label(DAI, "DAI");
    }

    // ── Identity default: fillModule/fillTotal = 0 behaves exactly as today ──
    function test_identity_noModule_unchanged() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;
        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);
        _approveMakerToSettlement(USDC, usdcIn);
        _approveSolverSide(wethOut, WETH);

        Order memory o = _order(maker, 0, USDC, WETH, usdcIn, wethOut, new Item[](0));
        assertEq(o.fillModule, address(0), "no module by default");
        assertEq(o.fillTotal, 0, "no explicit total by default");
        bytes memory sig = _sign(o);

        vm.prank(solver);
        settlement.fill(o, sig, usdcIn);
        assertEq(IERC20(WETH).balanceOf(maker), wethOut, "identity fill delivers full output");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "identity fill pays full input");
    }

    // ── FullFillModule: indivisible, one shot completes; second fill reverts ──
    function test_fullFillModule_allOrNothing() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;
        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);
        _approveMakerToSettlement(USDC, usdcIn);
        _approveSolverSide(wethOut, WETH);

        Order memory o = _order(maker, 1, USDC, WETH, usdcIn, wethOut, new Item[](0));
        o.fillModule = address(fullFill);
        o.fillTotal = 1; // indivisible unit — fraction is 1/1 at the single fill
        bytes memory sig = _sign(o);

        // A "partial" request is ignored — the module returns the whole total.
        vm.prank(solver);
        settlement.fill(o, sig, 999, ""); // fillAmount irrelevant to FullFillModule
        assertEq(IERC20(WETH).balanceOf(maker), wethOut, "full output on the single fill");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "full input on the single fill");

        // A second fill: delta = fillTotal - prevFilled = 0 ⇒ ZeroFill.
        vm.prank(solver);
        vm.expectRevert(UniversalSettlement.ZeroFill.selector);
        settlement.fill(o, sig, 1, "");
    }

    // ── The module gates the counterparty match via takerData ──
    function test_matchModule_revertsOnMismatch() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;
        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);
        _approveMakerToSettlement(USDC, usdcIn);
        _approveSolverSide(wethOut, WETH);

        mock.setRequired(abi.encode("the-right-proof"));
        Order memory o = _order(maker, 2, USDC, WETH, usdcIn, wethOut, new Item[](0));
        o.fillModule = address(mock);
        o.fillTotal = usdcIn; // denominator = the leg anchor value
        bytes memory sig = _sign(o);

        // Wrong takerData → the module reverts the fill.
        vm.prank(solver);
        vm.expectRevert(); // "fill mismatch"
        settlement.fill(o, sig, usdcIn, abi.encode("wrong"));

        // Correct takerData → fills.
        vm.prank(solver);
        settlement.fill(o, sig, usdcIn, abi.encode("the-right-proof"));
        assertEq(IERC20(WETH).balanceOf(maker), wethOut, "match to full fill");
    }

    // ── SAFETY: a module cannot over-extract — the core cap catches delta > total ──
    function test_overfillCap_moduleCannotExceedTotal() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;
        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);
        _approveMakerToSettlement(USDC, usdcIn);
        _approveSolverSide(wethOut, WETH);

        mock.force(usdcIn + 1); // hostile module: claim MORE than the whole order
        Order memory o = _order(maker, 3, USDC, WETH, usdcIn, wethOut, new Item[](0));
        o.fillModule = address(mock);
        o.fillTotal = usdcIn;
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert(UniversalSettlement.OverFill.selector);
        settlement.fill(o, sig, usdcIn, "");
    }

    // ── minFillAnchor gates the module's DELTA (the real progress), not the
    //    solver's requested fillAmount — so a dust delta can't strand a tail. ──
    function test_minFillAnchor_appliesToDelta() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;
        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);
        _approveMakerToSettlement(USDC, usdcIn);
        _approveSolverSide(wethOut, WETH);

        Order memory o = _order(maker, 7, USDC, WETH, usdcIn, wethOut, new Item[](0));
        o.fillModule = address(mock);
        o.fillTotal = usdcIn;
        o.minFillAnchor = usdcIn / 2; // maker: no fill may advance by less than half
        mock.force(1); //                 module returns a dust delta of 1
        bytes memory sig = _sign(o);

        // Solver requests the full amount, but the module's delta (1) is below the
        // floor → FillTooSmall (previously this slipped through — the check was on
        // fillAmount, not delta).
        vm.prank(solver);
        vm.expectRevert(UniversalSettlement.FillTooSmall.selector);
        settlement.fill(o, sig, usdcIn, "");
    }

    // ── SAFETY: a module returning 0 is a no-op fill — rejected by the core ──
    function test_zeroDelta_reverts() public {
        Order memory o = _order(maker, 4, USDC, WETH, 2_000e6, 1 ether, new Item[](0));
        o.fillModule = address(mock);
        o.fillTotal = 2_000e6;
        mock.force(0);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert(UniversalSettlement.ZeroFill.selector);
        settlement.fill(o, sig, 2_000e6, "");
    }

    // ── THE core invariant: the module picks ONE fraction; the core scales EVERY
    //    leg by it uniformly. A module returning half the total delivers exactly
    //    half of every output leg and charges half of every input leg. ──
    function test_singleFraction_scalesAllLegsUniformly() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;
        uint256 daiOut = 400e18;
        uint256 total = 2; // divisible into two halves

        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);
        deal(DAI, solver, daiOut);
        _approveMakerToSettlement(USDC, usdcIn);
        _approveSolverSide(wethOut, WETH);
        vm.startPrank(solver);
        IERC20(DAI).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), DAI, uint160(daiOut), 0);
        vm.stopPrank();

        // One input (USDC), two outputs (WETH, DAI) — all to the maker.
        address[] memory tOut = new address[](2);
        tOut[0] = WETH;
        tOut[1] = DAI;
        uint256[] memory aOut = new uint256[](2);
        aOut[0] = wethOut;
        aOut[1] = daiOut;

        Order memory o = _order(maker, 5, USDC, WETH, usdcIn, wethOut, new Item[](0));
        o.tokenOut = tOut;
        o.startAmountOut = aOut;
        o.endAmountOut = aOut;
        o.recipientOut = new address[](2); // both → maker
        o.fillModule = address(mock);
        o.fillTotal = total;
        bytes memory sig = _sign(o);

        // Fraction 1/2: force delta = 1 of total = 2.
        mock.force(1);
        vm.prank(solver);
        settlement.fill(o, sig, 1, "");

        // EVERY leg scaled by exactly 1/2 — the same fraction.
        assertEq(IERC20(WETH).balanceOf(maker), wethOut / 2, "WETH leg half");
        assertEq(IERC20(DAI).balanceOf(maker), daiOut / 2, "DAI leg half");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn / 2, "USDC input half");

        // The second half completes the order (delta 1 → total 2).
        vm.prank(solver);
        settlement.fill(o, sig, 1, "");
        assertEq(IERC20(WETH).balanceOf(maker), wethOut, "WETH leg whole after both halves");
        assertEq(IERC20(DAI).balanceOf(maker), daiOut, "DAI leg whole");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "USDC input whole");
    }

    // ── Lens: a module order may carry empty fungible legs (pure NFT-swap shape);
    //    a module with no denominator is rejected. ──
    function test_lens_moduleOrder_shapes() public view {
        // Module-denominated, empty tokenIn/tokenOut, one (mock) item → valid.
        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.MAKE, module: address(0xD0D0), amount: 1, recipient: address(0), data: ""});
        Order memory o = Order({
            maker: maker,
            side: OrderSide.SELL,
            nonce: 6,
            deadline: block.timestamp + 1 hours,
            tokenIn: new address[](0),
            startAmountIn: new uint256[](0),
            endAmountIn: new uint256[](0),
            decayStartTime: 0,
            decayDuration: 0,
            tokenOut: new address[](0),
            startAmountOut: new uint256[](0),
            endAmountOut: new uint256[](0),
            recipientOut: new address[](0),
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
            fillModule: address(fullFill),
            fillTotal: 1
        });
        (bool ok, string memory reason) = lens.validateOrder(o);
        assertTrue(ok, string.concat("pure module order valid: ", reason));

        // A module with NO explicit total AND no leg to derive one → rejected.
        o.fillTotal = 0;
        (ok, reason) = lens.validateOrder(o);
        assertFalse(ok, "module without denominator rejected");
        assertEq(reason, "fill module without denominator");
    }
}
