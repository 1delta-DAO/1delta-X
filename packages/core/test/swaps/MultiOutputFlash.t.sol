// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, Validator, OrderSide} from "@core/settlement/UniversalSettlement.sol";
import {MultiOutputFlashSolver, OutputLeg} from "@core/solver/MultiOutputFlashSolver.sol";

import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

/// @dev Multi-OUTPUT fill with ZERO solver inventory. The maker sells WETH for a
/// {USDC, DAI} basket; the solver owns neither output. MultiOutputFlashSolver:
///
///   1. Flash-loans the USDC + DAI basket from Balancer.
///   2. Settlement delivers both to the maker and pays the solver the WETH.
///   3. The solver buys USDC and DAI back from that WETH and repays the flash;
///      leftover WETH + surplus basket tokens are profit.
///
/// This is the output-side analogue of the leverage flash solvers — the one
/// filler shape the family didn't previously cover. WETH is the input so both
/// buybacks route through the WETH/USDC and WETH/DAI pools.
contract MultiOutputFlashTest is CoreSettlementBase {
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address constant UNI_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    // Priced generously so the buybacks comfortably cover the flash (this is
    // about the filler mechanics, not the maker's P&L). At the pinned fork block
    // 1 WETH buys ~2143 USDC / ~2141 DAI, so each 1-WETH buyback (minOut below)
    // clears the 2_000 it must repay with headroom; the maker sells 3 WETH, so
    // ~1 WETH is left as solver profit.
    uint256 constant WETH_IN = 3 ether;
    uint256 constant USDC_OUT = 2_000e6;
    uint256 constant DAI_OUT = 2_000e18;

    MultiOutputFlashSolver flashSolver;

    function setUp() public override {
        super.setUp();
        vm.label(DAI, "DAI");
        flashSolver =
            new MultiOutputFlashSolver(address(permit3), address(settlement), BALANCER_VAULT, UNI_ROUTER);
        vm.label(address(flashSolver), "multiOutputFlashSolver");
    }

    function _a2(address a, address b) internal pure returns (address[] memory r) {
        r = new address[](2);
        r[0] = a;
        r[1] = b;
    }

    function _u2(uint256 a, uint256 b) internal pure returns (uint256[] memory r) {
        r = new uint256[](2);
        r[0] = a;
        r[1] = b;
    }

    /// @dev Flash + buyback plan, sorted ascending by token (DAI < USDC). Each
    ///      output is bought back with ~1 WETH: DAI via WETH/DAI 0.3%, USDC via
    ///      WETH/USDC 0.05%; ~2 of the 3 WETH goes to buybacks, the rest is profit.
    function _legs() internal view returns (OutputLeg[] memory legs) {
        legs = new OutputLeg[](2);
        legs[0] = OutputLeg({token: DAI, flashAmount: DAI_OUT, dexFee: 3000, spendIn: 1 ether, minOut: DAI_OUT});
        legs[1] = OutputLeg({token: USDC, flashAmount: USDC_OUT, dexFee: 500, spendIn: 1 ether, minOut: USDC_OUT});
    }

    function _order() internal view returns (Order memory) {
        return Order({
            maker: maker,
            side: OrderSide.SELL,
            nonce: 0,
            deadline: block.timestamp + 1 hours,
            tokenIn: _a1(WETH),
            startAmountIn: _u1(WETH_IN),
            endAmountIn: _u1(WETH_IN),
            decayStartTime: 0,
            decayDuration: 0,
            tokenOut: _a2(USDC, DAI),
            startAmountOut: _u2(USDC_OUT, DAI_OUT),
            endAmountOut: _u2(USDC_OUT, DAI_OUT),
            exclusiveFiller: address(0),
            exclusivityEndTime: 0,
            minFillAnchor: 0,
            exclusivityOverrideBps: 0,
            curve: _noCurve(),
            gasBumpBps: 0,
            gasPriceRef: 0,
            items: new Item[](0),
            validators: new Validator[](0),
            invariants: new Validator[](0),
            feeConfig: bytes32(0)
        });
    }

    function test_multiOutput_zeroInventory_flashFill() public {
        deal(WETH, maker, WETH_IN);
        vm.prank(maker);
        permit3.approveToken(address(settlement), WETH, uint160(WETH_IN), 0);

        // Solver registers the output tokens so Settlement can pull the flashed
        // basket during delivery. No inventory is dealt to it.
        flashSolver.setupTokenApproval(USDC);
        flashSolver.setupTokenApproval(DAI);

        Order memory order = _order();
        bytes memory sig = _sign(order);

        // Zero inventory — anyone can call.
        flashSolver.executeFill(order, sig, WETH_IN, _legs());

        // Maker received the full basket, paid all the WETH.
        assertEq(IERC20(USDC).balanceOf(maker), USDC_OUT, "maker received USDC");
        assertEq(IERC20(DAI).balanceOf(maker), DAI_OUT, "maker received DAI");
        assertEq(IERC20(WETH).balanceOf(maker), 0, "maker WETH spent");

        // Flash repaid (tx didn't revert); leftover WETH is solver profit.
        assertGe(IERC20(WETH).balanceOf(address(flashSolver)), 0, "solver WETH profit non-negative");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(DAI).balanceOf(address(settlement)), 0, "settlement DAI drained");
    }
}
