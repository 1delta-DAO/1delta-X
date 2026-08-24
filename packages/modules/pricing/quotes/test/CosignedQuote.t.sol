// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order} from "@core/settlement/Settlement.sol";
import {CosignedQuotePriceModule} from "../src/CosignedQuotePriceModule.sol";

import {MockSettlementBase} from "@coretest/shared/MockSettlementBase.t.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

/// @title CosignedQuote
/// @notice {CosignedQuotePriceModule} end to end through a real fill: a quote
///         improves WITHIN the maker's band, an absent quote degrades to the
///         configured fallback, and a forged one reverts.
///
///  The clock-floored variant — and the `FALLBACK_BPS` footgun it removes
///  structurally — is {ClockFlooredQuoteTest} in this same package.
///
///  Lived in core's `PricingModes.t.sol` until the pricing modules moved out to
///  `packages/modules/pricing`; the block-clock and priority-auction cases stayed
///  behind, since those are core pricing rather than a module.
contract CosignedQuoteTest is MockSettlementBase {
    uint256 constant SELL_IN = 1_000e18; //   the maker's fixed input (anchor)
    uint256 constant OUT_START = 2_000e18; // best-for-maker output
    uint256 constant OUT_END = 1_000e18; //   the maker's floor

    function _fund(uint256 outAmount) internal {
        tA.mint(maker, SELL_IN);
        _makerApprove(address(settlement), address(tA), SELL_IN);
        tB.mint(solver, outAmount);
        _solverApprove(address(settlement), address(tB), outAmount);
    }

    /// @dev A decaying SELL: fixed input, output falling OUT_START → OUT_END.
    function _decayingSell(uint256 nonce) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), SELL_IN, OUT_START);
        o.legsOut = PackedEncode.oneLegOut(address(tB), OUT_START, OUT_END, address(0));
    }

    function test_cosignedQuote_improvesWithinBand() public {
        _fund(OUT_START);
        uint256 cosignerPk = 0xC05161;
        CosignedQuotePriceModule mod = new CosignedQuotePriceModule(vm.addr(cosignerPk), 10_000);

        Order memory o = _decayingSell(12);
        o.pricingModule = address(mod);
        bytes memory sig = _sign(o);
        bytes32 orderHash = lens.hashOrder(o);

        // The cosigner quotes a 2500 bps bump — a quarter of the way down from the
        // maker's ambition, i.e. an improvement on the unquoted floor.
        uint256 deadline = block.timestamp + 5 minutes;
        bytes32 digest = mod.quoteDigest(orderHash, solver, 2_500, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(cosignerPk, digest);
        bytes memory takerData = abi.encodePacked(solver, uint256(2_500), deadline, r, s, v);

        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN, takerData);
        assertEq(tB.balanceOf(maker) - before_, OUT_START - (OUT_START - OUT_END) / 4, "quoted tick");
    }

    /// @dev No quote ⇒ the configured fallback (here: the maker's floor). The order
    ///      stays fillable without the cosigner — the cosigner is an improver, never
    ///      a gatekeeper.
    function test_cosignedQuote_absentQuote_fallsBackToFloor() public {
        _fund(OUT_START);
        CosignedQuotePriceModule mod = new CosignedQuotePriceModule(address(0xC0), 10_000);
        Order memory o = _decayingSell(13);
        o.pricingModule = address(mod);
        bytes memory sig = _sign(o);

        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN);
        assertEq(tB.balanceOf(maker) - before_, OUT_END, "unquoted fills clear at the floor");
    }

    function test_cosignedQuote_forgedQuote_reverts() public {
        _fund(OUT_START);
        uint256 cosignerPk = 0xC05161;
        uint256 attackerPk = 0xBAD;
        CosignedQuotePriceModule mod = new CosignedQuotePriceModule(vm.addr(cosignerPk), 10_000);

        Order memory o = _decayingSell(14);
        o.pricingModule = address(mod);
        bytes memory sig = _sign(o);
        uint256 deadline = block.timestamp + 5 minutes;
        bytes32 digest = mod.quoteDigest(lens.hashOrder(o), solver, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attackerPk, digest);
        bytes memory takerData = abi.encodePacked(solver, uint256(0), deadline, r, s, v);

        vm.prank(solver);
        vm.expectRevert();
        settlement.fill(o, sig, SELL_IN, takerData);
    }
}
