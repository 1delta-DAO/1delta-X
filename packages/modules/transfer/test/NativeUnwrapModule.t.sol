// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, LegIn, LegOut, Validator} from "@core/settlement/Settlement.sol";
import {NativeUnwrapModule} from "../src/NativeUnwrapModule.sol";

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
/// a MAKE item that unwraps exactly this fill's slice and pushes it on. The
/// leg and the item carry the SAME signed amount and slice by the same fill
/// fraction, which the partial-fill test pins with prime amounts.
contract NativeUnwrapModuleTest is CoreSettlementBase {
    NativeUnwrapModule unwrapModule;

    uint256 constant USDC_IN = 3000e6;
    uint256 constant ETH_OUT = 1e18;

    function setUp() public override {
        super.setUp();
        unwrapModule = new NativeUnwrapModule(WETH, address(settlement));
        vm.label(address(unwrapModule), "nativeUnwrapModule");
    }

    /// @dev USDC→native order: WETH leg to the module + the matching unwrap item.
    ///      `payout = address(0)` exercises the maker default.
    function _nativeOutOrder(uint256 nonce, uint256 usdcIn, uint256 ethOut, address payout)
        internal
        view
        returns (Order memory order)
    {
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(unwrapModule),
            amount: ethOut,
            recipient: address(0),
            data: abi.encode(payout)
        });
        LegIn[] memory legsIn = new LegIn[](1);
        legsIn[0] = LegIn(USDC, usdcIn, 0);
        LegOut[] memory legsOut = new LegOut[](1);
        legsOut[0] = LegOut(WETH, ethOut, 0, address(unwrapModule));
        order = Order({
            params: 0,
            pricingModule: address(0),
            maker: maker,
            nonce: nonce,
            legsIn: PackedEncode.legsIn(legsIn),
            legsOut: PackedEncode.legsOut(legsOut),
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
        // Legs slice by cumulative CEIL (maker-favoring), items by cumulative
        // FLOOR — so mid-order the module may hold ceil−floor = at most 1 wei,
        // and the item is never underfunded. Both telescope to the exact signed
        // amount at completion (asserted below).
        assertLe(IERC20(WETH).balanceOf(address(unwrapModule)), 1, "transient residue bounded by 1 wei");

        vm.prank(solver);
        settlement.fill(order, sig, usdcIn - usdcIn / 3);

        // The maker's receipt is the cumulative-floor item sum — exactly the
        // signed amount. The per-fill ceil over-delivery (≤ 1 wei per extra
        // fill) stays behind as module dust, never mispays a maker.
        assertEq(maker.balance - makerEthBefore, ethOut, "full amount accumulated exactly");
        assertLe(IERC20(WETH).balanceOf(address(unwrapModule)), 1, "dust bounded by fills-1 wei");
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
        unwrapModule.makeOnBehalf(maker, 1e18, abi.encode(address(0)));
    }

    // ── Item without its funding leg fails loud (no donation, no payout) ──
    function test_nativeOut_itemWithoutLeg_reverts() public {
        _fund(USDC_IN, ETH_OUT);
        Order memory order = _nativeOutOrder(4, USDC_IN, ETH_OUT, address(0));
        // Strip the WETH leg: the item now has nothing to unwrap.
        order.legsOut = PackedEncode.legsOut(new LegOut[](0));
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(); // WETH9: withdraw exceeds balance
        settlement.fill(order, sig, USDC_IN);
    }
}
