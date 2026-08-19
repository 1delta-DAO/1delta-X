// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {Order, OrderSide, Item, ItemOp, Validator, LegIn, LegOut} from "@core/settlement/Settlement.sol";

import {CompoundV3ModulesBase} from "../shared/CompoundV3ModulesBase.t.sol";

/// @dev Single-signature fill. The maker's wallet has done ZERO setup with
/// Permit3 except the bare `IERC20.approve(permit3, ∞)` per token. They sign
/// exactly ONE EIP-712 message that bundles:
///   • a PermitBatch (token allowances Settlement + the deposit module need)
///   • a witness binding the permits to this specific Order
///
/// Solver calls `fillWithPermit(order, batch, sig, fillAmountIn)`:
///   1. Settlement asks Permit3 to verify the sig against
///      EIP-712(PermitBatchWitness, witness=orderHash) and apply the allowances.
///   2. Settlement runs the normal fill core; the freshly-applied allowances
///      satisfy every Permit3.transferFrom inside the fill.
///   3. Permit's nonce is consumed; the same signature can never be replayed.
contract FillWithPermitTest is CompoundV3ModulesBase {
    function test_fillWithPermit_singleSignature() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;

        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);

        // Maker side already has the bare ERC20 approves from setUp; no
        // permit3.approveX calls are made. Build the order.
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(depositModule),
            amount: wethOut,
            recipient: address(0),
            data: abi.encode(COMET, WETH)
        });
        Order memory order = Order({
            params: 0,
            pricingModule: address(0),
            maker: maker,
            nonce: 42,
            legsIn: _legsIn1(USDC, usdcIn),
            legsOut: _legsOut1(WETH, wethOut),
            timing: _expiryBits(block.timestamp + 1 hours),
            exclusiveFiller: address(0),
            minFillAnchor: 0,
            curve: _noCurve(),
            items: PackedEncode.items(items),
            validators: PackedEncode.noValidators(),
            invariants: PackedEncode.noValidators(),
            fillModule: address(0),
            fillTotal: 0
        });

        // Build the permit batch the fill needs:
        //   - settlement may pull USDC for tokenIn shortfall (cap = full amountIn for safety)
        //   - depositModule pulls WETH for the supply
        IPermit3.TokenPermit[] memory tokenPermits = new IPermit3.TokenPermit[](2);
        tokenPermits[0] = IPermit3.TokenPermit({
            spender: address(settlement), token: USDC, amount: uint160(usdcIn), expiration: uint48(_expiry(order))
        });
        tokenPermits[1] = IPermit3.TokenPermit({
            spender: address(depositModule), token: WETH, amount: uint160(wethOut), expiration: uint48(_expiry(order))
        });
        IPermit3.TakerPermit[] memory takerPermits = new IPermit3.TakerPermit[](0);

        IPermit3.PermitBatch memory batch =
            IPermit3.PermitBatch({tokens: tokenPermits, takers: takerPermits, nonce: 1, deadline: _expiry(order)});

        // Sign the witness-bound permit.
        bytes memory sig = _signPermitWitness(batch, _hashOrder(order));

        // Fill — single solver call, single maker signature.
        vm.prank(solver);
        uint256 paid = settlement.fillWithPermit(order, batch, sig, usdcIn)[0];

        assertEq(paid, wethOut, "solver paid 1 WETH");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "maker USDC pulled");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver received USDC");
        assertApproxEqAbs(_wethCollateral(maker), wethOut, 2, "maker received Comet collateral");

        // Permit nonce now used; signature non-replayable.
        assertTrue(permit3.isPermitNonceUsed(maker, 1), "permit nonce used");

        // Order nonce path is independent and untouched (no order sig was used).
        assertFalse(settlement.isNonceCancelled(maker, order.nonce), "order nonce untouched");
    }
}
