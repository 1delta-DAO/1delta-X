// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, LegOut} from "@core/settlement/Settlement.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";

import {TellerPreFundModule} from "../../src/TellerPreFundModules.sol";
import {TellerRepayModule} from "../../src/TellerModules.sol";

/// @dev The slice of the REAL mainnet TellerV2 surface this PoC drives. Nothing here
///      is mocked: the proxy below is the live deployment (impl 0x37f4…b002).
interface ITellerV2Live {
    function submitBid(
        address lendingToken,
        uint256 marketplaceId,
        uint256 principal,
        uint32 duration,
        uint16 apr,
        string calldata metadataURI,
        address receiver
    ) external returns (uint256 bidId);
    function lenderAcceptBid(uint256 bidId) external returns (uint256, uint256, uint256);
    /// @dev Returns `Payment{principal, interest}`.
    function calculateAmountOwed(uint256 bidId, uint256 timestamp) external view returns (uint256, uint256);
    function getBidState(uint256 bidId) external view returns (uint8);
    function getLoanLender(uint256 bidId) external view returns (address);
    function getLoanBorrower(uint256 bidId) external view returns (address);
    function repayLoan(uint256 bidId, uint256 amount) external;
}

/// @title 2026-09-30 audit, L-CMT-1 / L-CMT-5 — Teller repay against the LIVE venue.
/// @notice The deployed TellerV2 `repayLoan` does NOT clamp an overpayment (pinned by
///         the venue-premise test below); the repay modules therefore clamp at the
///         live debt themselves. Mainnet fork against the LIVE TellerV2 proxy. The loan is opened in the
///         fork by the test maker (market 21 is open and attestation-free), a real
///         lender accepts it, interest accrues for 10 days, then the maker's signed
///         order is filled through the REAL Settlement + Permit3 with the Teller
///         repay modules. Only the maker/solver/lender EOAs and their balances
///         (`deal`) are test-controlled.
contract TellerRepayClampForkTest is CoreSettlementBase {
    address constant TELLER_V2 = 0x00182FdB0B880eE24D428e3Cc39383717677C37e;
    address constant TELLER_V2_IMPL = 0x37F483C895C66d3eDb14AE88ea9bA52F937Eb002;
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 constant MARKET_ID = 21; // open, no borrower/lender attestation on mainnet

    uint8 constant STATE_ACCEPTED = 3;
    uint8 constant STATE_PAID = 4;

    uint256 constant PRINCIPAL = 1 ether;
    uint256 constant USDC_IN = 3_000e6;

    TellerPreFundModule preFund;
    TellerRepayModule repayModule;
    address lender;

    function _forkBlock() internal pure override returns (uint256) {
        return 26_090_000;
    }

    function setUp() public override {
        super.setUp();
        preFund = new TellerPreFundModule(address(permit3), address(settlement));
        repayModule = new TellerRepayModule(address(permit3), address(settlement));
        lender = makeAddr("tellerLender");
        vm.label(TELLER_V2, "TellerV2");
        vm.label(address(preFund), "tellerPreFund");
        vm.label(address(repayModule), "tellerRepay");

        // The venue under test IS the deployed implementation the triage cites.
        assertEq(
            address(uint160(uint256(vm.load(TELLER_V2, IMPL_SLOT)))), TELLER_V2_IMPL, "live TellerV2 implementation"
        );
    }

    // ──────────────────── helpers ────────────────────

    /// @dev Maker borrows `PRINCIPAL` WETH on the live TellerV2 from a real lender,
    ///      dumps the proceeds so the wallet starts clean, then 10 days of interest
    ///      accrue.
    function _openLoan() internal returns (uint256 bidId) {
        vm.prank(maker);
        bidId = ITellerV2Live(TELLER_V2).submitBid(WETH, MARKET_ID, PRINCIPAL, 30 days, 1_000, "", maker);

        deal(WETH, lender, PRINCIPAL);
        vm.startPrank(lender);
        IERC20(WETH).approve(TELLER_V2, PRINCIPAL);
        ITellerV2Live(TELLER_V2).lenderAcceptBid(bidId);
        vm.stopPrank();

        assertEq(ITellerV2Live(TELLER_V2).getBidState(bidId), STATE_ACCEPTED, "loan live");
        assertEq(ITellerV2Live(TELLER_V2).getLoanBorrower(bidId), maker, "maker is the borrower");
        assertEq(ITellerV2Live(TELLER_V2).getLoanLender(bidId), lender, "lender");

        vm.startPrank(maker);
        IERC20(WETH).transfer(address(0xdead), IERC20(WETH).balanceOf(maker));
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);
        vm.roll(block.number + 72_000);
    }

    function _owed(uint256 bidId) internal view returns (uint256) {
        (uint256 p, uint256 i) = ITellerV2Live(TELLER_V2).calculateAmountOwed(bidId, block.timestamp);
        return p + i;
    }

    function _forLegOp(uint256 index, address token, TellerPreFundModule.Op op) internal pure returns (uint256) {
        // bit 255 = leg reference; bit 253 = the PRE-FUND shape; op in bits [244,252).
        return (uint256(1) << 255) | (uint256(1) << 253) | (uint256(uint160(token)) << 16) | index
            | (uint256(op) << 244);
    }

    /// @dev "Sell USDC, WETH output leg delivered to the pre-fund module (Dutch
    ///      `top → floor` over 1h), MAKE Repay(bid, full)". Exactly the finding's
    ///      order shape.
    function _preFundRepayOrder(uint256 nonce, uint256 bidId, bool full, uint256 top, uint256 floor)
        internal
        view
        returns (Order memory o)
    {
        bytes memory data =
            abi.encode(_forLegOp(0, WETH, TellerPreFundModule.Op.Repay), TELLER_V2, WETH, bidId, full);
        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.MAKE, address(preFund), 0, address(0), data);
        o = _order(maker, nonce, USDC, WETH, USDC_IN, top, items);
        LegOut[] memory legsOut = new LegOut[](1);
        legsOut[0] = LegOut(WETH, top, floor, address(preFund));
        o.legsOut = PackedEncode.legsOut(legsOut);
        _setDecayStart(o, block.timestamp);
        _setDecayDuration(o, 1 hours);
    }

    // ──────────────────── venue premise ────────────────────

    /// @dev Why the modules must clamp: a payer handing the LIVE `repayLoan` more
    ///      than the loan owes loses ALL of it to the lender. If this ever stops
    ///      holding (an implementation upgrade), the clamp becomes redundant, not wrong.
    function test_audit_L_CMT_1_venuePremise_repayLoanDoesNotClamp() public {
        uint256 bidId = _openLoan();
        uint256 owed = _owed(bidId);
        uint256 pay = owed + 0.2 ether;

        address payer = makeAddr("payer");
        deal(WETH, payer, pay);
        uint256 lenderBefore = IERC20(WETH).balanceOf(lender);

        vm.startPrank(payer);
        IERC20(WETH).approve(TELLER_V2, pay);
        ITellerV2Live(TELLER_V2).repayLoan(bidId, pay);
        vm.stopPrank();

        assertEq(ITellerV2Live(TELLER_V2).getBidState(bidId), STATE_PAID, "loan closed");
        assertEq(IERC20(WETH).balanceOf(lender) - lenderBefore, pay, "venue sent the uncapped amount to the lender");
    }

    // ──────────────────── pre-fund module ────────────────────

    /// @dev The finding's scenario, SAFE end state: a Dutch WETH leg 1.2 → 0.95 to the
    ///      pre-fund module, `Repay(full=false)`, filled at the top. The lender gets
    ///      exactly the owed amount and the surplus is swept back to the maker.
    function test_audit_L_CMT_1_preFundPartial_overDelivery_sweptToMaker() public {
        uint256 bidId = _openLoan();
        uint256 top = 1.2 ether;

        deal(USDC, maker, USDC_IN);
        _approveMakerToSettlement(USDC, USDC_IN);
        deal(WETH, solver, top);
        _approveSolverSide(top, WETH);

        Order memory o = _preFundRepayOrder(9001, bidId, false, top, 0.95 ether);
        bytes memory sig = _sign(o);

        uint256 owed = _owed(bidId);
        assertLt(owed, top, "pre: the delivery overshoots the live debt");
        uint256 makerWethBefore = IERC20(WETH).balanceOf(maker);
        uint256 lenderBefore = IERC20(WETH).balanceOf(lender);

        vm.prank(solver);
        settlement.fill(o, sig, USDC_IN);

        assertEq(ITellerV2Live(TELLER_V2).getBidState(bidId), STATE_PAID, "loan closed");
        assertEq(IERC20(WETH).balanceOf(lender) - lenderBefore, owed, "lender received EXACTLY owed");
        assertEq(IERC20(WETH).balanceOf(maker) - makerWethBefore, top - owed, "surplus swept back to the maker");
        assertEq(IERC20(WETH).balanceOf(address(preFund)), 0, "module holds nothing");
        assertEq(IERC20(WETH).allowance(address(preFund), TELLER_V2), 0, "scoped approval cleared");
    }

    /// @dev The same `full=false` Dutch order filled LATE (0.95 WETH, below the debt)
    ///      reaches `repayLoan` — the clamp only reroutes amounts AT OR ABOVE the
    ///      debt. On this market the whole loan is one payment cycle, so the venue's
    ///      minimum due is the full owed amount and it rejects the partial with
    ///      `PaymentNotMinimum`: a liveness limit of the venue, failing closed with
    ///      nothing moved (documented in the package README).
    function test_audit_L_CMT_1_preFundPartial_lateFillBelowVenueMinimum_failsClosed() public {
        uint256 bidId = _openLoan();
        uint256 top = 1.2 ether;
        uint256 floor = 0.95 ether;

        deal(USDC, maker, USDC_IN);
        _approveMakerToSettlement(USDC, USDC_IN);
        deal(WETH, solver, top);
        _approveSolverSide(top, WETH);

        Order memory o = _preFundRepayOrder(9005, bidId, false, top, floor);
        bytes memory sig = _sign(o);

        vm.warp(block.timestamp + 1 hours); // fully decayed → 0.95 WETH delivered
        assertGt(_owed(bidId), floor, "pre: late delivery is below the live debt");

        vm.prank(solver);
        vm.expectRevert(); // TellerV2.PaymentNotMinimum(bidId, payment, minimumOwed)
        settlement.fill(o, sig, USDC_IN);
        assertEq(ITellerV2Live(TELLER_V2).getBidState(bidId), STATE_ACCEPTED, "loan untouched");
    }

    /// @dev `full=true` keeps its meaning: it sweeps the surplus on an over-delivery.
    function test_audit_L_CMT_1_preFundFull_overDelivery_sweptToMaker() public {
        uint256 bidId = _openLoan();
        uint256 top = 1.2 ether;

        deal(USDC, maker, USDC_IN);
        _approveMakerToSettlement(USDC, USDC_IN);
        deal(WETH, solver, top);
        _approveSolverSide(top, WETH);

        Order memory o = _preFundRepayOrder(9004, bidId, true, top, 0.95 ether);
        bytes memory sig = _sign(o);
        uint256 owed = _owed(bidId);
        uint256 makerWethBefore = IERC20(WETH).balanceOf(maker);
        uint256 lenderBefore = IERC20(WETH).balanceOf(lender);

        vm.prank(solver);
        settlement.fill(o, sig, USDC_IN);

        assertEq(ITellerV2Live(TELLER_V2).getBidState(bidId), STATE_PAID, "loan closed");
        assertEq(IERC20(WETH).balanceOf(lender) - lenderBefore, owed, "lender received exactly owed");
        assertEq(IERC20(WETH).balanceOf(maker) - makerWethBefore, top - owed, "surplus swept to maker");
    }

    // ──────────────────── pull module ────────────────────

    /// @dev A buffered partial repay (owed + 0.05 WETH, `full=false`) through the
    ///      PULL module: the buffer comes back to the maker.
    function test_audit_L_CMT_1_pullPartial_buffer_sweptToMaker() public {
        uint256 bidId = _openLoan();
        uint256 owed = _owed(bidId);
        uint256 buffered = owed + 0.05 ether;

        deal(USDC, maker, USDC_IN);
        deal(WETH, solver, buffered);
        _approveSolverSide(buffered, WETH);
        vm.startPrank(maker);
        permit3.approveToken(address(settlement), USDC, uint160(USDC_IN), 0);
        permit3.approveToken(address(repayModule), WETH, uint160(buffered), 0);
        vm.stopPrank();

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.MAKE, address(repayModule), buffered, address(0), abi.encode(TELLER_V2, WETH, bidId, false));
        Order memory o = _order(maker, 9003, USDC, WETH, USDC_IN, buffered, items);
        bytes memory sig = _sign(o);

        uint256 makerWethBefore = IERC20(WETH).balanceOf(maker);
        uint256 lenderBefore = IERC20(WETH).balanceOf(lender);

        vm.prank(solver);
        settlement.fill(o, sig, USDC_IN);

        assertEq(ITellerV2Live(TELLER_V2).getBidState(bidId), STATE_PAID, "loan closed");
        assertEq(IERC20(WETH).balanceOf(lender) - lenderBefore, owed, "lender received EXACTLY owed");
        // The output leg delivered `buffered` to the maker; the module pulled it all,
        // repaid `owed` and swept the 0.05 buffer back.
        assertEq(IERC20(WETH).balanceOf(maker) - makerWethBefore, buffered - owed, "buffer swept back to the maker");
        assertEq(IERC20(WETH).balanceOf(address(repayModule)), 0, "module holds nothing");
    }
}
