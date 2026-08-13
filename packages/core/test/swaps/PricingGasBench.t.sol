// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/console2.sol";

import {Order} from "@core/settlement/Settlement.sol";
import {DutchAuction} from "@core/settlement/DutchAuction.sol";
import {ChainlinkPeggedPriceModule} from "@core/modules/ChainlinkPeggedPriceModule.sol";
import {CosignedQuotePriceModule} from "@core/modules/CosignedQuotePriceModule.sol";
import {RangePriceModule} from "@core/modules/RangePriceModule.sol";

import {MockSettlementBase} from "../shared/MockSettlementBase.t.sol";
import {PackedEncode} from "../shared/PackedEncode.sol";
import {PriceFeed} from "./PricingModes.t.sol";

/// @title PricingGasBench
/// @notice FILL-ONLY gas for each pricing mode, measured with `gasleft()` around the
///         `fill` call so no setup, deployment or minting is counted. The suite-level
///         numbers in `.gas-snapshot` cannot answer "what does a price module cost
///         per fill?" — they include the module's own deployment.
///
///         Every case fills the SAME order shape (one fixed input leg, one decaying
///         output leg, whole fill) so the only variable is how the bump is resolved.
///         Run with `-vv` to read the table.
contract PricingGasBenchTest is MockSettlementBase {
    uint256 constant SELL_IN = 1_000e18;
    uint256 constant OUT_START = 2_000e18;
    uint256 constant OUT_END = 1_000e18;

    function _fund() internal {
        tA.mint(maker, SELL_IN);
        _makerApprove(address(settlement), address(tA), SELL_IN);
        tB.mint(solver, OUT_START);
        _solverApprove(address(settlement), address(tB), OUT_START);
    }

    function _decayingSell(uint256 nonce) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), SELL_IN, OUT_START);
        o.legsOut = PackedEncode.oneLegOut(address(tB), OUT_START, OUT_END, address(0));
    }

    function _measure(string memory label, Order memory o, bytes memory sig, bytes memory takerData)
        internal
        returns (uint256 used)
    {
        // `sig` is always built by the caller, before this prank — see `_warm`.
        vm.prank(solver);
        uint256 g = gasleft();
        settlement.fill(o, sig, SELL_IN, takerData);
        used = g - gasleft();
        console2.log(label, used);
    }

    /// @dev A discarded fill that WARMS the shared state — the token accounts, the
    ///      maker's allowance slots, the settlement's own storage. Without it the
    ///      first measured case pays ~50k of cold-access gas the others do not, and
    ///      every delta below it reads as a saving. Each measured case still gets a
    ///      fresh (cold) per-order `filled` slot, which is the honest shape.
    function _warm() internal {
        _fund();
        // Nonce 0 shares the bitmap WORD with every measured case (nonces 1..24, and
        // a word holds 256), so the warm-up pays that word's cold SLOAD and no
        // measured case does. Getting this wrong is worth ~2,100 gas and silently
        // reads as "the first mode measured is the expensive one".
        Order memory w = _plainOrder(0, address(tA), address(tB), SELL_IN, OUT_START);
        // Sign BEFORE the prank — `_sign` calls the settlement for its domain
        // separator, which would consume it.
        bytes memory ws = _sign(w);
        vm.prank(solver);
        settlement.fill(w, ws, SELL_IN);
    }

    /// @dev The reference: an ordinary time-decayed fill, the shape every other case
    ///      is a delta against.
    function test_bench_allModes() public {
        _warm();
        // ── 1. clock (linear decay) — the baseline
        _fund();
        Order memory o = _decayingSell(1);
        o.timing = uint256(uint32(block.timestamp)) | (uint256(600) << 32);
        vm.warp(block.timestamp + 300);
        uint256 base = _measure("clock  (linear decay)      ", o, _sign(o), "");

        // ── 2. block clock
        _fund();
        o = _decayingSell(2);
        o.timing = uint256(uint32(block.number)) | (uint256(100) << 32) | (uint256(1) << 102);
        vm.roll(block.number + 50);
        uint256 blockClock = _measure("block clock                ", o, _sign(o), "");

        // ── 3. priority auction
        _fund();
        o = _decayingSell(3);
        o.timing = uint256(1) << 103;
        o.params = DutchAuction.packParams(0, 0, 0, 2 gwei);
        vm.fee(1 gwei);
        vm.txGasPrice(2 gwei);
        uint256 priority = _measure("priority auction           ", o, _sign(o), "");

        // ── 4. range price module (one STATICCALL, pure arithmetic)
        _fund();
        RangePriceModule range = new RangePriceModule(0, 10_000);
        o = _decayingSell(4);
        o.pricingModule = address(range);
        uint256 rangeMod = _measure("price module: range        ", o, _sign(o), "");

        // ── 5. oracle-pegged module (STATICCALL + a feed read)
        _fund();
        PriceFeed feed = new PriceFeed();
        feed.set(1.5e18, block.timestamp);
        ChainlinkPeggedPriceModule pegged =
            new ChainlinkPeggedPriceModule(address(feed), 1 hours, 0.5e18, 3e18, 1, 1e18, true, 0);
        o = _decayingSell(5);
        o.pricingModule = address(pegged);
        uint256 oracleMod = _measure("price module: oracle-pegged", o, _sign(o), "");

        // ── 6. cosigned quote (STATICCALL + ecrecover inside the module)
        uint256 cosignedMod = _benchCosigned();

        console2.log("--- deltas vs the clock baseline ---");
        console2.log("block clock                ", int256(blockClock) - int256(base));
        console2.log("priority auction           ", int256(priority) - int256(base));
        console2.log("price module: range        ", int256(rangeMod) - int256(base));
        console2.log("price module: oracle-pegged", int256(oracleMod) - int256(base));
        console2.log("price module: cosigned     ", int256(cosignedMod) - int256(base));
    }

    /// @dev Its own frame: the quote needs four more live values than `bench` has
    ///      room for under legacy codegen.
    function _benchCosigned() private returns (uint256) {
        _fund();
        uint256 cosignerPk = 0xC05161;
        CosignedQuotePriceModule cosigned = new CosignedQuotePriceModule(vm.addr(cosignerPk), 10_000);
        Order memory o = _decayingSell(6);
        o.pricingModule = address(cosigned);
        bytes memory sig6 = _sign(o);
        uint256 deadline = block.timestamp + 5 minutes;
        bytes memory takerData;
        {
            bytes32 digest = cosigned.quoteDigest(lens.hashOrder(o), solver, 2_500, deadline);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(cosignerPk, digest);
            takerData = abi.encodePacked(solver, uint256(2_500), deadline, r, s, v);
        }
        return _measure("price module: cosigned     ", o, sig6, takerData);
    }

    /// @dev A BULK (Merkle) signature against a single one: the proof fold plus the
    ///      second `_hashTypedData`, per proof level.
    function test_bench_bulkSignature() public {
        _warm();
        _fund();
        Order memory o = _plainOrder(10, address(tA), address(tB), SELL_IN, OUT_START);
        uint256 single = _measure("signature: single          ", o, _sign(o), "");

        // A 4-leaf tree ⇒ a 2-level proof.
        bytes32[4] memory leaves;
        Order[4] memory os;
        for (uint256 i; i < 4; i++) {
            os[i] = _plainOrder(20 + i, address(tA), address(tB), SELL_IN, OUT_START);
            leaves[i] = lens.hashOrder(os[i]);
        }
        bytes32 l01 = _pair(leaves[0], leaves[1]);
        bytes32 root = _pair(l01, _pair(leaves[2], leaves[3]));
        bytes32 structHash = keccak256(abi.encode(keccak256("OrderRoot(bytes32 root)"), root));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(makerPk, keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), structHash)));
        bytes memory bulk = abi.encodePacked(r, s, v, leaves[1], _pair(leaves[2], leaves[3]), bytes1(0xB0));

        _fund();
        uint256 bulkGas = _measure("signature: bulk (2 levels) ", os[0], bulk, "");
        console2.log("--- delta ---");
        console2.log("bulk - single              ", int256(bulkGas) - int256(single));
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
}
