// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MockSettlementBase, MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Order, Item, ItemOp, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";

import {RiverPreFundModule} from "../../src/RiverPreFundModules.sol";
import {RiverTakerModule} from "../../src/RiverModules.sol";

/// @dev satUSD: the diamond mints it and BURNS it from `msg.sender` with no allowance.
contract RiverNettedSat is MockERC20 {
    constructor() MockERC20("satUSD") {}

    function burn(address from, uint256 a) external {
        balanceOf[from] -= a;
    }
}

/// @dev One TroveManager, per-account troves.
contract RiverNettedTM {
    address public immutable debtToken;
    address public immutable collateralToken;
    mapping(address => uint256) public debt;
    mapping(address => uint256) public coll;

    constructor(address d, address c) {
        debtToken = d;
        collateralToken = c;
    }

    function book(address a, int256 dDebt, int256 dColl) external {
        debt[a] = uint256(int256(debt[a]) + dDebt);
        coll[a] = uint256(int256(coll[a]) + dColl);
    }

    function getEntireDebtAndColl(address a) external view returns (uint256, uint256, uint256, uint256) {
        return (debt[a], coll[a], 0, 0);
    }
}

/// @dev The deployed diamond's fund flow (fork-validated, see `IRiver.sol`): value-IN
///      pulled from `msg.sender`; value-OUT lands on `msg.sender` (the delegate);
///      `repayDebt` BURNS from `msg.sender`; every op is caller-or-delegate gated;
///      a trove opens once; net debt must stay ≥ MIN_NET_DEBT.
contract RiverNettedXApp {
    uint256 public constant MIN_NET_DEBT = 10e18;
    mapping(address => mapping(address => bool)) public isApprovedDelegate;

    function setDelegateApproval(address d, bool ok) external {
        isApprovedDelegate[msg.sender][d] = ok;
    }

    function _auth(address account) internal view {
        require(account == msg.sender || isApprovedDelegate[account][msg.sender], "Caller not approved");
    }

    function openTrove(address tm, address account, uint256, uint256 collAmt, uint256 debtAmt, address, address)
        external
    {
        _auth(account);
        RiverNettedTM t = RiverNettedTM(tm);
        require(t.debt(account) == 0, "trove exists");
        require(debtAmt >= MIN_NET_DEBT, "min net debt");
        MockERC20(t.collateralToken()).transferFrom(msg.sender, address(this), collAmt);
        t.book(account, int256(debtAmt), int256(collAmt));
        MockERC20(t.debtToken()).mint(msg.sender, debtAmt);
    }

    function addColl(address tm, address account, uint256 amt, address, address) external {
        _auth(account);
        RiverNettedTM t = RiverNettedTM(tm);
        MockERC20(t.collateralToken()).transferFrom(msg.sender, address(this), amt);
        t.book(account, 0, int256(amt));
    }

    function withdrawColl(address tm, address account, uint256 amt, address, address) external {
        _auth(account);
        RiverNettedTM t = RiverNettedTM(tm);
        t.book(account, 0, -int256(amt));
        MockERC20(t.collateralToken()).transfer(msg.sender, amt);
    }

    function repayDebt(address tm, address account, uint256 amt, address, address) external {
        _auth(account);
        RiverNettedTM t = RiverNettedTM(tm);
        require(t.debt(account) - amt >= MIN_NET_DEBT, "net debt below minimum");
        RiverNettedSat(t.debtToken()).burn(msg.sender, amt);
        t.book(account, -int256(amt), 0);
    }
}

