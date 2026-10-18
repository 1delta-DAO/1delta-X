// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, ItemPolicy, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {MorphoBluePreFundModule} from "../../src/MorphoBluePreFundModules.sol";
import {MorphoModulesBase} from "../shared/MorphoModulesBase.t.sol";

/// @title MorphoNettedPreFundTest
/// @notice The Morpho Blue pre-fund module on the NETTED path (`matchSettle`, task 31),
///         against the live mainnet singleton (wstETH/USDC 86% market). Closes review
///         2026-10-18 M-6 for this venue: plan §4.1 requires the netted interleaving to
///         be tested on every pre-fund module.
///
///         Every plan is ACYCLIC and filled with ZERO solver capital: the order's own
///         TAKE (a borrow / a collateral withdraw against an existing position) funds its
///         input leg early, a counter-order (Carol, a CoW) supplies the output asset, and
///         the pre-funded MAKE (supplyCollateral / repay / supply) consumes the delivery
///         late:
///
///           PULL carol → ITEM(A, 0: TAKE) → PULL A (draws nothing) → DELIVER A
///                      → ITEM(A, 1: pre-fund MAKE) → DELIVER carol
///
///         The solver is an EOA holding nothing and approving nothing. The pre-fund
///         singleton carries RESIDUE in both tokens before the plan, so a sweep sized
///         from anything but the pre-call floor ({PreFundGuard.floorOf}) would show up as
///         residue or a sibling's parked delivery reaching the wrong maker.
///
///         Morpho repay is SHARE-based: when the delivery covers the round-up live debt
///         the module repays by `borrowShares` (exact close) and sweeps the rest; the
///         expected surplus is therefore `delivered - toAssetsUp(borrowShares)`.
contract MorphoNettedPreFundTest is MorphoModulesBase {
    MorphoBluePreFundModule preFund;

    uint256 bobPk = 0xB0B;
    address bob = vm.addr(bobPk);
    uint256 carolPk = 0xCA201;
    address carol = vm.addr(carolPk);

    uint256 constant COLL = 10 ether; //          existing wstETH collateral every position starts with
    uint256 constant DEBT = 1_000e6; //           existing USDC debt a close retires
    uint256 constant RESIDUE_USDC = 77e6; //      stray balance already on the singleton
    uint256 constant RESIDUE_WSTETH = 0.07 ether;

    function setUp() public override {
        super.setUp();
        preFund = new MorphoBluePreFundModule(address(permit3), address(settlement));
        vm.label(address(preFund), "morphoPreFund");
        vm.label(bob, "bob");
        vm.label(carol, "carol");

        deal(USDC, address(preFund), RESIDUE_USDC);
        deal(WSTETH, address(preFund), RESIDUE_WSTETH);
    }

    // ──────────────────── position + auth helpers ────────────────────

    /// @dev `who` supplies COLL wstETH and borrows `debt` USDC, dumping the proceeds so
    ///      the close must be funded by the plan. The harness's setUp leaves the
    ///      maker's wstETH bare-approved to Permit3; strip it so nothing the plan does
    ///      could lean on the maker wallet.
    function _seed(address who, uint256 debt) internal {
        deal(WSTETH, who, COLL);
        vm.startPrank(who);
        IERC20(WSTETH).approve(address(MORPHO), COLL);
        MORPHO.supplyCollateral(marketParams, COLL, who, "");
        if (debt > 0) {
            MORPHO.borrow(marketParams, debt, 0, who, who);
            IERC20(USDC).transfer(address(0xdead), debt);
        }
        IERC20(WSTETH).approve(address(permit3), 0);
        vm.stopPrank();
    }

    function _authBorrow(address who, uint256 amount) internal {
        vm.startPrank(who);
        MORPHO.setAuthorization(address(takerModule), true);
        permit3.approveTaker(address(settlement), address(takerModule), keccak256(_borrowData()), uint160(amount), 0);
        vm.stopPrank();
    }

    function _authWithdraw(address who, uint256 amount) internal {
        vm.startPrank(who);
        MORPHO.setAuthorization(address(takerModule), true);
        permit3.approveTaker(address(settlement), address(takerModule), keccak256(_withdrawData()), uint160(amount), 0);
        vm.stopPrank();
    }

    // ──────────────────── order builders ────────────────────

    /// @dev Pre-fund leg reference to legsOut[j] (bits 255+253), op in [244,252).
    function _desc(MorphoBluePreFundModule.Op op, address token, uint256 j) internal pure returns (uint256) {
        return (uint256(5) << 253) | (uint256(op) << 244) | (uint256(uint160(token)) << 16) | j;
    }

    function _preFundData(MorphoBluePreFundModule.Op op, address token) internal view returns (bytes memory) {
        return abi.encode(_desc(op, token, 0), address(MORPHO), marketParams);
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

    /// @dev OPEN: borrow USDC early (funds the input leg), supplyCollateral the
    ///      delivered wstETH late.
    function _openOrder(address who, uint256 nonce, uint256 borrowAmt, uint256 wstethOut)
        internal
        returns (Order memory)
    {
        _authBorrow(who, borrowAmt);
        return _order2(
            who,
            nonce,
            USDC,
            borrowAmt,
            WSTETH,
            wstethOut,
            Item(ItemOp.TAKE, address(takerModule), borrowAmt, address(0), _borrowData()),
            _preFundData(MorphoBluePreFundModule.Op.SupplyCollateral, WSTETH)
        );
    }

    /// @dev CLOSE: withdraw wstETH collateral early (funds the input leg), apply the
    ///      delivered USDC late with `op` (Repay, or Supply for the lender rotation).
    function _withdrawThen(
        address who,
        uint256 nonce,
        uint256 wstethIn,
        uint256 usdcOut,
        MorphoBluePreFundModule.Op op
    ) internal returns (Order memory) {
        _authWithdraw(who, wstethIn);
        return _order2(
            who,
            nonce,
            WSTETH,
            wstethIn,
            USDC,
            usdcOut,
            Item(ItemOp.TAKE, address(takerModule), wstethIn, address(0), _withdrawData()),
            _preFundData(op, USDC)
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
        assertEq(IERC20(USDC).balanceOf(solver) + IERC20(WSTETH).balanceOf(solver), 0, "zero solver capital, zero take");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "nothing pooled (USDC)");
        assertEq(IERC20(WSTETH).balanceOf(address(settlement)), 0, "nothing pooled (wstETH)");
        assertEq(IERC20(USDC).balanceOf(address(preFund)), RESIDUE_USDC, "USDC residue untouched");
        assertEq(IERC20(WSTETH).balanceOf(address(preFund)), RESIDUE_WSTETH, "wstETH residue untouched");
        assertEq(IERC20(USDC).allowance(address(preFund), address(MORPHO)), 0, "USDC approval cleared");
        assertEq(IERC20(WSTETH).allowance(address(preFund), address(MORPHO)), 0, "wstETH approval cleared");
    }

    // ──────────────────── open: borrow early, pre-fund supplyCollateral late ────────────────────

    function test_netted_open_borrowThenPreFundSupplyCollateral_zeroCapital_morpho() public {
        _seed(maker, 0);
        uint256 borrowAmt = 1_500e6;
        uint256 wstethOut = 0.4 ether;
        Order memory a = _openOrder(maker, 1, borrowAmt, wstethOut);
        Order memory c = _carol(WSTETH, wstethOut, USDC, borrowAmt);
        (Order[] memory orders, uint256[] memory pks) = _pair(a, c, makerPk);
        MatchPlan memory p = _plan(orders, pks, _acyclic());

        vm.prank(solver);
        settlement.matchSettle(p);

        // supplyCollateral never accrues: the delivery maps 1:1.
        assertEq(_collateral(maker), COLL + wstethOut, "delivery became collateral, exactly");
        assertApproxEqAbs(_borrowAssets(maker), borrowAmt, 1, "borrow booked to the maker");
        assertEq(IERC20(USDC).balanceOf(maker) + IERC20(WSTETH).balanceOf(maker), 0, "maker wallet never touched");
        assertEq(IERC20(USDC).balanceOf(carol), borrowAmt, "carol paid out of the borrow");
        _assertSolverFlat();
    }

    // ──────────────────── close: withdraw early, pre-fund repay late ────────────────────

    /// The delivery over-covers the debt (1,100 vs 1,000): the repay goes by SHARES
    /// (exact close) and the module sweeps exactly `delivered - toAssetsUp(shares)` to
    /// the maker — not the residue.
    function test_netted_close_withdrawThenPreFundRepay_sweepsSurplus_morpho() public {
        _seed(maker, DEBT);
        uint256 wstethIn = 0.5 ether;
        uint256 usdcOut = 1_100e6;
        Order memory a = _withdrawThen(maker, 1, wstethIn, usdcOut, MorphoBluePreFundModule.Op.Repay);
        Order memory c = _carol(USDC, usdcOut, WSTETH, wstethIn);
        (Order[] memory orders, uint256[] memory pks) = _pair(a, c, makerPk);
        MatchPlan memory p = _plan(orders, pks, _acyclic());

        // Seeded this block: no accrual between here and the fill.
        uint256 debtUp = _borrowAssets(maker);
        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(_position(maker).borrowShares, 0, "debt retired in full (by shares)");
        assertEq(IERC20(USDC).balanceOf(maker), usdcOut - debtUp, "exactly the unconsumed delivery swept back");
        assertEq(_collateral(maker), COLL - wstethIn, "collateral withdrawn");
        assertEq(IERC20(WSTETH).balanceOf(carol), wstethIn, "carol paid out of the withdraw");
        _assertSolverFlat();
    }

    /// Partial close: the delivery is BELOW the debt, so the module takes the assets
    /// branch, consumes the whole delivery, and sweeps nothing.
    function test_netted_close_partialRepay_consumesExactly_morpho() public {
        _seed(maker, DEBT);
        uint256 wstethIn = 0.1 ether;
        uint256 usdcOut = 300e6;
        Order memory a = _withdrawThen(maker, 1, wstethIn, usdcOut, MorphoBluePreFundModule.Op.Repay);
        Order memory c = _carol(USDC, usdcOut, WSTETH, wstethIn);
        (Order[] memory orders, uint256[] memory pks) = _pair(a, c, makerPk);
        MatchPlan memory p = _plan(orders, pks, _acyclic());

        uint256 debtUp = _borrowAssets(maker);
        vm.prank(solver);
        settlement.matchSettle(p);

        assertApproxEqAbs(_borrowAssets(maker), debtUp - usdcOut, 1, "debt reduced by the delivery");
        assertGt(_position(maker).borrowShares, 0, "a partial repay leaves a position");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "nothing to sweep on a partial repay");
        _assertSolverFlat();
    }

    /// Two closes on ONE singleton, both deliveries parked ahead of both repays:
    /// DELIVER A, DELIVER B, ITEM B, ITEM A. Alice over-delivers (sweep), Bob delivers
    /// a hair over his debt. When B's repay runs the module holds residue + A's + B's
    /// USDC; the floor leaves A's intact for A, and A's sweep returns only A's surplus.
    uint256 constant A_IN = 0.5 ether;
    uint256 constant A_OUT = 1_250e6;
    uint256 constant B_IN = 0.2 ether;
    uint256 constant B_OUT = 401e6;

    function test_netted_twoClosesInterleaved_eachRepaysAndSweepsOnlyItsOwn_morpho() public {
        _seed(maker, DEBT);
        _seed(bob, 400e6);
        Order[] memory orders = new Order[](3);
        orders[0] = _withdrawThen(maker, 1, A_IN, A_OUT, MorphoBluePreFundModule.Op.Repay);
        orders[1] = _withdrawThen(bob, 1, B_IN, B_OUT, MorphoBluePreFundModule.Op.Repay);
        orders[2] = _carol(USDC, A_OUT + B_OUT, WSTETH, A_IN + B_IN);
        uint256[] memory pks = new uint256[](3);
        (pks[0], pks[1], pks[2]) = (makerPk, bobPk, carolPk);

        uint256[] memory s = new uint256[](10);
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
        MatchPlan memory p = _plan(orders, pks, s);

        uint256 aDebt = _borrowAssets(maker);
        uint256 bDebt = _borrowAssets(bob);
        uint256 morphoUsdc = IERC20(USDC).balanceOf(address(MORPHO));
        (,, uint128 totalBorrowBefore,,,) = MORPHO.market(_marketId());
        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(_position(maker).borrowShares, 0, "alice's debt retired");
        assertEq(_position(bob).borrowShares, 0, "bob's debt retired");
        // ±1 wei, not exact: B's shares-repay runs FIRST and moves the market's
        // assets/shares ratio, so A's round-up debt at the moment A's repay runs can
        // sit one wei under the value read before the plan (observed: 1e9+1 → 1e9).
        // The exact accounting is pinned by the two conservation checks below.
        uint256 aSwept = IERC20(USDC).balanceOf(maker);
        uint256 bSwept = IERC20(USDC).balanceOf(bob);
        assertApproxEqAbs(aSwept, A_OUT - aDebt, 1, "alice swept her own surplus");
        assertApproxEqAbs(bSwept, B_OUT - bDebt, 1, "bob swept his own surplus");
        // Every delivered wei is either repaid into Morpho or swept to its own maker.
        uint256 consumed = (A_OUT - aSwept) + (B_OUT - bSwept);
        assertEq(IERC20(USDC).balanceOf(address(MORPHO)) - morphoUsdc, consumed, "repaid == delivered - swept");
        (,, uint128 totalBorrowAfter,,,) = MORPHO.market(_marketId());
        assertEq(uint256(totalBorrowBefore) - totalBorrowAfter, consumed, "market debt fell by exactly the repaid");
        assertEq(_collateral(maker), COLL - A_IN, "alice's collateral withdrawn");
        assertEq(_collateral(bob), COLL - B_IN, "bob's collateral withdrawn");
        assertEq(IERC20(WSTETH).balanceOf(carol), A_IN + B_IN, "carol paid");
        _assertSolverFlat();
    }

    // ──────────────────── lender side: withdraw collateral early, pre-fund supply late ────────────────────

    /// Collateral → earn rotation: the withdrawn wstETH funds the input leg, Carol pays
    /// USDC to the singleton, and the pre-funded Supply books it as a lend balance.
    /// Supply consumes exactly the delivery, so nothing is swept.
    function test_netted_withdrawThenPreFundSupply_lenderSide_morpho() public {
        _seed(maker, 0);
        uint256 wstethIn = 0.5 ether;
        uint256 usdcOut = 1_000e6;
        Order memory a = _withdrawThen(maker, 1, wstethIn, usdcOut, MorphoBluePreFundModule.Op.Supply);
        Order memory c = _carol(USDC, usdcOut, WSTETH, wstethIn);
        (Order[] memory orders, uint256[] memory pks) = _pair(a, c, makerPk);
        MatchPlan memory p = _plan(orders, pks, _acyclic());

        vm.prank(solver);
        settlement.matchSettle(p);

        assertApproxEqAbs(_supplyAssets(maker), usdcOut, 2, "delivery became a lend balance");
        assertEq(_collateral(maker), COLL - wstethIn, "collateral withdrawn");
        assertEq(IERC20(USDC).balanceOf(maker) + IERC20(WSTETH).balanceOf(maker), 0, "maker wallet never touched");
        assertEq(IERC20(WSTETH).balanceOf(carol), wstethIn, "carol paid out of the withdraw");
        _assertSolverFlat();
    }

    // ──────────────────── fail-closed ordering ────────────────────

    /// The pre-funded supplyCollateral hoisted ahead of its own DELIVER — with residue
    /// on the singleton that could have "funded" it — fails closed in the core ledger.
    function test_netted_preFundBeforeOwnDelivery_failsClosed_morpho() public {
        _seed(maker, 0);
        uint256 borrowAmt = 100e6;
        uint256 wstethOut = 0.05 ether; // below RESIDUE_WSTETH: the floor alone would not stop it
        Order memory a = _openOrder(maker, 1, borrowAmt, wstethOut);
        Order memory c = _carol(WSTETH, wstethOut, USDC, borrowAmt);
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

    /// Same hoist on the repay side: the repay before its own DELIVER fails closed even
    /// though the singleton's USDC residue (77) covers the 50 the item would claim.
    function test_netted_preFundRepayBeforeOwnDelivery_failsClosed_morpho() public {
        _seed(maker, DEBT);
        uint256 wstethIn = 0.02 ether;
        uint256 usdcOut = 50e6; // below RESIDUE_USDC
        Order memory a = _withdrawThen(maker, 1, wstethIn, usdcOut, MorphoBluePreFundModule.Op.Repay);
        Order memory c = _carol(USDC, usdcOut, WSTETH, wstethIn);
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
