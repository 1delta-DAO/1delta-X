// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Base} from "@core/settlement/Base.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {SignatureVerification} from "@core/permit3/SignatureVerification.sol";
import {
    Settlement,
    CallbackMode,
    Order,
    Item,
    ItemOp,
    LegIn,
    LegOut,
    MatchPlan,
    MatchStep
} from "@core/settlement/Settlement.sol";

import {MockSettlementBase, MockERC20} from "../shared/MockSettlementBase.t.sol";
import {PackedEncode} from "../shared/PackedEncode.sol";

/// @dev A TAKE module: hands `produce` of `token` (both in `data`) to `receiver`.
///      Decoupled from the gated amount so a test can drive exact / surplus /
///      shortfall proceeds.
contract StashTaker is ITakerModule {
    address public immutable permit3;

    constructor(address _permit3) {
        permit3 = _permit3;
    }

    function takeOnBehalf(address, uint256, address receiver, bytes calldata data) external override {
        require(msg.sender == permit3, "only permit3");
        (address token, uint256 produce) = abi.decode(data, (address, uint256));
        MockERC20(token).transfer(receiver, produce);
    }
}

/// @dev A solver callback that tries, mid-fill, to move a token balance OUT of
///      Settlement — the "intermediate funds" attack. It runs through
///      {SolverCallbackExecutor}, which is an approved spender for nobody, so its
///      only levers are a `transferFrom` (no allowance) and a `transfer` (not its
///      tokens). Both must fail or move nothing.
contract GrabbyCallback {
    address public immutable settlement;
    address public immutable attacker;

    constructor(address _settlement, address _attacker) {
        settlement = _settlement;
        attacker = _attacker;
    }

    /// Try to pull Settlement's balance to the attacker.
    function grabViaTransferFrom(address token, uint256 amount) external {
        MockERC20(token).transferFrom(settlement, attacker, amount);
    }

    /// Donate into Settlement mid-fill, hoping the payout counts it as proceeds.
    function donate(address token, uint256 amount) external {
        MockERC20(token).transfer(settlement, amount);
    }
}

