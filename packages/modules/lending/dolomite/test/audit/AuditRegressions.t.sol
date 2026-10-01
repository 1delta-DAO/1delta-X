// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";

import {
    AccountInfo,
    AssetAmount,
    AssetDenomination,
    AssetReference,
    ActionType,
    ActionArgs
} from "../../src/interfaces/IDolomite.sol";
import {DolomiteOperatorModule} from "../../src/DolomiteOperatorModule.sol";
import {DolomiteModulesBase} from "../shared/DolomiteModulesBase.t.sol";

/// @title DolomiteAccountNumberConventionTest
/// @notice 2026-09-30 audit L-ED-2: every Dolomite debt test used to MOCK the
///         risk-override setter away, on a misdiagnosis ("the setter rejects raw
///         test-built debt on any sub-account"). The real cause was the harness's
///         account number 1: the setter live at the fork block requires
///         `accountNumber >= 100` for any account holding debt. The harness now signs
///         100 and no test mocks the setter; this file pins the convention against
///         the LIVE setter.
contract DolomiteAccountNumberConventionTest is DolomiteModulesBase {
    function _directOpen(uint256 accountNumber) internal {
        deal(COLL, maker, 1 ether);
        vm.startPrank(maker);
        IERC20(COLL).approve(address(DOLOMITE), 1 ether);
        AccountInfo[] memory accounts = new AccountInfo[](1);
        accounts[0] = AccountInfo(maker, accountNumber);
        ActionArgs[] memory actions = new ActionArgs[](2);
        actions[0] = ActionArgs(
            ActionType.Deposit, 0, AssetAmount(true, AssetDenomination.Wei, AssetReference.Delta, 1 ether),
            COLL_MARKET, 0, maker, 0, ""
        );
        actions[1] = ActionArgs(
            ActionType.Withdraw, 0, AssetAmount(false, AssetDenomination.Wei, AssetReference.Delta, 500e6),
            DEBT_MARKET, 0, maker, 0, ""
        );
        DOLOMITE.operate(accounts, actions);
        vm.stopPrank();
    }

    /// The diagnosis, pinned: a sub-account BELOW 100 cannot carry debt on the setter
    /// live at this block.
    function test_audit_L_ED_2_accountBelow100_cannotCarryDebt_onLiveSetter() public {
        try this.directOpen(1) {
            fail("account 1 carried debt");
        } catch (bytes memory reason) {
            assertTrue(_contains(reason, "Invalid account for debt"), "the setter's account-number cutoff");
        }
    }

    function _contains(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        if (needle.length > hay.length) return false;
        for (uint256 i; i <= hay.length - needle.length; ++i) {
            bool ok = true;
            for (uint256 j; j < needle.length; ++j) {
                if (hay[i + j] != needle[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }

    /// A borrow-position account (>= 100) carries debt with the setter UNMOCKED.
    function test_audit_L_ED_2_account100_carriesDebt_unmocked() public {
        _directOpen(ACCOUNT);
        assertEq(_debtOf(maker), 500e6, "debt opened on the borrow-position account");
    }

    /// The module's own debt op, unmocked, on account 100.
    function test_audit_L_ED_2_moduleBorrow_unmocked() public {
        _seedDolomiteCollateral(1 ether);
        bytes memory d = _borrowData();
        vm.prank(maker);
        permit3.approveTaker(address(settlement), address(operatorModule), keccak256(d), 300e6, 0);
        vm.prank(address(settlement));
        permit3.take(address(operatorModule), maker, 300e6, address(0xCAFE), d);
        assertEq(_debtOf(maker), 300e6, "module borrow ran against the real risk-override path");
        assertEq(IERC20(DEBT).balanceOf(address(0xCAFE)), 300e6, "proceeds delivered");
    }

    function directOpen(uint256 accountNumber) external {
        _directOpen(accountNumber);
    }
}

/// @title DolomiteMarketTokenBindingTest
/// @notice 2026-09-30 audit G-BYTE_MAP-7: every blob names the asset twice (market
///         id + token) and nothing bound them, so the lens views trusted a `token`
///         the venue never delivered. Every entrypoint now reverts
///         `MarketTokenMismatch` and the views report the registry token.
contract DolomiteMarketTokenBindingTest is DolomiteModulesBase {
    /// Borrow from the USDC market while SIGNING the token as WETH: the venue would
    /// pay USDC to Settlement while the lens/core expected WETH.
    function test_audit_G_BYTE_MAP_7_borrow_signedTokenNotMarketToken_reverts() public {
        _seedDolomiteCollateral(1 ether);
        bytes memory d =
            abi.encode(uint8(DolomiteOperatorModule.Op.Borrow), address(DOLOMITE), DEBT_MARKET, COLL, ACCOUNT);
        vm.prank(maker);
        permit3.approveTaker(address(settlement), address(operatorModule), keccak256(d), 300e6, 0);
        vm.prank(address(settlement));
        vm.expectRevert(
            abi.encodeWithSignature("MarketTokenMismatch(uint256,address,address)", DEBT_MARKET, COLL, DEBT)
        );
        permit3.take(address(operatorModule), maker, 300e6, address(0xCAFE), d);
        assertEq(_debtOf(maker), 0, "no debt opened");
    }

    /// The same on the fused BatchOpen (borrow side mis-signed).
    function test_audit_G_BYTE_MAP_7_batchOpen_borrowTokenMismatch_reverts() public {
        DolomiteOperatorModule.BatchData memory p = DolomiteOperatorModule.BatchData({
            op: uint256(DolomiteOperatorModule.Op.BatchOpen),
            dolomite: address(DOLOMITE),
            collMarketId: COLL_MARKET,
            collToken: COLL,
            borrowMarketId: DEBT_MARKET,
            borrowToken: COLL, // wrong: market 2 is USDC
            accountNumber: ACCOUNT,
            sideAmount: 1 ether,
            totalAmount: 300e6
        });
        bytes memory d = abi.encode(p);
        vm.prank(maker);
        permit3.approveTaker(address(settlement), address(operatorModule), keccak256(d), 300e6, 0);
        vm.prank(address(settlement));
        vm.expectRevert(
            abi.encodeWithSignature("MarketTokenMismatch(uint256,address,address)", DEBT_MARKET, COLL, DEBT)
        );
        permit3.take(address(operatorModule), maker, 300e6, address(0xCAFE), d);
    }

    /// The lens views now report what the venue delivers, not what the blob says.
    function test_audit_G_BYTE_MAP_7_proceedsAsset_reportsRegistryToken() public view {
        bytes memory d =
            abi.encode(uint8(DolomiteOperatorModule.Op.Borrow), address(DOLOMITE), DEBT_MARKET, COLL, ACCOUNT);
        assertEq(operatorModule.proceedsAsset(d), DEBT, "the USDC market delivers USDC, whatever the blob says");
    }

    /// `Open` no longer reports `address(0)`: the borrow market's token is read.
    function test_audit_G_BYTE_MAP_7_openProceedsAsset_isTheBorrowToken() public view {
        bytes memory d = abi.encode(
            DolomiteOperatorModule.OpenData({
                forDesc: (uint256(1) << 255) | (uint256(DolomiteOperatorModule.Op.Open) << 244),
                forCap: 0,
                dolomite: address(DOLOMITE),
                collMarketId: COLL_MARKET,
                collToken: COLL,
                borrowMarketId: DEBT_MARKET,
                accountNumber: ACCOUNT
            })
        );
        assertEq(operatorModule.proceedsAsset(d), DEBT, "Open reports the borrow market's token");
    }
}

/// @title DolomiteSeamIsolationTest
/// @notice 2026-09-30 audit L-ED-5: Dolomite is the one module hosting all THREE
///         seams (MAKE, plain TAKE, TAKE_FOR) with MAKE and plain TAKE sharing the
///         `>> 253 == 0` data space — a MAKE item consumes no taker grant, so the op
///         table is the only thing stopping a MAKE item from running Borrow/Withdraw
///         on the maker's unscoped operator flag. These are the executing negative
///         tests that property had only by review (Euler's equivalents ported, plus
///         the MAKE-seam and pre-fund token cases).
contract DolomiteSeamIsolationTest is DolomiteModulesBase {
    address attacker = address(0xBAD);

    function _single(DolomiteOperatorModule.Op op) internal view returns (bytes memory) {
        return abi.encode(uint8(op), address(DOLOMITE), DEBT_MARKET, DEBT, ACCOUNT);
    }

    // ── MAKE seam ──

    function test_audit_L_ED_5_make_rejectsNonSettlement() public {
        vm.prank(attacker);
        vm.expectRevert(PreFundGuard.OnlySettlement.selector);
        operatorModule.makeOnBehalf(maker, 1e6, _depositData());
    }

    function test_audit_L_ED_5_make_rejectsEveryTakeOp() public {
        DolomiteOperatorModule.Op[5] memory ops = [
            DolomiteOperatorModule.Op.Borrow,
            DolomiteOperatorModule.Op.Withdraw,
            DolomiteOperatorModule.Op.BatchOpen,
            DolomiteOperatorModule.Op.BatchClose,
            DolomiteOperatorModule.Op.Open
        ];
        for (uint256 i; i < ops.length; ++i) {
            vm.prank(address(settlement));
            vm.expectRevert(abi.encodeWithSelector(DolomiteOperatorModule.BadOp.selector, uint256(ops[i])));
            operatorModule.makeOnBehalf(maker, 1e6, _single(ops[i]));
        }
    }

    // ── plain TAKE seam ──

    function test_audit_L_ED_5_take_rejectsMakeOps() public {
        DolomiteOperatorModule.Op[3] memory ops =
            [DolomiteOperatorModule.Op.Deposit, DolomiteOperatorModule.Op.Repay, DolomiteOperatorModule.Op.Open];
        for (uint256 i; i < ops.length; ++i) {
            vm.prank(address(permit3));
            vm.expectRevert(abi.encodeWithSelector(DolomiteOperatorModule.BadOp.selector, uint256(ops[i])));
            operatorModule.takeOnBehalf(maker, 1e6, attacker, _single(ops[i]));
        }
    }

    function test_audit_L_ED_5_take_rejectsDescriptorHeadedBlob() public {
        bytes memory d = abi.encode(
            (uint256(1) << 255) | (uint256(DolomiteOperatorModule.Op.Borrow) << 244),
            address(DOLOMITE),
            DEBT_MARKET,
            DEBT,
            ACCOUNT
        );
        vm.prank(address(permit3));
        vm.expectRevert(PreFundGuard.PreFundDescriptorNotAllowed.selector);
        operatorModule.takeOnBehalf(maker, 1e6, attacker, d);
    }

    // ── TAKE_FOR seam ──

    function _openData(uint256 forDesc, address collToken) internal view returns (bytes memory) {
        return abi.encode(
            DolomiteOperatorModule.OpenData({
                forDesc: forDesc,
                forCap: 0,
                dolomite: address(DOLOMITE),
                collMarketId: COLL_MARKET,
                collToken: collToken,
                borrowMarketId: DEBT_MARKET,
                accountNumber: ACCOUNT
            })
        );
    }

    function _legRef(DolomiteOperatorModule.Op op, bool preFund, address token) internal pure returns (uint256) {
        return (uint256(1) << 255) | (uint256(op) << 244)
            | (preFund ? (uint256(1) << 253) | (uint256(uint160(token)) << 16) : 0);
    }

    function test_audit_L_ED_5_takeFor_rejectsForeignSpender() public {
        vm.prank(address(permit3));
        vm.expectRevert(PreFundGuard.OnlySettlement.selector);
        operatorModule.takeForOnBehalf(
            attacker, maker, 1e6, 1 ether, attacker, _openData(_legRef(DolomiteOperatorModule.Op.Open, true, COLL), COLL)
        );
    }

    function test_audit_L_ED_5_takeFor_rejectsLiteralDescriptor() public {
        vm.prank(address(permit3));
        vm.expectRevert(PreFundGuard.LiteralDescriptorNotAllowed.selector);
        operatorModule.takeForOnBehalf(address(settlement), maker, 1e6, 1 ether, attacker, _openData(1 ether, COLL));
    }

    function test_audit_L_ED_5_takeFor_rejectsNonOpenOps() public {
        DolomiteOperatorModule.Op[4] memory ops = [
            DolomiteOperatorModule.Op.Borrow,
            DolomiteOperatorModule.Op.Withdraw,
            DolomiteOperatorModule.Op.Deposit,
            DolomiteOperatorModule.Op.BatchOpen
        ];
        for (uint256 i; i < ops.length; ++i) {
            vm.prank(address(permit3));
            vm.expectRevert(abi.encodeWithSelector(DolomiteOperatorModule.BadOp.selector, uint256(ops[i])));
            operatorModule.takeForOnBehalf(
                address(settlement), maker, 1e6, 1 ether, attacker, _openData(_legRef(ops[i], true, COLL), COLL)
            );
        }
    }

    /// The module-side half of the pre-fund token binding (F27/H-1): a descriptor
    /// naming USDC funds a WETH collateral leg → `FundingTokenMismatch`, before any
    /// balance is spent. No test in the tree had executed this guard.
    function test_audit_L_ED_5_preFundOpen_fundingTokenMismatch_reverts() public {
        deal(COLL, address(operatorModule), 1 ether);
        vm.prank(address(permit3));
        vm.expectRevert(PreFundGuard.FundingTokenMismatch.selector);
        operatorModule.takeForOnBehalf(
            address(settlement),
            maker,
            1e6,
            1 ether,
            attacker,
            _openData(_legRef(DolomiteOperatorModule.Op.Open, true, DEBT), COLL)
        );
        assertEq(IERC20(COLL).balanceOf(address(operatorModule)), 1 ether, "nothing spent");
    }

    /// Sanity: the error the seam checks above all route through is the shared one.
    function test_audit_L_ED_5_take_rejectsNonPermit3() public {
        vm.prank(attacker);
        vm.expectRevert(PreFundModuleBase.OnlyPermit3.selector);
        operatorModule.takeForOnBehalf(
            address(settlement), maker, 1e6, 1 ether, attacker, _openData(_legRef(DolomiteOperatorModule.Op.Open, true, COLL), COLL)
        );
    }
}
