// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MockSettlementBase, MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Order, Item, ItemOp, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";

import {AaveV3PreFundModule} from "../../src/AaveV3PreFundModules.sol";
import {AaveV3CreditModule} from "../../src/AaveV3CreditModule.sol";

/// @dev A venue that does what an honest Aave pool does with an approval — pulls
///      EXACTLY the instructed amount — and books it per `onBehalfOf`, so a test can
///      tell which maker's position each pulled wei went to. `borrow` pays out of
///      a minted float, the way a pool's liquidity would.
contract NettedMockPool {
    mapping(address => uint256) public supplied;
    mapping(address => uint256) public repaid;

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        MockERC20(asset).transferFrom(msg.sender, address(this), amount);
        supplied[onBehalfOf] += amount;
    }

    function repay(address asset, uint256 amount, uint256, address onBehalfOf) external returns (uint256) {
        MockERC20(asset).transferFrom(msg.sender, address(this), amount);
        repaid[onBehalfOf] += amount;
        return amount;
    }

    function borrow(address asset, uint256 amount, uint256, uint16, address) external {
        MockERC20(asset).mint(msg.sender, amount);
    }
}

/// @dev A debt token with a settable per-user balance — the debt the repay op clamps
///      to. Zero for anyone not set, as a real debt token reports for no position.
contract NettedMockDebt {
    mapping(address => uint256) public balanceOf;

    function set(address user, uint256 amount) external {
        balanceOf[user] = amount;
    }
}

