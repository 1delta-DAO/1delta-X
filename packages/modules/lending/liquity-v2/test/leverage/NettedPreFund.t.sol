// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, ItemPolicy, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";

import {LiquityV2PreFundModule} from "../../src/LiquityV2PreFundModules.sol";
import {LiquityV2TakerModule} from "../../src/LiquityV2Modules.sol";
import {ILiquityV2TroveManager, LatestTroveData} from "../../src/interfaces/ILiquityV2.sol";

/// @dev The open/onboarding surface beyond the module interface — the same plain
///      `openTrove` + remove-manager grant the leverage suite uses.
interface IBorrowerOpsNetted {
    function openTrove(
        address _owner,
        uint256 _ownerIndex,
        uint256 _collAmount,
        uint256 _boldAmount,
        uint256 _upperHint,
        uint256 _lowerHint,
        uint256 _annualInterestRate,
        uint256 _maxUpfrontFee,
        address _addManager,
        address _removeManager,
        address _receiver
    ) external returns (uint256);

    function setRemoveManagerWithReceiver(uint256 _troveId, address _manager, address _receiver) external;
}

/// @title LiquityV2NettedPreFundTest
/// @notice The Liquity V2 pre-fund module on the NETTED path (`matchSettle`, task 31),
///         against the live Ethereum mainnet WETH branch. Closes review 2026-10-18 M-6
///         for this venue: plan §4.1 requires the netted interleaving to be tested on
///         every pre-fund module.
///
///         Liquity has no on-behalf open, so every flow acts on an EXISTING trove:
///         OPEN = leverage up (borrow BOLD early → pre-fund AddColl late), CLOSE =
///         deleverage (withdraw WETH early → pre-fund Repay late). Every plan is
///         ACYCLIC and filled with ZERO solver capital:
///
///           PULL carol → ITEM(A, 0: TAKE) → PULL A (draws nothing) → DELIVER A
///                      → ITEM(A, 1: pre-fund MAKE) → DELIVER carol
///
///         The troves have NO add manager, so the value-in ops (addColl/repayBold) are
///         permissionless at the venue and the pre-fund module needs no grant; the
///         value-out ops need the taker module as remove manager + receiver.
///
///         Liquity's repay CLAMP: BorrowerOperations silently caps a repayment at
///         `entireDebt − MIN_DEBT` (a trove cannot be repaid below 2000 BOLD — only
///         closed, which no module exposes). An over-delivering close therefore lands
///         the trove exactly on MIN_DEBT and the module sweeps the un-repayable
///         remainder to the maker, measured against the pre-call floor.
///
///         Both the pre-fund singleton and the taker module carry RESIDUE before every
///         plan, so a sweep/forward sized from anything but this call's own delta
///         would show up as residue reaching a maker.
contract LiquityV2NettedPreFundTest is CoreSettlementBase {
    // ── Verified Ethereum mainnet addresses (Liquity V2, WETH branch) — same set
    //    and pin as test/leverage/Leverage.t.sol and PreFundOneSided.t.sol. ──
    address internal constant TROVE_MANAGER = 0x7bcb64B2c9206a5B699eD43363f6F98D4776Cf5A;
    address internal constant COLLATERAL_REGISTRY = 0xf949982B91C8c61e952B3bA942cbbfaef5386684;
    uint256 internal constant BRANCH = 0; // WETH branch
    address internal constant BORROWER_OPS = 0x372ABD1810eAF23Cb9D941BbE7596DFb2c46BC65;
    address internal constant BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;

    uint256 internal constant ETH_GAS_COMPENSATION = 0.0375 ether;
    uint256 internal constant OPEN_COLL = 10 ether;
    /// @dev Opened ABOVE the 2000-BOLD minimum so a close has a repayable band.
    uint256 internal constant OPEN_DEBT = 4000e18;
    uint256 internal constant MIN_DEBT = 2000e18;
    uint256 internal constant INTEREST_RATE = 0.25e18;

    uint256 internal constant RESIDUE_BOLD = 77e18; //   stray balance already on the singletons
    uint256 internal constant RESIDUE_WETH = 0.07 ether;

    // Interleaved-close amounts: Alice overshoots her band, Bob stays inside his.
    uint256 internal constant CLOSE_A_IN = 0.5 ether;
    uint256 internal constant CLOSE_A_OUT = 2_600e18;
    uint256 internal constant CLOSE_B_IN = 0.2 ether;
    uint256 internal constant CLOSE_B_OUT = 1_000e18;
    // Interleaved-open amounts (BOLD borrowed in, WETH collateral out).
    uint256 internal constant OPEN_A_IN = 1_000e18;
    uint256 internal constant OPEN_A_OUT = 0.4 ether;
    uint256 internal constant OPEN_B_IN = 600e18;
    uint256 internal constant OPEN_B_OUT = 0.25 ether;

    LiquityV2PreFundModule preFund;
    LiquityV2TakerModule takerModule;

    uint256 bobPk = 0xB0B;
    address bob = vm.addr(bobPk);
    uint256 carolPk = 0xCA201;
    address carol = vm.addr(carolPk);

    mapping(address => uint256) troveOf;

    function _forkBlock() internal view virtual override returns (uint256) {
        return 25_600_000;
    }

    function setUp() public override {
        super.setUp();
        preFund = new LiquityV2PreFundModule(address(permit3), address(settlement), COLLATERAL_REGISTRY);
        takerModule = new LiquityV2TakerModule(address(permit3), COLLATERAL_REGISTRY);
        vm.label(address(preFund), "preFund");
        vm.label(address(takerModule), "liquityTakerModule");
        vm.label(TROVE_MANAGER, "troveManager");
        vm.label(BORROWER_OPS, "borrowerOperations");
        vm.label(BOLD, "BOLD");
        vm.label(bob, "bob");
        vm.label(carol, "carol");

        deal(BOLD, address(preFund), RESIDUE_BOLD);
        deal(WETH, address(preFund), RESIDUE_WETH);
        deal(BOLD, address(takerModule), RESIDUE_BOLD);
        deal(WETH, address(takerModule), RESIDUE_WETH);
    }

    // ──────────────────── trove + auth helpers ────────────────────

    /// @dev Open `who`'s trove (no add manager: value-in is permissionless), grant
    ///      the taker module remove-manager + receiver, and dump the minted BOLD so
    ///      the wallet starts empty in both assets.
    function _seed(address who) internal returns (uint256 id) {
        deal(WETH, who, OPEN_COLL + ETH_GAS_COMPENSATION);
        vm.startPrank(who);
        IERC20(WETH).approve(BORROWER_OPS, type(uint256).max);
        id = IBorrowerOpsNetted(BORROWER_OPS)
            .openTrove(
                who, 0, OPEN_COLL, OPEN_DEBT, 0, 0, INTEREST_RATE, type(uint256).max, address(0), address(0), address(0)
            );
        IBorrowerOpsNetted(BORROWER_OPS).setRemoveManagerWithReceiver(id, address(takerModule), address(takerModule));
        IERC20(BOLD).transfer(address(0xdead), IERC20(BOLD).balanceOf(who));
        IERC20(WETH).approve(BORROWER_OPS, 0);
        vm.stopPrank();
        troveOf[who] = id;
    }

    function _trove(address who) internal view returns (LatestTroveData memory) {
        return ILiquityV2TroveManager(TROVE_MANAGER).getLatestTroveData(troveOf[who]);
    }

    function _borrowData(address who, uint256 amount) internal view returns (bytes memory) {
        return abi.encode(
            uint8(LiquityV2TakerModule.Op.Borrow), BRANCH, troveOf[who], BOLD, type(uint256).max, amount
        );
    }

    function _withdrawCollData(address who) internal view returns (bytes memory) {
        return abi.encode(uint8(LiquityV2TakerModule.Op.WithdrawColl), BRANCH, troveOf[who], WETH);
    }

    function _authTake(address who, bytes memory data, uint256 amount) internal {
        vm.prank(who);
        permit3.approveTaker(address(settlement), address(takerModule), keccak256(data), uint160(amount), 0);
    }

    // ──────────────────── order builders ────────────────────

    /// @dev Pre-fund leg reference to legsOut[j] (bits 255+253), op in [244,252).
    function _desc(LiquityV2PreFundModule.Op op, address token, uint256 j) internal pure returns (uint256) {
        return (uint256(5) << 253) | (uint256(op) << 244) | (uint256(uint160(token)) << 16) | j;
    }

    /// @dev `data = abi.encode(forDesc, branchIndex, troveId, token)` for legsOut[0].
    function _makeData(LiquityV2PreFundModule.Op op, address who, address token) internal view returns (bytes memory) {
        return abi.encode(_desc(op, token, 0), BRANCH, troveOf[who], token);
    }

    /// @dev `who` gives `amtIn` of `tokIn` (funded by `take`) for `amtOut` of `tokOut`
    ///      delivered to the pre-fund singleton and consumed by one pre-funded MAKE.
    ///      Signed under ORDERED — the SDK default for an order whose TAKE funds an
    ///      input leg — so the core also checks TAKE-before-PULL and TAKE-before-MAKE.
    function _order2(
        address who,
        uint256 nonce,
        address tokIn,
        uint256 amtIn,
        address tokOut,
        uint256 amtOut,
        Item memory take,
        bytes memory makeData
    ) internal view returns (Order memory o) {
        Item[] memory items = new Item[](2);
        items[0] = take;
        items[1] = Item(ItemOp.MAKE, address(preFund), 0, address(0), makeData);
        o = _order(who, nonce, tokIn, tokOut, amtIn, amtOut, items);
        o.legsOut = PackedEncode.oneLegOut(tokOut, amtOut, 0, address(preFund));
        o.timing = ItemPolicy.pack(o.timing, ItemPolicy.ORDERED);
    }

    /// @dev Leverage up: borrow `boldIn` BOLD (withdrawBold) early, add the `wethOut`
    ///      WETH the counter-order delivers as collateral late.
    function _openOrder(address who, uint256 nonce, uint256 boldIn, uint256 wethOut) internal returns (Order memory) {
        bytes memory bd = _borrowData(who, boldIn);
        _authTake(who, bd, boldIn);
        return _order2(
            who,
            nonce,
            BOLD,
            boldIn,
            WETH,
            wethOut,
            Item(ItemOp.TAKE, address(takerModule), boldIn, address(0), bd),
            _makeData(LiquityV2PreFundModule.Op.AddColl, who, WETH)
        );
    }

    /// @dev Deleverage: withdraw `wethIn` collateral early, repay with the `boldOut`
    ///      BOLD the counter-order delivers late.
    function _closeOrder(address who, uint256 nonce, uint256 wethIn, uint256 boldOut) internal returns (Order memory) {
        bytes memory wd = _withdrawCollData(who);
        _authTake(who, wd, wethIn);
        return _order2(
            who,
            nonce,
            WETH,
            wethIn,
            BOLD,
            boldOut,
            Item(ItemOp.TAKE, address(takerModule), wethIn, address(0), wd),
            _makeData(LiquityV2PreFundModule.Op.Repay, who, BOLD)
        );
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

    /// @dev Signatures are produced HERE, before any prank (`_sign()` eats a pending one).
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

    /// @dev The one-order acyclic schedule: order 0 = the maker, order 1 = Carol.
    function _acyclic() internal pure returns (uint256[] memory s) {
        s = new uint256[](6);
        s[0] = _s(MatchStep.PULL, 1, 0);
        s[1] = _s(MatchStep.ITEM, 0, 0);
        s[2] = _s(MatchStep.PULL, 0, 0);
        s[3] = _s(MatchStep.DELIVER, 0, 0);
        s[4] = _s(MatchStep.ITEM, 0, 1);
        s[5] = _s(MatchStep.DELIVER, 1, 0);
    }

    /// @dev Two makers (orders 0,1) + Carol (order 2): both TAKEs, both PULLs, both
    ///      deliveries parked on the ONE singleton, then the MAKEs in REVERSE order.
    function _interleaved() internal pure returns (uint256[] memory s) {
        s = new uint256[](10);
        s[0] = _s(MatchStep.PULL, 2, 0);
        s[1] = _s(MatchStep.ITEM, 0, 0);
        s[2] = _s(MatchStep.ITEM, 1, 0);
        s[3] = _s(MatchStep.PULL, 0, 0);
        s[4] = _s(MatchStep.PULL, 1, 0);
        s[5] = _s(MatchStep.DELIVER, 0, 0);
        s[6] = _s(MatchStep.DELIVER, 1, 0);
        s[7] = _s(MatchStep.ITEM, 1, 1);
        s[8] = _s(MatchStep.ITEM, 0, 1);
        s[9] = _s(MatchStep.DELIVER, 2, 0);
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

    function _triple(Order memory a, Order memory b, Order memory c)
        internal
        view
        returns (Order[] memory o, uint256[] memory pks)
    {
        o = new Order[](3);
        (o[0], o[1], o[2]) = (a, b, c);
        pks = new uint256[](3);
        (pks[0], pks[1], pks[2]) = (makerPk, bobPk, carolPk);
    }

    function _assertSolverFlat() internal view {
        assertEq(IERC20(BOLD).balanceOf(solver) + IERC20(WETH).balanceOf(solver), 0, "zero solver capital, zero take");
        assertEq(IERC20(BOLD).balanceOf(address(settlement)), 0, "nothing pooled (BOLD)");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "nothing pooled (WETH)");
        assertEq(IERC20(BOLD).balanceOf(address(preFund)), RESIDUE_BOLD, "pre-fund BOLD residue untouched");
        assertEq(IERC20(WETH).balanceOf(address(preFund)), RESIDUE_WETH, "pre-fund WETH residue untouched");
        assertEq(IERC20(BOLD).balanceOf(address(takerModule)), RESIDUE_BOLD, "taker BOLD residue untouched");
        assertEq(IERC20(WETH).balanceOf(address(takerModule)), RESIDUE_WETH, "taker WETH residue untouched");
    }

    function _assertWalletEmpty(address who) internal view {
        assertEq(IERC20(BOLD).balanceOf(who) + IERC20(WETH).balanceOf(who), 0, "maker wallet never touched");
    }

    // ──────────────────── open: borrow early, pre-fund AddColl late ────────────────────

    function test_netted_open_borrowThenPreFundAddColl_zeroCapital_liquityV2() public {
        _seed(maker);
        uint256 boldIn = 1_500e18;
        uint256 wethOut = 0.6 ether;
        Order memory a = _openOrder(maker, 1, boldIn, wethOut);
        Order memory c = _carol(WETH, wethOut, BOLD, boldIn);
        (Order[] memory orders, uint256[] memory pks) = _pair(a, c, makerPk);
        MatchPlan memory p = _plan(orders, pks, _acyclic());

        LatestTroveData memory before = _trove(maker);
        vm.prank(solver);
        settlement.matchSettle(p);
        LatestTroveData memory after_ = _trove(maker);

        assertEq(after_.entireColl - before.entireColl, wethOut, "delivery became trove collateral, exactly");
        assertGe(after_.entireDebt - before.entireDebt, boldIn, "borrow booked to the maker's trove");
        assertLt(after_.entireDebt - before.entireDebt, boldIn + boldIn / 50, "debt delta = borrow + small upfront fee");
        _assertWalletEmpty(maker);
        assertEq(IERC20(BOLD).balanceOf(carol), boldIn, "carol paid out of the borrow");
        _assertSolverFlat();
    }

    // ──────────────────── close: withdraw early, pre-fund Repay late ────────────────────

    /// The delivery (2,500) overshoots the repayable band (`entireDebt − MIN_DEBT`
    /// ≈ 2,000 + open fee): the venue clamps the burn at the MIN_DEBT floor and the
    /// module sweeps exactly the un-repayable remainder to the maker — not the residue.
    function test_netted_close_withdrawThenPreFundRepay_clampsAtMinDebt_sweepsSurplus_liquityV2() public {
        _seed(maker);
        uint256 wethIn = 0.5 ether;
        uint256 boldOut = 2_500e18;
        Order memory a = _closeOrder(maker, 1, wethIn, boldOut);
        Order memory c = _carol(BOLD, boldOut, WETH, wethIn);
        (Order[] memory orders, uint256[] memory pks) = _pair(a, c, makerPk);
        MatchPlan memory p = _plan(orders, pks, _acyclic());

        LatestTroveData memory before = _trove(maker);
        uint256 burnable = before.entireDebt - MIN_DEBT;
        assertLt(burnable, boldOut, "the delivery overshoots the repayable band");

        vm.prank(solver);
        settlement.matchSettle(p);
        LatestTroveData memory after_ = _trove(maker);

        assertEq(after_.entireDebt, MIN_DEBT, "trove repaid down to exactly the minimum-debt floor");
        assertEq(before.entireColl - after_.entireColl, wethIn, "collateral withdrawn");
        assertEq(IERC20(BOLD).balanceOf(maker), boldOut - burnable, "exactly the un-repayable delivery swept back");
        assertEq(IERC20(WETH).balanceOf(maker), 0, "maker WETH wallet never billed");
        assertEq(IERC20(WETH).balanceOf(carol), wethIn, "carol paid out of the withdraw");
        _assertSolverFlat();
    }

    // ──────────────────── two makers interleaved on ONE singleton ────────────────────

    /// Two closes, both deliveries parked ahead of both repays: DELIVER A, DELIVER B,
    /// ITEM B, ITEM A. Alice over-delivers (venue clamp + sweep), Bob delivers inside
    /// his band (burns exactly, nothing swept). When B's repay runs the module holds
    /// residue + A's + B's BOLD; the floor leaves A's intact for A, and A's sweep
    /// returns only A's un-repayable surplus.
    function test_netted_twoClosesInterleaved_eachRepaysAndSweepsOnlyItsOwn_liquityV2() public {
        _seed(maker);
        _seed(bob);
        Order memory a = _closeOrder(maker, 1, CLOSE_A_IN, CLOSE_A_OUT);
        Order memory b = _closeOrder(bob, 1, CLOSE_B_IN, CLOSE_B_OUT);
        Order memory c = _carol(BOLD, CLOSE_A_OUT + CLOSE_B_OUT, WETH, CLOSE_A_IN + CLOSE_B_IN);
        (Order[] memory orders, uint256[] memory pks) = _triple(a, b, c);
        MatchPlan memory p = _plan(orders, pks, _interleaved());

        LatestTroveData memory aBefore = _trove(maker);
        LatestTroveData memory bBefore = _trove(bob);
        uint256 aBurnable = aBefore.entireDebt - MIN_DEBT;
        assertLt(aBurnable, CLOSE_A_OUT, "alice overshoots her band");
        assertGt(bBefore.entireDebt - MIN_DEBT, CLOSE_B_OUT, "bob stays inside his band");

        vm.prank(solver);
        settlement.matchSettle(p);
        LatestTroveData memory aAfter = _trove(maker);
        LatestTroveData memory bAfter = _trove(bob);

        assertEq(aAfter.entireDebt, MIN_DEBT, "alice repaid to the floor");
        assertEq(bBefore.entireDebt - bAfter.entireDebt, CLOSE_B_OUT, "bob burned exactly his own delivery");
        assertEq(IERC20(BOLD).balanceOf(maker), CLOSE_A_OUT - aBurnable, "alice swept exactly her own surplus");
        assertEq(IERC20(BOLD).balanceOf(bob), 0, "bob: nothing to sweep, and nothing of alice's");
        assertEq(aBefore.entireColl - aAfter.entireColl, CLOSE_A_IN, "alice's collateral withdrawn");
        assertEq(bBefore.entireColl - bAfter.entireColl, CLOSE_B_IN, "bob's collateral withdrawn");
        assertEq(IERC20(WETH).balanceOf(maker) + IERC20(WETH).balanceOf(bob), 0, "no maker WETH billed");
        assertEq(IERC20(WETH).balanceOf(carol), CLOSE_A_IN + CLOSE_B_IN, "carol paid");
        _assertSolverFlat();
    }

    /// Two opens on the same interleaving: each AddColl consumes exactly its own
    /// delivery from a singleton holding residue + both deliveries.
    function test_netted_twoOpensInterleaved_eachAddsOnlyItsOwn_liquityV2() public {
        _seed(maker);
        _seed(bob);
        Order memory a = _openOrder(maker, 1, OPEN_A_IN, OPEN_A_OUT);
        Order memory b = _openOrder(bob, 1, OPEN_B_IN, OPEN_B_OUT);
        Order memory c = _carol(WETH, OPEN_A_OUT + OPEN_B_OUT, BOLD, OPEN_A_IN + OPEN_B_IN);
        (Order[] memory orders, uint256[] memory pks) = _triple(a, b, c);
        MatchPlan memory p = _plan(orders, pks, _interleaved());

        LatestTroveData memory aBefore = _trove(maker);
        LatestTroveData memory bBefore = _trove(bob);
        vm.prank(solver);
        settlement.matchSettle(p);
        LatestTroveData memory aAfter = _trove(maker);
        LatestTroveData memory bAfter = _trove(bob);

        assertEq(aAfter.entireColl - aBefore.entireColl, OPEN_A_OUT, "alice's trove got exactly her delivery");
        assertEq(bAfter.entireColl - bBefore.entireColl, OPEN_B_OUT, "bob's trove got exactly his delivery");
        assertGe(aAfter.entireDebt - aBefore.entireDebt, OPEN_A_IN, "alice's borrow booked to her");
        assertGe(bAfter.entireDebt - bBefore.entireDebt, OPEN_B_IN, "bob's borrow booked to him");
        _assertWalletEmpty(maker);
        _assertWalletEmpty(bob);
        assertEq(IERC20(BOLD).balanceOf(carol), OPEN_A_IN + OPEN_B_IN, "carol paid");
        _assertSolverFlat();
    }

    // ──────────────────── ordering: pre-fund before its own delivery ────────────────────

    /// The pre-funded AddColl hoisted ahead of its own DELIVER — with WETH residue on
    /// the singleton that could have "funded" it — fails closed in the core ledger.
    function test_netted_preFundBeforeOwnDelivery_failsClosed_liquityV2() public {
        _seed(maker);
        uint256 boldIn = 1_000e18;
        uint256 wethOut = 0.05 ether; // below RESIDUE_WETH: the floor alone would not stop it
        Order memory a = _openOrder(maker, 1, boldIn, wethOut);
        Order memory c = _carol(WETH, wethOut, BOLD, boldIn);
        (Order[] memory orders, uint256[] memory pks) = _pair(a, c, makerPk);
        uint256[] memory s = new uint256[](6);
        s[0] = _s(MatchStep.PULL, 1, 0);
        s[1] = _s(MatchStep.ITEM, 0, 0);
        s[2] = _s(MatchStep.PULL, 0, 0);
        s[3] = _s(MatchStep.ITEM, 0, 1); // before DELIVER A
        s[4] = _s(MatchStep.DELIVER, 0, 0);
        s[5] = _s(MatchStep.DELIVER, 1, 0);
        MatchPlan memory p = _plan(orders, pks, s);

        vm.prank(solver);
        vm.expectRevert(Base.ForLegInvalid.selector);
        settlement.matchSettle(p);
    }

    /// The same hoist on the Repay op (BOLD residue on the singleton exceeds the
    /// delivery): fails closed identically — the ledger guard is op-independent.
    function test_netted_preFundRepayBeforeOwnDelivery_failsClosed_liquityV2() public {
        _seed(maker);
        uint256 wethIn = 0.1 ether;
        uint256 boldOut = 50e18; // below RESIDUE_BOLD
        Order memory a = _closeOrder(maker, 1, wethIn, boldOut);
        Order memory c = _carol(BOLD, boldOut, WETH, wethIn);
        (Order[] memory orders, uint256[] memory pks) = _pair(a, c, makerPk);
        uint256[] memory s = new uint256[](6);
        s[0] = _s(MatchStep.PULL, 1, 0);
        s[1] = _s(MatchStep.ITEM, 0, 0);
        s[2] = _s(MatchStep.PULL, 0, 0);
        s[3] = _s(MatchStep.ITEM, 0, 1); // before DELIVER A
        s[4] = _s(MatchStep.DELIVER, 0, 0);
        s[5] = _s(MatchStep.DELIVER, 1, 0);
        MatchPlan memory p = _plan(orders, pks, s);

        vm.prank(solver);
        vm.expectRevert(Base.ForLegInvalid.selector);
        settlement.matchSettle(p);
    }
}
