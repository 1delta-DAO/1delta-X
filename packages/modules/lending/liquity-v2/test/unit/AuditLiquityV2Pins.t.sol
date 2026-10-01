// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Permit3} from "@core/permit3/Permit3.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";

import {
    LiquityV2AddCollModule,
    LiquityV2RepayModule,
    LiquityV2TakerModule,
    LiquityV2TroveAuth
} from "../../src/LiquityV2Modules.sol";
import {LiquityV2PreFundModule} from "../../src/LiquityV2PreFundModules.sol";
import {
    LqtyRegistry,
    LqtyToken,
    LqtyTroveNFT,
    LqtyTroveManager,
    LqtyBorrowerOperations
} from "./LiquityV2TroveAuth.t.sol";

/// @title 2026-09-30 audit — Liquity v2 token pins and the delivery bound.
/// @notice G-VENUE_B-1 (short delivery from a stale receiver is now a revert, not a
///         wallet bill), L-LRG-1 (WithdrawColl pins the collateral to the branch),
///         L-LRG-5 (every debt-token pin has a mismatch test), L-LRG-3 (the single
///         add-manager slot). The Felix seam is in `AuditFelixModules.t.sol`.
contract AuditLiquityV2PinsTest is Test {
    Permit3 permit3;
    LqtyToken bold;
    LqtyToken collateral;
    LqtyToken fake;
    LqtyTroveNFT nft;
    LqtyTroveManager tm;
    LqtyBorrowerOperations bo;
    LqtyRegistry registry;

    LiquityV2AddCollModule addCollModule;
    LiquityV2RepayModule repayModule;
    LiquityV2TakerModule takerModule;
    LiquityV2PreFundModule preFund;

    address settlement = address(0x5E77);
    address maker = address(0xA11CE);
    address staleReceiver = address(0x5E11E2);
    address receiver = address(0xFEE);

    uint256 constant BRANCH = 0;
    uint256 constant TROVE = 1111;

    function setUp() public {
        permit3 = new Permit3();
        bold = new LqtyToken();
        collateral = new LqtyToken();
        fake = new LqtyToken();
        nft = new LqtyTroveNFT();
        tm = new LqtyTroveManager(address(nft));
        bo = new LqtyBorrowerOperations(address(tm), address(bold), address(collateral));
        tm.setBorrowerOperations(address(bo));
        registry = new LqtyRegistry();
        registry.set(BRANCH, address(tm));
        registry.setBold(address(bold));
        registry.setColl(BRANCH, address(collateral));

        addCollModule = new LiquityV2AddCollModule(address(permit3), settlement, address(registry));
        repayModule = new LiquityV2RepayModule(address(permit3), settlement, address(registry));
        takerModule = new LiquityV2TakerModule(address(permit3), address(registry));
        preFund = new LiquityV2PreFundModule(address(permit3), settlement, address(registry));

        nft.mint(TROVE, maker);
        tm.setColl(TROVE, 20e18);
        tm.setDebt(TROVE, 4_000e18);
        collateral.mint(address(bo), 100e18);
    }

    function _take(bytes memory data, uint256 amount) internal {
        vm.prank(maker);
        permit3.approveTaker(settlement, address(takerModule), keccak256(data), uint160(amount), 0);
        vm.prank(settlement);
        permit3.take(address(takerModule), maker, uint160(amount), receiver, data);
    }

    function _desc(address token, LiquityV2PreFundModule.Op op) internal pure returns (uint256) {
        return (uint256(1) << 255) | (uint256(1) << 253) | (uint256(uint160(token)) << 16) | (uint256(op) << 244);
    }

    // ──────────────── G-VENUE_B-1: stale receiver ⇒ revert ────────────────

    /// The trove carries manager = the module but receiver = a former owner (the
    /// pair survives a TroveNFT sale). The venue pays the stale receiver; the module
    /// used to forward 0 without reverting, and the core billed the leg to the
    /// maker's wallet. Now the fill fails closed and nothing moves.
    function test_audit_G_VENUE_B_1_withdrawColl_staleReceiver_reverts() public {
        bo.setRemoveManagerWithReceiver(TROVE, address(takerModule), staleReceiver);
        bytes memory data = abi.encode(uint8(1), BRANCH, TROVE, address(collateral));

        vm.prank(maker);
        permit3.approveTaker(settlement, address(takerModule), keccak256(data), uint160(5e18), 0);
        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(FullFillGuard.ShortWithdraw.selector, 0, 5e18));
        permit3.take(address(takerModule), maker, uint160(5e18), receiver, data);

        assertEq(collateral.balanceOf(staleReceiver), 0, "stale receiver got nothing");
        assertEq(tm.coll(TROVE), 20e18, "trove untouched");
    }

    function test_audit_G_VENUE_B_1_borrow_staleReceiver_reverts() public {
        bo.setRemoveManagerWithReceiver(TROVE, address(takerModule), staleReceiver);
        bytes memory data = abi.encode(uint8(0), BRANCH, TROVE, address(bold), uint256(0), uint256(1_000e18));

        vm.prank(maker);
        permit3.approveTaker(settlement, address(takerModule), keccak256(data), uint160(1_000e18), 0);
        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(FullFillGuard.ShortWithdraw.selector, 0, 1_000e18));
        permit3.take(address(takerModule), maker, uint160(1_000e18), receiver, data);

        assertEq(bold.balanceOf(staleReceiver), 0, "stale receiver got nothing");
    }

    /// Control: receiver == module still settles, partial slices included (the
    /// bound cannot misfire — the venue call is sized at the slice).
    function test_audit_G_VENUE_B_1_receiverIsModule_partialSlice_settles() public {
        bo.setRemoveManagerWithReceiver(TROVE, address(takerModule), address(takerModule));
        _take(abi.encode(uint8(1), BRANCH, TROVE, address(collateral)), 2e18);
        assertEq(collateral.balanceOf(receiver), 2e18, "slice forwarded");
        assertEq(collateral.balanceOf(address(takerModule)), 0, "module holds nothing");
    }

    // ──────────────── L-LRG-1: collateral pin ────────────────

    /// A real-but-wrong collateral named on the WithdrawColl leg used to measure 0,
    /// forward 0 and strand the real collateral on the singleton.
    function test_audit_L_LRG_1_withdrawColl_misnamedToken_reverts() public {
        bo.setRemoveManagerWithReceiver(TROVE, address(takerModule), address(takerModule));
        bytes memory data = abi.encode(uint8(1), BRANCH, TROVE, address(fake));

        vm.prank(maker);
        permit3.approveTaker(settlement, address(takerModule), keccak256(data), uint160(5e18), 0);
        vm.prank(settlement);
        vm.expectRevert(
            abi.encodeWithSelector(LiquityV2TroveAuth.CollTokenMismatch.selector, address(fake), address(collateral))
        );
        permit3.take(address(takerModule), maker, uint160(5e18), receiver, data);

        assertEq(collateral.balanceOf(address(takerModule)), 0, "nothing stranded on the singleton");
        assertEq(tm.coll(TROVE), 20e18, "trove untouched");
    }

    function test_audit_L_LRG_1_addColl_misnamedToken_reverts() public {
        vm.prank(settlement);
        vm.expectRevert(
            abi.encodeWithSelector(LiquityV2TroveAuth.CollTokenMismatch.selector, address(fake), address(collateral))
        );
        addCollModule.makeOnBehalf(maker, 1e18, abi.encode(BRANCH, TROVE, address(fake)));
    }

    function test_audit_L_LRG_1_preFundAddColl_misnamedToken_reverts() public {
        fake.mint(address(preFund), 1e18);
        bytes memory data =
            abi.encode(_desc(address(fake), LiquityV2PreFundModule.Op.AddColl), BRANCH, TROVE, address(fake));
        vm.prank(settlement);
        vm.expectRevert(
            abi.encodeWithSelector(LiquityV2TroveAuth.CollTokenMismatch.selector, address(fake), address(collateral))
        );
        preFund.makeOnBehalf(maker, 1e18, data);
    }

    // ──────────────── L-LRG-5: every debt-token pin, negative ────────────────

    function test_audit_L_LRG_5_repay_misnamedBold_reverts() public {
        vm.prank(settlement);
        vm.expectRevert(
            abi.encodeWithSelector(LiquityV2TroveAuth.BoldTokenMismatch.selector, address(fake), address(bold))
        );
        repayModule.makeOnBehalf(maker, 1e18, abi.encode(BRANCH, TROVE, address(fake)));
    }

    function test_audit_L_LRG_5_borrow_misnamedBold_reverts() public {
        bo.setRemoveManagerWithReceiver(TROVE, address(takerModule), address(takerModule));
        bytes memory data = abi.encode(uint8(0), BRANCH, TROVE, address(fake), uint256(0), uint256(1e18));
        vm.prank(maker);
        permit3.approveTaker(settlement, address(takerModule), keccak256(data), uint160(1e18), 0);
        vm.prank(settlement);
        vm.expectRevert(
            abi.encodeWithSelector(LiquityV2TroveAuth.BoldTokenMismatch.selector, address(fake), address(bold))
        );
        permit3.take(address(takerModule), maker, uint160(1e18), receiver, data);
    }

    function test_audit_L_LRG_5_preFundRepay_misnamedBold_reverts() public {
        fake.mint(address(preFund), 1e18);
        bytes memory data =
            abi.encode(_desc(address(fake), LiquityV2PreFundModule.Op.Repay), BRANCH, TROVE, address(fake));
        vm.prank(settlement);
        vm.expectRevert(
            abi.encodeWithSelector(LiquityV2TroveAuth.BoldTokenMismatch.selector, address(fake), address(bold))
        );
        preFund.makeOnBehalf(maker, 1e18, data);
    }

    /// L-LRG-3: the single add-manager slot. Naming the add-coll module locks the
    /// separate pull repay module out — the README no longer instructs both.
    function test_audit_L_LRG_3_singleAddManagerSlot_locksOutTheOtherPullModule() public {
        bo.setAddManager(TROVE, address(addCollModule));
        bold.mint(maker, 1_000e18);
        vm.startPrank(maker);
        bold.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(repayModule), address(bold), uint160(1_000e18), 0);
        vm.stopPrank();

        vm.prank(settlement);
        vm.expectRevert(LqtyBorrowerOperations.NotManager.selector);
        repayModule.makeOnBehalf(maker, 1_000e18, abi.encode(BRANCH, TROVE, address(bold)));
    }

}