/// @title NettedPreFundTest
/// @notice The aave-v3 pre-fund family on the NETTED path (`matchSettle`), which since
///         task 31 admits pre-funded MAKE items and leg-reference TAKE_FOR items.
///
///         Both modules here are SWEEP-SURPLUS shaped: they take
///         `floor = balance − forAmount` BEFORE the venue call, let the venue pull at
///         most `forAmount` (a scoped approval), and return everything above the
///         floor to the item's maker. On the forward path the only foreign balance
///         below that floor is residue; on the netted path it can also be another
///         order's delivery, parked on the same singleton between its DELIVER and
///         its ITEM. These tests drive exactly that interleaving — including a venue
///         that consumes LESS than `forAmount` (the repay clamp), which is the case
///         where a sweep sized from anything but the pre-call floor would hand the
///         parked delivery to the wrong maker.
///
///         The counterparty is a third order (a CoW), so every plan here settles with
///         zero solver capital.
contract NettedPreFundTest is MockSettlementBase {
    AaveV3PreFundModule preFund;
    AaveV3CreditModule credit;
    NettedMockPool pool;
    NettedMockDebt debt;

    uint256 bobPk = 0xB0B;
    address bob = vm.addr(bobPk);
    uint256 carolPk = 0xCA201;
    address carol = vm.addr(carolPk);
    uint256 malloryPk = 0xBAD;
    address mallory = vm.addr(malloryPk);

    // tA = what the makers pay, tB = the delivered asset the modules spend.
    uint256 constant IN_A = 1_000e18;
    uint256 constant OUT_A = 13e18; //  alice: supply
    uint256 constant IN_B = 2_000e18;
    uint256 constant OUT_B = 7e18; //   bob: repay, debt below the delivery
    uint256 constant DEBT_B = 5e18; //  → 2e18 must come back to BOB, and only to bob
    uint256 constant RESIDUE = 3e18; // stray tB already on each singleton

    function setUp() public override {
        super.setUp();
        preFund = new AaveV3PreFundModule(address(permit3), address(settlement));
        credit = new AaveV3CreditModule(address(permit3), address(settlement));
        pool = new NettedMockPool();
        debt = new NettedMockDebt();
        vm.label(address(preFund), "preFund");
        vm.label(address(credit), "credit");

        tB.mint(address(preFund), RESIDUE);
        tB.mint(address(credit), RESIDUE);
        debt.set(bob, DEBT_B);
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

    function _supplyData() internal view returns (bytes memory) {
        return abi.encode(_desc(0, address(tB), 0), address(pool), address(tB));
    }

    function _repayData() internal view returns (bytes memory) {
        return abi.encode(_desc(1, address(tB), 0), address(pool), address(tB), uint256(2), address(debt));
    }

    /// @dev `who` pays `amtIn` tA for `amtOut` tB delivered to `module`, consumed by
    ///      one pre-funded MAKE item carrying `data`.
    function _preFundOrder(address who, uint256 nonce, uint256 amtIn, uint256 amtOut, bytes memory data)
        internal
        view
        returns (Order memory o)
    {
        o = _blank(nonce);
        o.maker = who;
        o.legsIn = PackedEncode.oneLegIn(address(tA), amtIn, 0);
        o.legsOut = PackedEncode.oneLegOut(address(tB), amtOut, 0, address(preFund));
        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.MAKE, module: address(preFund), amount: 0, recipient: address(0), data: data});
        o.items = PackedEncode.items(items);
    }

    /// @dev Carol: the CoW counter-order — sells `tokIn` for `tokOut`.
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

    function _three(Order memory a, Order memory b, Order memory c)
        internal
        pure
        returns (Order[] memory o)
    {
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

    /// @dev Alice (supply) + Bob (repay) + Carol (sells tB for tA), funded and approved.
    function _fundSupplyRepay() internal returns (Order[] memory orders) {
        tA.mint(maker, IN_A);
        tA.mint(bob, IN_B);
        tB.mint(carol, OUT_A + OUT_B);
        _approveAs(maker, address(tA));
        _approveAs(bob, address(tA));
        _approveAs(carol, address(tB));
        orders = _three(
            _preFundOrder(maker, 1, IN_A, OUT_A, _supplyData()),
            _preFundOrder(bob, 1, IN_B, OUT_B, _repayData()),
            _carol(address(tB), OUT_A + OUT_B, address(tA), IN_A + IN_B)
        );
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

    // ──────────────────── pre-funded MAKE (supply / repay) ────────────────────

    /// DELIVER A, DELIVER B, ITEM B (repay: consumes 5 of 7), ITEM A (supply 13).
    /// When ITEM B sweeps, the module holds residue + A's 13 + B's 7; the floor is
    /// `residue + 13`, so the sweep returns exactly B's unconsumed 2 — to bob — and
    /// A's delivery is intact for ITEM A.
    function test_netted_interleaved_sweepReturnsOnlyOwnSurplus() public {
        Order[] memory orders = _fundSupplyRepay();
        uint256[] memory mid = new uint256[](4);
        mid[0] = _step(MatchStep.DELIVER, 0, 0);
        mid[1] = _step(MatchStep.DELIVER, 1, 0);
        mid[2] = _step(MatchStep.ITEM, 1, 0);
        mid[3] = _step(MatchStep.ITEM, 0, 0);
        MatchPlan memory p = _plan(orders, _u3(makerPk, bobPk, carolPk), _u3(IN_A, IN_B, OUT_A + OUT_B), _withMiddle(mid));

        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(pool.supplied(maker), OUT_A, "alice supplied exactly her delivery");
        assertEq(pool.repaid(bob), DEBT_B, "bob repaid his debt, clamped");
        assertEq(tB.balanceOf(bob), OUT_B - DEBT_B, "bob got back exactly his unconsumed slice");
        assertEq(tB.balanceOf(maker), 0, "alice received no sweep of anyone's tB");
        assertEq(tB.balanceOf(address(preFund)), RESIDUE, "singleton back to its residue");
        assertEq(tA.balanceOf(carol), IN_A + IN_B, "carol paid");
        assertEq(tA.balanceOf(solver) + tB.balanceOf(solver), 0, "zero solver capital, zero take");
        assertEq(tB.balanceOf(address(settlement)), 0, "nothing pooled");
    }

    /// ITEM A scheduled before DELIVER A while B's delivery (and residue) sit on the
    /// module — enough balance for A's floor to NOT underflow. Before task 31 that was
    /// the stated reason to refuse the shape ("would silently consume whatever
    /// residue was sitting there"). Now the core ledger refuses it.
    function test_netted_itemBeforeOwnDelivery_failsClosed() public {
        Order[] memory orders = _fundSupplyRepay();
        uint256[] memory mid = new uint256[](4);
        mid[0] = _step(MatchStep.DELIVER, 1, 0); // bob's 7 parks; with residue that's 10 ≥ ...
        mid[1] = _step(MatchStep.ITEM, 1, 0); // (bob is fine)
        mid[2] = _step(MatchStep.ITEM, 0, 0); // ... alice's item before alice's delivery
        mid[3] = _step(MatchStep.DELIVER, 0, 0);
        // Give alice a slice the parked balance would cover.
        orders[0] = _preFundOrder(maker, 1, IN_A, 2e18, _supplyData());
        orders[2] = _carol(address(tB), 2e18 + OUT_B, address(tA), IN_A + IN_B);
        MatchPlan memory p = _plan(orders, _u3(makerPk, bobPk, carolPk), _u3(IN_A, IN_B, 2e18 + OUT_B), _withMiddle(mid));

        vm.prank(solver);
        vm.expectRevert(Base.ForLegInvalid.selector);
        settlement.matchSettle(p);
    }

    /// A hostile maker (Mallory) with a solver's help: her repay names a market where
    /// she has NO debt, so the venue consumes nothing and the module sweeps everything
    /// above the floor to her — while Bob's delivery is parked on the same singleton.
    /// The floor makes her sweep exactly her OWN delivery; bob's item then repays in
    /// full and gets his own surplus. Nothing crosses between the two makers.
    function test_netted_hostileZeroConsumeSweep_takesOnlyItsOwnDelivery() public {
        uint256 outM = 11e18;
        tA.mint(mallory, 1);
        tA.mint(bob, IN_B);
        tB.mint(carol, outM + OUT_B);
        _approveAs(mallory, address(tA));
        _approveAs(bob, address(tA));
        _approveAs(carol, address(tB));

        Order memory m = _preFundOrder(mallory, 1, 1, outM, _repayData()); // debt(mallory) == 0
        Order memory b = _preFundOrder(bob, 1, IN_B, OUT_B, _repayData());
        Order memory c = _carol(address(tB), outM + OUT_B, address(tA), IN_B + 1);

        uint256[] memory mid = new uint256[](4);
        mid[0] = _step(MatchStep.DELIVER, 1, 0); // bob's 7 parks first
        mid[1] = _step(MatchStep.DELIVER, 0, 0); // mallory's 11
        mid[2] = _step(MatchStep.ITEM, 0, 0); //    mallory sweeps "everything above the floor"
        mid[3] = _step(MatchStep.ITEM, 1, 0);
        MatchPlan memory p = _plan(_three(m, b, c), _u3(malloryPk, bobPk, carolPk), _u3(1, IN_B, outM + OUT_B), _withMiddle(mid));

        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(tB.balanceOf(mallory), outM, "mallory swept back exactly her own delivery");
        assertEq(pool.repaid(bob), DEBT_B, "bob's repay was fully funded after mallory's sweep");
        assertEq(tB.balanceOf(bob), OUT_B - DEBT_B, "bob's own surplus, untouched by mallory");
        assertEq(tB.balanceOf(address(preFund)), RESIDUE, "residue unreachable");
    }

    // ──────────────────── TAKE_FOR composite (credit / leverage) ────────────────────

    /// @dev `who` opens leverage: `coll` tB delivered to the credit module (pre-fund),
    ///      which supplies it and borrows `borrowAmt` tA into the pool — the proceeds
    ///      that pay `who`'s own input leg. No PULL step and no wallet balance: the
    ///      borrow IS the payment.
    function _leverage(address who, uint256 nonce, uint256 borrowAmt, uint256 coll)
        internal
        returns (Order memory o)
    {
        bytes memory data =
            abi.encode(_desc(1, address(tB), 0), uint256(0), address(pool), address(tA), uint256(2), address(tB));
        o = _blank(nonce);
        o.maker = who;
        o.legsIn = PackedEncode.oneLegIn(address(tA), borrowAmt, 0);
        o.legsOut = PackedEncode.oneLegOut(address(tB), coll, 0, address(credit));
        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.TAKE_FOR, module: address(credit), amount: borrowAmt, recipient: address(0), data: data});
        o.items = PackedEncode.items(items);
        vm.prank(who);
        permit3.approveTaker(address(settlement), address(credit), keccak256(data), type(uint160).max, 0);
    }

    /// Two leverage opens on ONE credit singleton, deliveries interleaved ahead of
    /// both items: DELIVER L1, DELIVER L2, ITEM L2, ITEM L1. Each supplies exactly
    /// its own collateral; the borrow proceeds pay each order's input; Carol (who
    /// sells the collateral) is paid out of those proceeds. Zero solver capital,
    /// zero maker wallet — the acyclic leverage shape §2 of the plan describes,
    /// funded by a counter-order.
    function test_netted_takeFor_twoLeverageOpens_interleaved_eachSuppliesItsOwn() public {
        uint256 b1 = 500e18;
        uint256 c1 = 9e18;
        uint256 b2 = 300e18;
        uint256 c2 = 4e18;
        Order memory l1 = _leverage(maker, 1, b1, c1);
        Order memory l2 = _leverage(bob, 1, b2, c2);
        Order memory c = _carol(address(tB), c1 + c2, address(tA), b1 + b2);
        tB.mint(carol, c1 + c2);
        _approveAs(carol, address(tB));

        uint256[] memory s = new uint256[](6);
        s[0] = _step(MatchStep.PULL, 2, 0); //    carol's collateral into the pool
        s[1] = _step(MatchStep.DELIVER, 0, 0); // L1 collateral → credit module
        s[2] = _step(MatchStep.DELIVER, 1, 0); // L2 collateral parks next to it
        s[3] = _step(MatchStep.ITEM, 1, 0); //    L2: supply c2, borrow b2 → pool
        s[4] = _step(MatchStep.ITEM, 0, 0); //    L1: supply c1, borrow b1 → pool
        s[5] = _step(MatchStep.DELIVER, 2, 0); // carol paid from the borrows
        MatchPlan memory p = _plan(_three(l1, l2, c), _u3(makerPk, bobPk, carolPk), _u3(b1, b2, c1 + c2), s);

        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(pool.supplied(maker), c1, "L1 supplied exactly its delivery");
        assertEq(pool.supplied(bob), c2, "L2 supplied exactly its delivery");
        assertEq(tB.balanceOf(address(credit)), RESIDUE, "credit singleton back to residue");
        assertEq(tA.balanceOf(carol), b1 + b2, "carol paid out of the two borrows");
        assertEq(tA.balanceOf(maker) + tB.balanceOf(maker), 0, "alice's wallet untouched");
        assertEq(tA.balanceOf(bob) + tB.balanceOf(bob), 0, "bob's wallet untouched");
        assertEq(tA.balanceOf(solver) + tB.balanceOf(solver), 0, "zero solver capital");
    }

    /// The leverage item hoisted ahead of its own collateral delivery — while the
    /// sibling's collateral is parked on the module — fails closed in the core.
    function test_netted_takeFor_itemBeforeOwnDelivery_failsClosed() public {
        uint256 b1 = 500e18;
        uint256 c1 = 2e18;
        uint256 b2 = 300e18;
        uint256 c2 = 4e18; // parked, larger than c1
        Order memory l1 = _leverage(maker, 1, b1, c1);
        Order memory l2 = _leverage(bob, 1, b2, c2);
        Order memory c = _carol(address(tB), c1 + c2, address(tA), b1 + b2);
        tB.mint(carol, c1 + c2);
        _approveAs(carol, address(tB));

        uint256[] memory s = new uint256[](6);
        s[0] = _step(MatchStep.PULL, 2, 0);
        s[1] = _step(MatchStep.DELIVER, 1, 0);
        s[2] = _step(MatchStep.ITEM, 0, 0); // L1 before L1's DELIVER
        s[3] = _step(MatchStep.DELIVER, 0, 0);
        s[4] = _step(MatchStep.ITEM, 1, 0);
        s[5] = _step(MatchStep.DELIVER, 2, 0);
        MatchPlan memory p = _plan(_three(l1, l2, c), _u3(makerPk, bobPk, carolPk), _u3(b1, b2, c1 + c2), s);

        vm.prank(solver);
        vm.expectRevert(Base.ForLegInvalid.selector);
        settlement.matchSettle(p);
    }
}
