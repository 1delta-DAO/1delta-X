// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {DustHandler} from "@lib/DustHandler.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";

import {ListaModulesBase, IListaBrokerViews} from "../shared/ListaModulesBase.t.sol";
import {ListaBrokerModule} from "../../src/ListaBrokerModule.sol";
import {IListaBroker, IMoolah} from "../../src/interfaces/ILista.sol";

struct AuditFixedTermAndRate20260930 {
    uint256 termId;
    uint256 duration;
    uint256 apr;
}

/// @dev The broker's BOT-only term editor and its role enumeration (fork-only).
interface IListaBrokerBot20260930 {
    function updateFixedTermAndRate(AuditFixedTermAndRate20260930 calldata term, bool removeTerm) external;
    function getRoleMember(bytes32 role, uint256 index) external view returns (address);
}

/// @notice 2026-09-30 audit regressions for the Lista modules (group B-lend2),
///         against the live BSC Moolah + USD1/BTCB LendingBroker fork.
contract ListaAudit20260930Test is ListaModulesBase {
    uint256 constant COLLATERAL_IN = 0.1e18; // BTCB
    uint256 constant BORROW_OUT = 1_000e18; //  USD1

    // ──────────────────── helpers ────────────────────

    /// @dev Maker grants for a [MAKE supply, TAKE borrow] order whose borrow blob is
    ///      `borrowData` (the taker grant is keyed by its hash).
    function _grantsFor(bytes memory borrowData) internal {
        vm.startPrank(maker);
        IERC20(BTCB).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(supplyModule), BTCB, uint160(COLLATERAL_IN), 0);
        IMoolah(MOOLAH).setAuthorization(address(brokerModule), true);
        permit3.approveTaker(address(settlement), address(brokerModule), keccak256(borrowData), uint160(BORROW_OUT), 0);
        vm.stopPrank();
        deal(BTCB, solver, COLLATERAL_IN);
        _approveSolverSide(COLLATERAL_IN, BTCB);
    }

    function _order(bytes memory borrowData, uint256 nonce) internal view returns (Order memory) {
        Item[] memory items = new Item[](2);
        items[0] = Item({
            op: ItemOp.MAKE, module: address(supplyModule), amount: COLLATERAL_IN, recipient: address(0), data: _supplyData()
        });
        items[1] = Item({
            op: ItemOp.TAKE, module: address(brokerModule), amount: BORROW_OUT, recipient: address(0), data: borrowData
        });
        return _order(maker, nonce, USD1, BTCB, BORROW_OUT, COLLATERAL_IN, items);
    }

    function _reprice(uint256 termId, uint256 duration, uint256 apr) internal {
        address bot = IListaBrokerBot20260930(BROKER).getRoleMember(keccak256("BOT"), 0);
        vm.prank(bot);
        IListaBrokerBot20260930(BROKER).updateFixedTermAndRate(
            AuditFixedTermAndRate20260930({termId: termId, duration: duration, apr: apr}), false
        );
    }

    // ──────────────────── L-ML-2 — termId does not pin the terms ────────────────────

    /// The maker signs the live 7-day term; the broker BOT then reprices the SAME
    /// termId in place before the fill. Before the fix the borrow booked the new
    /// APR silently; now the booked position is checked against the signed ceiling.
    function test_audit_L_ML_2_botRepriceAfterSigningReverts() public {
        bytes memory borrowData = _borrowData(); // live apr as maxApr, live duration
        _grantsFor(borrowData);
        Order memory order = _order(borrowData, 1);
        bytes memory sig = _sign(order);

        (uint256 duration, uint256 apr) = _liveTerm(BROKER, TERM_7D);
        uint256 repriced = apr + 0.05e27; // +5% APR, within the contract's 30% bound
        _reprice(TERM_7D, duration, repriced);

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(ListaBrokerModule.TermMismatch.selector, repriced, duration, BORROW_OUT));
        settlement.fill(order, sig, BORROW_OUT);
        assertEq(IListaBrokerViews(BROKER).getUserTotalDebt(maker), 0, "no debt booked at the repriced term");
    }

    /// Same, but the BOT re-durations the termId (7d → 365d) in place.
    function test_audit_L_ML_2_botReDurationAfterSigningReverts() public {
        bytes memory borrowData = _borrowData();
        _grantsFor(borrowData);
        Order memory order = _order(borrowData, 2);
        bytes memory sig = _sign(order);

        (, uint256 apr) = _liveTerm(BROKER, TERM_7D);
        _reprice(TERM_7D, 365 days, apr);

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(ListaBrokerModule.TermMismatch.selector, apr, 365 days, BORROW_OUT));
        settlement.fill(order, sig, BORROW_OUT);
    }

    /// A reprice DOWN is within the maker's ceiling and still fills.
    function test_audit_L_ML_2_cheaperRepriceStillFills() public {
        bytes memory borrowData = _borrowData();
        _grantsFor(borrowData);
        Order memory order = _order(borrowData, 3);
        bytes memory sig = _sign(order);

        (uint256 duration, uint256 apr) = _liveTerm(BROKER, TERM_7D);
        _reprice(TERM_7D, duration, apr - 0.01e27);

        vm.prank(solver);
        settlement.fill(order, sig, BORROW_OUT);
        assertEq(IERC20(USD1).balanceOf(solver), BORROW_OUT, "borrow proceeds delivered");
    }

    // ──────────────────── L-ML-6 — one tranche per order, on request ────────────────────

    /// A maker-signed `totalAmount` makes the broker borrow full-fill only, so a
    /// filler cannot split it into N separately-dated tranches.
    function test_audit_L_ML_6_signedTotalRejectsPartialSlices() public {
        bytes memory borrowData = _borrowBlob(BROKER, TERM_7D, BORROW_OUT);
        _grantsFor(borrowData);
        Order memory order = _order(borrowData, 4);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(FullFillGuard.PartialFillUnsupported.selector, BORROW_OUT / 2, BORROW_OUT)
        );
        settlement.fill(order, sig, BORROW_OUT / 2);

        vm.prank(solver);
        settlement.fill(order, sig, BORROW_OUT);
        assertEq(IListaBroker(BROKER).userFixedPositions(maker).length, 1, "exactly one fixed tranche");
    }

    /// L-ML-8: without the total, partial fills are allowed and each slice books
    /// its OWN fixed position (documented behaviour, previously untested).
    function test_audit_L_ML_8_partialBorrowFillsOpenSeparateTranches() public {
        bytes memory borrowData = _borrowData(); // totalAmount = 0
        _grantsFor(borrowData);
        Order memory order = _order(borrowData, 5);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, BORROW_OUT / 2);
        vm.prank(solver);
        settlement.fill(order, sig, BORROW_OUT / 2);

        uint256[8][] memory positions = IListaBroker(BROKER).userFixedPositions(maker);
        assertEq(positions.length, 2, "one fixed tranche per slice");
        assertEq(positions[0][1] + positions[1][1], BORROW_OUT, "slices sum to the signed total");
        assertEq(IERC20(USD1).balanceOf(solver), BORROW_OUT, "solver paid in full across slices");
    }

    // ──────────────────── L-ML-5 — funding preflight per shape ────────────────────

    function test_audit_L_ML_5_pullRepayReportsPermit3Book() public {
        bytes memory pullRepay = abi.encode(uint8(ListaBrokerModule.Op.Repay), BROKER, USD1, uint256(type(uint128).max));

        (address asset, uint256 available) = brokerModule.fundingSource(maker, pullRepay);
        assertEq(asset, USD1, "asset = loan token");
        assertEq(available, 0, "no grant, no balance: nothing is pullable");

        deal(USD1, maker, 300e18);
        vm.prank(maker);
        permit3.approveToken(address(brokerModule), USD1, 500e18, 0);
        (, available) = brokerModule.fundingSource(maker, pullRepay);
        assertEq(available, 300e18, "min(balance, Permit3 grant to the module)");
    }

    function test_audit_L_ML_5_preFundRepayStillReportsMax() public view {
        uint256 desc = (uint256(1) << 255) | (uint256(1) << 253) | (uint256(uint160(USD1)) << 16)
            | (uint256(ListaBrokerModule.Op.Repay) << 244);
        (address asset, uint256 available) =
            brokerModule.fundingSource(maker, abi.encode(desc, BROKER, USD1, uint256(type(uint128).max)));
        assertEq(asset, USD1);
        assertEq(available, type(uint256).max, "funded by the fill's own delivery");
    }

    // ──────────────────── L-ML-8 — coverage gaps ────────────────────

    /// op 1 (direct Moolah) Full mode — previously only op 2 and native Full were
    /// fork-tested.
    function test_audit_L_ML_8_op1FullModeWithdrawsWholePosition() public {
        uint256 seeded = 0.1e18;
        uint256 forward = 0.04e18;
        _seedCollateral(seeded);
        vm.prank(maker);
        IMoolah(MOOLAH).setAuthorization(address(takerModule), true);

        bytes memory data =
            abi.encode(uint8(1), MOOLAH, _mp(), DustHandler.encodeMode(DustHandler.BalanceMode.Full), forward);
        vm.prank(address(permit3));
        takerModule.takeOnBehalf(maker, forward, solver, data);

        assertEq(_makerCollateral(), 0, "whole position withdrawn");
        assertEq(IERC20(BTCB).balanceOf(solver), forward, "signed amount forwarded");
        assertEq(IERC20(BTCB).balanceOf(maker), seeded - forward, "remainder swept to the maker");
        assertEq(IERC20(BTCB).balanceOf(address(takerModule)), 0, "module drained");
    }

    /// Cross-principal: a victim's standing Moolah grant to the broker module is
    /// unusable by an attacker who self-signs a borrow and self-grants the taker
    /// allowance — the core pins `onBehalfOf = order.maker` and Permit3 keys the
    /// grant by owner, so the attacker can only ever reach their OWN position.
    function test_audit_L_ML_8_attackerCannotBorrowAgainstVictimGrant() public {
        address victim = makeAddr("victim");
        vm.prank(victim);
        IMoolah(MOOLAH).setAuthorization(address(brokerModule), true); // victim's standing grant

        // The attacker IS `maker` here (self-signed order + own taker grant), with
        // no Moolah authorization of their own.
        bytes memory borrowData = _borrowData();
        vm.startPrank(maker);
        permit3.approveTaker(address(settlement), address(brokerModule), keccak256(borrowData), uint160(BORROW_OUT), 0);
        vm.stopPrank();
        deal(BTCB, solver, COLLATERAL_IN);
        _approveSolverSide(COLLATERAL_IN, BTCB);
        vm.startPrank(maker);
        IERC20(BTCB).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(supplyModule), BTCB, uint160(COLLATERAL_IN), 0);
        vm.stopPrank();
        Order memory order = _order(borrowData, 6);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(bytes4(0xea8e4eb5)); // broker: NotAuthorized() — for the ATTACKER's position
        settlement.fill(order, sig, BORROW_OUT);
        assertEq(IListaBrokerViews(BROKER).getUserTotalDebt(victim), 0, "victim untouched");

        // And no path names the victim directly: the module only answers Permit3.
        vm.expectRevert();
        brokerModule.takeOnBehalf(victim, BORROW_OUT, maker, borrowData);
    }
}

/// @notice The same regressions re-run against the CURRENT BSC broker
///         implementation (0xf1db…, live since the 2026-08 upgrade) — the default
///         pin exercises the pre-upgrade 0xf71b… (audit 2026-09-30 L-ML-8).
contract ListaAuditLiveImpl20260930Test is ListaAudit20260930Test {
    /// @dev 2026-10-01, after the broker upgrade.
    function _forkBlock() internal pure override returns (uint256) {
        return 125_150_000;
    }
}
