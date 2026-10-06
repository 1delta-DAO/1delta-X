// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order} from "@core/settlement/Settlement.sol";
import {SolverCallbackExecutor} from "@core/settlement/SolverCallbackExecutor.sol";
import {AggregatorFillSolver, RoutePlan, SurplusPolicy, NO_PATCH} from "@solvers/aggregator/AggregatorFillSolver.sol";
import {RouteSandbox} from "@solvers/aggregator/RouteSandbox.sol";

import {UsdrifForkBase} from "../../modules/redeem/usdrif/test/shared/UsdrifForkBase.t.sol";
import {FreshTxComparisonTest, ISwapRouter02} from "./RawSwapComparison.t.sol";

/// @title SandboxGasBench
/// @notice The per-fill price of {RouteSandbox}, on the same live pool, block and
///         order as {FreshTxComparisonTest}, in FRESH-TRANSACTION conditions (all
///         seeding in `setUp`; see the EIP-2200 trap noted there), in STEADY STATE:
///         the sandbox's standing router approval already exists, as it does after
///         its first fill. Prints execution gas AND the net transaction gas after
///         the end-of-transaction refund (`vm.lastCallGas().gasRefunded`, capped at
///         gasUsed / 5 by EIP-3529) — the sandbox's balance slot is written and
///         restored inside one transaction, so execution gas alone misprices it.
///
///  Measured 2026-10-04 with ONE harness for all three designs (the pre-sandbox
///  contract compiled side by side; 1,000 USDRIF → USDT0, solver floor seeded,
///  spread paid to a treasury), execution / net tx gas:
///
///      design                         direct              pull
///      per-fill router approval       236,354 / 231,042   294,302 / 266,038
///      STANDING router approval       209,569 / 224,157   267,517 / 259,153
///      RouteSandbox (this)            247,905 / 242,593   305,853 / 277,589
///
///  i.e. +11.5k net per fill against the per-fill design and +18.4k net (+38.3k
///  execution) against the standing one — the price of an allowlist-free route.
///  The very first fill through a new sandbox also pays its one-time 0→max
///  approval (~+25k). This contract's own fixture prints ~2.5k more than the table
///  on both paths (direct 250,372 / 245,060, pull 308,320 / 280,056): its
///  inherited `setUp` leaves different slots warm, so compare designs only within
///  one harness.
contract SandboxGasBench is FreshTxComparisonTest {
    function _seedSolverFloor() internal override {
        deal(USDRIF, address(agg), 1);
        deal(USDT0, address(agg), 1);
        deal(USDRIF, TREASURY, 1);
        deal(USDT0, TREASURY, 1);
        // Steady state: the standing approval an earlier fill left on the sandbox.
        vm.prank(address(agg.SANDBOX()));
        IERC20(USDRIF).approve(SWAP_ROUTER_02, type(uint256).max);
    }

    function _bench(string memory label, bool direct) internal {
        Order memory o = _order(80, direct);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _plan(direct ? maker : address(agg));
        p.profitRecipient = TREASURY;
        bytes memory cd = abi.encodeCall(agg.executeFill, (o, sig, AMOUNT_IN, p, ""));
        uint256 g0 = gasleft();
        agg.executeFill(o, sig, AMOUNT_IN, p, "");
        uint256 used = g0 - gasleft();
        _reportNet(label, used, cd);
        assertGe(IERC20(USDT0).balanceOf(maker), FLOOR_OUT, "maker paid");
        address sb = address(agg.SANDBOX());
        assertEq(IERC20(USDRIF).balanceOf(sb), 0, "sandbox ends empty");
        assertEq(IERC20(USDT0).balanceOf(sb), 0, "sandbox ends empty");
    }

    function _reportNet(string memory label, uint256 used, bytes memory cd) internal view {
        Vm.Gas memory g = vm.lastCallGas();
        uint256 refund = uint256(uint64(g.gasRefunded));
        uint256 txGas = 21_000 + _calldataGas(cd) + used;
        uint256 credited = refund < txGas / 5 ? refund : txGas / 5;
        console.log(label);
        console.log("   execution      ", used);
        console.log("   refund         ", refund);
        console.log("   net tx gas     ", txGas - credited);
    }

    function test_sandbox_gas_direct() public {
        _bench("SANDBOX direct (fresh tx, steady state)", true);
    }

    function test_sandbox_gas_pull() public {
        _bench("SANDBOX pull (fresh tx, steady state)", false);
    }
}

