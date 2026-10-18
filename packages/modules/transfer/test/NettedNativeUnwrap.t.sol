// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MockSettlementBase, MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Order, Item, ItemOp, LegIn, LegOut, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";

import {NativeUnwrapModule} from "../src/NativeUnwrapModule.sol";

/// @dev WETH9 in miniature: an ERC-20 whose `withdraw` pays native with the 2300
///      stipend (`transfer`), exactly the shape {NativeUnwrapModule.receive} must
///      stay compatible with. `mint` is test-only; the test backs every minted wei
///      with native via `vm.deal` so `withdraw` is always payable.
contract MockWETH9 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
    }

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }
}

/// @dev Cannot take native at all (no `receive`): the misconfigured contract payee.
contract NoReceive {}

/// @dev Burns every unit of gas it is given: the griefing payee that, uncapped, would
///      starve the rest of a batch.
contract GasBurner {
    receive() external payable {
        while (true) {}
    }
}

/// @dev Succeeds only when given (about) the module's full send budget: burns 90k of
///      the 100k + 2,300 it should receive, then returns. The payee a caller would
///      most like to push into the WETH fallback by starving the send.
contract NeedsGas {
    receive() external payable {
        uint256 start = gasleft();
        while (start - gasleft() < 90_000) {}
    }
}

/// @dev A smart-account-shaped payee whose `receive()` does real work (three fresh
///      SSTOREs, ~66k gas) — above any stipend, inside the module's send budget.
contract HeavyReceiver {
    uint256[3] public slots;

    receive() external payable {
        slots[0] = msg.value;
        slots[1] = block.number;
        slots[2] = uint160(msg.sender);
    }
}

