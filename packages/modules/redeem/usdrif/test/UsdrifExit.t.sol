// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Base} from "@core/settlement/Base.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Settlement, Order, OrderSide, Item, Validator, LegIn, LegOut} from "@core/settlement/Settlement.sol";

import {UsdrifForkBase} from "./shared/UsdrifForkBase.t.sol";
import {RedemptionSettledValidator} from "../src/RedemptionSettledValidator.sol";
import {DepegGuardValidator} from "../src/DepegGuardValidator.sol";
import {IMocRif, IMocQueue} from "../src/interfaces/IMoc.sol";

/// @dev End-to-end USDRIF→USDT0 exit on a Rootstock fork — the plan's variant 1
/// ("the settlement needs no new module at all"):
///   STEP 1  user calls MoC redeemTP directly (recipient = user) → queues an op
///   (executor) the MoC queue executes → RIF lands in the user's wallet
///   STEP 2  a solver fills the signed RIF→USDT0 limit order (a clean swap)
///
/// MoC's `redeemTP` enforces `recipient == msg.sender`, so the redemption must be
/// initiated by the user's own account (a pass-through helper contract could only
/// redeem to itself — that's the plan's variant-2 escrow, out of scope here). The
/// repo's contribution is the two order validators, exercised below.
///
/// Covers the plan's must-pass matrix (§9): fill reverts before settlement (via
/// the validator AND via the implicit Permit3 RIF pull), fill succeeds after
/// settlement, and the depeg guard gates fills by the live RIF price band.
contract UsdrifExitTest is UsdrifForkBase {
    uint256 constant USDRIF_IN = 1_000e18; //  $1000 of USDRIF
    uint256 constant QAC_MIN = 1e18; //         conservative RIF floor for the redeem

    RedemptionSettledValidator settledValidator;
    DepegGuardValidator depegValidator;

    function setUp() public override {
        super.setUp();
        settledValidator = new RedemptionSettledValidator(RIF);
        depegValidator = new DepegGuardValidator();
    }

    // ──────────────────── Step 1: user redeems USDRIF → RIF directly ────────────────────

    function _initiateRedemption() internal returns (uint256 opId) {
        deal(USDRIF, maker, USDRIF_IN);
        // MoC requires msg.value == execCost × block.basefee (RSK's minimumGasPrice
        // via RSKIP-412 BASEFEE). Forge forks default basefee to 0 — pin the real
        // ~0.024 gwei minimum so the fee is non-zero and `getExecFee` reflects it.
        vm.fee(0.024 gwei);
        uint256 fee = IMocQueue(MOC_QUEUE).getExecFee(OPER_REDEEM_TP);
        vm.deal(maker, fee);

        vm.startPrank(maker);
        IERC20(USDRIF).approve(MOC_CORE, USDRIF_IN);
        // recipient == msg.sender (maker) — required by MoC.
        opId = IMocRif(MOC_CORE).redeemTP{value: fee}(USDRIF, USDRIF_IN, QAC_MIN, maker, address(0));
        vm.stopPrank();
    }

    /// @dev Build the exit order RIF→USDT0 (fixed price) with the given validators.
    function _exitOrder(uint256 nonce, uint256 amountIn, uint256 amountOut, Validator[] memory validators)
        internal
        view
        returns (Order memory)
    {
        return Order({
            maker: maker,
            nonce: nonce,
            deadline: block.timestamp + 1 hours,
            legsIn: _legsIn1(RIF, amountIn),
            legsOut: _legsOut1(USDT0, amountOut),
            timing: 0,
            exclusiveFiller: address(0),
            minFillAnchor: 0,
            exclusivityOverrideBps: 0,
            curve: _noCurve(),
            gasBumpBps: 0,
            gasPriceRef: 0,
            items: PackedEncode.noItems(),
            validators: PackedEncode.validators(validators),
            invariants: PackedEncode.noValidators(),
            fillModule: address(0),
            fillTotal: 0
        });
    }

    function _approveExitSides(uint256 rifIn, uint256 usdtOut) internal {
        // Maker lets Settlement pull the redeemed RIF.
        vm.startPrank(maker);
        IERC20(RIF).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), RIF, uint160(rifIn), 0);
        vm.stopPrank();
        // Solver funds + lets Settlement pull the USDT0 it pays the maker.
        deal(USDT0, solver, usdtOut);
        vm.startPrank(solver);
        IERC20(USDT0).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDT0, uint160(usdtOut), 0);
        vm.stopPrank();
    }

    function _settledData(uint256 opId, uint256 minRif) internal view returns (bytes memory) {
        return abi.encode(MOC_QUEUE, opId, maker, minRif);
    }

    // ──────────────────── Tests ────────────────────

    /// Sanity: the redemption mechanics work on the fork — RIF is delivered to
    /// the maker after the queue executes, and the op is marked settled.
    function test_redemption_deliversRif() public {
        uint256 opId = _initiateRedemption();

        assertEq(IERC20(RIF).balanceOf(maker), 0, "no RIF before execution");
        assertLe(IMocQueue(MOC_QUEUE).firstOperId(), opId, "op still pending");

        _executeQueue();

        assertGt(IMocQueue(MOC_QUEUE).firstOperId(), opId, "op settled (dequeued)");
        assertGt(IERC20(RIF).balanceOf(maker), QAC_MIN, "RIF delivered above floor");
    }

    /// Full happy path: redeem → execute → solver fills the RIF→USDT0 order.
    function test_exit_succeedsAfterSettlement() public {
        uint256 opId = _initiateRedemption();
        _executeQueue();

        uint256 rifIn = IERC20(RIF).balanceOf(maker); //   sell the full realized RIF
        uint256 usdtOut = 950e6; //                         seller's USDT0 floor (~par − 5%)

        _approveExitSides(rifIn, usdtOut);

        Validator[] memory validators = new Validator[](1);
        validators[0] = Validator({target: address(settledValidator), data: _settledData(opId, rifIn)});

        Order memory order = _exitOrder(1, rifIn, usdtOut, validators);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, rifIn)[0];

        assertEq(paid, usdtOut, "solver paid the seller's USDT0 floor");
        assertEq(IERC20(USDT0).balanceOf(maker), usdtOut, "seller exited to USDT0");
        assertEq(IERC20(RIF).balanceOf(maker), 0, "seller's RIF fully sold");
        assertEq(IERC20(RIF).balanceOf(solver), rifIn, "solver received the RIF");
        assertEq(IERC20(RIF).balanceOf(address(settlement)), 0, "settlement RIF drained");
        assertEq(IERC20(USDT0).balanceOf(address(settlement)), 0, "settlement USDT0 drained");
    }

    /// The RedemptionSettledValidator blocks fills before the redemption settles.
    function test_exit_revertsBeforeSettlement_viaValidator() public {
        uint256 opId = _initiateRedemption(); // queue NOT executed → still pending, no RIF

        uint256 rifIn = 100e18;
        uint256 usdtOut = 950e6;
        _approveExitSides(rifIn, usdtOut);

        Validator[] memory validators = new Validator[](1);
        validators[0] = Validator({target: address(settledValidator), data: _settledData(opId, rifIn)});

        Order memory order = _exitOrder(2, rifIn, usdtOut, validators);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.ValidationFailed.selector, uint256(0)));
        settlement.fill(order, sig, rifIn);
    }

    /// Even without the validator, the fill cannot land before settlement: the
    /// Permit3 RIF pull reverts because the maker holds no RIF yet.
    function test_exit_revertsBeforeSettlement_viaPermit3Pull() public {
        _initiateRedemption(); // queue NOT executed

        uint256 rifIn = 100e18;
        uint256 usdtOut = 950e6;
        _approveExitSides(rifIn, usdtOut);

        Order memory order = _exitOrder(3, rifIn, usdtOut, new Validator[](0));
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(); // RIF transferFrom fails — maker has 0 RIF
        settlement.fill(order, sig, rifIn);
    }

    /// DepegGuardValidator blocks fills when the RIF price is outside the band.
    function test_depegGuard_blocksOutOfBand() public {
        uint256 opId = _initiateRedemption();
        _executeQueue();

        uint256 rifIn = IERC20(RIF).balanceOf(maker);
        uint256 usdtOut = 950e6;
        _approveExitSides(rifIn, usdtOut);

        Validator[] memory validators = new Validator[](2);
        validators[0] = Validator({target: address(settledValidator), data: _settledData(opId, rifIn)});
        // Absurd band far above the live RIF price (~6.85e16) → out of band.
        validators[1] = Validator({
            target: address(depegValidator), data: abi.encode(MOC_PRICE_PROVIDER, uint256(1e18), uint256(2e18))
        });

        Order memory order = _exitOrder(4, rifIn, usdtOut, validators);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.ValidationFailed.selector, uint256(1)));
        settlement.fill(order, sig, rifIn);
    }

    /// DepegGuardValidator allows fills when the RIF price is inside the band.
    function test_depegGuard_passesInBand() public {
        uint256 opId = _initiateRedemption();
        _executeQueue();

        uint256 rifIn = IERC20(RIF).balanceOf(maker);
        uint256 usdtOut = 950e6;
        _approveExitSides(rifIn, usdtOut);

        Validator[] memory validators = new Validator[](2);
        validators[0] = Validator({target: address(settledValidator), data: _settledData(opId, rifIn)});
        // Wide band that brackets the live RIF price.
        validators[1] = Validator({
            target: address(depegValidator), data: abi.encode(MOC_PRICE_PROVIDER, uint256(1e16), uint256(1e18))
        });

        Order memory order = _exitOrder(5, rifIn, usdtOut, validators);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, rifIn)[0];
        assertEq(paid, usdtOut, "in-band fill succeeds");
        assertEq(IERC20(USDT0).balanceOf(maker), usdtOut, "seller exited to USDT0");
    }
}
