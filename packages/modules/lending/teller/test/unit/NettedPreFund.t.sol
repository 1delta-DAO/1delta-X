// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MockSettlementBase, MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Order, Item, ItemOp, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";

import {TellerPreFundModule} from "../../src/TellerPreFundModules.sol";

/// @dev ERC-4626-shaped Teller V2/V3 pool. `deposit` pulls `assets` from the caller
///      and books it per `receiver`, so a test can tell which maker each wei went to.
///      It MODELS the Hypernative firewall the live pool carries
///      (`onlyOracleApprovedAllowEOA`): a contract caller that was never registered
///      reverts "Account not registered" — the deploy step the README requires for
///      the pre-fund singleton. `consumeBps` lets a test stand in for a venue that
///      consumes LESS than instructed (the case the module's floor-relative sweep is
///      for); 10_000 = an honest pool.
contract NettedMockTellerPool {
    MockERC20 public immutable asset;
    mapping(address => uint256) public deposited;
    mapping(address => bool) public registered;
    uint256 public consumeBps = 10_000;

    constructor(MockERC20 _asset) {
        asset = _asset;
    }

    function register(address account) external {
        registered[account] = true;
    }

    function setConsumeBps(uint256 bps) external {
        consumeBps = bps;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256) {
        if (msg.sender != tx.origin && !registered[msg.sender]) revert("Account not registered");
        uint256 take = assets * consumeBps / 10_000;
        asset.transferFrom(msg.sender, address(this), take);
        deposited[receiver] += take;
        return take;
    }
}

/// @dev TellerV2 repay surface modelled on the DEPLOYED implementation (as the
///      package's other unit tests do): `repayLoanFull` pulls exactly owed,
///      `repayLoan` transfers the UNCAPPED amount. Payments are booked per bid.
contract NettedMockTellerV2 {
    MockERC20 public immutable principal;
    mapping(uint256 => uint256) public owed;
    mapping(uint256 => address) public borrowerOf;
    mapping(uint256 => uint256) public received;

    struct Payment {
        uint256 principal;
        uint256 interest;
    }

    constructor(MockERC20 _principal) {
        principal = _principal;
    }

    function setLoan(uint256 bidId, address borrower, uint256 amount) external {
        borrowerOf[bidId] = borrower;
        owed[bidId] = amount;
    }

    function getLoanBorrower(uint256 bidId) external view returns (address) {
        return borrowerOf[bidId];
    }

    function calculateAmountOwed(uint256 bidId, uint256) external view returns (Payment memory p) {
        p.principal = owed[bidId];
    }

    function repayLoanFull(uint256 bidId) external {
        uint256 due = owed[bidId];
        owed[bidId] = 0;
        received[bidId] += due;
        principal.transferFrom(msg.sender, address(this), due);
    }

    function repayLoan(uint256 bidId, uint256 amount) external {
        uint256 due = owed[bidId];
        owed[bidId] = amount >= due ? 0 : due - amount;
        received[bidId] += amount;
        principal.transferFrom(msg.sender, address(this), amount);
    }
}

