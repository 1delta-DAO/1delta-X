// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "../shared/PackedEncode.sol";

import {Base} from "@core/settlement/Base.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Settlement, CallbackMode, Order, Item, ItemOp, Validator} from "@core/settlement/Settlement.sol";
import {SettlementLens} from "@core/periphery/SettlementLens.sol";
import {SolverCallbackExecutor} from "@core/settlement/SolverCallbackExecutor.sol";
import {SignatureVerification} from "@core/permit3/SignatureVerification.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";

import {MockSettlementBase, MockERC20} from "../shared/MockSettlementBase.t.sol";

/// @dev A maker module that re-enters Settlement while a fill is mid-flight, to
///      prove the `nonReentrant` guard fires. Re-enters via `batchFill` with
///      empty arrays: the reentrancy modifier reverts BEFORE the (empty) body,
///      so no valid inner order is needed.
contract ReentrantMakerModule is IMakerModule {
    Settlement immutable settlement;

    constructor(Settlement s) {
        settlement = s;
    }

    function makeOnBehalf(address, uint256, bytes calldata) external override {
        settlement.batchFill(new Order[](0), new bytes[](0), new uint256[](0), false);
    }
}

/// @dev Re-enters Settlement from inside a `fillWithCallback` solver callback.
contract ReentrantCallback {
    Settlement immutable settlement;

    constructor(Settlement s) {
        settlement = s;
    }

    function reenter() external {
        settlement.batchFill(new Order[](0), new bytes[](0), new uint256[](0), false);
    }
}

/// @dev A callback target that simply reverts, to prove the executor bubbles a
///      failed callback as `CallbackFailed`.
contract Reverter {
    error Boom();

    function boom() external pure {
        revert Boom();
    }
}

/// @dev A benign callback that funds the solver with output inventory just in
///      time (mirrors SolverCallback.t.sol's LiquiditySource, non-fork).
contract Supplier {
    function supply(address to, address token, uint256 amount) external {
        MockERC20(token).transfer(to, amount);
    }
}

