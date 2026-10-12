// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order} from "@core/settlement/Settlement.sol";
import {
    AggregatorFillSolver,
    RoutePlan,
    SurplusPolicy,
    NO_PATCH,
    POOL_ROUTE,
    Permit2612,
    PoolVenue
} from "@solvers/aggregator/AggregatorFillSolver.sol";

import {UsdrifForkBase} from "../../modules/redeem/usdrif/test/shared/UsdrifForkBase.t.sol";
import {newAgg} from "./shared/AggDeploy.sol";

interface IV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    struct ExactOutputParams {
        bytes path;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256);
    function exactOutputSingle(ExactOutputSingleParams calldata p) external payable returns (uint256);
    function exactInput(ExactInputParams calldata p) external payable returns (uint256);
    function exactOutput(ExactOutputParams calldata p) external payable returns (uint256);
}

interface IErc2612 {
    function nonces(address owner) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;
}

/// @title PoolRouteForkHarness
/// @notice DIRECT POOL ROUTES vs the SANDBOX route vs a RAW SwapRouter02 swap, on live
///         Rootstock pools at one pinned block, in fresh-transaction conditions (every
///         balance, approval, floor and signature prepared in `setUp`, which Foundry
///         runs as a separate transaction — EIP-2929/2200: a slot first touched in the
///         measured call is priced cold, as on chain). Prints execution gas, the
///         end-of-transaction refund and the NET transaction gas (execution + calldata
///         + 21k intrinsic − refund capped at gasUsed / 5), like {SandboxGasBench}.
///
///  Shapes (the live beta ones):
///    • single hop, WRBTC → USDT0 on the Oku 0.3% pool 0xaeF6…9Bbd, 0.0002 WRBTC —
///      DIRECT exact-output (what the app signs) and PULL exact-input;
///    • two hops, USDRIF →(0.05%)→ USDT0 →(0.3%)→ WRBTC, 100 USDRIF — direct exact-output
///      (the recursive callback) and pull exact-input;
///    • the same single hop on SushiSwap v3's pool 0x6d77…Fd71 (venue 1);
///    • the ERC-2612 permit overhead: a USD₮0 → WRBTC order funded by a Permit3 grant,
///      by a plain approval to Settlement, and by a permit passed to `executeFill`;
///    • three hops over both venues, USDRIF →(Oku 0.05%)→ USDT0 →(Sushi 0.3%)→ WRBTC
///      →(Oku 0.3%)→ RIF (and the all-Oku path a raw SwapRouter02 `exactInput` takes);
///    • RETAIN mode (`profitRecipient` = the solver) for the pool shapes;
///    • an exact-input multi-hop route whose INTERMEDIATE token(s) the solver holds no
///      floor of ({PoolRouteForkColdIntermediateBench}) — measures equal to the seeded
///      bench: the intermediate slot round-trips inside the tx, so a floor buys nothing.
///  ⚠ NOTHING is read in the measured transaction before the fill (a `balanceOf(maker)`
///  "before" read warmed the slots the fill then wrote and under-stated the 2-hop
///  figures by 4.5k until 2026-10-12): pre-fill balances come from what `setUp` dealt.
///  `AGG_ARTIFACT=<artifact>` swaps in another build of the solver ({newAgg}) — `make
///  test-solvers-deployed` runs this bench against the shipped via-IR bytecode.
///  Steady state everywhere: the solver holds its 1-wei floors, the treasury and the
///  maker have received each token before, the sandbox's standing router approvals
///  exist (as after its first fill).
abstract contract PoolRouteForkHarness is UsdrifForkBase {
    address internal constant SWAP_ROUTER_02 = 0x0B14ff67f0014046b4b99057Aec4509640b3947A;
    address internal constant WRBTC = 0x542fDA317318eBF1d3DEAf76E0b632741A7e677d;
    address internal constant OKU_FACTORY = 0xaF37EC98A00FD63689CF3060BF3B6784E00caD82;
    address internal constant SUSHI_V3_FACTORY = 0x46B3fDF7b5CDe91Ac049936bF0bDb12c5d22202e;
    bytes32 internal constant V3_INIT_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
    address internal constant OKU_WRBTC_USDT0_3000 = 0xaeF6fABf3b0C9e5F9d6D5170AfC703A633479Bbd;
    address internal constant SUSHI_WRBTC_USDT0_3000 = 0x6d778c369cB386D50f4Ee676c5c264374C52Fd71;
    address internal constant OKU_USDRIF_USDT0_500 = 0xD845702af381f0405661747a6a20bde0401A19d6;
    address internal constant TREASURY = address(0x7EA5);
    address internal constant OKU_RIF_WRBTC_3000 = 0xfBa1ca3F3F5eafa65c2a535a54Fe11f1C3a5f416;

    uint256 internal constant BTC_IN = 2e14; //       0.0002 WRBTC (the live fill shape)
    uint256 internal constant BTC_OWED = 16e6; //     16 USDT0 (~16.96 quoted at the block)
    uint256 internal constant RIF_IN = 100e18; //     100 USDRIF
    uint256 internal constant RIF_OWED = 11e14; //    0.0011 WRBTC (~0.00117 quoted)
    uint256 internal constant USDT_IN = 20e6; //      20 USD₮0
    uint256 internal constant USDT_OWED = 2e14; //    0.0002 WRBTC (~0.000235 quoted)
    uint256 internal constant MAKER_WRBTC = 1e18; //  the maker's WRBTC after setUp
    uint256 internal constant RIF3_OWED = 900e18; //  900 RIF for 100 USDRIF over 3 hops (~1,0xx quoted)

    AggregatorFillSolver internal agg;
    address internal sandbox;
    bytes32 internal ds; // Settlement's EIP-712 domain separator, read in setUp
    address internal trader = address(0x7AAdE);

    uint256 internal constant M2_PK = 0xB0B; // the permit-funded maker
    uint256 internal constant M3_PK = 0xB0C; // the Permit3-funded maker (baseline)
    uint256 internal constant M4_PK = 0xB0D; // the directly-approved maker (baseline)
    address internal m2;
    address internal m3;
    address internal m4;
    Permit2612 internal storedPermit;

    function _forkBlock() internal pure override returns (uint256) {
        return 9_295_925;
    }

    function setUp() public virtual override {
        super.setUp();
        address[] memory ops = new address[](1);
        ops[0] = address(this);
        PoolVenue[] memory venues = new PoolVenue[](2);
        venues[0] = PoolVenue({factory: OKU_FACTORY, initCodeHash: V3_INIT_HASH});
        venues[1] = PoolVenue({factory: SUSHI_V3_FACTORY, initCodeHash: V3_INIT_HASH});
        SurplusPolicy memory none = SurplusPolicy({makerPpm: 0, protocolPpm: 0, protocolRecipient: address(0)});
        // `AGG_ARTIFACT=<artifact json>` measures a solver compiled under ANOTHER profile
        // (the shipped via-IR `solvers-deploy` build: `make test-solvers-deployed`)
        // against the same Settlement / fork state — see {newAgg}.
        agg = newAgg(address(settlement), ops, none, venues);
        sandbox = address(agg.SANDBOX());
        ds = settlement.DOMAIN_SEPARATOR();
        vm.label(address(agg), "aggregatorSolver");
        vm.label(WRBTC, "WRBTC");

        // Maker: funds, Permit3 grants, and a history of receiving every token.
        _fund(maker, WRBTC, MAKER_WRBTC);
        _fund(maker, USDRIF, 10_000e18);
        deal(USDT0, maker, 1);
        // Steady-state floors / recipients.
        address[4] memory toks = [WRBTC, USDT0, USDRIF, RIF];
        deal(RIF, maker, 1);
        for (uint256 i; i < 4; i++) {
            if (!_noFloor(toks[i])) deal(toks[i], address(agg), 1);
            deal(toks[i], TREASURY, 1);
        }
        // The sandbox's standing approvals an earlier fill left (steady state).
        vm.startPrank(sandbox);
        IERC20(WRBTC).approve(SWAP_ROUTER_02, type(uint256).max);
        IERC20(USDRIF).approve(SWAP_ROUTER_02, type(uint256).max);
        vm.stopPrank();
        // The raw-swap trader: funds, the one-time router approval, prior receipts.
        deal(WRBTC, trader, 1e18);
        deal(USDRIF, trader, 10_000e18);
        deal(USDT0, trader, 1);
        deal(RIF, trader, 1);
        vm.startPrank(trader);
        IERC20(WRBTC).approve(SWAP_ROUTER_02, type(uint256).max);
        IERC20(USDRIF).approve(SWAP_ROUTER_02, type(uint256).max);
        vm.stopPrank();

        // The permit-funded maker: USD₮0 only, NO approval of anything; a permit to
        // Settlement signed in setUp (the token's nonce/domain reads are not part of
        // the fill transaction).
        m2 = vm.addr(M2_PK);
        deal(USDT0, m2, 1_000e6);
        deal(WRBTC, m2, 1);
        storedPermit = _signPermit(M2_PK, m2, USDT_IN, block.timestamp + 1 hours);
        // The two baselines, same token and size: a Permit3 grant, and a plain approval
        // to Settlement of exactly the order input (what the permit would create).
        m3 = vm.addr(M3_PK);
        _fund(m3, USDT0, 1_000e6);
        deal(WRBTC, m3, 1);
        m4 = vm.addr(M4_PK);
        deal(USDT0, m4, 1_000e6);
        deal(WRBTC, m4, 1);
        vm.prank(m4);
        IERC20(USDT0).approve(address(settlement), USDT_IN);
    }

    /// @dev Tokens the solver holds NO 1-wei floor of in this harness (none by default).
    function _noFloor(address) internal view virtual returns (bool) {
        return false;
    }

    function _fund(address who, address token, uint256 amount) internal {
        deal(token, who, amount);
        vm.startPrank(who);
        IERC20(token).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), token, type(uint160).max, 0);
        vm.stopPrank();
    }

    function _signPermit(uint256 pk, address owner, uint256 value, uint256 deadline)
        internal
        view
        returns (Permit2612 memory p)
    {
        IErc2612 t = IErc2612(USDT0);
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                address(settlement),
                value,
                t.nonces(owner),
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", t.DOMAIN_SEPARATOR(), structHash)));
        p = Permit2612({token: USDT0, owner: owner, value: value, deadline: deadline, v: v, r: r, s: s});
    }

    // ───────────────────────── builders ─────────────────────────

    function _order(address who, uint256 nonce, address tokenIn, uint256 amtIn, address tokenOut, uint256 owed, bool direct)
        internal
        view
        returns (Order memory o)
    {
        o = Order({
            params: 0,
            pricingModule: address(0),
            maker: who,
            nonce: nonce,
            legsIn: _legsIn1(tokenIn, amtIn),
            legsOut: _legsOut1(tokenOut, owed),
            timing: _expiryBits(block.timestamp + 1 hours) | (direct ? uint256(1) << 104 : 0),
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

    function _sig(Order memory o, uint256 pk) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", ds, _hashOrder(o))));
        return abi.encodePacked(r, s, v);
    }

    function _plan(address router, bytes memory data, uint256 minOut) internal pure returns (RoutePlan memory) {
        return RoutePlan({
            router: router,
            minOut: minOut,
            maxPay: 0,
            amountInOffset: NO_PATCH,
            amountOutOffset: NO_PATCH,
            minBumpBps: 0,
            profitRecipient: TREASURY,
            originator: address(0),
            originatorPpm: 0,
            data: data
        });
    }

    function _poolData(uint256 amountIn, uint256 amountOut, bytes memory path) internal pure returns (bytes memory) {
        return abi.encodePacked(amountIn, amountOut, path);
    }

    function _btcPath(uint8 venue) internal pure returns (bytes memory) {
        return abi.encodePacked(WRBTC, uint24(3000), venue, USDT0);
    }

    function _rifPath() internal pure returns (bytes memory) {
        return abi.encodePacked(USDRIF, uint24(500), uint8(0), USDT0, uint24(3000), uint8(0), WRBTC);
    }

    function _routerPath2() internal pure returns (bytes memory) {
        return abi.encodePacked(USDRIF, uint24(500), USDT0, uint24(3000), WRBTC);
    }

    /// @dev Three hops over BOTH venues: USDRIF →(Oku 0.05%)→ USDT0 →(Sushi 0.3%)→ WRBTC
    ///      →(Oku 0.3%)→ RIF.
    function _mixedPath3() internal pure returns (bytes memory) {
        return abi.encodePacked(
            USDRIF, uint24(500), uint8(0), USDT0, uint24(3000), uint8(1), WRBTC, uint24(3000), uint8(0), RIF
        );
    }

    /// @dev The same three hops all on Oku (what SwapRouter02 can route).
    function _okuPath3() internal pure returns (bytes memory) {
        return abi.encodePacked(
            USDRIF, uint24(500), uint8(0), USDT0, uint24(3000), uint8(0), WRBTC, uint24(3000), uint8(0), RIF
        );
    }

    function _routerPath3() internal pure returns (bytes memory) {
        return abi.encodePacked(USDRIF, uint24(500), USDT0, uint24(3000), WRBTC, uint24(3000), RIF);
    }

    function _routerPath2Reversed() internal pure returns (bytes memory) {
        return abi.encodePacked(WRBTC, uint24(3000), USDT0, uint24(500), USDRIF);
    }

    // ───────────────────────── measurement ─────────────────────────

    function _calldataGas(bytes memory data) internal pure returns (uint256 g) {
        for (uint256 i; i < data.length; i++) g += data[i] == 0 ? 4 : 16;
    }

    function _report(string memory label, uint256 used, bytes memory cd) internal view {
        Vm.Gas memory g = vm.lastCallGas();
        uint256 refund = uint256(uint64(g.gasRefunded));
        uint256 txGas = 21_000 + _calldataGas(cd) + used;
        uint256 credited = refund < txGas / 5 ? refund : txGas / 5;
        console.log(label);
        console.log("   execution      ", used);
        console.log("   calldata bytes ", cd.length);
        console.log("   refund         ", refund);
        console.log("   net tx gas     ", txGas - credited);
    }

    function _fill(string memory label, Order memory o, bytes memory sig, uint256 amt, RoutePlan memory p, Permit2612[] memory ps)
        internal
    {
        bytes memory cd = abi.encodeCall(agg.executeFill, (o, sig, amt, p, "", ps));
        uint256 g0 = gasleft();
        agg.executeFill(o, sig, amt, p, "", ps);
        uint256 used = g0 - gasleft();
        _report(label, used, cd);
    }

    function _np() internal pure returns (Permit2612[] memory) {
        return new Permit2612[](0);
    }

    function _sandboxEmpty() internal view {
        assertEq(IERC20(WRBTC).balanceOf(sandbox), 0, "sandbox WRBTC");
        assertEq(IERC20(USDT0).balanceOf(sandbox), 0, "sandbox USDT0");
        assertEq(IERC20(USDRIF).balanceOf(sandbox), 0, "sandbox USDRIF");
    }

    function _usdtOrder(address who) internal view returns (Order memory o, RoutePlan memory p) {
        o = _order(who, 1, USDT0, USDT_IN, WRBTC, USDT_OWED, true);
        p = _plan(POOL_ROUTE, _poolData(USDT_IN, USDT_OWED, abi.encodePacked(USDT0, uint24(3000), uint8(0), WRBTC)), 0);
    }
}

/// @title PoolRouteForkBench
/// @notice The measurements and live-chain checks over {PoolRouteForkHarness} — see its
///         header for the conditions.
contract PoolRouteForkBench is PoolRouteForkHarness {
    // ═══════════════ pool derivation against the live chain ═══════════════

    function test_fork_poolDerivation_bothVenues() public view {
        assertEq(agg.poolFor(0, WRBTC, USDT0, 3000), OKU_WRBTC_USDT0_3000, "Oku WRBTC/USDT0 0.3%");
        assertEq(agg.poolFor(1, USDT0, WRBTC, 3000), SUSHI_WRBTC_USDT0_3000, "Sushi v3 WRBTC/USDT0 0.3%");
        assertEq(agg.poolFor(0, USDRIF, USDT0, 500), OKU_USDRIF_USDT0_500, "Oku USDRIF/USDT0 0.05%");
        assertEq(agg.poolFor(0, WRBTC, USDT0, 3000), IV3Factory(OKU_FACTORY).getPool(WRBTC, USDT0, 3000));
        assertEq(agg.poolFor(1, WRBTC, USDT0, 3000), IV3Factory(SUSHI_V3_FACTORY).getPool(WRBTC, USDT0, 3000));
        assertEq(agg.poolFor(0, USDRIF, USDT0, 500), IV3Factory(OKU_FACTORY).getPool(USDRIF, USDT0, 500));
    }

    // ═══════════════ raw SwapRouter02 (the trader's own tx) ═══════════════

    function test_raw_exactOutputSingle() public {
        bytes memory cd = abi.encodeCall(
            IRouter02.exactOutputSingle,
            (IRouter02.ExactOutputSingleParams(WRBTC, USDT0, 3000, trader, BTC_OWED, BTC_IN, 0))
        );
        vm.prank(trader, trader);
        uint256 g0 = gasleft();
        (bool ok,) = SWAP_ROUTER_02.call(cd);
        uint256 used = g0 - gasleft();
        assertTrue(ok);
        _report("RAW SwapRouter02 exactOutputSingle 0.0002 WRBTC->16 USDT0", used, cd);
    }

    function test_raw_exactInputSingle() public {
        bytes memory cd = abi.encodeCall(
            IRouter02.exactInputSingle, (IRouter02.ExactInputSingleParams(WRBTC, USDT0, 3000, trader, BTC_IN, BTC_OWED, 0))
        );
        vm.prank(trader, trader);
        uint256 g0 = gasleft();
        (bool ok,) = SWAP_ROUTER_02.call(cd);
        uint256 used = g0 - gasleft();
        assertTrue(ok);
        _report("RAW SwapRouter02 exactInputSingle 0.0002 WRBTC", used, cd);
    }

    function test_raw_exactOutput_2hop() public {
        bytes memory cd = abi.encodeCall(
            IRouter02.exactOutput, (IRouter02.ExactOutputParams(_routerPath2Reversed(), trader, RIF_OWED, RIF_IN))
        );
        vm.prank(trader, trader);
        uint256 g0 = gasleft();
        (bool ok,) = SWAP_ROUTER_02.call(cd);
        uint256 used = g0 - gasleft();
        assertTrue(ok);
        _report("RAW SwapRouter02 exactOutput 2-hop USDRIF->USDT0->WRBTC", used, cd);
    }

    function test_raw_exactInput_2hop() public {
        bytes memory cd =
            abi.encodeCall(IRouter02.exactInput, (IRouter02.ExactInputParams(_routerPath2(), trader, RIF_IN, RIF_OWED)));
        vm.prank(trader, trader);
        uint256 g0 = gasleft();
        (bool ok,) = SWAP_ROUTER_02.call(cd);
        uint256 used = g0 - gasleft();
        assertTrue(ok);
        _report("RAW SwapRouter02 exactInput 2-hop USDRIF->USDT0->WRBTC", used, cd);
    }

    // ═══════════════ single hop WRBTC → USDT0 ═══════════════

    function test_single_direct_exactOut_sandbox() public {
        Order memory o = _order(maker, 1, WRBTC, BTC_IN, USDT0, BTC_OWED, true);
        RoutePlan memory p = _plan(
            SWAP_ROUTER_02,
            abi.encodeCall(
                IRouter02.exactOutputSingle,
                (IRouter02.ExactOutputSingleParams(WRBTC, USDT0, 3000, maker, BTC_OWED, BTC_IN, 0))
            ),
            0
        );
        _fill("SANDBOX direct exact-out 1 hop (live shape)", o, _sig(o, makerPk), BTC_IN, p, _np());
        assertEq(IERC20(USDT0).balanceOf(maker), 1 + BTC_OWED, "maker paid exactly");
        _sandboxEmpty();
    }

    function test_single_direct_exactOut_pool() public {
        Order memory o = _order(maker, 1, WRBTC, BTC_IN, USDT0, BTC_OWED, true);
        RoutePlan memory p = _plan(POOL_ROUTE, _poolData(BTC_IN, BTC_OWED, _btcPath(0)), 0);
        _fill("POOL direct exact-out 1 hop (live shape)", o, _sig(o, makerPk), BTC_IN, p, _np());
        assertEq(IERC20(USDT0).balanceOf(maker), 1 + BTC_OWED, "maker paid exactly");
        assertGt(IERC20(WRBTC).balanceOf(TREASURY), 1, "WRBTC residue = the spread");
        assertEq(IERC20(USDT0).balanceOf(address(agg)), 1, "the solver never touched USDT0");
        _sandboxEmpty();
    }

    /// @dev The same with `amountOutOffset = 32` (typed callback, live `pricedOut[0]`) —
    ///      what the beta sends for a SELL still decaying.
    function test_single_direct_exactOut_pool_liveOut() public {
        Order memory o = _order(maker, 1, WRBTC, BTC_IN, USDT0, BTC_OWED, true);
        RoutePlan memory p = _plan(POOL_ROUTE, _poolData(BTC_IN, 0, _btcPath(0)), 0);
        p.amountOutOffset = 32;
        _fill("POOL direct exact-out 1 hop, live amountOut (typed)", o, _sig(o, makerPk), BTC_IN, p, _np());
        assertEq(IERC20(USDT0).balanceOf(maker), 1 + BTC_OWED, "maker paid exactly the live price");
    }

    /// @dev FILL-ONCE (`timing` bit 100) on a WORD-PACKED nonce — what the app signs for
    ///      every MARKET ticket since 2026-10-12: the maker's SECOND order in a bitmap
    ///      word whose first order already filled, against the same order as a classic
    ///      per-hash counter order. The fill-once fill sets a bit in that warm, already
    ///      non-zero word instead of writing a fresh `filled[hash]` slot.
    function test_fillOnce_packedNonce_direct_exactOut_pool() public {
        uint256 fillOnce = uint256(1) << 100;
        RoutePlan memory p = _plan(POOL_ROUTE, _poolData(BTC_IN, BTC_OWED, _btcPath(0)), 0);
        // The maker's first order in word 2 (nonce 512), filled: the word is non-zero.
        Order memory first = _order(maker, 512, WRBTC, BTC_IN, USDT0, BTC_OWED, true);
        first.timing |= fillOnce;
        agg.executeFill(first, _sig(first, makerPk), BTC_IN, p, "", _np());
        assertTrue(settlement.isNonceCancelled(maker, 512), "first fill consumed its nonce");

        uint256 snap = vm.snapshotState();
        Order memory counter = _order(maker, 513, WRBTC, BTC_IN, USDT0, BTC_OWED, true);
        _fill("POOL direct exact-out 1 hop, COUNTER order, 2nd nonce of the word", counter, _sig(counter, makerPk), BTC_IN, p, _np());
        assertEq(settlement.filled(_hashOrder(counter)), BTC_IN, "counter order: filled[hash] written");
        vm.revertToState(snap);

        Order memory once = _order(maker, 513, WRBTC, BTC_IN, USDT0, BTC_OWED, true);
        once.timing |= fillOnce;
        _fill("POOL direct exact-out 1 hop, FILL-ONCE, 2nd nonce of the word", once, _sig(once, makerPk), BTC_IN, p, _np());
        assertTrue(settlement.isNonceCancelled(maker, 513), "fill-once: the nonce is the record");
        assertEq(settlement.filled(_hashOrder(once)), 0, "fill-once: filled[hash] never written");
        assertEq(IERC20(USDT0).balanceOf(maker), 1 + 2 * BTC_OWED, "maker paid exactly, twice");
    }

    /// @dev A fill-once order refuses a partial outright (`FillOnceMustBeFull`): the
    ///      beta filler skips one it cannot take whole instead of sending this revert.
    function test_fillOnce_partialReverts() public {
        Order memory o = _order(maker, 514, WRBTC, BTC_IN, USDT0, BTC_OWED, true);
        o.timing |= uint256(1) << 100;
        RoutePlan memory p = _plan(POOL_ROUTE, _poolData(BTC_IN / 2, BTC_OWED / 2, _btcPath(0)), 0);
        bytes memory sig = _sig(o, makerPk);
        vm.expectRevert(bytes4(keccak256("FillOnceMustBeFull()")));
        agg.executeFill(o, sig, BTC_IN / 2, p, "", _np());
    }

    function test_single_direct_exactOut_pool_sushiVenue() public {
        Order memory o = _order(maker, 1, WRBTC, BTC_IN, USDT0, BTC_OWED, true);
        RoutePlan memory p = _plan(POOL_ROUTE, _poolData(BTC_IN, BTC_OWED, _btcPath(1)), 0);
        uint256 sushiBefore = IERC20(WRBTC).balanceOf(SUSHI_WRBTC_USDT0_3000);
        _fill("POOL direct exact-out 1 hop, SushiSwap v3 venue", o, _sig(o, makerPk), BTC_IN, p, _np());
        assertEq(IERC20(USDT0).balanceOf(maker), 1 + BTC_OWED, "maker paid via Sushi v3");
        assertGt(IERC20(WRBTC).balanceOf(SUSHI_WRBTC_USDT0_3000), sushiBefore, "the Sushi pool was paid");
    }

    function test_single_pull_exactIn_sandbox() public {
        Order memory o = _order(maker, 1, WRBTC, BTC_IN, USDT0, BTC_OWED, false);
        RoutePlan memory p = _plan(
            SWAP_ROUTER_02,
            abi.encodeCall(
                IRouter02.exactInputSingle,
                (IRouter02.ExactInputSingleParams(WRBTC, USDT0, 3000, address(agg), BTC_IN, BTC_OWED, 0))
            ),
            BTC_OWED
        );
        _fill("SANDBOX pull exact-in 1 hop", o, _sig(o, makerPk), BTC_IN, p, _np());
        assertEq(IERC20(USDT0).balanceOf(maker), 1 + BTC_OWED, "maker paid");
        _sandboxEmpty();
    }

    function test_single_pull_exactIn_pool() public {
        Order memory o = _order(maker, 1, WRBTC, BTC_IN, USDT0, BTC_OWED, false);
        RoutePlan memory p = _plan(POOL_ROUTE, _poolData(BTC_IN, 0, _btcPath(0)), BTC_OWED);
        _fill("POOL pull exact-in 1 hop", o, _sig(o, makerPk), BTC_IN, p, _np());
        assertEq(IERC20(USDT0).balanceOf(maker), 1 + BTC_OWED, "maker paid");
        assertGt(IERC20(USDT0).balanceOf(TREASURY), 1, "USDT0 spread to the treasury");
        assertEq(IERC20(USDT0).allowance(address(agg), address(settlement)), 0, "no allowance survives");
    }

    // ═══════════════ two hops USDRIF → USDT0 → WRBTC ═══════════════

    function test_2hop_direct_exactOut_sandbox() public {
        Order memory o = _order(maker, 1, USDRIF, RIF_IN, WRBTC, RIF_OWED, true);
        RoutePlan memory p = _plan(
            SWAP_ROUTER_02,
            abi.encodeCall(IRouter02.exactOutput, (IRouter02.ExactOutputParams(_routerPath2Reversed(), maker, RIF_OWED, RIF_IN))),
            0
        );
        uint256 before = MAKER_WRBTC; // never read in the measured tx: it would warm the slot
        _fill("SANDBOX direct exact-out 2 hops", o, _sig(o, makerPk), RIF_IN, p, _np());
        assertEq(IERC20(WRBTC).balanceOf(maker) - before, RIF_OWED, "maker paid exactly");
        _sandboxEmpty();
    }

    function test_2hop_direct_exactOut_pool() public {
        Order memory o = _order(maker, 1, USDRIF, RIF_IN, WRBTC, RIF_OWED, true);
        RoutePlan memory p = _plan(POOL_ROUTE, _poolData(RIF_IN, RIF_OWED, _rifPath()), 0);
        uint256 before = MAKER_WRBTC; // never read in the measured tx: it would warm the slot
        _fill("POOL direct exact-out 2 hops (recursive callback)", o, _sig(o, makerPk), RIF_IN, p, _np());
        assertEq(IERC20(WRBTC).balanceOf(maker) - before, RIF_OWED, "maker paid exactly");
        assertEq(IERC20(USDT0).balanceOf(address(agg)), 1, "the intermediate never landed here");
        assertGt(IERC20(USDRIF).balanceOf(TREASURY), 1, "USDRIF residue = the spread");
    }

    function test_2hop_pull_exactIn_sandbox() public {
        Order memory o = _order(maker, 1, USDRIF, RIF_IN, WRBTC, RIF_OWED, false);
        RoutePlan memory p = _plan(
            SWAP_ROUTER_02,
            abi.encodeCall(IRouter02.exactInput, (IRouter02.ExactInputParams(_routerPath2(), address(agg), RIF_IN, RIF_OWED))),
            RIF_OWED
        );
        uint256 before = MAKER_WRBTC; // never read in the measured tx: it would warm the slot
        _fill("SANDBOX pull exact-in 2 hops", o, _sig(o, makerPk), RIF_IN, p, _np());
        assertEq(IERC20(WRBTC).balanceOf(maker) - before, RIF_OWED, "maker paid");
        _sandboxEmpty();
    }

    function test_2hop_pull_exactIn_pool() public {
        Order memory o = _order(maker, 1, USDRIF, RIF_IN, WRBTC, RIF_OWED, false);
        RoutePlan memory p = _plan(POOL_ROUTE, _poolData(RIF_IN, 0, _rifPath()), RIF_OWED);
        uint256 before = MAKER_WRBTC; // never read in the measured tx: it would warm the slot
        _fill("POOL pull exact-in 2 hops", o, _sig(o, makerPk), RIF_IN, p, _np());
        assertEq(IERC20(WRBTC).balanceOf(maker) - before, RIF_OWED, "maker paid");
        assertEq(IERC20(USDT0).balanceOf(address(agg)), 1, "the intermediate is consumed in full");
    }

    // ═══════════════ three hops, mixed venues, USDRIF → USDT0 → WRBTC → RIF ═══════════════

    function test_raw_exactInput_3hop() public {
        bytes memory cd =
            abi.encodeCall(IRouter02.exactInput, (IRouter02.ExactInputParams(_routerPath3(), trader, RIF_IN, RIF3_OWED)));
        vm.prank(trader, trader);
        uint256 g0 = gasleft();
        (bool ok,) = SWAP_ROUTER_02.call(cd);
        uint256 used = g0 - gasleft();
        assertTrue(ok);
        _report("RAW SwapRouter02 exactInput 3-hop USDRIF->USDT0->WRBTC->RIF (Oku)", used, cd);
    }

    function test_3hop_direct_exactOut_pool_mixed() public {
        Order memory o = _order(maker, 1, USDRIF, RIF_IN, RIF, RIF3_OWED, true);
        RoutePlan memory p = _plan(POOL_ROUTE, _poolData(RIF_IN, RIF3_OWED, _mixedPath3()), 0);
        uint256 before = 1; // the 1 wei dealt in setUp (reading it here would warm the slot)
        _fill("POOL direct exact-out 3 hops, mixed venues", o, _sig(o, makerPk), RIF_IN, p, _np());
        assertEq(IERC20(RIF).balanceOf(maker) - before, RIF3_OWED, "maker paid exactly");
        assertEq(IERC20(USDT0).balanceOf(address(agg)), 1, "intermediate USDT0 never landed here");
        assertEq(IERC20(WRBTC).balanceOf(address(agg)), 1, "intermediate WRBTC never landed here");
    }

    function test_3hop_pull_exactIn_pool_mixed() public {
        Order memory o = _order(maker, 1, USDRIF, RIF_IN, RIF, RIF3_OWED, false);
        RoutePlan memory p = _plan(POOL_ROUTE, _poolData(RIF_IN, 0, _mixedPath3()), RIF3_OWED);
        uint256 before = 1; // the 1 wei dealt in setUp (reading it here would warm the slot)
        _fill("POOL pull exact-in 3 hops, mixed venues", o, _sig(o, makerPk), RIF_IN, p, _np());
        assertEq(IERC20(RIF).balanceOf(maker) - before, RIF3_OWED, "maker paid");
        assertGe(IERC20(USDT0).balanceOf(address(agg)), 1, "intermediate floor kept");
        assertGe(IERC20(WRBTC).balanceOf(address(agg)), 1, "intermediate floor kept");
    }

    function test_3hop_pull_exactIn_pool_oku() public {
        Order memory o = _order(maker, 1, USDRIF, RIF_IN, RIF, RIF3_OWED, false);
        RoutePlan memory p = _plan(POOL_ROUTE, _poolData(RIF_IN, 0, _okuPath3()), RIF3_OWED);
        _fill("POOL pull exact-in 3 hops, Oku only", o, _sig(o, makerPk), RIF_IN, p, _np());
    }

    // ═══════════════ retain mode (profitRecipient = the solver) ═══════════════

    function test_retain_single_direct_exactOut_pool() public {
        Order memory o = _order(maker, 1, WRBTC, BTC_IN, USDT0, BTC_OWED, true);
        RoutePlan memory p = _plan(POOL_ROUTE, _poolData(BTC_IN, BTC_OWED, _btcPath(0)), 0);
        p.profitRecipient = address(agg);
        _fill("RETAIN POOL direct exact-out 1 hop", o, _sig(o, makerPk), BTC_IN, p, _np());
        assertEq(IERC20(USDT0).balanceOf(maker), 1 + BTC_OWED, "maker paid exactly");
    }

    function test_retain_single_pull_exactIn_pool() public {
        Order memory o = _order(maker, 1, WRBTC, BTC_IN, USDT0, BTC_OWED, false);
        RoutePlan memory p = _plan(POOL_ROUTE, _poolData(BTC_IN, 0, _btcPath(0)), BTC_OWED);
        p.profitRecipient = address(agg);
        _fill("RETAIN POOL pull exact-in 1 hop", o, _sig(o, makerPk), BTC_IN, p, _np());
        assertEq(IERC20(USDT0).balanceOf(maker), 1 + BTC_OWED, "maker paid");
    }

    function test_retain_2hop_direct_exactOut_pool() public {
        Order memory o = _order(maker, 1, USDRIF, RIF_IN, WRBTC, RIF_OWED, true);
        RoutePlan memory p = _plan(POOL_ROUTE, _poolData(RIF_IN, RIF_OWED, _rifPath()), 0);
        p.profitRecipient = address(agg);
        _fill("RETAIN POOL direct exact-out 2 hops", o, _sig(o, makerPk), RIF_IN, p, _np());
    }

    function test_retain_2hop_pull_exactIn_pool() public {
        Order memory o = _order(maker, 1, USDRIF, RIF_IN, WRBTC, RIF_OWED, false);
        RoutePlan memory p = _plan(POOL_ROUTE, _poolData(RIF_IN, 0, _rifPath()), RIF_OWED);
        p.profitRecipient = address(agg);
        _fill("RETAIN POOL pull exact-in 2 hops", o, _sig(o, makerPk), RIF_IN, p, _np());
    }

    // ═══════════════ ERC-2612 permit overhead (USD₮0 → WRBTC, pool direct) ═══════════════

    function test_permit_baseline_permit3Funded() public {
        (Order memory o, RoutePlan memory p) = _usdtOrder(m3);
        _fill("PERMIT baseline: maker funded by a Permit3 grant", o, _sig(o, M3_PK), USDT_IN, p, _np());
        assertEq(IERC20(WRBTC).balanceOf(m3), 1 + USDT_OWED);
    }

    function test_permit_baseline_directApproval() public {
        (Order memory o, RoutePlan memory p) = _usdtOrder(m4);
        _fill("PERMIT baseline: maker approved Settlement directly", o, _sig(o, M4_PK), USDT_IN, p, _np());
        assertEq(IERC20(WRBTC).balanceOf(m4), 1 + USDT_OWED);
    }

    function test_permit_inFill() public {
        (Order memory o, RoutePlan memory p) = _usdtOrder(m2);
        Permit2612[] memory ps = new Permit2612[](1);
        ps[0] = storedPermit;
        _fill("PERMIT in executeFill (USD0 permit to Settlement + fill, ONE tx)", o, _sig(o, M2_PK), USDT_IN, p, ps);
        assertEq(IERC20(WRBTC).balanceOf(m2), 1 + USDT_OWED, "filled on the permit");
        assertEq(IERC20(USDT0).allowance(m2, address(settlement)), 0, "allowance used up exactly");
        assertEq(IErc2612(USDT0).nonces(m2), 1, "the permit landed");
    }

    /// @dev The relay design this replaces: the permit as its OWN transaction.
    function test_permit_standaloneRelayTx() public {
        Permit2612 memory pm = storedPermit;
        bytes memory cd =
            abi.encodeCall(IErc2612.permit, (m2, address(settlement), pm.value, pm.deadline, pm.v, pm.r, pm.s));
        vm.prank(address(0xF00D), address(0xF00D));
        uint256 g0 = gasleft();
        (bool ok,) = USDT0.call(cd);
        uint256 used = g0 - gasleft();
        assertTrue(ok);
        _report("PERMIT as a standalone relay tx (the replaced design)", used, cd);
    }
}

/// @title PoolRouteForkRelayedBench
/// @notice The permit was relayed BEFORE the fill transaction (it is public — a
///         front-runner, or the maker's own wallet): our `permit` call reverts on the
///         spent nonce, the allowance it already created covers `value`, and the fill
///         goes through. Relayed in `setUp`, so the measured fill sees the allowance as
///         a live slot exactly as it would on chain.
contract PoolRouteForkRelayedBench is PoolRouteForkHarness {
    function setUp() public override {
        super.setUp();
        Permit2612 memory pm = storedPermit;
        vm.prank(address(0xF00D));
        IErc2612(USDT0).permit(m2, address(settlement), pm.value, pm.deadline, pm.v, pm.r, pm.s);
    }

    function test_permit_relayedFirst() public {
        (Order memory o, RoutePlan memory p) = _usdtOrder(m2);
        Permit2612[] memory ps = new Permit2612[](1);
        ps[0] = storedPermit;
        _fill("PERMIT in executeFill, already relayed (failed call + allowance read)", o, _sig(o, M2_PK), USDT_IN, p, ps);
        assertEq(IERC20(WRBTC).balanceOf(m2), 1 + USDT_OWED, "filled on the relayed allowance");
        assertEq(IERC20(USDT0).allowance(m2, address(settlement)), 0, "allowance used up exactly");
    }

    /// @dev The same order WITHOUT the permit: the filler's cheaper choice once it sees
    ///      the nonce spent and the allowance in place.
    function test_permit_relayedFirst_omitted() public {
        (Order memory o, RoutePlan memory p) = _usdtOrder(m2);
        _fill("PERMIT already relayed, omitted from executeFill", o, _sig(o, M2_PK), USDT_IN, p, _np());
        assertEq(IERC20(WRBTC).balanceOf(m2), 1 + USDT_OWED);
    }
}

/// @title PoolRouteForkColdIntermediateBench
/// @notice The solver holds NO floor of the INTERMEDIATE token (USDT0 on the 2-hop
///         USDRIF → USDT0 → WRBTC path, USDT0 + WRBTC on the 3-hop): what an
///         exact-input multi-hop route costs before (and, with the intermediate 1-wei
///         floor, after) the intermediate slot is seeded. Two fills in two fresh
///         transactions are not expressible in one test, so the "after" figure is
///         the steady-state {PoolRouteForkBench} one.
contract PoolRouteForkColdIntermediateBench is PoolRouteForkHarness {
    function _noFloor(address t) internal pure override returns (bool) {
        return t == USDT0;
    }

    function test_cold_2hop_pull_exactIn_pool() public {
        Order memory o = _order(maker, 1, USDRIF, RIF_IN, WRBTC, RIF_OWED, false);
        RoutePlan memory p = _plan(POOL_ROUTE, _poolData(RIF_IN, 0, _rifPath()), RIF_OWED);
        _fill("COLD-INTERMEDIATE POOL pull exact-in 2 hops (no USDT0 floor)", o, _sig(o, makerPk), RIF_IN, p, _np());
        emit log_named_uint("solver USDT0 after", IERC20(USDT0).balanceOf(address(agg)));
    }

}

/// @notice {PoolRouteForkColdIntermediateBench} for the 3-hop path: neither USDT0 nor
///         WRBTC (both intermediates) has a floor on the solver.
contract PoolRouteForkColdIntermediate3Bench is PoolRouteForkHarness {
    function _noFloor(address t) internal pure override returns (bool) {
        return t == USDT0 || t == WRBTC;
    }

    function test_cold_3hop_pull_exactIn_pool_mixed() public {
        Order memory o = _order(maker, 1, USDRIF, RIF_IN, RIF, RIF3_OWED, false);
        RoutePlan memory p = _plan(POOL_ROUTE, _poolData(RIF_IN, 0, _mixedPath3()), RIF3_OWED);
        _fill("COLD-INTERMEDIATE POOL pull exact-in 3 hops (no USDT0/WRBTC floor)", o, _sig(o, makerPk), RIF_IN, p, _np());
    }
}
