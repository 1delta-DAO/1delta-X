// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {MockSettlementBase} from "@coretest/shared/MockSettlementBase.t.sol";

import {Order, Item, ItemOp, LegOut} from "@core/settlement/Settlement.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";

import {ERC4626WithdrawModule} from "../src/ERC4626WithdrawModule.sol";
import {MockERC20 as VaultToken, MockTimelockVault} from "./ERC4626WithdrawModule.t.sol";

/// @title Erc4626SettlementFlowTest
/// @notice Audit 2026-09-30 MISC-MOD-6: the ERC4626WithdrawModule suite drove both
///         phases through a MockPermit3 with no taker book and no Settlement, so the
///         two-phase order flow (Phase 1 MAKE request, Phase 2 TAKE claim, the F28
///         whole-request gate, the Permit3 taker-book key) never ran end to end.
///         These tests run both phases as signed orders through a real Settlement and
///         a real Permit3.
contract Erc4626SettlementFlowTest is MockSettlementBase {
    ERC4626WithdrawModule module;
    VaultToken shares;
    VaultToken underlying;
    MockTimelockVault vault;

    uint256 constant SHARES = 100e18;
    uint256 constant LOCK = 7 days;
    uint256 constant TIP = 1e6; // Phase 1 pays the solver a small tA tip
    uint256 constant OUT = 250e6; // Phase 2: the solver pays tB for the claimed assets

    function setUp() public override {
        super.setUp();
        shares = new VaultToken();
        underlying = new VaultToken();
        vault = new MockTimelockVault(shares, underlying, LOCK);
        module = new ERC4626WithdrawModule(address(permit3), address(settlement));
        underlying.mint(address(vault), 1_000_000e18);

        shares.mint(maker, SHARES);
        tA.mint(maker, 10e6);
        tB.mint(solver, 10_000e6);
        vm.startPrank(maker);
        shares.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(module), address(shares), uint160(SHARES), 0);
        vm.stopPrank();
        _makerApprove(address(settlement), address(tA), TIP);
        _solverApprove(address(settlement), address(tB), type(uint160).max);
    }

    /// Phase 1: an outputless order that pays the solver a tip and carries one MAKE
    /// item submitting the redeem request on the maker's behalf.
    function _requestOrder(uint256 nonce) internal view returns (Order memory o) {
        o = _blank(nonce);
        o.legsIn = _legsIn1(address(tA), TIP);
        o.legsOut = PackedEncode.legsOut(new LegOut[](0));
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(module),
            amount: SHARES,
            recipient: address(0),
            data: abi.encode(address(vault), address(shares))
        });
        o.items = PackedEncode.items(items);
    }

    function _claimDataFor(uint256 requestId) internal view returns (bytes memory) {
        return abi.encode(address(vault), requestId, SHARES, SHARES);
    }

    /// Phase 2: sell the claimed underlying (legsIn[0], funded by the TAKE item's
    /// proceeds landing on Settlement) for tB.
    function _claimOrder(uint256 nonce, uint256 requestId) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(underlying), address(tB), SHARES, OUT);
        _setExpiry(o, block.timestamp + 30 days); // must outlive the vault lock
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.TAKE,
            module: address(module),
            amount: SHARES,
            recipient: address(0),
            data: _claimDataFor(requestId)
        });
        o.items = PackedEncode.items(items);
    }

    function _phase1() internal returns (uint256 requestId) {
        Order memory o = _requestOrder(1);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        settlement.fill(o, sig, type(uint256).max);
        requestId = 1; // the mock vault's first id
        (address beneficiary, uint256 unlocksAt) = module.pendingWithdrawals(address(vault), requestId);
        assertEq(beneficiary, maker, "request recorded for the maker");
        assertEq(unlocksAt, block.timestamp + LOCK);
    }

    function _grantClaim(uint256 requestId) internal {
        vm.prank(maker);
        permit3.approveTaker(
            address(settlement),
            address(module),
            keccak256(_claimDataFor(requestId)),
            uint160(SHARES),
            uint48(block.timestamp + 30 days)
        );
    }

    /// Phase 1 through Settlement: shares move maker -> module -> vault via the
    /// maker's Permit3 token grant to the module; the solver earns the tip.
    function test_audit_MISC_MOD_6_erc4626_phase1_requestThroughSettlement() public {
        _phase1();
        assertEq(shares.balanceOf(maker), 0, "maker's shares submitted");
        assertEq(shares.balanceOf(address(module)), 0, "no share residue on the module");
        assertEq(shares.balanceOf(address(vault)), SHARES, "vault holds the queued shares");
        assertEq(tA.balanceOf(solver), TIP, "solver paid the tip");
    }

    /// Phase 1 then Phase 2: after the lock, the claim TAKE's proceeds land on
    /// Settlement and fund legsIn[0]; the maker receives tB.
    function test_audit_MISC_MOD_6_erc4626_phase1ThenPhase2_fullFlow() public {
        uint256 requestId = _phase1();
        _grantClaim(requestId);
        Order memory o = _claimOrder(2, requestId);
        bytes memory sig = _sign(o);

        // Before the lock elapses the claim reverts (module early-exit).
        vm.prank(solver);
        vm.expectRevert();
        settlement.fill(o, sig, type(uint256).max);

        vm.warp(block.timestamp + LOCK);
        vm.prank(solver);
        settlement.fill(o, sig, type(uint256).max);

        assertEq(underlying.balanceOf(solver), SHARES, "solver received the claimed assets");
        assertEq(tB.balanceOf(maker), OUT, "maker received the output leg");
        assertEq(underlying.balanceOf(address(settlement)), 0, "nothing stranded on Settlement");
        assertEq(underlying.balanceOf(address(module)), 0, "nothing stranded on the module");
        (address beneficiary,) = module.pendingWithdrawals(address(vault), requestId);
        assertEq(beneficiary, address(0), "request consumed");
        (uint160 left,) =
            permit3.takerAllowance(maker, address(settlement), address(module), keccak256(_claimDataFor(requestId)));
        assertEq(left, 0, "taker grant spent");
    }

    /// The F28 whole-request gate holds through Settlement: a partial claim fill
    /// reverts and the request survives for a later full fill.
    function test_audit_MISC_MOD_6_erc4626_phase2_partialFillRefused_requestSurvives() public {
        uint256 requestId = _phase1();
        _grantClaim(requestId);
        Order memory o = _claimOrder(3, requestId);
        bytes memory sig = _sign(o);
        vm.warp(block.timestamp + LOCK);

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(FullFillGuard.PartialFillUnsupported.selector, SHARES / 2, SHARES));
        settlement.fill(o, sig, SHARES / 2);

        (address beneficiary,) = module.pendingWithdrawals(address(vault), requestId);
        assertEq(beneficiary, maker, "request intact after the refused slice");

        vm.prank(solver);
        settlement.fill(o, sig, SHARES);
        assertEq(tB.balanceOf(maker), OUT);
    }

    /// The taker book is keyed (maker, Settlement, module, ref): a claim grant for
    /// one request cannot dispatch a claim of another.
    function test_audit_MISC_MOD_6_erc4626_phase2_needsTakerGrantForThisRef() public {
        uint256 requestId = _phase1();
        _grantClaim(requestId + 1); // a grant over a DIFFERENT request's bytes
        Order memory o = _claimOrder(4, requestId);
        bytes memory sig = _sign(o);
        vm.warp(block.timestamp + LOCK);

        vm.prank(solver);
        vm.expectRevert();
        settlement.fill(o, sig, type(uint256).max);
    }
}
