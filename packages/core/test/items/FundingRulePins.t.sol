// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerForModule} from "@core/interfaces/ITakerForModule.sol";
import {Order, Item, ItemOp, LegOut} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";

import {MockSettlementBase, MockERC20} from "../shared/MockSettlementBase.t.sol";
import {PackedEncode} from "../shared/PackedEncode.sol";

/// @dev PRE-FUNDED maker module. Supplies `amount` of the token its descriptor
///      names (bits [16:176) of word 0 — the same field the core binds against the
///      referenced leg) out of its OWN balance, and checks nothing else about it.
///      Deliberately trusting: the core's binding must be the only thing standing
///      between a mis-tokened descriptor and whatever residue a shared singleton
///      holds.
contract FundingPinPreFundMake is IMakerModule {
    address public immutable settlement;
    uint256 public calls;
    uint256 public totalFunded;

    constructor(address settlement_) {
        settlement = settlement_;
    }

    function makeOnBehalf(address, uint256 amount, bytes calldata data) external override {
        require(msg.sender == settlement, "only settlement");
        address fundToken = address(uint160(uint256(bytes32(data[0:32])) >> 16));
        require(IERC20(fundToken).balanceOf(address(this)) >= totalFunded + amount, "unfunded");
        calls++;
        totalFunded += amount;
    }
}

/// @dev PRE-FUNDED composite (`TAKE_FOR`): funds the value-IN side from its own
///      balance of the descriptor-named token, hands `amount` of the proceeds
///      token to `receiver`. Same trust posture as {FundingPinPreFundMake}.
contract FundingPinPreFundTakeFor is ITakerForModule {
    address public immutable permit3;
    address public immutable settlement;
    address public immutable proceedsToken;
    uint256 public calls;
    uint256 public totalFor;

    constructor(address permit3_, address settlement_, address proceedsToken_) {
        permit3 = permit3_;
        settlement = settlement_;
        proceedsToken = proceedsToken_;
    }

    function takeForOnBehalf(
        address spender,
        address,
        uint256 amount,
        uint256 forAmount,
        address receiver,
        bytes calldata data
    ) external override {
        require(msg.sender == permit3, "only permit3");
        require(spender == settlement, "only settlement-dispatched");
        address fundToken = address(uint160(uint256(bytes32(data[0:32])) >> 16));
        require(IERC20(fundToken).balanceOf(address(this)) >= totalFor + forAmount, "unfunded");
        calls++;
        totalFor += forAmount;
        IERC20(proceedsToken).transfer(receiver, amount);
    }
}

/// @dev PULL composite (`TAKE_FOR`) for the wallet-funded forms (LITERAL and
///      BALANCE): pulls `forAmount` of a fixed funding token from the maker via
///      Permit3 and hands `amount` of the proceeds token to `receiver`. The tokens
///      are immutables so `data` can be exactly the descriptor (+ cap) under test —
///      the BALANCE pin needs a 63-byte blob no ABI layout can carry.
contract FundingPinPullTakeFor is ITakerForModule {
    IPermit3 public immutable permit3;
    address public immutable fundToken;
    address public immutable proceedsToken;
    uint256 public calls;
    uint256 public lastFor;

    constructor(address permit3_, address fundToken_, address proceedsToken_) {
        permit3 = IPermit3(permit3_);
        fundToken = fundToken_;
        proceedsToken = proceedsToken_;
    }

    function takeForOnBehalf(address, address onBehalfOf, uint256 amount, uint256 forAmount, address receiver, bytes calldata)
        external
        override
    {
        require(msg.sender == address(permit3), "only permit3");
        // Skips a zero pull exactly as a lenient real adapter would — so a zero
        // `forAmount` the core let through would DRAW `amount` against no funding
        // (the fail-open the LITERAL-dust pin exists for), not revert in Permit3.
        if (forAmount != 0) permit3.transferFrom(onBehalfOf, address(this), fundToken, uint160(forAmount));
        IERC20(proceedsToken).transfer(receiver, amount);
        calls++;
        lastFor = forAmount;
    }
}

