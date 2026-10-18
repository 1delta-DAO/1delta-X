// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Item, ItemOp, Order, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {stdError} from "forge-std/StdError.sol";

import {MidnightPreFundModule} from "../../src/MidnightPreFundModules.sol";
import {MidnightBlob, MidnightTakerModule} from "../../src/MidnightModules.sol";
import {Offer} from "../../src/interfaces/IMidnight.sol";
import {MidnightModulesBase} from "../shared/MidnightModulesBase.t.sol";
import {MockERC20} from "../shared/MidnightMock.sol";

/// @title MidnightNettedPreFundTest
/// @notice Morpho Midnight's pre-fund family on the NETTED path (`matchSettle`, review
///         2026-10-18 M-6), including the new pre-funded LEND op (M-5), over the real
///         Settlement + Permit3 and the package's faithful Midnight mock.
///
///         Midnight's blobs are the only DYNAMIC ones in the lending tree — `Market`
///         embeds a `CollateralParams[]`, `Offer` embeds a `Market` plus `bytes` — and
///         every item here decodes one of them on the netted path, which had never run
///         before (M-6). Each scenario parks two makers' deliveries side by side on the
///         ONE pre-fund singleton (which also carries loan-token and collateral
///         residue) before either item runs, and the counterparties are CoW orders, so
///         every plan settles at zero solver capital:
///
///           • the acyclic OPEN: borrow TAKE early (against existing headroom), sell
///             the loan token, pre-funded supply-collateral LATE;
///           • the pre-funded LEND next to a pre-funded REPAY, with a settlement fee
///             so the lend consumes LESS than its delivery and must sweep exactly its
///             own remainder;
///           • the acyclic CLOSE: withdraw-collateral TAKE early, sell, pre-funded
///             repay LATE.
contract MidnightNettedPreFundTest is MidnightModulesBase {
    MidnightPreFundModule preFund;
    MockERC20 SELL; // what the makers pay

    uint256 bobPk = 0xB0B;
    address bob = vm.addr(bobPk);
    uint256 carolPk = 0xCA201;
    address carol = vm.addr(carolPk);

    uint256 constant RESIDUE_L = 3e6; //  LOAN on the singleton
    uint256 constant RESIDUE_C = 3e18; // COLL on the singleton
    uint256 constant FEE = 0.01e18; //    1% settlement fee on the lend
    uint256 constant RATE = 0.99e18; //   units per loan wei the lender signs (< 1/(1+fee))

    function setUp() public override {
        super.setUp();
        preFund = new MidnightPreFundModule(address(permit3), address(settlement), address(midnight));
        SELL = new MockERC20("Sell", "SELL", 18);
        vm.label(address(preFund), "preFund");
        LOAN.mint(address(preFund), RESIDUE_L);
        COLL.mint(address(preFund), RESIDUE_C);
        _authorize(maker, address(preFund));
        _authorize(bob, address(preFund));
    }

    // ──────────────────── builders ────────────────────

    function _authorize(address who, address module) internal {
        vm.prank(who);
        midnight.setIsAuthorized(module, true, who);
    }

    function _signWith(Order memory o, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), _hashOrder(o)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _approveAs(address who, MockERC20 token) internal {
        vm.startPrank(who);
        token.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(token), type(uint160).max, 0);
        vm.stopPrank();
    }

    function _ord(address who, uint256 nonce, address tIn, address tOut, uint256 aIn, uint256 aOut)
        internal
        view
        returns (Order memory)
    {
        return _sellOrder(nonce, who, tIn, tOut, aIn, aOut, new Item[](0));
    }

    function _desc(MidnightPreFundModule.Op op, address token, uint256 j) internal pure returns (uint256) {
        return (uint256(5) << 253) | (uint256(op) << 244) | (uint256(uint160(token)) << 16) | j;
    }

    function _pfSupply() internal view returns (bytes memory) {
        return abi.encode(_desc(MidnightPreFundModule.Op.SupplyCollateral, address(COLL), 0), _market(), uint256(0));
    }

    function _pfRepay() internal view returns (bytes memory) {
        return abi.encode(_desc(MidnightPreFundModule.Op.Repay, address(LOAN), 0), _market());
    }

    function _pfLend(uint256 rate) internal view returns (bytes memory) {
        return abi.encode(_desc(MidnightPreFundModule.Op.Lend, address(LOAN), 0), _offer(false), bytes(""), rate);
    }

    /// @dev `who` pays `amtIn` SELL for `amtOut` of `tokOut` delivered to the
    ///      pre-fund singleton, consumed by one pre-funded MAKE carrying `data`.
    function _pfOrder(address who, uint256 amtIn, address tokOut, uint256 amtOut, bytes memory data)
        internal
        view
        returns (Order memory o)
    {
        o = _ord(who, 1, address(SELL), tokOut, amtIn, amtOut);
        o.legsOut = PackedEncode.oneLegOut(tokOut, amtOut, 0, address(preFund));
        Item[] memory items = new Item[](1);
        items[0] = _item(ItemOp.MAKE, address(preFund), 0, data);
        o.items = PackedEncode.items(items);
    }

    function _cow(address tokIn, uint256 amtIn, address tokOut, uint256 amtOut) internal view returns (Order memory o) {
        o = _ord(carol, 1, tokIn, tokOut, amtIn, amtOut);
    }

    function _step(uint256 kind, uint256 a, uint256 b) internal pure returns (uint256) {
        return MatchStep.pack(kind, a, b);
    }

    function _plan(Order[] memory orders, uint256[] memory pks, uint256[] memory fills, uint256[] memory s)
        internal
        view
        returns (MatchPlan memory)
    {
        bytes[] memory sigs = new bytes[](orders.length);
        for (uint256 i; i < orders.length; i++) {
            sigs[i] = _signWith(orders[i], pks[i]);
        }
        return MatchPlan({
            orders: orders,
            sigs: sigs,
            fillAmounts: fills,
            takerDatas: new bytes[](0),
            schedule: s,
            callTargets: new address[](0),
            callDatas: new bytes[](0),
            profitRecipient: address(0)
        });
    }

    function _o(Order memory a, Order memory b, Order memory c) internal pure returns (Order[] memory o) {
        o = new Order[](3);
        (o[0], o[1], o[2]) = (a, b, c);
    }

    function _u(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory x) {
        x = new uint256[](3);
        (x[0], x[1], x[2]) = (a, b, c);
    }

    /// @dev PULL 0..2, `mid`, DELIVER the CoW (order 2).
    function _withMiddle(uint256[] memory mid) internal pure returns (uint256[] memory s) {
        s = new uint256[](mid.length + 4);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 1, 0);
        s[2] = _step(MatchStep.PULL, 2, 0);
        for (uint256 i; i < mid.length; i++) {
            s[3 + i] = mid[i];
        }
        s[s.length - 1] = _step(MatchStep.DELIVER, 2, 0);
    }

    function _interleaved() internal pure returns (uint256[] memory mid) {
        mid = new uint256[](4);
        mid[0] = _step(MatchStep.DELIVER, 0, 0);
        mid[1] = _step(MatchStep.DELIVER, 1, 0);
        mid[2] = _step(MatchStep.ITEM, 1, 0);
        mid[3] = _step(MatchStep.ITEM, 0, 0);
    }

    function _assertResidue() internal view {
        assertEq(LOAN.balanceOf(address(preFund)), RESIDUE_L, "loan residue intact");
        assertEq(COLL.balanceOf(address(preFund)), RESIDUE_C, "collateral residue intact");
        assertEq(LOAN.allowance(address(preFund), address(midnight)), 0, "loan approval cleared");
        assertEq(COLL.allowance(address(preFund), address(midnight)), 0, "collateral approval cleared");
    }

    // ──────────────────── pre-funded LEND (M-5) next to pre-funded REPAY ────────────────────

    /// @dev Alice lends (rate-sized units) and Bob repays (debt below delivery), both
    ///      funded by LOAN delivered to the one singleton; Carol sells the LOAN.
    function _fundLendRepay(uint256 outA, uint256 outB, uint256 debtB, uint256 rate)
        internal
        returns (Order[] memory orders)
    {
        midnight.setSettlementFee(_market(), FEE);
        midnight.seedDebt(_market(), bob, debtB);
        SELL.mint(maker, 1_000e18);
        SELL.mint(bob, 2_000e18);
        LOAN.mint(carol, outA + outB);
        _approveAs(maker, SELL);
        _approveAs(bob, SELL);
        _approveAs(carol, LOAN);
        orders = _o(
            _pfOrder(maker, 1_000e18, address(LOAN), outA, _pfLend(rate)),
            _pfOrder(bob, 2_000e18, address(LOAN), outB, _pfRepay()),
            _cow(address(LOAN), outA + outB, address(SELL), 3_000e18)
        );
    }

    /// DELIVER A, DELIVER B, ITEM B (repay 5 of 7), ITEM A (lend: units = 0.99·1000,
    /// cost = ceil(units·1.01) < 1000). Each maker is swept exactly their own
    /// remainder; the loan residue is untouched; the Offer decodes on the netted path.
    function test_netted_lendAndRepay_interleaved_eachSweepsOnlyItsOwn() public {
        uint256 outA = 1_000e6;
        uint256 outB = 7e6;
        uint256 debtB = 5e6;
        Order[] memory orders = _fundLendRepay(outA, outB, debtB, RATE);
        MatchPlan memory p =
            _plan(orders, _u(makerPk, bobPk, carolPk), _u(1_000e18, 2_000e18, outA + outB), _withMiddle(_interleaved()));

        uint256 offerMakerBefore = LOAN.balanceOf(offerMaker);
        vm.prank(solver);
        settlement.matchSettle(p);

        uint256 units = outA * RATE / 1e18;
        uint256 cost = (units * (1e18 + FEE) + 1e18 - 1) / 1e18;
        assertEq(_creditOf(maker), units, "alice bought exactly the rate-sized units");
        assertEq(LOAN.balanceOf(maker), outA - cost, "alice swept back exactly her unspent delivery");
        assertEq(LOAN.balanceOf(offerMaker) - offerMakerBefore, units, "the offer's seller got par");
        assertEq(_debtOf(bob), 0, "bob's debt retired, clamped");
        assertEq(LOAN.balanceOf(bob), outB - debtB, "bob swept back exactly his surplus");
        _assertResidue();
        assertEq(SELL.balanceOf(carol), 3_000e18, "carol paid");
        assertEq(LOAN.balanceOf(solver) + SELL.balanceOf(solver), 0, "zero solver capital");
    }

    /// The lend signed at a rate the offer cannot honour (1 unit per wei against a 1%
    /// fee) while Bob's delivery sits parked on the singleton: Midnight would need
    /// MORE than Alice's delivery, the scoped approval refuses it, and the plan fails
    /// closed — it can never be paid out of Bob's parked tokens or the residue.
    function test_netted_lend_priceWorseThanRate_failsClosed_neverDrawsParkedFunds() public {
        uint256 outA = 1_000e6;
        Order[] memory orders = _fundLendRepay(outA, 50_000e6, 1e6, 1e18); // bob parks far more than the gap
        uint256[] memory mid = new uint256[](3);
        mid[0] = _step(MatchStep.DELIVER, 1, 0);
        mid[1] = _step(MatchStep.DELIVER, 0, 0);
        mid[2] = _step(MatchStep.ITEM, 0, 0);
        MatchPlan memory p =
            _plan(orders, _u(makerPk, bobPk, carolPk), _u(1_000e18, 2_000e18, outA + 50_000e6), _withMiddle(mid));

        vm.prank(solver);
        vm.expectRevert(stdError.arithmeticError); // allowance underflow inside the venue's pull
        settlement.matchSettle(p);
    }

    /// The lend item hoisted ahead of its own delivery, with Bob's LOAN parked: the
    /// core ledger refuses it before the module ever reads the balance.
    function test_netted_lend_itemBeforeOwnDelivery_failsClosed() public {
        Order[] memory orders = _fundLendRepay(2e6, 7e6, 5e6, RATE);
        uint256[] memory mid = new uint256[](4);
        mid[0] = _step(MatchStep.DELIVER, 1, 0);
        mid[1] = _step(MatchStep.ITEM, 1, 0);
        mid[2] = _step(MatchStep.ITEM, 0, 0);
        mid[3] = _step(MatchStep.DELIVER, 0, 0);
        MatchPlan memory p =
            _plan(orders, _u(makerPk, bobPk, carolPk), _u(1_000e18, 2_000e18, 9e6), _withMiddle(mid));

        vm.prank(solver);
        vm.expectRevert(Base.ForLegInvalid.selector);
        settlement.matchSettle(p);
    }

    // ──────────────────── the acyclic OPEN at zero capital ────────────────────

    /// Alice already holds collateral headroom. She borrows EARLY (TAKE, sells debt
    /// units into a buy offer; proceeds credit her LOAN input leg), Carol buys the
    /// LOAN with COLL, and the COLL is delivered to the pre-fund module and supplied
    /// LATE. Bob's own COLL supply parks on the same singleton in between.
    ///
    ///   PULL carol (COLL) → PULL bob (SELL) → ITEM alice#0 (borrow) → DELIVER alice
    ///   → DELIVER bob → ITEM bob → ITEM alice#1 (supply) → DELIVER carol
    function test_netted_open_borrowEarly_supplyLate_zeroCapital() public {
        uint256 units = 400e6; //   debt sold
        uint256 collA = 9e18; //    COLL bought with the proceeds
        uint256 collB = 4e18; //    bob's supply
        _seedCollateral(maker, 1_000e18); // headroom
        _authorize(maker, address(borrowModule));

        bytes memory bData = _borrowData(units, units);
        Order memory a = _ord(maker, 1, address(LOAN), address(COLL), units, collA);
        a.legsOut = PackedEncode.oneLegOut(address(COLL), collA, 0, address(preFund));
        {
            Item[] memory items = new Item[](2);
            items[0] = _item(ItemOp.TAKE, address(borrowModule), units, bData);
            items[1] = _item(ItemOp.MAKE, address(preFund), 0, _pfSupply());
            a.items = PackedEncode.items(items);
        }
        _makerApproveTaker(address(borrowModule), keccak256(bData), units);

        SELL.mint(bob, 100e18);
        _approveAs(bob, SELL);
        Order memory b = _pfOrder(bob, 100e18, address(COLL), collB, _pfSupply());

        // Carol sells COLL twice: for LOAN out of alice's borrow, for SELL from bob.
        COLL.mint(carol, collA + collB);
        _approveAs(carol, COLL);
        Order memory c = _ord(carol, 1, address(COLL), address(LOAN), collA, units);
        Order memory c2 = _ord(carol, 2, address(COLL), address(SELL), collB, 100e18);

        Order[] memory orders = new Order[](4);
        (orders[0], orders[1], orders[2], orders[3]) = (a, b, c, c2);
        uint256[] memory pks = new uint256[](4);
        (pks[0], pks[1], pks[2], pks[3]) = (makerPk, bobPk, carolPk, carolPk);
        uint256[] memory fills = new uint256[](4);
        (fills[0], fills[1], fills[2], fills[3]) = (units, 100e18, collA, collB);
        uint256[] memory s = new uint256[](10);
        s[0] = _step(MatchStep.PULL, 2, 0);
        s[1] = _step(MatchStep.PULL, 3, 0);
        s[2] = _step(MatchStep.PULL, 1, 0);
        s[3] = _step(MatchStep.ITEM, 0, 0); //    borrow → LOAN credited to alice's leg
        s[4] = _step(MatchStep.DELIVER, 0, 0); // alice's COLL → preFund
        s[5] = _step(MatchStep.DELIVER, 1, 0); // bob's COLL parks beside it
        s[6] = _step(MatchStep.ITEM, 1, 0); //    bob supplies exactly his
        s[7] = _step(MatchStep.ITEM, 0, 1); //    alice supplies exactly hers
        s[8] = _step(MatchStep.DELIVER, 2, 0);
        s[9] = _step(MatchStep.DELIVER, 3, 0);
        MatchPlan memory p = _plan(orders, pks, fills, s);

        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(_collateralOf(maker), 1_000e18 + collA, "alice supplied exactly her delivery");
        assertEq(_collateralOf(bob), collB, "bob supplied exactly his");
        assertEq(_debtOf(maker), units, "alice borrowed the signed units");
        assertEq(LOAN.balanceOf(carol), units, "carol paid out of the borrow");
        assertEq(SELL.balanceOf(carol), 100e18, "carol paid by bob");
        assertEq(LOAN.balanceOf(maker) + COLL.balanceOf(maker), 0, "alice's wallet untouched");
        _assertResidue();
        assertEq(LOAN.balanceOf(solver) + COLL.balanceOf(solver) + SELL.balanceOf(solver), 0, "zero solver capital");
    }

    // ──────────────────── the acyclic CLOSE at zero capital ────────────────────

    /// Alice withdraws collateral EARLY (TAKE, proceeds credit her COLL input leg),
    /// Carol buys it with LOAN, and the LOAN is delivered to the pre-fund module and
    /// repays LATE — clamped at the live debt, the remainder swept back to her.
    function test_netted_close_withdrawEarly_repayLate_zeroCapital() public {
        uint256 collOut = 20e18;
        uint256 loanIn = 300e6;
        uint256 debt = 250e6;
        _seedCollateral(maker, 1_000e18);
        midnight.seedDebt(_market(), maker, debt);
        _authorize(maker, address(takerModule));

        bytes memory wData = _withdrawCollateralData(0, 0);
        Order memory a = _ord(maker, 1, address(COLL), address(LOAN), collOut, loanIn);
        a.legsOut = PackedEncode.oneLegOut(address(LOAN), loanIn, 0, address(preFund));
        {
            Item[] memory items = new Item[](2);
            items[0] = _item(ItemOp.TAKE, address(takerModule), collOut, wData);
            items[1] = _item(ItemOp.MAKE, address(preFund), 0, _pfRepay());
            a.items = PackedEncode.items(items);
        }
        _makerApproveTaker(address(takerModule), keccak256(wData), collOut);

        LOAN.mint(carol, loanIn);
        _approveAs(carol, LOAN);
        Order memory c = _cow(address(LOAN), loanIn, address(COLL), collOut);

        Order[] memory orders = new Order[](2);
        (orders[0], orders[1]) = (a, c);
        uint256[] memory pks = new uint256[](2);
        (pks[0], pks[1]) = (makerPk, carolPk);
        uint256[] memory fills = new uint256[](2);
        (fills[0], fills[1]) = (collOut, loanIn);
        uint256[] memory s = new uint256[](6);
        s[0] = _step(MatchStep.PULL, 1, 0);
        s[1] = _step(MatchStep.ITEM, 0, 0);
        s[2] = _step(MatchStep.DELIVER, 0, 0);
        s[3] = _step(MatchStep.ITEM, 0, 1);
        s[4] = _step(MatchStep.PULL, 0, 0); // covered by the TAKE
        s[5] = _step(MatchStep.DELIVER, 1, 0);
        MatchPlan memory p = _plan(orders, pks, fills, s);

        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(_debtOf(maker), 0, "debt fully repaid");
        assertEq(LOAN.balanceOf(maker), loanIn - debt, "the unconsumed delivery swept back");
        assertEq(_collateralOf(maker), 1_000e18 - collOut, "exactly the signed collateral withdrawn");
        assertEq(COLL.balanceOf(carol), collOut, "carol paid in collateral");
        assertEq(COLL.balanceOf(maker), 0, "withdrawn collateral went to the CoW");
        _assertResidue();
        assertEq(LOAN.balanceOf(solver) + COLL.balanceOf(solver), 0, "zero solver capital");
    }

    // ──────────────────── pre-funded LEND on the forward path, and its gates ────────────────────

    /// Two partial `fill`s of one lend order: the units pro-rate with each delivery
    /// (the absolute-units pull module is full-fill only), and each fill sweeps back
    /// only its own unspent part.
    function test_forward_lend_partialFills_unitsFollowEachDelivery() public {
        uint256 outA = 1_000e6;
        midnight.setSettlementFee(_market(), FEE);
        SELL.mint(maker, 1_000e18);
        _approveAs(maker, SELL);
        LOAN.mint(solver, outA + 2);
        Order memory o = _pfOrder(maker, 1_000e18, address(LOAN), outA, _pfLend(RATE));
        bytes memory sig = _sign(o);

        vm.prank(solver);
        settlement.fill(o, sig, 400e18);
        uint256 d1 = outA + 2 - LOAN.balanceOf(solver);
        vm.prank(solver);
        settlement.fill(o, sig, 600e18);
        uint256 d2 = outA + 2 - LOAN.balanceOf(solver) - d1;

        uint256 u1 = d1 * RATE / 1e18;
        uint256 u2 = d2 * RATE / 1e18;
        assertEq(_creditOf(maker), u1 + u2, "each fill bought its own delivery's units");
        uint256 cost = (u1 * (1e18 + FEE) + 1e18 - 1) / 1e18 + (u2 * (1e18 + FEE) + 1e18 - 1) / 1e18;
        assertEq(LOAN.balanceOf(maker), d1 + d2 - cost, "every unspent wei back to the maker");
        _assertResidue();
    }

    function test_lend_gates() public {
        vm.startPrank(address(settlement));
        // Wrong side: a buy offer would make the maker a borrower.
        bytes memory buySide =
            abi.encode(_desc(MidnightPreFundModule.Op.Lend, address(LOAN), 0), _offer(true), bytes(""), RATE);
        vm.expectRevert(MidnightPreFundModule.WrongOfferSide.selector);
        preFund.makeOnBehalf(maker, 1e6, buySide);
        // The funding token must be the offer's loan token.
        bytes memory wrongTok =
            abi.encode(_desc(MidnightPreFundModule.Op.Lend, address(COLL), 0), _offer(false), bytes(""), RATE);
        vm.expectRevert(PreFundGuard.FundingTokenMismatch.selector);
        preFund.makeOnBehalf(maker, 1e6, wrongTok);
        // A 3-word head (no rate) cannot alias the rate onto a tail word.
        bytes memory shortHead =
            abi.encode(_desc(MidnightPreFundModule.Op.Lend, address(LOAN), 0), _offer(false), bytes(""));
        vm.expectRevert(MidnightBlob.MalformedData.selector);
        preFund.makeOnBehalf(maker, 1e6, shortHead);
        vm.expectRevert(abi.encodeWithSelector(MidnightPreFundModule.BadOp.selector, uint256(3)));
        preFund.makeOnBehalf(
            maker, 1e6, abi.encode(uint256(5) << 253 | uint256(3) << 244 | uint256(uint160(address(LOAN))) << 16, _market())
        );
        vm.stopPrank();
        (address asset,) = preFund.fundingSource(maker, _pfLend(RATE));
        assertEq(asset, address(LOAN), "lend funds from the loan token");
    }
}
