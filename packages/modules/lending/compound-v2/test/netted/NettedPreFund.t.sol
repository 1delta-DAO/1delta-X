// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MockSettlementBase, MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Order, Item, ItemOp, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";

import {CompoundV2PreFundModule, CompoundV2NativePreFundModule} from "../../src/CompoundV2PreFundModules.sol";
import {CompoundV2WithdrawModule} from "../../src/CompoundV2Modules.sol";

/// @dev WETH9-shaped: `withdraw` pays through `transfer` (2,300 gas), so a module's
///      `receive()` that does anything would revert here exactly as on mainnet.
contract Cv2NettedWETH {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 a) external {
        balanceOf[msg.sender] -= a;
        payable(msg.sender).transfer(a);
    }

    /// @dev Test funding: credits WETH against ETH the test `deal`t to this contract.
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

/// @dev A cToken that books per-account, enough of the cErc20 / cEther surface the
///      modules call. `rate` is the underlying-per-cToken exchange rate (1e18-scaled,
///      deliberately not 1) so a module forwarding underlying instead of cTokens
///      would show. Native when `underlying == address(0)`.
contract Cv2NettedCToken {
    address public immutable underlying;
    uint256 public constant RATE = 2e17; // 1 cToken = 0.2 underlying
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public borrowBalance;
    mapping(address => uint256) public repaid;

    constructor(address _underlying) {
        underlying = _underlying;
    }

    // ── value in ──
    function mint(uint256 a) external returns (uint256) {
        MockERC20(underlying).transferFrom(msg.sender, address(this), a);
        balanceOf[msg.sender] += a * 1e18 / RATE;
        return 0;
    }

    function mint() external payable {
        balanceOf[msg.sender] += msg.value * 1e18 / RATE;
    }

    function repayBorrowBehalf(address b, uint256 a) external returns (uint256) {
        MockERC20(underlying).transferFrom(msg.sender, address(this), a);
        borrowBalance[b] -= a; // over-repay reverts, as Compound's SafeMath does
        repaid[b] += a;
        return 0;
    }

    function repayBorrowBehalf(address b) external payable {
        borrowBalance[b] -= msg.value;
        repaid[b] += msg.value;
    }

    // ── value out ──
    function redeemUnderlying(uint256 a) external returns (uint256) {
        balanceOf[msg.sender] -= (a * 1e18 + RATE - 1) / RATE;
        MockERC20(underlying).transfer(msg.sender, a);
        return 0;
    }

    function exchangeRateCurrent() external pure returns (uint256) {
        return RATE;
    }

    function borrowBalanceCurrent(address a) external view returns (uint256) {
        return borrowBalance[a];
    }

    // ── test seeding ──
    function seedDebt(address a, uint256 d) external {
        borrowBalance[a] = d;
    }

    function seedCollateral(address a, uint256 c) external {
        balanceOf[a] += c;
    }

    // ── the cToken itself ──
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

/// @title Cv2NettedPreFundTest
/// @notice Compound v2's pre-fund family on the NETTED path (`matchSettle`), which
///         since task 31 admits pre-funded MAKE items (review 2026-10-18 M-6), and the
///         new native (cEther) pre-fund sink (M-5) in particular.
///
///         Every module here is SWEEP-SURPLUS shaped: it takes
///         `floor = balance − forAmount` before the venue call and returns everything
///         above it to the item's maker. On the netted path the balance below that
///         floor can be ANOTHER order's delivery, parked on the same singleton between
///         its DELIVER and its ITEM — and, on the native module, that applies twice:
///         to the parked WETH, and to the ETH the unwrap produces mid-item. The tests
///         below drive exactly those interleavings with resident WETH, ETH and
///         underlying on every singleton, and assert nothing crosses between makers.
///
///         Counterparties are counter-orders (CoWs), so every plan settles with zero
///         solver capital: the acyclic OPEN (sell → deposit late) and the acyclic
///         CLOSE (withdraw TAKE early → sell → native repay late).
contract Cv2NettedPreFundTest is MockSettlementBase {
    CompoundV2PreFundModule preFund;
    CompoundV2NativePreFundModule nativePreFund;
    CompoundV2WithdrawModule withdraw;
    Cv2NettedWETH weth;
    Cv2NettedCToken cEther;
    Cv2NettedCToken cB; // ERC20 market over tB
    Cv2NettedCToken cA; // ERC20 market over tA (the close's collateral)

    uint256 bobPk = 0xB0B;
    address bob = vm.addr(bobPk);
    uint256 carolPk = 0xCA201;
    address carol = vm.addr(carolPk);
    uint256 malloryPk = 0xBAD;
    address mallory = vm.addr(malloryPk);
    uint256 davePk = 0xDA7E;
    address dave = vm.addr(davePk);

    uint256 constant IN_A = 1_000e18;
    uint256 constant OUT_A = 13e18; //  alice: deposit
    uint256 constant IN_B = 2_000e18;
    uint256 constant OUT_B = 7e18; //   bob: repay, debt below the delivery
    uint256 constant DEBT_B = 5e18; //  → 2e18 must come back to BOB, and only to bob
    uint256 constant RESIDUE = 3e18; // stray WETH / ETH / tB already on each singleton

    function setUp() public override {
        super.setUp();
        weth = new Cv2NettedWETH();
        vm.deal(address(weth), 1_000_000e18); // backs `mint`
        cEther = new Cv2NettedCToken(address(0));
        cB = new Cv2NettedCToken(address(tB));
        cA = new Cv2NettedCToken(address(tA));
        preFund = new CompoundV2PreFundModule(address(permit3), address(settlement));
        nativePreFund = new CompoundV2NativePreFundModule(address(permit3), address(settlement), address(weth));
        withdraw = new CompoundV2WithdrawModule(address(permit3));
        vm.label(address(nativePreFund), "nativePreFund");
        vm.label(address(preFund), "preFund");

        // Residue on every singleton, in every asset it touches.
        weth.mint(address(nativePreFund), RESIDUE);
        vm.deal(address(nativePreFund), RESIDUE);
        tB.mint(address(preFund), RESIDUE);
        cEther.seedDebt(bob, DEBT_B);
        cB.seedDebt(bob, DEBT_B);
    }

    // ──────────────────── builders ────────────────────

    function _approveAs(address who, address token) internal {
        vm.startPrank(who);
        MockERC20(token).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), token, type(uint160).max, 0);
        vm.stopPrank();
    }

    /// @dev Pre-fund leg reference (bits 255+253), op in [244,252), token in [16,176).
    function _desc(uint256 op, address token, uint256 j) internal pure returns (uint256) {
        return (uint256(5) << 253) | (op << 244) | (uint256(uint160(token)) << 16) | j;
    }

    function _nativeData(CompoundV2NativePreFundModule.Op op) internal view returns (bytes memory) {
        return abi.encode(_desc(uint256(op), address(weth), 0), address(cEther));
    }

    function _erc20Data(CompoundV2PreFundModule.Op op) internal view returns (bytes memory) {
        return abi.encode(_desc(uint256(op), address(tB), 0), address(cB), address(tB));
    }

    /// @dev `who` pays `amtIn` tA for `amtOut` of `tokOut` delivered to `module`,
    ///      consumed by one pre-funded MAKE item carrying `data`.
    function _preFundOrder(
        address who,
        uint256 amtIn,
        address tokOut,
        uint256 amtOut,
        address module,
        bytes memory data
    ) internal view returns (Order memory o) {
        o = _blank(1);
        o.maker = who;
        o.legsIn = PackedEncode.oneLegIn(address(tA), amtIn, 0);
        o.legsOut = PackedEncode.oneLegOut(tokOut, amtOut, 0, module);
        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.MAKE, module: module, amount: 0, recipient: address(0), data: data});
        o.items = PackedEncode.items(items);
    }

    function _carol(address tokIn, uint256 amtIn, address tokOut, uint256 amtOut)
        internal
        view
        returns (Order memory o)
    {
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

    function _three(Order memory a, Order memory b, Order memory c) internal pure returns (Order[] memory o) {
        o = new Order[](3);
        o[0] = a;
        o[1] = b;
        o[2] = c;
    }

    function _u3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory x) {
        x = new uint256[](3);
        x[0] = a;
        x[1] = b;
        x[2] = c;
    }

    /// @dev PULL all three, `mid`, then DELIVER carol.
    function _withMiddle(uint256[] memory mid) internal pure returns (uint256[] memory s) {
        s = new uint256[](mid.length + 4);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 1, 0);
        s[2] = _step(MatchStep.PULL, 2, 0);
        for (uint256 i; i < mid.length; i++) {
            s[3 + i] = mid[i];
        }
        s[s.length - 1] = _step(MatchStep.DELIVER, 2, 0);
    }

    function _interleaved() internal pure returns (uint256[] memory mid) {
        mid = new uint256[](4);
        mid[0] = _step(MatchStep.DELIVER, 0, 0);
        mid[1] = _step(MatchStep.DELIVER, 1, 0);
        mid[2] = _step(MatchStep.ITEM, 1, 0);
        mid[3] = _step(MatchStep.ITEM, 0, 0);
    }

    /// @dev Alice (native deposit) + Bob (native repay) + Carol (sells WETH for tA).
    function _fundNative() internal returns (Order[] memory orders) {
        tA.mint(maker, IN_A);
        tA.mint(bob, IN_B);
        weth.mint(carol, OUT_A + OUT_B);
        _approveAs(maker, address(tA));
        _approveAs(bob, address(tA));
        _approveAs(carol, address(weth));
        orders = _three(
            _preFundOrder(
                maker, IN_A, address(weth), OUT_A, address(nativePreFund), _nativeData(CompoundV2NativePreFundModule.Op.Deposit)
            ),
            _preFundOrder(
                bob, IN_B, address(weth), OUT_B, address(nativePreFund), _nativeData(CompoundV2NativePreFundModule.Op.Repay)
            ),
            _carol(address(weth), OUT_A + OUT_B, address(tA), IN_A + IN_B)
        );
    }

    // ──────────────────── native pre-fund (M-5 sink) on the netted path ────────────────────

    /// THE OPEN, natively: DELIVER A, DELIVER B, ITEM B (repay 5 of 7), ITEM A (deposit 13).
    /// When ITEM B runs the module holds residue + A's 13 + B's 7 WETH and residue ETH;
    /// it unwraps only 5, sweeps exactly B's 2 WETH back to bob, and A's delivery is
    /// intact for ITEM A, which unwraps exactly 13 and forwards only its own cTokens.
    function test_netted_native_interleaved_eachUnwrapsOnlyItsOwnDelivery() public {
        Order[] memory orders = _fundNative();
        MatchPlan memory p =
            _plan(orders, _u3(makerPk, bobPk, carolPk), _u3(IN_A, IN_B, OUT_A + OUT_B), _withMiddle(_interleaved()));

        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(cEther.balanceOf(maker), OUT_A * 1e18 / cEther.RATE(), "alice holds exactly her mint's cTokens");
        assertEq(cEther.balanceOf(address(nativePreFund)), 0, "no cToken left on the singleton");
        assertEq(cEther.repaid(bob), DEBT_B, "bob repaid his debt, clamped, in native");
        assertEq(weth.balanceOf(bob), OUT_B - DEBT_B, "bob got back exactly his unconsumed WETH");
        assertEq(weth.balanceOf(maker), 0, "alice received no sweep of anyone's WETH");
        assertEq(weth.balanceOf(address(nativePreFund)), RESIDUE, "WETH back to its residue");
        assertEq(address(nativePreFund).balance, RESIDUE, "ETH back to its residue");
        assertEq(address(cEther).balance, OUT_A + DEBT_B, "the venue received exactly the two unwraps");
        assertEq(bob.balance + maker.balance, 0, "no raw native to any maker");
        assertEq(tA.balanceOf(carol), IN_A + IN_B, "carol paid");
        assertEq(tA.balanceOf(solver) + weth.balanceOf(solver), 0, "zero solver capital, zero take");
        assertEq(weth.balanceOf(address(settlement)), 0, "nothing pooled");
    }

    /// The native item hoisted ahead of its own delivery, while bob's 7 WETH (and the
    /// residue) would cover its floor, fails closed in the core ledger.
    function test_netted_native_itemBeforeOwnDelivery_failsClosed() public {
        Order[] memory orders = _fundNative();
        orders[0] = _preFundOrder(
            maker, IN_A, address(weth), 2e18, address(nativePreFund), _nativeData(CompoundV2NativePreFundModule.Op.Deposit)
        );
        orders[2] = _carol(address(weth), 2e18 + OUT_B, address(tA), IN_A + IN_B);
        uint256[] memory mid = new uint256[](4);
        mid[0] = _step(MatchStep.DELIVER, 1, 0);
        mid[1] = _step(MatchStep.ITEM, 1, 0);
        mid[2] = _step(MatchStep.ITEM, 0, 0); // before alice's DELIVER
        mid[3] = _step(MatchStep.DELIVER, 0, 0);
        MatchPlan memory p =
            _plan(orders, _u3(makerPk, bobPk, carolPk), _u3(IN_A, IN_B, 2e18 + OUT_B), _withMiddle(mid));

        vm.prank(solver);
        vm.expectRevert(Base.ForLegInvalid.selector);
        settlement.matchSettle(p);
    }

    /// Mallory's native repay names a position with NO debt, so nothing is unwrapped
    /// and the module sweeps everything above the floor to her — while bob's WETH is
    /// parked next to hers. The floor makes her sweep exactly her own delivery.
    function test_netted_native_hostileZeroDebtSweep_takesOnlyItsOwnDelivery() public {
        uint256 outM = 11e18;
        tA.mint(mallory, 1);
        tA.mint(bob, IN_B);
        weth.mint(carol, outM + OUT_B);
        _approveAs(mallory, address(tA));
        _approveAs(bob, address(tA));
        _approveAs(carol, address(weth));
        bytes memory repay = _nativeData(CompoundV2NativePreFundModule.Op.Repay);
        Order memory m = _preFundOrder(mallory, 1, address(weth), outM, address(nativePreFund), repay);
        Order memory b = _preFundOrder(bob, IN_B, address(weth), OUT_B, address(nativePreFund), repay);
        Order memory c = _carol(address(weth), outM + OUT_B, address(tA), IN_B + 1);

        uint256[] memory mid = new uint256[](4);
        mid[0] = _step(MatchStep.DELIVER, 1, 0);
        mid[1] = _step(MatchStep.DELIVER, 0, 0);
        mid[2] = _step(MatchStep.ITEM, 0, 0);
        mid[3] = _step(MatchStep.ITEM, 1, 0);
        MatchPlan memory p =
            _plan(_three(m, b, c), _u3(malloryPk, bobPk, carolPk), _u3(1, IN_B, outM + OUT_B), _withMiddle(mid));

        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(weth.balanceOf(mallory), outM, "mallory swept back exactly her own delivery");
        assertEq(mallory.balance, 0, "and no native");
        assertEq(cEther.repaid(bob), DEBT_B, "bob's repay was fully funded after mallory's sweep");
        assertEq(weth.balanceOf(bob), OUT_B - DEBT_B, "bob's own surplus, untouched by mallory");
        assertEq(weth.balanceOf(address(nativePreFund)), RESIDUE, "WETH residue unreachable");
        assertEq(address(nativePreFund).balance, RESIDUE, "ETH residue unreachable");
    }

    // ──────────────────── ERC20 pre-fund on the netted path ────────────────────

    /// The ERC20 sibling ({CompoundV2PreFundModule}) on the same interleaving: deposit
    /// and repay parked side by side on one singleton with tB residue.
    function test_netted_erc20_interleaved_sweepReturnsOnlyOwnSurplus() public {
        tA.mint(maker, IN_A);
        tA.mint(bob, IN_B);
        tB.mint(carol, OUT_A + OUT_B);
        _approveAs(maker, address(tA));
        _approveAs(bob, address(tA));
        _approveAs(carol, address(tB));
        Order[] memory orders = _three(
            _preFundOrder(maker, IN_A, address(tB), OUT_A, address(preFund), _erc20Data(CompoundV2PreFundModule.Op.Deposit)),
            _preFundOrder(bob, IN_B, address(tB), OUT_B, address(preFund), _erc20Data(CompoundV2PreFundModule.Op.Repay)),
            _carol(address(tB), OUT_A + OUT_B, address(tA), IN_A + IN_B)
        );
        MatchPlan memory p =
            _plan(orders, _u3(makerPk, bobPk, carolPk), _u3(IN_A, IN_B, OUT_A + OUT_B), _withMiddle(_interleaved()));

        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(cB.balanceOf(maker), OUT_A * 1e18 / cB.RATE(), "alice holds exactly her mint's cTokens");
        assertEq(cB.repaid(bob), DEBT_B, "bob repaid, clamped");
        assertEq(tB.balanceOf(bob), OUT_B - DEBT_B, "bob got back exactly his unconsumed slice");
        assertEq(tB.balanceOf(maker), 0, "alice received no sweep");
        assertEq(tB.balanceOf(address(preFund)), RESIDUE, "singleton back to its residue");
        assertEq(tA.balanceOf(solver) + tB.balanceOf(solver), 0, "zero solver capital");
    }

    // ──────────────────── the acyclic CLOSE at zero capital ────────────────────

    /// Dave closes a native-debt position: his cA collateral is withdrawn EARLY (TAKE,
    /// proceeds credited to his tA input leg), sold to Carol for WETH, and the WETH is
    /// delivered to the native pre-fund module and repaid LATE. Dave's wallet holds
    /// nothing before or after but the unconsumed WETH; the solver holds nothing.
    ///
    ///   PULL carol (WETH) → ITEM dave#0 (withdraw tA) → DELIVER dave (WETH → module)
    ///   → ITEM dave#1 (native repay) → DELIVER carol (tA)
    function test_netted_close_withdrawEarly_nativeRepayLate_zeroCapital() public {
        uint256 collOut = 900e18; // tA withdrawn
        uint256 wethIn = 6e18; //    WETH bought with it
        uint256 debt = 4e18; //      dave's live native debt (< delivery)
        cA.seedCollateral(dave, 10 * collOut);
        tA.mint(address(cA), 10 * collOut); // the market's cash
        cEther.seedDebt(dave, debt);

        bytes memory wData = abi.encode(address(cA), address(tA));
        Order memory d = _blank(1);
        d.maker = dave;
        d.legsIn = PackedEncode.oneLegIn(address(tA), collOut, 0);
        d.legsOut = PackedEncode.oneLegOut(address(weth), wethIn, 0, address(nativePreFund));
        {
            Item[] memory items = new Item[](2);
            items[0] = Item({op: ItemOp.TAKE, module: address(withdraw), amount: collOut, recipient: address(0), data: wData});
            items[1] = Item({
                op: ItemOp.MAKE,
                module: address(nativePreFund),
                amount: 0,
                recipient: address(0),
                data: _nativeData(CompoundV2NativePreFundModule.Op.Repay)
            });
            d.items = PackedEncode.items(items);
        }
        vm.startPrank(dave);
        cA.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(withdraw), address(cA), type(uint160).max, 0);
        permit3.approveTaker(address(settlement), address(withdraw), keccak256(wData), type(uint160).max, 0);
        vm.stopPrank();

        weth.mint(carol, wethIn);
        _approveAs(carol, address(weth));
        Order memory c = _carol(address(weth), wethIn, address(tA), collOut);

        Order[] memory orders = new Order[](2);
        orders[0] = d;
        orders[1] = c;
        uint256[] memory pks = new uint256[](2);
        pks[0] = davePk;
        pks[1] = carolPk;
        uint256[] memory fills = new uint256[](2);
        fills[0] = collOut;
        fills[1] = wethIn;
        uint256[] memory s = new uint256[](6);
        s[0] = _step(MatchStep.PULL, 1, 0);
        s[1] = _step(MatchStep.ITEM, 0, 0);
        s[2] = _step(MatchStep.DELIVER, 0, 0);
        s[3] = _step(MatchStep.ITEM, 0, 1);
        s[4] = _step(MatchStep.PULL, 0, 0); // covered by the TAKE: draws nothing
        s[5] = _step(MatchStep.DELIVER, 1, 0);

        uint256 cBefore = cA.balanceOf(dave);
        vm.prank(solver);
        settlement.matchSettle(_plan(orders, pks, fills, s));

        assertEq(cEther.borrowBalance(dave), 0, "native debt fully repaid");
        assertEq(weth.balanceOf(dave), wethIn - debt, "unconsumed WETH back to dave, wrapped");
        assertEq(dave.balance, 0, "no raw native");
        assertEq(cBefore - cA.balanceOf(dave), (collOut * 1e18 + cA.RATE() - 1) / cA.RATE(), "exactly the withdraw's cTokens");
        assertEq(tA.balanceOf(dave), 0, "the withdrawn collateral went to the CoW, not the wallet");
        assertEq(tA.balanceOf(carol), collOut, "carol paid in collateral");
        assertEq(weth.balanceOf(address(nativePreFund)), RESIDUE, "WETH residue intact");
        assertEq(address(nativePreFund).balance, RESIDUE, "ETH residue intact");
        assertEq(tA.balanceOf(solver) + weth.balanceOf(solver), 0, "zero solver capital");
    }

    // ──────────────────── the native sink on the FORWARD path, and its gates ────────────────────

    /// Two partial `fill`s of one native-deposit order: each unwraps exactly the WETH
    /// that fill delivered (the delivery ledger, not a pro-rated item amount). A SELL
    /// leg rounds maker-ward PER FILL, so two slices can deliver the signed total + 1
    /// wei — that wei reaches the maker as cTokens instead of stranding on the
    /// singleton (the {NativeUnwrapModule} rounding note, closed by the ledger).
    function test_forward_native_partialFills_unwrapEachDelivery() public {
        tA.mint(maker, IN_A);
        _approveAs(maker, address(tA));
        weth.mint(solver, OUT_A + 2);
        vm.startPrank(solver);
        weth.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(weth), type(uint160).max, 0);
        vm.stopPrank();
        Order memory o = _preFundOrder(
            maker, IN_A, address(weth), OUT_A, address(nativePreFund), _nativeData(CompoundV2NativePreFundModule.Op.Deposit)
        );
        bytes memory sig = _sign(o);

        vm.prank(solver);
        settlement.fill(o, sig, IN_A / 3);
        vm.prank(solver);
        settlement.fill(o, sig, IN_A - IN_A / 3);

        uint256 delivered = OUT_A + 2 - weth.balanceOf(solver);
        assertGe(delivered, OUT_A, "at least the signed total");
        assertLe(delivered, OUT_A + 1, "at most one wei of per-fill ceil");
        assertEq(address(cEther).balance, delivered, "the two unwraps sum to exactly the deliveries");
        assertEq(cEther.balanceOf(address(nativePreFund)), 0, "every cToken forwarded");
        assertEq(cEther.balanceOf(maker), delivered * 1e18 / cEther.RATE(), "maker holds exactly the mints' cTokens");
        assertEq(weth.balanceOf(address(nativePreFund)), RESIDUE, "WETH residue intact");
        assertEq(address(nativePreFund).balance, RESIDUE, "ETH residue intact");
        assertEq(weth.balanceOf(maker), 0, "nothing swept back on a deposit");
    }

    function test_native_gates() public {
        bytes memory good = _nativeData(CompoundV2NativePreFundModule.Op.Deposit);
        // Only Settlement dispatches a MAKE.
        vm.expectRevert(PreFundGuard.OnlySettlement.selector);
        nativePreFund.makeOnBehalf(maker, 1e18, good);
        vm.startPrank(address(settlement));
        // A literal descriptor is a mis-pairing by construction.
        vm.expectRevert(PreFundGuard.PreFundDescriptorRequired.selector);
        nativePreFund.makeOnBehalf(maker, 1e18, abi.encode(uint256(1e18), address(cEther)));
        // The funding leg must be the module's own WETH.
        vm.expectRevert(PreFundGuard.FundingTokenMismatch.selector);
        nativePreFund.makeOnBehalf(maker, 1e18, abi.encode(_desc(0, address(tB), 0), address(cEther)));
        // Unknown op.
        vm.expectRevert(abi.encodeWithSelector(CompoundV2NativePreFundModule.BadOp.selector, uint256(7)));
        nativePreFund.makeOnBehalf(maker, 1e18, abi.encode(_desc(7, address(weth), 0), address(cEther)));
        // A delivery that did not land here underflows the floor (residue 3 < 4).
        vm.expectRevert();
        nativePreFund.makeOnBehalf(maker, RESIDUE + 1, good);
        vm.stopPrank();
        (address asset, uint256 avail) = nativePreFund.fundingSource(maker, good);
        assertEq(asset, address(weth));
        assertEq(avail, type(uint256).max);
    }
}
