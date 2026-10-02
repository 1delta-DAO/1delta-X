// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {Permit3} from "@core/permit3/Permit3.sol";

import {TellerPreFundModule} from "../../src/TellerPreFundModules.sol";
import {TellerRepayModule, TellerPoolDepositModule} from "../../src/TellerModules.sol";
import {MockERC20, MockTellerV2, MockTellerPool, RevertingPermit3} from "./TellerPreFundModules.t.sol";

/// @title 2026-09-30 audit, L-CMT-1 / L-CMT-5 — Teller repay clamps at the LIVE debt.
/// @notice The deployed TellerV2 `repayLoan(bidId, X)` transfers the WHOLE `X` to
///         the lender and marks the loan PAID once `X ≥ owed` — it does not clamp.
///         Both repay modules used to pass the whole held amount with `full = false`,
///         so the "unused buffer is swept back" promise paid the maker's surplus to
///         the lender. The mock venue ({MockTellerV2}) now models the deployed
///         (uncapped) behaviour; these tests pin the SAFE end state: the lender
///         receives exactly what is owed and the surplus reaches the maker. The fork
///         twin (`test/fork/TellerRepayClampFork.t.sol`) proves the same against the
///         live mainnet TellerV2.
contract AuditTellerRepayClampTest is Test {
    TellerPreFundModule preFund;
    TellerRepayModule repayModule;
    TellerPoolDepositModule depositModule;
    Permit3 permit3;
    MockERC20 asset;
    MockTellerV2 tellerV2;
    MockTellerPool pool;

    address settlement = address(0x5E77);
    address maker = address(0xA11CE);
    uint256 constant BID_ID = 42;

    function setUp() public {
        asset = new MockERC20();
        tellerV2 = new MockTellerV2(asset);
        pool = new MockTellerPool(asset);
        permit3 = new Permit3();
        // The pre-fund module must never touch Permit3 — reverting stub.
        preFund = new TellerPreFundModule(address(new RevertingPermit3()), settlement);
        repayModule = new TellerRepayModule(address(permit3), settlement);
        depositModule = new TellerPoolDepositModule(address(permit3), settlement);
        tellerV2.setBorrower(BID_ID, maker);
    }

    function _repayData(bool full) internal view returns (bytes memory) {
        uint256 desc = (uint256(1) << 255) | (uint256(1) << 253) | (uint256(uint160(address(asset))) << 16)
            | (uint256(TellerPreFundModule.Op.Repay) << 244);
        return abi.encode(desc, address(tellerV2), address(asset), BID_ID, full);
    }

    function _grantPull(address module, uint256 amount) internal {
        asset.mint(maker, amount);
        vm.startPrank(maker);
        asset.approve(address(permit3), type(uint256).max);
        permit3.approveToken(module, address(asset), uint160(amount), 0);
        vm.stopPrank();
    }

    // ──────────────── pre-fund module ────────────────

    /// The finding's scenario: an auction delivered 1,000 against a live debt of 800
    /// and the maker signed `full = false` (the only setting that does not revert on a
    /// late, below-debt fill). Before the fix the module called `repayLoan(42, 1000)`
    /// and the venue kept all 1,000.
    function test_audit_L_CMT_1_preFundPartial_overDelivery_sweptToMaker() public {
        uint256 debt = 800e6;
        uint256 forAmount = 1_000e6;
        uint256 dust = 3; // another fill's residue, must survive
        tellerV2.setOwed(BID_ID, debt);
        asset.mint(address(preFund), dust);
        asset.mint(address(preFund), forAmount);

        vm.prank(settlement);
        preFund.makeOnBehalf(maker, forAmount, _repayData(false));

        assertEq(tellerV2.owed(BID_ID), 0, "loan closed");
        assertEq(asset.balanceOf(address(tellerV2)), debt, "lender received EXACTLY the owed amount");
        assertEq(asset.balanceOf(maker), forAmount - debt, "surplus swept back to the maker");
        assertEq(asset.balanceOf(address(preFund)), dust, "floor untouched");
        assertEq(asset.allowance(address(preFund), address(tellerV2)), 0, "scoped approval cleared");
        assertEq(tellerV2.repayLoanCalls(), 0, "an amount covering the debt never reaches repayLoan");
        assertEq(tellerV2.repayLoanFullCalls(), 1, "routed to repayLoanFull");
    }

    /// Exactly the owed amount is the boundary: it closes via `repayLoanFull` too.
    function test_audit_L_CMT_1_preFundPartial_exactlyOwed_closes() public {
        tellerV2.setOwed(BID_ID, 800e6);
        asset.mint(address(preFund), 800e6);

        vm.prank(settlement);
        preFund.makeOnBehalf(maker, 800e6, _repayData(false));

        assertEq(tellerV2.owed(BID_ID), 0, "loan closed");
        assertEq(asset.balanceOf(maker), 0, "nothing to sweep");
        assertEq(tellerV2.repayLoanFullCalls(), 1, "closed through the full-repay entrypoint");
    }

    /// Below the debt the partial path is unchanged: `repayLoan(forAmount)`.
    function test_audit_L_CMT_1_preFundPartial_belowOwed_staysPartial() public {
        tellerV2.setOwed(BID_ID, 1_000e6);
        asset.mint(address(preFund), 400e6);

        vm.prank(settlement);
        preFund.makeOnBehalf(maker, 400e6, _repayData(false));

        assertEq(tellerV2.owed(BID_ID), 600e6, "partial repay applied");
        assertEq(tellerV2.repayLoanCalls(), 1, "partial entrypoint");
        assertEq(asset.balanceOf(address(preFund)), 0, "module drained");
    }

    /// `full = true` below the owed figure still fails closed (the scoped approval
    /// is the delivery, `repayLoanFull` wants more) — the maker asked for a close.
    function test_audit_L_CMT_1_preFundFull_belowOwed_failsClosed() public {
        tellerV2.setOwed(BID_ID, 1_000e6);
        asset.mint(address(preFund), 400e6);

        vm.prank(settlement);
        vm.expectRevert();
        preFund.makeOnBehalf(maker, 400e6, _repayData(true));
    }

    // ──────────────── pull module ────────────────

    /// A buffered partial repay (owed + 50, `full = false`) through the PULL module:
    /// the buffer used to go to the lender.
    function test_audit_L_CMT_1_pullPartial_buffer_sweptToMaker() public {
        uint256 debt = 800e6;
        uint256 buffered = debt + 50e6;
        tellerV2.setOwed(BID_ID, debt);
        _grantPull(address(repayModule), buffered);

        vm.prank(settlement);
        repayModule.makeOnBehalf(maker, buffered, abi.encode(address(tellerV2), address(asset), BID_ID, false));

        assertEq(tellerV2.owed(BID_ID), 0, "loan closed");
        assertEq(asset.balanceOf(address(tellerV2)), debt, "lender received EXACTLY the owed amount");
        assertEq(asset.balanceOf(maker), 50e6, "buffer swept back to the maker");
        assertEq(asset.balanceOf(address(repayModule)), 0, "module holds nothing");
        assertEq(asset.allowance(address(repayModule), address(tellerV2)), 0, "scoped approval cleared");
    }

    /// L-CMT-5: the pull repay module's partial path, functionally (it only had a
    /// direct-call rejection test before).
    function test_audit_L_CMT_5_pullPartial_belowOwed_repaysExactly() public {
        tellerV2.setOwed(BID_ID, 1_000e6);
        _grantPull(address(repayModule), 300e6);

        vm.prank(settlement);
        repayModule.makeOnBehalf(maker, 300e6, abi.encode(address(tellerV2), address(asset), BID_ID, false));

        assertEq(tellerV2.owed(BID_ID), 700e6, "partial repay applied");
        assertEq(asset.balanceOf(maker), 0, "nothing to sweep");
        assertEq(asset.balanceOf(address(repayModule)), 0, "module holds nothing");
    }

    /// L-CMT-5: the pull repay module's full path sweeps the unused buffer.
    function test_audit_L_CMT_5_pullFull_sweepsBuffer() public {
        tellerV2.setOwed(BID_ID, 800e6);
        _grantPull(address(repayModule), 1_000e6);

        vm.prank(settlement);
        repayModule.makeOnBehalf(maker, 1_000e6, abi.encode(address(tellerV2), address(asset), BID_ID, true));

        assertEq(tellerV2.owed(BID_ID), 0, "loan closed");
        assertEq(asset.balanceOf(maker), 200e6, "buffer swept back");
    }

    /// L-CMT-5: the pull pool-deposit module, functionally.
    function test_audit_L_CMT_5_pullDeposit_creditsMaker() public {
        _grantPull(address(depositModule), 500e6);

        vm.prank(settlement);
        depositModule.makeOnBehalf(maker, 500e6, abi.encode(address(pool), address(asset)));

        assertEq(pool.sharesOf(maker), 500e6, "maker credited");
        assertEq(asset.balanceOf(address(depositModule)), 0, "module holds nothing");
        assertEq(asset.allowance(address(depositModule), address(pool)), 0, "scoped approval cleared");
    }

    // ──────────────── L-CENSUS-8 (3): the loan is bound to the maker ────────────────

    uint256 constant STRANGER_BID = 77;

    /// A signed `bidId` that is a STRANGER's loan used to spend the maker's funds
    /// retiring that stranger's debt (repay is permissionless on Teller). The pull
    /// module now refuses: the maker keeps its funds, the stranger's loan is untouched.
    function test_audit_L_CENSUS_8_pullRepayRefusesStrangersLoan() public {
        address stranger = address(0x5742);
        tellerV2.setBorrower(STRANGER_BID, stranger);
        tellerV2.setOwed(STRANGER_BID, 800e6);
        _grantPull(address(repayModule), 1_000e6);

        vm.prank(settlement);
        try repayModule.makeOnBehalf(maker, 1_000e6, abi.encode(address(tellerV2), address(asset), STRANGER_BID, false))
        {} catch {}

        assertEq(tellerV2.owed(STRANGER_BID), 800e6, "stranger's loan untouched");
        assertEq(asset.balanceOf(maker), 1_000e6, "maker keeps its funds");
    }

    /// Same binding on the pre-fund module: the delivered funds stay on the module
    /// (the fill reverts) rather than retiring a stranger's loan.
    function test_audit_L_CENSUS_8_preFundRepayRefusesStrangersLoan() public {
        address stranger = address(0x5742);
        tellerV2.setBorrower(STRANGER_BID, stranger);
        tellerV2.setOwed(STRANGER_BID, 800e6);
        asset.mint(address(preFund), 1_000e6);
        uint256 desc = (uint256(1) << 255) | (uint256(1) << 253) | (uint256(uint160(address(asset))) << 16)
            | (uint256(TellerPreFundModule.Op.Repay) << 244);

        vm.prank(settlement);
        try preFund.makeOnBehalf(
            maker, 1_000e6, abi.encode(desc, address(tellerV2), address(asset), STRANGER_BID, false)
        ) {} catch {}

        assertEq(tellerV2.owed(STRANGER_BID), 800e6, "stranger's loan untouched");
        assertEq(asset.balanceOf(address(tellerV2)), 0, "nothing paid to the venue");
    }
}
