// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";

import {TellerPreFundModule} from "../../src/TellerPreFundModules.sol";

/// @dev The slice of the REAL mainnet TellerV2 surface these tests drive.
interface ITellerV2Netted {
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
    function calculateAmountOwed(uint256 bidId, uint256 timestamp) external view returns (uint256, uint256);
    function getBidState(uint256 bidId) external view returns (uint8);
}

/// @title TellerNettedPreFundForkTest
/// @notice {TellerPreFundModule} `Op.Repay` on the NETTED path (`matchSettle`, task 31),
///         against the LIVE mainnet TellerV2 proxy (same block + open market 21 as
///         {TellerRepayClampForkTest}). Closes review 2026-10-18 M-6 for this venue's
///         repay op: plan §4.1 requires the netted interleaving to be tested on every
///         pre-fund module.
///
///         Teller is VALUE-IN ONLY — there is no borrow/withdraw TAKE module that could
///         fund the maker's input leg on the venue — so the input leg is a plain PULL
///         from the maker's wallet. A counter-order (Carol, a CoW) supplies the output
///         asset; the output leg is delivered to the pre-fund singleton and the
///         pre-funded repay consumes it late:
///
///           PULL carol → PULL A → DELIVER A → ITEM(A, 0: pre-fund Repay) → DELIVER carol
///
///         The solver is the base's EOA, holding nothing. The singleton carries WETH
///         RESIDUE before every plan; a sweep sized from anything but the pre-call floor
///         would hand residue, or a sibling's parked delivery, to the wrong maker.
///
///         Pool DEPOSIT is not driven here: no live V2/V3 `LenderCommitmentGroup` pool
///         address is pinned in this repo and its `deposit` is Hypernative-firewalled
///         for contract callers. The netted deposit is covered against a mock pool
///         (with a modelled firewall) in `test/unit/NettedPreFund.t.sol`.
contract TellerNettedPreFundForkTest is CoreSettlementBase {
    address constant TELLER_V2 = 0x00182FdB0B880eE24D428e3Cc39383717677C37e;
    uint256 constant MARKET_ID = 21; // open, no borrower/lender attestation on mainnet
    uint8 constant STATE_ACCEPTED = 3;
    uint8 constant STATE_PAID = 4;

    uint256 constant RESIDUE_WETH = 0.07 ether; // stray balance already on the singleton
    uint256 constant RESIDUE_USDC = 77e6;

    TellerPreFundModule preFund;
    address lender;

    uint256 bobPk = 0xB0B;
    address bob = vm.addr(bobPk);
    uint256 carolPk = 0xCA201;
    address carol = vm.addr(carolPk);

    function _forkBlock() internal pure override returns (uint256) {
        return 26_090_000;
    }

    function setUp() public override {
        super.setUp();
        preFund = new TellerPreFundModule(address(permit3), address(settlement));
        lender = makeAddr("tellerLender");
        vm.label(TELLER_V2, "TellerV2");
        vm.label(address(preFund), "tellerPreFund");
        vm.label(bob, "bob");
        vm.label(carol, "carol");

        deal(WETH, address(preFund), RESIDUE_WETH);
        deal(USDC, address(preFund), RESIDUE_USDC);
    }

    // ──────────────────── venue helpers ────────────────────

    /// @dev `who` borrows `principal` WETH on the live TellerV2 from a real lender and
    ///      dumps the proceeds, so the repay must be funded by the plan.
    function _openLoan(address who, uint256 principal) internal returns (uint256 bidId) {
        vm.prank(who);
        bidId = ITellerV2Netted(TELLER_V2).submitBid(WETH, MARKET_ID, principal, 30 days, 1_000, "", who);

        deal(WETH, lender, principal);
        vm.startPrank(lender);
        IERC20(WETH).approve(TELLER_V2, principal);
        ITellerV2Netted(TELLER_V2).lenderAcceptBid(bidId);
        vm.stopPrank();
        assertEq(ITellerV2Netted(TELLER_V2).getBidState(bidId), STATE_ACCEPTED, "loan live");

        vm.startPrank(who);
        IERC20(WETH).transfer(address(0xdead), IERC20(WETH).balanceOf(who));
        vm.stopPrank();
    }

    /// @dev Interest accrues for 10 days on every open loan.
    function _accrue() internal {
        vm.warp(block.timestamp + 10 days);
        vm.roll(block.number + 72_000);
    }

    function _owed(uint256 bidId) internal view returns (uint256) {
        (uint256 p, uint256 i) = ITellerV2Netted(TELLER_V2).calculateAmountOwed(bidId, block.timestamp);
        return p + i;
    }

    // ──────────────────── order builders ────────────────────

    /// @dev Pre-fund leg reference to legsOut[j] (bits 255+253), op in [244,252).
    function _desc(TellerPreFundModule.Op op, address token, uint256 j) internal pure returns (uint256) {
        return (uint256(5) << 253) | (uint256(op) << 244) | (uint256(uint160(token)) << 16) | j;
    }

    /// @dev `who` sells `usdcIn` USDC (PULLed from the wallet) for `wethOut` WETH
    ///      delivered to the pre-fund singleton and consumed by ONE pre-funded
    ///      `Repay(bidId, full=false)` MAKE.
    function _repayOrder(address who, uint256 nonce, uint256 usdcIn, uint256 wethOut, uint256 bidId)
        internal
        returns (Order memory o)
    {
        deal(USDC, who, usdcIn);
        vm.startPrank(who);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDC, uint160(usdcIn), 0);
        vm.stopPrank();

        bytes memory data =
            abi.encode(_desc(TellerPreFundModule.Op.Repay, WETH, 0), TELLER_V2, WETH, bidId, false);
        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.MAKE, address(preFund), 0, address(0), data);
        o = _order(who, nonce, USDC, WETH, usdcIn, wethOut, items);
        o.legsOut = PackedEncode.oneLegOut(WETH, wethOut, 0, address(preFund));
    }

    /// @dev Carol, the CoW counter-order: sells `amtIn` of `tokIn` for `amtOut` of `tokOut`.
    function _carol(address tokIn, uint256 amtIn, address tokOut, uint256 amtOut) internal returns (Order memory) {
        deal(tokIn, carol, amtIn);
        vm.startPrank(carol);
        IERC20(tokIn).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), tokIn, uint160(amtIn), 0);
        vm.stopPrank();
        return _order(carol, 1, tokIn, tokOut, amtIn, amtOut, new Item[](0));
    }

    function _signAs(Order memory o, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), _hashOrder(o)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _plan(Order[] memory orders, uint256[] memory pks, uint256[] memory schedule)
        internal
        view
        returns (MatchPlan memory)
    {
        uint256 n = orders.length;
        bytes[] memory sigs = new bytes[](n);
        uint256[] memory fills = new uint256[](n);
        for (uint256 i; i < n; i++) {
            sigs[i] = _signAs(orders[i], pks[i]);
            fills[i] = PackedEncode.getLegInStart(orders[i].legsIn, 0);
        }
        return MatchPlan({
            orders: orders,
            sigs: sigs,
            fillAmounts: fills,
            takerDatas: new bytes[](0),
            schedule: schedule,
            callTargets: new address[](0),
            callDatas: new bytes[](0),
            profitRecipient: address(0)
        });
    }

    function _s(uint256 kind, uint256 a, uint256 b) internal pure returns (uint256) {
        return MatchStep.pack(kind, a, b);
    }

    function _pair(Order memory a, Order memory c, uint256 pkA)
        internal
        view
        returns (Order[] memory o, uint256[] memory pks)
    {
        o = new Order[](2);
        (o[0], o[1]) = (a, c);
        pks = new uint256[](2);
        (pks[0], pks[1]) = (pkA, carolPk);
    }

    function _assertSolverFlat() internal view {
        assertEq(IERC20(USDC).balanceOf(solver) + IERC20(WETH).balanceOf(solver), 0, "zero solver capital, zero take");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "nothing pooled (USDC)");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "nothing pooled (WETH)");
        assertEq(IERC20(WETH).balanceOf(address(preFund)), RESIDUE_WETH, "WETH residue untouched");
        assertEq(IERC20(USDC).balanceOf(address(preFund)), RESIDUE_USDC, "USDC residue untouched");
        assertEq(IERC20(WETH).allowance(address(preFund), TELLER_V2), 0, "scoped approval cleared");
    }

    // ──────────────────── (b) netted repay, over-delivery swept ────────────────────

    /// The delivery (1.2 WETH) over-covers the live debt (~1.003 WETH): the module
    /// routes it to `repayLoanFull`, the lender receives EXACTLY owed, and only the
    /// unconsumed part of THIS delivery — not the residue — is swept to the maker.
    function test_netted_preFundRepay_overDelivery_sweptToMaker_zeroCapital_teller() public {
        uint256 bidId = _openLoan(maker, 1 ether);
        _accrue();
        uint256 usdcIn = 3_000e6;
        uint256 wethOut = 1.2 ether;
        Order memory a = _repayOrder(maker, 1, usdcIn, wethOut, bidId);
        Order memory c = _carol(WETH, wethOut, USDC, usdcIn);
        (Order[] memory orders, uint256[] memory pks) = _pair(a, c, makerPk);

        uint256[] memory s = new uint256[](5);
        s[0] = _s(MatchStep.PULL, 1, 0);
        s[1] = _s(MatchStep.PULL, 0, 0);
        s[2] = _s(MatchStep.DELIVER, 0, 0);
        s[3] = _s(MatchStep.ITEM, 0, 0);
        s[4] = _s(MatchStep.DELIVER, 1, 0);
        MatchPlan memory p = _plan(orders, pks, s);

        uint256 owed = _owed(bidId);
        assertLt(owed, wethOut, "pre: the delivery overshoots the live debt");
        uint256 lenderBefore = IERC20(WETH).balanceOf(lender);

        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(ITellerV2Netted(TELLER_V2).getBidState(bidId), STATE_PAID, "loan closed");
        assertEq(IERC20(WETH).balanceOf(lender) - lenderBefore, owed, "lender received EXACTLY owed");
        assertEq(IERC20(WETH).balanceOf(maker), wethOut - owed, "exactly the unconsumed delivery swept back");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "maker's input pulled in full");
        assertEq(IERC20(USDC).balanceOf(carol), usdcIn, "carol paid out of the maker's PULL");
        _assertSolverFlat();
    }

    // ──────────────────── (c) two repays interleaved on ONE singleton ────────────────────

    /// DELIVER A, DELIVER B, ITEM B, ITEM A. Alice over-delivers (sweep), Bob delivers
    /// barely above his debt. When B's repay runs the module holds residue + A's + B's
    /// WETH; the floor leaves A's delivery intact for A, B's sweep returns only B's
    /// surplus, and A's sweep returns only A's.
    function test_netted_twoRepaysInterleaved_eachRepaysAndSweepsOnlyItsOwn_teller() public {
        uint256 bidA = _openLoan(maker, 1 ether);
        uint256 bidB = _openLoan(bob, 0.4 ether);
        _accrue();
        uint256 aIn = 3_000e6;
        uint256 aOut = 1.25 ether;
        uint256 bIn = 1_200e6;
        uint256 bOut = 0.41 ether;

        Order[] memory orders = new Order[](3);
        orders[0] = _repayOrder(maker, 1, aIn, aOut, bidA);
        orders[1] = _repayOrder(bob, 1, bIn, bOut, bidB);
        orders[2] = _carol(WETH, aOut + bOut, USDC, aIn + bIn);
        uint256[] memory pks = new uint256[](3);
        (pks[0], pks[1], pks[2]) = (makerPk, bobPk, carolPk);

        uint256[] memory s = new uint256[](8);
        s[0] = _s(MatchStep.PULL, 2, 0);
        s[1] = _s(MatchStep.PULL, 0, 0);
        s[2] = _s(MatchStep.PULL, 1, 0);
        s[3] = _s(MatchStep.DELIVER, 0, 0);
        s[4] = _s(MatchStep.DELIVER, 1, 0);
        s[5] = _s(MatchStep.ITEM, 1, 0);
        s[6] = _s(MatchStep.ITEM, 0, 0);
        s[7] = _s(MatchStep.DELIVER, 2, 0);
        MatchPlan memory p = _plan(orders, pks, s);

        uint256 owedA = _owed(bidA);
        uint256 owedB = _owed(bidB);
        assertLt(owedA, aOut, "pre: A over-delivers");
        assertLt(owedB, bOut, "pre: B over-delivers");
        uint256 lenderBefore = IERC20(WETH).balanceOf(lender);

        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(ITellerV2Netted(TELLER_V2).getBidState(bidA), STATE_PAID, "alice's loan closed");
        assertEq(ITellerV2Netted(TELLER_V2).getBidState(bidB), STATE_PAID, "bob's loan closed");
        assertEq(IERC20(WETH).balanceOf(lender) - lenderBefore, owedA + owedB, "lender received exactly both debts");
        assertEq(IERC20(WETH).balanceOf(maker), aOut - owedA, "alice swept exactly her own surplus");
        assertEq(IERC20(WETH).balanceOf(bob), bOut - owedB, "bob swept exactly his own surplus");
        assertEq(IERC20(USDC).balanceOf(carol), aIn + bIn, "carol paid");
        _assertSolverFlat();
    }

    // ──────────────────── (d) pre-fund item before its own DELIVER ────────────────────

    /// The pre-funded repay hoisted ahead of its own DELIVER — with residue on the
    /// singleton that could have "funded" it — fails closed in the core ledger.
    function test_netted_preFundRepayBeforeOwnDelivery_failsClosed_teller() public {
        uint256 bidId = _openLoan(maker, 1 ether);
        _accrue();
        uint256 usdcIn = 150e6;
        uint256 wethOut = 0.05 ether; // below RESIDUE_WETH: the floor alone would not stop it
        Order memory a = _repayOrder(maker, 1, usdcIn, wethOut, bidId);
        Order memory c = _carol(WETH, wethOut, USDC, usdcIn);
        (Order[] memory orders, uint256[] memory pks) = _pair(a, c, makerPk);

        uint256[] memory s = new uint256[](5);
        s[0] = _s(MatchStep.PULL, 1, 0);
        s[1] = _s(MatchStep.PULL, 0, 0);
        s[2] = _s(MatchStep.ITEM, 0, 0); // before DELIVER A
        s[3] = _s(MatchStep.DELIVER, 0, 0);
        s[4] = _s(MatchStep.DELIVER, 1, 0);
        MatchPlan memory p = _plan(orders, pks, s);

        vm.prank(solver);
        vm.expectRevert(Base.ForLegInvalid.selector);
        settlement.matchSettle(p);
        assertEq(ITellerV2Netted(TELLER_V2).getBidState(bidId), STATE_ACCEPTED, "loan untouched");
    }
}
