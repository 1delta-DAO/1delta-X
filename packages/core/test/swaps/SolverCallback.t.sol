// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, Validator} from "@core/settlement/UniversalSettlement.sol";
import {SolverCallbackExecutor} from "@core/settlement/SolverCallbackExecutor.sol";

import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

/// @dev A stand-in liquidity source the solver controls: on the callback it
///      hands the solver the `tokenOut` it is about to owe. Models a flash
///      provider / DEX route sourcing inventory just-in-time.
contract LiquiditySource {
    function supply(address to, address token, uint256 amount) external {
        IERC20(token).transfer(to, amount);
    }
}

/// @dev Coverage for the filler-supplied callback path (Option A):
/// `fillWithCallback` runs a solver-chosen `(target, data)` just before output
/// delivery, through the allowance-less {SolverCallbackExecutor}. Proves:
///   • a ZERO-inventory solver can source `tokenOut` just-in-time and fill;
///   • the same solver WITHOUT the callback cannot (the callback is load-bearing);
///   • the executor isolation defeats the Permit3-drain vector that a
///     Settlement-made call would expose;
///   • the executor rejects callers other than Settlement.
contract SolverCallbackTest is CoreSettlementBase {
    LiquiditySource source;

    uint256 constant USDC_IN = 1_500e6;
    uint256 constant WETH_OUT = 1 ether;

    function setUp() public override {
        super.setUp();
        source = new LiquiditySource();
        vm.label(address(source), "liquiditySource");
        // The source is pre-stocked with the output asset; the solver holds none.
        deal(WETH, address(source), 100 ether);
    }

    function _sellUsdcForWeth(uint256 nonce) internal view returns (Order memory) {
        return _order(maker, nonce, USDC, WETH, USDC_IN, WETH_OUT, new Item[](0));
    }

    // ══════════════════════ JIT inventory (happy path) ══════════════════════

    function test_fillWithCallback_zeroInventorySolver_sourcesOutput() public {
        deal(USDC, maker, USDC_IN);
        _approveMakerToSettlement(USDC, USDC_IN);

        // base `solver` already has WETH/USDC allowances to Settlement but ZERO
        // WETH balance. The callback sources exactly the output it must deliver.
        assertEq(IERC20(WETH).balanceOf(solver), 0, "solver starts with no output inventory");

        Order memory order = _sellUsdcForWeth(0);
        bytes memory sig = _sign(order);
        bytes memory cb = abi.encodeCall(LiquiditySource.supply, (solver, WETH, WETH_OUT));

        vm.prank(solver);
        settlement.fillWithCallback(order, sig, USDC_IN, address(source), cb);

        assertEq(IERC20(WETH).balanceOf(maker), WETH_OUT, "maker received WETH");
        assertEq(IERC20(USDC).balanceOf(solver), USDC_IN, "solver received USDC");
        assertEq(IERC20(WETH).balanceOf(solver), 0, "solver delivered all sourced output");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement drained");
    }

    /// @dev Same zero-inventory solver, but a plain `fill` (no callback) — output
    ///      delivery has nothing to pull, so it reverts. Confirms the callback is
    ///      what makes the zero-inventory fill possible.
    function test_plainFill_zeroInventorySolver_reverts() public {
        deal(USDC, maker, USDC_IN);
        _approveMakerToSettlement(USDC, USDC_IN);

        Order memory order = _sellUsdcForWeth(0);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(); // Permit3 has no WETH to pull from the solver
        settlement.fill(order, sig, USDC_IN);
    }

    // ══════════════════════ Executor isolation defeats Permit3 drain ══════════════════════
    //
    // THE reason the executor exists. A malicious solver points the callback at
    // Permit3 to move a third-party victim's funds. Because the call is made by
    // the allowance-less executor — not Settlement, which the victim DID approve
    // — Permit3 sees no allowance for the caller and reverts. Victim untouched.

    function test_fillWithCallback_cannotDrainViaPermit3() public {
        address victim = makeAddr("victim");
        uint256 victimBal = 5_000e6;
        deal(USDC, victim, victimBal);
        // Victim approved Settlement (as any maker with a live order would).
        vm.startPrank(victim);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDC, type(uint160).max, uint48(block.timestamp + 1 hours));
        vm.stopPrank();

        // A legit maker order the attacker is nominally filling.
        deal(USDC, maker, USDC_IN);
        _approveMakerToSettlement(USDC, USDC_IN);
        deal(WETH, solver, WETH_OUT); // attacker can actually deliver, to isolate the drain as the only failure

        Order memory order = _sellUsdcForWeth(0);
        bytes memory sig = _sign(order);

        // callbackTarget = Permit3, data = drain the victim to the attacker.
        address attacker = solver;
        bytes memory drain = abi.encodeWithSignature(
            "transferFrom(address,address,address,uint160)", victim, attacker, USDC, uint160(victimBal)
        );

        vm.prank(attacker);
        vm.expectRevert(); // executor is not an approved spender → Permit3 reverts → CallbackFailed
        settlement.fillWithCallback(order, sig, USDC_IN, address(permit3), drain);

        assertEq(IERC20(USDC).balanceOf(victim), victimBal, "victim funds untouched");
    }

    // ══════════════════════ Executor caller gate ══════════════════════

    function test_executor_directCall_revertsOnlySettlement() public {
        SolverCallbackExecutor executor = settlement.EXECUTOR();
        assertEq(executor.SETTLEMENT(), address(settlement), "executor bound to settlement");

        bytes memory cb = abi.encodeCall(LiquiditySource.supply, (solver, WETH, WETH_OUT));
        vm.prank(address(0xBAD));
        vm.expectRevert(SolverCallbackExecutor.OnlySettlement.selector);
        executor.execute(address(source), cb);
    }
}
