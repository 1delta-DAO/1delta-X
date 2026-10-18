// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {stdError} from "forge-std/StdError.sol";

import {Order, Item, ItemOp, LegOut, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";
import {ItemPolicy} from "@core/settlement/Structs.sol";
import {Base} from "@core/settlement/Base.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";

import {EulerV2OperatorModule} from "../../src/EulerV2OperatorModule.sol";
import {EulerV2PreFundModule} from "../../src/EulerV2PreFundModules.sol";
import {EulerV2ModulesBase} from "../shared/EulerV2ModulesBase.t.sol";

/// @title EulerV2NettedPreFundTest
/// @notice {EulerV2PreFundModule} on the NETTED path (`matchSettle`) against the real
///         EVK vaults — review 2026-10-18 M-1 (no pre-funded sink on Euler) and M-6
///         (netted interleaving untested outside aave-v3).
///
///         The two ACYCLIC position shapes, each filled by a solver holding NOTHING,
///         against a CoW counter-order (Carol):
///
///           open:  ITEM borrow (early, pays the input) → PULL Carol → DELIVER the
///                  collateral to the module → ITEM deposit (late) → DELIVER Carol
///           close: ITEM withdraw (early, pays the input) → PULL Carol → DELIVER the
///                  debt asset to the module → ITEM repay (late) → DELIVER Carol
///
///         Before this module the late sink was {EulerV2DepositModule} /
///         {EulerV2RepayModule}, which PULL from the maker's wallet — so the maker
///         needed a Permit3 allowance to the module for a token they never held. Here
///         the maker's receive side is EMPTY: no ERC-20 approval of the delivered
///         token, no Permit3 token allowance; the only grants are the borrow/withdraw
///         taker allowance and the EVC operator flag every value-out op needs anyway.
///
///         Then the interleavings that make the floor load-bearing: two makers' deliveries
///         parked on ONE singleton (plus residue) ahead of both items, a hostile maker
///         whose repay consumes nothing, and an item hoisted before its own delivery.
contract EulerV2NettedPreFundTest is EulerV2ModulesBase {
    EulerV2PreFundModule preFund;

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
        preFund = new EulerV2PreFundModule(address(permit3), address(settlement));
        vm.label(address(preFund), "eulerPreFundModule");
        vm.label(carol, "carol");
        vm.label(bob, "bob");
        vm.label(mallory, "mallory");
        deal(USDC, address(preFund), RESIDUE_USDC);
        deal(WETH, address(preFund), RESIDUE_WETH);
    }

    // ──────────────────── builders ────────────────────

    /// @dev Pre-fund leg reference: bit 255 (leg ref) + bit 253 (pre-fund), op in
    ///      [244,252), the signed funding token in [16,176), leg index in [0,16).
    function _desc(EulerV2PreFundModule.Op op, address token, uint256 j) internal pure returns (uint256) {
        return (uint256(5) << 253) | (uint256(op) << 244) | (uint256(uint160(token)) << 16) | j;
    }

    function _depositData(address vault, address token) internal pure returns (bytes memory) {
        return abi.encode(_desc(EulerV2PreFundModule.Op.Deposit, token, 0), vault);
    }

    function _repayData() internal view returns (bytes memory) {
        return abi.encode(_desc(EulerV2PreFundModule.Op.Repay, USDC, 0), address(EUSDC));
    }

    function _borrowData() internal pure returns (bytes memory) {
        return abi.encode(uint8(EulerV2OperatorModule.Op.Borrow), address(EUSDC));
    }

    function _withdrawData() internal pure returns (bytes memory) {
        return abi.encode(uint8(EulerV2OperatorModule.Op.Withdraw), address(EWETH));
    }

    /// @dev `who` pays `amtIn` of `tokIn`, `amtOut` of `tokOut` is delivered to the
    ///      PRE-FUND MODULE, consumed by `items`. ORDERED item policy — the SDK default
    ///      for an order whose TAKE funds an input leg.
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
        legsOut[0] = LegOut(tokOut, amtOut, 0, address(preFund));
        o.legsOut = PackedEncode.legsOut(legsOut);
        o.timing = ItemPolicy.pack(o.timing, ItemPolicy.ORDERED);
    }

    function _preFundItem(bytes memory data) internal view returns (Item memory) {
        return Item({op: ItemOp.MAKE, module: address(preFund), amount: 0, recipient: address(0), data: data});
    }

    function _takeItem(uint256 amount, bytes memory data) internal view returns (Item memory) {
        return
            Item({op: ItemOp.TAKE, module: address(operatorModule), amount: amount, recipient: address(0), data: data});
    }

    /// @dev Carol: a plain counter-order selling `tokIn` for `tokOut`.
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
        IERC20(WETH).approve(address(permit3), 0);
        IERC20(USDC).approve(address(permit3), 0);
        vm.stopPrank();
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

    /// @dev The acyclic one-maker schedule: source item, pulls, delivery, sink item,
    ///      counter-order delivery. Order 0 = the maker, order 1 = Carol.
    function _acyclicSchedule() internal pure returns (uint256[] memory s) {
        s = new uint256[](6);
        s[0] = _step(MatchStep.ITEM, 0, 0); //    borrow / withdraw → pool, credits maker's input
        s[1] = _step(MatchStep.PULL, 0, 0); //    draws nothing: the item already covered it
        s[2] = _step(MatchStep.PULL, 1, 0); //    Carol's leg → pool
        s[3] = _step(MatchStep.DELIVER, 0, 0); // Carol's asset → the PRE-FUND MODULE
        s[4] = _step(MatchStep.ITEM, 0, 1); //    deposit / repay exactly the delivery
        s[5] = _step(MatchStep.DELIVER, 1, 0); // the maker's proceeds → Carol
    }

    function _assertSolverFlat() internal view {
        assertEq(IERC20(USDC).balanceOf(solver), 0, "solver: no USDC, before or after");
        assertEq(IERC20(WETH).balanceOf(solver), 0, "solver: no WETH, before or after");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "nothing pooled (USDC)");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "nothing pooled (WETH)");
    }

    // ──────────────────── M-1: the acyclic open, zero capital ────────────────────

    /// Leverage up against existing headroom: borrow 5,000 USDC (early TAKE), Carol
    /// sells 2 WETH for it, the 2 WETH land on the pre-fund module and are deposited
    /// as collateral (late MAKE). No solver capital, no flash, and NO receive-side
    /// grant for WETH from the maker.
    function test_netted_acyclicOpen_borrowThenDeposit_zeroCapital_noReceiveSideGrant() public {
        uint256 borrowAmt = 5_000e6;
        uint256 coll = 2 ether;
        _seedEulerCollateral(10 ether);
        // The controller / collateral / operator flags are the base's (setUp).
        vm.prank(maker);
        permit3.approveTaker(
            address(settlement), address(operatorModule), keccak256(_borrowData()), uint160(borrowAmt), 0
        );

        Item[] memory items = new Item[](2);
        items[0] = _takeItem(borrowAmt, _borrowData());
        items[1] = _preFundItem(_depositData(address(EWETH), WETH));
        Order memory o = _preFundOrder(maker, 1, USDC, borrowAmt, WETH, coll, items);
        Order memory c = _carol(1, WETH, coll, USDC, borrowAmt);

        // The receive side is EMPTY, and proven so: revoke the maker's base ERC-20
        // approvals to Permit3 for BOTH tokens. Nothing can be pulled from the wallet —
        // not the delivered WETH (the pre-fund deposit spends the delivery) and not the
        // USDC input (the borrow item credited it before the PULL step).
        _revokeWallet(maker);
        assertEq(IERC20(WETH).allowance(maker, address(permit3)), 0, "no WETH approval to Permit3");
        assertEq(IERC20(USDC).allowance(maker, address(permit3)), 0, "no USDC approval either");

        uint256 coll0 = _wethCollateral(maker);
        uint256 debt0 = _usdcDebt(maker);
        vm.prank(solver);
        settlement.matchSettle(_plan(_two(o, c), _pks(makerPk, carolPk), _acyclicSchedule()));

        assertApproxEqAbs(_wethCollateral(maker) - coll0, coll, 1, "deposited exactly the delivery");
        assertEq(_usdcDebt(maker) - debt0, borrowAmt, "borrowed exactly the signed amount");
        assertEq(IERC20(WETH).balanceOf(maker), 0, "maker's wallet never held WETH");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "nor USDC");
        assertEq(IERC20(USDC).balanceOf(carol), borrowAmt, "carol paid out of the borrow");
        assertEq(IERC20(WETH).balanceOf(address(preFund)), RESIDUE_WETH, "singleton back to its residue");
        _assertSolverFlat();
    }

    // ──────────────────── M-1: the acyclic close, zero capital ────────────────────

    /// Deleverage against headroom: withdraw 2 WETH (early TAKE), Carol buys it for
    /// `debt + 100` USDC, which lands on the pre-fund module; the repay is CLAMPED to
    /// the live debt (EVK reverts above it) and the 100 USDC surplus is SWEPT to the
    /// maker — measured against the floor, so the singleton's residue stays put.
    function test_netted_acyclicClose_withdrawThenRepay_zeroCapital_surplusSwept() public {
        uint256 debtSigned = 3_000e6;
        uint256 wd = 2 ether;
        _openEulerPosition(10 ether, debtSigned);
        uint256 debt = _usdcDebt(maker);
        uint256 delivered = debt + 100e6;
        vm.prank(maker);
        permit3.approveTaker(address(settlement), address(operatorModule), keccak256(_withdrawData()), uint160(wd), 0);

        Item[] memory items = new Item[](2);
        items[0] = _takeItem(wd, _withdrawData());
        items[1] = _preFundItem(_repayData());
        Order memory o = _preFundOrder(maker, 2, WETH, wd, USDC, delivered, items);
        Order memory c = _carol(2, USDC, delivered, WETH, wd);
        _revokeWallet(maker);
        assertEq(IERC20(USDC).allowance(maker, address(permit3)), 0, "no USDC approval to Permit3");
        assertEq(IERC20(WETH).allowance(maker, address(permit3)), 0, "no WETH approval to Permit3");

        uint256 coll0 = _wethCollateral(maker);
        vm.prank(solver);
        settlement.matchSettle(_plan(_two(o, c), _pks(makerPk, carolPk), _acyclicSchedule()));

        assertEq(_usdcDebt(maker), 0, "debt fully repaid");
        assertApproxEqAbs(coll0 - _wethCollateral(maker), wd, 1, "withdrew exactly the signed collateral");
        assertEq(IERC20(USDC).balanceOf(maker), delivered - debt, "surplus over the debt swept to the maker");
        assertEq(IERC20(WETH).balanceOf(carol), wd, "carol paid out of the withdraw");
        assertEq(IERC20(USDC).balanceOf(address(preFund)), RESIDUE_USDC, "residue untouched by the sweep");
        _assertSolverFlat();
    }

    // ──────────────────── M-6: interleaving on one singleton ────────────────────

    /// @dev Bob: an independent USDC debt in eUSDC-2, opened directly (no module).
    function _bobDebt(uint256 coll, uint256 debt) internal {
        deal(WETH, bob, coll);
        vm.startPrank(bob);
        IERC20(WETH).approve(address(EWETH), coll);
        EWETH.deposit(coll, bob);
        EVC.enableCollateral(bob, address(EWETH));
        EVC.enableController(bob, address(EUSDC));
        EUSDC.borrow(debt, bob);
        IERC20(USDC).transfer(address(0xdead), debt);
        vm.stopPrank();
    }

    /// Alice (swap → deposit USDC as a lend balance) and Bob (swap → repay, debt BELOW
    /// his delivery) on ONE singleton, with residue on it: DELIVER A, DELIVER B, ITEM B,
    /// ITEM A. When Bob's repay sweeps, the module holds residue + A + B; the floor is
    /// `residue + A`, so the sweep returns exactly Bob's unconsumed part — to Bob — and
    /// Alice's delivery is intact for her deposit.
    function test_netted_interleaved_twoMakers_eachSpendsOnlyItsOwnDelivery() public {
        uint256 outA = 4_000e6;
        uint256 inA = 2 ether;
        uint256 outB = 1_500e6;
        uint256 inB = 1 ether;
        _bobDebt(5 ether, 1_000e6);
        uint256 debtB = _usdcDebt(bob);

        deal(WETH, maker, inA);
        _approveSettlement(maker, WETH);
        deal(WETH, bob, inB);
        _approveSettlement(bob, WETH);

        Item[] memory ia = new Item[](1);
        ia[0] = _preFundItem(_depositData(address(EUSDC), USDC));
        Item[] memory ib = new Item[](1);
        ib[0] = _preFundItem(_repayData());
        Order memory a = _preFundOrder(maker, 3, WETH, inA, USDC, outA, ia);
        Order memory b = _preFundOrder(bob, 1, WETH, inB, USDC, outB, ib);
        Order memory c = _carol(3, USDC, outA + outB, WETH, inA + inB);

        uint256[] memory s = new uint256[](7);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 1, 0);
        s[2] = _step(MatchStep.PULL, 2, 0);
        s[3] = _step(MatchStep.DELIVER, 0, 0); // alice's USDC parks on the module
        s[4] = _step(MatchStep.DELIVER, 1, 0); // bob's next to it
        s[5] = _step(MatchStep.ITEM, 1, 0); //    bob repays (clamped) + sweeps
        s[6] = _step(MatchStep.ITEM, 0, 0); //    alice deposits
        uint256[] memory full = new uint256[](8);
        for (uint256 i; i < 7; i++) {
            full[i] = s[i];
        }
        full[7] = _step(MatchStep.DELIVER, 2, 0);

        uint256 lendA0 = EUSDC.convertToAssets(EUSDC.balanceOf(maker));
        vm.prank(solver);
        settlement.matchSettle(_plan(_three(a, b, c), _pks(makerPk, bobPk, carolPk), full));

        assertApproxEqAbs(
            EUSDC.convertToAssets(EUSDC.balanceOf(maker)) - lendA0, outA, 1, "alice: exactly her delivery"
        );
        assertEq(IERC20(USDC).balanceOf(maker), 0, "alice: swept nothing of anyone's");
        assertEq(_usdcDebt(bob), 0, "bob: debt repaid, clamped");
        assertEq(IERC20(USDC).balanceOf(bob), outB - debtB, "bob: exactly his own unconsumed part");
        assertEq(IERC20(USDC).balanceOf(address(preFund)), RESIDUE_USDC, "singleton back to its residue");
        assertEq(IERC20(WETH).balanceOf(carol), inA + inB, "carol paid");
        _assertSolverFlat();
    }

    /// A hostile maker whose repay names a vault where she has NO debt: the vault takes
    /// nothing and the module sweeps "everything above the floor" to her — while Bob's
    /// delivery is parked on the same singleton. The floor makes her sweep exactly her
    /// OWN delivery; Bob's repay then runs fully funded.
    function test_netted_hostileZeroConsumeRepay_sweepsOnlyItsOwnDelivery() public {
        uint256 outM = 900e6;
        uint256 outB = 1_200e6;
        _bobDebt(5 ether, 1_000e6);
        uint256 debtB = _usdcDebt(bob);
        deal(WETH, mallory, 1);
        _approveSettlement(mallory, WETH);
        deal(WETH, bob, 1 ether);
        _approveSettlement(bob, WETH);

        Item[] memory im = new Item[](1);
        im[0] = _preFundItem(_repayData()); // debtOf(mallory) == 0
        Item[] memory ib = new Item[](1);
        ib[0] = _preFundItem(_repayData());
        Order memory m = _preFundOrder(mallory, 1, WETH, 1, USDC, outM, im);
        Order memory b = _preFundOrder(bob, 2, WETH, 1 ether, USDC, outB, ib);
        Order memory c = _carol(4, USDC, outM + outB, WETH, 1 ether + 1);

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

        assertEq(IERC20(USDC).balanceOf(mallory), outM, "mallory swept back exactly her own delivery");
        assertEq(_usdcDebt(bob), 0, "bob's repay fully funded after mallory's sweep");
        assertEq(IERC20(USDC).balanceOf(bob), outB - debtB, "bob's own surplus, untouched");
        assertEq(IERC20(USDC).balanceOf(address(preFund)), RESIDUE_USDC, "residue unreachable");
        _assertSolverFlat();
    }

    /// The deposit item hoisted ahead of its own DELIVER while a sibling's delivery
    /// and residue sit on the module — enough balance that the floor alone would NOT
    /// underflow. The core's delivery ledger refuses it.
    function test_netted_itemBeforeOwnDelivery_failsClosed() public {
        uint256 outA = 50e6; // smaller than what is parked
        uint256 outB = 1_200e6;
        _bobDebt(5 ether, 1_000e6);
        deal(WETH, maker, 1 ether);
        _approveSettlement(maker, WETH);
        deal(WETH, bob, 1 ether);
        _approveSettlement(bob, WETH);

        Item[] memory ia = new Item[](1);
        ia[0] = _preFundItem(_depositData(address(EUSDC), USDC));
        Item[] memory ib = new Item[](1);
        ib[0] = _preFundItem(_repayData());
        Order memory a = _preFundOrder(maker, 4, WETH, 1 ether, USDC, outA, ia);
        Order memory b = _preFundOrder(bob, 3, WETH, 1 ether, USDC, outB, ib);
        Order memory c = _carol(5, USDC, outA + outB, WETH, 2 ether);

        uint256[] memory s = new uint256[](8);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 1, 0);
        s[2] = _step(MatchStep.PULL, 2, 0);
        s[3] = _step(MatchStep.DELIVER, 1, 0); // bob's 1,200 parks
        s[4] = _step(MatchStep.ITEM, 0, 0); //    alice's item BEFORE alice's delivery
        s[5] = _step(MatchStep.DELIVER, 0, 0);
        s[6] = _step(MatchStep.ITEM, 1, 0);
        s[7] = _step(MatchStep.DELIVER, 2, 0);
        MatchPlan memory p = _plan(_three(a, b, c), _pks(makerPk, bobPk, carolPk), s);
        vm.prank(solver);
        vm.expectRevert(Base.ForLegInvalid.selector);
        settlement.matchSettle(p);
    }

    // ──────────────────── the gate and the floor, at the door ────────────────────

    function test_gate_onlySettlement() public {
        vm.prank(mallory);
        vm.expectRevert(PreFundGuard.OnlySettlement.selector);
        preFund.makeOnBehalf(mallory, RESIDUE_USDC, _repayData());
    }

    /// A PULL leg reference (bit 253 clear) would get the core's loose recipient rule
    /// back; the module refuses it.
    function test_gate_requiresPreFundDescriptor() public {
        bytes memory pullShape = abi.encode((uint256(1) << 255) | (uint256(uint160(USDC)) << 16), address(EUSDC));
        vm.prank(address(settlement));
        vm.expectRevert(PreFundGuard.PreFundDescriptorRequired.selector);
        preFund.makeOnBehalf(maker, 1e6, pullShape);
    }

    /// Nothing was delivered beyond residue: an instructed amount above the balance
    /// underflows the floor rather than spending someone else's balance.
    function test_floor_underDelivery_failsClosed() public {
        vm.prank(address(settlement));
        vm.expectRevert(stdError.arithmeticError);
        preFund.makeOnBehalf(maker, RESIDUE_USDC + 1, _depositData(address(EUSDC), USDC));
    }

    /// The descriptor's signed funding token is USDC but the maker-named vault's asset
    /// is WETH: the module would spend a token the leg never delivered.
    function test_floor_vaultAssetMustBeTheSignedFundingToken() public {
        vm.prank(address(settlement));
        vm.expectRevert(PreFundGuard.FundingTokenMismatch.selector);
        preFund.makeOnBehalf(maker, 1e6, abi.encode(_desc(EulerV2PreFundModule.Op.Deposit, USDC, 0), address(EWETH)));
    }

    function test_gate_unknownOp_reverts() public {
        bytes memory data =
            abi.encode((uint256(5) << 253) | (uint256(7) << 244) | (uint256(uint160(USDC)) << 16), address(EUSDC));
        vm.prank(address(settlement));
        vm.expectRevert(abi.encodeWithSelector(EulerV2PreFundModule.BadOp.selector, 7));
        preFund.makeOnBehalf(maker, 1e6, data);
    }

    function test_view_fundingSource_isTheVaultAsset_selfFunded() public view {
        (address asset, uint256 available) = preFund.fundingSource(maker, _repayData());
        assertEq(asset, USDC, "repay spends the borrow vault's asset");
        assertEq(available, type(uint256).max, "self-funded by the delivery");
        (asset,) = preFund.fundingSource(maker, _depositData(address(EWETH), WETH));
        assertEq(asset, WETH, "deposit spends the named vault's asset");
    }
}
