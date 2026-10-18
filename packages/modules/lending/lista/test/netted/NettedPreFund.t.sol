// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MockSettlementBase, MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Order, Item, ItemOp, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";

import {ListaPreFundModule} from "../../src/ListaPreFundModules.sol";
import {ListaNativeCollateralTakerModule} from "../../src/ListaNativeModules.sol";
import {ListaBrokerModule} from "../../src/ListaBrokerModule.sol";
import {MarketParams} from "../../src/interfaces/ILista.sol";

/// @dev WBNB-shaped: `withdraw` pays through `transfer` (2,300 gas).
contract ListaNettedWNative {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 a) external {
        balanceOf[msg.sender] -= a;
        payable(msg.sender).transfer(a);
    }

    /// @dev Test funding against ETH `deal`t to this contract.
    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

/// @dev Lista's NATIVE provider shape: payable 3-arg supply (amount = msg.value),
///      4-arg withdraw that pays RAW native to `receiver`.
contract ListaNettedNativeProvider {
    mapping(address => uint256) public collateral;

    function supplyCollateral(MarketParams memory, address onBehalf, bytes memory) external payable {
        require(msg.value != 0, "zero");
        collateral[onBehalf] += msg.value;
    }

    function withdrawCollateral(MarketParams memory, uint256 assets, address onBehalf, address receiver) external {
        collateral[onBehalf] -= assets;
        (bool ok,) = receiver.call{value: assets}("");
        require(ok, "pay");
    }

    function seed(address who, uint256 a) external payable {
        collateral[who] += a;
    }
}

/// @dev Lista's SmartLP provider shape: one- or two-coin zap, LP minted 1:1 per coin
///      wei less a settable haircut (bps), credited to `onBehalf`; `dex()` is itself.
contract ListaNettedSmartProvider {
    address public coin0;
    address public coin1;
    uint256 public haircutBps;
    mapping(address => uint256) public collateral;

    constructor(address c0, address c1) {
        coin0 = c0;
        coin1 = c1;
    }

    function setHaircut(uint256 bps) external {
        haircutBps = bps;
    }

    function supplyCollateral(MarketParams memory, address onBehalf, uint256 a0, uint256 a1, uint256 minLp)
        external
        payable
    {
        if (a0 != 0) MockERC20(coin0).transferFrom(msg.sender, address(this), a0);
        if (a1 != 0) MockERC20(coin1).transferFrom(msg.sender, address(this), a1);
        uint256 lp = (a0 + a1) * (10_000 - haircutBps) / 10_000;
        require(lp >= minLp, "slippage");
        collateral[onBehalf] += lp;
    }

    function dex() external view returns (address) {
        return address(this);
    }

    function coins(uint256 i) external view returns (address) {
        return i == 0 ? coin0 : coin1;
    }
}

/// @dev Broker dynamic repay: pulls the LITERAL amount (as the deployed broker does).
contract ListaNettedBroker {
    address public immutable loanToken;
    mapping(address => uint256) public debt;

    constructor(address t) {
        loanToken = t;
    }

    function seedDebt(address who, uint256 d) external {
        debt[who] = d;
    }

    function repay(uint256 amount, address onBehalf) external {
        require(amount != 0, "ZeroAmount");
        MockERC20(loanToken).transferFrom(msg.sender, address(this), amount);
        debt[onBehalf] -= amount;
    }
}

