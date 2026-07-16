// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {UniversalSettlement, Order, Validator} from "@core/settlement/UniversalSettlement.sol";
import {SettlementLens} from "@core/periphery/SettlementLens.sol";
import {FillerWhitelistValidator} from "@core/validators/FillerWhitelistValidator.sol";

import {MockSettlementBase} from "../shared/MockSettlementBase.t.sol";

/// @title FillerWhitelistTest
/// @notice Coverage for {FillerWhitelistValidator} and the filler-aware validator
///         ABI: listed fillers pass, unlisted fillers revert `ValidationFailed`,
///         a non-zero `openAfter` opens the order to everyone (Fusion-style
///         liveness fallback) while `openAfter == 0` stays hard forever, curator
///         lists are isolated, `batchFill` threads the REAL caller as the filler,
///         the same gate works as a post-execution invariant, and the lens
///         previews filler-dependent orders per filler.
contract FillerWhitelistTest is MockSettlementBase {
    uint256 constant AMOUNT_IN = 100e18; // tA maker gives
    uint256 constant AMOUNT_OUT = 300e18; // tB maker gets

    FillerWhitelistValidator wl;
    address curator = address(0xC04A704); // default trusted curator
    address outsider = address(0x0DD); // never listed under `curator`

    function setUp() public override {
        super.setUp();
        wl = new FillerWhitelistValidator();

        tA.mint(maker, 1_000e18);
        _makerApprove(address(settlement), address(tA), type(uint160).max);

        // Both the (to-be-listed) solver and the outsider can deliver tokenOut,
        // so the ONLY thing separating them is the whitelist gate.
        tB.mint(solver, 1_000e18);
        _solverApprove(address(settlement), address(tB), type(uint160).max);
        tB.mint(outsider, 1_000e18);
        vm.startPrank(outsider);
        tB.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(tB), type(uint160).max, 0);
        vm.stopPrank();
    }

    // ──────────────────── Helpers ────────────────────

    function _setListed(address curator_, address filler, bool allowed) internal {
        address[] memory fillers = new address[](1);
        fillers[0] = filler;
        vm.prank(curator_);
        wl.setFillers(fillers, allowed);
    }

    /// @dev Plain tA→tB order gated by the whitelist validator under `curator_`.
    function _gated(uint256 nonce, address curator_, uint256 openAfter) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        Validator[] memory v = new Validator[](1);
        v[0] = Validator({target: address(wl), data: abi.encode(curator_, openAfter)});
        o.validators = v;
    }

    function _expectValidationFailed() internal {
        vm.expectRevert(abi.encodeWithSelector(UniversalSettlement.ValidationFailed.selector, uint256(0)));
    }

    // ──────────────────── Registry ────────────────────

    function test_whitelist_setFillers_emitsAndStores() public {
        address[] memory fillers = new address[](2);
        fillers[0] = solver;
        fillers[1] = outsider;
        vm.expectEmit(true, false, false, true, address(wl));
        emit FillerWhitelistValidator.FillersSet(curator, fillers, true);
        vm.prank(curator);
        wl.setFillers(fillers, true);

        assertTrue(wl.isListed(curator, solver), "solver listed");
        assertTrue(wl.isListed(curator, outsider), "outsider listed");
        assertFalse(wl.isListed(solver, solver), "other curators untouched");
    }

    // ──────────────────── Pre-execution gate ────────────────────

    function test_whitelist_listedFillerFills() public {
        _setListed(curator, solver, true);
        Order memory o = _gated(1, curator, 0);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        settlement.fill(o, sig, AMOUNT_IN);
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "maker got output");
        assertEq(tA.balanceOf(solver), AMOUNT_IN, "listed solver got input");
    }

    function test_whitelist_unlistedFillerReverts() public {
        Order memory o = _gated(1, curator, 0);
        bytes memory sig = _sign(o);

        vm.prank(outsider);
        _expectValidationFailed();
        settlement.fill(o, sig, AMOUNT_IN);
    }

    function test_whitelist_delistedFillerBlockedAgain() public {
        _setListed(curator, solver, true);
        _setListed(curator, solver, false);
        Order memory o = _gated(1, curator, 0);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        _expectValidationFailed();
        settlement.fill(o, sig, AMOUNT_IN);
    }

    // ──────────────────── openAfter liveness fallback ────────────────────

    function test_whitelist_unlistedFillerOpensAfterT() public {
        uint256 openAfter = block.timestamp + 30 minutes;
        Order memory o = _gated(1, curator, openAfter);
        o.deadline = block.timestamp + 2 hours; // stays live past the open-up
        bytes memory sig = _sign(o);

        // Before T: whitelisted-only.
        vm.prank(outsider);
        _expectValidationFailed();
        settlement.fill(o, sig, AMOUNT_IN);

        // At/after T: open to everyone.
        vm.warp(openAfter);
        vm.prank(outsider);
        settlement.fill(o, sig, AMOUNT_IN);
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "maker got output after open-up");
        assertEq(tA.balanceOf(outsider), AMOUNT_IN, "outsider filled after open-up");
    }

    function test_whitelist_openAfterZeroStaysHardForever() public {
        Order memory o = _gated(1, curator, 0);
        o.deadline = block.timestamp + 3650 days;
        bytes memory sig = _sign(o);

        vm.warp(block.timestamp + 365 days);
        vm.prank(outsider);
        _expectValidationFailed();
        settlement.fill(o, sig, AMOUNT_IN);
    }

    // ──────────────────── Curator isolation ────────────────────

    function test_whitelist_curatorIsolation() public {
        address curatorB = address(0xB0B);
        // Listed under curator A — but the order trusts curator B's list.
        _setListed(curator, solver, true);
        Order memory o = _gated(1, curatorB, 0);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        _expectValidationFailed();
        settlement.fill(o, sig, AMOUNT_IN);

        // Listing under the SIGNED curator unblocks it.
        _setListed(curatorB, solver, true);
        vm.prank(solver);
        settlement.fill(o, sig, AMOUNT_IN);
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "fills once listed under curator B");
    }

    // ──────────────────── batchFill threads the real filler ────────────────────

    function test_whitelist_batchFillThreadsRealFiller() public {
        _setListed(curator, solver, true);
        Order memory o = _gated(1, curator, 0);

        Order[] memory orders = new Order[](1);
        orders[0] = o;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(o);
        uint256[] memory amts = new uint256[](1);
        amts[0] = AMOUNT_IN;

        // Unlisted caller: the self-call threads OUTSIDER as the filler (not the
        // settlement's own address) → the order is skipped, not filled.
        vm.prank(outsider);
        (, bool[] memory ok) = settlement.batchFill(orders, sigs, amts, false);
        assertFalse(ok[0], "unlisted batch caller skipped");
        assertEq(tB.balanceOf(maker), 0, "nothing delivered");

        // Listed caller: threads SOLVER → fills.
        vm.prank(solver);
        (, ok) = settlement.batchFill(orders, sigs, amts, false);
        assertTrue(ok[0], "listed batch caller fills");
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "maker got output via batchFill");
    }

    // ──────────────────── Post-execution invariant ────────────────────

    /// @dev A filler-aware validator works as a post-execution invariant too: the
    ///      invariant gate receives `ctx.filler` and unwinds the whole fill for an
    ///      unlisted filler AFTER all transfers executed.
    function test_whitelist_asPostExecutionInvariant() public {
        Order memory o = _plainOrder(1, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        Validator[] memory inv = new Validator[](1);
        inv[0] = Validator({target: address(wl), data: abi.encode(curator, uint256(0))});
        o.invariants = inv;
        bytes memory sig = _sign(o);

        // Unlisted filler: everything (delivery + payout) unwinds on the invariant.
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(UniversalSettlement.InvariantFailed.selector, uint256(0)));
        settlement.fill(o, sig, AMOUNT_IN);
        assertEq(tB.balanceOf(maker), 0, "unwound: maker kept nothing");
        assertEq(tA.balanceOf(outsider), 0, "unwound: outsider got nothing");

        // Listed filler passes the same signed invariant.
        _setListed(curator, solver, true);
        vm.prank(solver);
        settlement.fill(o, sig, AMOUNT_IN);
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "listed filler settles");
    }

    // ──────────────────── Lens preview is filler-aware ────────────────────

    function test_whitelist_lensPreviewsPerFiller() public {
        _setListed(curator, solver, true);
        Order memory o = _gated(1, curator, 0);
        bytes memory sig = _sign(o);

        (SettlementLens.OrderStatus st, uint256 fillable, bool sigOk, bool passSolver) =
            lens.getOrderRelevantState(o, sig, solver, "");
        assertEq(uint8(st), uint8(SettlementLens.OrderStatus.Fillable), "fillable");
        assertEq(fillable, AMOUNT_IN, "full amount");
        assertTrue(sigOk, "sig valid");
        assertTrue(passSolver, "listed filler previews as passing");

        (,,, bool passOutsider) = lens.getOrderRelevantState(o, sig, outsider, "");
        assertFalse(passOutsider, "unlisted filler previews as blocked");
    }
}
