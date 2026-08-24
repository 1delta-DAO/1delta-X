// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, LegIn, LegOut, OrderSide, Validator} from "@core/settlement/Settlement.sol";
import {FeeTransferModule} from "../src/FeeTransferModule.sol";

import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";

/// @dev The originator-fee item ({FeeTransferModule}) on the outputless order
/// shape — the maker-funded fee channel for orders with no `tokenOut` to carry
/// a fee leg. The canonical integrator order carries BOTH fee actors at once:
///
///   items    = [ MAKE FeeTransferModule: ORIG_FEE USDC → originator ]  (absolute, named)
///   tokenIn  = [ USDC ]  F0 → FMAX rising                              (relayer, auctioned)
///   tokenOut = [ ]
///
/// (A real order would also carry the action item — deposit, repay, … — see the
/// aave-v3 DepositWithFee integrator test; the mechanics are identical.)
contract FeeTransferModuleTest is CoreSettlementBase {
    FeeTransferModule feeModule;
    address originator = address(0x0F0F);

    uint256 constant ORIG_FEE = 5e6; //   absolute originator fee
    uint256 constant F0 = 1e6; //         relayer fee floor (anchor)
    uint256 constant FMAX = 3e6; //       relayer fee ceiling
    uint32 constant DURATION = 1000;

    function setUp() public override {
        super.setUp();
        feeModule = new FeeTransferModule(address(permit3), address(settlement));
        vm.label(address(feeModule), "feeTransferModule");
        vm.label(originator, "originator");
    }

    function _feeOrder(uint256 nonce) internal view returns (Order memory order) {
        return _feeOrderTo(nonce, originator);
    }

    /// @dev `_feeOrder` with the fee recipient overridable — the packed item blob is
    ///      not mutable in place, so a test that wants a different recipient builds
    ///      the order with it rather than poking the encoded bytes afterwards.
    function _feeOrderTo(uint256 nonce, address feeRecipient) internal view returns (Order memory order) {
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(feeModule),
            amount: ORIG_FEE,
            recipient: address(0),
            data: abi.encode(USDC, feeRecipient)
        });
        LegIn[] memory legsIn = new LegIn[](1);
        legsIn[0] = LegIn(USDC, F0, FMAX); // rising relayer-fee input (F0 → FMAX)
        order = Order({
            params: 0,
            pricingModule: address(0),
            maker: maker,
            nonce: nonce,
            legsIn: PackedEncode.legsIn(legsIn),
            legsOut: PackedEncode.legsOut(new LegOut[](0)), // gasless deposit — no conversion output
            timing: _packTiming(uint32(block.timestamp), DURATION, 0) | _expiryBits(block.timestamp + 1 hours),
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

    function _fund() internal {
        deal(USDC, maker, ORIG_FEE + FMAX);
        vm.startPrank(maker);
        // Fee item: the module pulls the originator's absolute fee.
        permit3.approveToken(address(feeModule), USDC, uint160(ORIG_FEE), 0);
        // Rising relayer leg: Settlement pulls up to the ceiling.
        permit3.approveToken(address(settlement), USDC, uint160(FMAX), 0);
        vm.stopPrank();
    }

    // ── Both fee actors paid from one outputless order ──
    function test_feeItem_paysOriginator_alongsideRisingRelayerLeg() public {
        _fund();
        Order memory order = _feeOrder(0);
        bytes memory sig = _sign(order);

        vm.warp(block.timestamp + DURATION / 2); // bump = 5000
        uint256 relayerFee = F0 + (FMAX - F0) / 2; // 2e6

        vm.prank(solver);
        settlement.fill(order, sig, F0);

        assertEq(IERC20(USDC).balanceOf(originator), ORIG_FEE, "originator got the absolute fee");
        assertEq(IERC20(USDC).balanceOf(solver), relayerFee, "relayer got the auction-tick fee");
        assertEq(IERC20(USDC).balanceOf(maker), FMAX - relayerFee, "maker paid both");
        assertEq(IERC20(USDC).balanceOf(address(feeModule)), 0, "module never holds funds");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement drained");
    }

    // ── The fee item slices pro-rata like any item ──
    function test_feeItem_partialFills_proRata() public {
        _fund();
        Order memory order = _feeOrder(1);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, F0 / 2);
        assertEq(IERC20(USDC).balanceOf(originator), ORIG_FEE / 2, "half fee after half fill");

        vm.prank(solver);
        settlement.fill(order, sig, F0 - F0 / 2);
        assertEq(IERC20(USDC).balanceOf(originator), ORIG_FEE, "full fee accumulated");
    }

    // ── Auth: only Settlement may dispatch; recipient must be set ──
    function test_feeItem_directCall_reverts() public {
        vm.expectRevert(FeeTransferModule.OnlySettlement.selector);
        feeModule.makeOnBehalf(maker, 1e6, abi.encode(USDC, address(0xBAD)));
    }

    function test_feeItem_zeroRecipient_reverts() public {
        _fund();
        Order memory order = _feeOrderTo(2, address(0));
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(); // FeeTransferModule.ZeroRecipient (bubbled through the item call)
        settlement.fill(order, sig, F0);
    }

    // ── Lens: cross-overlap tokenIn == tokenOut is valid for ITEM orders ──
    function test_lens_sameAssetOverlap_flaggedOnlyWithoutItems() public view {
        // Item-bearing same-asset order (the same-asset exit / fee shape) → valid.
        Order memory o = _feeOrder(3);
        LegOut[] memory _tmplegsOut = new LegOut[](1);
        _tmplegsOut[0] = LegOut(USDC, 1e6, 0, address(0));
        o.legsOut = PackedEncode.legsOut(_tmplegsOut);
        (bool ok, string memory reason) = lens.validateOrder(o);
        assertTrue(ok, string.concat("item order overlap valid: ", reason));

        // Item-free self-trade → still flagged.
        o.items = PackedEncode.noItems();
        (ok, reason) = lens.validateOrder(o);
        assertFalse(ok, "item-free self-trade rejected");
        assertEq(reason, "input token == output token");
    }
}