/// @title RiverNettedPreFundTest
/// @notice River's pre-fund family on the NETTED path (`matchSettle`, review 2026-10-18
///         M-6), with the new pre-funded trove OPEN (M-5: River's side leg — the
///         collateral {RiverOpenModule} pulls from the maker's wallet — delivered by
///         the fill instead). Every scenario parks two makers' deliveries on the ONE
///         singleton (which also carries collateral and satUSD residue) before either
///         item runs; counterparties are CoW orders, so every plan settles at zero
///         solver capital — and, for the open, zero maker wallet: the mint IS the
///         payment. The CLOSE is the acyclic shape: withdraw-collateral TAKE early,
///         sell, pre-funded repay late.
contract RiverNettedPreFundTest is MockSettlementBase {
    RiverPreFundModule preFund;
    RiverTakerModule taker;
    RiverNettedSat sat;
    RiverNettedTM tm;
    RiverNettedXApp xapp;

    uint256 bobPk = 0xB0B;
    address bob = vm.addr(bobPk);
    uint256 carolPk = 0xCA201;
    address carol = vm.addr(carolPk);
    uint256 malloryPk = 0xBAD;
    address mallory = vm.addr(malloryPk);

    uint256 constant RESIDUE_C = 3e18; // collateral (tB) on the singleton
    uint256 constant RESIDUE_S = 4e18; // satUSD on the singleton

    function setUp() public override {
        super.setUp();
        sat = new RiverNettedSat();
        tm = new RiverNettedTM(address(sat), address(tB));
        xapp = new RiverNettedXApp();
        preFund = new RiverPreFundModule(address(permit3), address(settlement));
        taker = new RiverTakerModule(address(permit3));
        vm.label(address(preFund), "preFund");
        tB.mint(address(preFund), RESIDUE_C);
        sat.mint(address(preFund), RESIDUE_S);
        _delegate(maker, address(preFund));
        _delegate(bob, address(preFund));
        _delegate(mallory, address(preFund));
    }

    // ──────────────────── builders ────────────────────

    function _delegate(address who, address module) internal {
        vm.prank(who);
        xapp.setDelegateApproval(module, true);
    }

    function _approveAs(address who, address token) internal {
        vm.startPrank(who);
        MockERC20(token).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), token, type(uint160).max, 0);
        vm.stopPrank();
    }

    function _desc(RiverPreFundModule.Op op, address token, uint256 j) internal pure returns (uint256) {
        return (uint256(5) << 253) | (uint256(op) << 244) | (uint256(uint160(token)) << 16) | j;
    }

    function _openData(uint256 total) internal view returns (bytes memory) {
        return abi.encode(
            RiverPreFundModule.OpenData({
                forDesc: _desc(RiverPreFundModule.Op.Open, address(tB), 0),
                xapp: address(xapp),
                tm: address(tm),
                collateralToken: address(tB),
                debtToken: address(sat),
                maxFeePercentage: 0,
                upperHint: address(0),
                lowerHint: address(0),
                totalAmount: total
            })
        );
    }

    function _addCollData() internal view returns (bytes memory) {
        return abi.encode(
            _desc(RiverPreFundModule.Op.AddColl, address(tB), 0), address(xapp), address(tm), address(tB), address(0), address(0)
        );
    }

    function _repayData() internal view returns (bytes memory) {
        return abi.encode(
            _desc(RiverPreFundModule.Op.Repay, address(sat), 0), address(xapp), address(tm), address(sat), address(0), address(0)
        );
    }

    /// @dev `who` opens a trove: `coll` tB delivered to the pre-fund module, which
    ///      opens with it and mints `mint` satUSD into the pool — the proceeds that
    ///      pay `who`'s own input leg. No PULL, no wallet balance.
    function _open(address who, uint256 mint, uint256 coll) internal returns (Order memory o) {
        bytes memory data = _openData(mint);
        o = _blank(1);
        o.maker = who;
        o.legsIn = PackedEncode.oneLegIn(address(sat), mint, 0);
        o.legsOut = PackedEncode.oneLegOut(address(tB), coll, 0, address(preFund));
        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.TAKE_FOR, module: address(preFund), amount: mint, recipient: address(0), data: data});
        o.items = PackedEncode.items(items);
        vm.prank(who);
        permit3.approveTaker(address(settlement), address(preFund), keccak256(data), type(uint160).max, 0);
    }

    function _preFundMake(address who, uint256 amtIn, address tokOut, uint256 amtOut, bytes memory data)
        internal
        view
        returns (Order memory o)
    {
        o = _blank(1);
        o.maker = who;
        o.legsIn = PackedEncode.oneLegIn(address(tA), amtIn, 0);
        o.legsOut = PackedEncode.oneLegOut(tokOut, amtOut, 0, address(preFund));
        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.MAKE, module: address(preFund), amount: 0, recipient: address(0), data: data});
        o.items = PackedEncode.items(items);
    }

    function _cow(address tokIn, uint256 amtIn, address tokOut, uint256 amtOut) internal view returns (Order memory o) {
        o = _blank(1);
        o.maker = carol;
        o.legsIn = PackedEncode.oneLegIn(tokIn, amtIn, 0);
        o.legsOut = PackedEncode.oneLegOut(tokOut, amtOut, 0, address(0));
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

    function _assertResidue() internal view {
        assertEq(tB.balanceOf(address(preFund)), RESIDUE_C, "collateral residue intact");
        assertEq(sat.balanceOf(address(preFund)), RESIDUE_S, "satUSD residue intact");
        assertEq(tB.allowance(address(preFund), address(xapp)), 0, "collateral approval cleared");
    }

    // ──────────────────── pre-funded OPEN (M-5: the side leg) ────────────────────

    /// Two trove opens on ONE singleton, deliveries parked ahead of both items:
    /// PULL carol (collateral) → DELIVER O1 → DELIVER O2 → ITEM O2 → ITEM O1 → DELIVER
    /// carol. Each opens with exactly its own collateral, each mint pays its own input
    /// leg, and Carol (who sold the collateral) is paid out of the two mints.
    function test_netted_twoOpens_interleaved_eachOpensWithItsOwnCollateral() public {
        (uint256 m1, uint256 c1, uint256 m2, uint256 c2) = (500e18, 9e18, 300e18, 4e18);
        Order memory o1 = _open(maker, m1, c1);
        Order memory o2 = _open(bob, m2, c2);
        tB.mint(carol, c1 + c2);
        _approveAs(carol, address(tB));
        Order memory c = _cow(address(tB), c1 + c2, address(sat), m1 + m2);

        uint256[] memory s = new uint256[](6);
        s[0] = _step(MatchStep.PULL, 2, 0);
        s[1] = _step(MatchStep.DELIVER, 0, 0);
        s[2] = _step(MatchStep.DELIVER, 1, 0);
        s[3] = _step(MatchStep.ITEM, 1, 0);
        s[4] = _step(MatchStep.ITEM, 0, 0);
        s[5] = _step(MatchStep.DELIVER, 2, 0);
        MatchPlan memory p = _plan(_o(o1, o2, c), _u(makerPk, bobPk, carolPk), _u(m1, m2, c1 + c2), s);

        vm.prank(solver);
        settlement.matchSettle(p);

        (uint256 d1, uint256 k1,,) = tm.getEntireDebtAndColl(maker);
        (uint256 d2, uint256 k2,,) = tm.getEntireDebtAndColl(bob);
        assertEq(k1, c1, "O1 opened with exactly its delivery");
        assertEq(k2, c2, "O2 opened with exactly its delivery");
        assertEq(d1, m1, "O1 minted its signed debt");
        assertEq(d2, m2, "O2 minted its signed debt");
        assertEq(sat.balanceOf(carol), m1 + m2, "carol paid out of the two mints");
        assertEq(tB.balanceOf(maker) + sat.balanceOf(maker), 0, "alice's wallet untouched");
        assertEq(tB.balanceOf(bob) + sat.balanceOf(bob), 0, "bob's wallet untouched");
        _assertResidue();
        assertEq(tB.balanceOf(solver) + sat.balanceOf(solver), 0, "zero solver capital");
    }

    /// The open hoisted ahead of its own collateral delivery, with the sibling's
    /// (larger) collateral parked on the singleton: the core ledger refuses it.
    function test_netted_open_itemBeforeOwnDelivery_failsClosed() public {
        Order memory o1 = _open(maker, 500e18, 2e18);
        Order memory o2 = _open(bob, 300e18, 4e18);
        tB.mint(carol, 6e18);
        _approveAs(carol, address(tB));
        Order memory c = _cow(address(tB), 6e18, address(sat), 800e18);
        uint256[] memory s = new uint256[](6);
        s[0] = _step(MatchStep.PULL, 2, 0);
        s[1] = _step(MatchStep.DELIVER, 1, 0);
        s[2] = _step(MatchStep.ITEM, 0, 0);
        s[3] = _step(MatchStep.DELIVER, 0, 0);
        s[4] = _step(MatchStep.ITEM, 1, 0);
        s[5] = _step(MatchStep.DELIVER, 2, 0);
        MatchPlan memory p = _plan(_o(o1, o2, c), _u(makerPk, bobPk, carolPk), _u(500e18, 300e18, 6e18), s);

        vm.prank(solver);
        vm.expectRevert(Base.ForLegInvalid.selector);
        settlement.matchSettle(p);
    }

    // ──────────────────── pre-funded MAKEs (add / repay) ────────────────────

    /// Mallory's repay names an account with NO debt (so nothing is burned and the
    /// module sweeps everything above the floor to her) while Bob's add-collateral
    /// delivery and Alice's repay delivery are parked on the same singleton. The floor
    /// makes her sweep exactly her own; Alice repays exactly hers; Bob adds exactly his.
    function test_netted_addCollAndRepays_interleaved_hostileZeroDebtSweep() public {
        tm.book(maker, 100e18, 50e18); // alice: an open trove, debt well above the delivery
        tm.book(bob, 100e18, 50e18);
        (uint256 outA, uint256 outB, uint256 outM) = (20e18, 6e18, 11e18);
        tA.mint(maker, 1_000e18);
        tA.mint(bob, 1_000e18);
        tA.mint(mallory, 1);
        _approveAs(maker, address(tA));
        _approveAs(bob, address(tA));
        _approveAs(mallory, address(tA));
        Order memory a = _preFundMake(maker, 1_000e18, address(sat), outA, _repayData());
        Order memory b = _preFundMake(bob, 1_000e18, address(tB), outB, _addCollData());
        Order memory m = _preFundMake(mallory, 1, address(sat), outM, _repayData());
        // Two CoWs from Carol: satUSD for alice + mallory, collateral for bob.
        sat.mint(carol, outA + outM);
        tB.mint(carol, outB);
        _approveAs(carol, address(sat));
        _approveAs(carol, address(tB));
        Order memory cS = _cow(address(sat), outA + outM, address(tA), 1_000e18 + 1);
        Order memory cB = _cow(address(tB), outB, address(tA), 1_000e18);
        cB.nonce = 2;

        Order[] memory orders = new Order[](5);
        (orders[0], orders[1], orders[2], orders[3], orders[4]) = (a, b, m, cS, cB);
        uint256[] memory pks = new uint256[](5);
        (pks[0], pks[1], pks[2], pks[3], pks[4]) = (makerPk, bobPk, malloryPk, carolPk, carolPk);
        uint256[] memory fills = new uint256[](5);
        (fills[0], fills[1], fills[2], fills[3], fills[4]) = (1_000e18, 1_000e18, 1, outA + outM, outB);
        uint256[] memory s = new uint256[](13);
        for (uint256 i; i < 5; i++) {
            s[i] = _step(MatchStep.PULL, i, 0);
        }
        s[5] = _step(MatchStep.DELIVER, 0, 0); // alice's satUSD parks
        s[6] = _step(MatchStep.DELIVER, 1, 0); // bob's collateral parks
        s[7] = _step(MatchStep.DELIVER, 2, 0); // mallory's satUSD parks
        s[8] = _step(MatchStep.ITEM, 2, 0); //    mallory "sweeps everything above the floor"
        s[9] = _step(MatchStep.ITEM, 1, 0);
        s[10] = _step(MatchStep.ITEM, 0, 0);
        s[11] = _step(MatchStep.DELIVER, 3, 0);
        s[12] = _step(MatchStep.DELIVER, 4, 0);
        MatchPlan memory p = _plan(orders, pks, fills, s);

        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(sat.balanceOf(mallory), outM, "mallory swept back exactly her own delivery");
        (uint256 dA,,,) = tm.getEntireDebtAndColl(maker);
        assertEq(dA, 100e18 - outA, "alice's repay was fully funded after mallory's sweep");
        (, uint256 kB,,) = tm.getEntireDebtAndColl(bob);
        assertEq(kB, 50e18 + outB, "bob added exactly his delivery");
        assertEq(sat.balanceOf(maker) + tB.balanceOf(bob), 0, "nobody else was swept anything");
        _assertResidue();
        assertEq(tA.balanceOf(solver) + tB.balanceOf(solver) + sat.balanceOf(solver), 0, "zero solver capital");
    }

    // ──────────────────── the acyclic CLOSE at zero capital ────────────────────

    /// Alice withdraws collateral EARLY (TAKE; the diamond pays the module, which
    /// settles to the pool), Carol buys it with satUSD, and the satUSD is delivered to
    /// the pre-fund module and repaid LATE — a partial repay, since River refuses to
    /// retire the whole debt through `repayDebt`.
    function test_netted_close_withdrawEarly_repayLate_zeroCapital() public {
        uint256 collOut = 15e18;
        uint256 satIn = 60e18;
        tm.book(maker, 100e18, 50e18);
        tB.mint(address(xapp), 50e18); // the trove's collateral, held by the diamond
        _delegate(maker, address(taker));

        bytes memory wData = abi.encode(uint8(1), address(xapp), address(tm), address(tB), address(0), address(0));
        Order memory a = _blank(1);
        a.legsIn = PackedEncode.oneLegIn(address(tB), collOut, 0);
        a.legsOut = PackedEncode.oneLegOut(address(sat), satIn, 0, address(preFund));
        {
            Item[] memory items = new Item[](2);
            items[0] = Item({op: ItemOp.TAKE, module: address(taker), amount: collOut, recipient: address(0), data: wData});
            items[1] = Item({op: ItemOp.MAKE, module: address(preFund), amount: 0, recipient: address(0), data: _repayData()});
            a.items = PackedEncode.items(items);
        }
        vm.prank(maker);
        permit3.approveTaker(address(settlement), address(taker), keccak256(wData), type(uint160).max, 0);
        sat.mint(carol, satIn);
        _approveAs(carol, address(sat));
        Order memory c = _cow(address(sat), satIn, address(tB), collOut);

        Order[] memory orders = new Order[](2);
        (orders[0], orders[1]) = (a, c);
        uint256[] memory pks = new uint256[](2);
        (pks[0], pks[1]) = (makerPk, carolPk);
        uint256[] memory fills = new uint256[](2);
        (fills[0], fills[1]) = (collOut, satIn);
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

        (uint256 d, uint256 k,,) = tm.getEntireDebtAndColl(maker);
        assertEq(d, 100e18 - satIn, "the whole delivery repaid");
        assertEq(k, 50e18 - collOut, "exactly the signed collateral withdrawn");
        assertEq(tB.balanceOf(carol), collOut, "carol paid in collateral");
        assertEq(tB.balanceOf(maker) + sat.balanceOf(maker), 0, "alice's wallet untouched");
        _assertResidue();
        assertEq(tB.balanceOf(solver) + sat.balanceOf(solver), 0, "zero solver capital");
    }

    /// The same pre-funded open on the FORWARD path (`fill`): the filler delivers the
    /// collateral to the module and is paid in the minted satUSD — the maker's wallet
    /// is never touched and holds no approval for the collateral.
    function test_forward_open_fill() public {
        (uint256 m, uint256 c) = (500e18, 9e18);
        Order memory o = _open(maker, m, c);
        bytes memory sig = _sign(o);
        tB.mint(solver, c);
        _solverApprove(address(settlement), address(tB), c);

        vm.prank(solver);
        settlement.fill(o, sig, m);

        (uint256 d, uint256 k,,) = tm.getEntireDebtAndColl(maker);
        assertEq(k, c, "opened with the delivered collateral");
        assertEq(d, m, "minted the signed debt");
        assertEq(sat.balanceOf(solver), m, "filler paid out of the mint");
        assertEq(tB.balanceOf(maker) + sat.balanceOf(maker), 0, "maker wallet untouched");
        _assertResidue();
    }

    // ──────────────────── the open's gates ────────────────────

    /// `Permit3.takeFor` is permissionless: a caller that names ITSELF spender (with
    /// its own taker grant) reaches the module with a `forAmount` of its choosing.
    /// The spender pin is what stops it spending the singleton's residue.
    function test_open_directTakeFor_selfGrantedSpender_refused() public {
        bytes memory data = _openData(100e18);
        vm.startPrank(mallory);
        permit3.approveTaker(mallory, address(preFund), keccak256(data), type(uint160).max, 0);
        vm.expectRevert(PreFundGuard.OnlySettlement.selector);
        permit3.takeFor(address(preFund), mallory, 100e18, uint160(RESIDUE_C), mallory, data);
        vm.stopPrank();
        _assertResidue();
    }

    function test_open_gates() public {
        bytes memory good = _openData(100e18);
        // Caller is not Permit3.
        vm.expectRevert(PreFundModuleBase.OnlyPermit3.selector);
        preFund.takeForOnBehalf(address(settlement), maker, 100e18, 1e18, maker, good);
        vm.startPrank(address(permit3));
        // A sliced fill would re-open the trove.
        vm.expectRevert(abi.encodeWithSelector(FullFillGuard.PartialFillUnsupported.selector, 50e18, 100e18));
        preFund.takeForOnBehalf(address(settlement), maker, 50e18, 1e18, maker, good);
        // The PULL descriptor form is {RiverOpenModule}'s, not this seam's.
        bytes memory pull = abi.encode(
            RiverPreFundModule.OpenData({
                forDesc: (uint256(1) << 255) | (uint256(2) << 244) | (uint256(uint160(address(tB))) << 16),
                xapp: address(xapp),
                tm: address(tm),
                collateralToken: address(tB),
                debtToken: address(sat),
                maxFeePercentage: 0,
                upperHint: address(0),
                lowerHint: address(0),
                totalAmount: 100e18
            })
        );
        vm.expectRevert(PreFundGuard.PreFundDescriptorRequired.selector);
        preFund.takeForOnBehalf(address(settlement), maker, 100e18, 1e18, maker, pull);
        // The add-collateral op is a MAKE: unreachable through takeFor.
        vm.expectRevert(abi.encodeWithSelector(RiverPreFundModule.BadOp.selector, uint256(0)));
        preFund.takeForOnBehalf(address(settlement), maker, 100e18, 1e18, maker, _addCollData());
        // A debt token that is not the TroveManager's.
        bytes memory wrongDebt = abi.encode(
            RiverPreFundModule.OpenData({
                forDesc: _desc(RiverPreFundModule.Op.Open, address(tB), 0),
                xapp: address(xapp),
                tm: address(tm),
                collateralToken: address(tB),
                debtToken: address(tA),
                maxFeePercentage: 0,
                upperHint: address(0),
                lowerHint: address(0),
                totalAmount: 100e18
            })
        );
        vm.expectRevert(abi.encodeWithSelector(RiverPreFundModule.DebtTokenMismatch.selector, address(tA), address(sat)));
        preFund.takeForOnBehalf(address(settlement), maker, 100e18, 1e18, maker, wrongDebt);
        vm.stopPrank();
        // And the open is a TAKE_FOR: unreachable through the MAKE seam.
        vm.prank(address(settlement));
        vm.expectRevert(abi.encodeWithSelector(RiverPreFundModule.BadOp.selector, uint256(2)));
        preFund.makeOnBehalf(maker, 1e18, good);
        (address asset,) = preFund.fundingSource(maker, good);
        assertEq(asset, address(tB), "the open funds from the collateral");
    }
}
