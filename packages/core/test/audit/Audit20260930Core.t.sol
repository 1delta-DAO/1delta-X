// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "../shared/PackedEncode.sol";
import {MockSettlementBase, MockERC20} from "../shared/MockSettlementBase.t.sol";
import {FixedBumpModule} from "../shared/MockModules.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IFillModule} from "@core/interfaces/IFillModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {Order, Item, ItemOp, LegIn, LegOut, CallbackMode} from "@core/settlement/Settlement.sol";
import {OrderGates} from "@core/settlement/OrderGates.sol";
import {OrderState} from "@core/settlement/OrderState.sol";
import {Proportional} from "@core/settlement/Proportional.sol";
import {OrderHash} from "@core/settlement/OrderHash.sol";

// ──────────────────── The 2026-09-30 entry shapes ────────────────────
//
// Reached through an interface rather than the typed `Settlement` member so this file
// also COMPILES against the pre-fix tree (where these selectors do not exist) — the
// "fails before" run of the remediation policy executes these exact tests there.
interface IFlooredEntries {
    function fillWithPermit(
        Order calldata order,
        IPermit3.PermitBatch calldata batch,
        bytes calldata sig,
        uint256 fillAmount,
        uint256 minBumpBps,
        bytes calldata takerData
    ) external returns (uint256[] memory);

    function fillWithPermitTake(
        Order calldata order,
        IPermit3.PermitTake calldata permit,
        bytes calldata sig,
        uint256 fillAmount,
        uint256 minBumpBps
    ) external returns (uint256[] memory);

    function batchFill(
        Order[] calldata orders,
        bytes[] calldata sigs,
        uint256[] calldata fillAmounts,
        bool revertIfIncomplete,
        uint256[] calldata minBumpBps,
        bytes[] calldata takerDatas
    ) external returns (uint256[][] memory, bool[] memory);
}

/// @dev A maker-deployed fill module that IGNORES the filler's proposal and takes
///      the whole remainder — the CORE-FILLER-2 attacker.
contract AuditGreedyFillModule is IFillModule {
    function resolveFill(Order calldata order, uint256 prevFilled, uint256, bytes calldata)
        external
        pure
        returns (uint256)
    {
        return order.fillTotal - prevFilled;
    }
}

/// @dev A module that gives `type(uint256).max` no meaning of its own — it refuses it,
///      so a test can tell whether the core normalised the sentinel before the call.
contract AuditNoSentinelFillModule is IFillModule {
    error SawSentinel();

    function resolveFill(Order calldata order, uint256 prevFilled, uint256 fillAmount, bytes calldata)
        external
        pure
        returns (uint256)
    {
        if (fillAmount == type(uint256).max) revert SawSentinel();
        uint256 rem = order.fillTotal - prevFilled;
        return fillAmount < rem ? fillAmount : rem;
    }
}

/// @dev TAKE mock: on dispatch sends `produce` of `token` from its stash to `receiver`.
contract AuditFundingTaker is ITakerModule {
    address public immutable permit3;

    constructor(address p3) {
        permit3 = p3;
    }

    function takeOnBehalf(address, uint256, address receiver, bytes calldata data) external override {
        require(msg.sender == permit3, "only permit3");
        (address token, uint256 produce) = abi.decode(data, (address, uint256));
        MockERC20(token).transfer(receiver, produce);
    }
}

/// @dev MAKE mock: pulls `amount` of `token` from the maker through its Permit3 grant
///      and sends it to an attacker-chosen `sink` — what a victim-approved bridge-out
///      module looks like to a forged order.
contract AuditDrainingMaker is IMakerModule {
    IPermit3 public immutable permit3;
    address public immutable settlement;

    constructor(address p3, address s) {
        permit3 = IPermit3(p3);
        settlement = s;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        require(msg.sender == settlement, "only settlement");
        (address token, address sink) = abi.decode(data, (address, address));
        permit3.transferFrom(onBehalfOf, sink, token, uint160(amount));
    }
}

