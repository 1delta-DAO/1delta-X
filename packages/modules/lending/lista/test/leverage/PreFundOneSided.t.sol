// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, LegOut} from "@core/settlement/Settlement.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {ListaPreFundModule} from "../../src/ListaPreFundModules.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";
import {ListaModulesBase, IListaBrokerViews} from "../shared/ListaModulesBase.t.sol";

/// @dev The bare FLEX (dynamic) borrow — `msg.sender`-only, so it is out of
///      module scope but exactly right for SEEDING the maker's flex debt here
///      (selector 0xc5ebeaec, verified present on the deployed broker
///      implementation 0xf71b…709f).
interface IListaBrokerFlex {
    function borrow(uint256 amount) external;
}

/// @dev The ONE-SIDED pre-fund composites on Lista (Moolah + LendingBroker):
/// "supply-collateral whatever the conversion delivered" / "repay whatever the
/// conversion delivered", with ZERO receive-side approvals. The converted output
/// leg is delivered straight to the module (`recipient = module`), the core
/// sizes `forAmount` to exactly that delivery, and the maker's only grants are
/// the input-leg approval they had anyway plus a signable taker allowance. The
/// received asset — BTCB on a swap-and-collateralise, USD1 on a swap-and-repay —
/// is never approved to anything, anywhere, and (Moolah `supplyCollateral` and
/// the broker's repays being permissionless on behalf) needs no Moolah
/// `setAuthorization` either: the receive side is empty end to end.
contract ListaPreFundOneSidedTest is ListaModulesBase {
    ListaPreFundModule preFund;

    uint256 constant USD1_IN = 1_000e18; //  maker's equity sold on the supply flow
    uint256 constant BTCB_OUT = 0.01e18; //  delivered conversion output (~$1.1k)

    function setUp() public override {
        super.setUp();
        preFund = new ListaPreFundModule(address(permit3), address(settlement));
        }

    /// @dev `(1 << 255) | index` — fund from `legsOut[index]`.
    function _forLeg(uint256 index, address token) internal pure returns (uint256) {
        // bit 255 = leg reference; bit 253 = the PRE-FUND shape, which makes the core
        // require `legsOut[index].recipient == module` (F27/H-1).
        return (uint256(1) << 255) | (uint256(1) << 253) | (uint256(uint160(token)) << 16) | index;
    }

    /// @dev Same leg reference, with the op in descriptor bits [244,252).
    function _forLegOp(uint256 index, address token, ListaPreFundModule.Op op) internal pure returns (uint256) {
        return _forLeg(index, token) | (uint256(op) << 244);
    }

    /// @dev Push supply blob: descriptor word FIRST, then the Moolah singleton,
    ///      then the market (224 bytes — the Morpho push byte map).
    function _preFundSupplyData() internal pure returns (bytes memory) {
        return abi.encode(_forLeg(0, BTCB), MOOLAH, _mp());
    }

    /// @dev Push repay blob targeting the FLEX position (dynamic sentinel).
    function _preFundRepayData() internal pure returns (bytes memory) {
        return abi.encode(_forLegOp(0, USD1, ListaPreFundModule.Op.BrokerRepay), BROKER, USD1, uint256(type(uint128).max));
    }

    /// @dev Address one output leg to `to` (the pre-fund shape).
    function _routeLegOut(Order memory o, address token, uint256 start, uint256 end, address to) internal pure {
        LegOut[] memory legsOut = new LegOut[](1);
        legsOut[0] = LegOut(token, start, end, to);
        o.legsOut = PackedEncode.legsOut(legsOut);
    }

    // ── SWAP & SUPPLY-COLLATERAL. The maker converts USD1 (the one asset they
    //    hold and had approved anyway) into BTCB Moolah collateral. BTCB — the
    //    asset they RECEIVE — has no ERC20 approval to Permit3 and no Permit3
    //    book entry to anything: the receive side is strictly empty, and Moolah
    //    `supplyCollateral` needs no `setAuthorization` either (the USD1/BTCB
    //    market has no collateral provider registered — see the harness header).
    function test_preFundSupplyCollateral_swapAndDeposit_zeroReceiveSideApprovals() public {
        deal(USD1, maker, USD1_IN);
        _approveMakerToSettlement(USD1, USD1_IN); //  the input leg — the ONE approval
        deal(BTCB, solver, BTCB_OUT);
        _approveSolverSide(BTCB_OUT, BTCB);

        bytes memory data = _preFundSupplyData();
        vm.startPrank(maker);
        IERC20(BTCB).approve(address(permit3), 0); //  receive side stripped bare
        vm.stopPrank();

        // Prove the receive side is empty BEFORE the fill, not just unused.
        assertEq(IERC20(BTCB).allowance(maker, address(permit3)), 0, "BTCB has no ERC20 approval to Permit3");
        (uint160 amt,) = permit3.tokenAllowance(maker, address(preFund), BTCB);
        assertEq(amt, 0, "BTCB has no Permit3 book entry either");

        Item[] memory items = new Item[](1);
        // `amount` is the PACING total (the anchor) — this module moves nothing out.
        items[0] = Item(ItemOp.MAKE, address(preFund), 0, address(0), data);
        Order memory o = _order(maker, 501, USD1, BTCB, USD1_IN, BTCB_OUT, items);
        _routeLegOut(o, BTCB, BTCB_OUT, 0, address(preFund));
        bytes memory sig = _sign(o);

        uint256 collBefore = _makerCollateral();
        uint256 makerBtcb = IERC20(BTCB).balanceOf(maker);

        vm.prank(solver);
        settlement.fill(o, sig, USD1_IN);

        // Moolah collateral never accrues — the delivered amount maps 1:1.
        assertEq(_makerCollateral() - collBefore, BTCB_OUT, "the delivered leg became collateral, exactly");
        assertEq(IERC20(BTCB).balanceOf(maker), makerBtcb, "the maker's wallet never saw the BTCB");
        assertEq(IERC20(BTCB).balanceOf(address(preFund)), 0, "module drained");
        assertEq(IERC20(USD1).balanceOf(solver), USD1_IN, "solver received the input leg");
    }

    // ── SWAP & REPAY, with overshoot. The maker converts BTCB into retiring
    //    their FLEX broker debt. USD1 — the loan token — is the canonical
    //    never-approved asset: no ERC20 approval to Permit3, no Permit3 book
    //    entry, asserted before the fill. The solver delivers MORE than the debt
    //    (1500 vs ~1000 owed); the broker consumes exactly the debt from the
    //    module's scoped allowance and the module sweeps the measured surplus to
    //    the maker — it is theirs. ──
    function test_preFundBrokerRepay_capsAtDebt_andSweepsSurplusToMaker() public {
        uint256 borrow = 1_000e18;
        uint256 btcbIn = 0.02e18;
        uint256 usd1Out = 1_500e18; //  delivered conversion output — overshoots the debt

        // Seed: collateral in Moolah, then the maker flex-borrows for themselves
        // (the bare msg.sender-only borrow) and parks the proceeds away.
        _seedCollateral(0.1e18);
        vm.startPrank(maker);
        IListaBrokerFlex(BROKER).borrow(borrow);
        IERC20(USD1).transfer(address(0xD1ED), IERC20(USD1).balanceOf(maker));
        vm.stopPrank();

        deal(BTCB, maker, btcbIn);
        _approveMakerToSettlement(BTCB, btcbIn); //  the input leg — already-held asset
        deal(USD1, solver, usd1Out);
        _approveSolverSide(usd1Out, USD1);

        bytes memory data = _preFundRepayData();
        vm.startPrank(maker);
        IERC20(USD1).approve(address(permit3), 0); //  receive side stripped bare
        vm.stopPrank();
        assertEq(IERC20(USD1).allowance(maker, address(permit3)), 0, "the loan token is approved nowhere");

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.MAKE, address(preFund), 0, address(0), data); //  pacing amount
        Order memory o = _order(maker, 502, BTCB, USD1, btcbIn, usd1Out, items);
        _routeLegOut(o, USD1, usd1Out, 0, address(preFund));
        bytes memory sig = _sign(o);

        // The live debt right before the fill — exactly what the repay consumes.
        uint256 debt = IListaBrokerViews(BROKER).getUserTotalDebt(maker);
        assertGe(debt, borrow, "flex debt seeded");
        uint256 makerUsd1 = IERC20(USD1).balanceOf(maker);

        vm.prank(solver);
        settlement.fill(o, sig, btcbIn);

        assertEq(IListaBrokerViews(BROKER).getUserTotalDebt(maker), 0, "the flex debt is retired in full");
        assertEq(IERC20(USD1).balanceOf(maker), makerUsd1 + (usd1Out - debt), "the surplus was swept to the maker");
        assertEq(IERC20(USD1).balanceOf(address(preFund)), 0, "module drained");
        assertEq(IERC20(BTCB).balanceOf(solver), btcbIn, "solver received the input leg");
        assertEq(IERC20(USD1).allowance(maker, address(permit3)), 0, "the loan-token approval stayed zero throughout");
    }

    // ── The dispatch gate: only Permit3 may enter. ──
    function test_preFundModules_rejectNonPermit3() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(PreFundGuard.OnlySettlement.selector);
        preFund.makeOnBehalf(maker, 1, _preFundSupplyData());
        vm.prank(address(0xBAD));
        vm.expectRevert(PreFundGuard.OnlySettlement.selector);
        preFund.makeOnBehalf(maker, 1, _preFundRepayData());
    }

    // ── The descriptor gate: only a `legsOut` REFERENCE — the one form whose
    //    amount the core sized to a delivery this module actually received. ──
    function test_preFundModules_rejectNonLegRefDescriptors() public {
        bytes memory literal = abi.encode(uint256(0), MOOLAH, _mp());
        bytes memory balance = abi.encode((uint256(3) << 254) | uint160(BTCB), MOOLAH, _mp());
        bytes memory literalRepay = abi.encode(uint256(0), BROKER, USD1, uint256(type(uint128).max));
        bytes memory balanceRepay =
            abi.encode((uint256(3) << 254) | uint160(USD1), BROKER, USD1, uint256(type(uint128).max));

        vm.startPrank(address(settlement));
        vm.expectRevert(PreFundGuard.PreFundDescriptorRequired.selector);
        preFund.makeOnBehalf(maker, 1, literal);
        vm.expectRevert(PreFundGuard.PreFundDescriptorRequired.selector);
        preFund.makeOnBehalf(maker, 1, balance);
        vm.expectRevert(PreFundGuard.PreFundDescriptorRequired.selector);
        preFund.makeOnBehalf(maker, 1, literalRepay);
        vm.expectRevert(PreFundGuard.PreFundDescriptorRequired.selector);
        preFund.makeOnBehalf(maker, 1, balanceRepay);
        vm.stopPrank();
    }
}
