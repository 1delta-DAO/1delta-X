// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Item, ItemOp, Order, LegOut} from "@core/settlement/Settlement.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {MidnightPreFundModule} from "../src/MidnightPreFundModules.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";
import {MidnightModulesBase} from "./shared/MidnightModulesBase.t.sol";

/// @dev The ONE-SIDED pre-fund composites on Midnight: "supply whatever the
/// conversion delivered as collateral" / "repay whatever the conversion
/// delivered", with ZERO receive-side approvals. The converted output leg is
/// delivered straight to the module (`recipient = module`), the core sizes
/// `forAmount` to exactly that delivery, and the maker's only grants are the
/// input-leg approval they had anyway plus a signable taker allowance. The
/// received asset — the collateral on a supply, the loan token on a repay — is
/// never approved to anything, anywhere, and neither op needs Midnight's
/// `setIsAuthorized` (both are permissionless benign inflows).
///
/// End-to-end over the real Settlement + Permit3 and the mock Midnight
/// singleton, like every suite in this package. The maker holds NO Permit3 token
/// allowance to the pre-fund modules (asserted), so the fills succeeding is the
/// proof that the funding side never calls `permit3.transferFrom`.
contract MidnightPreFundOneSidedTest is MidnightModulesBase {
    MidnightPreFundModule preFund;

    function setUp() public override {
        super.setUp();
        preFund = new MidnightPreFundModule(address(permit3), address(settlement), address(midnight));
        vm.label(address(preFund), "pushSupplyModule");
        vm.label(address(preFund), "pushRepayModule");
    }

    /// @dev `(1 << 255) | index` — fund from `legsOut[index]`.
    function _forLeg(uint256 index, address token) internal pure returns (uint256) {
        // bit 255 = leg reference; bit 253 = the PRE-FUND shape, which makes the core
        // require `legsOut[index].recipient == module` (F27/H-1).
        return (uint256(1) << 255) | (uint256(1) << 253) | (uint256(uint160(token)) << 16) | index;
    }

    /// @dev Same leg reference, with the op in descriptor bits [244,252).
    function _forLegOp(uint256 index, address token, MidnightPreFundModule.Op op) internal pure returns (uint256) {
        return _forLeg(index, token) | (uint256(op) << 244);
    }

    /// @dev Address the single output leg to `to` — the pre-fund shape.
    function _routeLegOut(Order memory o, address token, uint256 amount, address to) internal pure {
        LegOut[] memory legsOut = new LegOut[](1);
        legsOut[0] = LegOut(token, amount, 0, to);
        o.legsOut = PackedEncode.legsOut(legsOut);
    }

    function _preFundSupplyData() internal view returns (bytes memory) {
        return abi.encode(_forLeg(0, address(COLL)), _market(), uint256(0));
    }

    function _preFundRepayData() internal view returns (bytes memory) {
        return abi.encode(_forLegOp(0, address(LOAN), MidnightPreFundModule.Op.Repay), _market());
    }

    // ── SWAP & SUPPLY COLLATERAL. The maker converts LOAN (the one asset they
    //    hold and approve) into Midnight collateral. COLL — the asset they
    //    RECEIVE — has its ERC20 approval to Permit3 revoked outright and no
    //    Permit3 book entry to anything: the receive side is strictly empty. ──
    function test_preFundSupplyCollateral_zeroReceiveSideApprovals() public {
        uint256 loanIn = 900e6;
        uint256 collOut = 1.2e18;

        LOAN.mint(maker, loanIn);
        COLL.mint(solver, collOut);

        bytes memory data = _preFundSupplyData();
        _makerApproveToken(address(settlement), address(LOAN), loanIn); // the input leg
        _makerApproveTaker(address(preFund), keccak256(data), loanIn);
        vm.prank(maker);
        COLL.approve(address(permit3), 0); // receive side stripped bare

        Item[] memory items = new Item[](1);
        // `amount` is the PACING total (the anchor) — this module moves nothing out.
        items[0] = _item(ItemOp.MAKE, address(preFund), 0, data);
        Order memory order = _order(maker, 21, address(LOAN), address(COLL), loanIn, collOut, items);
        _routeLegOut(order, address(COLL), collOut, address(preFund));
        bytes memory sig = _sign(order);

        // The funding side holds no pull rights at all.
        (uint160 amt,) = permit3.tokenAllowance(maker, address(preFund), address(COLL));
        assertEq(amt, 0, "no Permit3 book entry for the receive asset");

        vm.prank(solver);
        settlement.fill(order, sig, loanIn);

        assertEq(_collateralOf(maker), collOut, "the delivered leg became collateral");
        assertEq(COLL.balanceOf(maker), 0, "the maker's wallet never saw the COLL");
        assertEq(COLL.balanceOf(address(preFund)), 0, "module drained");
        assertEq(LOAN.balanceOf(solver), loanIn, "solver received the input leg");
        assertEq(COLL.allowance(address(preFund), address(midnight)), 0, "scoped approval cleared");
    }

    // ── Partial fills pace naturally: each slice funds exactly that slice's
    //    delivered leg, and the slices sum EXACTLY to the signed total. ──
    function test_preFundSupplyCollateral_partialFills_accumulateExactly() public {
        uint256 loanIn = 900e6;
        uint256 collOut = 1.2e18;

        LOAN.mint(maker, loanIn);
        COLL.mint(solver, collOut);

        bytes memory data = _preFundSupplyData();
        _makerApproveToken(address(settlement), address(LOAN), loanIn);
        _makerApproveTaker(address(preFund), keccak256(data), loanIn);

        Item[] memory items = new Item[](1);
        items[0] = _item(ItemOp.MAKE, address(preFund), 0, data);
        Order memory order = _order(maker, 22, address(LOAN), address(COLL), loanIn, collOut, items);
        _routeLegOut(order, address(COLL), collOut, address(preFund));
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, loanIn / 3);
        assertEq(_collateralOf(maker), collOut / 3, "first slice supplied its own delivery");

        vm.prank(solver);
        settlement.fill(order, sig, loanIn - loanIn / 3);
        assertEq(_collateralOf(maker), collOut, "slices sum exactly to the signed leg");
        assertEq(COLL.balanceOf(address(preFund)), 0, "module drained across slices");
    }

    // ── SWAP & REPAY. The maker converts COLL into retiring their LOAN debt.
    //    The loan token is the canonical never-approved asset: its ERC20 approval
    //    to Permit3 is revoked to prove the point. Over-delivery (1000 delivered
    //    vs 800 owed) is swept to the maker — the surplus is theirs. ──
    function test_preFundRepay_capsAtDebt_andSweepsSurplusToMaker() public {
        uint256 debtUnits = 800e6;
        uint256 loanOut = 1_000e6; // delivered conversion output — overshoots the debt
        uint256 collIn = 1e18;

        midnight.seedDebt(_market(), maker, debtUnits);
        COLL.mint(maker, collIn);
        LOAN.mint(solver, loanOut);

        bytes memory data = _preFundRepayData();
        _makerApproveToken(address(settlement), address(COLL), collIn); // the input leg
        _makerApproveTaker(address(preFund), keccak256(data), collIn);
        vm.prank(maker);
        LOAN.approve(address(permit3), 0); // receive side stripped bare

        Item[] memory items = new Item[](1);
        items[0] = _item(ItemOp.MAKE, address(preFund), 0, data);
        Order memory order = _order(maker, 23, address(COLL), address(LOAN), collIn, loanOut, items);
        _routeLegOut(order, address(LOAN), loanOut, address(preFund));
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, collIn);

        assertEq(_debtOf(maker), 0, "the debt is retired in full");
        assertEq(LOAN.balanceOf(maker), loanOut - debtUnits, "the surplus was swept to the maker");
        assertEq(LOAN.balanceOf(address(preFund)), 0, "module drained");
        assertEq(COLL.balanceOf(solver), collIn, "solver received the input leg");
        assertEq(LOAN.allowance(address(preFund), address(midnight)), 0, "scoped approval cleared");
    }

    // ──────────────────── security gates (direct calls) ────────────────────

    function test_preFundModules_reject_non_permit3() public {
        vm.startPrank(address(0xBAD));
        vm.expectRevert(PreFundGuard.OnlySettlement.selector);
        preFund.makeOnBehalf(maker, 1, _preFundSupplyData());
        vm.expectRevert(PreFundGuard.OnlySettlement.selector);
        preFund.makeOnBehalf(maker, 1, _preFundRepayData());
        vm.stopPrank();
    }

    function test_preFundModules_reject_non_legRef_descriptors() public {
        // Literal (top bit clear) and balance-relative (top two bits set): neither
        // is sized to a delivery this module received.
        bytes memory literalSupply = abi.encode(uint256(1e18), _market(), uint256(0));
        bytes memory balanceRepay = abi.encode((uint256(3) << 254) | uint160(address(LOAN)), _market());

        vm.startPrank(address(settlement));
        vm.expectRevert(PreFundGuard.PreFundDescriptorRequired.selector);
        preFund.makeOnBehalf(maker, 1, literalSupply);
        vm.expectRevert(PreFundGuard.PreFundDescriptorRequired.selector);
        preFund.makeOnBehalf(maker, 1, balanceRepay);
        vm.stopPrank();
    }

    // ──────────────────── funding-source preflight ────────────────────

    function test_fundingSource_views() public view {
        (address a1, uint256 avail1) = preFund.fundingSource(maker, _preFundSupplyData());
        assertEq(a1, address(COLL));
        assertEq(avail1, type(uint256).max, "funded by the fill's own delivery");

        (address a2, uint256 avail2) = preFund.fundingSource(maker, _preFundRepayData());
        assertEq(a2, address(LOAN));
        assertEq(avail2, type(uint256).max);
    }
}
