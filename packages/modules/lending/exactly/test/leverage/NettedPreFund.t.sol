// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, ItemPolicy, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";
import {Settlement} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";
import {Permit3} from "@core/permit3/Permit3.sol";
import {SettlementLens} from "@periphery/SettlementLens.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";

import {ExactlyPreFundModule} from "../../src/ExactlyPreFundModules.sol";
import {ExactlyTakerModule} from "../../src/ExactlyModules.sol";
import {IExactlyMarket, IExactlyAuditor} from "../../src/interfaces/IExactly.sol";

/// @title ExactlyNettedPreFundTest
/// @notice The Exactly pre-fund module on the NETTED path (`matchSettle`, task 31),
///         against the live exaUSDC / exaWETH Markets on Optimism through the REAL
///         Settlement and Permit3. Closes review 2026-10-18 M-6 for this venue: plan
///         §4.1 requires the netted interleaving to be tested on every pre-fund
///         module, and the review names Exactly's mandatory fixed-branch
///         `totalAmount` (byte 160) ({ExactlyPreFundModule._scaledFace}) as never having run
///         on the path that is now its zero-capital path. Both books are covered here:
///         floating `deposit`/`repay` and FIXED-maturity `depositAtMaturity` /
///         `repayAtMaturity`, the latter full-fill, partial (scaled face) and
///         with the total missing (fail-closed).
///
///         Positions: WETH collateral in exaWETH (entered), USDC debt in exaUSDC.
///         Every plan is ACYCLIC and filled with ZERO solver capital: the order's own
///         TAKE (a borrow / a withdraw on the {ExactlyTakerModule}) funds its input
///         leg early, a counter-order (Carol, a CoW) supplies the output asset, and the
///         pre-funded MAKE (deposit / repay) consumes the delivery late:
///
///           PULL carol → ITEM(A, 0: TAKE) → PULL A (draws nothing) → DELIVER A
///                      → ITEM(A, 1: pre-fund MAKE) → DELIVER carol
///
///         The solver is an EOA holding nothing and approving nothing. The pre-fund
///         singleton carries RESIDUE before the plan, so a sweep sized from anything
///         but the pre-call floor ({PreFundGuard.floorOf}) would show up as a residue
///         or a sibling's parked delivery reaching the wrong maker.
contract ExactlyNettedPreFundTest is CoreSettlementBase {
    // ── deployed Exactly suite on Optimism (same pins as Leverage.t.sol) ──
    address internal constant AUDITOR = 0xaEb62e6F27BC103702E7BC879AE98bceA56f027E;
    address internal constant MARKET_USDC = 0x6926B434CCe9b5b7966aE1BfEef6D0A7DCF3A8bb; // exaUSDC (native)
    address internal constant MARKET_WETH = 0xc4d4500326981eacD020e20A81b1c479c161c7EF; // exaWETH
    address internal constant OP_USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address internal constant OP_WETH = 0x4200000000000000000000000000000000000006;

    uint256 internal constant FORK_BLOCK = 154_900_000; // the package's fork pin
    uint256 internal constant FIXED_INTERVAL = 4 weeks; // Exactly's maturity grid

    uint256 constant COLL = 10 ether; //       the existing WETH collateral every position starts with
    uint256 constant DEBT = 1_000e6; //        the existing USDC debt a close retires
    uint256 constant RESIDUE_USDC = 77e6; //   stray balance already on the singleton
    uint256 constant RESIDUE_WETH = 0.07 ether;

    ExactlyPreFundModule preFund;
    ExactlyTakerModule takerModule;
    uint256 maturity;

    uint256 bobPk = 0xB0B;
    address bob = vm.addr(bobPk);
    uint256 carolPk = 0xCA201;
    address carol = vm.addr(carolPk);

    // ──────────────────── fork plumbing (PreMaturityWithdraw.t.sol pattern) ────────────────────

    function _forkOptimism() internal {
        try vm.envString("OPTIMISM_RPC_URL") returns (string memory v) {
            if (bytes(v).length > 0 && _tryForkOp(v)) return;
        } catch {}
        string[3] memory rpcs = ["https://mainnet.optimism.io", "https://optimism.drpc.org", "https://1rpc.io/op"];
        for (uint256 i = 0; i < rpcs.length; i++) {
            if (_tryForkOp(rpcs[i])) return;
        }
        revert("ExactlyNettedPreFund: no archive-capable Optimism RPC (set OPTIMISM_RPC_URL)");
    }

    function _tryForkOp(string memory rpc) internal returns (bool) {
        try this.__forkOp(rpc) {
            return true;
        } catch {
            return false;
        }
    }

    function __forkOp(string calldata rpc) external {
        vm.createSelectFork(rpc, FORK_BLOCK);
    }

    function setUp() public override {
        // NOT super.setUp(): that forks Ethereum mainnet and pre-approves the solver.
        // Same core deployments, on Optimism; the solver is left with NOTHING.
        _forkOptimism();
        USDC = OP_USDC;
        WETH = OP_WETH;

        permit3 = new Permit3();
        settlement = new Settlement(address(permit3));
        lens = new SettlementLens(address(settlement));
        preFund = new ExactlyPreFundModule(address(permit3), address(settlement));
        takerModule = new ExactlyTakerModule(address(permit3));

        // The next live fixed pool — no warp anywhere in this file, so no oracle or
        // maturity edge is crossed.
        maturity = block.timestamp - (block.timestamp % FIXED_INTERVAL) + FIXED_INTERVAL;

        vm.label(MARKET_USDC, "exaUSDC");
        vm.label(MARKET_WETH, "exaWETH");
        vm.label(AUDITOR, "Auditor");
        vm.label(address(settlement), "settlement");
        vm.label(address(preFund), "preFund");
        vm.label(address(takerModule), "takerModule");
        vm.label(maker, "maker");
        vm.label(bob, "bob");
        vm.label(carol, "carol");
        vm.label(solver, "solver");

        deal(USDC, address(preFund), RESIDUE_USDC);
        deal(WETH, address(preFund), RESIDUE_WETH);
    }

    // ──────────────────── position + auth helpers ────────────────────

    /// @dev WETH collateral (entered) and, optionally, a USDC debt — floating when
    ///      `fixedMaturity == 0`, else at that maturity. Returns what is owed (the
    ///      fixed face incl. fee, or the floating principal). The drawn cash leaves
    ///      the wallet: the close must be funded by the plan.
    function _seed(address who, uint256 debt, uint256 fixedMaturity) internal returns (uint256 owed) {
        deal(WETH, who, COLL);
        vm.startPrank(who);
        IERC20(WETH).approve(MARKET_WETH, COLL);
        IExactlyMarket(MARKET_WETH).deposit(COLL, who);
        IExactlyAuditor(AUDITOR).enterMarket(MARKET_WETH);
        if (debt > 0) {
            if (fixedMaturity == 0) {
                IExactlyMarket(MARKET_USDC).borrow(debt, who, who);
                owed = debt;
            } else {
                owed = IExactlyMarket(MARKET_USDC).borrowAtMaturity(fixedMaturity, debt, type(uint256).max, who, who);
            }
            IERC20(USDC).transfer(address(0xdead), debt);
        }
        vm.stopPrank();
    }

    /// @dev op@0, market@32, asset@64, maturity@96, bound@128, totalAmount@160.
    function _borrowData() internal pure returns (bytes memory) {
        return abi.encode(uint8(ExactlyTakerModule.Op.Borrow), MARKET_USDC, OP_USDC, uint256(0), uint256(0), uint256(0));
    }

    /// @dev Floating, BalanceMode absent ⇒ exact-amount withdraw of the collateral.
    function _withdrawData() internal pure returns (bytes memory) {
        return abi.encode(uint8(ExactlyTakerModule.Op.Withdraw), MARKET_WETH, OP_WETH, uint256(0), uint256(0), uint256(0));
    }

    /// @dev The borrowed market's SHARE allowance funds the on-behalf borrow; the
    ///      taker book bounds it.
    function _authBorrow(address who, uint256 amount) internal {
        vm.startPrank(who);
        IERC20(MARKET_USDC).approve(address(takerModule), type(uint256).max);
        permit3.approveTaker(address(settlement), address(takerModule), keccak256(_borrowData()), uint160(amount), 0);
        vm.stopPrank();
    }

    function _authWithdraw(address who, uint256 amount) internal {
        vm.startPrank(who);
        IERC20(MARKET_WETH).approve(address(takerModule), type(uint256).max);
        permit3.approveTaker(address(settlement), address(takerModule), keccak256(_withdrawData()), uint160(amount), 0);
        vm.stopPrank();
    }

    // ──────────────────── pre-fund data (must match the module's byte maps) ────────────────────

    /// @dev Pre-fund leg reference to legsOut[j] (bits 255+253), op in [244,252).
    function _desc(ExactlyPreFundModule.Op op, address token, uint256 j) internal pure returns (uint256) {
        return (uint256(5) << 253) | (uint256(op) << 244) | (uint256(uint160(token)) << 16) | j;
    }

    /// @dev Supply: forDesc@0, market@32, asset@64, maturity@96, minAssetsRequired@128.
    function _depositData(uint256 mat, uint256 minAssets) internal pure returns (bytes memory) {
        return abi.encode(_desc(ExactlyPreFundModule.Op.Deposit, OP_WETH, 0), MARKET_WETH, OP_WETH, mat, minAssets);
    }

    /// @dev Repay: forDesc@0, market@32, asset@64, maturity@96, positionAssets@128,
    ///      totalAmount at 160 — the funding leg's smallest full-fill delivery (its
    ///      amount: every leg in this file is fixed-priced). Mandatory on the fixed
    ///      branch; inert on floating.
    function _repayData(uint256 mat, uint256 face, uint256 total) internal pure returns (bytes memory) {
        return abi.encode(_desc(ExactlyPreFundModule.Op.Repay, OP_USDC, 0), MARKET_USDC, OP_USDC, mat, face, total);
    }

    // ──────────────────── order builders ────────────────────

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

    /// @dev Open: borrow USDC early, pre-fund deposit the delivered WETH late.
    function _openOrder(address who, uint256 nonce, uint256 borrowAmt, uint256 wethOut, bytes memory depositData)
        internal
        returns (Order memory)
    {
        _authBorrow(who, borrowAmt);
        return _order2(
            who,
            nonce,
            USDC,
            borrowAmt,
            WETH,
            wethOut,
            Item(ItemOp.TAKE, address(takerModule), borrowAmt, address(0), _borrowData()),
            depositData
        );
    }

    /// @dev Close: withdraw WETH collateral early, pre-fund repay the delivered USDC late.
    function _closeOrder(address who, uint256 nonce, uint256 wethIn, uint256 usdcOut, bytes memory repayData)
        internal
        returns (Order memory)
    {
        _authWithdraw(who, wethIn);
        return _order2(
            who,
            nonce,
            WETH,
            wethIn,
            USDC,
            usdcOut,
            Item(ItemOp.TAKE, address(takerModule), wethIn, address(0), _withdrawData()),
            repayData
        );
    }

    /// @dev Carol, the CoW counter-order: sells `amtIn` of `tokIn` for `amtOut` of `tokOut`.
    function _carol(uint256 nonce, address tokIn, uint256 amtIn, address tokOut, uint256 amtOut)
        internal
        returns (Order memory)
    {
        deal(tokIn, carol, amtIn);
        vm.startPrank(carol);
        IERC20(tokIn).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), tokIn, uint160(amtIn), 0);
        vm.stopPrank();
        return _order(carol, nonce, tokIn, tokOut, amtIn, amtOut, new Item[](0));
    }

    function _signAs(Order memory o, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), _hashOrder(o)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Full fills of every order.
    function _plan(Order[] memory orders, uint256[] memory pks, uint256[] memory schedule)
        internal
        view
        returns (MatchPlan memory)
    {
        uint256 n = orders.length;
        uint256[] memory fills = new uint256[](n);
        for (uint256 i; i < n; i++) {
            fills[i] = PackedEncode.getLegInStart(orders[i].legsIn, 0);
        }
        return _planFills(orders, pks, schedule, fills);
    }

    function _planFills(Order[] memory orders, uint256[] memory pks, uint256[] memory schedule, uint256[] memory fills)
        internal
        view
        returns (MatchPlan memory)
    {
        uint256 n = orders.length;
        bytes[] memory sigs = new bytes[](n);
        for (uint256 i; i < n; i++) {
            sigs[i] = _signAs(orders[i], pks[i]);
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

    /// @dev Two closes on one singleton, both deliveries parked ahead of both
    ///      consuming items, the consumers in REVERSE order:
    ///      DELIVER A, DELIVER B, ITEM B, ITEM A. Order 2 = Carol.
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

    function _three(Order memory a, Order memory b, Order memory c)
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
        assertEq(IERC20(USDC).balanceOf(solver) + IERC20(WETH).balanceOf(solver), 0, "zero solver capital, zero take");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "nothing pooled (USDC)");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "nothing pooled (WETH)");
        assertEq(IERC20(USDC).balanceOf(address(preFund)), RESIDUE_USDC, "USDC residue untouched");
        assertEq(IERC20(WETH).balanceOf(address(preFund)), RESIDUE_WETH, "WETH residue untouched");
        assertEq(IERC20(USDC).allowance(address(preFund), MARKET_USDC), 0, "venue grant cleared (USDC)");
        assertEq(IERC20(WETH).allowance(address(preFund), MARKET_WETH), 0, "venue grant cleared (WETH)");
    }

    function _floatingDebt(address who) internal view returns (uint256) {
        (,, uint256 shares) = IExactlyMarket(MARKET_USDC).accounts(who);
        return IExactlyMarket(MARKET_USDC).previewRefund(shares);
    }

    function _fixedDebt(address who) internal view returns (uint256) {
        (uint256 principal, uint256 fee) = IExactlyMarket(MARKET_USDC).fixedBorrowPositions(maturity, who);
        return principal + fee;
    }

    function _wethCollateral(address who) internal view returns (uint256) {
        return IExactlyMarket(MARKET_WETH).previewRedeem(IERC20(MARKET_WETH).balanceOf(who));
    }

    // ──────────────────── open: borrow early, pre-fund deposit late ────────────────────

    /// Floating deposit: the delivered WETH becomes floating exaWETH collateral; the
    /// borrowed USDC pays Carol. Nothing transits the maker's wallet.
    function test_netted_open_borrowThenPreFundDeposit_floating_zeroCapital_exactly() public {
        _seed(maker, 0, 0);
        uint256 borrowAmt = 1_500e6;
        uint256 wethOut = 0.3 ether;
        Order memory a = _openOrder(maker, 1, borrowAmt, wethOut, _depositData(0, 0));
        Order memory c = _carol(1, WETH, wethOut, USDC, borrowAmt);
        (Order[] memory orders, uint256[] memory pks) = _pair(a, c, makerPk);
        MatchPlan memory p = _plan(orders, pks, _acyclic());

        uint256 collBefore = _wethCollateral(maker);
        vm.prank(solver);
        settlement.matchSettle(p);

        assertApproxEqAbs(_wethCollateral(maker) - collBefore, wethOut, 2, "delivery became floating collateral");
        assertApproxEqAbs(IExactlyMarket(MARKET_USDC).previewDebt(maker), borrowAmt, 2, "borrow booked to the maker");
        assertEq(IERC20(USDC).balanceOf(maker) + IERC20(WETH).balanceOf(maker), 0, "maker wallet never touched");
        assertEq(IERC20(USDC).balanceOf(carol), borrowAmt, "carol paid out of the borrow");
        _assertSolverFlat();
    }

    /// FIXED deposit: `depositAtMaturity` of the delivery, guarded by the
    /// maker-signed `minAssetsRequired` (= the delivery), on the netted path.
    function test_netted_open_borrowThenPreFundDeposit_fixedMaturity_zeroCapital_exactly() public {
        _seed(maker, 0, 0);
        uint256 borrowAmt = 1_500e6;
        uint256 wethOut = 0.3 ether;
        Order memory a = _openOrder(maker, 1, borrowAmt, wethOut, _depositData(maturity, wethOut));
        Order memory c = _carol(1, WETH, wethOut, USDC, borrowAmt);
        (Order[] memory orders, uint256[] memory pks) = _pair(a, c, makerPk);
        MatchPlan memory p = _plan(orders, pks, _acyclic());

        uint256 collBefore = _wethCollateral(maker);
        uint256 marketBefore = IERC20(WETH).balanceOf(MARKET_WETH);
        vm.prank(solver);
        settlement.matchSettle(p);

        (uint256 principal, uint256 fee) = IExactlyMarket(MARKET_WETH).fixedDepositPositions(maturity, maker);
        assertEq(principal, wethOut, "the whole delivery is the fixed principal");
        assertGe(principal + fee, wethOut, "position >= the signed floor");
        assertEq(IERC20(WETH).balanceOf(MARKET_WETH) - marketBefore, wethOut, "delivery entered the market");
        assertEq(_wethCollateral(maker), collBefore, "floating book untouched");
        assertApproxEqAbs(IExactlyMarket(MARKET_USDC).previewDebt(maker), borrowAmt, 2, "borrow booked to the maker");
        assertEq(IERC20(USDC).balanceOf(maker) + IERC20(WETH).balanceOf(maker), 0, "maker wallet never touched");
        _assertSolverFlat();
    }

    // ──────────────────── close: withdraw early, pre-fund repay late ────────────────────

    /// Floating: the delivery over-covers the debt (1,100 vs 1,000): the repay clamps
    /// at the live floating debt and the module sweeps exactly the unconsumed 100 to
    /// the maker — not the residue.
    function test_netted_close_withdrawThenPreFundRepay_floating_sweepsSurplus_exactly() public {
        _seed(maker, DEBT, 0);
        uint256 wethIn = 0.5 ether;
        uint256 usdcOut = 1_100e6;
        Order memory a = _closeOrder(maker, 1, wethIn, usdcOut, _repayData(0, 0, 0));
        Order memory c = _carol(1, USDC, usdcOut, WETH, wethIn);
        (Order[] memory orders, uint256[] memory pks) = _pair(a, c, makerPk);
        MatchPlan memory p = _plan(orders, pks, _acyclic());

        uint256 collBefore = _wethCollateral(maker);
        uint256 debtBefore = _floatingDebt(maker);
        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(IExactlyMarket(MARKET_USDC).previewDebt(maker), 0, "debt retired in full");
        assertApproxEqAbs(IERC20(USDC).balanceOf(maker), usdcOut - debtBefore, 1, "exactly the unconsumed delivery swept back");
        assertApproxEqAbs(collBefore - _wethCollateral(maker), wethIn, 2, "collateral withdrawn");
        assertEq(IERC20(WETH).balanceOf(carol), wethIn, "carol paid out of the withdraw");
        _assertSolverFlat();
    }

    /// FIXED, full fill: `positionAssets = owed`, `totalAmount` (byte 160) `= usdcOut` (the
    /// fixed-priced leg's amount). `forAmount == total`, so the whole face is
    /// presented against the delivered budget. Pre-maturity the market takes the
    /// DISCOUNTED cost; the sweep is the discount plus the over-delivery, and is
    /// exactly `usdcOut − what the market took`.
    function test_netted_close_withdrawThenPreFundRepay_fixedMaturity_totalAmount_sweepsSurplus_exactly() public {
        uint256 owed = _seed(maker, DEBT, maturity);
        uint256 wethIn = 0.5 ether;
        uint256 usdcOut = owed + 50e6;
        Order memory a = _closeOrder(maker, 1, wethIn, usdcOut, _repayData(maturity, owed, usdcOut));
        Order memory c = _carol(1, USDC, usdcOut, WETH, wethIn);
        (Order[] memory orders, uint256[] memory pks) = _pair(a, c, makerPk);
        MatchPlan memory p = _plan(orders, pks, _acyclic());

        assertEq(_fixedDebt(maker), owed, "precondition: the fixed position");
        uint256 collBefore = _wethCollateral(maker);
        uint256 marketBefore = IERC20(USDC).balanceOf(MARKET_USDC);
        vm.prank(solver);
        settlement.matchSettle(p);

        uint256 cost = IERC20(USDC).balanceOf(MARKET_USDC) - marketBefore;
        assertEq(_fixedDebt(maker), 0, "the fixed position is closed");
        assertLe(cost, owed, "pre-maturity: never more than the face");
        assertEq(IERC20(USDC).balanceOf(maker), usdcOut - cost, "exactly the unconsumed delivery swept back");
        assertGe(IERC20(USDC).balanceOf(maker), 50e6, "over-delivery (+ discount) reached the maker");
        assertApproxEqAbs(collBefore - _wethCollateral(maker), wethIn, 2, "collateral withdrawn");
        assertEq(IERC20(WETH).balanceOf(carol), wethIn, "carol paid out of the withdraw");
        _assertSolverFlat();
    }

    /// FIXED, PARTIAL netted fill — the path `_scaledFace` exists for. Two half
    /// slices of ONE order, each in its own `matchSettle` against its own Carol. Each
    /// delivery is `usdcOut/2`, so `_scaledFace` presents `owed · (usdcOut/2) /
    /// usdcOut` — half the face — and exactly that much of the position is retired
    /// (F27/H-3: unscaled, every slice would present the WHOLE face; see the
    /// too-small-total test below for what that does on this path). The second slice
    /// closes it to the floor's rounding wei. Every slice sweeps only its own unspent
    /// budget.
    function test_netted_close_fixedMaturity_partialFill_scalesFaceByTotalAmount_exactly() public {
        uint256 owed = _seed(maker, DEBT, maturity);
        uint256 wethIn = 0.5 ether;
        uint256 usdcOut = owed + 50e6;
        if (usdcOut % 2 == 1) usdcOut += 1; // two exact halves of the fixed-priced leg
        Order memory a = _closeOrder(maker, 1, wethIn, usdcOut, _repayData(maturity, owed, usdcOut));

        // ── slice 1 ──
        (uint256 cost1, uint256 swept1) = _halfSlice(a, 1, wethIn / 2, usdcOut / 2);
        uint256 face1 = owed * (usdcOut / 2) / usdcOut;
        assertGt(_fixedDebt(maker), 0, "a half slice must NOT retire the whole fixed position");
        assertApproxEqAbs(_fixedDebt(maker), owed - face1, 1, "exactly the scaled face retired");
        assertEq(swept1, usdcOut / 2 - cost1, "slice 1 swept only its own unspent budget");
        assertEq(IERC20(WETH).balanceOf(carol), wethIn / 2, "carol paid half");

        // ── slice 2: the remainder of the SAME signed order ──
        (uint256 cost2, uint256 swept2) = _halfSlice(a, 2, wethIn - wethIn / 2, usdcOut / 2);
        // Floor rounding per slice: the two halves sum to at most the face, so at
        // most a wei of face stays open — never over-retired.
        assertLe(_fixedDebt(maker), 1, "both slices together retire the face");
        assertEq(swept2, usdcOut / 2 - cost2, "slice 2 swept only its own");
        assertEq(IERC20(WETH).balanceOf(carol), wethIn, "carol paid in full across both");
    }

    /// @dev One partial netted fill of `a` (`fillIn` of its input) against a fresh
    ///      Carol buying exactly that slice. Returns what the market took and what
    ///      reached the maker's wallet.
    function _halfSlice(Order memory a, uint256 carolNonce, uint256 fillIn, uint256 deliverOut)
        internal
        returns (uint256 cost, uint256 swept)
    {
        Order memory c = _carol(carolNonce, USDC, deliverOut, WETH, fillIn);
        (Order[] memory orders, uint256[] memory pks) = _pair(a, c, makerPk);
        uint256[] memory fills = new uint256[](2);
        (fills[0], fills[1]) = (fillIn, deliverOut);
        MatchPlan memory p = _planFills(orders, pks, _acyclic(), fills);

        uint256 marketBefore = IERC20(USDC).balanceOf(MARKET_USDC);
        uint256 makerBefore = IERC20(USDC).balanceOf(maker);
        vm.prank(solver);
        settlement.matchSettle(p);
        cost = IERC20(USDC).balanceOf(MARKET_USDC) - marketBefore;
        swept = IERC20(USDC).balanceOf(maker) - makerBefore;
        _assertSolverFlat();
    }

    /// FIXED, PARTIAL, `totalAmount` mis-signed too SMALL (= the half slice's
    /// delivery): `forAmount >= total`, so the half slice presents the WHOLE face
    /// against a half budget. Pre-maturity the whole face's discounted cost exceeds
    /// that budget, so Exactly refuses (`Disagreement`) — the word at 160 is
    /// load-bearing on the netted path: it alone decides how much face a slice may
    /// retire, and the delivered budget is the only backstop.
    function test_netted_close_fixedMaturity_partialFill_tooSmallTotal_presentsWholeFace_exactly() public {
        uint256 owed = _seed(maker, DEBT, maturity);
        uint256 wethIn = 0.5 ether;
        uint256 usdcOut = owed + 50e6;
        if (usdcOut % 2 == 1) usdcOut += 1;
        Order memory a = _closeOrder(maker, 1, wethIn, usdcOut, _repayData(maturity, owed, usdcOut / 2));
        Order memory c = _carol(1, USDC, usdcOut / 2, WETH, wethIn / 2);
        (Order[] memory orders, uint256[] memory pks) = _pair(a, c, makerPk);
        uint256[] memory fills = new uint256[](2);
        (fills[0], fills[1]) = (wethIn / 2, usdcOut / 2);
        MatchPlan memory p = _planFills(orders, pks, _acyclic(), fills);

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSignature("Disagreement()"));
        settlement.matchSettle(p);
        assertEq(_fixedDebt(maker), owed, "position untouched");
    }

    /// FIXED, totalAmount MISSING (a 160-byte blob — the pre-F27/H-3 shape): the
    /// netted path fails closed in the module with {FaceTotalMissing} rather than
    /// presenting an unscaled face.
    function test_netted_close_fixedMaturity_missingTotalAmount_failsClosed_exactly() public {
        uint256 owed = _seed(maker, DEBT, maturity);
        uint256 wethIn = 0.5 ether;
        uint256 usdcOut = owed + 50e6;
        bytes memory data =
            abi.encode(_desc(ExactlyPreFundModule.Op.Repay, OP_USDC, 0), MARKET_USDC, OP_USDC, maturity, owed);
        assertEq(data.length, 160, "no totalAmount word");
        Order memory a = _closeOrder(maker, 1, wethIn, usdcOut, data);
        Order memory c = _carol(1, USDC, usdcOut, WETH, wethIn);
        (Order[] memory orders, uint256[] memory pks) = _pair(a, c, makerPk);
        MatchPlan memory p = _plan(orders, pks, _acyclic());

        vm.prank(solver);
        vm.expectRevert(ExactlyPreFundModule.FaceTotalMissing.selector);
        settlement.matchSettle(p);
        assertEq(_fixedDebt(maker), owed, "position untouched");
    }

    // ──────────────────── two closes interleaved on ONE singleton ────────────────────

    /// Floating × floating: DELIVER A, DELIVER B, ITEM B, ITEM A. Alice over-delivers
    /// (sweep), Bob delivers exactly his LIVE debt (`previewRefund` of his borrow
    /// shares — a wei or two above the 400 principal: Exactly rounds the refund of
    /// borrow shares UP, so delivering the bare principal leaves 2 wei open). When
    /// B's repay runs the module holds residue + A's + B's USDC; the floor leaves A's
    /// intact for A, and A's sweep returns only A's surplus.
    function test_netted_twoClosesInterleaved_floating_eachRepaysAndSweepsOnlyItsOwn_exactly() public {
        _seed(maker, DEBT, 0);
        _seed(bob, 400e6, 0);
        uint256 aIn = 0.5 ether;
        uint256 aOut = 1_250e6;
        uint256 bIn = 0.2 ether;
        uint256 bOut = _floatingDebt(bob);
        assertGe(bOut, 400e6, "live debt >= principal");
        Order memory a = _closeOrder(maker, 1, aIn, aOut, _repayData(0, 0, 0));
        Order memory b = _closeOrder(bob, 1, bIn, bOut, _repayData(0, 0, 0));
        Order memory c = _carol(1, USDC, aOut + bOut, WETH, aIn + bIn);
        (Order[] memory orders, uint256[] memory pks) = _three(a, b, c);
        MatchPlan memory p = _plan(orders, pks, _interleaved());

        uint256 aDebt = _floatingDebt(maker);
        uint256 bDebt = _floatingDebt(bob);
        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(IExactlyMarket(MARKET_USDC).previewDebt(maker), 0, "alice's debt retired");
        assertEq(IExactlyMarket(MARKET_USDC).previewDebt(bob), 0, "bob's debt retired");
        assertApproxEqAbs(IERC20(USDC).balanceOf(maker), aOut - aDebt, 1, "alice swept exactly her own surplus");
        assertEq(bDebt, bOut, "bob signed his live debt");
        assertEq(IERC20(USDC).balanceOf(bob), 0, "bob had no surplus and received none of alice's");
        assertEq(IERC20(WETH).balanceOf(carol), aIn + bIn, "carol paid");
        _assertSolverFlat();
    }

    /// FIXED × floating on one singleton, same reversed consumption: Alice's FIXED
    /// repay (totalAmount-scaled face, full fill) runs LAST, after Bob's floating
    /// repay has consumed his delivery from a balance that also held Alice's. Bob's
    /// sweep is pinned independently (his live floating debt); Alice's is exactly her
    /// delivery minus what the market took for her face.
    function test_netted_twoClosesInterleaved_fixedAndFloating_eachRepaysAndSweepsOnlyItsOwn_exactly() public {
        uint256 aOwed = _seed(maker, DEBT, maturity);
        _seed(bob, 400e6, 0);
        uint256 aOut = aOwed + 80e6;
        MatchPlan memory p;
        {
            Order memory a = _closeOrder(maker, 1, 0.5 ether, aOut, _repayData(maturity, aOwed, aOut));
            Order memory b = _closeOrder(bob, 1, 0.2 ether, 450e6, _repayData(0, 0, 0));
            Order memory c = _carol(1, USDC, aOut + 450e6, WETH, 0.7 ether);
            (Order[] memory orders, uint256[] memory pks) = _three(a, b, c);
            p = _plan(orders, pks, _interleaved());
        }

        uint256 bDebt = _floatingDebt(bob);
        uint256 marketBefore = IERC20(USDC).balanceOf(MARKET_USDC);
        vm.prank(solver);
        settlement.matchSettle(p);
        uint256 marketTook = IERC20(USDC).balanceOf(MARKET_USDC) - marketBefore;

        assertEq(_fixedDebt(maker), 0, "alice's fixed position closed");
        assertEq(IExactlyMarket(MARKET_USDC).previewDebt(bob), 0, "bob's floating debt retired");
        assertApproxEqAbs(IERC20(USDC).balanceOf(bob), 450e6 - bDebt, 1, "bob swept exactly his own surplus");
        // Alice's cost = what the market took minus Bob's (independently pinned) spend.
        uint256 aliceCost = marketTook - (450e6 - IERC20(USDC).balanceOf(bob));
        assertLe(aliceCost, aOwed, "alice paid at most her face");
        assertEq(IERC20(USDC).balanceOf(maker), aOut - aliceCost, "alice swept exactly her own surplus");
        assertGe(IERC20(USDC).balanceOf(maker), 80e6, "alice's over-delivery reached alice");
        assertEq(IERC20(WETH).balanceOf(carol), 0.7 ether, "carol paid");
        _assertSolverFlat();
    }

    // ──────────────────── ordering: pre-fund before its own delivery ────────────────────

    /// The pre-funded deposit hoisted ahead of its own DELIVER — with residue on the
    /// singleton that could have "funded" it — fails closed in the core ledger.
    function test_netted_preFundBeforeOwnDelivery_failsClosed_exactly() public {
        _seed(maker, 0, 0);
        uint256 borrowAmt = 150e6;
        uint256 wethOut = 0.05 ether; // below RESIDUE_WETH: the floor alone would not stop it
        Order memory a = _openOrder(maker, 1, borrowAmt, wethOut, _depositData(0, 0));
        Order memory c = _carol(1, WETH, wethOut, USDC, borrowAmt);
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

    /// The same hoist on the FIXED repay branch (with USDC residue on the singleton
    /// larger than the delivery): fails closed before the module ever reads the face.
    function test_netted_fixedRepayBeforeOwnDelivery_failsClosed_exactly() public {
        uint256 owed = _seed(maker, DEBT, maturity);
        uint256 wethIn = 0.02 ether;
        uint256 usdcOut = 60e6; // below RESIDUE_USDC
        Order memory a = _closeOrder(maker, 1, wethIn, usdcOut, _repayData(maturity, owed, usdcOut));
        Order memory c = _carol(1, USDC, usdcOut, WETH, wethIn);
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
        assertEq(_fixedDebt(maker), owed, "position untouched");
    }
}