/// @title NettedNativeUnwrapTest
/// @notice {NativeUnwrapModule} on the NETTED path (`matchSettle`), which since task 31
///         admits pre-funded MAKE items. The single-order path delivers and then runs
///         the item with nothing in between, so the only foreign balance the shared
///         singleton can hold at item time is residue. Here the solver writes the
///         schedule, so between an order's DELIVER and its ITEM the module can also
///         hold OTHER orders' in-flight deliveries — the case these tests pin:
///
///           • interleaved (DELIVER A, DELIVER B, ITEM B, ITEM A): each item unwraps
///             exactly its own core-sized `forAmount`, the module ends where it
///             started, residue and a native donation stay unreachable;
///           • an item scheduled before its OWN order's DELIVER fails closed
///             (`ForLegInvalid`) even though a sibling's delivery is parked on the
///             module and would cover it — the core's delivery ledger, not the
///             module's balance, is what admits the item;
///           • a hostile maker+solver pair cannot point an item at the parked
///             delivery (token mismatch, second claim on one leg).
///
///         The counterparty is a third order (a CoW), so the solver fronts nothing:
///         the whole plan settles with zero solver capital.
contract NettedNativeUnwrapTest is MockSettlementBase {
    NativeUnwrapModule unwrap;
    MockWETH9 weth;

    uint256 bobPk = 0xB0B;
    address bob = vm.addr(bobPk);
    uint256 carolPk = 0xCA201;
    address carol = vm.addr(carolPk);
    uint256 malloryPk = 0xBAD;
    address mallory = vm.addr(malloryPk);

    // Deliberately unequal, so a mix-up between the two orders shows in every assert.
    uint256 constant IN_A = 3_000e18;
    uint256 constant OUT_A = 1.3e18;
    uint256 constant IN_B = 2_000e18;
    uint256 constant OUT_B = 0.7e18;

    uint256 constant RESIDUE = 0.25e18; //   stray WETH already on the singleton
    uint256 constant DONATION = 0.5 ether; // stray native already on the singleton
    uint256 constant SEND_GAS = 100_000;

    function setUp() public override {
        super.setUp();
        weth = new MockWETH9();
        unwrap = new NativeUnwrapModule(address(weth), address(settlement), SEND_GAS);
        vm.label(address(unwrap), "nativeUnwrap");
        vm.label(bob, "bob");
        vm.label(carol, "carol");

        // Two makers selling tA for native; Carol sells WETH for tA — the CoW leg.
        tA.mint(maker, IN_A);
        tA.mint(bob, IN_B);
        weth.mint(carol, OUT_A + OUT_B);
        vm.deal(address(weth), OUT_A + OUT_B + RESIDUE); // back every minted wei
        _approveAs(maker, address(tA));
        _approveAs(bob, address(tA));
        _approveAs(carol, address(weth));

        // Foreign balances the module must never spend.
        weth.mint(address(unwrap), RESIDUE);
        vm.deal(address(unwrap), DONATION);
    }

    // ──────────────────── builders ────────────────────

    function _approveAs(address who, address token) internal {
        vm.startPrank(who);
        MockERC20(token).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), token, type(uint160).max, 0);
        vm.stopPrank();
    }

    /// @dev Pre-fund leg reference (bit 255 + bit 253), funding token in [16:176).
    function _forLeg(address token, uint256 j) internal pure returns (uint256) {
        return (uint256(5) << 253) | (uint256(uint160(token)) << 16) | j;
    }

    /// @dev `who` sells `tA` for native: a WETH leg addressed to the module plus the
    ///      unwrap item that spends it.
    function _nativeOut(address who, uint256 nonce, uint256 amtIn, uint256 ethOut)
        internal
        view
        returns (Order memory o)
    {
        return _nativeOutTo(who, nonce, amtIn, ethOut, address(0));
    }

    /// @dev {_nativeOut} with an explicit payout recipient (`address(0)` = the maker).
    function _nativeOutTo(address who, uint256 nonce, uint256 amtIn, uint256 ethOut, address payout)
        internal
        view
        returns (Order memory o)
    {
        o = _blank(nonce);
        o.maker = who;
        o.legsIn = PackedEncode.oneLegIn(address(tA), amtIn, 0);
        o.legsOut = PackedEncode.oneLegOut(address(weth), ethOut, 0, address(unwrap));
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(unwrap),
            amount: 0, // unread: the delivery ledger sizes a pre-funded MAKE
            recipient: address(0),
            data: abi.encode(_forLeg(address(weth), 0), payout)
        });
        o.items = PackedEncode.items(items);
    }

    /// @dev Carol: the CoW counter-order that sells the WETH both makers buy.
    function _carol(uint256 nonce) internal view returns (Order memory o) {
        o = _blank(nonce);
        o.maker = carol;
        o.legsIn = PackedEncode.oneLegIn(address(weth), OUT_A + OUT_B, 0);
        o.legsOut = PackedEncode.oneLegOut(address(tA), IN_A + IN_B, 0, address(0));
    }

    function _step(uint256 kind, uint256 a, uint256 b) internal pure returns (uint256) {
        return MatchStep.pack(kind, a, b);
    }

    /// @dev [Alice, Bob, Carol], each filled in full. Signed here, BEFORE any prank.
    function _plan3(Order memory a, Order memory b, uint256 pkB, Order memory c, uint256[] memory schedule)
        internal
        view
        returns (MatchPlan memory p)
    {
        Order[] memory orders = new Order[](3);
        orders[0] = a;
        orders[1] = b;
        orders[2] = c;
        bytes[] memory sigs = new bytes[](3);
        sigs[0] = _signWith(a, makerPk);
        sigs[1] = _signWith(b, pkB);
        sigs[2] = _signWith(c, carolPk);
        uint256[] memory fills = new uint256[](3);
        fills[0] = PackedEncode.getLegInStart(a.legsIn, 0);
        fills[1] = PackedEncode.getLegInStart(b.legsIn, 0);
        fills[2] = OUT_A + OUT_B;
        p = MatchPlan({
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

    /// @dev PULL all three inputs, then the caller's DELIVER/ITEM middle, then
    ///      Carol's DELIVER last.
    function _schedule(uint256[] memory middle) internal pure returns (uint256[] memory s) {
        s = new uint256[](middle.length + 4);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 1, 0);
        s[2] = _step(MatchStep.PULL, 2, 0);
        for (uint256 i; i < middle.length; i++) {
            s[3 + i] = middle[i];
        }
        s[s.length - 1] = _step(MatchStep.DELIVER, 2, 0);
    }

    // ──────────────────── interleaving ────────────────────

    /// DELIVER A, DELIVER B, ITEM B, ITEM A. While ITEM B runs the module holds
    /// residue + A's delivery + B's delivery; `requireDelivered` admits B's slice and
    /// the module moves exactly `OUT_B`, so A's delivery is still there for ITEM A.
    function test_netted_interleavedDeliveries_eachItemUnwrapsExactlyItsOwn() public {
        uint256[] memory mid = new uint256[](4);
        mid[0] = _step(MatchStep.DELIVER, 0, 0);
        mid[1] = _step(MatchStep.DELIVER, 1, 0);
        mid[2] = _step(MatchStep.ITEM, 1, 0); // reverse order on purpose
        mid[3] = _step(MatchStep.ITEM, 0, 0);
        MatchPlan memory p = _plan3(
            _nativeOut(maker, 1, IN_A, OUT_A), _nativeOut(bob, 1, IN_B, OUT_B), bobPk, _carol(1), _schedule(mid)
        );

        uint256 aliceEth = maker.balance;
        uint256 bobEth = bob.balance;
        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(maker.balance - aliceEth, OUT_A, "alice: exactly her own delivery, in native");
        assertEq(bob.balance - bobEth, OUT_B, "bob: exactly his own delivery, in native");
        assertEq(weth.balanceOf(address(unwrap)), RESIDUE, "module WETH back to its residue");
        assertEq(address(unwrap).balance, DONATION, "native donation untouched");
        assertEq(tA.balanceOf(carol), IN_A + IN_B, "carol paid by the two makers' inputs");
        assertEq(weth.balanceOf(carol), 0, "carol's WETH fully sold");
        // Zero solver capital, nothing pooled.
        assertEq(tA.balanceOf(solver), 0, "solver: no tA");
        assertEq(weth.balanceOf(solver), 0, "solver: no WETH");
        assertEq(tA.balanceOf(address(settlement)), 0, "no tA pooled");
        assertEq(weth.balanceOf(address(settlement)), 0, "no WETH pooled");
    }

    /// The forward ordering (DELIVER A, ITEM A, DELIVER B, ITEM B) is one of the
    /// admissible schedules too, and settles identically.
    function test_netted_forwardShapedSchedule_settlesIdentically() public {
        uint256[] memory mid = new uint256[](4);
        mid[0] = _step(MatchStep.DELIVER, 0, 0);
        mid[1] = _step(MatchStep.ITEM, 0, 0);
        mid[2] = _step(MatchStep.DELIVER, 1, 0);
        mid[3] = _step(MatchStep.ITEM, 1, 0);
        MatchPlan memory p = _plan3(
            _nativeOut(maker, 1, IN_A, OUT_A), _nativeOut(bob, 1, IN_B, OUT_B), bobPk, _carol(1), _schedule(mid)
        );

        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(maker.balance, OUT_A, "alice native");
        assertEq(bob.balance, OUT_B, "bob native");
        assertEq(weth.balanceOf(address(unwrap)), RESIDUE, "module back to residue");
        assertEq(address(unwrap).balance, DONATION, "donation untouched");
    }

    // ──────────────────── delivery-before-consumption ────────────────────

    /// ITEM A before DELIVER A — with B's delivery (0.7) and the residue (0.25)
    /// already parked on the module, i.e. a balance that WOULD satisfy a
    /// balance-floor check for a slice of that size. The item is refused by the core
    /// ledger (`ForLegInvalid`: A's `outs` is still empty), not by the module.
    function test_netted_itemBeforeOwnDelivery_failsClosed_withSiblingDeliveryParked() public {
        // A's slice smaller than what is parked, so only the ledger can refuse it.
        uint256 smallOut = 0.5e18;
        uint256[] memory mid = new uint256[](4);
        mid[0] = _step(MatchStep.DELIVER, 1, 0); // bob's 0.7 WETH lands on the module
        mid[1] = _step(MatchStep.ITEM, 0, 0); //    alice's item, BEFORE alice's DELIVER
        mid[2] = _step(MatchStep.DELIVER, 0, 0);
        mid[3] = _step(MatchStep.ITEM, 1, 0);
        Order memory a = _nativeOut(maker, 1, IN_A, smallOut);
        MatchPlan memory p = _plan3(a, _nativeOut(bob, 1, IN_B, OUT_B), bobPk, _carol(1), _schedule(mid));
        p.orders[2].legsIn = PackedEncode.oneLegIn(address(weth), smallOut + OUT_B, 0);
        p.sigs[2] = _signWith(p.orders[2], carolPk);
        p.fillAmounts[2] = smallOut + OUT_B;

        vm.prank(solver);
        vm.expectRevert(Base.ForLegInvalid.selector);
        settlement.matchSettle(p);
    }

    /// A second item naming the SAME delivered leg is refused even with plenty parked
    /// on the module: `outsUsed` lives in the order's `FillCtx`, which persists across
    /// steps, so the leg is spent once per fill on the netted path too.
    function test_netted_secondItemOnOneLeg_reverts() public {
        Order memory a = _nativeOut(maker, 1, IN_A, OUT_A);
        Item[] memory items = new Item[](2);
        bytes memory d = abi.encode(_forLeg(address(weth), 0), address(0));
        items[0] = Item({op: ItemOp.MAKE, module: address(unwrap), amount: 0, recipient: address(0), data: d});
        items[1] = items[0];
        a.items = PackedEncode.items(items);

        uint256[] memory mid = new uint256[](5);
        mid[0] = _step(MatchStep.DELIVER, 0, 0);
        mid[1] = _step(MatchStep.DELIVER, 1, 0); // bob's 0.7 parked: enough for a re-claim
        mid[2] = _step(MatchStep.ITEM, 0, 0);
        mid[3] = _step(MatchStep.ITEM, 0, 1); //   second claim on alice's leg 0
        mid[4] = _step(MatchStep.ITEM, 1, 0);
        MatchPlan memory p = _plan3(a, _nativeOut(bob, 1, IN_B, OUT_B), bobPk, _carol(1), _schedule(mid));

        vm.prank(solver);
        vm.expectRevert(Base.ForLegInvalid.selector);
        settlement.matchSettle(p);
    }

    // ──────────────────── hostile maker + solver ────────────────────

    /// Mallory signs an order whose module-addressed leg is a token she mints for
    /// free, with a descriptor naming THAT token (so the core's leg-token binding
    /// passes), and schedules her item while Bob's WETH is parked on the singleton.
    /// The module spends WETH, which is not the descriptor's token, so
    /// {PreFundGuard.floorOf} refuses before a wei moves.
    function test_netted_hostileOrder_cannotSpendParkedDelivery() public {
        MockERC20 junk = tC;
        junk.mint(mallory, 1);
        junk.mint(address(this), OUT_B);
        _approveAs(mallory, address(junk));

        Order memory m = _blank(7);
        m.maker = mallory;
        m.legsIn = PackedEncode.oneLegIn(address(junk), 1, 0);
        m.legsOut = PackedEncode.oneLegOut(address(junk), OUT_B, 0, address(unwrap));
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(unwrap),
            amount: 0,
            recipient: address(0),
            data: abi.encode(_forLeg(address(junk), 0), mallory)
        });
        m.items = PackedEncode.items(items);

        // [Bob, Mallory, Carol(sells exactly Bob's WETH)]. The junk Mallory "delivers"
        // is pushed into the pool up front, standing in for a colluding solver.
        Order memory c = _carol(1);
        c.legsIn = PackedEncode.oneLegIn(address(weth), OUT_B, 0);
        c.legsOut = PackedEncode.oneLegOut(address(tA), IN_B, 0, address(0));
        uint256[] memory s = new uint256[](7);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 1, 0);
        s[2] = _step(MatchStep.PULL, 2, 0);
        s[3] = _step(MatchStep.DELIVER, 0, 0); // bob's WETH parks on the module
        s[4] = _step(MatchStep.DELIVER, 1, 0); // mallory's junk lands there too
        s[5] = _step(MatchStep.ITEM, 1, 0); //    ...and her item asks for WETH
        s[6] = _step(MatchStep.DELIVER, 2, 0);

        Order[] memory orders = new Order[](3);
        orders[0] = _nativeOut(bob, 1, IN_B, OUT_B);
        orders[1] = m;
        orders[2] = c;
        bytes[] memory sigs = new bytes[](3);
        sigs[0] = _signWith(orders[0], bobPk);
        sigs[1] = _signWith(m, malloryPk);
        sigs[2] = _signWith(c, carolPk);
        uint256[] memory fills = new uint256[](3);
        fills[0] = IN_B;
        fills[1] = 1;
        fills[2] = OUT_B;
        MatchPlan memory p = MatchPlan({
            orders: orders,
            sigs: sigs,
            fillAmounts: fills,
            takerDatas: new bytes[](0),
            schedule: s,
            callTargets: new address[](0),
            callDatas: new bytes[](0),
            profitRecipient: address(0)
        });
        junk.transfer(address(settlement), OUT_B); // the colluding solver's "delivery"

        vm.prank(solver);
        vm.expectRevert(PreFundGuard.FundingTokenMismatch.selector);
        settlement.matchSettle(p);
    }

    // ──────────────────── batch safety (v2: capped send + WETH fallback) ────────────────────

    /// The netted plan pays two makers natively in ONE transaction. Bob's payee cannot
    /// take native; uncapped-and-reverting (v1) that killed Alice's fill too. Now Bob's
    /// payee is paid in WETH and the plan settles.
    function test_batch_revertingPayee_paidWrapped_otherMakerStillNative() public {
        NoReceive bad = new NoReceive();
        uint256[] memory mid = new uint256[](4);
        mid[0] = _step(MatchStep.DELIVER, 0, 0);
        mid[1] = _step(MatchStep.DELIVER, 1, 0);
        mid[2] = _step(MatchStep.ITEM, 0, 0);
        mid[3] = _step(MatchStep.ITEM, 1, 0);
        MatchPlan memory p = _plan3(
            _nativeOut(maker, 1, IN_A, OUT_A),
            _nativeOutTo(bob, 1, IN_B, OUT_B, address(bad)),
            bobPk,
            _carol(1),
            _schedule(mid)
        );

        vm.expectEmit(true, false, false, true, address(unwrap));
        emit NativeUnwrapModule.PaidWrapped(address(bad), OUT_B);
        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(maker.balance, OUT_A, "alice: native, unaffected by bob's payee");
        assertEq(weth.balanceOf(address(bad)), OUT_B, "bob's payee: the same amount in WETH");
        assertEq(weth.balanceOf(address(unwrap)), RESIDUE, "module back to its residue");
        assertEq(address(unwrap).balance, DONATION, "donation untouched (re-wrap is exact)");
    }

    /// A payee that burns all gas it gets costs the batch at most {SEND_GAS}: the plan
    /// settles, the payee is paid in WETH, and the transaction's gas stays within the
    /// budget of the same plan with an ordinary payee.
    function test_batch_gasBurningPayee_boundedByCap() public {
        GasBurner burner = new GasBurner();
        uint256[] memory mid = new uint256[](4);
        mid[0] = _step(MatchStep.DELIVER, 0, 0);
        mid[1] = _step(MatchStep.DELIVER, 1, 0);
        mid[2] = _step(MatchStep.ITEM, 0, 0);
        mid[3] = _step(MatchStep.ITEM, 1, 0);

        uint256 snap = vm.snapshotState();
        MatchPlan memory base = _plan3(
            _nativeOut(maker, 1, IN_A, OUT_A), _nativeOut(bob, 1, IN_B, OUT_B), bobPk, _carol(1), _schedule(mid)
        );
        vm.prank(solver);
        uint256 g0 = gasleft();
        settlement.matchSettle(base);
        uint256 baseGas = g0 - gasleft();
        vm.revertToState(snap);

        MatchPlan memory p = _plan3(
            _nativeOut(maker, 1, IN_A, OUT_A),
            _nativeOutTo(bob, 1, IN_B, OUT_B, address(burner)),
            bobPk,
            _carol(1),
            _schedule(mid)
        );
        vm.prank(solver);
        uint256 g1 = gasleft();
        settlement.matchSettle(p);
        uint256 burnGas = g1 - gasleft();

        assertEq(maker.balance, OUT_A, "alice native");
        assertEq(weth.balanceOf(address(burner)), OUT_B, "burner paid in WETH");
        // The burner eats its whole budget (+ the 2,300 value stipend); the WETH
        // re-wrap and transfer add a few tens of thousands on top.
        assertLe(burnGas, baseGas + SEND_GAS + 2300 + 60_000, "burn bounded by the cap");
    }

    /// A payee whose `receive()` does real work (~66k: above a stipend, inside the
    /// budget) is paid in NATIVE — the cap is not C10's 2,300-gas exclusion.
    function test_batch_heavySmartAccountPayee_getsNative() public {
        HeavyReceiver acct = new HeavyReceiver();
        uint256[] memory mid = new uint256[](4);
        mid[0] = _step(MatchStep.DELIVER, 0, 0);
        mid[1] = _step(MatchStep.DELIVER, 1, 0);
        mid[2] = _step(MatchStep.ITEM, 0, 0);
        mid[3] = _step(MatchStep.ITEM, 1, 0);
        MatchPlan memory p = _plan3(
            _nativeOut(maker, 1, IN_A, OUT_A),
            _nativeOutTo(bob, 1, IN_B, OUT_B, address(acct)),
            bobPk,
            _carol(1),
            _schedule(mid)
        );

        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(address(acct).balance, OUT_B, "smart account: native");
        assertEq(acct.slots(0), OUT_B, "its receive() ran to completion");
        assertEq(weth.balanceOf(address(acct)), 0, "no WETH fallback");
    }

    /// Too little gas left to hand the payee its full {SEND_GAS}: the module reverts
    /// with {InsufficientSendGas} rather than sending a starved call. With enough gas
    /// the same call (a payee that burns everything) falls back to WETH.
    function test_module_underfundedGas_revertsInsteadOfStarvingTheSend() public {
        GasBurner burner = new GasBurner();
        uint256 amt = 0.1e18; // inside the module's residue: stands in for a delivery
        bytes memory d = abi.encode(_forLeg(address(weth), 0), address(burner));

        vm.prank(address(settlement));
        vm.expectRevert(NativeUnwrapModule.InsufficientSendGas.selector);
        unwrap.makeOnBehalf{gas: SEND_GAS + 40_000}(maker, amt, d);

        vm.prank(address(settlement));
        unwrap.makeOnBehalf{gas: SEND_GAS + 200_000}(maker, amt, d);
        assertEq(weth.balanceOf(address(burner)), amt, "full budget given, refused, paid in WETH");
    }

    /// THE PROPERTY: no gas limit a caller picks turns a payee that CAN take native
    /// within the budget into a WETH payout. Swept across every limit from "far too
    /// little" to "ample" in 1k steps: each attempt either reverts or pays NATIVE.
    /// (EIP-150 alone already leaves a starved send only ~1/64 of the gas, too little
    /// for the re-wrap; {InsufficientSendGas} makes the refusal explicit.)
    function test_module_noGasLimit_forcesWrappedPayout() public {
        NeedsGas payee = new NeedsGas();
        uint256 amt = 0.001e18;
        bytes memory d = abi.encode(_forLeg(address(weth), 0), address(payee));
        uint256 paid;
        for (uint256 g = 60_000; g <= 400_000; g += 1_000) {
            vm.prank(address(settlement));
            try unwrap.makeOnBehalf{gas: g}(maker, amt, d) {
                paid++;
            } catch {}
            assertEq(weth.balanceOf(address(payee)), 0, "never paid wrapped");
        }
        assertGt(paid, 0, "ample gas pays");
        assertEq(address(payee).balance, paid * amt, "every success paid native");
    }

    function test_constructor_sendGasBelowStipend_reverts() public {
        vm.expectRevert(NativeUnwrapModule.SendGasTooLow.selector);
        new NativeUnwrapModule(address(weth), address(settlement), 2299);
    }
}