/// @title SolverValueExtractionTest
/// @notice ADVERSARIAL: every way a filler might funnel value out of a settlement
///         that is not its own — a wrong receiver, an intermediate balance, an
///         injected order, a redirected sweep.
///
///  CLASS [C15] of `docs/reference-audits.md` — *the settler's balance treated as a
///  shared pot* — with [C1] (the arbitrary call) and [F7] (`matchSettle` paid a
///  self-addressed output leg to the solver) as its two live instances here.
///
///  ══ THE MODEL THIS FILE TESTS ══
///
///  Every token movement in a fill has a DESTINATION and an AMOUNT, and the safety
///  argument is that a filler never controls both halves for money that is not its
///  own. Enumerated:
///
///    destination            chosen by            amount bounded by
///    ───────────────────────────────────────────────────────────────────────────
///    output leg recipient   MAKER (typehash)     the signed leg price
///    item recipient         MAKER (typehash)     the signed item slice
///    `payTo` (`fillUpTo`)   FILLER               `owed` — the filler's own price
///    `profitRecipient`      FILLER               `balanceOf − beforeBal`
///    PRESEND → msg.sender   FILLER               unencumbered surplus only
///    callback target/data   FILLER               nothing: the executor holds no
///                                                allowance and is nobody's spender
///
///  So the filler-chosen destinations (`payTo`, `profitRecipient`, PRESEND) are
///  DESTINATIONS ONLY: they route money the filler had already earned and could
///  have forwarded itself. The maker-chosen ones are in the EIP-712 typehash, so
///  changing one invalidates the signature. The tests below attack each row.
///
///  ⚠ THE MEASUREMENT RULE that makes all of it hold: every amount a filler can
///  receive is a *measured delta* over a snapshot taken inside this settlement —
///  `balanceOf − before`, never a raw `balanceOf`. That is what makes a
///  pre-existing or donated Settlement balance unreachable, and it is the single
///  property most worth protecting here. `SolverCallback.t.sol` covers the
///  callback's *authority*; this file covers the *accounting*.
contract SolverValueExtractionTest is MockSettlementBase {
    uint256 constant IN_AMT = 1_000e18;
    uint256 constant OUT_AMT = 2_000e18;

    address attacker = address(0xA77ACC);
    uint256 bobPk = 0xB0B;
    address bob = vm.addr(bobPk);

    StashTaker taker;

    function setUp() public override {
        super.setUp();
        vm.label(attacker, "attacker");
        vm.label(bob, "bob");
        taker = new StashTaker(address(permit3));
        vm.label(address(taker), "stashTaker");
    }

    function _fund() internal {
        tA.mint(maker, IN_AMT * 4);
        _makerApprove(address(settlement), address(tA), IN_AMT * 4);
        tB.mint(solver, OUT_AMT * 4);
        _solverApprove(address(settlement), address(tB), OUT_AMT * 4);
    }

    function _order(uint256 nonce) internal view returns (Order memory) {
        return _plainOrder(nonce, address(tA), address(tB), IN_AMT, OUT_AMT);
    }

    // ════════════════ A · Injecting a receiver ════════════════

    /// @dev `fillUpTo`'s `recipient` is the one destination a filler names on the
    ///      single-order path. It must route the FILLER'S OWN input proceeds and
    ///      nothing else — in particular it must not touch the maker's output leg,
    ///      which is the money an attacker would actually want.
    function test_recipient_cannotCaptureTheMakersOutput() public {
        _fund();
        Order memory o = _order(1);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        settlement.fillUpTo(o, sig, IN_AMT, attacker, 0, "");

        assertEq(tA.balanceOf(attacker), IN_AMT, "the filler routed its OWN proceeds, which it may");
        assertEq(tB.balanceOf(maker), OUT_AMT, "the maker's output went to the maker regardless");
        assertEq(tB.balanceOf(attacker), 0, "and none of it was reachable");
    }

    /// @dev The maker's receiver lives in the EIP-712 typehash, so "inject a
    ///      different receiver" is not an accounting question at all — it is a
    ///      forgery question, and the signature answers it. Asserted on a FEE leg,
    ///      because that is the leg whose recipient is not the maker and therefore
    ///      the one that looks re-pointable.
    function test_repointingAFeeRecipient_breaksTheSignature() public {
        _fund();
        address originator = address(0xFEE);
        Order memory o = _order(2);
        LegOut[] memory legs = new LegOut[](2);
        legs[0] = LegOut({token: address(tB), start: OUT_AMT, end: 0, recipient: address(0)});
        legs[1] = LegOut({token: address(tB), start: 10e18, end: 0, recipient: originator});
        o.legsOut = PackedEncode.legsOut(legs);
        bytes memory sig = _sign(o);

        // The filler re-points the fee leg at itself and presents the same signature.
        // Built from scratch rather than `Order memory tampered = o` — a memory
        // struct assignment in Solidity is a REFERENCE copy, so mutating the copy
        // would silently corrupt the original and the honest fill below would be
        // testing the tampered order.
        Order memory tampered = _order(2);
        LegOut[] memory bad = new LegOut[](2);
        bad[0] = LegOut({token: address(tB), start: OUT_AMT, end: 0, recipient: address(0)});
        bad[1] = LegOut({token: address(tB), start: 10e18, end: 0, recipient: attacker});
        tampered.legsOut = PackedEncode.legsOut(bad);

        vm.prank(solver);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        settlement.fill(tampered, sig, IN_AMT);

        // Untampered, the originator is paid — so the leg really was live.
        vm.prank(solver);
        settlement.fill(o, sig, IN_AMT);
        assertEq(tB.balanceOf(originator), 10e18, "the signed recipient was paid");
        assertEq(tB.balanceOf(attacker), 0, "the injected one never was");
    }

    /// @dev `takerData` is the only wholly filler-controlled blob that reaches deep
    ///      into a fill (validators, invariants, fill module, price module). It must
    ///      reach NO destination decision. Pinned by handing it a well-formed
    ///      attacker address and showing every balance is byte-identical to a fill
    ///      with an empty blob.
    function test_takerData_reachesNoDestination() public {
        _fund();
        Order memory a = _order(3);
        Order memory b = _order(4);
        bytes memory sigA = _sign(a);
        bytes memory sigB = _sign(b);

        vm.prank(solver);
        settlement.fill(a, sigA, IN_AMT, "");
        (uint256 mOut, uint256 sIn) = (tB.balanceOf(maker), tA.balanceOf(solver));

        vm.prank(solver);
        settlement.fill(b, sigB, IN_AMT, abi.encode(attacker, IN_AMT, address(tA)));

        assertEq(tB.balanceOf(maker) - mOut, OUT_AMT, "same output to the same maker");
        assertEq(tA.balanceOf(solver) - sIn, IN_AMT, "same input to the same filler");
        assertEq(tA.balanceOf(attacker) + tB.balanceOf(attacker), 0, "the blob addressed nobody");
    }

    /// @dev Naming Settlement itself is the filler's own funeral, not an exploit,
    ///      and the property worth pinning is that the money is then UNRECOVERABLE.
    ///      Every payout in the settler is `balanceOf − before`, so value parked in
    ///      Settlement raises the floor for every future settlement and can never be
    ///      swept out by a later filler. A "donation" is therefore permanent — which
    ///      is exactly why donations cannot be harvested.
    function test_recipientIsSettlement_strandsTheFillersOwnProceeds() public {
        _fund();
        Order memory o = _order(5);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        settlement.fillUpTo(o, sig, IN_AMT, address(settlement), 0, "");
        assertEq(tA.balanceOf(address(settlement)), IN_AMT, "the filler paid itself into the settler");
        assertEq(tB.balanceOf(maker), OUT_AMT, "the maker was unaffected either way");

        // A later, ordinary fill hands out its own amounts and not one wei more.
        Order memory o2 = _order(6);
        bytes memory sig2 = _sign(o2);
        vm.prank(solver);
        settlement.fill(o2, sig2, IN_AMT);
        assertEq(tA.balanceOf(solver), IN_AMT, "the second fill paid its own input only");
        assertEq(tA.balanceOf(address(settlement)), IN_AMT, "the stranded balance is still stranded");
    }

    // ════════════════ B · Pre-existing and intermediate balances ════════════════

    /// @dev Build an order funded by a TAKE item, so `_payInputsToSolver` runs its
    ///      MEASURED-proceeds branch (`balanceOf − tokenInBefore`) rather than the
    ///      trivial item-free one.
    function _itemOrder(uint256 nonce, uint256 produce) internal returns (Order memory o) {
        o = _order(nonce);
        bytes memory data = abi.encode(address(tA), produce);
        Item[] memory its = new Item[](1);
        its[0] = Item({op: ItemOp.TAKE, module: address(taker), amount: produce, recipient: address(0), data: data});
        o.items = PackedEncode.items(its);
        tA.mint(address(taker), produce);
        vm.prank(maker);
        permit3.approveTaker(
            address(settlement), address(taker), keccak256(data), uint160(produce), uint48(block.timestamp + 1 hours)
        );
    }

    /// @dev C15, on the single-order path. A balance sitting in Settlement before a
    ///      fill — donated, stranded by an earlier mistake, or airdropped — must not
    ///      be handed to the filler as if this fill had produced it. The snapshot in
    ///      `_settleForward` is what makes the payout use only THIS fill's proceeds.
    ///
    ///      Every other donation test in the suite is on the netted path; this one
    ///      is the single-order twin.
    function test_donatedBalance_isNotPaidOutAsProceeds() public {
        _fund();
        uint256 donation = 500e18;
        tA.mint(attacker, donation);
        vm.prank(attacker);
        tA.transfer(address(settlement), donation);

        // The item produces only half the input leg; the rest must come from the
        // MAKER, not from the donation sitting in the settler.
        Order memory o = _itemOrder(10, IN_AMT / 2);
        bytes memory sig = _sign(o);
        uint256 makerBefore = tA.balanceOf(maker);

        vm.prank(solver);
        settlement.fill(o, sig, IN_AMT);

        assertEq(tA.balanceOf(solver), IN_AMT, "the filler got exactly its signed input");
        assertEq(makerBefore - tA.balanceOf(maker), IN_AMT / 2, "and the maker funded the shortfall");
        assertEq(tA.balanceOf(address(settlement)), donation, "the donation is untouched");
    }

    /// @dev The same question asked of the OUTPUT side: a donated `tokenOut` balance
    ///      must not stand in for the delivery the filler owes. Delivery is a pull
    ///      from the filler, never a spend of Settlement's own balance, so a filler
    ///      with no inventory still cannot settle.
    function test_donatedOutputBalance_doesNotFundTheDelivery() public {
        tA.mint(maker, IN_AMT);
        _makerApprove(address(settlement), address(tA), IN_AMT);
        // The filler holds NOTHING; the settler holds more than enough.
        tB.mint(attacker, OUT_AMT * 2);
        vm.prank(attacker);
        tB.transfer(address(settlement), OUT_AMT * 2);

        Order memory o = _order(11);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert();
        settlement.fill(o, sig, IN_AMT);
        assertEq(tB.balanceOf(address(settlement)), OUT_AMT * 2, "the settler's balance funded nothing");
    }

    /// @dev INTERMEDIATE FUNDS, the live window. A PreDelivery callback runs while
    ///      the settlement is mid-flight; the attacker's contract tries to pull
    ///      Settlement's balance out during it. It executes through
    ///      {SolverCallbackExecutor}, which is an approved spender for nobody and
    ///      holds no allowance of its own, so the `transferFrom` finds nothing.
    ///
    ///      This is the accounting twin of `SolverCallback.t.sol`'s
    ///      `test_fillWithCallback_cannotDrainViaPermit3`: that one proves the
    ///      callback cannot reach the ALLOWANCE HUB, this one that it cannot reach
    ///      the settler's own BALANCE.
    function test_callbackCannotLiftTheSettlersBalanceMidFill() public {
        _fund();
        uint256 parked = 750e18;
        tA.mint(address(settlement), parked);

        GrabbyCallback grabber = new GrabbyCallback(address(settlement), attacker);
        Order memory o = _order(12);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert();
        settlement.fillWithCallback(
            o,
            sig,
            IN_AMT,
            address(grabber),
            abi.encodeCall(GrabbyCallback.grabViaTransferFrom, (address(tA), parked)),
            CallbackMode.PreDelivery
        );
        assertEq(tA.balanceOf(attacker), 0, "nothing was lifted");
        assertEq(tA.balanceOf(address(settlement)), parked, "the parked balance is intact");
    }

    /// @dev The mirror-image attempt: instead of taking from the settler, PUSH into
    ///      it mid-callback and hope the payout counts the donation as this fill's
    ///      TAKE proceeds — which would let a filler pay the maker's side with its
    ///      own money and get it straight back while the maker keeps their input.
    ///
    ///      It does not, because the input snapshot is taken AFTER the callback
    ///      returns. The donation lands below the snapshot floor, counts as nothing,
    ///      and is stranded. Order-of-operations, not a check — which is exactly the
    ///      kind of property that needs a test rather than a comment.
    function test_callbackDonationIsNotCountedAsThisFillsProceeds() public {
        _fund();
        Order memory o = _itemOrder(13, IN_AMT / 2);
        bytes memory sig = _sign(o);

        GrabbyCallback donor = new GrabbyCallback(address(settlement), attacker);
        uint256 donation = IN_AMT / 2;
        tA.mint(address(donor), donation);
        uint256 makerBefore = tA.balanceOf(maker);

        vm.prank(solver);
        settlement.fillWithCallback(
            o,
            sig,
            IN_AMT,
            address(donor),
            abi.encodeCall(GrabbyCallback.donate, (address(tA), donation)),
            CallbackMode.PreDelivery
        );

        assertEq(tA.balanceOf(solver), IN_AMT, "the filler received its signed input and no more");
        assertEq(makerBefore - tA.balanceOf(maker), IN_AMT / 2, "the maker still funded the whole shortfall");
        assertEq(tA.balanceOf(address(settlement)), donation, "the mid-fill donation is stranded, not recycled");
    }

    // ════════════════ C · The netted path ════════════════

    function _approveFrom(address who, address token, uint256 cap) internal {
        vm.startPrank(who);
        tA.approve(address(permit3), type(uint256).max);
        tB.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), token, uint160(cap), 0);
        vm.stopPrank();
    }

    function _step(uint256 kind, uint256 a, uint256 b) internal pure returns (uint256) {
        return kind | (a << 8) | (b << 24);
    }

    /// @dev Alice sells IN_AMT tA for OUT_AMT tB; Bob mirrors her exactly.
    function _mirrorPlan(address profitRecipient) internal view returns (MatchPlan memory) {
        Order memory a = _plainOrder(20, address(tA), address(tB), IN_AMT, OUT_AMT);
        Order memory b = _plainOrder(21, address(tB), address(tA), OUT_AMT, IN_AMT);
        b.maker = bob;

        Order[] memory orders = new Order[](2);
        (orders[0], orders[1]) = (a, b);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signWith(a, makerPk);
        sigs[1] = _signWith(b, bobPk);
        uint256[] memory fills = new uint256[](2);
        (fills[0], fills[1]) = (IN_AMT, OUT_AMT);
        uint256[] memory s = new uint256[](4);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 1, 0);
        s[2] = _step(MatchStep.DELIVER, 0, 0);
        s[3] = _step(MatchStep.DELIVER, 1, 0);
        return MatchPlan({
            orders: orders,
            sigs: sigs,
            fillAmounts: fills,
            takerDatas: new bytes[](0),
            schedule: s,
            callTargets: new address[](0),
            callDatas: new bytes[](0),
            profitRecipient: profitRecipient
        });
    }

    function _stageMirror() internal {
        tA.mint(maker, IN_AMT);
        tB.mint(bob, OUT_AMT);
        _approveFrom(maker, address(tA), IN_AMT);
        _approveFrom(bob, address(tB), OUT_AMT);
    }

    /// @dev `profitRecipient` is the netted path's `payTo`, and the donation test
    ///      that exists uses the DEFAULT recipient. Naming a third party must not
    ///      widen what the sweep can reach: it is still `balanceOf − beforeBal`, so a
    ///      balance that predates the plan is invisible to it.
    function test_profitRecipient_cannotReachAPreExistingBalance() public {
        _stageMirror();
        uint256 parked = 900e18;
        tA.mint(address(settlement), parked);
        tB.mint(address(settlement), parked);

        MatchPlan memory p = _mirrorPlan(attacker);
        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(tA.balanceOf(attacker), 0, "no surplus on a balanced plan, named recipient or not");
        assertEq(tB.balanceOf(attacker), 0, "and none on the other side either");
        assertEq(tA.balanceOf(address(settlement)), parked, "the pre-existing balance is untouched");
        assertEq(tB.balanceOf(address(settlement)), parked, "both sides of it");
        assertEq(tB.balanceOf(maker), OUT_AMT, "alice paid");
        assertEq(tA.balanceOf(bob), IN_AMT, "bob paid");
    }

    /// @dev THE INJECTED-ORDER ATTACK. A filler may put any signed order in a plan,
    ///      including one it signed itself. The tempting shape is an order that gives
    ///      a dust input and takes a large output, funded by the OTHER makers'
    ///      pooled inputs — a self-addressed drain that never appears as a "surplus"
    ///      and so never meets the sweep's `balanceOf − before` bound.
    ///
    ///      It fails on funding: every order's delivery is asserted to have happened
    ///      ({PlanIncomplete}) and the pool must end no worse off ({BatchNotWhole}),
    ///      so taking Alice's tA leaves her own counterparty unfunded and the whole
    ///      plan unwinds. The filler cannot spend what it did not put in.
    function test_injectedSelfOrder_cannotDrainThePooledInputs() public {
        _stageMirror();
        // The filler signs its own order: 1 wei of tB in, the whole pooled tA out.
        tB.mint(solver, 1);
        _approveFrom(solver, address(tB), 1);
        Order memory greedy = _plainOrder(22, address(tB), address(tA), 1, IN_AMT);
        greedy.maker = solver;

        MatchPlan memory p = _mirrorPlan(address(0));
        Order[] memory orders = new Order[](3);
        (orders[0], orders[1], orders[2]) = (p.orders[0], p.orders[1], greedy);
        bytes[] memory sigs = new bytes[](3);
        (sigs[0], sigs[1]) = (p.sigs[0], p.sigs[1]);
        sigs[2] = _signWith(greedy, solverPk);
        uint256[] memory fills = new uint256[](3);
        (fills[0], fills[1], fills[2]) = (IN_AMT, OUT_AMT, 1);
        uint256[] memory s = new uint256[](6);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 1, 0);
        s[2] = _step(MatchStep.PULL, 2, 0);
        s[3] = _step(MatchStep.DELIVER, 2, 0); // pay the filler FIRST, out of the pool
        s[4] = _step(MatchStep.DELIVER, 0, 0);
        s[5] = _step(MatchStep.DELIVER, 1, 0);

        MatchPlan memory greedyPlan = MatchPlan({
            orders: orders,
            sigs: sigs,
            fillAmounts: fills,
            takerDatas: new bytes[](0),
            schedule: s,
            callTargets: new address[](0),
            callDatas: new bytes[](0),
            profitRecipient: address(0)
        });

        vm.prank(solver);
        vm.expectRevert();
        settlement.matchSettle(greedyPlan);

        assertEq(tA.balanceOf(maker), IN_AMT, "alice's input never left");
        assertEq(tB.balanceOf(bob), OUT_AMT, "bob's never did either");
        assertEq(tA.balanceOf(solver), 0, "and the filler took nothing");
    }

    /// @dev The honest version of the same idea, to prove the refusal above is about
    ///      FUNDING rather than about self-dealing: a filler-signed order that pays
    ///      its own way settles, and nets the filler exactly the spread it actually
    ///      funded — no access to the other makers' principal.
    function test_injectedSelfOrder_thatPaysItsOwnWay_isFine() public {
        _stageMirror();
        tB.mint(solver, OUT_AMT);
        _approveFrom(solver, address(tB), OUT_AMT);
        // The filler buys IN_AMT of tA for OUT_AMT of tB — its own money, in and out.
        Order memory fair = _plainOrder(23, address(tB), address(tA), OUT_AMT, IN_AMT);
        fair.maker = solver;

        // Alice sells tA for tB; the filler's order is her counterparty. Bob is not
        // needed, so this is a clean two-order plan.
        Order memory alice = _plainOrder(20, address(tA), address(tB), IN_AMT, OUT_AMT);
        Order[] memory orders = new Order[](2);
        (orders[0], orders[1]) = (alice, fair);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signWith(alice, makerPk);
        sigs[1] = _signWith(fair, solverPk);
        uint256[] memory fills = new uint256[](2);
        (fills[0], fills[1]) = (IN_AMT, OUT_AMT);
        uint256[] memory s = new uint256[](4);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 1, 0);
        s[2] = _step(MatchStep.DELIVER, 0, 0);
        s[3] = _step(MatchStep.DELIVER, 1, 0);

        vm.prank(solver);
        settlement.matchSettle(
            MatchPlan({
                orders: orders,
                sigs: sigs,
                fillAmounts: fills,
                takerDatas: new bytes[](0),
                schedule: s,
                callTargets: new address[](0),
                callDatas: new bytes[](0),
                profitRecipient: address(0)
            })
        );

        assertEq(tB.balanceOf(maker), OUT_AMT, "alice received her signed output");
        assertEq(tA.balanceOf(solver), IN_AMT, "the filler received what it paid for");
        assertEq(tB.balanceOf(solver), 0, "having paid for it in full");
    }
}
