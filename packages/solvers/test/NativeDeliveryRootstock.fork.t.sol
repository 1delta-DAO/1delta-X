// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {Order, LegIn, LegOut, Settlement} from "@core/settlement/Settlement.sol";
import {
    AggregatorFillSolver,
    RoutePlan,
    SurplusPolicy,
    PoolVenue,
    Permit2612,
    NO_PATCH,
    POOL_ROUTE
} from "@solvers/aggregator/AggregatorFillSolver.sol";
import {NativeBalance} from "@periphery/NativeBalance.sol";

import {newAggNative} from "./shared/AggDeploy.sol";

interface ILensHashOrder {
    function hashOrder(Order calldata order) external pure returns (bytes32);
}

/// @title NativeDeliveryRootstockForkTest
/// @notice Task 30 acceptance against the LIVE Rootstock beta Settlement (deployed
///         2026-10-09, unchanged — native delivery needs no Settlement change): a DIRECT
///         USD₮0 → RBTC market order whose output leg is the {NativeBalance} view, filled
///         by a solver v3 instance with ZERO capital through the live Oku WRBTC/USD₮0
///         pool; the route ends in WRBTC paid to the solver, which unwraps the priced
///         amount and sends raw RBTC. Compared with the same order taking WRBTC.
///
///      Opt-in: `RSK_FORK_URL=https://public-node.rsk.co FOUNDRY_PROFILE=solvers forge test
///      --match-path '*NativeDeliveryRootstock*' -vv`. Skipped without RSK_FORK_URL.
contract NativeDeliveryRootstockForkTest is Test {
    Settlement constant SETTLEMENT = Settlement(payable(0xe6EDbb5c49Fb4CFb313476e3B78E274D3584ddf5));
    ILensHashOrder constant LENS = ILensHashOrder(0xF9e905EdCC376FDaBF62Ca0966624611721C5206);
    address constant WRBTC = 0x542fDA317318eBF1d3DEAf76E0b632741A7e677d;
    address constant USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
    address constant OKU_FACTORY = 0xaF37EC98A00FD63689CF3060BF3B6784E00caD82;
    bytes32 constant V3_INIT_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
    address constant POOL = 0xaeF6fABf3b0C9e5F9d6D5170AfC703A633479Bbd; // Oku WRBTC/USD₮0 0.3 %
    address constant TREASURY = address(0x7EA5);

    uint256 constant USDT_IN = 50e6;
    uint256 constant RBTC_OUT = 2e14; // 0.0002 RBTC — fills while BTC < ~$250k

    uint256 makerPk = 0xA11CE;
    address maker;
    NativeBalance nb;
    AggregatorFillSolver agg;
    bool live;

    function setUp() public {
        string memory url = vm.envOr("RSK_FORK_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        live = true;
        maker = vm.addr(makerPk);
        nb = new NativeBalance();
        address[] memory ops = new address[](1);
        ops[0] = address(this);
        PoolVenue[] memory venues = new PoolVenue[](1);
        venues[0] = PoolVenue({factory: OKU_FACTORY, initCodeHash: V3_INIT_HASH});
        agg = newAggNative(
            address(SETTLEMENT),
            ops,
            SurplusPolicy({makerPpm: 0, protocolPpm: 0, protocolRecipient: address(0)}),
            venues,
            address(nb),
            WRBTC
        );
        vm.prank(POOL);
        IERC20(USDT0).transfer(maker, 200e6);
        vm.prank(maker);
        IERC20(USDT0).approve(address(SETTLEMENT), type(uint256).max); // the app's direct approval
        // Steady state: the maker has held both before; the treasury has a USD₮0 balance.
        vm.deal(maker, 1);
        vm.prank(POOL);
        IERC20(WRBTC).transfer(maker, 1);
        vm.prank(POOL);
        IERC20(USDT0).transfer(TREASURY, 1);
        // The solver's 1-wei balance floors (what its first fills self-seed, or the
        // deploy script's FLOOR_TOKENS): without the WRBTC one, a native fill writes the
        // solver's WRBTC slot 0 → x → 0 — ~+17k of execution gas that the end-of-tx
        // refund returns, so a same-tx `gasleft` figure would overstate it.
        if (vm.envOr("NATIVE_FORK_FLOORS", true)) {
            vm.startPrank(POOL);
            IERC20(WRBTC).transfer(address(agg), 1);
            IERC20(USDT0).transfer(address(agg), 1);
            vm.stopPrank();
        }
    }

    function _order(uint256 nonce, address outToken) internal view returns (Order memory o) {
        LegIn[] memory li = new LegIn[](1);
        li[0] = LegIn(USDT0, USDT_IN, 0);
        LegOut[] memory lo = new LegOut[](1);
        lo[0] = LegOut(outToken, RBTC_OUT, 0, address(0));
        o = Order({
            params: 0,
            pricingModule: address(0),
            maker: maker,
            nonce: nonce,
            legsIn: PackedEncode.legsIn(li),
            legsOut: PackedEncode.legsOut(lo),
            timing: (uint256(uint48(block.timestamp + 1 hours)) << 160) | (uint256(1) << 104), // DIRECT
            exclusiveFiller: address(agg),
            minFillAnchor: 0,
            curve: PackedEncode.noCurve(),
            items: PackedEncode.noItems(),
            validators: PackedEncode.noValidators(),
            invariants: PackedEncode.noValidators(),
            fillModule: address(0),
            fillTotal: 0
        });
    }

    function _sign(Order memory o) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", SETTLEMENT.DOMAIN_SEPARATOR(), LENS.hashOrder(o)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev One-hop exact-output pool route USD₮0 → WRBTC, output word patched with the
    ///      live priced amount (offset 32), input = the routed delta (offset 0).
    function _plan() internal pure returns (RoutePlan memory) {
        return RoutePlan({
            router: POOL_ROUTE,
            minOut: 0,
            maxPay: 0,
            amountInOffset: 0,
            amountOutOffset: 32,
            minBumpBps: 0,
            profitRecipient: TREASURY,
            originator: address(0),
            originatorPpm: 0,
            data: abi.encodePacked(USDT_IN, uint256(1), USDT0, uint24(3000), uint8(0), WRBTC)
        });
    }

    function _fill(Order memory o) internal returns (uint256 gasUsed) {
        bytes memory sig = _sign(o);
        RoutePlan memory p = _plan();
        uint256 g0 = gasleft();
        agg.executeFill(o, sig, USDT_IN, p, "", new Permit2612[](0));
        gasUsed = g0 - gasleft();
    }

    function test_fork_liveSettlement_directUsdt0ToRawRbtc() public {
        if (!live) return vm.skip(true);
        uint256 before = maker.balance;
        uint256 g = _fill(_order(101, address(nb)));
        emit log_named_uint("native direct fill gas (unit, same tx)", g);
        assertEq(maker.balance - before, RBTC_OUT, "raw RBTC in the maker's wallet, exactly the priced amount");
        assertLe(IERC20(WRBTC).balanceOf(address(agg)), 1, "no WRBTC left beyond the floor: the route produced exactly the leg");
        assertEq(address(agg).balance, 0, "the solver keeps no RBTC");
        assertGt(IERC20(USDT0).balanceOf(TREASURY), 1, "the spread, as USD0 input residue");
        assertLe(IERC20(USDT0).balanceOf(address(agg)), 1, "zero capital: at most the 1-wei floor");
    }

    /// The same shape taking WRBTC (the plain direct fill), for the gas comparison —
    /// each measured from the SAME state (snapshot / revert), so neither warms the other.
    function test_fork_gasDelta_nativeVsWrapped() public {
        if (!live) return vm.skip(true);
        uint256 snap = vm.snapshotState();
        uint256 gW = _fill(_order(102, WRBTC));
        vm.revertToState(snap);
        uint256 gN = _fill(_order(103, address(nb)));
        emit log_named_uint("direct fill, WRBTC out                  ", gW);
        emit log_named_uint("direct fill, RBTC out via NativeBalance ", gN);
        emit log_named_int("native - wrapped", int256(gN) - int256(gW));
        // MEASURED 2026-10-14 (live state, via-IR deployed bytecode, solver floors seeded):
        // +27.0k EXECUTION gas — the WRBTC `withdraw` (its value transfer to the solver),
        // the value `call` to the maker, the cold `NativeBalance` account the core reads,
        // the solver's WRBTC slot written up and back, one `balanceOf`. ~2.8k of it (the
        // slot restore) is refunded at the end of the transaction, which `gasleft` here
        // cannot see: ~24k net, the plan's "~20–25k". Bound at 30k execution.
        assertLt(gN, gW + 30_000, "native delivery within ~30k execution (~25k net) of a plain direct fill");
    }
}
