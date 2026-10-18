// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, ItemPolicy, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";
import {Chains, Lenders} from "@coretest/data/LenderRegistry.sol";

import {IAaveV2Pool, IAaveV2CreditDelegation} from "../../src/interfaces/IAaveV2.sol";
import {AaveV2PreFundModule} from "../../src/AaveV2PreFundModules.sol";
import {AaveV2BorrowModule, AaveV2WithdrawModule} from "../../src/AaveV2Modules.sol";

/// @title AaveV2NettedPreFundTest
/// @notice The Aave V2 pre-fund module on the NETTED path (`matchSettle`, task 31),
///         against the live mainnet LendingPool. Closes review 2026-10-18 M-6 for
///         this venue: plan §4.1 requires the netted interleaving to be tested on
///         every pre-fund module, not only aave-v3.
///
///         Every plan is ACYCLIC and filled with ZERO solver capital: the order's own
///         TAKE (a borrow / a withdraw against an existing position) funds its input
///         leg early, a counter-order (Carol, a CoW) supplies the output asset, and the
///         pre-funded MAKE (deposit / repay) consumes the delivery late:
///
///           PULL carol → ITEM(A, 0: TAKE) → PULL A (draws nothing) → DELIVER A
///                      → ITEM(A, 1: pre-fund MAKE) → DELIVER carol
///
///         The solver is an EOA holding nothing and approving nothing. Each pre-fund
///         singleton carries RESIDUE before the plan, so a sweep sized from anything
///         but the pre-call floor ({PreFundGuard.floorOf}) would show up as a
///         residue or a sibling's parked delivery reaching the wrong maker.
contract AaveV2NettedPreFundTest is CoreSettlementBase {
    AaveV2PreFundModule preFund;
    AaveV2BorrowModule borrowModule;
    AaveV2WithdrawModule withdrawModule;

    address POOL;
    address aWETH;
    address usdcVariableDebt;

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
        POOL = lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2];
        aWETH = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][WETH].collateral;
        usdcVariableDebt = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V2][USDC].debt;

        preFund = new AaveV2PreFundModule(address(permit3), address(settlement));
        borrowModule = new AaveV2BorrowModule(address(permit3));
        withdrawModule = new AaveV2WithdrawModule(address(permit3));
        vm.label(POOL, "aaveV2Pool");
        vm.label(aWETH, "aWETH_v2");
        vm.label(usdcVariableDebt, "variableDebtUSDC_v2");
        vm.label(address(preFund), "preFund");
        vm.label(bob, "bob");
        vm.label(carol, "carol");

        deal(USDC, address(preFund), RESIDUE_USDC);
        deal(WETH, address(preFund), RESIDUE_WETH);
    }

    // ──────────────────── position + auth helpers ────────────────────

    function _seed(address who, uint256 debt) internal {
        deal(WETH, who, COLL);
        vm.startPrank(who);
        IERC20(WETH).approve(POOL, COLL);
        IAaveV2Pool(POOL).deposit(WETH, COLL, who, 0);
        if (debt > 0) IAaveV2Pool(POOL).borrow(USDC, debt, 2, 0, who);
        // The debt asset leaves the wallet: the close must be funded by the plan.
        if (debt > 0) IERC20(USDC).transfer(address(0xdead), debt);
        vm.stopPrank();
    }

    function _borrowData() internal view returns (bytes memory) {
        return abi.encode(POOL, USDC, uint256(2));
    }

    function _withdrawData() internal view returns (bytes memory) {
        return abi.encode(POOL, WETH, aWETH);
    }

    function _authBorrow(address who, uint256 amount) internal {
        vm.startPrank(who);
        IAaveV2CreditDelegation(usdcVariableDebt).approveDelegation(address(borrowModule), amount);
        permit3.approveTaker(address(settlement), address(borrowModule), keccak256(_borrowData()), uint160(amount), 0);
        vm.stopPrank();
    }

    function _authWithdraw(address who, uint256 amount) internal {
        vm.startPrank(who);
        IERC20(aWETH).approve(address(withdrawModule), type(uint256).max);
        permit3.approveTaker(address(settlement), address(withdrawModule), keccak256(_withdrawData()), uint160(amount), 0);
        vm.stopPrank();
    }

    // ──────────────────── order builders ────────────────────

    /// @dev Pre-fund leg reference to legsOut[j] (bits 255+253), op in [244,252).
    function _desc(AaveV2PreFundModule.Op op, address token, uint256 j) internal pure returns (uint256) {
        return (uint256(5) << 253) | (uint256(op) << 244) | (uint256(uint160(token)) << 16) | j;
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

    function _openOrder(address who, uint256 nonce, uint256 borrowAmt, uint256 wethOut) internal returns (Order memory) {
        _authBorrow(who, borrowAmt);
        return _order2(
            who,
            nonce,
            USDC,
            borrowAmt,
            WETH,
            wethOut,
            Item(ItemOp.TAKE, address(borrowModule), borrowAmt, address(0), _borrowData()),
            abi.encode(_desc(AaveV2PreFundModule.Op.Deposit, WETH, 0), POOL, WETH)
        );
    }

    function _closeOrder(address who, uint256 nonce, uint256 wethIn, uint256 usdcOut) internal returns (Order memory) {
        _authWithdraw(who, wethIn);
        return _order2(
            who,
            nonce,
            WETH,
            wethIn,
            USDC,
            usdcOut,
            Item(ItemOp.TAKE, address(withdrawModule), wethIn, address(0), _withdrawData()),
            abi.encode(_desc(AaveV2PreFundModule.Op.Repay, USDC, 0), POOL, USDC, uint256(2), usdcVariableDebt)
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
    }

    // ──────────────────── open: borrow early, pre-fund deposit late ────────────────────

    function test_netted_open_borrowThenPreFundDeposit_zeroCapital_aaveV2() public {
        _seed(maker, 0);
        uint256 borrowAmt = 1_500e6;
        uint256 wethOut = 0.6 ether;
        Order memory a = _openOrder(maker, 1, borrowAmt, wethOut);
        Order memory c = _carol(WETH, wethOut, USDC, borrowAmt);
        (Order[] memory orders, uint256[] memory pks) = _pair(a, c, makerPk);
        MatchPlan memory p = _plan(orders, pks, _acyclic());

        uint256 aBefore = IERC20(aWETH).balanceOf(maker);
        vm.prank(solver);
        settlement.matchSettle(p);

        assertApproxEqAbs(IERC20(aWETH).balanceOf(maker) - aBefore, wethOut, 2, "delivery became collateral");
        assertApproxEqAbs(IERC20(usdcVariableDebt).balanceOf(maker), borrowAmt, 2, "borrow booked to the maker");
        assertEq(IERC20(USDC).balanceOf(maker) + IERC20(WETH).balanceOf(maker), 0, "maker wallet never touched");
        assertEq(IERC20(USDC).balanceOf(carol), borrowAmt, "carol paid out of the borrow");
        _assertSolverFlat();
    }

    // ──────────────────── close: withdraw early, pre-fund repay late ────────────────────

    /// The delivery over-covers the debt (1,100 vs 1,000): the repay clamps and the
    /// module sweeps exactly the unconsumed 100 to the maker — not the residue.
    function test_netted_close_withdrawThenPreFundRepay_sweepsSurplus_aaveV2() public {
        _seed(maker, DEBT);
        uint256 wethIn = 0.5 ether;
        uint256 usdcOut = 1_100e6;
        Order memory a = _closeOrder(maker, 1, wethIn, usdcOut);
        Order memory c = _carol(USDC, usdcOut, WETH, wethIn);
        (Order[] memory orders, uint256[] memory pks) = _pair(a, c, makerPk);
        MatchPlan memory p = _plan(orders, pks, _acyclic());

        uint256 aBefore = IERC20(aWETH).balanceOf(maker);
        uint256 debtBefore = IERC20(usdcVariableDebt).balanceOf(maker);
        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(IERC20(usdcVariableDebt).balanceOf(maker), 0, "debt retired in full");
        assertEq(IERC20(USDC).balanceOf(maker), usdcOut - debtBefore, "exactly the unconsumed delivery swept back");
        assertApproxEqAbs(aBefore - IERC20(aWETH).balanceOf(maker), wethIn, 2, "collateral withdrawn");
        assertEq(IERC20(WETH).balanceOf(carol), wethIn, "carol paid out of the withdraw");
        _assertSolverFlat();
    }

    /// Two closes on ONE singleton, both deliveries parked ahead of both repays:
    /// DELIVER A, DELIVER B, ITEM B, ITEM A. Alice over-delivers (sweep), Bob delivers
    /// exactly his debt. When B's repay runs the module holds residue + A's + B's
    /// USDC; the floor leaves A's intact for A, and A's sweep returns only A's surplus.
    function test_netted_twoClosesInterleaved_eachRepaysAndSweepsOnlyItsOwn_aaveV2() public {
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

        uint256 aDebt = IERC20(usdcVariableDebt).balanceOf(maker);
        uint256 bDebt = IERC20(usdcVariableDebt).balanceOf(bob);
        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(IERC20(usdcVariableDebt).balanceOf(maker), 0, "alice's debt retired");
        assertEq(IERC20(usdcVariableDebt).balanceOf(bob), 0, "bob's debt retired");
        assertEq(IERC20(USDC).balanceOf(maker), aOut - aDebt, "alice swept exactly her own surplus");
        assertEq(IERC20(USDC).balanceOf(bob), bOut - bDebt, "bob swept exactly his own surplus");
        assertEq(IERC20(WETH).balanceOf(carol), aIn + bIn, "carol paid");
        _assertSolverFlat();
    }

    /// The pre-funded deposit hoisted ahead of its own DELIVER — with residue on the
    /// singleton that could have "funded" it — fails closed in the core ledger.
    function test_netted_preFundBeforeOwnDelivery_failsClosed_aaveV2() public {
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
}