/// @title Audit20260930CoreTest
/// @notice Regression tests for the A-core group of the 2026-09-30 whole-tree audit.
///         Each `test_audit_<ID>_*` asserts the SAFE end state of one finding and was
///         run against the pre-fix sources to confirm it failed there.
contract Audit20260930CoreTest is MockSettlementBase {
    uint256 constant IN_ = 1_000e18;
    uint256 constant OUT_ = 2e18;

    bytes4 constant BUMP_TOO_LOW = bytes4(keccak256("BumpTooLow()"));
    bytes4 constant OUTPUT_TO_SETTLEMENT = bytes4(keccak256("OutputToSettlement()"));
    bytes4 constant PERMIT_TAKE_NOT_CONSUMED = bytes4(keccak256("PermitTakeNotConsumed()"));

    IFlooredEntries floored;

    function setUp() public override {
        super.setUp();
        floored = IFlooredEntries(address(settlement));
    }

    function _fund(uint256 makerIn, uint256 solverOut) internal {
        tA.mint(maker, makerIn);
        tB.mint(solver, solverOut);
        _makerApprove(address(settlement), address(tA), makerIn);
        _solverApprove(address(settlement), address(tB), solverOut);
    }

    /// @dev A price-module order whose output decays OUT_ → OUT_/2 and whose module
    ///      pins bump 4000: the filler's floor must be read against that pin.
    function _moduleOrder(uint256 nonce) internal returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), IN_, OUT_);
        o.legsOut = PackedEncode.setLegOutEnd(o.legsOut, 0, OUT_ / 2);
        o.pricingModule = address(new FixedBumpModule(4_000));
    }

    // ════════════════ PERIPH-1.v3 — a price floor on every permit / batch entry ════════════════

    function _permitFor(Order memory o, uint256 nonce, uint256 deadline)
        internal
        view
        returns (IPermit3.PermitBatch memory batch, bytes memory sig)
    {
        batch = _buildBatch(_tokenPermit1(address(settlement), address(tA), IN_, 0), nonce, deadline);
        sig = _signPermitWitness(batch, _hashOrder(o));
    }

    /// @dev A PermitBatchWitness order's FIRST fill can only go through
    ///      `fillWithPermit`; it now carries the same floor `fillUpTo` does.
    function test_audit_PERIPH_1_v3_fillWithPermit_honoursFloor() public {
        tA.mint(maker, IN_);
        vm.prank(maker);
        tA.approve(address(permit3), type(uint256).max);
        tB.mint(solver, OUT_);
        _solverApprove(address(settlement), address(tB), OUT_);

        Order memory o = _moduleOrder(1);
        (IPermit3.PermitBatch memory batch, bytes memory sig) = _permitFor(o, 11, block.timestamp + 1 hours);

        vm.prank(solver);
        vm.expectRevert(BUMP_TOO_LOW);
        floored.fillWithPermit(o, batch, sig, IN_, 4_001, "");

        vm.prank(solver);
        floored.fillWithPermit(o, batch, sig, IN_, 4_000, "");
        assertEq(tA.balanceOf(solver), IN_, "filled at a bump meeting the floor");
    }

    /// @dev `fillWithPermitTake` is the only entry that funds a PermitTake order's
    ///      TAKE; the floor is checked right after the bump resolves, before any item.
    function test_audit_PERIPH_1_v3_fillWithPermitTake_honoursFloor() public {
        tB.mint(solver, OUT_);
        _solverApprove(address(settlement), address(tB), OUT_);
        Order memory o = _moduleOrder(2);
        IPermit3.PermitTake memory junk;

        vm.prank(solver);
        vm.expectRevert(BUMP_TOO_LOW);
        floored.fillWithPermitTake(o, junk, "", IN_, 4_001);

        // A floor the pinned bump meets passes the gate and the fill proceeds — to the
        // missing-TAKE guard, since this order has none: proof the floor let it through.
        vm.prank(solver);
        vm.expectRevert(PERMIT_TAKE_NOT_CONSUMED);
        floored.fillWithPermitTake(o, junk, "", IN_, 4_000);
    }

    /// @dev batchFill carries a per-order floor; a floor miss is a skipped order.
    function test_audit_PERIPH_1_v3_batchFill_perOrderFloor() public {
        _fund(IN_ * 2, OUT_ * 2);
        Order[] memory orders = new Order[](2);
        orders[0] = _moduleOrder(3);
        orders[1] = _moduleOrder(4);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(orders[0]);
        sigs[1] = _sign(orders[1]);
        uint256[] memory amts = new uint256[](2);
        amts[0] = IN_;
        amts[1] = IN_;
        uint256[] memory floors = new uint256[](2);
        floors[0] = 4_001; // above the pinned 4000 — must be skipped
        floors[1] = 4_000;

        vm.prank(solver);
        (, bool[] memory ok) = floored.batchFill(orders, sigs, amts, false, floors, new bytes[](2));
        assertFalse(ok[0], "the floored-out order was skipped");
        assertTrue(ok[1], "the order meeting its floor filled");
        assertEq(settlement.filled(_hashOrder(orders[0])), 0, "nothing of the skipped order moved");

        // and `revertIfIncomplete` turns the floor miss into a batch revert
        Order[] memory one = new Order[](1);
        one[0] = _moduleOrder(5);
        bytes[] memory s1 = new bytes[](1);
        s1[0] = _sign(one[0]);
        uint256[] memory a1 = new uint256[](1);
        a1[0] = IN_;
        uint256[] memory f1 = new uint256[](1);
        f1[0] = 4_001;
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSignature("BatchFillIncomplete(uint256)", 0));
        floored.batchFill(one, s1, a1, true, f1, new bytes[](1));
    }

    // ════════════════ CORE-FILLER-2 — the filler's size is a ceiling on any module ════════════════

    function test_audit_CORE_FILLER_2_moduleCannotUpsizeFillersRequest() public {
        _fund(IN_, OUT_);
        Order memory o = _plainOrder(20, address(tA), address(tB), IN_, OUT_);
        o.fillModule = address(new AuditGreedyFillModule());
        o.fillTotal = IN_;
        bytes memory sig = _sign(o);

        // The filler asked for 1%; the maker's module answers "all of it".
        vm.prank(solver);
        vm.expectRevert(OrderState.OverFill.selector);
        settlement.fill(o, sig, IN_ / 100);
        assertEq(tB.balanceOf(solver), OUT_, "the filler's approval was not drawn");

        // A filler that wants whatever the module decides says so with the sentinel.
        vm.prank(solver);
        settlement.fill(o, sig, type(uint256).max);
        assertEq(tB.balanceOf(maker), OUT_, "the explicit opt-in fills the whole order");
    }

    // ════════════════ CORE-FILL-4 — one meaning of the sentinel on every entry ════════════════

    function test_audit_CORE_FILL_4_plainFill_sentinelFillsRemainder() public {
        _fund(IN_, OUT_);
        Order memory o = _plainOrder(30, address(tA), address(tB), IN_, OUT_);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        settlement.fill(o, sig, IN_ / 4);

        // Used to die on a raw Panic(0x11) at `prevFilled + max`.
        vm.prank(solver);
        settlement.fill(o, sig, type(uint256).max);
        assertEq(settlement.filled(_hashOrder(o)), IN_, "the remainder filled");
        assertEq(tA.balanceOf(solver), IN_, "solver received the full input");
    }

    function test_audit_CORE_FILL_4_moduleNeverSeesMax_onFillOrFillUpTo() public {
        _fund(IN_ * 2, OUT_ * 2);
        AuditNoSentinelFillModule mod = new AuditNoSentinelFillModule();

        Order memory o = _plainOrder(31, address(tA), address(tB), IN_, OUT_);
        o.fillModule = address(mod);
        o.fillTotal = IN_;
        bytes memory sig_o = _sign(o);
        vm.prank(solver);
        settlement.fill(o, sig_o, type(uint256).max);
        assertEq(settlement.filled(_hashOrder(o)), IN_, "fill: module got the remainder, not max");

        Order memory u = _plainOrder(32, address(tA), address(tB), IN_, OUT_);
        u.fillModule = address(mod);
        u.fillTotal = IN_;
        bytes memory sig_u = _sign(u);
        vm.prank(solver);
        (uint256 delta,,) = settlement.fillUpTo(u, sig_u, type(uint256).max, address(0), 0, "");
        assertEq(delta, IN_, "fillUpTo: module got the remainder, not max");
    }

    // ════════════════ CORE-FILL-1 — the carrier test is amount-aware ════════════════

    address constant EXCLUSIVE = address(0xE1);

    function _softWindow(Order memory o) internal view {
        o.exclusiveFiller = EXCLUSIVE;
        _setExclusivityEnd(o, block.timestamp + 1 hours);
        o.params = (o.params & ~uint256(0xffff)) | 500; // 5% soft premium
    }

    /// @dev A BUY whose only input leg is a zero placeholder has nothing to charge the
    ///      premium on — a soft window there is a hard one.
    function test_audit_CORE_FILL_1_buyZeroPlaceholderInput_isHardWindow() public {
        tB.mint(solver, OUT_);
        _solverApprove(address(settlement), address(tB), OUT_);
        Order memory o = _buyOrder(40, address(0), address(tB), 0, 0, OUT_);
        _softWindow(o);
        bytes memory sig = _sign(o);

        vm.prank(solver); // an outsider, inside the window
        vm.expectRevert(OrderGates.NotExclusiveFiller.selector);
        settlement.fill(o, sig, OUT_);
        assertEq(tB.balanceOf(maker), 0, "outsider was not admitted at the exclusive price");
    }

    /// @dev The SELL mirror: a maker-addressed output of `start == 0` prices to 0.
    function test_audit_CORE_FILL_1_sellZeroMakerOutput_isHardWindow() public {
        tA.mint(maker, IN_);
        _makerApprove(address(settlement), address(tA), IN_);
        Order memory o = _plainOrder(41, address(tA), address(tB), IN_, 0);
        _softWindow(o);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert(OrderGates.NotExclusiveFiller.selector);
        settlement.fill(o, sig, IN_);
        assertEq(tA.balanceOf(maker), IN_, "maker untouched");
    }

    /// @dev Control: a real (non-zero) maker output still carries the premium.
    function test_audit_CORE_FILL_1_nonZeroCarrier_stillSoft() public {
        _fund(IN_, OUT_ * 2);
        Order memory o = _plainOrder(42, address(tA), address(tB), IN_, OUT_);
        _softWindow(o);
        bytes memory sig_o = _sign(o);
        vm.prank(solver);
        settlement.fill(o, sig_o, IN_);
        assertEq(tB.balanceOf(maker), OUT_ + (OUT_ * 500) / 10_000, "outsider paid the premium");
    }

    // ════════════════ CORE-MATCH-4 — no TAKE proceeds to the EXECUTOR ════════════════

    function test_audit_CORE_MATCH_4_takeRecipientExecutor_refused() public {
        AuditFundingTaker taker = new AuditFundingTaker(address(permit3));
        tA.mint(address(taker), IN_);
        tA.mint(maker, IN_);
        _makerApprove(address(settlement), address(tA), IN_);
        tB.mint(solver, OUT_);
        _solverApprove(address(settlement), address(tB), OUT_);

        bytes memory data = abi.encode(address(tA), IN_);
        vm.prank(maker);
        permit3.approveTaker(address(settlement), address(taker), keccak256(data), uint160(IN_), 0);

        Order memory o = _plainOrder(50, address(tA), address(tB), IN_, OUT_);
        Item[] memory its = new Item[](1);
        its[0] = Item({
            op: ItemOp.TAKE, module: address(taker), amount: IN_, recipient: address(settlement.EXECUTOR()), data: data
        });
        o.items = PackedEncode.items(its);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert(OUTPUT_TO_SETTLEMENT);
        settlement.fill(o, sig, IN_);
        assertEq(tA.balanceOf(address(settlement.EXECUTOR())), 0, "nothing landed on the executor");
        assertEq(tA.balanceOf(maker), IN_, "the maker did not pay the input from its wallet");
    }

    // ════════════════ X-DIFF-CORE-3 — a direct shortening retires outstanding permits ════════════════

    function _signerPermit(address signer, uint256 expiry, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                settlement.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256(
                            "OrderSignerPermit(address maker,address signer,uint256 expiry,uint256 nonce,uint256 deadline)"
                        ),
                        maker,
                        signer,
                        expiry,
                        nonce,
                        deadline
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_audit_X_DIFF_CORE_3_staleLongerPermit_cannotUndoShortening() public {
        address d = address(0xD1);
        uint256 n = uint256(uint160(d)) << 8;
        uint256 longExpiry = block.timestamp + 365 days;
        uint256 deadline = block.timestamp + 30 days;
        // The maker signs a gasless year-long nomination nobody relays yet…
        bytes memory p = _signerPermit(d, longExpiry, n, deadline);

        // …then nominates directly and winds the delegate down to one hour.
        vm.startPrank(maker);
        settlement.setOrderSigner(d, longExpiry);
        settlement.setOrderSigner(d, block.timestamp + 1 hours);
        vm.stopPrank();

        // The stale permit must not restore the year.
        vm.expectRevert(OrderState.NonceCancelled.selector);
        settlement.setOrderSignerWithSig(maker, d, longExpiry, n, deadline, p);
        assertEq(settlement.orderSignerExpiry(maker, d), block.timestamp + 1 hours, "the wind-down held");
    }

    /// @dev Control: an EXTENSION burns nothing, so a later gasless extension still works.
    function test_audit_X_DIFF_CORE_3_extensionKeepsGaslessRenewal() public {
        address d = address(0xD2);
        uint256 n = uint256(uint160(d)) << 8;
        vm.startPrank(maker);
        settlement.setOrderSigner(d, block.timestamp + 1 days);
        settlement.setOrderSigner(d, block.timestamp + 2 days);
        vm.stopPrank();
        bytes memory p = _signerPermit(d, block.timestamp + 30 days, n, block.timestamp + 1 hours);
        settlement.setOrderSignerWithSig(maker, d, block.timestamp + 30 days, n, block.timestamp + 1 hours, p);
        assertEq(settlement.orderSignerExpiry(maker, d), block.timestamp + 30 days, "relayed extension applied");
    }

    // ════════════════ P3-4 — the permit deadline binds the application, not the no-op ════════════════

    function test_audit_P3_4_hub_spentNoncePastDeadline_isNoOp() public {
        tA.mint(maker, IN_);
        IPermit3.PermitBatch memory batch =
            _buildBatch(_tokenPermit1(address(settlement), address(tA), IN_, 0), 21, block.timestamp + 1 hours);
        bytes32 orderHash = keccak256("any order");
        bytes memory sig = _signPermitWitness(batch, orderHash);
        bytes32 witness = _settlementWitness(orderHash);

        permit3.permitBatchWithWitnessHashIfNeeded(
            maker, batch, witness, OrderHash.PERMIT_BATCH_WITNESS_TYPEHASH, sig
        );
        vm.warp(block.timestamp + 2 hours);
        // Spent nonce + expired deadline: applies nothing, and no longer reverts.
        permit3.permitBatchWithWitnessHashIfNeeded(
            maker, batch, witness, OrderHash.PERMIT_BATCH_WITNESS_TYPEHASH, sig
        );

        // An expired permit whose nonce is still FRESH still writes nothing — it reverts.
        IPermit3.PermitBatch memory fresh =
            _buildBatch(_tokenPermit1(address(settlement), address(tA), IN_, 0), 22, block.timestamp - 1);
        bytes memory sig2 = _signPermitWitness(fresh, orderHash);
        vm.expectRevert(IPermit3.PermitExpired.selector);
        permit3.permitBatchWithWitnessHashIfNeeded(
            maker, fresh, witness, OrderHash.PERMIT_BATCH_WITNESS_TYPEHASH, sig2
        );
    }

    function test_audit_P3_4_fillWithPermit_continuesPastPermitDeadline() public {
        tA.mint(maker, IN_);
        vm.prank(maker);
        tA.approve(address(permit3), type(uint256).max);
        tB.mint(solver, OUT_);
        _solverApprove(address(settlement), address(tB), OUT_);

        Order memory o = _plainOrder(60, address(tA), address(tB), IN_, OUT_);
        _setExpiry(o, block.timestamp + 1 days);
        (IPermit3.PermitBatch memory batch, bytes memory sig) = _permitFor(o, 23, block.timestamp + 1 hours);

        vm.prank(solver);
        floored.fillWithPermit(o, batch, sig, IN_ / 2, 0, "");
        vm.warp(block.timestamp + 2 hours); // past the permit deadline, order still live

        vm.prank(solver);
        floored.fillWithPermit(o, batch, sig, IN_ / 2, 0, "");
        assertEq(settlement.filled(_hashOrder(o)), IN_, "the remainder filled through the same entry");
    }

    // ════════════════ X-DIFF-CORE-7 — the view refuses what the settler refuses ════════════════

    function test_audit_X_DIFF_CORE_7_currentAmountIn_refusesMarkerOffLeg0() public {
        tA.mint(maker, IN_);
        tC.mint(maker, IN_);
        Order memory o = _plainOrder(70, address(tA), address(tB), IN_, OUT_);
        LegIn[] memory legs = new LegIn[](2);
        legs[0] = LegIn({token: address(tA), start: IN_, end: 0});
        legs[1] = LegIn({token: address(tC), start: Proportional.encode(10_000), end: IN_});
        o.legsIn = PackedEncode.legsIn(legs);

        vm.expectRevert(Proportional.InvalidProportionalLeg.selector);
        lens.previewAmountIn(o);
    }

    // ════════════════ P3-2 — the live pull's branches, on a real fill ════════════════

    /// @dev A maker-signed leg of 2^160 used to be guarded only on the dead library
    ///      copy. On the live `_pullViaPermit3` it must refuse, not route around the book.
    function test_audit_P3_2_legAboveUint160_refusedOnFill() public {
        uint256 big = uint256(type(uint160).max) + 1;
        tA.mint(maker, big);
        vm.prank(maker);
        tA.approve(address(settlement), big); // a DIRECT approval that would fund it
        tB.mint(solver, OUT_);
        _solverApprove(address(settlement), address(tB), OUT_);

        Order memory o = _plainOrder(80, address(tA), address(tB), big, OUT_);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert(IPermit3.Permit3Denied.selector);
        settlement.fill(o, sig, big);
        assertEq(tA.balanceOf(maker), big, "nothing moved around the book");
    }

    /// @dev Per-token strict mode on the REAL hub and a REAL fill: the flagged token
    ///      refuses the direct-approval fallback; an unflagged one still uses it.
    function test_audit_P3_2_perTokenStrict_onRealFill() public {
        tA.mint(maker, IN_);
        tC.mint(maker, IN_);
        tB.mint(solver, OUT_ * 2);
        _solverApprove(address(settlement), address(tB), OUT_ * 2);
        vm.startPrank(maker);
        tA.approve(address(settlement), IN_); // direct approvals only — no Permit3 grant
        tC.approve(address(settlement), IN_);
        permit3.setStrictModeToken(address(tA), true);
        vm.stopPrank();

        Order memory oa = _plainOrder(81, address(tA), address(tB), IN_, OUT_);
        bytes memory sa = _sign(oa);
        vm.prank(solver);
        vm.expectRevert(IPermit3.Permit3Denied.selector);
        settlement.fill(oa, sa, IN_);

        Order memory oc = _plainOrder(82, address(tC), address(tB), IN_, OUT_);
        bytes memory sig_oc = _sign(oc);
        vm.prank(solver);
        settlement.fill(oc, sig_oc, IN_);
        assertEq(tC.balanceOf(solver), IN_, "the unflagged token still falls back");
    }

    // ════════════════ CORE-SIG-3 — items ahead of the permit TAKE are covered by atomicity ════════════════

    /// @dev A forged order (maker = victim) with a MAKE item ahead of the TAKE runs
    ///      that MAKE before any authorisation; the junk permit then fails and the
    ///      whole call unwinds. Pins that nothing the MAKE did survives.
    function test_audit_CORE_SIG_3_forgedMakeBeforeTake_unwindsCompletely() public {
        AuditDrainingMaker drain = new AuditDrainingMaker(address(permit3), address(settlement));
        AuditFundingTaker taker = new AuditFundingTaker(address(permit3));
        address sink = address(0xBAD);
        // Victim: a standing Permit3 grant to the module it uses.
        tA.mint(maker, IN_);
        _makerApprove(address(drain), address(tA), IN_);
        tA.mint(address(taker), IN_);

        Order memory o = _plainOrder(90, address(tA), address(tB), IN_, 0);
        Item[] memory its = new Item[](2);
        its[0] = Item({op: ItemOp.MAKE, module: address(drain), amount: IN_, recipient: address(0), data: abi.encode(address(tA), sink)});
        its[1] = Item({op: ItemOp.TAKE, module: address(taker), amount: IN_, recipient: address(0), data: abi.encode(address(tA), IN_)});
        o.items = PackedEncode.items(its);

        IPermit3.PermitTake memory junk = IPermit3.PermitTake({
            module: address(taker), ref: keccak256(its[1].data), amount: uint160(IN_), nonce: 1, deadline: block.timestamp + 1
        });
        (uint160 grantBefore,) = permit3.tokenAllowance(maker, address(drain), address(tA));

        vm.prank(address(0xA77AC));
        vm.expectRevert();
        floored.fillWithPermitTake(o, junk, new bytes(65), IN_, 0);

        assertEq(tA.balanceOf(maker), IN_, "victim balance untouched");
        assertEq(tA.balanceOf(sink), 0, "nothing reached the attacker");
        (uint160 grantAfter,) = permit3.tokenAllowance(maker, address(drain), address(tA));
        assertEq(grantAfter, grantBefore, "victim allowance untouched");
        assertEq(settlement.filled(_hashOrder(o)), 0, "no fill recorded");
    }

    // ════════════════ CORE-FILL-2 — the callback sentinel on more order shapes ════════════════

    function test_audit_CORE_FILL_2_callbackSentinel_partiallyFilledIdentity() public {
        _fund(IN_, OUT_ + 1); // two slices, each output rounded up
        Order memory o = _plainOrder(100, address(tA), address(tB), IN_, OUT_);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        settlement.fill(o, sig, IN_ / 3);
        vm.prank(solver);
        settlement.fillWithCallback(o, sig, type(uint256).max, address(0), "", CallbackMode.PreDelivery);
        assertEq(settlement.filled(_hashOrder(o)), IN_, "the exact remainder filled");
    }

    function test_audit_CORE_FILL_2_callbackSentinel_fillOnceOrder() public {
        _fund(IN_, OUT_);
        Order memory o = _plainOrder(101, address(tA), address(tB), IN_, OUT_);
        o.timing |= uint256(1) << 100; // fill-once (nonce as progress)
        bytes memory sig_o = _sign(o);
        vm.prank(solver);
        settlement.fillWithCallback(o, sig_o, type(uint256).max, address(0), "", CallbackMode.PreDelivery);
        assertEq(tB.balanceOf(maker), OUT_, "whole fill-once order settled");
    }

    function test_audit_CORE_FILL_2_callbackSentinel_fillModuleOrder() public {
        _fund(IN_, OUT_);
        Order memory o = _plainOrder(102, address(tA), address(tB), IN_, OUT_);
        o.fillModule = address(new AuditNoSentinelFillModule());
        o.fillTotal = IN_;
        bytes memory sig_o = _sign(o);
        vm.prank(solver);
        settlement.fillWithCallback(o, sig_o, type(uint256).max, address(0), "", CallbackMode.PreDelivery);
        assertEq(settlement.filled(_hashOrder(o)), IN_, "module got the remainder");
    }
}
