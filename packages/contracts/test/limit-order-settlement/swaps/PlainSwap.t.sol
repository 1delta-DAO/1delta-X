// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "../../../src/interfaces/IPermit3.sol";
import {LimitOrder, Item, Validator} from "../../../src/settlement/LimitOrderSettlement.sol";

import {LimitOrderSettlementBase} from "../shared/LimitOrderSettlementBase.t.sol";

/// @dev Plain swap: the maker sells tokenIn for tokenOut with NO lending items.
/// tokenOut lands directly in the maker's wallet; tokenIn is pulled from the
/// maker and paid to the solver. This is the purest fill — no modules, no Aave,
/// just Permit3-gated token movement — and the cleanest way to exercise the
/// order-level mechanics (partial fills, dutch decay).
///
///   tokenIn  = USDC   (maker gives, solver receives)
///   tokenOut = WETH   (solver gives, maker receives — straight to wallet)
contract PlainSwapTest is LimitOrderSettlementBase {
    /// @dev Maker only needs to let Settlement pull tokenIn; the bare ERC20
    ///      approve to Permit3 is already granted in `setUp`.
    function _approveMakerPlainSwap(uint256 usdcCap) internal {
        vm.prank(maker);
        permit3.approveToken(address(settlement), USDC, uint160(usdcCap), 0);
    }

    function _plainSwapOrder(uint256 nonce, uint256 usdcIn, uint256 wethOut)
        internal
        view
        returns (LimitOrder memory)
    {
        return _order(maker, nonce, USDC, WETH, usdcIn, wethOut, new Item[](0));
    }

    // ──────────────────── Full fill ────────────────────

    function test_plain_swap_full() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;

        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);

        _approveMakerPlainSwap(usdcIn);
        _approveSolverSide(wethOut, WETH);

        LimitOrder memory order = _plainSwapOrder(0, usdcIn, wethOut);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, usdcIn);

        assertEq(paid, wethOut, "solver paid exactly wethOut");

        // Maker swapped USDC for WETH, received straight to wallet (no deposit).
        assertEq(IERC20(USDC).balanceOf(maker), 0, "maker USDC spent");
        assertEq(IERC20(WETH).balanceOf(maker), wethOut, "maker received WETH in wallet");

        // Solver gave WETH, received USDC.
        assertEq(IERC20(WETH).balanceOf(solver), 0, "solver WETH spent");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver received USDC");

        // Settlement holds nothing.
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
    }

    // ──────────────────── Partial fills (pro-rata accumulation) ────────────────────

    function test_plain_swap_partialFills() public {
        uint256 usdcIn = 2_000e6; //    full order size
        uint256 wethOut = 1 ether; //    full output at fixed price

        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);

        _approveMakerPlainSwap(usdcIn);
        _approveSolverSide(wethOut, WETH);

        LimitOrder memory order = _plainSwapOrder(1, usdcIn, wethOut);
        bytes memory sig = _sign(order);

        // First fill: half the order.
        vm.prank(solver);
        uint256 paid1 = settlement.fill(order, sig, usdcIn / 2);
        assertEq(paid1, wethOut / 2, "first fill pays half the output");
        assertEq(settlement.filledAmountIn(settlement.hashOrder(order)), usdcIn / 2, "half filled");
        assertEq(settlement.remaining(order), usdcIn / 2, "half remaining");

        // Second fill: the rest. Pro-rata slices accumulate exactly to the totals.
        vm.prank(solver);
        uint256 paid2 = settlement.fill(order, sig, usdcIn - usdcIn / 2);
        assertEq(paid1 + paid2, wethOut, "two fills sum to full output");
        assertEq(settlement.remaining(order), 0, "fully filled");

        // A third fill must revert — order is exhausted.
        vm.prank(solver);
        vm.expectRevert();
        settlement.fill(order, sig, 1);

        assertEq(IERC20(WETH).balanceOf(maker), wethOut, "maker received full WETH across fills");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver received full USDC across fills");
    }

    // ──────────────────── Dutch decay pricing ────────────────────

    function test_plain_swap_dutchDecay() public {
        uint256 usdcIn = 2_000e6;
        uint256 startOut = 1 ether; //      best for maker (auction start)
        uint256 endOut = 0.8 ether; //       worst for maker (auction end)

        deal(USDC, maker, usdcIn);
        deal(WETH, solver, startOut);

        _approveMakerPlainSwap(usdcIn);
        _approveSolverSide(startOut, WETH);

        Item[] memory items = new Item[](0);
        LimitOrder memory order = LimitOrder({
            maker: maker,
            nonce: 2,
            deadline: block.timestamp + 1 hours,
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: usdcIn,
            decayStartTime: uint32(block.timestamp),
            decayDuration: 100,
            startAmountOut: startOut,
            endAmountOut: endOut,
            exclusiveFiller: address(0),
            exclusivityEndTime: 0,
            minFillAmountIn: 0,
            items: items,
            validators: new Validator[](0),
            invariants: new Validator[](0)
        });
        bytes memory sig = _sign(order);

        // Warp to the auction midpoint → output decays halfway from start to end.
        vm.warp(block.timestamp + 50);
        uint256 expectedOut = startOut - (startOut - endOut) / 2; // 0.9 ether
        assertEq(settlement.previewAmountOut(order), expectedOut, "preview matches midpoint price");

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, usdcIn);

        assertEq(paid, expectedOut, "solver paid the decayed price");
        assertEq(IERC20(WETH).balanceOf(maker), expectedOut, "maker received decayed WETH");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver received full USDC");
    }

    // ──────────────────── Single-signature permit fill ────────────────────

    function test_permit_plain_swap() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;

        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);

        LimitOrder memory order = _plainSwapOrder(3, usdcIn, wethOut);

        // Single token permit: Settlement may pull the maker's USDC.
        IPermit3.TokenPermit[] memory tp = new IPermit3.TokenPermit[](1);
        tp[0] = IPermit3.TokenPermit({
            spender: address(settlement),
            token: USDC,
            amount: uint160(usdcIn),
            expiration: uint48(order.deadline)
        });

        IPermit3.PermitBatch memory batch = _buildBatch(tp, _noTakerPermits(), 0, order.deadline);
        bytes memory sig = _signPermitWitness(batch, _hashOrder(order));

        vm.prank(solver);
        uint256 paid = settlement.fillWithPermit(order, batch, sig, usdcIn);

        assertEq(paid, wethOut, "solver paid exactly wethOut");
        assertEq(IERC20(WETH).balanceOf(maker), wethOut, "maker received WETH in wallet");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver received USDC");
    }
}
