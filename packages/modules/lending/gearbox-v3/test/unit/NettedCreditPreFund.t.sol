// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {stdError} from "forge-std/StdError.sol";
import {MockSettlementBase, MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Order, Item, ItemOp, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";

import {GearboxCreditPreFundModule} from "../../src/GearboxV3PreFundModules.sol";
import {GearboxCreditBorrowModule, GearboxCreditWithdrawModule, GearboxCreditAuth} from "../../src/GearboxV3Modules.sol";
import {IGearboxBot, IGearboxCreditFacadeV3Multicall, MultiCall} from "../../src/interfaces/IGearboxV3.sol";

// ── A Gearbox V3 credit suite with the semantics these modules depend on ─────────
//
//   • CA → CreditManager → CreditFacade chain, borrower registry that REVERTS on an
//     unknown account;
//   • BotListV3's exact-mask rule and per-op permission bits;
//   • the CREDIT MANAGER (not the facade) runs `addCollateral`'s `transferFrom`, with
//     the BOT as payer;
//   • `decreaseDebt` burns the account's UNDERLYING, CAPPED at the total debt, and the
//     remaining debt must be 0 or ≥ `minDebt`;
//   • one end-of-multicall collateral check (`debt ≤ 90% · value`, every token 1:1).

contract NettedCA {
    address public creditManager;

    constructor(address cm) {
        creditManager = cm;
    }

    function transferOut(address token, address to, uint256 amount) external {
        require(msg.sender == creditManager, "only CM");
        MockERC20(token).transfer(to, amount);
    }
}

contract NettedCM {
    address public creditFacade;
    address public immutable underlying;
    address public immutable collateral;
    uint256 public constant MIN_DEBT = 20e18;
    mapping(address => address) public borrowerOf;
    mapping(address => uint256) public debtOf;

    error NoBorrower();
    error BorrowAmountOutOfLimitsException();
    error NotEnoughCollateralException();

    constructor(address _underlying, address _collateral) {
        underlying = _underlying;
        collateral = _collateral;
    }

    function setFacade(address f) external {
        creditFacade = f;
    }

    function register(address ca, address owner) external {
        borrowerOf[ca] = owner;
    }

    function getBorrowerOrRevert(address ca) external view returns (address) {
        address b = borrowerOf[ca];
        if (b == address(0)) revert NoBorrower();
        return b;
    }

    function accrue(address ca, uint256 interest) external {
        debtOf[ca] += interest;
    }

    modifier onlyFacade() {
        require(msg.sender == creditFacade, "only facade");
        _;
    }

    function pullCollateral(address token, address payer, address ca, uint256 amount) external onlyFacade {
        MockERC20(token).transferFrom(payer, ca, amount); // the MANAGER is the spender
    }

    function borrow(address ca, uint256 amount) external onlyFacade {
        debtOf[ca] += amount;
        MockERC20(underlying).mint(ca, amount); // the pool draw
    }

    function repay(address ca, uint256 amount) external onlyFacade {
        uint256 d = debtOf[ca];
        if (amount > d) amount = d; // capped at the total debt
        NettedCA(ca).transferOut(underlying, address(0xB001), amount); // back to the pool
        d -= amount;
        if (d != 0 && d < MIN_DEBT) revert BorrowAmountOutOfLimitsException();
        debtOf[ca] = d;
    }

    function withdrawTo(address ca, address token, address to, uint256 amount) external onlyFacade {
        NettedCA(ca).transferOut(token, to, amount);
    }

    function check(address ca) external view {
        uint256 value = MockERC20(underlying).balanceOf(ca) + MockERC20(collateral).balanceOf(ca);
        if (debtOf[ca] * 10 > value * 9) revert NotEnoughCollateralException();
    }
}

contract NettedFacade {
    NettedCM public immutable cm;
    mapping(address => mapping(address => uint192)) public botPermissions;

    error IncorrectBotPermissions();
    error BotNotRegistered();
    error MissingPermission();

    constructor(NettedCM _cm) {
        cm = _cm;
    }

    function setBotPermissions(address ca, address bot, uint192 mask) external {
        require(cm.borrowerOf(ca) == msg.sender, "owner only");
        if (IGearboxBot(bot).requiredPermissions() != mask) revert IncorrectBotPermissions();
        botPermissions[ca][bot] = mask;
    }

    function botMulticall(address ca, MultiCall[] calldata calls) external {
        uint192 perms = botPermissions[ca][msg.sender];
        if (perms == 0) revert BotNotRegistered();
        for (uint256 i; i < calls.length; i++) {
            require(calls[i].target == address(this), "adapter");
            bytes calldata cd = calls[i].callData;
            bytes4 sel = bytes4(cd[:4]);
            if (sel == IGearboxCreditFacadeV3Multicall.addCollateral.selector) {
                if (perms & GearboxCreditAuth.ADD_COLLATERAL_PERMISSION == 0) revert MissingPermission();
                (address token, uint256 amount) = abi.decode(cd[4:], (address, uint256));
                cm.pullCollateral(token, msg.sender, ca, amount);
            } else if (sel == IGearboxCreditFacadeV3Multicall.increaseDebt.selector) {
                if (perms & GearboxCreditAuth.INCREASE_DEBT_PERMISSION == 0) revert MissingPermission();
                cm.borrow(ca, abi.decode(cd[4:], (uint256)));
            } else if (sel == IGearboxCreditFacadeV3Multicall.decreaseDebt.selector) {
                if (perms & GearboxCreditAuth.DECREASE_DEBT_PERMISSION == 0) revert MissingPermission();
                cm.repay(ca, abi.decode(cd[4:], (uint256)));
            } else if (sel == IGearboxCreditFacadeV3Multicall.withdrawCollateral.selector) {
                if (perms & GearboxCreditAuth.WITHDRAW_COLLATERAL_PERMISSION == 0) revert MissingPermission();
                (address token, uint256 amount, address to) = abi.decode(cd[4:], (address, uint256, address));
                cm.withdrawTo(ca, token, to, amount);
            } else {
                revert("unknown op");
            }
        }
        cm.check(ca);
    }
}

/// @title GearboxNettedCreditPreFundTest
/// @notice {GearboxCreditPreFundModule} + {GearboxCreditWithdrawModule} on the NETTED
///         path (`matchSettle`), modelled on the aave-v3 `NettedPreFund` suite (review
///         2026-10-18 M-6, closing M-1 and M-2 for Gearbox credit).
///
///         Suite: underlying (debt asset) = tB, collateral = tA, all valued 1:1.
///
///         Part 1 — two makers' deliveries parked on ONE singleton, with residue.
///         Part 2 — the acyclic open (borrow TAKE early, AddCollateral late) and the
///         acyclic deleverage / full close (withdraw TAKE early, Repay late), at zero
///         solver capital; plus the LTV-edge cycle and the `minDebt` edge, both of
///         which must fail closed.
contract GearboxNettedCreditPreFundTest is MockSettlementBase {
    GearboxCreditPreFundModule preFund;
    GearboxCreditWithdrawModule withdrawer;
    GearboxCreditBorrowModule borrower;
    NettedCM cm;
    NettedFacade facade;

    uint256 bobPk = 0xB0B;
    address bob = vm.addr(bobPk);
    uint256 carolPk = 0xCA201;
    address carol = vm.addr(carolPk);
    uint256 malloryPk = 0xBAD;
    address mallory = vm.addr(malloryPk);

    address caAlice;
    address caBob;

    uint256 constant RESIDUE = 3e18; // stray tB already on the singleton
    uint256 constant IN_A = 1_000e18;
    uint256 constant OUT_A = 13e18; //  alice: add 13 tB (underlying) as collateral
    uint256 constant IN_B = 2_000e18;
    uint256 constant OUT_B = 27e18; //  bob: repay with 27 against a debt of 25
    uint256 constant DEBT_B = 25e18; // → the 2 over stays on BOB's account (forced Recycle)

    function setUp() public override {
        super.setUp();
        cm = new NettedCM(address(tB), address(tA));
        facade = new NettedFacade(cm);
        cm.setFacade(address(facade));
        preFund = new GearboxCreditPreFundModule(address(permit3), address(settlement));
        withdrawer = new GearboxCreditWithdrawModule(address(permit3));
        borrower = new GearboxCreditBorrowModule(address(permit3));
        vm.label(address(preFund), "preFund");
        vm.label(address(withdrawer), "withdrawer");
        vm.label(address(borrower), "borrower");

        tB.mint(address(preFund), RESIDUE);
        caAlice = _account(maker, 100e18, 0);
        caBob = _account(bob, 100e18, DEBT_B);
    }

    // ──────────────────── builders ────────────────────

    /// @dev A credit account owned by `who` holding `col` tA, with `debt` drawn (the
    ///      borrowed underlying leaves the account), and this suite's bots granted.
    function _account(address who, uint256 col, uint256 debt) internal returns (address ca) {
        ca = address(new NettedCA(address(cm)));
        cm.register(ca, who);
        tA.mint(ca, col);
        if (debt != 0) {
            vm.prank(address(facade));
            cm.borrow(ca, debt);
            vm.prank(address(cm));
            NettedCA(ca).transferOut(address(tB), address(0xdead), debt);
        }
        vm.startPrank(who);
        facade.setBotPermissions(ca, address(preFund), preFund.requiredPermissions());
        facade.setBotPermissions(ca, address(withdrawer), withdrawer.requiredPermissions());
        facade.setBotPermissions(ca, address(borrower), borrower.requiredPermissions());
        vm.stopPrank();
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

    function _pfData(uint256 op, address ca, address token) internal pure returns (bytes memory) {
        return abi.encode(_desc(op, token, 0), ca, token);
    }

    /// @dev `who` pays `amtIn` tC from the wallet for `amtOut` tB delivered to the
    ///      module, consumed by one pre-funded MAKE item carrying `data`.
    function _walletOrder(address who, uint256 amtIn, uint256 amtOut, bytes memory data)
        internal
        view
        returns (Order memory o)
    {
        o = _blank(1);
        o.maker = who;
        o.legsIn = PackedEncode.oneLegIn(address(tC), amtIn, 0);
        o.legsOut = PackedEncode.oneLegOut(address(tB), amtOut, 0, address(preFund));
        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.MAKE, module: address(preFund), amount: 0, recipient: address(0), data: data});
        o.items = PackedEncode.items(items);
    }

    /// @dev A position order on `ca`: `tokIn` produced by a TAKE through `takeModule`,
    ///      `tokOut` delivered to the pre-fund module and consumed by op `makeOp`. The
    ///      maker's only Permit3 grant is the taker allowance on what LEAVES the account.
    function _positionOrder(
        address ca,
        address takeModule,
        uint256 makeOp,
        address tokIn,
        uint256 amtIn,
        address tokOut,
        uint256 amtOut
    ) internal returns (Order memory o) {
        bytes memory takeData = abi.encode(ca, tokIn);
        o = _blank(1);
        o.legsIn = PackedEncode.oneLegIn(tokIn, amtIn, 0);
        o.legsOut = PackedEncode.oneLegOut(tokOut, amtOut, 0, address(preFund));
        Item[] memory items = new Item[](2);
        items[0] = Item({op: ItemOp.TAKE, module: takeModule, amount: amtIn, recipient: address(0), data: takeData});
        items[1] = Item({
            op: ItemOp.MAKE, module: address(preFund), amount: 0, recipient: address(0), data: _pfData(makeOp, ca, tokOut)
        });
        o.items = PackedEncode.items(items);
        vm.prank(maker);
        permit3.approveTaker(address(settlement), takeModule, keccak256(takeData), type(uint160).max, 0);
    }

    function _carol(address tokIn, uint256 amtIn, address tokOut, uint256 amtOut) internal returns (Order memory o) {
        MockERC20(tokIn).mint(carol, amtIn);
        _approveAs(carol, tokIn);
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

    function _two(Order memory a, Order memory b) internal pure returns (Order[] memory o) {
        o = new Order[](2);
        o[0] = a;
        o[1] = b;
    }

    function _three(Order memory a, Order memory b, Order memory c) internal pure returns (Order[] memory o) {
        o = new Order[](3);
        o[0] = a;
        o[1] = b;
        o[2] = c;
    }

    function _u2(uint256 a, uint256 b) internal pure returns (uint256[] memory x) {
        x = new uint256[](2);
        x[0] = a;
        x[1] = b;
    }

    function _u3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory x) {
        x = new uint256[](3);
        x[0] = a;
        x[1] = b;
        x[2] = c;
    }

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

    /// @dev ITEM take (early) → PULL maker (nets to nothing) → PULL carol → DELIVER
    ///      maker (to the module) → ITEM make (late) → DELIVER carol (from the take).
    function _acyclic() internal pure returns (uint256[] memory s) {
        s = new uint256[](6);
        s[0] = _step(MatchStep.ITEM, 0, 0);
        s[1] = _step(MatchStep.PULL, 0, 0);
        s[2] = _step(MatchStep.PULL, 1, 0);
        s[3] = _step(MatchStep.DELIVER, 0, 0);
        s[4] = _step(MatchStep.ITEM, 0, 1);
        s[5] = _step(MatchStep.DELIVER, 1, 0);
    }

    /// @dev Alice (AddCollateral of 13 tB) + Bob (Repay 27 against 25) + Carol (sells
    ///      tB for tC). Both pre-fund items spend tB on the ONE singleton.
    function _fundAddRepay() internal returns (Order[] memory orders) {
        tC.mint(maker, IN_A);
        tC.mint(bob, IN_B);
        _approveAs(maker, address(tC));
        _approveAs(bob, address(tC));
        orders = _three(
            _walletOrder(maker, IN_A, OUT_A, _pfData(0, caAlice, address(tB))),
            _walletOrder(bob, IN_B, OUT_B, _pfData(1, caBob, address(tB))),
            _carol(address(tB), OUT_A + OUT_B, address(tC), IN_A + IN_B)
        );
    }

    // ──────────────────── part 1: shared-singleton interleaving ────────────────────

    /// DELIVER A, DELIVER B, ITEM B (repay 27 against 25), ITEM A (add 13). When ITEM
    /// B runs, the module holds residue + A's 13 + B's 27; the scoped approval is B's
    /// 27, so the manager draws exactly that, and the floor (`residue + 13`) leaves A's
    /// delivery intact for ITEM A. Bob's 2 over the debt stays on BOB's account.
    function test_netted_interleaved_eachSpendsOnlyItsOwnDelivery() public {
        Order[] memory orders = _fundAddRepay();
        uint256[] memory mid = new uint256[](4);
        mid[0] = _step(MatchStep.DELIVER, 0, 0);
        mid[1] = _step(MatchStep.DELIVER, 1, 0);
        mid[2] = _step(MatchStep.ITEM, 1, 0);
        mid[3] = _step(MatchStep.ITEM, 0, 0);
        MatchPlan memory p =
            _plan(orders, _u3(makerPk, bobPk, carolPk), _u3(IN_A, IN_B, OUT_A + OUT_B), _withMiddle(mid));

        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(tB.balanceOf(caAlice), OUT_A, "alice's account got exactly her delivery");
        assertEq(cm.debtOf(caBob), 0, "bob's debt closed (capped at the total)");
        assertEq(tB.balanceOf(caBob), OUT_B - DEBT_B, "bob's over-delivery recycled onto HIS account");
        assertEq(tB.balanceOf(maker) + tB.balanceOf(bob), 0, "no wallet sweep of anyone's tB");
        assertEq(tB.balanceOf(address(preFund)), RESIDUE, "singleton back to its residue");
        assertEq(tB.allowance(address(preFund), address(cm)), 0, "manager grant cleared");
        assertEq(tC.balanceOf(carol), IN_A + IN_B, "carol paid");
        assertEq(tB.balanceOf(solver) + tC.balanceOf(solver), 0, "zero solver capital, zero take");
    }

    /// ITEM A scheduled before DELIVER A while B's delivery and residue are parked on
    /// the module: the core ledger refuses it.
    function test_netted_itemBeforeOwnDelivery_failsClosed() public {
        Order[] memory orders = _fundAddRepay();
        uint256[] memory mid = new uint256[](4);
        mid[0] = _step(MatchStep.DELIVER, 1, 0); // bob's 27 parks
        mid[1] = _step(MatchStep.ITEM, 0, 0); //    alice's item before alice's delivery
        mid[2] = _step(MatchStep.DELIVER, 0, 0);
        mid[3] = _step(MatchStep.ITEM, 1, 0);
        MatchPlan memory p =
            _plan(orders, _u3(makerPk, bobPk, carolPk), _u3(IN_A, IN_B, OUT_A + OUT_B), _withMiddle(mid));

        vm.prank(solver);
        vm.expectRevert(Base.ForLegInvalid.selector);
        settlement.matchSettle(p);
    }

    /// Mallory signs a repay naming BOB's account (the shared bot is registered on it):
    /// the borrower check refuses before anything moves.
    function test_netted_foreignAccount_refusedByTheBorrowerCheck() public {
        tC.mint(mallory, 1);
        _approveAs(mallory, address(tC));
        Order memory m = _walletOrder(mallory, 1, 1e18, _pfData(1, caBob, address(tB)));
        Order memory c = _carol(address(tB), 1e18, address(tC), 1);
        uint256[] memory s = new uint256[](5);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 1, 0);
        s[2] = _step(MatchStep.DELIVER, 0, 0);
        s[3] = _step(MatchStep.ITEM, 0, 0);
        s[4] = _step(MatchStep.DELIVER, 1, 0);
        MatchPlan memory p = _plan(_two(m, c), _u2(malloryPk, carolPk), _u2(1, 1e18), s);

        vm.prank(solver);
        vm.expectRevert(GearboxCreditAuth.InvalidCaller.selector);
        settlement.matchSettle(p);
    }

    // ──────────────────── part 2: the acyclic position shapes ────────────────────

    /// Acyclic OPEN on alice's account (100 tA, no debt): borrow 30 tB early against
    /// the existing collateral, Carol converts, 28 tA delivered to the module,
    /// AddCollateral late. Zero wallet, zero solver capital, zero receive-side grant.
    function test_netted_acyclicOpen_borrowEarly_addCollateralLate_zeroCapital() public {
        Order memory m = _positionOrder(caAlice, address(borrower), 0, address(tB), 30e18, address(tA), 28e18);
        Order memory c = _carol(address(tA), 28e18, address(tB), 30e18);
        MatchPlan memory p = _plan(_two(m, c), _u2(makerPk, carolPk), _u2(30e18, 28e18), _acyclic());

        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(cm.debtOf(caAlice), 30e18, "borrow drawn");
        assertEq(tA.balanceOf(caAlice), 128e18, "delivered collateral added");
        assertEq(tB.balanceOf(carol), 30e18, "carol paid from the borrow");
        assertEq(tA.balanceOf(maker) + tB.balanceOf(maker), 0, "maker wallet untouched");
        assertEq(tA.balanceOf(solver) + tB.balanceOf(solver), 0, "zero solver capital");
        (uint160 a,) = permit3.tokenAllowance(maker, address(preFund), address(tA));
        assertEq(a, 0, "no receive-side allowance");
    }

    /// Acyclic FULL CLOSE (review 2026-10-18 M-2): bob's account holds 100 tA against
    /// 25 tB of debt (+2 accrued). Withdraw 30 tA early with the WITHDRAW-ONLY TAKE —
    /// the op that did not exist — Carol converts, 30 tB delivered, Repay late:
    /// `decreaseDebt` caps at the live 27, the debt is zero, the 3 over is recycled onto
    /// the account. Then the account, debt-free, releases the rest of its collateral
    /// through the same withdraw module.
    function test_netted_acyclicFullClose_withdrawEarly_repayLate_zeroCapital() public {
        address ca = _account(maker, 100e18, DEBT_B);
        cm.accrue(ca, 2e18);
        Order memory m = _positionOrder(ca, address(withdrawer), 1, address(tA), 30e18, address(tB), 30e18);
        Order memory c = _carol(address(tB), 30e18, address(tA), 30e18);
        MatchPlan memory p = _plan(_two(m, c), _u2(makerPk, carolPk), _u2(30e18, 30e18), _acyclic());

        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(cm.debtOf(ca), 0, "debt fully closed, accrual included");
        assertEq(tB.balanceOf(ca), 3e18, "the over-delivery stays on the maker's own account");
        assertEq(tA.balanceOf(ca), 70e18, "collateral left after the early withdraw");
        assertEq(tA.balanceOf(carol), 30e18, "carol paid from the withdrawal");
        assertEq(tA.balanceOf(solver) + tB.balanceOf(solver), 0, "zero solver capital");
        assertEq(tB.balanceOf(address(preFund)), RESIDUE, "singleton back to its residue");

        // Debt-free, the rest leaves through the withdraw-only module: the account is
        // closed in everything but name (`closeCreditAccount` is owner-only).
        bytes memory data = abi.encode(ca, address(tA));
        vm.prank(address(settlement));
        permit3.take(address(withdrawer), maker, uint160(70e18), maker, data);
        assertEq(tA.balanceOf(maker), 70e18, "remaining collateral out to the maker");
    }

    /// The close at the LTV edge is a true CYCLE: the withdraw cannot run before the
    /// repay, so the acyclic plan reverts in the end-of-multicall collateral check.
    function test_netted_closeAtTheLtvEdge_isACycle_reverts() public {
        address ca = _account(maker, 30e18, 25e18); // 83% LTV, check at 90%
        Order memory m = _positionOrder(ca, address(withdrawer), 1, address(tA), 10e18, address(tB), 30e18);
        Order memory c = _carol(address(tB), 30e18, address(tA), 10e18);
        MatchPlan memory p = _plan(_two(m, c), _u2(makerPk, carolPk), _u2(10e18, 30e18), _acyclic());

        vm.prank(solver);
        vm.expectRevert(NettedCM.NotEnoughCollateralException.selector);
        settlement.matchSettle(p);
    }

    /// A delivery that would leave a residual debt in (0, minDebt) fails closed in the
    /// venue — the delivery is not consumed and nothing strands.
    function test_netted_partialRepayBelowMinDebt_failsClosed() public {
        address ca = _account(maker, 100e18, DEBT_B);
        Order memory m = _positionOrder(ca, address(withdrawer), 1, address(tA), 10e18, address(tB), 10e18);
        Order memory c = _carol(address(tB), 10e18, address(tA), 10e18);
        MatchPlan memory p = _plan(_two(m, c), _u2(makerPk, carolPk), _u2(10e18, 10e18), _acyclic());

        vm.prank(solver);
        vm.expectRevert(NettedCM.BorrowAmountOutOfLimitsException.selector);
        settlement.matchSettle(p);
    }

    // ──────────────────── unit: the door and the grants ────────────────────

    function test_unit_masks() public view {
        assertEq(preFund.requiredPermissions(), 0x05, "pre-fund: ADD_COLLATERAL | DECREASE_DEBT");
        assertEq(withdrawer.requiredPermissions(), 0x20, "withdraw: WITHDRAW_COLLATERAL only");
    }

    function test_unit_preFund_onlySettlement() public {
        bytes memory data = _pfData(0, caAlice, address(tB));
        vm.expectRevert(PreFundGuard.OnlySettlement.selector);
        preFund.makeOnBehalf(maker, 1e18, data);
    }

    function test_unit_preFund_unknownOp_reverts() public {
        bytes memory data = _pfData(2, caAlice, address(tB));
        vm.prank(address(settlement));
        vm.expectRevert(abi.encodeWithSelector(GearboxCreditPreFundModule.BadOp.selector, 2));
        preFund.makeOnBehalf(maker, 1e18, data);
    }

    function test_unit_preFund_repayInANonUnderlying_refused() public {
        tA.mint(address(preFund), 1e18);
        bytes memory data = _pfData(1, caAlice, address(tA));
        vm.prank(address(settlement));
        vm.expectRevert(abi.encodeWithSelector(GearboxCreditPreFundModule.NotUnderlying.selector, address(tA), address(tB)));
        preFund.makeOnBehalf(maker, 1e18, data);
    }

    function test_unit_preFund_literalDescriptor_refused() public {
        bytes memory data = abi.encode(uint256(1e18), caAlice, address(tB));
        vm.prank(address(settlement));
        vm.expectRevert(PreFundGuard.PreFundDescriptorRequired.selector);
        preFund.makeOnBehalf(maker, 1e18, data);
    }

    function test_unit_preFund_unfunded_failsClosedOnTheFloor() public {
        bytes memory data = _pfData(0, caAlice, address(tB));
        vm.prank(address(settlement));
        vm.expectRevert(stdError.arithmeticError); // floor underflow: RESIDUE < forAmount
        preFund.makeOnBehalf(maker, RESIDUE + 1, data);
    }

    function test_unit_preFund_zeroForAmount_isANoOp() public {
        bytes memory data = _pfData(0, caAlice, address(tB));
        vm.prank(address(settlement));
        preFund.makeOnBehalf(maker, 0, data);
        assertEq(tB.balanceOf(address(preFund)), RESIDUE, "residue untouched");
    }

    function test_unit_withdraw_onlyPermit3() public {
        vm.expectRevert(GearboxCreditWithdrawModule.OnlyPermit3.selector);
        withdrawer.takeOnBehalf(maker, 1e18, maker, abi.encode(caAlice, address(tA)));
    }

    /// The self-approved drain the borrower check exists for: Mallory grants HERSELF
    /// a taker bucket over a blob naming alice's account and takes from it.
    function test_unit_withdraw_selfApprovedForeignAccount_refused() public {
        bytes memory data = abi.encode(caAlice, address(tA));
        vm.prank(mallory);
        permit3.approveTaker(address(settlement), address(withdrawer), keccak256(data), type(uint160).max, 0);
        vm.prank(address(settlement));
        vm.expectRevert(GearboxCreditAuth.InvalidCaller.selector);
        permit3.take(address(withdrawer), mallory, uint160(1e18), mallory, data);
        assertEq(tA.balanceOf(caAlice), 100e18, "alice's collateral untouched");
    }

    /// Withdraw never draws debt: the only permission it holds is the collateral-out bit.
    function test_unit_withdraw_movesCollateralWithoutDebt() public {
        bytes memory data = abi.encode(caAlice, address(tA));
        vm.prank(maker);
        permit3.approveTaker(address(settlement), address(withdrawer), keccak256(data), type(uint160).max, 0);
        vm.prank(address(settlement));
        permit3.take(address(withdrawer), maker, uint160(40e18), address(0xFEE), data);
        assertEq(tA.balanceOf(address(0xFEE)), 40e18, "collateral to the receiver");
        assertEq(cm.debtOf(caAlice), 0, "no debt drawn");
    }

    function test_unit_fundingSource() public view {
        (address asset, uint256 avail) = preFund.fundingSource(maker, _pfData(1, caBob, address(tB)));
        assertEq(asset, address(tB));
        assertEq(avail, type(uint256).max);
    }
}
