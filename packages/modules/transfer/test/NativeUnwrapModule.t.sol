// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, LegIn, LegOut, Validator} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";
import {NativeUnwrapModule} from "../src/NativeUnwrapModule.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";

import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";

/// @dev A recipient that cannot accept native currency — the hostile/misconfigured
///      receiver whose revert must kill the fill (never strand funds mid-module).
contract NoReceive {}

/// @dev A smart-account-shaped recipient: accepting native costs real gas (an
///      SSTORE), which the module's full-gas forward must accommodate.
contract StatefulReceiver {
    uint256 public received;

    receive() external payable {
        received += msg.value;
    }
}

/// @dev In-fill native-out ({NativeUnwrapModule}): the maker sells USDC and
/// receives raw ETH — a WETH output leg delivered to the module singleton, then
/// a pre-funded MAKE item that unwraps exactly what this fill DELIVERED for that
/// leg (sized by the settler from its delivery ledger) and pushes it on. The
/// partial-fill test pins that with prime amounts; the residue tests pin the
/// property the ledger sizing exists for — an auction-priced leg leaves nothing
/// behind for a stranger to claim.
contract NativeUnwrapModuleTest is CoreSettlementBase {
    NativeUnwrapModule unwrapModule;

    uint256 constant USDC_IN = 3000e6;
    uint256 constant ETH_OUT = 1e18;

    function setUp() public override {
        super.setUp();
        unwrapModule = new NativeUnwrapModule(WETH, address(settlement));
        vm.label(address(unwrapModule), "nativeUnwrapModule");
    }

    /// @dev The pre-fund leg reference the item carries: leg `j`, funding token WETH
    ///      (mirror of the SDK's `forLegPreFund`).
    function _forLeg(uint256 j) internal view returns (uint256) {
        return (uint256(5) << 253) | (uint256(uint160(WETH)) << 16) | j;
    }

    /// @dev USDC→native order: WETH leg to the module + the matching unwrap item.
    ///      `payout = address(0)` exercises the maker default. `ethEnd != 0` makes
    ///      the WETH leg a Dutch auction (`start → end` over `DECAY`).
    function _nativeOutOrder(uint256 nonce, uint256 usdcIn, uint256 ethOut, address payout)
        internal
        view
        returns (Order memory order)
    {
        return _nativeOutOrder(nonce, usdcIn, ethOut, 0, payout);
    }

    uint32 constant DECAY = 1000;

    function _nativeOutOrder(uint256 nonce, uint256 usdcIn, uint256 ethOut, uint256 ethEnd, address payout)
        internal
        view
        returns (Order memory order)
    {
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(unwrapModule),
            amount: 0, // sized from the delivery ledger, not signed
            recipient: address(0),
            data: abi.encode(_forLeg(0), payout)
        });
        LegIn[] memory legsIn = new LegIn[](1);
        legsIn[0] = LegIn(USDC, usdcIn, 0);
        LegOut[] memory legsOut = new LegOut[](1);
        legsOut[0] = LegOut(WETH, ethOut, ethEnd, address(unwrapModule));
        uint256 timing = _expiryBits(block.timestamp + 1 hours);
        if (ethEnd != 0) timing |= _packTiming(uint32(block.timestamp), DECAY, 0);
        order = Order({
            params: 0,
            pricingModule: address(0),
            maker: maker,
            nonce: nonce,
            legsIn: PackedEncode.legsIn(legsIn),
            legsOut: PackedEncode.legsOut(legsOut),
            timing: timing,
            exclusiveFiller: address(0),
            minFillAnchor: 0,
            curve: PackedEncode.noCurve(),
            items: PackedEncode.items(items),
            validators: PackedEncode.noValidators(),
            invariants: PackedEncode.noValidators(),
            fillModule: address(0),
            fillTotal: 0
        });
    }

    function _fund(uint256 usdcIn, uint256 ethOut) internal {
        deal(USDC, maker, usdcIn);
        deal(WETH, solver, ethOut);
        vm.prank(maker);
        permit3.approveToken(address(settlement), USDC, uint160(usdcIn), 0);
    }

    // ── Full fill: maker signs once, raw ETH lands in their wallet ──
    function test_nativeOut_fullFill_makerReceivesEth() public {
        _fund(USDC_IN, ETH_OUT);
        Order memory order = _nativeOutOrder(0, USDC_IN, ETH_OUT, address(0));
        bytes memory sig = _sign(order);

        uint256 makerEthBefore = maker.balance;
        vm.prank(solver);
        settlement.fill(order, sig, USDC_IN);

        assertEq(maker.balance - makerEthBefore, ETH_OUT, "maker got raw ETH");
        assertEq(IERC20(USDC).balanceOf(solver), USDC_IN, "solver got the USDC");
        assertEq(IERC20(WETH).balanceOf(address(unwrapModule)), 0, "module holds no WETH");
        assertEq(address(unwrapModule).balance, 0, "module holds no ETH");
        assertEq(IERC20(WETH).balanceOf(maker), 0, "nothing left wrapped");
    }

    // ── Partial fills: leg slice == item slice under floor rounding (primes) ──
    function test_nativeOut_partialFills_sliceStaysMatched() public {
        uint256 usdcIn = 2999999983; // prime-ish, indivisible amounts
        uint256 ethOut = 999999999999999989;
        // SELL-side output legs round up PER FILL (maker-favoring), so across
        // 2 partial fills the solver can owe up to 1 wei beyond `ethOut`.
        _fund(usdcIn, ethOut + 1);
        Order memory order = _nativeOutOrder(1, usdcIn, ethOut, address(0));
        bytes memory sig = _sign(order);

        uint256 makerEthBefore = maker.balance;

        vm.prank(solver);
        settlement.fill(order, sig, usdcIn / 3);
        assertGt(maker.balance, makerEthBefore, "first slice arrived as ETH");
        // The item is sized from the delivery ledger, so each fill unwraps
        // exactly what its leg delivered: nothing is ever parked here, not even
        // mid-order.
        assertEq(IERC20(WETH).balanceOf(address(unwrapModule)), 0, "no transient residue");

        vm.prank(solver);
        settlement.fill(order, sig, usdcIn - usdcIn / 3);

        // SELL legs round up PER FILL in the maker's favour, so across two fills
        // the maker may receive up to 1 wei over the signed amount — and receives
        // it as ETH, rather than leaving it stranded on the singleton (the
        // pre-audit behaviour, where the item unwrapped a cumulative-floor
        // constant and the ceil excess accrued here as "dust").
        uint256 got = maker.balance - makerEthBefore;
        assertGe(got, ethOut, "at least the signed amount");
        assertLe(got, ethOut + 1, "at most one wei of per-fill ceil");
        assertEq(IERC20(WETH).balanceOf(address(unwrapModule)), 0, "nothing stranded");
        assertEq(address(unwrapModule).balance, 0, "no stranded ETH");
    }

    // ── Signed payout override: a third party (smart-account-shaped) receives ──
    function test_nativeOut_payoutOverride_contractRecipient() public {
        StatefulReceiver recipient = new StatefulReceiver();
        _fund(USDC_IN, ETH_OUT);
        Order memory order = _nativeOutOrder(2, USDC_IN, ETH_OUT, address(recipient));
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, USDC_IN);

        assertEq(recipient.received(), ETH_OUT, "contract recipient got the ETH");
        assertEq(maker.balance, 0, "maker was not paid twice");
    }

    // ── A recipient that can't take native kills the fill (nothing strands) ──
    function test_nativeOut_revertingRecipient_killsFill() public {
        NoReceive bad = new NoReceive();
        _fund(USDC_IN, ETH_OUT);
        Order memory order = _nativeOutOrder(3, USDC_IN, ETH_OUT, address(bad));
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(); // NativeUnwrapModule.NativeSendFailed, bubbled through the item call
        settlement.fill(order, sig, USDC_IN);

        assertEq(IERC20(WETH).balanceOf(address(unwrapModule)), 0, "atomic: no WETH stranded");
        assertEq(IERC20(USDC).balanceOf(solver), 0, "atomic: solver not paid");
    }

    // ── Auth: only Settlement may dispatch the unwrap ──
    function test_directCall_reverts() public {
        vm.expectRevert(NativeUnwrapModule.OnlySettlement.selector);
        unwrapModule.makeOnBehalf(maker, 1e18, abi.encode(_forLeg(0), address(0)));
    }

    // ── The old plain-address blob (signed constant) is refused outright ──
    function test_nativeOut_plainAddressData_reverts() public {
        _fund(USDC_IN, ETH_OUT);
        Order memory order = _nativeOutOrder(7, USDC_IN, ETH_OUT, address(0));
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(unwrapModule),
            amount: ETH_OUT,
            recipient: address(0),
            data: abi.encode(address(0)) // the pre-audit shape
        });
        order.items = PackedEncode.items(items);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(PreFundGuard.PreFundDescriptorRequired.selector);
        settlement.fill(order, sig, USDC_IN);
    }

    // ── Item without its funding leg fails loud (no donation, no payout) ──
    function test_nativeOut_itemWithoutLeg_reverts() public {
        _fund(USDC_IN, ETH_OUT);
        Order memory order = _nativeOutOrder(4, USDC_IN, ETH_OUT, address(0));
        // Strip the WETH leg: the item now has nothing to unwrap.
        order.legsOut = PackedEncode.legsOut(new LegOut[](0));
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(Base.ForLegMissing.selector); // the descriptor names a leg that is not there
        settlement.fill(order, sig, USDC_IN);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  2026-09-12 audit, finding 2 — auction-priced leg vs signed constant.
    //  Before: the item unwrapped a pro-rated CONSTANT while the leg delivered
    //  `Pricing.outputAt`; on a Dutch leg the difference stranded on this shared
    //  singleton and a zero-leg self-order withdrew it to a stranger. Now the
    //  item is sized from the delivery ledger, so nothing is ever left behind.
    // ────────────────────────────────────────────────────────────────────────

    /// @dev Full fill of a 1e18 → 0.9e18 Dutch leg halfway through the decay:
    ///      the maker receives the resolved tick as ETH and the module ends empty.
    function test_nativeOut_dutchLeg_unwrapsExactlyTheDelivery() public {
        uint256 ethEnd = 0.9e18;
        _fund(USDC_IN, ETH_OUT);
        Order memory order = _nativeOutOrder(5, USDC_IN, ETH_OUT, ethEnd, address(0));
        bytes memory sig = _sign(order);

        vm.warp(block.timestamp + DECAY / 2); // tick = 0.95e18
        uint256 makerEthBefore = maker.balance;
        vm.prank(solver);
        settlement.fill(order, sig, USDC_IN);

        uint256 got = maker.balance - makerEthBefore;
        assertGt(got, ethEnd, "maker received more than the floor");
        assertLt(got, ETH_OUT, "and less than the start: the resolved tick");
        assertEq(IERC20(WETH).balanceOf(address(unwrapModule)), 0, "no auction improvement stranded");
        assertEq(address(unwrapModule).balance, 0, "no ETH stranded");
    }

    /// @dev The attacker's claim order: WETH donated/stranded on the module, a
    ///      self-signed order with NO output leg and an item naming the residue.
    ///      The descriptor points at a leg that does not exist ⇒ fails closed;
    ///      a plain-address blob is refused by the module. Either way the residue
    ///      stays put — donations are no longer claimable through a fill.
    function test_nativeOut_residueCannotBeClaimedByZeroLegOrder() public {
        deal(WETH, address(unwrapModule), 0.1e18); // "stranded" WETH
        address attacker = makeAddr("attacker");
        deal(USDC, attacker, 1);
        vm.prank(attacker);
        permit3.approveToken(address(settlement), USDC, 1, 0);

        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(unwrapModule),
            amount: 0.1e18,
            recipient: address(0),
            data: abi.encode(_forLeg(0), attacker)
        });
        LegIn[] memory legsIn = new LegIn[](1);
        legsIn[0] = LegIn(USDC, 1, 0);
        Order memory order = Order({
            params: 0,
            pricingModule: address(0),
            maker: attacker,
            nonce: 99,
            legsIn: PackedEncode.legsIn(legsIn),
            legsOut: PackedEncode.legsOut(new LegOut[](0)),
            timing: _expiryBits(block.timestamp + 1 hours),
            exclusiveFiller: address(0),
            minFillAnchor: 0,
            curve: PackedEncode.noCurve(),
            items: PackedEncode.items(items),
            validators: PackedEncode.noValidators(),
            invariants: PackedEncode.noValidators(),
            fillModule: address(0),
            fillTotal: 0
        });
        // The attacker approves the order on-chain (no key for makeAddr) — the
        // shape is what matters, not the signature path.
        vm.prank(attacker);
        settlement.approveOrder(order);

        vm.prank(solver);
        vm.expectRevert(Base.ForLegMissing.selector);
        settlement.fill(order, "", 1);

        assertEq(IERC20(WETH).balanceOf(address(unwrapModule)), 0.1e18, "residue untouched");
        assertEq(attacker.balance, 0, "attacker got nothing");
    }

    /// @dev A 1-wei under-delivering leg cannot lever a stranded balance either:
    ///      the item is sized from the ledger (1 wei), and the floor proves only
    ///      that 1 wei arrived.
    function test_nativeOut_underDeliveringLegUnwrapsOnlyItsDelivery() public {
        deal(WETH, address(unwrapModule), 0.1e18); // "stranded" WETH
        _fund(1, 1);
        Order memory order = _nativeOutOrder(6, 1, 1, address(0));
        bytes memory sig = _sign(order);

        uint256 makerEthBefore = maker.balance;
        vm.prank(solver);
        settlement.fill(order, sig, 1);

        assertEq(maker.balance - makerEthBefore, 1, "exactly the 1 wei delivered");
        assertEq(IERC20(WETH).balanceOf(address(unwrapModule)), 0.1e18, "residue untouched");
    }
}