/// @title FundingRulePins
/// @notice Regression pins for the four funding sub-rules that survived the
///         2026-09-25 merge of six `TAKE_FOR`/pre-fund errors into
///         {Base.ForLegInvalid} and {Base.ForBalanceInvalid} with NO expectRevert
///         test of their own. The merge was a pure size trade (the on-chain revert
///         no longer says WHICH rule failed), so each rule is pinned here to its
///         exact selector.
///
///  Every test has the same three-part shape, so a pin cannot pass for the wrong
///  reason:
///    1. the defective order reverts with the EXACT merged selector;
///    2. nothing moved — every (token, holder) balance in the fixture, the module's
///       call log, and (for the composite) the maker's taker allowance;
///    3. a TWIN differing ONLY in the axis under test then fills — proving the
///       fixture is otherwise well formed and the revert is that rule's alone.
///
///  Fixture: SELL order, maker gives `tA` (the anchor), receives `tB`; `tC` is the
///  "wrong"/wallet-funded token. Non-fork ({MockSettlementBase}), RPC-independent.
contract FundingRulePinsTest is MockSettlementBase {
    FundingPinPreFundMake preFundMake;
    FundingPinPreFundTakeFor preFundTakeFor;
    FundingPinPullTakeFor pullTakeFor;

    address alice = address(0xA11CE01); // the exclusive filler in the soft-exclusivity pin

    uint256 constant AMOUNT_IN = 1_000e6; // tA — the maker's input leg == the SELL anchor
    uint256 constant AMOUNT_OUT = 1 ether; // tB — the output leg the leg-ref descriptors reference
    uint256 constant RESIDUE = 10 ether; //  tC stranded on each pre-fund singleton
    uint256 constant OVERRIDE_BPS = 100; //  1% soft-exclusivity improvement

    function setUp() public override {
        super.setUp();
        preFundMake = new FundingPinPreFundMake(address(settlement));
        preFundTakeFor = new FundingPinPreFundTakeFor(address(permit3), address(settlement), address(tA));
        pullTakeFor = new FundingPinPullTakeFor(address(permit3), address(tC), address(tA));
        vm.label(address(preFundMake), "preFundMake");
        vm.label(address(preFundTakeFor), "preFundTakeFor");
        vm.label(address(pullTakeFor), "pullTakeFor");
        vm.label(alice, "alice");

        // Borrow inventory the composites hand out as proceeds (the input-leg token).
        tA.mint(address(preFundTakeFor), AMOUNT_IN * 10);
        tA.mint(address(pullTakeFor), AMOUNT_IN * 10);

        // RESIDUE of the wrong token on both pre-fund singletons — the threat the
        // token binding exists for. With the core's check removed, a mis-tokened
        // descriptor would fund from THIS and fill; with it, the fill refuses.
        tC.mint(address(preFundMake), RESIDUE);
        tC.mint(address(preFundTakeFor), RESIDUE);

        // Maker pays the input leg from the wallet on the MAKE seam (no proceeds).
        tA.mint(maker, AMOUNT_IN * 10);
        _makerApprove(address(settlement), address(tA), type(uint160).max);
        // …and funds the pull composite's value-IN side from the wallet.
        _makerApprove(address(pullTakeFor), address(tC), type(uint160).max);

        // Both fillers can deliver the output leg.
        tB.mint(solver, AMOUNT_OUT * 10);
        _solverApprove(address(settlement), address(tB), type(uint160).max);
        tB.mint(alice, AMOUNT_OUT * 10);
        vm.startPrank(alice);
        tB.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(tB), type(uint160).max, 0);
        vm.stopPrank();
    }

    // ──────────────────── helpers ────────────────────

    /// @dev PRE-FUND leg reference: bit 255 (leg ref) + bit 253 (pre-fund shape),
    ///      funding TOKEN in bits [16:176), leg index in the low 16 bits.
    function _preFundDesc(address token, uint256 index) internal pure returns (uint256) {
        return (uint256(5) << 253) | (uint256(uint160(token)) << 16) | index;
    }

    /// @dev BALANCE form: bits 255+254, floor bps in [160:176), token in the low 160.
    function _balanceDesc(address token, uint256 floorBps) internal pure returns (uint256) {
        return (uint256(3) << 254) | (floorBps << 160) | uint160(token);
    }

    /// @dev One-item SELL order: tA (AMOUNT_IN, fixed) in, tB (AMOUNT_OUT, fixed)
    ///      out to `legRecipient` (0 = the maker).
    function _order(uint256 nonce, ItemOp op, address module, uint256 itemAmount, bytes memory data, address legRecipient)
        internal
        view
        returns (Order memory o)
    {
        o = _blank(nonce);
        o.legsIn = PackedEncode.oneLegIn(address(tA), AMOUNT_IN, 0);
        o.legsOut = PackedEncode.oneLegOut(address(tB), AMOUNT_OUT, 0, legRecipient);
        Item[] memory items = new Item[](1);
        items[0] = Item({op: op, module: module, amount: itemAmount, recipient: address(0), data: data});
        o.items = PackedEncode.items(items);
    }

    /// @dev The composite's value-OUT gate, sized to the whole item.
    function _grantTaker(address module, bytes memory data) internal {
        vm.prank(maker);
        permit3.approveTaker(
            address(settlement), module, keccak256(data), uint160(AMOUNT_IN), uint48(block.timestamp + 1 hours)
        );
    }

    function _assertTakerUnspent(address module, bytes memory data) internal view {
        (uint160 amt,) = permit3.takerAllowance(maker, address(settlement), module, keccak256(data));
        assertEq(amt, AMOUNT_IN, "taker allowance was spent on a refused fill");
    }

    function _truncate(bytes memory b, uint256 n) internal pure returns (bytes memory r) {
        r = new bytes(n);
        for (uint256 i; i < n; i++) {
            r[i] = b[i];
        }
    }

    /// @dev Every (token, holder) balance the fixture can move.
    function _snap() internal view returns (uint256[] memory s) {
        address[7] memory who = [
            maker,
            solver,
            alice,
            address(settlement),
            address(preFundMake),
            address(preFundTakeFor),
            address(pullTakeFor)
        ];
        MockERC20[3] memory tok = [tA, tB, tC];
        s = new uint256[](21);
        for (uint256 i; i < 7; i++) {
            for (uint256 j; j < 3; j++) {
                s[i * 3 + j] = tok[j].balanceOf(who[i]);
            }
        }
    }

    function _assertNothingMoved(uint256[] memory before) internal view {
        uint256[] memory now_ = _snap();
        for (uint256 k; k < now_.length; k++) {
            assertEq(now_[k], before[k], "a balance moved on a refused fill");
        }
    }

    // ──────────── 1. PRE-FUND TOKEN MISMATCH → ForLegInvalid ────────────
    //
    // Base._forSlice, pre-fund branch: the descriptor's token (bits [16:176)) must
    // equal `legsOut[j].token`. Everything else is well formed — the leg IS
    // addressed to the item's module, no override is live — so the token term of
    // the `bad` flag is the only one that can fire.

    /// Pre-funded MAKE: the leg delivers tB to the module, the descriptor tells it
    /// to supply tC — which it holds as residue, so without the binding this fills.
    function test_fundingRule_preFundMakeTokenMismatch_reverts() public {
        Order memory bad = _order(
            1, ItemOp.MAKE, address(preFundMake), 0, abi.encode(_preFundDesc(address(tC), 0)), address(preFundMake)
        );
        bytes memory sig = _sign(bad);
        uint256[] memory before = _snap();

        vm.prank(solver);
        vm.expectRevert(Base.ForLegInvalid.selector);
        settlement.fill(bad, sig, AMOUNT_IN);

        _assertNothingMoved(before);
        assertEq(preFundMake.calls(), 0, "module reached on a refused fill");

        // Twin: the descriptor names the leg's own token → fills, funds the delivery.
        Order memory good = _order(
            2, ItemOp.MAKE, address(preFundMake), 0, abi.encode(_preFundDesc(address(tB), 0)), address(preFundMake)
        );
        sig = _sign(good);
        vm.prank(solver);
        settlement.fill(good, sig, AMOUNT_IN);
        assertEq(preFundMake.totalFunded(), AMOUNT_OUT, "twin funds exactly the delivered leg");
        assertEq(tC.balanceOf(address(preFundMake)), RESIDUE, "residue untouched");
    }

    /// Pre-funded TAKE_FOR: same binding, reached through {Base._dispatchTake}.
    function test_fundingRule_preFundTakeForTokenMismatch_reverts() public {
        bytes memory badData = abi.encode(_preFundDesc(address(tC), 0));
        _grantTaker(address(preFundTakeFor), badData);
        Order memory bad =
            _order(3, ItemOp.TAKE_FOR, address(preFundTakeFor), AMOUNT_IN, badData, address(preFundTakeFor));
        bytes memory sig = _sign(bad);
        uint256[] memory before = _snap();

        vm.prank(solver);
        vm.expectRevert(Base.ForLegInvalid.selector);
        settlement.fill(bad, sig, AMOUNT_IN);

        _assertNothingMoved(before);
        _assertTakerUnspent(address(preFundTakeFor), badData);
        assertEq(preFundTakeFor.calls(), 0, "module reached on a refused fill");

        // Twin: matching token → fills.
        bytes memory goodData = abi.encode(_preFundDesc(address(tB), 0));
        _grantTaker(address(preFundTakeFor), goodData);
        Order memory good =
            _order(4, ItemOp.TAKE_FOR, address(preFundTakeFor), AMOUNT_IN, goodData, address(preFundTakeFor));
        sig = _sign(good);
        vm.prank(solver);
        settlement.fill(good, sig, AMOUNT_IN);
        assertEq(preFundTakeFor.totalFor(), AMOUNT_OUT, "twin funds exactly the delivered leg");
        assertEq(tC.balanceOf(address(preFundTakeFor)), RESIDUE, "residue untouched");
    }

    // ──────────── 2. PRE-FUND UNDER A LIVE SOFT-EXCLUSIVITY OVERRIDE → ForLegInvalid ────────────
    //
    // `Pricing.outputAt` lifts a non-exclusive filler's price only on a leg addressed
    // to the maker (or 0); a pre-fund leg is addressed to the MODULE, so the lift can
    // never apply. `_forSlice` therefore refuses the combination for an outsider
    // (`ctx.overrideBps != 0`) rather than let it fill at the exclusive price. The
    // nominated filler (override 0) is unaffected, and so is an outsider once the
    // window has closed — the refusal tracks the override being LIVE.
    //
    // ⚠ WHY A SECOND, MAKER-ADDRESSED OUTPUT LEG. Since the 2026-09-29 re-audit,
    // `OrderGates.exclusivityOverride` refuses an outsider with `NotExclusiveFiller`
    // at the GATE when no leg can carry the premium (`_overrideHasCarrier`) — which
    // is exactly the sole-module-leg + fixed-input shape. So the `_forSlice` term is
    // reachable only when SOME leg carries the override while the item's funding leg
    // is the module's. Leg 1 (to the maker) is that carrier; leg 0 (to the module)
    // is the one the pre-fund descriptor references.

    function test_fundingRule_preFundSoftExclusivityOutsider_reverts() public {
        Order memory o = _order(
            5, ItemOp.MAKE, address(preFundMake), 0, abi.encode(_preFundDesc(address(tB), 0)), address(preFundMake)
        );
        LegOut[] memory outs = new LegOut[](2);
        outs[0] = LegOut(address(tB), AMOUNT_OUT, 0, address(preFundMake)); // funds the position
        outs[1] = LegOut(address(tB), AMOUNT_OUT / 10, 0, address(0)); //      to the maker: the override's carrier
        o.legsOut = PackedEncode.legsOut(outs);
        o.exclusiveFiller = alice;
        _setExclusivityEnd(o, block.timestamp + 60); // window open
        o.params = OVERRIDE_BPS; // params bits [0:16): SOFT exclusivity
        bytes memory sig = _sign(o);
        uint256[] memory before = _snap();

        // Outsider, in-window: the override is live → refused.
        vm.prank(solver);
        vm.expectRevert(Base.ForLegInvalid.selector);
        settlement.fill(o, sig, AMOUNT_IN / 2);

        _assertNothingMoved(before);
        assertEq(preFundMake.calls(), 0, "module reached on a refused fill");

        // The EXCLUSIVE filler, same order and signature, same window → fills.
        vm.prank(alice);
        settlement.fill(o, sig, AMOUNT_IN / 2);
        assertEq(preFundMake.calls(), 1, "exclusive filler fills");

        // Window closed: no override is live, so the same outsider now fills too.
        vm.warp(block.timestamp + 61);
        vm.prank(solver);
        settlement.fill(o, sig, AMOUNT_IN - AMOUNT_IN / 2);
        assertEq(preFundMake.calls(), 2, "outsider fills once the override is no longer live");
        assertEq(
            preFundMake.totalFunded(), tB.balanceOf(address(preFundMake)), "funded exactly what was delivered"
        );
    }

    // ──────────── 3. BALANCE CAP WORD ABSENT (63-byte data) → ForBalanceInvalid ────────────
    //
    // Distinct from the existing present-but-ZERO pin: here `data` ends one byte
    // short of word 1, so the length guard folded into the cap load
    // (`mul(gt(itemData.length, 63), …)`) is what zeroes it. The twin is the SAME
    // 64-byte blob untruncated, and CAP's low byte is 0x00 — which is also the ABI
    // zero-padding that follows the items blob in calldata — so a guard-less
    // `calldataload` would recover exactly CAP and this pin would fill. Full fill,
    // explicit full floor: every other BALANCE rule passes.

    function test_fundingRule_balanceCapWordAbsent_reverts() public {
        uint256 cap = 10 ether;
        assertEq(cap & 0xff, 0, "fixture: CAP's dropped low byte must equal the zero padding");
        tC.mint(maker, cap);

        bytes memory full = abi.encode(_balanceDesc(address(tC), 10_000), cap); // 64 bytes
        bytes memory bad = _truncate(full, 63);
        assertEq(bad.length, 63);

        _grantTaker(address(pullTakeFor), bad);
        Order memory o = _order(6, ItemOp.TAKE_FOR, address(pullTakeFor), AMOUNT_IN, bad, address(0));
        bytes memory sig = _sign(o);
        uint256[] memory before = _snap();

        vm.prank(solver);
        vm.expectRevert(Base.ForBalanceInvalid.selector);
        settlement.fill(o, sig, AMOUNT_IN); // FULL fill — the full-fill rule is satisfied

        _assertNothingMoved(before);
        _assertTakerUnspent(address(pullTakeFor), bad);
        assertEq(pullTakeFor.calls(), 0, "module reached on a refused fill");

        // Twin: the cap word present → funds min(balance, cap) == cap.
        _grantTaker(address(pullTakeFor), full);
        Order memory good = _order(7, ItemOp.TAKE_FOR, address(pullTakeFor), AMOUNT_IN, full, address(0));
        sig = _sign(good);
        vm.prank(solver);
        settlement.fill(good, sig, AMOUNT_IN);
        assertEq(pullTakeFor.lastFor(), cap, "twin funds the capped balance");
    }

    // ──────────── 4. LITERAL SLICE FLOORS TO ZERO → ForBalanceInvalid ────────────
    //
    // Base._dispatchTake: a zero `forSlice` against a non-zero value-OUT slice is an
    // uncollateralised draw and is refused for every descriptor form. For the LITERAL
    // form the zero comes from `_prorate` flooring a small signed total on a partial
    // fill, while `item.amount == anchor` keeps the value-OUT slice == fillAmount > 0
    // (so `SettleSliceZero` cannot pre-empt it).

    function test_fundingRule_literalSliceFloorsToZero_reverts() public {
        uint256 literal = 1_000; // raw tC units, wallet-funded
        uint256 breakEven = AMOUNT_IN / literal; // smallest fill whose literal slice is 1
        tC.mint(maker, literal);

        bytes memory data = abi.encode(literal);
        _grantTaker(address(pullTakeFor), data);
        Order memory o = _order(8, ItemOp.TAKE_FOR, address(pullTakeFor), AMOUNT_IN, data, address(0));
        bytes memory sig = _sign(o);
        uint256[] memory before = _snap();

        // Pure dust: one anchor unit.
        vm.prank(solver);
        vm.expectRevert(Base.ForBalanceInvalid.selector);
        settlement.fill(o, sig, 1);

        // The boundary: the LARGEST fill whose funding slice still floors to zero.
        vm.prank(solver);
        vm.expectRevert(Base.ForBalanceInvalid.selector);
        settlement.fill(o, sig, breakEven - 1);

        _assertNothingMoved(before);
        _assertTakerUnspent(address(pullTakeFor), data);
        assertEq(pullTakeFor.calls(), 0, "module reached on a refused fill");

        // Twin: same order, same signature, one more unit → the slice is 1 and it fills.
        vm.prank(solver);
        settlement.fill(o, sig, breakEven);
        assertEq(pullTakeFor.lastFor(), 1, "twin funds the first whole unit of the literal");
    }
}
