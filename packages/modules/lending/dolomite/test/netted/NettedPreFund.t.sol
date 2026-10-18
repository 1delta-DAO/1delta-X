// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {stdError} from "forge-std/StdError.sol";

import {Order, Item, ItemOp, LegOut, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";
import {ItemPolicy} from "@core/settlement/Structs.sol";
import {Base} from "@core/settlement/Base.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";

import {
    AccountInfo,
    ActionArgs,
    ActionType,
    AssetAmount,
    AssetDenomination,
    AssetReference,
    OperatorArg
} from "../../src/interfaces/IDolomite.sol";
import {DolomiteOperatorModule} from "../../src/DolomiteOperatorModule.sol";
import {DolomiteModulesBase} from "../shared/DolomiteModulesBase.t.sol";

/// @title DolomiteNettedPreFundTest
/// @notice The PRE-FUNDED `Deposit` / `Repay` MAKE ops of {DolomiteOperatorModule} on
///         the NETTED path (`matchSettle`) against the live DolomiteMargin — review
///         2026-10-18 M-1 (no pre-funded sink on Dolomite) and M-6 (netted
///         interleaving untested outside aave-v3).
///
///         The two ACYCLIC position shapes, each filled by a solver holding NOTHING,
///         against a CoW counter-order (Carol):
///
///           open:  ITEM borrow (early) → PULL Carol → DELIVER the collateral to the
///                  module → ITEM pre-funded deposit (late) → DELIVER Carol
///           close: ITEM withdraw (early) → PULL Carol → DELIVER the debt asset to the
///                  module → ITEM pre-funded repay (late) → DELIVER Carol
///
///         Before the pre-fund ops the late sink PULLED from the maker's wallet, so the
///         maker needed a Permit3 allowance to the module for a token they never held —
///         on top of the operator flag. Now the maker's whole grant set is the ONE
///         `setOperators` boolean (Dolomite has no permissionless value-in path, so no
///         funding shape can remove it) plus the borrow/withdraw taker allowance; the
///         ERC-20 approvals of both tokens to Permit3 are REVOKED before each fill.
///
///         Every debt test runs UNMOCKED on account 100 (the borrow-position range) —
///         see the base for why the old risk-override mock was a misdiagnosis.
contract DolomiteNettedPreFundTest is DolomiteModulesBase {
    uint256 carolPk = 0xCA201;
    address carol = vm.addr(carolPk);
    uint256 bobPk = 0xB0B;
    address bob = vm.addr(bobPk);
    uint256 malloryPk = 0xBAD;
    address mallory = vm.addr(malloryPk);

    uint256 constant RESIDUE_USDC = 7e6; //     stray balance already on the singleton
    uint256 constant RESIDUE_WETH = 0.02 ether;

    function setUp() public override {
        super.setUp();
        vm.label(carol, "carol");
        vm.label(bob, "bob");
        vm.label(mallory, "mallory");
        deal(DEBT, address(operatorModule), RESIDUE_USDC);
        deal(COLL, address(operatorModule), RESIDUE_WETH);
    }

    // ──────────────────── builders ────────────────────

    /// @dev Pre-fund leg reference: bit 255 (leg ref) + bit 253 (pre-fund), op in
    ///      [244,252), the signed funding token in [16,176), leg index in [0,16).
    function _desc(uint256 op, address token, uint256 j) internal pure returns (uint256) {
        return (uint256(5) << 253) | (op << 244) | (uint256(uint160(token)) << 16) | j;
    }

    function _preData(DolomiteOperatorModule.Op op, uint256 marketId, address token)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(_desc(uint256(op), token, 0), address(DOLOMITE), marketId, token, ACCOUNT);
    }

    function _preDeposit(uint256 marketId, address token) internal pure returns (bytes memory) {
        return _preData(DolomiteOperatorModule.Op.Deposit, marketId, token);
    }

    function _preRepay() internal view returns (bytes memory) {
        return _preData(DolomiteOperatorModule.Op.Repay, DEBT_MARKET, DEBT);
    }

    /// @dev `who` pays `amtIn` of `tokIn`; `amtOut` of `tokOut` is delivered to the
    ///      MODULE and consumed by `items`. ORDERED item policy.
    function _preFundOrder(
        address who,
        uint256 nonce,
        address tokIn,
        uint256 amtIn,
        address tokOut,
        uint256 amtOut,
        Item[] memory items
    ) internal view returns (Order memory o) {
        o = _sellOrder(nonce, who, tokIn, tokOut, amtIn, amtOut, items);
        LegOut[] memory legsOut = new LegOut[](1);
        legsOut[0] = LegOut(tokOut, amtOut, 0, address(operatorModule));
        o.legsOut = PackedEncode.legsOut(legsOut);
        o.timing = ItemPolicy.pack(o.timing, ItemPolicy.ORDERED);
    }

    function _make(bytes memory data) internal view returns (Item memory) {
        return Item({op: ItemOp.MAKE, module: address(operatorModule), amount: 0, recipient: address(0), data: data});
    }

    function _take(uint256 amount, bytes memory data) internal view returns (Item memory) {
        return
            Item({op: ItemOp.TAKE, module: address(operatorModule), amount: amount, recipient: address(0), data: data});
    }

    function _carol(uint256 nonce, address tokIn, uint256 amtIn, address tokOut, uint256 amtOut)
        internal
        returns (Order memory o)
    {
        deal(tokIn, carol, amtIn);
        _approveSettlement(carol, tokIn);
        o = _sellOrder(nonce, carol, tokIn, tokOut, amtIn, amtOut, new Item[](0));
    }

    function _approveSettlement(address who, address token) internal {
        vm.startPrank(who);
        IERC20(token).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), token, type(uint160).max, 0);
        vm.stopPrank();
    }

    function _revokeWallet(address who) internal {
        vm.startPrank(who);
        IERC20(COLL).approve(address(permit3), 0);
        IERC20(DEBT).approve(address(permit3), 0);
        vm.stopPrank();
    }

    function _grantOperator(address who) internal {
        OperatorArg[] memory ops = new OperatorArg[](1);
        ops[0] = OperatorArg(address(operatorModule), true);
        vm.prank(who);
        DOLOMITE.setOperators(ops);
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

    function _two(Order memory a, Order memory b) internal pure returns (Order[] memory o) {
        o = new Order[](2);
        (o[0], o[1]) = (a, b);
    }

    function _three(Order memory a, Order memory b, Order memory c) internal pure returns (Order[] memory o) {
        o = new Order[](3);
        (o[0], o[1], o[2]) = (a, b, c);
    }

    function _pks(uint256 a, uint256 b) internal pure returns (uint256[] memory x) {
        x = new uint256[](2);
        (x[0], x[1]) = (a, b);
    }

    function _pks(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory x) {
        x = new uint256[](3);
        (x[0], x[1], x[2]) = (a, b, c);
    }

    function _step(uint256 kind, uint256 a, uint256 b) internal pure returns (uint256) {
        return MatchStep.pack(kind, a, b);
    }

    /// @dev Order 0 = the maker, order 1 = Carol. Source item first, sink item after
    ///      the delivery it consumes.
    function _acyclicSchedule() internal pure returns (uint256[] memory s) {
        s = new uint256[](6);
        s[0] = _step(MatchStep.ITEM, 0, 0); //    borrow / withdraw → pool, credits maker's input
        s[1] = _step(MatchStep.PULL, 0, 0); //    draws nothing: the item already covered it
        s[2] = _step(MatchStep.PULL, 1, 0); //    Carol's leg → pool
        s[3] = _step(MatchStep.DELIVER, 0, 0); // Carol's asset → the MODULE
        s[4] = _step(MatchStep.ITEM, 0, 1); //    pre-funded deposit / repay of exactly that
        s[5] = _step(MatchStep.DELIVER, 1, 0); // the maker's proceeds → Carol
    }

    /// @dev Bob: an independent USDC debt on account 100, opened directly.
    function _bobDebt(uint256 coll, uint256 debt) internal {
        deal(COLL, bob, coll);
        vm.startPrank(bob);
        IERC20(COLL).approve(address(DOLOMITE), coll);
        AccountInfo[] memory accounts = new AccountInfo[](1);
        accounts[0] = AccountInfo(bob, ACCOUNT);
        ActionArgs[] memory actions = new ActionArgs[](2);
        actions[0] = ActionArgs({
            actionType: ActionType.Deposit,
            accountId: 0,
            amount: AssetAmount(true, AssetDenomination.Wei, AssetReference.Delta, coll),
            primaryMarketId: COLL_MARKET,
            secondaryMarketId: 0,
            otherAddress: bob,
            otherAccountId: 0,
            data: ""
        });
        actions[1] = ActionArgs({
            actionType: ActionType.Withdraw,
            accountId: 0,
            amount: AssetAmount(false, AssetDenomination.Wei, AssetReference.Delta, debt),
            primaryMarketId: DEBT_MARKET,
            secondaryMarketId: 0,
            otherAddress: bob,
            otherAccountId: 0,
            data: ""
        });
        DOLOMITE.operate(accounts, actions);
        IERC20(DEBT).transfer(address(0xdead), debt);
        vm.stopPrank();
    }

    function _supplyOf(address who, uint256 marketId) internal view returns (uint256) {
        (bool sign, uint256 value) = _wei(who, marketId);
        return sign ? value : 0;
    }

    function _wei(address who, uint256 marketId) internal view returns (bool, uint256) {
        return (
            DOLOMITE.getAccountWei(AccountInfo(who, ACCOUNT), marketId).sign,
            DOLOMITE.getAccountWei(AccountInfo(who, ACCOUNT), marketId).value
        );
    }

    function _assertSolverFlat() internal view {
        assertEq(IERC20(DEBT).balanceOf(solver), 0, "solver: no USDC, before or after");
        assertEq(IERC20(COLL).balanceOf(solver), 0, "solver: no WETH, before or after");
        assertEq(IERC20(DEBT).balanceOf(address(settlement)), 0, "nothing pooled (USDC)");
        assertEq(IERC20(COLL).balanceOf(address(settlement)), 0, "nothing pooled (WETH)");
    }

    // ──────────────────── M-1: the acyclic open, zero capital ────────────────────

    /// Borrow 5,000 USDC against existing headroom (early TAKE); Carol sells 2 WETH for
    /// it; the 2 WETH land on the operator module and are deposited into the same
    /// borrow-position account (late pre-funded MAKE). No solver capital, no flash, and
    /// no wallet approval of either token.
    function test_netted_acyclicOpen_borrowThenDeposit_zeroCapital_operatorFlagOnly() public {
        uint256 borrowAmt = 5_000e6;
        uint256 coll = 2 ether;
        _seedDolomiteCollateral(10 ether);
        vm.prank(maker);
        permit3.approveTaker(
            address(settlement), address(operatorModule), keccak256(_borrowData()), uint160(borrowAmt), 0
        );

        Item[] memory items = new Item[](2);
        items[0] = _take(borrowAmt, _borrowData());
        items[1] = _make(_preDeposit(COLL_MARKET, COLL));
        Order memory o = _preFundOrder(maker, 1, DEBT, borrowAmt, COLL, coll, items);
        Order memory c = _carol(1, COLL, coll, DEBT, borrowAmt);

        _revokeWallet(maker);
        assertEq(IERC20(COLL).allowance(maker, address(permit3)), 0, "no WETH approval to Permit3");
        assertEq(IERC20(DEBT).allowance(maker, address(permit3)), 0, "no USDC approval to Permit3");

        uint256 coll0 = _collateralOf(maker);
        vm.prank(solver);
        settlement.matchSettle(_plan(_two(o, c), _pks(makerPk, carolPk), _acyclicSchedule()));

        assertApproxEqAbs(_collateralOf(maker) - coll0, coll, 1, "deposited exactly the delivery");
        assertApproxEqAbs(_debtOf(maker), borrowAmt, 1, "borrowed exactly the signed amount");
        assertEq(IERC20(COLL).balanceOf(maker), 0, "maker's wallet never held WETH");
        assertEq(IERC20(DEBT).balanceOf(maker), 0, "nor USDC");
        assertEq(IERC20(DEBT).balanceOf(carol), borrowAmt, "carol paid out of the borrow");
        assertEq(IERC20(COLL).balanceOf(address(operatorModule)), RESIDUE_WETH, "module back to its residue");
        _assertSolverFlat();
    }

    // ──────────────────── M-1: the acyclic close, zero capital ────────────────────

    /// Withdraw 2 WETH (early Exact TAKE, `WouldBorrow`-bounded); Carol pays `debt + 100`
    /// USDC to the module; the repay is CLAMPED to the live debt (a Wei deposit past it
    /// would open a supply the maker never signed) and the 100 USDC surplus is SWEPT to
    /// the maker's wallet, measured against the floor — residue untouched.
    function test_netted_acyclicClose_withdrawThenRepay_zeroCapital_surplusSwept() public {
        uint256 wd = 2 ether;
        _openDolomitePosition(10 ether, 3_000e6);
        uint256 debt = _debtOf(maker);
        uint256 delivered = debt + 100e6;
        vm.prank(maker);
        permit3.approveTaker(address(settlement), address(operatorModule), keccak256(_withdrawData()), uint160(wd), 0);

        Item[] memory items = new Item[](2);
        items[0] = _take(wd, _withdrawData());
        items[1] = _make(_preRepay());
        Order memory o = _preFundOrder(maker, 2, COLL, wd, DEBT, delivered, items);
        Order memory c = _carol(2, DEBT, delivered, COLL, wd);
        _revokeWallet(maker);

        uint256 coll0 = _collateralOf(maker);
        vm.prank(solver);
        settlement.matchSettle(_plan(_two(o, c), _pks(makerPk, carolPk), _acyclicSchedule()));

        assertEq(_debtOf(maker), 0, "debt closed to exactly zero");
        assertEq(_supplyOf(maker, DEBT_MARKET), 0, "and no USDC supply opened past it");
        assertApproxEqAbs(coll0 - _collateralOf(maker), wd, 1, "withdrew exactly the signed collateral");
        assertEq(IERC20(DEBT).balanceOf(maker), delivered - debt, "surplus over the debt swept to the maker");
        assertEq(IERC20(COLL).balanceOf(carol), wd, "carol paid out of the withdraw");
        assertEq(IERC20(DEBT).balanceOf(address(operatorModule)), RESIDUE_USDC, "residue untouched by the sweep");
        _assertSolverFlat();
    }

    // ──────────────────── M-6: interleaving on one singleton ────────────────────

    /// Alice (swap → deposit USDC as a lend balance) and Bob (swap → repay, debt BELOW
    /// his delivery) on the ONE operator module, with residue on it: DELIVER A, DELIVER
    /// B, ITEM B, ITEM A. Bob's sweep returns exactly his unconsumed part — to Bob — and
    /// Alice's parked delivery is intact for her deposit.
    function test_netted_interleaved_twoMakers_eachSpendsOnlyItsOwnDelivery() public {
        uint256 outA = 4_000e6;
        uint256 inA = 2 ether;
        uint256 outB = 1_500e6;
        uint256 inB = 1 ether;
        _bobDebt(5 ether, 1_000e6);
        _grantOperator(bob);
        uint256 debtB = _debtOf(bob);

        deal(COLL, maker, inA);
        _approveSettlement(maker, COLL);
        deal(COLL, bob, inB);
        _approveSettlement(bob, COLL);

        Item[] memory ia = new Item[](1);
        ia[0] = _make(_preDeposit(DEBT_MARKET, DEBT));
        Item[] memory ib = new Item[](1);
        ib[0] = _make(_preRepay());
        Order memory a = _preFundOrder(maker, 3, COLL, inA, DEBT, outA, ia);
        Order memory b = _preFundOrder(bob, 1, COLL, inB, DEBT, outB, ib);
        Order memory c = _carol(3, DEBT, outA + outB, COLL, inA + inB);

        uint256[] memory s = new uint256[](8);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 1, 0);
        s[2] = _step(MatchStep.PULL, 2, 0);
        s[3] = _step(MatchStep.DELIVER, 0, 0); // alice's USDC parks on the module
        s[4] = _step(MatchStep.DELIVER, 1, 0); // bob's next to it
        s[5] = _step(MatchStep.ITEM, 1, 0); //    bob repays (clamped) + sweeps
        s[6] = _step(MatchStep.ITEM, 0, 0); //    alice deposits
        s[7] = _step(MatchStep.DELIVER, 2, 0);

        uint256 lendA0 = _supplyOf(maker, DEBT_MARKET);
        vm.prank(solver);
        settlement.matchSettle(_plan(_three(a, b, c), _pks(makerPk, bobPk, carolPk), s));

        assertApproxEqAbs(_supplyOf(maker, DEBT_MARKET) - lendA0, outA, 1, "alice: exactly her delivery");
        assertEq(IERC20(DEBT).balanceOf(maker), 0, "alice: swept nothing of anyone's");
        assertEq(_debtOf(bob), 0, "bob: debt repaid, clamped");
        assertEq(IERC20(DEBT).balanceOf(bob), outB - debtB, "bob: exactly his own unconsumed part");
        assertEq(IERC20(DEBT).balanceOf(address(operatorModule)), RESIDUE_USDC, "module back to its residue");
        assertEq(IERC20(COLL).balanceOf(carol), inA + inB, "carol paid");
        _assertSolverFlat();
    }

    /// A hostile maker (no operator grant, no debt) whose repay consumes NOTHING: the
    /// module skips `operate` and sweeps "everything above the floor" to her while Bob's
    /// delivery is parked beside hers. The floor bounds her sweep to her own delivery.
    function test_netted_hostileZeroConsumeRepay_sweepsOnlyItsOwnDelivery() public {
        uint256 outM = 900e6;
        uint256 outB = 1_200e6;
        _bobDebt(5 ether, 1_000e6);
        _grantOperator(bob);
        uint256 debtB = _debtOf(bob);
        deal(COLL, mallory, 1);
        _approveSettlement(mallory, COLL);
        deal(COLL, bob, 1 ether);
        _approveSettlement(bob, COLL);

        Item[] memory im = new Item[](1);
        im[0] = _make(_preRepay()); // mallory has no debt
        Item[] memory ib = new Item[](1);
        ib[0] = _make(_preRepay());
        Order memory m = _preFundOrder(mallory, 1, COLL, 1, DEBT, outM, im);
        Order memory b = _preFundOrder(bob, 2, COLL, 1 ether, DEBT, outB, ib);
        Order memory c = _carol(4, DEBT, outM + outB, COLL, 1 ether + 1);

        uint256[] memory s = new uint256[](8);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 1, 0);
        s[2] = _step(MatchStep.PULL, 2, 0);
        s[3] = _step(MatchStep.DELIVER, 1, 0); // bob's delivery parks first
        s[4] = _step(MatchStep.DELIVER, 0, 0);
        s[5] = _step(MatchStep.ITEM, 0, 0); //    mallory: zero consume, sweep
        s[6] = _step(MatchStep.ITEM, 1, 0);
        s[7] = _step(MatchStep.DELIVER, 2, 0);
        vm.prank(solver);
        settlement.matchSettle(_plan(_three(m, b, c), _pks(malloryPk, bobPk, carolPk), s));

        assertEq(IERC20(DEBT).balanceOf(mallory), outM, "mallory swept back exactly her own delivery");
        assertEq(_debtOf(bob), 0, "bob's repay fully funded after mallory's sweep");
        assertEq(IERC20(DEBT).balanceOf(bob), outB - debtB, "bob's own surplus, untouched");
        assertEq(IERC20(DEBT).balanceOf(address(operatorModule)), RESIDUE_USDC, "residue unreachable");
        _assertSolverFlat();
    }

    /// The deposit hoisted ahead of its own DELIVER while a sibling's delivery and
    /// residue sit on the module — enough that the floor alone would not underflow. The
    /// core's delivery ledger refuses it.
    function test_netted_itemBeforeOwnDelivery_failsClosed() public {
        uint256 outA = 50e6;
        uint256 outB = 1_200e6;
        _bobDebt(5 ether, 1_000e6);
        _grantOperator(bob);
        deal(COLL, maker, 1 ether);
        _approveSettlement(maker, COLL);
        deal(COLL, bob, 1 ether);
        _approveSettlement(bob, COLL);

        Item[] memory ia = new Item[](1);
        ia[0] = _make(_preDeposit(DEBT_MARKET, DEBT));
        Item[] memory ib = new Item[](1);
        ib[0] = _make(_preRepay());
        Order memory a = _preFundOrder(maker, 4, COLL, 1 ether, DEBT, outA, ia);
        Order memory b = _preFundOrder(bob, 3, COLL, 1 ether, DEBT, outB, ib);
        Order memory c = _carol(5, DEBT, outA + outB, COLL, 2 ether);

        uint256[] memory s = new uint256[](8);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 1, 0);
        s[2] = _step(MatchStep.PULL, 2, 0);
        s[3] = _step(MatchStep.DELIVER, 1, 0);
        s[4] = _step(MatchStep.ITEM, 0, 0); //    alice's item BEFORE alice's delivery
        s[5] = _step(MatchStep.DELIVER, 0, 0);
        s[6] = _step(MatchStep.ITEM, 1, 0);
        s[7] = _step(MatchStep.DELIVER, 2, 0);
        MatchPlan memory p = _plan(_three(a, b, c), _pks(makerPk, bobPk, carolPk), s);
        vm.prank(solver);
        vm.expectRevert(Base.ForLegInvalid.selector);
        settlement.matchSettle(p);
    }

    // ──────────────────── the gate, the floor and the seams, at the door ────────────────────

    function test_gate_onlySettlement() public {
        vm.prank(mallory);
        vm.expectRevert(PreFundGuard.OnlySettlement.selector);
        operatorModule.makeOnBehalf(mallory, RESIDUE_USDC, _preRepay());
    }

    /// Nothing was delivered beyond residue: an instructed amount above the balance
    /// underflows the floor instead of spending someone else's balance.
    function test_floor_underDelivery_failsClosed() public {
        vm.prank(address(settlement));
        vm.expectRevert(stdError.arithmeticError);
        operatorModule.makeOnBehalf(maker, RESIDUE_USDC + 1, _preDeposit(DEBT_MARKET, DEBT));
    }

    /// The descriptor's signed funding token (USDC) is not the token the body would
    /// spend (WETH, market 0 — itself correctly bound to its market).
    function test_floor_spentTokenMustBeTheSignedFundingToken() public {
        bytes memory data = abi.encode(
            _desc(uint256(DolomiteOperatorModule.Op.Deposit), DEBT, 0), address(DOLOMITE), COLL_MARKET, COLL, ACCOUNT
        );
        vm.prank(address(settlement));
        vm.expectRevert(PreFundGuard.FundingTokenMismatch.selector);
        operatorModule.makeOnBehalf(maker, 1e6, data);
    }

    /// The signed token is not the signed market's token (G-BYTE_MAP-7) — refused
    /// before any balance is read.
    function test_gate_marketTokenMismatch() public {
        bytes memory data = abi.encode(
            _desc(uint256(DolomiteOperatorModule.Op.Deposit), DEBT, 0), address(DOLOMITE), COLL_MARKET, DEBT, ACCOUNT
        );
        vm.prank(address(settlement));
        vm.expectRevert(
            abi.encodeWithSelector(DolomiteOperatorModule.MarketTokenMismatch.selector, COLL_MARKET, DEBT, COLL)
        );
        operatorModule.makeOnBehalf(maker, 1e6, data);
    }

    /// Only `Deposit` and `Repay` exist on the pre-funded MAKE seam: a value-OUT op
    /// (`Borrow`, 0) or the `TAKE_FOR` composite (`Open`, 6) in the descriptor is BadOp.
    function test_gate_preFundMake_rejectsEveryOtherOp() public {
        bytes memory borrowOp = _preData(DolomiteOperatorModule.Op.Borrow, DEBT_MARKET, DEBT);
        vm.prank(address(settlement));
        vm.expectRevert(abi.encodeWithSelector(DolomiteOperatorModule.BadOp.selector, 0));
        operatorModule.makeOnBehalf(maker, 1e6, borrowOp);

        bytes memory openOp = _preData(DolomiteOperatorModule.Op.Open, DEBT_MARKET, DEBT);
        vm.prank(address(settlement));
        vm.expectRevert(abi.encodeWithSelector(DolomiteOperatorModule.BadOp.selector, 6));
        operatorModule.makeOnBehalf(maker, 1e6, openOp);
    }

    /// A PULL leg reference (`>> 253 == 4`) is not the pre-fund shape, so it reads as
    /// a plain blob — whose "op" is the whole descriptor word, refused as BadOp. It
    /// can never be sized from the delivery ledger while spending as a pull.
    function test_gate_pullLegRef_onMake_isBadOp() public {
        uint256 w = (uint256(1) << 255) | (uint256(2) << 244) | (uint256(uint160(DEBT)) << 16);
        bytes memory data = abi.encode(w, address(DOLOMITE), DEBT_MARKET, DEBT, ACCOUNT);
        vm.prank(address(settlement));
        vm.expectRevert(abi.encodeWithSelector(DolomiteOperatorModule.BadOp.selector, w));
        operatorModule.makeOnBehalf(maker, 1e6, data);
    }

    /// ONE BLOB, ONE SEAM. A pre-funded `Deposit` blob handed to the taker seams:
    /// `takeOnBehalf` refuses the descriptor outright, `takeForOnBehalf` accepts the
    /// descriptor FORM but rejects every op but `Open`.
    function test_seams_preFundMakeBlob_reachesNoTakerSeam() public {
        bytes memory data = _preDeposit(COLL_MARKET, COLL);
        vm.prank(address(permit3));
        vm.expectRevert(PreFundGuard.PreFundDescriptorNotAllowed.selector);
        operatorModule.takeOnBehalf(maker, 1e6, mallory, data);

        vm.prank(address(permit3));
        vm.expectRevert(abi.encodeWithSelector(DolomiteOperatorModule.BadOp.selector, 2));
        operatorModule.takeForOnBehalf(address(settlement), maker, 1e6, 1e6, mallory, data);
    }

    function test_views_preFundMake_selfFunded_deliversNothing() public view {
        (address asset, uint256 available) = operatorModule.fundingSource(maker, _preRepay());
        assertEq(asset, DEBT, "repay spends the debt market's token");
        assertEq(available, type(uint256).max, "self-funded by the delivery");
        (asset,) = operatorModule.fundingSource(maker, _preDeposit(COLL_MARKET, COLL));
        assertEq(asset, COLL, "deposit spends the named market's token");
        assertEq(operatorModule.proceedsAsset(_preRepay()), address(0), "a sink delivers nothing");
    }
}