/// @title ListaNettedPreFundTest
/// @notice Lista's pre-fund family on the NETTED path (`matchSettle`, review
///         2026-10-18 M-6), with the two new provider-market sinks (M-5): the native
///         provider (WBNB delivered, unwrapped EXACTLY inside the item) and the SmartLP
///         one-coin zap. Every singleton carries residue in every asset it touches —
///         wrapped native, raw native and the pool coin — and two makers' deliveries
///         park side by side before either item runs. Counterparties are CoW orders,
///         so every plan settles at zero solver capital: the acyclic OPEN (sell →
///         supply late) and the acyclic CLOSE (native withdraw TAKE early → sell →
///         broker repay late).
contract ListaNettedPreFundTest is MockSettlementBase {
    ListaPreFundModule preFund;
    ListaNativeCollateralTakerModule nativeTaker;
    ListaBrokerModule broker;
    ListaNettedWNative wbnb;
    ListaNettedNativeProvider nativeProvider;
    ListaNettedSmartProvider smartProvider;
    ListaNettedBroker venueBroker;

    uint256 bobPk = 0xB0B;
    address bob = vm.addr(bobPk);
    uint256 carolPk = 0xCA201;
    address carol = vm.addr(carolPk);
    uint256 erinPk = 0xE121;
    address erin = vm.addr(erinPk);
    uint256 davePk = 0xDA7E;
    address dave = vm.addr(davePk);

    uint256 constant IN_A = 1_000e18;
    uint256 constant OUT_A = 13e18;
    uint256 constant IN_B = 2_000e18;
    uint256 constant OUT_B = 7e18;
    uint256 constant RESIDUE = 3e18;

    function setUp() public override {
        super.setUp();
        wbnb = new ListaNettedWNative();
        vm.deal(address(wbnb), 1_000_000e18);
        nativeProvider = new ListaNettedNativeProvider();
        smartProvider = new ListaNettedSmartProvider(address(tB), address(tC));
        venueBroker = new ListaNettedBroker(address(tB));
        preFund = new ListaPreFundModule(address(permit3), address(settlement));
        nativeTaker = new ListaNativeCollateralTakerModule(address(permit3));
        broker = new ListaBrokerModule(address(permit3), address(settlement));
        vm.label(address(preFund), "preFund");

        wbnb.mint(address(preFund), RESIDUE);
        vm.deal(address(preFund), RESIDUE);
        tB.mint(address(preFund), RESIDUE);
        tB.mint(address(broker), RESIDUE);
    }

    // ──────────────────── builders ────────────────────

    function _mp(address coll) internal view returns (MarketParams memory) {
        return MarketParams({loanToken: address(tB), collateralToken: coll, oracle: address(0), irm: address(0), lltv: 0});
    }

    function _approveAs(address who, address token) internal {
        vm.startPrank(who);
        MockERC20(token).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), token, type(uint160).max, 0);
        vm.stopPrank();
    }

    function _desc(uint256 op, address token, uint256 j) internal pure returns (uint256) {
        return (uint256(5) << 253) | (op << 244) | (uint256(uint160(token)) << 16) | j;
    }

    function _nativeData() internal view returns (bytes memory) {
        return abi.encode(
            _desc(uint256(ListaPreFundModule.Op.NativeSupplyCollateral), address(wbnb), 0),
            address(nativeProvider),
            _mp(address(wbnb))
        );
    }

    /// @dev Coin tB at index 0; LP floor = 0.99 LP per coin wei.
    function _smartData() internal view returns (bytes memory) {
        return abi.encode(
            _desc(uint256(ListaPreFundModule.Op.SmartSupplyCollateral), address(tB), 0),
            address(smartProvider),
            address(tB),
            uint256(0),
            uint256(0.99e18),
            _mp(address(smartProvider))
        );
    }

    function _preFundOrder(address who, uint256 amtIn, address tokOut, uint256 amtOut, address module, bytes memory data)
        internal
        view
        returns (Order memory o)
    {
        o = _blank(1);
        o.maker = who;
        o.legsIn = PackedEncode.oneLegIn(address(tA), amtIn, 0);
        o.legsOut = PackedEncode.oneLegOut(tokOut, amtOut, 0, module);
        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.MAKE, module: module, amount: 0, recipient: address(0), data: data});
        o.items = PackedEncode.items(items);
    }

    function _cow(address who, address tokIn, uint256 amtIn, address tokOut, uint256 amtOut)
        internal
        view
        returns (Order memory o)
    {
        o = _blank(1);
        o.maker = who;
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
        o[0] = a;
        o[1] = b;
        o[2] = c;
    }

    function _u(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory x) {
        x = new uint256[](3);
        x[0] = a;
        x[1] = b;
        x[2] = c;
    }

    /// @dev PULL every order, then `mid`, then DELIVER every order from index `firstCow`.
    function _sched(uint256 n, uint256 firstCow, uint256[] memory mid) internal pure returns (uint256[] memory s) {
        s = new uint256[](n + mid.length + (n - firstCow));
        uint256 k;
        for (uint256 i; i < n; i++) {
            s[k++] = _step(MatchStep.PULL, i, 0);
        }
        for (uint256 i; i < mid.length; i++) {
            s[k++] = mid[i];
        }
        for (uint256 i = firstCow; i < n; i++) {
            s[k++] = _step(MatchStep.DELIVER, i, 0);
        }
    }

    function _interleaved() internal pure returns (uint256[] memory mid) {
        mid = new uint256[](4);
        mid[0] = _step(MatchStep.DELIVER, 0, 0);
        mid[1] = _step(MatchStep.DELIVER, 1, 0);
        mid[2] = _step(MatchStep.ITEM, 1, 0);
        mid[3] = _step(MatchStep.ITEM, 0, 0);
    }

    function _assertResidue() internal view {
        assertEq(wbnb.balanceOf(address(preFund)), RESIDUE, "WBNB residue intact");
        assertEq(address(preFund).balance, RESIDUE, "native residue intact");
        assertEq(tB.balanceOf(address(preFund)), RESIDUE, "coin residue intact");
    }

    // ──────────────────── native-provider supply (M-5 sink) ────────────────────

    /// Two native supplies parked side by side: DELIVER A (13 WBNB), DELIVER B (7),
    /// ITEM B, ITEM A. When ITEM B runs the singleton holds 3 + 13 + 7 WBNB and 3
    /// native; it unwraps exactly 7 and supplies exactly 7, and A's 13 are still
    /// there for ITEM A. Nobody is swept anything.
    function test_netted_native_twoSupplies_interleaved_eachUnwrapsOnlyItsOwn() public {
        tA.mint(maker, IN_A);
        tA.mint(bob, IN_B);
        wbnb.mint(carol, OUT_A + OUT_B);
        _approveAs(maker, address(tA));
        _approveAs(bob, address(tA));
        _approveAs(carol, address(wbnb));
        Order[] memory orders = _o(
            _preFundOrder(maker, IN_A, address(wbnb), OUT_A, address(preFund), _nativeData()),
            _preFundOrder(bob, IN_B, address(wbnb), OUT_B, address(preFund), _nativeData()),
            _cow(carol, address(wbnb), OUT_A + OUT_B, address(tA), IN_A + IN_B)
        );
        MatchPlan memory p =
            _plan(orders, _u(makerPk, bobPk, carolPk), _u(IN_A, IN_B, OUT_A + OUT_B), _sched(3, 2, _interleaved()));

        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(nativeProvider.collateral(maker), OUT_A, "alice supplied exactly her delivery, natively");
        assertEq(nativeProvider.collateral(bob), OUT_B, "bob supplied exactly his");
        assertEq(address(nativeProvider).balance, OUT_A + OUT_B, "the provider got exactly the two unwraps");
        assertEq(wbnb.balanceOf(maker) + wbnb.balanceOf(bob), 0, "no sweep to either maker");
        assertEq(maker.balance + bob.balance, 0, "no raw native to either maker");
        _assertResidue();
        assertEq(tA.balanceOf(carol), IN_A + IN_B, "carol paid");
        assertEq(tA.balanceOf(solver) + wbnb.balanceOf(solver), 0, "zero solver capital");
    }

    // ──────────────────── SmartLP supply (M-5 sink) ────────────────────

    /// Native supply (alice) and SmartLP one-coin zap (bob) parked side by side on the
    /// ONE singleton, against two CoW counter-orders. The SmartLP floor is the signed
    /// RATE applied to bob's delivery (0.99 · 7), the venue mints 1:1.
    function test_netted_nativeAndSmart_interleaved_withTwoCows() public {
        tA.mint(maker, IN_A);
        tA.mint(bob, IN_B);
        wbnb.mint(carol, OUT_A);
        tB.mint(erin, OUT_B);
        _approveAs(maker, address(tA));
        _approveAs(bob, address(tA));
        _approveAs(carol, address(wbnb));
        _approveAs(erin, address(tB));
        Order[] memory orders = new Order[](4);
        orders[0] = _preFundOrder(maker, IN_A, address(wbnb), OUT_A, address(preFund), _nativeData());
        orders[1] = _preFundOrder(bob, IN_B, address(tB), OUT_B, address(preFund), _smartData());
        orders[2] = _cow(carol, address(wbnb), OUT_A, address(tA), IN_A);
        orders[3] = _cow(erin, address(tB), OUT_B, address(tA), IN_B);
        uint256[] memory pks = new uint256[](4);
        (pks[0], pks[1], pks[2], pks[3]) = (makerPk, bobPk, carolPk, erinPk);
        uint256[] memory fills = new uint256[](4);
        (fills[0], fills[1], fills[2], fills[3]) = (IN_A, IN_B, OUT_A, OUT_B);

        vm.prank(solver);
        settlement.matchSettle(_plan(orders, pks, fills, _sched(4, 2, _interleaved())));

        assertEq(nativeProvider.collateral(maker), OUT_A, "alice supplied natively");
        assertEq(smartProvider.collateral(bob), OUT_B, "bob's LP = his coin delivery (1:1 venue)");
        assertEq(tB.balanceOf(address(smartProvider)), OUT_B, "the provider pulled exactly bob's coin");
        assertEq(tB.allowance(address(preFund), address(smartProvider)), 0, "approval cleared");
        _assertResidue();
        assertEq(tA.balanceOf(carol), IN_A, "carol paid");
        assertEq(tA.balanceOf(erin), IN_B, "erin paid");
        assertEq(tA.balanceOf(solver) + tB.balanceOf(solver) + wbnb.balanceOf(solver), 0, "zero solver capital");
    }

    /// A SmartLP zap whose venue mints below the signed rate reverts inside the
    /// provider — the per-delivery floor follows the netted delivery too.
    function test_netted_smart_belowRate_failsClosed() public {
        smartProvider.setHaircut(200); // 2% < the 1% the maker allows
        tA.mint(bob, IN_B);
        tB.mint(erin, OUT_B);
        _approveAs(bob, address(tA));
        _approveAs(erin, address(tB));
        Order[] memory orders = new Order[](2);
        orders[0] = _preFundOrder(bob, IN_B, address(tB), OUT_B, address(preFund), _smartData());
        orders[1] = _cow(erin, address(tB), OUT_B, address(tA), IN_B);
        uint256[] memory pks = new uint256[](2);
        (pks[0], pks[1]) = (bobPk, erinPk);
        uint256[] memory fills = new uint256[](2);
        (fills[0], fills[1]) = (IN_B, OUT_B);
        uint256[] memory mid = new uint256[](2);
        mid[0] = _step(MatchStep.DELIVER, 0, 0);
        mid[1] = _step(MatchStep.ITEM, 0, 0);

        MatchPlan memory p = _plan(orders, pks, fills, _sched(2, 1, mid)); // signs: hoist above the cheatcodes

        vm.prank(solver);
        vm.expectRevert(bytes("slippage"));
        settlement.matchSettle(p);
    }

    /// The native item hoisted ahead of its own DELIVER while bob's WBNB (plus the
    /// residue) would cover its floor: the core ledger refuses it.
    function test_netted_native_itemBeforeOwnDelivery_failsClosed() public {
        tA.mint(maker, IN_A);
        tA.mint(bob, IN_B);
        wbnb.mint(carol, 2e18 + OUT_B);
        _approveAs(maker, address(tA));
        _approveAs(bob, address(tA));
        _approveAs(carol, address(wbnb));
        Order[] memory orders = _o(
            _preFundOrder(maker, IN_A, address(wbnb), 2e18, address(preFund), _nativeData()),
            _preFundOrder(bob, IN_B, address(wbnb), OUT_B, address(preFund), _nativeData()),
            _cow(carol, address(wbnb), 2e18 + OUT_B, address(tA), IN_A + IN_B)
        );
        uint256[] memory mid = new uint256[](4);
        mid[0] = _step(MatchStep.DELIVER, 1, 0);
        mid[1] = _step(MatchStep.ITEM, 1, 0);
        mid[2] = _step(MatchStep.ITEM, 0, 0);
        mid[3] = _step(MatchStep.DELIVER, 0, 0);

        MatchPlan memory p =
            _plan(orders, _u(makerPk, bobPk, carolPk), _u(IN_A, IN_B, 2e18 + OUT_B), _sched(3, 2, mid));

        vm.prank(solver);
        vm.expectRevert(Base.ForLegInvalid.selector);
        settlement.matchSettle(p);
    }

    // ──────────────────── the acyclic CLOSE at zero capital ────────────────────

    /// Dave's native collateral is withdrawn EARLY (TAKE through the native provider,
    /// wrapped, credited to his WBNB input leg), sold to Erin for the loan token, and
    /// the loan token is delivered to the broker module's PRE-FUNDED repay, which
    /// runs LATE. No wallet funds, no solver capital, and the broker module's own
    /// residue is untouched.
    ///
    ///   PULL erin (tB) → ITEM dave#0 (withdraw WBNB) → DELIVER dave (tB → broker
    ///   module) → ITEM dave#1 (repay) → DELIVER erin (WBNB)
    function test_netted_close_nativeWithdrawEarly_brokerRepayLate_zeroCapital() public {
        uint256 collOut = 5e18; // WBNB withdrawn
        uint256 repayIn = 900e18; // tB bought with it, repaid
        uint256 debt = 1_000e18;
        vm.deal(address(nativeProvider), 100e18);
        nativeProvider.seed(dave, 50e18);
        venueBroker.seedDebt(dave, debt);

        bytes memory tData = abi.encode(address(nativeProvider), address(nativeProvider), _mp(address(wbnb)));
        bytes memory rData = abi.encode(
            _desc(uint256(ListaBrokerModule.Op.Repay), address(tB), 0),
            address(venueBroker),
            address(tB),
            uint256(type(uint128).max) // dynamic position
        );
        Order memory d = _blank(1);
        d.maker = dave;
        d.legsIn = PackedEncode.oneLegIn(address(wbnb), collOut, 0);
        d.legsOut = PackedEncode.oneLegOut(address(tB), repayIn, 0, address(broker));
        {
            Item[] memory items = new Item[](2);
            items[0] =
                Item({op: ItemOp.TAKE, module: address(nativeTaker), amount: collOut, recipient: address(0), data: tData});
            items[1] = Item({op: ItemOp.MAKE, module: address(broker), amount: 0, recipient: address(0), data: rData});
            d.items = PackedEncode.items(items);
        }
        vm.prank(dave);
        permit3.approveTaker(address(settlement), address(nativeTaker), keccak256(tData), type(uint160).max, 0);

        tB.mint(erin, repayIn);
        _approveAs(erin, address(tB));
        Order memory e = _cow(erin, address(tB), repayIn, address(wbnb), collOut);

        Order[] memory orders = new Order[](2);
        (orders[0], orders[1]) = (d, e);
        uint256[] memory pks = new uint256[](2);
        (pks[0], pks[1]) = (davePk, erinPk);
        uint256[] memory fills = new uint256[](2);
        (fills[0], fills[1]) = (collOut, repayIn);
        uint256[] memory s = new uint256[](6);
        s[0] = _step(MatchStep.PULL, 1, 0);
        s[1] = _step(MatchStep.ITEM, 0, 0);
        s[2] = _step(MatchStep.DELIVER, 0, 0);
        s[3] = _step(MatchStep.ITEM, 0, 1);
        s[4] = _step(MatchStep.PULL, 0, 0); // covered by the TAKE: draws nothing
        s[5] = _step(MatchStep.DELIVER, 1, 0);

        vm.prank(solver);
        settlement.matchSettle(_plan(orders, pks, fills, s));

        assertEq(nativeProvider.collateral(dave), 50e18 - collOut, "exactly the signed collateral withdrawn");
        assertEq(venueBroker.debt(dave), debt - repayIn, "the whole delivery repaid");
        assertEq(wbnb.balanceOf(erin), collOut, "erin paid in wrapped native");
        assertEq(wbnb.balanceOf(dave) + tB.balanceOf(dave) + dave.balance, 0, "dave's wallet untouched");
        assertEq(tB.balanceOf(address(broker)), RESIDUE, "broker module residue intact");
        assertEq(tB.balanceOf(solver) + wbnb.balanceOf(solver), 0, "zero solver capital");
    }

    // ──────────────────── gates of the new ops ────────────────────

    function test_newOps_gates_andFundingSource() public {
        vm.startPrank(address(settlement));
        // The native op's funding token must be the market's collateral (the wrapper).
        vm.expectRevert(PreFundGuard.FundingTokenMismatch.selector);
        preFund.makeOnBehalf(
            maker,
            1,
            abi.encode(
                _desc(uint256(ListaPreFundModule.Op.NativeSupplyCollateral), address(tB), 0),
                address(nativeProvider),
                _mp(address(wbnb))
            )
        );
        // The SmartLP op's funding token must be the signed coin.
        vm.expectRevert(PreFundGuard.FundingTokenMismatch.selector);
        preFund.makeOnBehalf(
            maker,
            1,
            abi.encode(
                _desc(uint256(ListaPreFundModule.Op.SmartSupplyCollateral), address(tC), 0),
                address(smartProvider),
                address(tB),
                uint256(0),
                uint256(0),
                _mp(address(smartProvider))
            )
        );
        vm.expectRevert(abi.encodeWithSelector(ListaPreFundModule.BadOp.selector, uint256(3)));
        preFund.makeOnBehalf(maker, 1, abi.encode(_desc(3, address(tB), 0), address(0), _mp(address(tB))));
        vm.stopPrank();

        (address a,) = preFund.fundingSource(maker, _nativeData());
        assertEq(a, address(wbnb), "native op funds from the wrapper");
        (a,) = preFund.fundingSource(maker, _smartData());
        assertEq(a, address(tB), "smart op funds from the coin");
    }

    /// The FORWARD path (`fill`), in two partial fills: each unwraps exactly the WBNB
    /// that fill delivered; per-fill SELL ceil reaches the maker as collateral.
    function test_forward_native_partialFills_supplyEachDelivery() public {
        tA.mint(maker, IN_A);
        _approveAs(maker, address(tA));
        wbnb.mint(solver, OUT_A + 2);
        vm.startPrank(solver);
        wbnb.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(wbnb), type(uint160).max, 0);
        vm.stopPrank();
        Order memory o = _preFundOrder(maker, IN_A, address(wbnb), OUT_A, address(preFund), _nativeData());
        bytes memory sig = _sign(o);

        vm.prank(solver);
        settlement.fill(o, sig, IN_A / 3);
        vm.prank(solver);
        settlement.fill(o, sig, IN_A - IN_A / 3);

        uint256 delivered = OUT_A + 2 - wbnb.balanceOf(solver);
        assertLe(delivered - OUT_A, 1, "at most one wei of per-fill ceil");
        assertEq(nativeProvider.collateral(maker), delivered, "every delivered wei supplied");
        _assertResidue();
    }
}