/// @title TellerNettedPreFundTest
/// @notice {TellerPreFundModule} on the NETTED path (`matchSettle`, task 31), both ops,
///         against mock venues with the REAL Settlement + Permit3. Closes review
///         2026-10-18 M-6 for this venue's `Op.PoolDeposit` (no live V2/V3 pool is
///         pinned in this repo and the live `deposit` is Hypernative-firewalled, so the
///         deposit cannot be driven on a fork — see `test/fork/NettedPreFundFork.t.sol`
///         for `Op.Repay` against the live TellerV2).
///
///         Teller is VALUE-IN ONLY, so every maker's input leg is a plain PULL from the
///         wallet; a counter-order (Carol, a CoW) supplies the delivered asset (tB),
///         which lands on the pre-fund singleton and is consumed late by the pre-funded
///         MAKE. The solver holds nothing. The singleton carries tB RESIDUE before every
///         plan.
contract TellerNettedPreFundTest is MockSettlementBase {
    TellerPreFundModule preFund;
    NettedMockTellerPool pool;
    NettedMockTellerV2 tellerV2;

    uint256 bobPk = 0xB0B;
    address bob = vm.addr(bobPk);
    uint256 carolPk = 0xCA201;
    address carol = vm.addr(carolPk);
    uint256 malloryPk = 0xBAD;
    address mallory = vm.addr(malloryPk);

    uint256 constant BID_B = 7;
    uint256 constant BID_M = 8;

    uint256 constant IN_A = 1_000e18;
    uint256 constant OUT_A = 13e18; //  alice: pool deposit
    uint256 constant IN_B = 2_000e18;
    uint256 constant OUT_B = 7e18; //   bob: repay, debt below the delivery
    uint256 constant DEBT_B = 5e18; //  → 2e18 must come back to BOB, and only to bob
    uint256 constant RESIDUE = 3e18; // stray tB already on the singleton

    function setUp() public override {
        super.setUp();
        preFund = new TellerPreFundModule(address(permit3), address(settlement));
        pool = new NettedMockTellerPool(tB);
        tellerV2 = new NettedMockTellerV2(tB);
        vm.label(address(preFund), "tellerPreFund");
        vm.label(address(pool), "tellerPool");
        vm.label(address(tellerV2), "tellerV2");

        pool.register(address(preFund)); // the README's per-chain deploy step
        tB.mint(address(preFund), RESIDUE);
        tellerV2.setLoan(BID_B, bob, DEBT_B);
    }

    // ──────────────────── builders ────────────────────

    function _approveAs(address who, address token) internal {
        vm.startPrank(who);
        MockERC20(token).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), token, type(uint160).max, 0);
        vm.stopPrank();
    }

    /// @dev Pre-fund leg reference (bits 255+253), op in [244,252), token in [16,176).
    function _desc(TellerPreFundModule.Op op, address token, uint256 j) internal pure returns (uint256) {
        return (uint256(5) << 253) | (uint256(op) << 244) | (uint256(uint160(token)) << 16) | j;
    }

    function _depositData() internal view returns (bytes memory) {
        return abi.encode(_desc(TellerPreFundModule.Op.PoolDeposit, address(tB), 0), address(pool), address(tB));
    }

    function _repayData(uint256 bidId) internal view returns (bytes memory) {
        return abi.encode(
            _desc(TellerPreFundModule.Op.Repay, address(tB), 0), address(tellerV2), address(tB), bidId, false
        );
    }

    /// @dev `who` pays `amtIn` tA (PULLed from the wallet) for `amtOut` tB delivered to
    ///      the singleton and consumed by one pre-funded MAKE carrying `data`.
    function _preFundOrder(address who, uint256 nonce, uint256 amtIn, uint256 amtOut, bytes memory data)
        internal
        returns (Order memory o)
    {
        tA.mint(who, amtIn);
        _approveAs(who, address(tA));
        o = _blank(nonce);
        o.maker = who;
        o.legsIn = PackedEncode.oneLegIn(address(tA), amtIn, 0);
        o.legsOut = PackedEncode.oneLegOut(address(tB), amtOut, 0, address(preFund));
        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.MAKE, module: address(preFund), amount: 0, recipient: address(0), data: data});
        o.items = PackedEncode.items(items);
    }

    /// @dev Carol, the CoW counter-order: sells `amtIn` tB for `amtOut` tA.
    function _carol(uint256 amtIn, uint256 amtOut) internal returns (Order memory o) {
        tB.mint(carol, amtIn);
        _approveAs(carol, address(tB));
        o = _blank(1);
        o.maker = carol;
        o.legsIn = PackedEncode.oneLegIn(address(tB), amtIn, 0);
        o.legsOut = PackedEncode.oneLegOut(address(tA), amtOut, 0, address(0));
    }

    function _s(uint256 kind, uint256 a, uint256 b) internal pure returns (uint256) {
        return MatchStep.pack(kind, a, b);
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
            sigs[i] = _signWith(orders[i], pks[i]);
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

    function _two(Order memory a, Order memory c, uint256 pkA)
        internal
        view
        returns (Order[] memory o, uint256[] memory pks)
    {
        o = new Order[](2);
        (o[0], o[1]) = (a, c);
        pks = new uint256[](2);
        (pks[0], pks[1]) = (pkA, carolPk);
    }

    function _three(Order memory a, Order memory b, Order memory c, uint256 pkA, uint256 pkB)
        internal
        view
        returns (Order[] memory o, uint256[] memory pks)
    {
        o = new Order[](3);
        (o[0], o[1], o[2]) = (a, b, c);
        pks = new uint256[](3);
        (pks[0], pks[1], pks[2]) = (pkA, pkB, carolPk);
    }

    /// @dev PULL every order, then `mid`, then pay Carol (the last order).
    function _withMiddle(uint256 nOrders, uint256[] memory mid) internal pure returns (uint256[] memory s) {
        s = new uint256[](nOrders + mid.length + 1);
        for (uint256 i; i < nOrders; i++) {
            s[i] = _s(MatchStep.PULL, i, 0);
        }
        for (uint256 i; i < mid.length; i++) {
            s[nOrders + i] = mid[i];
        }
        s[s.length - 1] = _s(MatchStep.DELIVER, nOrders - 1, 0);
    }

    function _assertSolverFlat() internal view {
        assertEq(tA.balanceOf(solver) + tB.balanceOf(solver), 0, "zero solver capital, zero take");
        assertEq(tA.balanceOf(address(settlement)) + tB.balanceOf(address(settlement)), 0, "nothing pooled");
        assertEq(tB.balanceOf(address(preFund)), RESIDUE, "singleton back to its residue");
        assertEq(tB.allowance(address(preFund), address(pool)), 0, "pool approval cleared");
        assertEq(tB.allowance(address(preFund), address(tellerV2)), 0, "tellerV2 approval cleared");
    }

    // ──────────────────── (a) netted pool deposit at zero capital ────────────────────

    function test_netted_preFundPoolDeposit_zeroCapital_teller() public {
        Order memory a = _preFundOrder(maker, 1, IN_A, OUT_A, _depositData());
        Order memory c = _carol(OUT_A, IN_A);
        (Order[] memory orders, uint256[] memory pks) = _two(a, c, makerPk);
        uint256[] memory mid = new uint256[](2);
        mid[0] = _s(MatchStep.DELIVER, 0, 0);
        mid[1] = _s(MatchStep.ITEM, 0, 0);
        MatchPlan memory p = _plan(orders, pks, _withMiddle(2, mid));

        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(pool.deposited(maker), OUT_A, "delivery deposited for the maker");
        assertEq(tA.balanceOf(maker) + tB.balanceOf(maker), 0, "input pulled, nothing swept");
        assertEq(tA.balanceOf(carol), IN_A, "carol paid out of the maker's PULL");
        _assertSolverFlat();
    }

    /// The Hypernative firewall on the netted path: an UNREGISTERED singleton makes the
    /// whole plan revert (atomic — nothing moves). The registration that matters is the
    /// MODULE's, not the solver's or Settlement's: `deposit`'s `msg.sender` is the module.
    function test_netted_preFundPoolDeposit_unregisteredModule_revertsWholePlan_teller() public {
        TellerPreFundModule fresh = new TellerPreFundModule(address(permit3), address(settlement));
        bytes memory data =
            abi.encode(_desc(TellerPreFundModule.Op.PoolDeposit, address(tB), 0), address(pool), address(tB));
        Order memory a = _preFundOrder(maker, 1, IN_A, OUT_A, data);
        a.legsOut = PackedEncode.oneLegOut(address(tB), OUT_A, 0, address(fresh));
        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.MAKE, module: address(fresh), amount: 0, recipient: address(0), data: data});
        a.items = PackedEncode.items(items);
        Order memory c = _carol(OUT_A, IN_A);
        (Order[] memory orders, uint256[] memory pks) = _two(a, c, makerPk);
        uint256[] memory mid = new uint256[](2);
        mid[0] = _s(MatchStep.DELIVER, 0, 0);
        mid[1] = _s(MatchStep.ITEM, 0, 0);
        MatchPlan memory p = _plan(orders, pks, _withMiddle(2, mid));

        vm.prank(solver, solver); // tx.origin = the solver EOA, as in production
        vm.expectRevert(bytes("Account not registered"));
        settlement.matchSettle(p);
        assertEq(tA.balanceOf(maker), IN_A, "maker untouched");
        assertEq(tB.balanceOf(carol), OUT_A, "carol untouched");
    }

    // ──────────────────── (b) netted repay, over-delivery swept ────────────────────

    function test_netted_preFundRepay_overDelivery_sweptToMaker_teller() public {
        Order memory b = _preFundOrder(bob, 1, IN_B, OUT_B, _repayData(BID_B));
        Order memory c = _carol(OUT_B, IN_B);
        (Order[] memory orders, uint256[] memory pks) = _two(b, c, bobPk);
        uint256[] memory mid = new uint256[](2);
        mid[0] = _s(MatchStep.DELIVER, 0, 0);
        mid[1] = _s(MatchStep.ITEM, 0, 0);
        MatchPlan memory p = _plan(orders, pks, _withMiddle(2, mid));

        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(tellerV2.owed(BID_B), 0, "loan retired");
        assertEq(tellerV2.received(BID_B), DEBT_B, "lender got exactly owed (clamped to repayLoanFull)");
        assertEq(tB.balanceOf(bob), OUT_B - DEBT_B, "exactly the unconsumed delivery swept back");
        assertEq(tA.balanceOf(carol), IN_B, "carol paid");
        _assertSolverFlat();
    }

    // ──────────────────── (c) two makers interleaved on ONE singleton ────────────────────

    /// DELIVER A (deposit, 13), DELIVER B (repay, 7 vs debt 5), ITEM B, ITEM A. When
    /// ITEM B sweeps, the singleton holds residue + A's 13 + B's 7; the floor is
    /// `residue + 13`, so B's sweep returns exactly B's unconsumed 2 — to bob — and A's
    /// delivery is intact for A's deposit.
    function test_netted_depositAndRepayInterleaved_eachConsumesAndSweepsOnlyItsOwn_teller() public {
        (Order[] memory orders, uint256[] memory pks) = _three(
            _preFundOrder(maker, 1, IN_A, OUT_A, _depositData()),
            _preFundOrder(bob, 1, IN_B, OUT_B, _repayData(BID_B)),
            _carol(OUT_A + OUT_B, IN_A + IN_B),
            makerPk,
            bobPk
        );
        uint256[] memory mid = new uint256[](4);
        mid[0] = _s(MatchStep.DELIVER, 0, 0);
        mid[1] = _s(MatchStep.DELIVER, 1, 0);
        mid[2] = _s(MatchStep.ITEM, 1, 0);
        mid[3] = _s(MatchStep.ITEM, 0, 0);
        MatchPlan memory p = _plan(orders, pks, _withMiddle(3, mid));

        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(pool.deposited(maker), OUT_A, "alice deposited exactly her delivery");
        assertEq(tellerV2.received(BID_B), DEBT_B, "bob repaid his debt, clamped");
        assertEq(tB.balanceOf(bob), OUT_B - DEBT_B, "bob got back exactly his unconsumed slice");
        assertEq(tB.balanceOf(maker), 0, "alice received no sweep of anyone's tB");
        assertEq(tA.balanceOf(carol), IN_A + IN_B, "carol paid");
        _assertSolverFlat();
    }

    /// The same interleaving with the DEPOSIT as the under-consuming side: Alice's
    /// pool takes only 90 % (a venue consuming less than instructed — the case the
    /// deposit's floor-relative sweep exists for), and it runs FIRST, while Bob's
    /// delivery is parked: DELIVER B, DELIVER A, ITEM A, ITEM B. Alice's sweep must
    /// return exactly her unconsumed 10 %, leaving Bob's 7 for Bob's repay.
    function test_netted_shortConsumingDepositFirst_sweepsOnlyItsOwn_teller() public {
        pool.setConsumeBps(9_000);
        (Order[] memory orders, uint256[] memory pks) = _three(
            _preFundOrder(maker, 1, IN_A, OUT_A, _depositData()),
            _preFundOrder(bob, 1, IN_B, OUT_B, _repayData(BID_B)),
            _carol(OUT_A + OUT_B, IN_A + IN_B),
            makerPk,
            bobPk
        );
        uint256[] memory mid = new uint256[](4);
        mid[0] = _s(MatchStep.DELIVER, 1, 0);
        mid[1] = _s(MatchStep.DELIVER, 0, 0);
        mid[2] = _s(MatchStep.ITEM, 0, 0);
        mid[3] = _s(MatchStep.ITEM, 1, 0);
        MatchPlan memory p = _plan(orders, pks, _withMiddle(3, mid));

        vm.prank(solver);
        settlement.matchSettle(p);

        uint256 consumed = OUT_A * 9_000 / 10_000;
        assertEq(pool.deposited(maker), consumed, "alice deposited what the venue took");
        assertEq(tB.balanceOf(maker), OUT_A - consumed, "alice swept exactly her own unconsumed 10%");
        assertEq(tellerV2.received(BID_B), DEBT_B, "bob's repay fully funded after alice's sweep");
        assertEq(tB.balanceOf(bob), OUT_B - DEBT_B, "bob's own surplus");
        _assertSolverFlat();
    }

    /// A hostile maker: Mallory's repay names her own loan with NOTHING owed, so the
    /// venue consumes zero and the module sweeps everything above the floor to her —
    /// while Bob's delivery is parked on the same singleton. The floor makes her sweep
    /// exactly her OWN delivery; Bob's repay then runs fully funded.
    function test_netted_hostileZeroConsumeRepay_takesOnlyItsOwnDelivery_teller() public {
        tellerV2.setLoan(BID_M, mallory, 0);
        uint256 outM = 11e18;
        (Order[] memory orders, uint256[] memory pks) = _three(
            _preFundOrder(mallory, 1, 1, outM, _repayData(BID_M)),
            _preFundOrder(bob, 1, IN_B, OUT_B, _repayData(BID_B)),
            _carol(outM + OUT_B, IN_B + 1),
            malloryPk,
            bobPk
        );
        uint256[] memory mid = new uint256[](4);
        mid[0] = _s(MatchStep.DELIVER, 1, 0); // bob's 7 parks first
        mid[1] = _s(MatchStep.DELIVER, 0, 0); // mallory's 11
        mid[2] = _s(MatchStep.ITEM, 0, 0); //    mallory sweeps "everything above the floor"
        mid[3] = _s(MatchStep.ITEM, 1, 0);
        MatchPlan memory p = _plan(orders, pks, _withMiddle(3, mid));

        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(tB.balanceOf(mallory), outM, "mallory swept back exactly her own delivery");
        assertEq(tellerV2.received(BID_B), DEBT_B, "bob's repay was fully funded");
        assertEq(tB.balanceOf(bob), OUT_B - DEBT_B, "bob's own surplus, untouched by mallory");
        _assertSolverFlat();
    }

    // ──────────────────── (d) pre-fund item before its own DELIVER ────────────────────

    /// ITEM A (deposit) scheduled before DELIVER A while B's delivery and the residue
    /// sit on the singleton — enough balance for A's floor NOT to underflow. The core
    /// ledger refuses it.
    function test_netted_depositBeforeOwnDelivery_failsClosed_teller() public {
        uint256 outA = 2e18; // below residue + bob's parked 7
        (Order[] memory orders, uint256[] memory pks) = _three(
            _preFundOrder(maker, 1, IN_A, outA, _depositData()),
            _preFundOrder(bob, 1, IN_B, OUT_B, _repayData(BID_B)),
            _carol(outA + OUT_B, IN_A + IN_B),
            makerPk,
            bobPk
        );
        uint256[] memory mid = new uint256[](4);
        mid[0] = _s(MatchStep.DELIVER, 1, 0);
        mid[1] = _s(MatchStep.ITEM, 1, 0);
        mid[2] = _s(MatchStep.ITEM, 0, 0); // alice's item before alice's delivery
        mid[3] = _s(MatchStep.DELIVER, 0, 0);
        MatchPlan memory p = _plan(orders, pks, _withMiddle(3, mid));

        vm.prank(solver);
        vm.expectRevert(Base.ForLegInvalid.selector);
        settlement.matchSettle(p);
    }

    function test_netted_repayBeforeOwnDelivery_failsClosed_teller() public {
        uint256 outB = 2e18; // below the residue alone
        tellerV2.setLoan(BID_B, bob, outB);
        Order memory b = _preFundOrder(bob, 1, IN_B, outB, _repayData(BID_B));
        Order memory c = _carol(outB, IN_B);
        (Order[] memory orders, uint256[] memory pks) = _two(b, c, bobPk);
        uint256[] memory mid = new uint256[](2);
        mid[0] = _s(MatchStep.ITEM, 0, 0); // before DELIVER B
        mid[1] = _s(MatchStep.DELIVER, 0, 0);
        MatchPlan memory p = _plan(orders, pks, _withMiddle(2, mid));

        vm.prank(solver);
        vm.expectRevert(Base.ForLegInvalid.selector);
        settlement.matchSettle(p);
    }
}
