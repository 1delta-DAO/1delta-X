// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {console} from "forge-std/console.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, ItemPolicy, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";
import {MatchRaceGuard} from "@solvers/base/MatchRaceGuard.sol";
import {
    MatchFlashSolver,
    FlashKind,
    FlashSource,
    FlashMatch,
    FlashProviders,
    PoolSwap,
    RaceCheck,
    V3Venue
} from "@solvers/match/MatchFlashSolver.sol";

import {UsdrifForkBase} from "../../modules/redeem/usdrif/test/shared/UsdrifForkBase.t.sol";
import {MockLeverLender} from "./shared/FlashMatchMocks.sol";

interface IV3FactoryView {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

/// @title MatchFlashRootstockFork
/// @notice {MatchFlashSolver} against the LIVE Rootstock v3 pools (block 9,295,925, the
///         {PoolRouteFork} pin): the only flash source on the beta chain. A leverage open
///         at the edge (USD₮0 debt → WRBTC collateral, one pre-funded ORDERED TAKE_FOR on a
///         mock lender — Rootstock has no lending module in the tree) is filled with zero
///         filler capital twice:
///           • `flash()` WRBTC from the SushiSwap v3 WRBTC/USD₮0 0.3% pool (venue 1),
///             repay by swapping the borrowed USD₮0 on the Oku 0.3% pool (venue 0);
///           • a FLASH SWAP on the Oku pool alone (one pool, no flash fee).
///         Real `flash()` fee accounting, real pool locks, real CREATE2 derivation.
contract MatchFlashRootstockFork is UsdrifForkBase {
    address internal constant WRBTC = 0x542fDA317318eBF1d3DEAf76E0b632741A7e677d;
    address internal constant OKU_FACTORY = 0xaF37EC98A00FD63689CF3060BF3B6784E00caD82;
    address internal constant SUSHI_V3_FACTORY = 0x46B3fDF7b5CDe91Ac049936bF0bDb12c5d22202e;
    bytes32 internal constant V3_INIT_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
    address internal constant OKU_WRBTC_USDT0_3000 = 0xaeF6fABf3b0C9e5F9d6D5170AfC703A633479Bbd;
    address internal constant SUSHI_WRBTC_USDT0_3000 = 0x6d778c369cB386D50f4Ee676c5c264374C52Fd71;

    uint256 internal constant D_IN = 100e6; //       100 USD₮0 of new debt
    uint256 internal constant C_OUT = 0.001e18; //   for 0.001 WRBTC (market ~0.00117 at the pin)
    uint256 internal constant SEED_C = 0.0006e18; // existing collateral: max borrow 38.4 < 100

    address internal operator = address(0x0B0B);
    address internal treasury = address(0x7EA5);
    MockLeverLender internal lender;
    MatchFlashSolver internal fs;

    function _forkBlock() internal pure override returns (uint256) {
        return 9_295_925;
    }

    function setUp() public override {
        super.setUp();
        // Oracle 80,000 USD₮0 per BTC (USD₮0 has 6 decimals), LTV 80 %.
        lender = new MockLeverLender(address(permit3), address(settlement), WRBTC, USDT0, 80_000e6, 1e18);
        deal(USDT0, address(lender), 1_000_000e6);
        lender.book(USDT0);
        deal(WRBTC, address(lender), SEED_C);
        lender.book(WRBTC);
        lender.seed(maker, SEED_C, 0);

        V3Venue[] memory v = new V3Venue[](2);
        v[0] = V3Venue({factory: OKU_FACTORY, initCodeHash: V3_INIT_HASH});
        v[1] = V3Venue({factory: SUSHI_V3_FACTORY, initCodeHash: V3_INIT_HASH});
        address[] memory ops = new address[](1);
        ops[0] = operator;
        fs = new MatchFlashSolver(address(settlement), ops, v, FlashProviders(address(0), address(0), address(0)));
    }

    function _preFund(uint256 j, address token) internal pure returns (uint256) {
        return (uint256(5) << 253) | (uint256(uint160(token)) << 16) | j;
    }

    function _openOrder() internal returns (Order memory o) {
        bytes memory data = abi.encode(_preFund(0, WRBTC), uint256(0));
        Item[] memory its = new Item[](1);
        its[0] = Item({op: ItemOp.TAKE_FOR, module: address(lender), amount: D_IN, recipient: address(0), data: data});
        o = Order({
            params: 0,
            pricingModule: address(0),
            maker: maker,
            nonce: 1,
            legsIn: PackedEncode.oneLegIn(USDT0, D_IN, 0),
            legsOut: PackedEncode.oneLegOut(WRBTC, C_OUT, 0, address(lender)),
            timing: ItemPolicy.pack(_expiryBits(block.timestamp + 1 hours), ItemPolicy.ORDERED),
            exclusiveFiller: address(0),
            minFillAnchor: 0,
            curve: PackedEncode.noCurve(),
            items: PackedEncode.items(its),
            validators: PackedEncode.noValidators(),
            invariants: PackedEncode.noValidators(),
            fillModule: address(0),
            fillTotal: 0
        });
        vm.prank(maker);
        permit3.approveTaker(
            address(settlement), address(lender), keccak256(data), uint160(D_IN), uint48(block.timestamp + 1 hours)
        );
    }

    function _plan(Order memory o) internal view returns (MatchPlan memory p) {
        Order[] memory orders = new Order[](1);
        orders[0] = o;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(o);
        uint256[] memory fills = new uint256[](1);
        fills[0] = D_IN;
        uint256[] memory s = new uint256[](3);
        s[0] = MatchStep.pack(MatchStep.CALL, 0, 0);
        s[1] = MatchStep.pack(MatchStep.DELIVER, 0, 0);
        s[2] = MatchStep.pack(MatchStep.ITEM, 0, 0);
        address[] memory targets = new address[](1);
        targets[0] = address(fs);
        address[] memory t = new address[](1);
        t[0] = WRBTC;
        uint256[] memory a = new uint256[](1);
        a[0] = type(uint256).max;
        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodeCall(MatchFlashSolver.onMatchStep, (new PoolSwap[](0), t, a));
        p = MatchPlan({
            orders: orders,
            sigs: sigs,
            fillAmounts: fills,
            takerDatas: new bytes[](0),
            schedule: s,
            callTargets: targets,
            callDatas: datas,
            profitRecipient: address(0)
        });
    }

    function _job(FlashKind kind, uint8 venue, PoolSwap[] memory swaps) internal view returns (FlashMatch memory j) {
        j.flash = FlashSource({
            kind: kind,
            token: WRBTC,
            amount: C_OUT,
            pairToken: USDT0,
            fee: 3000,
            venue: venue,
            vault: address(0),
            maxRepay: 0
        });
        j.swaps = swaps;
        j.recipient = treasury;
        j.extraSweep = new address[](0);
        j.minProfit = new MatchRaceGuard.SweptFloor[](0);
    }

    function _guard(Order memory o) internal pure returns (RaceCheck memory g) {
        g.orderHashes = new bytes32[](1);
        g.orderHashes[0] = _hashOrder(o);
        g.expectedFilled = new uint256[](1);
        g.nonceMakers = new address[](0);
        g.nonces = new uint256[](0);
    }

    function _assertOpenedAndClean() internal view {
        assertEq(lender.collateral(maker), SEED_C + C_OUT, "collateral deposited");
        assertEq(lender.debt(maker), D_IN, "debt opened");
        assertEq(IERC20(WRBTC).balanceOf(address(fs)), 0, "solver holds no WRBTC");
        assertEq(IERC20(USDT0).balanceOf(address(fs)), 0, "solver holds no USDT0");
        assertEq(IERC20(WRBTC).balanceOf(address(settlement)), 0, "pool flat (WRBTC)");
        assertEq(IERC20(USDT0).balanceOf(address(settlement)), 0, "pool flat (USDT0)");
        assertEq(IERC20(WRBTC).allowance(address(fs), OKU_WRBTC_USDT0_3000), 0);
        assertEq(IERC20(USDT0).allowance(address(fs), OKU_WRBTC_USDT0_3000), 0);
        assertEq(IERC20(WRBTC).allowance(address(fs), SUSHI_WRBTC_USDT0_3000), 0);
        assertEq(IERC20(USDT0).allowance(address(fs), SUSHI_WRBTC_USDT0_3000), 0);
    }

    function test_fork_venuesDeriveTheLivePools() public view {
        assertEq(fs.poolFor(0, WRBTC, USDT0, 3000), OKU_WRBTC_USDT0_3000);
        assertEq(fs.poolFor(1, USDT0, WRBTC, 3000), SUSHI_WRBTC_USDT0_3000);
        assertEq(fs.poolFor(0, WRBTC, USDT0, 3000), IV3FactoryView(OKU_FACTORY).getPool(WRBTC, USDT0, 3000));
    }

    /// `flash()` on Sushi, repay-swap on Oku.
    function test_fork_leverageOpen_sushiFlash_okuSwap() public {
        Order memory o = _openOrder();
        PoolSwap[] memory sw = new PoolSwap[](1);
        sw[0] = PoolSwap({path: abi.encodePacked(USDT0, uint24(3000), uint8(0), WRBTC), amountIn: 0, minOut: 0});
        FlashMatch memory j = _job(FlashKind.UNI_V3_FLASH, 1, sw);
        RaceCheck memory g = _guard(o);
        MatchPlan memory p = _plan(o);
        uint256 sushiBefore = IERC20(WRBTC).balanceOf(SUSHI_WRBTC_USDT0_3000);

        vm.prank(operator);
        uint256 g0 = gasleft();
        (, uint256[] memory profit) = fs.executeMatch(g, j, p);
        console.log("executeMatch gas (v3 flash + 1 swap):", g0 - gasleft());

        _assertOpenedAndClean();
        uint256 fee = (C_OUT * 3000 + 1e6 - 1) / 1e6;
        assertEq(IERC20(WRBTC).balanceOf(SUSHI_WRBTC_USDT0_3000), sushiBefore + fee, "flash repaid + fee");
        assertGt(IERC20(WRBTC).balanceOf(treasury), 0, "positive spread in WRBTC");
        assertEq(profit[0], IERC20(WRBTC).balanceOf(treasury));
        console.log("WRBTC spread (wei):", profit[0]);
    }

    /// A flash swap on the Oku pool alone.
    function test_fork_leverageOpen_okuFlashSwap() public {
        Order memory o = _openOrder();
        FlashMatch memory j = _job(FlashKind.UNI_V3_SWAP, 0, new PoolSwap[](0));
        RaceCheck memory g = _guard(o);
        MatchPlan memory p = _plan(o);

        vm.prank(operator);
        uint256 g0 = gasleft();
        fs.executeMatch(g, j, p);
        console.log("executeMatch gas (v3 flash swap):", g0 - gasleft());

        _assertOpenedAndClean();
        uint256 spread = IERC20(USDT0).balanceOf(treasury);
        assertGt(spread, 0, "positive spread in USDT0");
        console.log("USDT0 spread:", spread);
    }

    /// The Oku pool cannot be both the flash and the repayment swap (`LOK`).
    function test_fork_flashAndSwapSamePool_reverts() public {
        Order memory o = _openOrder();
        PoolSwap[] memory sw = new PoolSwap[](1);
        sw[0] = PoolSwap({path: abi.encodePacked(USDT0, uint24(3000), uint8(0), WRBTC), amountIn: 0, minOut: 0});
        FlashMatch memory j = _job(FlashKind.UNI_V3_FLASH, 0, sw);
        RaceCheck memory g = _guard(o);
        MatchPlan memory p = _plan(o);
        vm.prank(operator);
        vm.expectRevert(bytes("LOK"));
        fs.executeMatch(g, j, p);
    }
}