/// @title SushiRouteForkTest
/// @notice Real SushiSwap API calldata through the sandbox, on Rootstock.
///
///  FIXTURES. Fetched from `https://api.sushi.com/swap/v7/30` at block 9,295,925
///  (2026-10-04) with `maxSlippage=0.005`, `sender=0x2222…2222` and
///  `recipient=0x1111…1111` placeholders, and replayed at that pinned block:
///
///    curl "https://api.sushi.com/swap/v7/30?tokenIn=<in>&tokenOut=<out>&amount=<amt>\
///          &maxSlippage=0.005&sender=0x2222…&recipient=0x1111…&simulate=false"
///
///  The sender appears nowhere in the returned calldata; the recipient appears in
///  two places (snwap's `recipient` word and the executor's own `to`), and
///  {_forSolver} substitutes the solver for it — byte-for-byte what the API returns
///  when asked with `recipient = solver`. Live calldata in CI would be brittle
///  (the quote moves every block), which is why the fixture is pinned.
///
///  WHAT THE API RETURNS. `tx.to` = 0xAC4c…0b75 is Sushi's **RedSnwapper**, not a
///  RouteProcessor: `snwap(tokenIn, amountIn, recipient, tokenOut, amountOutMin,
///  executor, executorData)` pulls `amountIn` from ITS `msg.sender` (the sandbox)
///  straight into `executor` (an unverified RouteProcessor at 0xC10e…0fb4, run via
///  RedSnwapper's approval-less SafeExecutor), then REQUIRES `recipient`'s
///  `tokenOut` balance to rise by `amountOutMin` (`MinimalOutputBalanceViolation`).
///  So for a pull fill `recipient` must be the SOLVER (or the sandbox, which sweeps
///  to the solver — but then snwap's own floor measures the sandbox). `amountIn` is
///  the word at byte offset 36; the executor swaps its actual balance, so patching
///  that word follows a resized fill — but `amountOutMin` is a fixed figure, so the
///  filler quotes the exact amount it will receive.
contract SushiRouteForkTest is UsdrifForkBase {
    address internal constant RED_SNWAPPER = 0xAC4c6e212A361c968F1725b4d055b47E63F80b75;
    address internal constant SWAP_ROUTER_02 = 0x0B14ff67f0014046b4b99057Aec4509640b3947A;
    address internal constant WRBTC = 0x542fDA317318eBF1d3DEAf76E0b632741A7e677d;
    address internal constant PLACEHOLDER = 0x1111111111111111111111111111111111111111;
    uint256 internal constant SNWAP_AMOUNT_IN_OFFSET = 36;

    /// @dev 100 USDRIF → USDT0; assumedAmountOut 99,756,478, amountOutMin 99,257,695.
    bytes internal constant SUSHI_USDRIF_USDT0 =
        hex"5f3bd1c80000000000000000000000003a15461d8ae0f0fb5fa2629e9da7d66a794a6e370000000000000000000000000000000000000000000000056bc75e2d631000000000000000000000000000001111111111111111111111111111111111111111000000000000000000000000779ded0c9e1022225f8e0630b35a9b54be7137360000000000000000000000000000000000000000000000000000000005ea8d5f000000000000000000000000c10ee9031f2a0b84766a86b55a8d90f357910fb400000000000000000000000000000000000000000000000000000000000000e000000000000000000000000000000000000000000000000000000000000001846be92b890000000000000000000000003a15461d8ae0f0fb5fa2629e9da7d66a794a6e370000000000000000000000000000000000000000000000056bc75e2d63100000000000000000000000000000779ded0c9e1022225f8e0630b35a9b54be7137360000000000000000000000000000000000000000000000000000000005f229be0000000000000000000000001111111111111111111111111111111111111111000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005101a106b319360001013a15461d8ae0f0fb5fa2629e9da7d66a794a6e3701ffff01d845702af381f0405661747a6a20bde0401a19d601c10ee9031f2a0b84766a86b55a8d90f357910fb400ad7933be450b00000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
    /// @dev 0.01 WRBTC → USDT0; assumedAmountOut 848,238,757, amountOutMin 843,997,563.
    bytes internal constant SUSHI_WRBTC_USDT0 =
        hex"5f3bd1c8000000000000000000000000542fda317318ebf1d3deaf76e0b632741a7e677d000000000000000000000000000000000000000000000000002386f26fc100000000000000000000000000001111111111111111111111111111111111111111000000000000000000000000779ded0c9e1022225f8e0630b35a9b54be71373600000000000000000000000000000000000000000000000000000000324e617b000000000000000000000000c10ee9031f2a0b84766a86b55a8d90f357910fb400000000000000000000000000000000000000000000000000000000000000e000000000000000000000000000000000000000000000000000000000000001846be92b89000000000000000000000000542fda317318ebf1d3deaf76e0b632741a7e677d000000000000000000000000000000000000000000000000002386f26fc10000000000000000000000000000779ded0c9e1022225f8e0630b35a9b54be71373600000000000000000000000000000000000000000000000000000000328f18a50000000000000000000000001111111111111111111111111111111111111111000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005101a106b31df0000101542fda317318ebf1d3deaf76e0b632741a7e677d01ffff01aef6fabf3b0c9e5f9d6d5170afc703a633479bbd01c10ee9031f2a0b84766a86b55a8d90f357910fb4008e1c26ca3c0e00000000000000000000000000000000000000000000000000000000000000000000000000000000000000";

    AggregatorFillSolver internal agg;
    address internal constant TREASURY = address(0x7EA5);

    function _forkBlock() internal pure override returns (uint256) {
        return 9_295_925;
    }

    function setUp() public override {
        super.setUp();
        address[] memory ops = new address[](1);
        ops[0] = address(this);
        agg = new AggregatorFillSolver(
            address(settlement), ops, SurplusPolicy({makerPpm: 0, protocolPpm: 0, protocolRecipient: address(0)})
        );
        vm.label(address(agg), "aggregatorSolver");
        vm.label(address(agg.SANDBOX()), "routeSandbox");
        vm.label(RED_SNWAPPER, "sushiRedSnwapper");
        _fund(USDRIF, 1_000e18);
        _fund(WRBTC, 1e18);
    }

    function _fund(address token, uint256 amount) internal {
        deal(token, maker, amount);
        vm.startPrank(maker);
        IERC20(token).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), token, type(uint160).max, 0);
        vm.stopPrank();
    }

    /// @dev Replace every occurrence of the 20-byte placeholder recipient.
    function _forSolver(bytes memory d, address who) internal pure returns (bytes memory) {
        bytes20 a = bytes20(PLACEHOLDER);
        bytes20 b = bytes20(who);
        for (uint256 i; i + 20 <= d.length; i++) {
            bool hit = true;
            for (uint256 j; j < 20; j++) {
                if (d[i + j] != a[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) for (uint256 j; j < 20; j++) d[i + j] = b[j];
        }
        return d;
    }

    function _order(uint256 nonce, address tokenIn, uint256 amtIn, uint256 out) internal view returns (Order memory o) {
        o = Order({
            params: 0,
            pricingModule: address(0),
            maker: maker,
            nonce: nonce,
            legsIn: _legsIn1(tokenIn, amtIn),
            legsOut: _legsOut1(USDT0, out),
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

    function _plan(bytes memory data, uint256 minOut, uint256 offset) internal pure returns (RoutePlan memory) {
        return RoutePlan({
            router: RED_SNWAPPER,
            minOut: minOut,
            maxPay: 0,
            amountInOffset: offset,
            amountOutOffset: NO_PATCH,
            minBumpBps: 0,
            profitRecipient: TREASURY,
            originator: address(0),
            originatorPpm: 0,
            data: data
        });
    }

    function _sandboxEmpty() internal view {
        address sb = address(agg.SANDBOX());
        assertEq(IERC20(USDRIF).balanceOf(sb), 0, "sandbox holds no USDRIF");
        assertEq(IERC20(USDT0).balanceOf(sb), 0, "sandbox holds no USDT0");
        assertEq(IERC20(WRBTC).balanceOf(sb), 0, "sandbox holds no WRBTC");
    }

    /// @dev PULL fill, Sushi route paying the SOLVER: the maker gets the signed
    ///      99 USDT0, the treasury the rest of the swap, nothing stays behind.
    function test_sushi_usdrifToUsdt0_pullFill() public {
        Order memory o = _order(1, USDRIF, 100e18, 99e6);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _plan(_forSolver(SUSHI_USDRIF_USDT0, address(agg)), 99e6, SNWAP_AMOUNT_IN_OFFSET);
        uint256 g0 = gasleft();
        agg.executeFill(o, sig, 100e18, p, "");
        console.log("sushi USDRIF->USDT0 pull fill, exec gas", g0 - gasleft());
        assertEq(IERC20(USDT0).balanceOf(maker), 99e6, "maker paid its signed output");
        assertEq(IERC20(USDT0).balanceOf(TREASURY), 99_756_478 - 99e6, "spread to the treasury");
        assertEq(IERC20(USDT0).balanceOf(address(agg)), 0, "solver keeps nothing");
        _sandboxEmpty();
        assertEq(IERC20(USDT0).allowance(address(agg), address(settlement)), 0, "no Settlement allowance left");
        assertEq(IERC20(USDRIF).allowance(address(agg), address(agg.SANDBOX())), 0, "the solver never approves the sandbox");
        assertEq(IERC20(USDRIF).allowance(address(agg), RED_SNWAPPER), 0, "the solver never approves the router");
    }

    function test_sushi_wrbtcToUsdt0_pullFill() public {
        Order memory o = _order(2, WRBTC, 1e16, 840e6);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _plan(_forSolver(SUSHI_WRBTC_USDT0, address(agg)), 840e6, SNWAP_AMOUNT_IN_OFFSET);
        uint256 makerBefore = IERC20(USDT0).balanceOf(maker);
        uint256 treasuryBefore = IERC20(USDT0).balanceOf(TREASURY);
        agg.executeFill(o, sig, 1e16, p, "");
        assertEq(IERC20(USDT0).balanceOf(maker) - makerBefore, 840e6, "maker paid");
        assertEq(IERC20(USDT0).balanceOf(TREASURY) - treasuryBefore, 848_238_757 - 840e6, "spread to the treasury");
        _sandboxEmpty();
    }

    /// @dev A route quoted to pay the SANDBOX: snwap's floor is measured on the
    ///      sandbox, the sandbox's unconditional sweep hands the output to the
    ///      solver, and the fill completes exactly as if the solver were named.
    function test_sushi_recipientSandbox_isSweptToTheSolver() public {
        Order memory o = _order(3, USDRIF, 100e18, 99e6);
        bytes memory sig = _sign(o);
        RoutePlan memory p =
            _plan(_forSolver(SUSHI_USDRIF_USDT0, address(agg.SANDBOX())), 99e6, SNWAP_AMOUNT_IN_OFFSET);
        agg.executeFill(o, sig, 100e18, p, "");
        assertEq(IERC20(USDT0).balanceOf(maker), 99e6, "maker paid");
        assertEq(IERC20(USDT0).balanceOf(TREASURY), 99_756_478 - 99e6, "spread to the treasury");
        _sandboxEmpty();
    }

    /// @dev A route quoted for SOMEONE ELSE (the filler EOA habit): snwap pays that
    ///      address, the solver measures nothing, and the fill reverts on minOut.
    function test_sushi_wrongRecipient_reverts() public {
        Order memory o = _order(4, USDRIF, 100e18, 99e6);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _plan(_forSolver(SUSHI_USDRIF_USDT0, address(0xE0A)), 99e6, SNWAP_AMOUNT_IN_OFFSET);
        vm.expectRevert(
            abi.encodeWithSelector(
                SolverCallbackExecutor.CallbackFailed.selector,
                abi.encodeWithSelector(AggregatorFillSolver.InsufficientOutput.selector, uint256(0), uint256(99e6))
            )
        );
        agg.executeFill(o, sig, 100e18, p, "");
        assertEq(IERC20(USDRIF).balanceOf(maker), 1_000e18, "maker untouched");
    }

    /// @dev The patch is safe and the executor follows it (it swaps its actual
    ///      balance), but snwap's `amountOutMin` is a fixed word from the full-size
    ///      quote — so a fill resized below the quote fails snwap's own floor. The
    ///      filler therefore quotes the exact amount it will receive.
    function test_sushi_resizedFillFailsSnwapsOwnFloor() public {
        Order memory o = _order(5, USDRIF, 100e18, 98e6);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _plan(_forSolver(SUSHI_USDRIF_USDT0, address(agg)), 98e6, SNWAP_AMOUNT_IN_OFFSET);
        vm.expectRevert(); // MinimalOutputBalanceViolation(USDT0, ~98.76e6), wrapped
        agg.executeFill(o, sig, 99e18, p, "");
    }

    /// @dev THE STANDING SANDBOX APPROVAL IS NOT EXPLOITABLE THROUGH SNWAP. After a
    ///      fill the sandbox holds a max USDRIF approval to RedSnwapper. snwap pulls
    ///      only from its own `msg.sender`, and the sandbox is empty anyway — a
    ///      stranger calling it gets nothing out of the sandbox.
    function test_sushi_standingSandboxApprovalIsInert() public {
        test_sushi_usdrifToUsdt0_pullFill();
        address sb = address(agg.SANDBOX());
        assertEq(IERC20(USDRIF).allowance(sb, RED_SNWAPPER), type(uint256).max, "standing approval left in place");

        address eve = address(0xE7E);
        bytes memory d = _forSolver(SUSHI_USDRIF_USDT0, eve);
        vm.prank(eve);
        (bool ok,) = RED_SNWAPPER.call(d); // eve holds no USDRIF: snwap pulls from eve, not the sandbox
        assertFalse(ok, "snwap pulls from its caller only");
        // And even a direct transferFrom on the approval finds an empty account.
        vm.prank(RED_SNWAPPER);
        vm.expectRevert();
        IERC20(USDRIF).transferFrom(sb, eve, 1);
        _sandboxEmpty();
    }

    /// @dev Oku's SwapRouter02 at the same block, through the same sandbox — both
    ///      venues with ONE solver instance and no allowlist.
    function test_oku_swapRouter02_pullFill_sameInstance() public {
        Order memory o = _order(6, USDRIF, 100e18, 99e6);
        bytes memory sig = _sign(o);
        RoutePlan memory p = RoutePlan({
            router: SWAP_ROUTER_02,
            minOut: 99e6,
            maxPay: 0,
            amountInOffset: 4 + 4 * 32,
            amountOutOffset: NO_PATCH,
            minBumpBps: 0,
            profitRecipient: TREASURY,
            originator: address(0),
            originatorPpm: 0,
            data: abi.encodeCall(
                ISwapRouter02.exactInputSingle,
                (
                    ISwapRouter02.ExactInputSingleParams({
                        tokenIn: USDRIF,
                        tokenOut: USDT0,
                        fee: 500,
                        recipient: address(agg),
                        amountIn: 100e18,
                        amountOutMinimum: 99e6,
                        sqrtPriceLimitX96: 0
                    })
                )
            )
        });
        agg.executeFill(o, sig, 100e18, p, "");
        assertEq(IERC20(USDT0).balanceOf(maker), 99e6, "maker paid");
        assertGt(IERC20(USDT0).balanceOf(TREASURY), 0, "spread to the treasury");
        _sandboxEmpty();
        // Then Sushi, same instance.
        test_sushi_wrbtcToUsdt0_pullFill();
    }
}
