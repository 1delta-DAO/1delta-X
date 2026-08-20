// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/console2.sol";
import {Order} from "@core/settlement/Settlement.sol";
import {DutchAuction} from "@core/settlement/DutchAuction.sol";
import {MockSettlementBase} from "../shared/MockSettlementBase.t.sol";
import {PackedEncode} from "../shared/PackedEncode.sol";

import {console2 as c2} from "forge-std/console2.sol";

interface IFill3 {
    function fill(Order calldata o, bytes calldata sig, uint256 amt) external returns (uint256[] memory);
}

/// @title CalldataSizeBench
/// @notice WHAT AN ORDER COSTS ON THE WIRE, and why a "compact" fill entry does not
///         pay for itself.
///
///  A losing priority-auction bid pays its transaction's intrinsic calldata cost in
///  full — the revert happens after the EVM has already charged for every byte. So
///  the wire size of a fill is part of a solver's cost of competing, alongside the
///  execution gas that `PriorityRaceGasBench` measures.
///
///  The headline byte count badly overstates it, which is the point of this bench.
///  An ABI-encoded {Order} is mostly PADDING — zero bytes, priced at 4 gas against a
///  non-zero byte's 16 — so the ~1.25 KB of a plain fill costs far less than its
///  length suggests, and a hand-packed encoding could recover only the padding, not
///  the content.
///
///  It is also not reachable. Every function in the fill path takes `Order calldata`,
///  and a struct's calldata representation IS its ABI encoding — there is no way to
///  hand the pipeline a compressed blob short of decoding into `Order memory` (which
///  would mean a second copy of {Core}/{Pricing}/{Base}, and Settlement has ~160
///  bytes of EIP-170 headroom) or bouncing through a self-call with an explicit
///  filler argument (an authority-forwarding entry point, i.e. the shape of the 2026-08
///  `GenericCallModule` finding). Run this before anyone proposes it again.
contract CalldataSizeBenchTest is MockSettlementBase {
    uint256 constant SELL_IN = 1_000e18;
    uint256 constant OUT_START = 2_000e18;

    function _report(string memory label, bytes memory cd) internal pure {
        uint256 z;
        for (uint256 i; i < cd.length; i++) {
            if (cd[i] == 0) z++;
        }
        uint256 nz = cd.length - z;
        console2.log(label);
        console2.log("  bytes / zero / nonzero  ", cd.length, z, nz);
        console2.log("  intrinsic calldata gas  ", z * 4 + nz * 16);
    }

    function test_bench_calldataSize() public view {
        Order memory o = _plainOrder(1, address(tA), address(tB), SELL_IN, OUT_START);
        o.legsOut = PackedEncode.oneLegOut(address(tB), OUT_START, OUT_START / 2, address(0));
        o.timing = (uint256(1) << 103) | _expiryBits(block.timestamp + 1 hours);
        o.params = DutchAuction.packParams(0, 0, 0, 2 gwei, 1 gwei);
        bytes memory sig = _sign(o);

        _report("fill(Order,bytes,uint256), 1 leg in / 1 leg out", abi.encodeCall(IFill3.fill, (o, sig, SELL_IN)));
        console2.log("  legsIn / legsOut / sig  ", o.legsIn.length, o.legsOut.length, sig.length);

        // The floor a hand-packed encoding could reach: no padding, empty fields
        // omitted behind a presence bitmap, addresses at 20 bytes, amounts as varints.
        // Its NON-ZERO content is the same, so only the padding is recoverable.
        uint256 compact = 4 + 2 + 20 + 8 + 26 + 26 + (2 + o.legsIn.length) + (2 + o.legsOut.length) + 16 + 65;
        console2.log("  hand-packed floor bytes ", compact);
    }

    /// @dev THE OTHER HALF OF THE ANSWER. A compact entry cannot hand the pipeline an
    ///      `Order calldata` — a struct's calldata form IS its ABI encoding — so it
    ///      would have to decode into memory, re-encode, and bounce through the
    ///      existing `onlySelf` {Core.fillSelf} trampoline. {Core.batchFill} already
    ///      does exactly that bounce, so a one-order batch prices it: the delta below
    ///      is what a compact entry would pay back before it saved anything, on top of
    ///      the decode it would still have to write.
    function test_bench_selfCallTrampoline() public {
        // warm the shared state so neither row absorbs the other's cold access
        _fundBoth();
        Order memory w = _plainOrder(90, address(tA), address(tB), SELL_IN, OUT_START);
        bytes memory ws = _sign(w);
        vm.prank(solver);
        settlement.fill(w, ws, SELL_IN);

        _fundBoth();
        Order memory a = _plainOrder(91, address(tA), address(tB), SELL_IN, OUT_START);
        bytes memory sa = _sign(a);
        vm.prank(solver);
        uint256 g = gasleft();
        settlement.fill(a, sa, SELL_IN);
        uint256 direct = g - gasleft();

        _fundBoth();
        Order[] memory os = new Order[](1);
        bytes[] memory ss = new bytes[](1);
        uint256[] memory as_ = new uint256[](1);
        os[0] = _plainOrder(92, address(tA), address(tB), SELL_IN, OUT_START);
        ss[0] = _sign(os[0]);
        as_[0] = SELL_IN;
        vm.prank(solver);
        g = gasleft();
        settlement.batchFill(os, ss, as_, true);
        uint256 bounced = g - gasleft();

        c2.log("direct fill / via self-call / overhead", direct, bounced, bounced - direct);
    }

    function _fundBoth() internal {
        tA.mint(maker, SELL_IN);
        _makerApprove(address(settlement), address(tA), SELL_IN);
        tB.mint(solver, OUT_START);
        _solverApprove(address(settlement), address(tB), OUT_START);
    }
}