/// @title SettlementGuards
/// @notice Non-fork coverage for the guards that were previously untested at the
///         Settlement boundary: the contract's own reentrancy guard, write-path
///         signature rejection, `fillWithPermit` failure modes, duplicate/zero
///         output legs, exclusivity through `batchFill`, callback-failure
///         bubbling, the overflow-safe preflight, and fork-aware domain
///         separator recomputation.
contract SettlementGuardsTest is MockSettlementBase {
    uint256 constant AMOUNT_IN = 1_000e18;
    uint256 constant AMOUNT_OUT = 2e18;

    Supplier supplier;

    function setUp() public override {
        super.setUp();
        supplier = new Supplier();
    }

    // ──────────────────── funding helpers ────────────────────

    /// @dev Fund + approve both sides for a plain tA→tB order of the given sizes.
    function _fund(uint256 amountIn, uint256 amountOut) internal {
        tA.mint(maker, amountIn);
        _makerApprove(address(settlement), address(tA), amountIn);
        tB.mint(solver, amountOut);
        _solverApprove(address(settlement), address(tB), amountOut);
    }

    // ════════════════════ A. Settlement's own reentrancy guard ════════════════════

    /// @dev A malicious MAKE module re-enters `batchFill` while the outer fill is
    ///      mid-flight. The module call is made directly by Settlement (not the
    ///      executor), so the `Reentrancy` revert bubbles up verbatim.
    function test_reentrancy_viaModule_reverts() public {
        _fund(AMOUNT_IN, AMOUNT_OUT);
        ReentrantMakerModule mod = new ReentrantMakerModule(settlement);

        Order memory order = _plainOrder(1, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.MAKE, module: address(mod), amount: 1, recipient: address(0), data: ""});
        order.items = PackedEncode.items(items);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(Base.Reentrancy.selector);
        settlement.fill(order, sig, AMOUNT_IN);
    }

    /// @dev A `fillWithCallback` callback that re-enters Settlement is blocked too;
    ///      the executor bubbles the inner `Reentrancy` as `CallbackFailed`.
    function test_reentrancy_viaCallback_reverts() public {
        _fund(AMOUNT_IN, AMOUNT_OUT);
        ReentrantCallback rc = new ReentrantCallback(settlement);

        Order memory order = _plainOrder(1, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        bytes memory sig = _sign(order);
        bytes memory cb = abi.encodeCall(ReentrantCallback.reenter, ());

        vm.prank(solver);
        // CallbackFailed carries the inner revert (Reentrancy) as data, so match
        // on the selector only.
        vm.expectPartialRevert(SolverCallbackExecutor.CallbackFailed.selector);
        settlement.fillWithCallback(order, sig, AMOUNT_IN, address(rc), cb, CallbackMode.PreDelivery);
    }

    // ════════════════════ B. Write-path signature rejection ════════════════════

    function test_fill_wrongSigner_reverts() public {
        _fund(AMOUNT_IN, AMOUNT_OUT);
        Order memory order = _plainOrder(1, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        bytes memory badSig = _signWith(order, solverPk); // not the maker's key

        vm.prank(solver);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        settlement.fill(order, badSig, AMOUNT_IN);
    }

    function test_fill_tamperedOrder_reverts() public {
        _fund(AMOUNT_IN, AMOUNT_OUT);
        Order memory order = _plainOrder(1, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        bytes memory sig = _sign(order);
        // Tamper after signing: the maker never authorised this cheaper output.
        order.legsOut = PackedEncode.setLegOutStart(order.legsOut, 0, AMOUNT_OUT / 2);

        vm.prank(solver);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        settlement.fill(order, sig, AMOUNT_IN);
    }

    function test_fillWithCallback_wrongSigner_reverts() public {
        _fund(AMOUNT_IN, AMOUNT_OUT);
        Order memory order = _plainOrder(1, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        bytes memory badSig = _signWith(order, solverPk);
        bytes memory cb = abi.encodeCall(Supplier.supply, (solver, address(tB), AMOUNT_OUT));

        vm.prank(solver);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        settlement.fillWithCallback(order, badSig, AMOUNT_IN, address(supplier), cb, CallbackMode.PreDelivery);
    }

    // ════════════════════ C. fillWithPermit failure modes ════════════════════

    /// @dev Maker's ERC20→Permit3 approval only (the Permit3 allowance itself is
    ///      granted by the signed batch), plus a funded solver output side.
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

    function test_fillWithPermit_happy() public {
        _fundPermitSide(AMOUNT_IN, AMOUNT_OUT);
        Order memory order = _plainOrder(1, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        (IPermit3.PermitBatch memory batch, bytes memory sig) =
            _permitFor(order, AMOUNT_IN, 1, block.timestamp + 1 hours);

        vm.prank(solver);
        settlement.fillWithPermit(order, batch, sig, AMOUNT_IN);
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "maker got output");
        assertEq(tA.balanceOf(solver), AMOUNT_IN, "solver got input");
    }

    function test_fillWithPermit_expiredPermit_reverts() public {
        _fundPermitSide(AMOUNT_IN, AMOUNT_OUT);
        vm.warp(block.timestamp + 2 hours);
        Order memory order = _plainOrder(1, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        // Permit batch deadline already in the past.
        (IPermit3.PermitBatch memory batch, bytes memory sig) = _permitFor(order, AMOUNT_IN, 1, block.timestamp - 1);

        vm.prank(solver);
        vm.expectRevert(IPermit3.PermitExpired.selector);
        settlement.fillWithPermit(order, batch, sig, AMOUNT_IN);
    }

    function test_fillWithPermit_insufficientAllowance_reverts() public {
        _fundPermitSide(AMOUNT_IN, AMOUNT_OUT);
        Order memory order = _plainOrder(1, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        // Batch grants only half the allowance the full fill needs.
        (IPermit3.PermitBatch memory batch, bytes memory sig) =
            _permitFor(order, AMOUNT_IN / 2, 1, block.timestamp + 1 hours);

        // The maker's tokenIn pull exceeds the granted Permit3 allowance. Delivery
        // legs use the direct-approval fallback (Euler EVK pattern), so the Permit3
        // InsufficientAllowance is caught and a plain transferFrom is attempted;
        // the maker granted no direct approval either, so the terminal revert is
        // the fallback's TransferFromFailed and the whole fill unwinds.
        vm.prank(solver);
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        settlement.fillWithPermit(order, batch, sig, AMOUNT_IN);
    }

    /// @dev S-1: the idempotent permit path makes `fillWithPermit` partial-fillable
    ///      with ONE signature. The first fill applies the batch (granting the full
    ///      Permit3 allowance) and consumes half; the second re-presents the same
    ///      signed batch, finds nonce 7 already spent, SKIPS the re-grant, and draws
    ///      the remainder against the standing allowance — no revert. Before the fix
    ///      the second fill reverted {PermitNonceUsed} and the order was stuck.
    function test_fillWithPermit_partialFillsReuseOneSignature() public {
        _fundPermitSide(AMOUNT_IN, AMOUNT_OUT);
        Order memory order = _plainOrder(1, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        (IPermit3.PermitBatch memory batch, bytes memory sig) =
            _permitFor(order, AMOUNT_IN, 7, block.timestamp + 1 hours);

        vm.prank(solver);
        settlement.fillWithPermit(order, batch, sig, AMOUNT_IN / 2);

        // Same signed batch again — the spent nonce is skipped, not reverted.
        vm.prank(solver);
        settlement.fillWithPermit(order, batch, sig, AMOUNT_IN / 2);

        assertEq(tA.balanceOf(solver), AMOUNT_IN, "solver received the whole input across two fills");
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "maker received the whole output");
    }

    function test_fillWithPermit_wrongWitnessOrder_reverts() public {
        _fundPermitSide(AMOUNT_IN, AMOUNT_OUT);
        Order memory signedOrder = _plainOrder(1, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        (IPermit3.PermitBatch memory batch, bytes memory sig) =
            _permitFor(signedOrder, AMOUNT_IN, 1, block.timestamp + 1 hours);

        // Present a DIFFERENT order than the witness bound: the recovered signer
        // no longer matches the maker.
        Order memory otherOrder = _plainOrder(1, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT / 2);

        vm.prank(solver);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        settlement.fillWithPermit(otherOrder, batch, sig, AMOUNT_IN);
    }

    function test_fillWithPermit_wrongSigner_reverts() public {
        _fundPermitSide(AMOUNT_IN, AMOUNT_OUT);
        Order memory order = _plainOrder(1, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        IPermit3.TokenPermit[] memory tp =
            _tokenPermit1(address(settlement), address(tA), AMOUNT_IN, uint48(block.timestamp + 1 hours));
        IPermit3.PermitBatch memory batch = _buildBatch(tp, 1, block.timestamp + 1 hours);
        // Sign with the wrong key.
        bytes memory sig = _signPermitWitnessWith(batch, _hashOrder(order), solverPk);

        vm.prank(solver);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        settlement.fillWithPermit(order, batch, sig, AMOUNT_IN);
    }

    // ════════════════════ D. Duplicate / zero output legs ════════════════════

    /// @dev A signed order with a duplicated tokenOut is not enforced against at
    ///      fill time (validateOrder flags it, but fills are unopinionated). It
    ///      settles by delivering BOTH legs — only the maker/solver are affected,
    ///      no protocol invariant breaks.
    function test_fill_duplicateTokenOut_deliversBothLegs() public {
        uint256 outA = 1e18;
        uint256 outB = 3e18;
        tA.mint(maker, AMOUNT_IN);
        _makerApprove(address(settlement), address(tA), AMOUNT_IN);
        tB.mint(solver, outA + outB);
        _solverApprove(address(settlement), address(tB), outA + outB);

        address[] memory tokenOut = new address[](2);
        tokenOut[0] = address(tB);
        tokenOut[1] = address(tB);
        uint256[] memory amountOut = new uint256[](2);
        amountOut[0] = outA;
        amountOut[1] = outB;

        Order memory order = _plainOrderMultiOut(1, address(tA), AMOUNT_IN, tokenOut, amountOut);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        uint256[] memory outs = settlement.fill(order, sig, AMOUNT_IN);
        assertEq(outs[0], outA);
        assertEq(outs[1], outB);
        assertEq(tB.balanceOf(maker), outA + outB, "maker received both legs");
        assertEq(tA.balanceOf(solver), AMOUNT_IN, "solver got input");
    }

    /// @dev A zero-priced output leg (start==end==0) is skipped by the `amt != 0`
    ///      guard in `_deliverOutputs` — no transfer, and the rest of the order
    ///      settles normally.
    function test_fill_zeroOutputLeg_skipped() public {
        uint256 outReal = 2e18;
        tA.mint(maker, AMOUNT_IN);
        _makerApprove(address(settlement), address(tA), AMOUNT_IN);
        tB.mint(solver, outReal);
        _solverApprove(address(settlement), address(tB), outReal);

        address[] memory tokenOut = new address[](2);
        tokenOut[0] = address(tC); // zero-priced leg
        tokenOut[1] = address(tB);
        uint256[] memory amountOut = new uint256[](2);
        amountOut[0] = 0;
        amountOut[1] = outReal;

        Order memory order = _plainOrderMultiOut(1, address(tA), AMOUNT_IN, tokenOut, amountOut);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        uint256[] memory outs = settlement.fill(order, sig, AMOUNT_IN);
        assertEq(outs[0], 0, "zero leg delivered nothing");
        assertEq(outs[1], outReal, "real leg delivered");
        assertEq(tC.balanceOf(maker), 0, "no tC moved");
        assertEq(tB.balanceOf(maker), outReal, "maker got real output");
    }

    // ════════════════════ E. Exclusivity through batchFill ════════════════════

    /// @dev batchFill threads the real filler (msg.sender) into each fill, so an
    ///      exclusivity-gated order fills for the nominated filler and is skipped
    ///      (not reverted) for a different one when revertIfIncomplete=false.
    function test_batchFill_exclusivity_threadsFiller() public {
        tA.mint(maker, 2 * AMOUNT_IN);
        _makerApprove(address(settlement), address(tA), 2 * AMOUNT_IN);
        tB.mint(solver, 2 * AMOUNT_OUT);
        _solverApprove(address(settlement), address(tB), 2 * AMOUNT_OUT);

        Order memory mine = _plainOrder(1, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        mine.exclusiveFiller = solver; // solver is the batch caller
        _setExclusivityEnd(mine, uint32(block.timestamp + 100));

        Order memory theirs = _plainOrder(2, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        theirs.exclusiveFiller = address(0xE); // someone else
        _setExclusivityEnd(theirs, uint32(block.timestamp + 100));

        Order[] memory orders = new Order[](2);
        orders[0] = mine;
        orders[1] = theirs;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(mine);
        sigs[1] = _sign(theirs);
        uint256[] memory amts = new uint256[](2);
        amts[0] = AMOUNT_IN;
        amts[1] = AMOUNT_IN;

        vm.prank(solver);
        (, bool[] memory success) = settlement.batchFill(orders, sigs, amts, false);

        assertTrue(success[0], "exclusive filler filled own order");
        assertFalse(success[1], "non-exclusive order skipped, not reverted");
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "only the fillable order delivered");
    }

    // ════════════════════ F. Callback failure bubbling ════════════════════

    function test_fillWithCallback_revertingCallback_bubblesCallbackFailed() public {
        _fund(AMOUNT_IN, AMOUNT_OUT);
        Reverter rev = new Reverter();
        Order memory order = _plainOrder(1, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        bytes memory sig = _sign(order);
        bytes memory cb = abi.encodeCall(Reverter.boom, ());

        vm.prank(solver);
        vm.expectPartialRevert(SolverCallbackExecutor.CallbackFailed.selector);
        settlement.fillWithCallback(order, sig, AMOUNT_IN, address(rev), cb, CallbackMode.PreDelivery);
    }

    // ════════════════════ G. Overflow-safe preflight (finding #1) ════════════════════

    /// @dev A max allowance × huge amountIn overflows the units rescale in
    ///      `_makerFillableCap`. The (singular) preflight must NOT revert on it —
    ///      it treats the overflowing leg as non-binding and reports Fillable.
    function test_getOrderRelevantState_hugeAmount_doesNotRevert() public {
        uint256 huge = 10 ** 40; // amountIn0 large enough that max-allowance × it overflows uint256
        tA.mint(maker, type(uint256).max);
        _makerApprove(address(settlement), address(tA), type(uint160).max);

        Order memory order = _plainOrder(1, address(tA), address(tB), huge, AMOUNT_OUT);
        bytes memory sig = _sign(order);

        (SettlementLens.OrderStatus status, uint256 fillable, bool sigValid,) =
            lens.getOrderRelevantState(order, sig, solver, "");

        assertEq(uint256(status), uint256(SettlementLens.OrderStatus.Fillable), "still fillable");
        assertEq(fillable, huge, "overflowing leg treated as non-binding");
        assertTrue(sigValid, "signature valid");
    }

    // ════════════════════ H. Fork-aware domain separator (finding #2) ════════════════════

    function test_domainSeparator_recomputesOnChainIdChange() public {
        bytes32 before = settlement.DOMAIN_SEPARATOR();
        vm.chainId(block.chainid + 1);
        bytes32 afterId = settlement.DOMAIN_SEPARATOR();
        assertTrue(before != afterId, "domain separator rebound to new chain id");

        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Settlement"),
                keccak256("1"),
                block.chainid,
                address(settlement)
            )
        );
        assertEq(afterId, expected, "recomputed with the live chain id");
    }

    /// @dev A signature made under the pre-fork domain no longer verifies after a
    ///      chain-id change (replay protection), while a fresh signature does.
    function test_fill_signatureBoundToChainId() public {
        _fund(AMOUNT_IN, AMOUNT_OUT);
        Order memory order = _plainOrder(1, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        bytes memory oldSig = _sign(order); // signed under the current domain

        vm.chainId(block.chainid + 1);

        // Old-domain signature is now invalid.
        vm.prank(solver);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        settlement.fill(order, oldSig, AMOUNT_IN);

        // A signature over the new domain fills fine.
        bytes memory newSig = _sign(order);
        vm.prank(solver);
        settlement.fill(order, newSig, AMOUNT_IN);
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "maker got output under new domain");
    }
}
