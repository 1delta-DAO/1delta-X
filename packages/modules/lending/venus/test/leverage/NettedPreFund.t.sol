// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, ItemPolicy, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {DustHandler} from "@lib/DustHandler.sol";

import {VenusPreFundModule} from "../../src/VenusPreFundModules.sol";
import {VenusTakerModule} from "../../src/VenusModules.sol";
import {VenusModulesBase} from "../shared/VenusModulesBase.t.sol";

/// @title VenusNettedPreFundTest
/// @notice The Venus pre-fund module on the NETTED path (`matchSettle`, task 31),
///         against the live Venus Core pool on the mainnet fork (vWETH collateral /
///         vUSDC debt — see {VenusModulesBase}). Closes review 2026-10-18 M-6 for
///         this venue: plan §4.1 requires the netted interleaving to be tested on
///         every pre-fund module, not only aave-v3.
///
///         Every plan is ACYCLIC and filled with ZERO solver capital: the order's own
///         TAKE (`borrowBehalf` / `redeemUnderlyingBehalf` against an existing
///         position, via {VenusTakerModule} under `comptroller.updateDelegate`) funds
///         its input leg early, a counter-order (Carol, a CoW) supplies the output
///         asset, and the pre-funded MAKE (`mintBehalf` / `repayBorrowBehalf`)
///         consumes the delivery late:
///
///           PULL carol → ITEM(A, 0: TAKE) → PULL A (draws nothing) → DELIVER A
///                      → ITEM(A, 1: pre-fund MAKE) → DELIVER carol
///
///         The solver is an EOA holding nothing and approving nothing. The pre-fund
///         singleton carries RESIDUE before the plan, so a sweep sized from anything
///         but the pre-call floor ({PreFundGuard.floorOf}) would show up as residue
///         or a sibling's parked delivery reaching the wrong maker.
///
///         {VenusPreFundModule} has no Full mode of its own (both ops are sized by
///         the core from the delivery); the Full-mode branch on Venus is the
///         withdraw TAKE (`redeemBehalf` of the whole vToken balance, with
///         `requireFullFillFromData` + `requireDelivered`). The fifth test runs that
///         branch on the netted path, scheduled AFTER the pre-fund repay so the
///         position is debt-free when the whole collateral leaves.
contract VenusNettedPreFundTest is VenusModulesBase {
    VenusPreFundModule preFund;

    uint256 bobPk = 0xB0B;
    address bob = vm.addr(bobPk);
    uint256 carolPk = 0xCA201;
    address carol = vm.addr(carolPk);

    uint256 constant COLL = 10 ether; //       the existing collateral every position starts with
    uint256 constant DEBT = 1_000e6; //        the existing debt a close retires
    uint256 constant RESIDUE_USDC = 77e6; //   stray balance already on the singleton
    uint256 constant RESIDUE_WETH = 0.07 ether;

    function setUp() public override {
        super.setUp();
        preFund = new VenusPreFundModule(address(permit3), address(settlement));
        vm.label(address(preFund), "venusPreFund");
        vm.label(bob, "bob");
        vm.label(carol, "carol");

        deal(USDC, address(preFund), RESIDUE_USDC);
        deal(WETH, address(preFund), RESIDUE_WETH);
    }

    // ──────────────────── position + auth helpers ────────────────────

    function _ok(address target, bytes memory cd, string memory what) internal {
        (bool ok, bytes memory ret) = target.call(cd);
        require(ok, what);
        require(ret.length < 32 || abi.decode(ret, (uint256)) == 0, what);
    }

    /// @dev `who` self-supplies COLL WETH into vWETH, enters both markets, delegates
    ///      the value-out taker module, and (optionally) borrows `debt` USDC, dumping
    ///      the proceeds so the close must be funded by the plan.
    function _seed(address who, uint256 debt) internal {
        deal(WETH, who, COLL);
        vm.startPrank(who);
        address[] memory markets = new address[](2);
        markets[0] = address(VWETH);
        markets[1] = address(VUSDC);
        COMPTROLLER.enterMarkets(markets);
        // The base harness already delegated for `maker`; a repeat reverts
        // `DelegationStatusUnchanged`.
        if (!COMPTROLLER.approvedDelegates(who, address(takerModule))) {
            COMPTROLLER.updateDelegate(address(takerModule), true);
        }
        IERC20(WETH).approve(address(VWETH), COLL);
        _ok(address(VWETH), abi.encodeWithSignature("mint(uint256)", COLL), "seed mint");
        if (debt > 0) {
            _ok(address(VUSDC), abi.encodeWithSignature("borrow(uint256)", debt), "seed borrow");
            IERC20(USDC).transfer(address(0xdead), debt);
        }
        vm.stopPrank();
    }

    function _grantTaker(address who, bytes memory data, uint256 amount) internal {
        vm.prank(who);
        permit3.approveTaker(address(settlement), address(takerModule), keccak256(data), uint160(amount), 0);
    }

    /// @dev Full-mode withdraw data: op@0, vToken@32, underlying@64, mode@96, total@128.
    function _withdrawFullData(uint256 total) internal view returns (bytes memory) {
        return abi.encode(
            uint8(VenusTakerModule.Op.Withdraw),
            address(VWETH),
            WETH,
            DustHandler.encodeMode(DustHandler.BalanceMode.Full),
            total
        );
    }

    // ──────────────────── order builders ────────────────────

    /// @dev Pre-fund leg reference to legsOut[j] (bits 255+253), op in [244,252).
    function _desc(VenusPreFundModule.Op op, address token, uint256 j) internal pure returns (uint256) {
        return (uint256(5) << 253) | (uint256(op) << 244) | (uint256(uint160(token)) << 16) | j;
    }

    function _depositMake() internal view returns (bytes memory) {
        return abi.encode(_desc(VenusPreFundModule.Op.Deposit, WETH, 0), address(VWETH), WETH);
    }

    function _repayMake() internal view returns (bytes memory) {
        return abi.encode(_desc(VenusPreFundModule.Op.Repay, USDC, 0), address(VUSDC), USDC);
    }

    /// @dev `who` gives `amtIn` of `tokIn` for `amtOut` of `tokOut` delivered to the
    ///      pre-fund singleton. `items` are signed as given. Signed under ORDERED —
    ///      the SDK default for an order whose TAKE funds an input leg — so the core
    ///      also checks item order and items-before-PULL.
    function _orderWith(
        address who,
        uint256 nonce,
        address tokIn,
        uint256 amtIn,
        address tokOut,
        uint256 amtOut,
        Item[] memory items
    ) internal view returns (Order memory o) {
        o = _order(who, nonce, tokIn, tokOut, amtIn, amtOut, items);
        o.legsOut = PackedEncode.oneLegOut(tokOut, amtOut, 0, address(preFund));
        o.timing = ItemPolicy.pack(o.timing, ItemPolicy.ORDERED);
    }

    /// @dev Two items: [0] the funding TAKE, [1] the pre-funded MAKE.
    function _order2(
        address who,
        uint256 nonce,
        address tokIn,
        uint256 amtIn,
        address tokOut,
        uint256 amtOut,
        Item memory take,
        bytes memory makeData
    ) internal view returns (Order memory) {
        Item[] memory items = new Item[](2);
        items[0] = take;
        items[1] = Item(ItemOp.MAKE, address(preFund), 0, address(0), makeData);
        return _orderWith(who, nonce, tokIn, amtIn, tokOut, amtOut, items);
    }

    function _openOrder(address who, uint256 nonce, uint256 borrowAmt, uint256 wethOut) internal returns (Order memory) {
        _grantTaker(who, _borrowData(), borrowAmt);
        return _order2(
            who,
            nonce,
            USDC,
            borrowAmt,
            WETH,
            wethOut,
            Item(ItemOp.TAKE, address(takerModule), borrowAmt, address(0), _borrowData()),
            _depositMake()
        );
    }

    function _closeOrder(address who, uint256 nonce, uint256 wethIn, uint256 usdcOut) internal returns (Order memory) {
        _grantTaker(who, _withdrawData(), wethIn);
        return _order2(
            who,
            nonce,
            WETH,
            wethIn,
            USDC,
            usdcOut,
            Item(ItemOp.TAKE, address(takerModule), wethIn, address(0), _withdrawData()),
            _repayMake()
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
        assertEq(IERC20(USDC).balanceOf(solver) + IERC20(WETH).balanceOf(solver), 0, "zero solver capital, zero take");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "nothing pooled (USDC)");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "nothing pooled (WETH)");
        assertEq(IERC20(USDC).balanceOf(address(preFund)), RESIDUE_USDC, "USDC residue untouched");
        assertEq(IERC20(WETH).balanceOf(address(preFund)), RESIDUE_WETH, "WETH residue untouched");
        assertEq(VWETH.balanceOf(address(preFund)) + VUSDC.balanceOf(address(preFund)), 0, "no vTokens on the singleton");
        assertEq(IERC20(USDC).balanceOf(address(takerModule)), 0, "taker module holds no USDC");
        assertEq(IERC20(WETH).balanceOf(address(takerModule)), 0, "taker module holds no WETH");
    }

    // ──────────────────── open: borrow early, pre-fund deposit late ────────────────────

    function test_netted_open_borrowThenPreFundDeposit_zeroCapital_venus() public {
        _seed(maker, 0);
        uint256 borrowAmt = 1_500e6;
        uint256 wethOut = 0.6 ether;
        Order memory a = _openOrder(maker, 1, borrowAmt, wethOut);
        Order memory c = _carol(WETH, wethOut, USDC, borrowAmt);
        (Order[] memory orders, uint256[] memory pks) = _pair(a, c, makerPk);
        MatchPlan memory p = _plan(orders, pks, _acyclic());

        uint256 collBefore = _wethCollateral(maker);
        vm.prank(solver);
        settlement.matchSettle(p);

        // vToken rounding is coarser than Aave's; a small relative band.
        assertApproxEqRel(_wethCollateral(maker) - collBefore, wethOut, 1e12, "delivery became collateral");
        assertEq(_usdcDebt(maker), borrowAmt, "borrow booked to the maker");
        assertEq(IERC20(USDC).balanceOf(maker) + IERC20(WETH).balanceOf(maker), 0, "maker wallet never touched");
        assertEq(IERC20(USDC).balanceOf(carol), borrowAmt, "carol paid out of the borrow");
        _assertSolverFlat();
    }

    // ──────────────────── close: withdraw early, pre-fund repay late ────────────────────

    /// The delivery over-covers the debt (1,100 vs 1,000): the repay clamps at the
    /// live debt and the module sweeps exactly the unconsumed 100 to the maker — not
    /// the residue.
    function test_netted_close_withdrawThenPreFundRepay_sweepsSurplus_venus() public {
        _seed(maker, DEBT);
        uint256 wethIn = 0.5 ether;
        uint256 usdcOut = 1_100e6;
        Order memory a = _closeOrder(maker, 1, wethIn, usdcOut);
        Order memory c = _carol(USDC, usdcOut, WETH, wethIn);
        (Order[] memory orders, uint256[] memory pks) = _pair(a, c, makerPk);
        MatchPlan memory p = _plan(orders, pks, _acyclic());

        uint256 collBefore = _wethCollateral(maker);
        uint256 debtBefore = _usdcDebt(maker);
        assertGt(debtBefore, 0, "pre: maker has debt");
        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(_usdcDebt(maker), 0, "debt retired in full");
        assertEq(IERC20(USDC).balanceOf(maker), usdcOut - debtBefore, "exactly the unconsumed delivery swept back");
        assertApproxEqRel(collBefore - _wethCollateral(maker), wethIn, 1e12, "collateral withdrawn");
        // `redeemUnderlyingBehalf` can round in the maker's favour by a few wei; the
        // taker module returns that to the maker, never to the pool.
        assertLt(IERC20(WETH).balanceOf(maker), 1e10, "maker wallet only sees redeem rounding");
        assertEq(IERC20(WETH).balanceOf(carol), wethIn, "carol paid out of the withdraw");
        _assertSolverFlat();
    }

    /// Two closes on ONE singleton, both deliveries parked ahead of both repays:
    /// DELIVER A, DELIVER B, ITEM B, ITEM A. Alice over-delivers (sweep), Bob delivers
    /// exactly his debt. When B's repay runs the module holds residue + A's + B's
    /// USDC; the floor leaves A's intact for A, and A's sweep returns only A's surplus.
    function test_netted_twoClosesInterleaved_eachRepaysAndSweepsOnlyItsOwn_venus() public {
        _seed(maker, DEBT);
        _seed(bob, 400e6);
        uint256 aIn = 0.5 ether;
        uint256 aOut = 1_250e6;
        uint256 bIn = 0.2 ether;
        uint256 bOut = 400e6;
        Order[] memory orders = new Order[](3);
        orders[0] = _closeOrder(maker, 1, aIn, aOut);
        orders[1] = _closeOrder(bob, 1, bIn, bOut);
        orders[2] = _carol(USDC, aOut + bOut, WETH, aIn + bIn);
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

        uint256 aDebt = _usdcDebt(maker);
        uint256 bDebt = _usdcDebt(bob);
        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(_usdcDebt(maker), 0, "alice's debt retired");
        assertEq(_usdcDebt(bob), 0, "bob's debt retired");
        assertEq(IERC20(USDC).balanceOf(maker), aOut - aDebt, "alice swept exactly her own surplus");
        assertEq(IERC20(USDC).balanceOf(bob), bOut - bDebt, "bob swept exactly his own surplus");
        assertEq(IERC20(WETH).balanceOf(carol), aIn + bIn, "carol paid");
        _assertSolverFlat();
    }

    /// The pre-funded deposit hoisted ahead of its own DELIVER — with residue on the
    /// singleton that could have "funded" it — fails closed in the core ledger.
    function test_netted_preFundBeforeOwnDelivery_failsClosed_venus() public {
        _seed(maker, 0);
        uint256 borrowAmt = 1_000e6;
        uint256 wethOut = 0.05 ether; // below RESIDUE_WETH: the floor alone would not stop it
        Order memory a = _openOrder(maker, 1, borrowAmt, wethOut);
        Order memory c = _carol(WETH, wethOut, USDC, borrowAmt);
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

    // ──────────────── full close: pre-fund repay, then Full-mode withdraw ────────────────

    /// A FULL unwind on the netted path, zero capital: Carol's USDC is delivered to
    /// the singleton FIRST, the pre-funded repay (item 0) retires the whole debt and
    /// sweeps the surplus, THEN the Full-mode withdraw TAKE (item 1) redeems the
    /// entire, now debt-free vWETH balance — `wethIn` credited to the input leg, the
    /// remainder to the maker. Exercises the Full branch's `requireFullFillFromData`
    /// + `requireDelivered` under `matchSettle`, and that ORDERED admits a MAKE item
    ///   before the order's TAKE when the indices say so.
    ///
    ///   PULL carol → DELIVER A → ITEM(A, 0: pre-fund repay) → ITEM(A, 1: Full withdraw)
    ///             → PULL A (draws nothing) → DELIVER carol
    function test_netted_fullClose_preFundRepayThenFullWithdraw_venus() public {
        _seed(maker, DEBT);
        uint256 wethIn = 0.5 ether;
        uint256 usdcOut = 1_100e6;
        bytes memory wData = _withdrawFullData(wethIn);
        _grantTaker(maker, wData, wethIn);

        Item[] memory items = new Item[](2);
        items[0] = Item(ItemOp.MAKE, address(preFund), 0, address(0), _repayMake());
        items[1] = Item(ItemOp.TAKE, address(takerModule), wethIn, address(0), wData);
        Order memory a = _orderWith(maker, 1, WETH, wethIn, USDC, usdcOut, items);
        Order memory c = _carol(USDC, usdcOut, WETH, wethIn);
        (Order[] memory orders, uint256[] memory pks) = _pair(a, c, makerPk);

        uint256[] memory s = new uint256[](6);
        s[0] = _s(MatchStep.PULL, 1, 0);
        s[1] = _s(MatchStep.DELIVER, 0, 0);
        s[2] = _s(MatchStep.ITEM, 0, 0);
        s[3] = _s(MatchStep.ITEM, 0, 1);
        s[4] = _s(MatchStep.PULL, 0, 0);
        s[5] = _s(MatchStep.DELIVER, 1, 0);
        MatchPlan memory p = _plan(orders, pks, s);

        uint256 collBefore = _wethCollateral(maker);
        uint256 debtBefore = _usdcDebt(maker);
        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(_usdcDebt(maker), 0, "debt retired in full");
        assertEq(VWETH.balanceOf(maker), 0, "whole position redeemed");
        assertEq(IERC20(USDC).balanceOf(maker), usdcOut - debtBefore, "repay surplus swept to the maker");
        assertApproxEqAbs(IERC20(WETH).balanceOf(maker), collBefore - wethIn, 1e10, "redeem remainder to the maker");
        assertEq(IERC20(WETH).balanceOf(carol), wethIn, "carol paid exactly the signed amount");
        _assertSolverFlat();
    }

    /// The same full close with the Full-mode withdraw scheduled FIRST (ahead of the
    /// repay that would make it safe) is refused by the venue — the whole collateral
    /// cannot leave while the debt is open (comptroller `InsufficientLiquidity()`) —
    /// so the plan reverts rather than stranding anything.
    function test_netted_fullWithdrawBeforeRepay_reverts_venus() public {
        _seed(maker, DEBT);
        uint256 wethIn = 0.5 ether;
        uint256 usdcOut = 1_100e6;
        bytes memory wData = _withdrawFullData(wethIn);
        _grantTaker(maker, wData, wethIn);

        Item[] memory items = new Item[](2);
        items[0] = Item(ItemOp.TAKE, address(takerModule), wethIn, address(0), wData);
        items[1] = Item(ItemOp.MAKE, address(preFund), 0, address(0), _repayMake());
        Order memory a = _orderWith(maker, 1, WETH, wethIn, USDC, usdcOut, items);
        Order memory c = _carol(USDC, usdcOut, WETH, wethIn);
        (Order[] memory orders, uint256[] memory pks) = _pair(a, c, makerPk);
        MatchPlan memory p = _plan(orders, pks, _acyclic());

        vm.prank(solver);
        // The Venus comptroller's redeem-allowed hook: the debt is still open.
        vm.expectRevert(bytes4(keccak256("InsufficientLiquidity()")));
        settlement.matchSettle(p);
    }
}
