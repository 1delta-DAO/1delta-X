// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Settlement, Order} from "@core/settlement/Settlement.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {SignatureVerification} from "@core/permit3/SignatureVerification.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";

import {MockSettlementBase, MockERC20} from "../shared/MockSettlementBase.t.sol";

/// @dev Two ITakerModules with the SAME `data` layout — the ref-collision PoC.
contract TakerA is ITakerModule {
    event Took(string which, address user, uint256 amount, address to);

    function takeOnBehalf(address user, uint256 amount, address receiver, bytes calldata) external override {
        emit Took("A", user, amount, receiver);
    }
}

contract TakerB is ITakerModule {
    event Took(string which, address user, uint256 amount, address to);

    function takeOnBehalf(address user, uint256 amount, address receiver, bytes calldata) external override {
        emit Took("B", user, amount, receiver);
    }
}

/// @title AuditPermit3PoC
/// @notice Throwaway PoCs written during the 2026-08 Permit3 audit.
contract AuditPermit3PoCTest is MockSettlementBase {
    uint256 constant AMOUNT_IN = 1_000e18;
    uint256 constant AMOUNT_OUT = 2e18;

    function _fundPermitSide(uint256 amountIn, uint256 amountOut) internal {
        tA.mint(maker, amountIn);
        vm.prank(maker);
        tA.approve(address(permit3), type(uint256).max);
        tB.mint(solver, amountOut);
        _solverApprove(address(settlement), address(tB), amountOut);
    }

    function _permitFor(Order memory order, uint256 allowance, uint256 permitNonce, uint256 deadline)
        internal
        view
        returns (IPermit3.PermitBatch memory batch, bytes memory sig)
    {
        IPermit3.TokenPermit[] memory tp =
            _tokenPermit1(address(settlement), address(tA), allowance, uint48(block.timestamp + 1 hours));
        batch = _buildBatch(tp, permitNonce, deadline);
        sig = _signPermitWitness(batch, _hashOrder(order));
    }

    // ═════════ S-1 regression: front-running the permit no longer bricks the order ═════════

    function test_s1_permitFrontRunDoesNotBrickOrder() public {
        _fundPermitSide(AMOUNT_IN, AMOUNT_OUT);
        Order memory order = _plainOrder(1, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        (IPermit3.PermitBatch memory batch, bytes memory sig) =
            _permitFor(order, AMOUNT_IN, 42, block.timestamp + 1 hours);

        // The griefer copies (batch, sig, orderHash) straight out of the pending
        // fillWithPermit calldata and lands the permit itself — burning nonce 42.
        address griefer = address(0xBADBAD);
        vm.prank(griefer);
        permit3.permitBatchWithWitness(
            maker,
            batch,
            _hashOrder(order),
            "Order witness)"
            "Order(address maker,uint256 nonce,bytes legsIn,bytes legsOut,uint256 timing,address exclusiveFiller,uint256 minFillAnchor,uint256 params,bytes curve,bytes items,bytes validators,bytes invariants,address fillModule,uint256 fillTotal,address pricingModule)"
            "TakerPermit(address spender,address module,bytes32 ref,uint160 amount,uint48 expiration)"
            "TokenPermit(address spender,address token,uint160 amount,uint48 expiration)",
            sig
        );
        assertTrue(permit3.isPermitNonceUsed(maker, 42), "griefer spent the nonce");

        // The fill still goes through: fillWithPermit routes through the IDEMPOTENT
        // permit path, which re-verifies the signature, sees the nonce already
        // spent, skips the (already-applied) grant, and settles against the standing
        // allowance the griefer's call left behind.
        vm.prank(solver);
        settlement.fillWithPermit(order, batch, sig, AMOUNT_IN);

        assertEq(tA.balanceOf(solver), AMOUNT_IN, "solver received the input");
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "maker received the output");
    }

    // ═════════ S-2 regression: the taker allowance now binds the module ═════════

    function test_s2_takerRefIsModuleBound() public {
        TakerA a = new TakerA();
        TakerB b = new TakerB();

        // Same `data` bytes → same ref, whatever the module.
        bytes memory data = abi.encode(address(0xC0FFEE));
        bytes32 ref = permit3.refFor(data);

        // Maker intends "module A may pull 1000 on my behalf, via this spender".
        vm.prank(maker);
        permit3.approveTaker(address(this), address(a), ref, 1_000, uint48(block.timestamp + 1 days));

        // Dispatching module B against the SAME ref finds no allowance under
        // (maker, this, B, ref) and reverts — the grant is module-scoped now.
        vm.expectRevert(abi.encodeWithSelector(IPermit3.InsufficientAllowance.selector, uint160(0)));
        permit3.take(address(b), maker, 1_000, address(this), data);

        // Module A — the one that was approved — still works.
        permit3.take(address(a), maker, 1_000, address(this), data);
        (uint160 left,) = permit3.takerAllowance(maker, address(this), address(a), ref);
        assertEq(left, 0, "module A consumed exactly its own allowance");
    }

    // ═════════ S-3 regression: zero-amount transferFrom is rejected ═════════

    function test_s3_zeroAmountTransferFromRejected() public {
        Probe p = new Probe();
        address rando = address(0xF00D);
        // Previously this landed against an empty allowance (spend(_, 0) never
        // reverts); now the explicit guard stops it before any external call.
        vm.prank(rando);
        vm.expectRevert(IPermit3.ZeroAmount.selector);
        permit3.transferFrom(maker, address(0xdead), address(p), 0);
        assertEq(p.callerSeen(), address(0), "Probe was never called");
    }
}

/// @dev Answers `transferFrom(address,address,uint256)` with `true` and records
///      who called it — stands in for any contract that gates on
///      `msg.sender == permit3`.
contract Probe {
    address public callerSeen;

    function transferFrom(address, address, uint256) external returns (bool) {
        callerSeen = msg.sender;
        return true;
    }
}
