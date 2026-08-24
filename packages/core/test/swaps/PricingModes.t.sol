// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Settlement, Order, OrderSide} from "@core/settlement/Settlement.sol";
import {DutchAuction} from "@core/settlement/DutchAuction.sol";
import {ProgressBumpModule} from "../shared/MockModules.sol";

import {MockSettlementBase} from "../shared/MockSettlementBase.t.sol";
import {PackedEncode} from "../shared/PackedEncode.sol";

/// @title PricingModes
/// @notice The 2026-08 pricing additions, end to end through a real fill:
///           • the BLOCK clock (`timing` bit 102) — decay measured in blocks;
///           • the PRIORITY auction (bit 103) — the bump is bid in priority fee;
///           • external {IPriceModule} DISPATCH — that the core resolves, pins and
///             clamps whatever a module answers, measured on a local mock;
///           • the CLAMP that keeps every one of them inside the maker's band.
///
///  Core ships no price modules of its own — the oracle-pegged, cosigned and range
///  instances all live in `packages/modules/pricing`, and their own behaviour is
///  tested there. What stays here is core's side of the seam, on {ProgressBumpModule}
///  so a failure points at the core rather than at a module's arithmetic.
contract PricingModesTest is MockSettlementBase {
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

    // ════════════════════ block clock (timing bit 102) ════════════════════

    function test_blockClock_decaysPerBlock() public {
        _fund(OUT_START);
        Order memory o = _decayingSell(1);
        // 10-BLOCK decay window starting at the current block, on the block clock.
        o.timing =
            uint256(uint32(block.number)) | (uint256(10) << 32) | (uint256(1) << 102) | _expiryBits(block.timestamp + 1 hours);
        bytes memory sig = _sign(o);

        // Half the window — in BLOCKS, with the timestamp deliberately untouched, so
        // a timestamp-clock reading would report no decay at all.
        vm.roll(block.number + 5);
        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN);
        assertEq(tB.balanceOf(maker) - before_, (OUT_START + OUT_END) / 2, "midpoint of the block window");
    }

    function test_blockClock_beforeStartBlock_reverts() public {
        _fund(OUT_START);
        Order memory o = _decayingSell(2);
        o.timing = uint256(uint32(block.number + 50)) | (uint256(10) << 32) | (uint256(1) << 102)
            | _expiryBits(block.timestamp + 1 hours);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert(DutchAuction.AuctionNotStarted.selector);
        settlement.fill(o, sig, SELL_IN);
    }

    // ════════════════════ priority auction (timing bit 103) ════════════════════

    /// @dev The floor is what a zero-bid fill clears at — the guarantee the maker
    ///      signed, identical to any other order's `end`.
    function test_priorityAuction_noBid_clearsAtFloor() public {
        _fund(OUT_START);
        Order memory o = _decayingSell(3);
        o.timing = (uint256(1) << 103) | _expiryBits(block.timestamp + 1 hours);
        o.params = DutchAuction.packParams(0, 0, 0, 1 gwei, 0);
        bytes memory sig = _sign(o);

        vm.fee(1 gwei);
        vm.txGasPrice(1 gwei); // no priority fee above basefee
        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN);
        assertEq(tB.balanceOf(maker) - before_, OUT_END, "unbid fill clears at the floor");
    }

    function test_priorityAuction_bidMovesTickTowardStart() public {
        _fund(OUT_START);
        Order memory o = _decayingSell(4);
        o.timing = (uint256(1) << 103) | _expiryBits(block.timestamp + 1 hours);
        o.params = DutchAuction.packParams(0, 0, 0, 2 gwei, 0); // 2 gwei buys a FULL bump
        bytes memory sig = _sign(o);

        vm.fee(1 gwei);
        vm.txGasPrice(2 gwei); // 1 gwei of priority = half of the scale
        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN);
        assertEq(tB.balanceOf(maker) - before_, (OUT_START + OUT_END) / 2, "half-bid lands mid-band");
    }

    /// @dev Overbidding is capped by the maker's own `start` — the band is absolute.
    function test_priorityAuction_overbid_capsAtStart() public {
        _fund(OUT_START);
        Order memory o = _decayingSell(5);
        o.timing = (uint256(1) << 103) | _expiryBits(block.timestamp + 1 hours);
        o.params = DutchAuction.packParams(0, 0, 0, 1 gwei, 0);
        bytes memory sig = _sign(o);

        vm.fee(1 gwei);
        vm.txGasPrice(100 gwei);
        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN);
        assertEq(tB.balanceOf(maker) - before_, OUT_START, "capped at the signed ambition");
    }

    /// @dev The chain's INCLUSION tip is not an auction bid. With a 1 gwei baseline a
    ///      fill that tips exactly 1 gwei has bid nothing and clears at the floor —
    ///      without it the maker would collect an improvement nobody chose to offer.
    function test_priorityAuction_baselineTipIsNotABid() public {
        _fund(OUT_START);
        Order memory o = _decayingSell(7);
        o.timing = (uint256(1) << 103) | _expiryBits(block.timestamp + 1 hours);
        o.params = DutchAuction.packParams(0, 0, 0, 2 gwei, 1 gwei); // 1 gwei baseline
        bytes memory sig = _sign(o);

        vm.fee(1 gwei);
        vm.txGasPrice(2 gwei); // 1 gwei of tip — exactly the baseline
        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN);
        assertEq(tB.balanceOf(maker) - before_, OUT_END, "the baseline tip buys nothing");
    }

    /// @dev Only the tip ABOVE the baseline bids. 3 gwei tip − 1 gwei baseline = 2 gwei
    ///      of bid against a 4 gwei scale ⇒ half a bump.
    function test_priorityAuction_baselineSubtractedFromBid() public {
        _fund(OUT_START);
        Order memory o = _decayingSell(8);
        o.timing = (uint256(1) << 103) | _expiryBits(block.timestamp + 1 hours);
        o.params = DutchAuction.packParams(0, 0, 0, 4 gwei, 1 gwei);
        bytes memory sig = _sign(o);

        vm.fee(1 gwei);
        vm.txGasPrice(4 gwei); // 3 gwei of tip, 2 of which are a bid
        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN);
        assertEq(tB.balanceOf(maker) - before_, (OUT_START + OUT_END) / 2, "half-bid lands mid-band");
    }

    /// @dev The gas bump cannot run under a priority auction — it moves the tick the
    ///      wrong way. An order carrying both is rejected outright rather than having
    ///      one of its signed parameters silently dropped.
    function test_priorityAuction_withGasBump_reverts() public {
        _fund(OUT_START);
        Order memory o = _decayingSell(9);
        o.timing = (uint256(1) << 103) | _expiryBits(block.timestamp + 1 hours);
        o.params = DutchAuction.packParams(0, 5_000, 1 gwei, 2 gwei, 0);
        bytes memory sig = _sign(o);

        vm.fee(1 gwei);
        vm.txGasPrice(2 gwei);
        vm.prank(solver);
        vm.expectRevert(DutchAuction.InvalidAuctionParams.selector);
        settlement.fill(o, sig, SELL_IN);
    }

    /// @dev `gasPriceRef` is the gas bump's reference basefee and NOTHING else. On a
    ///      priority order it stays inert, so an order signed before the baseline field
    ///      existed prices exactly as it did — the reason the baseline claimed its own
    ///      bits instead of overlaying this one.
    function test_priorityAuction_gasPriceRefIsInert() public {
        _fund(OUT_START);
        Order memory o = _decayingSell(10);
        o.timing = (uint256(1) << 103) | _expiryBits(block.timestamp + 1 hours);
        o.params = DutchAuction.packParams(0, 0, 5 gwei, 2 gwei, 0); // ref set, no bump, no baseline
        bytes memory sig = _sign(o);

        vm.fee(1 gwei);
        vm.txGasPrice(2 gwei); // 1 gwei of bid against a 2 gwei scale
        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN);
        assertEq(tB.balanceOf(maker) - before_, (OUT_START + OUT_END) / 2, "gasPriceRef did not eat the bid");
    }

    function test_priorityAuction_withoutScale_reverts() public {
        _fund(OUT_START);
        Order memory o = _decayingSell(6);
        o.timing = (uint256(1) << 103) | _expiryBits(block.timestamp + 1 hours); // no priorityScale in `params`
        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert(DutchAuction.InvalidAuctionParams.selector);
        settlement.fill(o, sig, SELL_IN);
    }

    // ════════════════════ external price modules ════════════════════

    function test_priceModule_bumpFollowsFillProgress() public {
        _fund(OUT_START * 2);
        // 0 bps at 0% filled (the maker's ambition) → 10000 bps at 100% (its floor).
        ProgressBumpModule mod = new ProgressBumpModule(0, 10_000);
        Order memory o = _decayingSell(7);
        o.pricingModule = address(mod);
        bytes memory sig = _sign(o);

        // First half: priced at progress 0 ⇒ the full `start` rate.
        uint256 before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN / 2);
        assertEq(tB.balanceOf(maker) - before_, OUT_START / 2, "first slice at the start rate");

        // Second half: progress is now 50% ⇒ the midpoint rate.
        before_ = tB.balanceOf(maker);
        vm.prank(solver);
        settlement.fill(o, sig, SELL_IN / 2);
        assertEq(tB.balanceOf(maker) - before_, ((OUT_START + OUT_END) / 2) / 2, "second slice at the midpoint");
    }
}
