// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IERC1271} from "@core/interfaces/IERC1271.sol";
import {Order, Item, Validator, OrderSide} from "@core/settlement/UniversalSettlement.sol";
import {UniversalSettlement} from "@core/settlement/UniversalSettlement.sol";

import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

/// @dev EIP-1271 smart-account wallet controlled by a single EOA key — the
///      maker is a contract, signatures come from `owner`'s key.
contract MockMakerWallet is IERC1271 {
    address public immutable owner;

    constructor(address _owner) {
        owner = _owner;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view override returns (bytes4) {
        require(signature.length == 65, "len");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
        if (ecrecover(hash, v, r, s) == owner) return IERC1271.isValidSignature.selector;
        return 0xffffffff;
    }
}

/// @dev Plain swap: the maker sells tokenIn for tokenOut with NO lending items.
/// tokenOut lands directly in the maker's wallet; tokenIn is pulled from the
/// maker and paid to the solver. This is the purest fill — no modules, no Aave,
/// just Permit3-gated token movement — and the cleanest way to exercise the
/// order-level mechanics (partial fills, dutch decay).
///
///   tokenIn  = USDC   (maker gives, solver receives)
///   tokenOut = WETH   (solver gives, maker receives — straight to wallet)
contract PlainSwapTest is CoreSettlementBase {
    /// @dev Maker only needs to let Settlement pull tokenIn; the bare ERC20
    ///      approve to Permit3 is already granted in `setUp`.
    function _approveMakerPlainSwap(uint256 usdcCap) internal {
        vm.prank(maker);
        permit3.approveToken(address(settlement), USDC, uint160(usdcCap), 0);
    }

    function _plainSwapOrder(uint256 nonce, uint256 usdcIn, uint256 wethOut)
        internal
        view
        returns (Order memory)
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

        Order memory order = _plainSwapOrder(0, usdcIn, wethOut);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, usdcIn)[0];

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

        Order memory order = _plainSwapOrder(1, usdcIn, wethOut);
        bytes memory sig = _sign(order);

        // First fill: half the order.
        vm.prank(solver);
        uint256 paid1 = settlement.fill(order, sig, usdcIn / 2)[0];
        assertEq(paid1, wethOut / 2, "first fill pays half the output");
        assertEq(settlement.filled(settlement.hashOrder(order)), usdcIn / 2, "half filled");
        assertEq(settlement.remaining(order), usdcIn / 2, "half remaining");

        // Second fill: the rest. Pro-rata slices accumulate exactly to the totals.
        vm.prank(solver);
        uint256 paid2 = settlement.fill(order, sig, usdcIn - usdcIn / 2)[0];
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
        Order memory order = Order({
            maker: maker,
            side: OrderSide.SELL,
            nonce: 2,
            deadline: block.timestamp + 1 hours,
            tokenIn: _a1(USDC),
            tokenOut: _a1(WETH),
            startAmountIn: _u1(usdcIn),
            endAmountIn: _u1(usdcIn),
            decayStartTime: uint32(block.timestamp),
            decayDuration: 100,
            startAmountOut: _u1(startOut),
            endAmountOut: _u1(endOut),
            exclusiveFiller: address(0),
            exclusivityEndTime: 0,
            minFillAnchor: 0,
            exclusivityOverrideBps: 0,
            curve: _noCurve(),
            gasBumpBps: 0,
            gasPriceRef: 0,
            items: items,
            validators: new Validator[](0),
            invariants: new Validator[](0),
            feeConfig: bytes32(0)
        });
        bytes memory sig = _sign(order);

        // Warp to the auction midpoint → output decays halfway from start to end.
        vm.warp(block.timestamp + 50);
        uint256 expectedOut = startOut - (startOut - endOut) / 2; // 0.9 ether
        assertEq(settlement.previewAmountOut(order)[0], expectedOut, "preview matches midpoint price");

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, usdcIn)[0];

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

        Order memory order = _plainSwapOrder(3, usdcIn, wethOut);

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
        uint256 paid = settlement.fillWithPermit(order, batch, sig, usdcIn)[0];

        assertEq(paid, wethOut, "solver paid exactly wethOut");
        assertEq(IERC20(WETH).balanceOf(maker), wethOut, "maker received WETH in wallet");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver received USDC");
    }

    // ──────────────────── Contract-signer maker (EIP-1271) ────────────────────

    /// @dev The maker is a smart-account wallet. Order verification now falls
    ///      back to EIP-1271, so a contract maker can sell via direct `fill`
    ///      (previously rejected — order sigs were ecrecover-only).
    function test_plain_swap_contractSigner_eip1271() public {
        MockMakerWallet wallet = new MockMakerWallet(maker); // validates makerPk sigs
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;

        deal(USDC, address(wallet), usdcIn);
        deal(WETH, solver, wethOut);

        // Contract maker grants Permit3 the pull + per-token settlement cap.
        vm.startPrank(address(wallet));
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDC, uint160(usdcIn), 0);
        vm.stopPrank();
        _approveSolverSide(wethOut, WETH);

        Order memory order = _order(address(wallet), 0, USDC, WETH, usdcIn, wethOut, new Item[](0));
        bytes memory sig = _sign(order); // signed by makerPk → validated by wallet

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, usdcIn)[0];

        assertEq(paid, wethOut, "solver paid exactly wethOut");
        assertEq(IERC20(WETH).balanceOf(address(wallet)), wethOut, "contract maker received WETH");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver received USDC");
    }

    // ──────────────────── EIP-7702 delegated-1271 maker ────────────────────

    /// @dev A 7702 maker whose delegate implements EIP-1271: the raw recovery
    ///      misses the account address, so verification falls through to the
    ///      delegate's `isValidSignature`. Exercises the 1271-fallback branch
    ///      end-to-end through `fill` for a delegated account.
    function test_plain_swap_eip7702_delegated1271Maker() public {
        MockMakerWallet impl = new MockMakerWallet(maker); // validates makerPk sigs
        address acct = address(0x77020D); // the 7702 account
        vm.etch(acct, address(impl).code); // delegate's 1271 logic runs in acct's context
        vm.label(acct, "7702-delegated-maker");

        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;

        deal(USDC, acct, usdcIn);
        deal(WETH, solver, wethOut);

        // Delegated maker grants Permit3 the pull + per-token settlement cap.
        vm.startPrank(acct);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDC, uint160(usdcIn), 0);
        vm.stopPrank();
        _approveSolverSide(wethOut, WETH);

        Order memory order = _order(acct, 0, USDC, WETH, usdcIn, wethOut, new Item[](0));
        bytes memory sig = _sign(order); // signed by makerPk → validated by delegate code

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, usdcIn)[0];

        assertEq(paid, wethOut, "solver paid exactly wethOut");
        assertEq(IERC20(WETH).balanceOf(acct), wethOut, "7702 delegated maker received WETH");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver received USDC");
    }

    // ──────────────────── EIP-7702 raw-key maker ────────────────────

    /// @dev A 7702 maker carries delegate code but signs with its own key; the
    ///      order signature still recovers to the account address. Confirms the
    ///      shared verifier keeps this path working through `fill`.
    function test_plain_swap_eip7702_rawKeyMaker() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;

        // Delegation designator on the maker EOA: 0xef0100 ‖ delegate address.
        vm.etch(maker, bytes.concat(hex"ef0100", abi.encodePacked(address(0xDE1E6A7E))));
        assertGt(maker.code.length, 0, "maker now carries delegate code");

        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);

        _approveMakerPlainSwap(usdcIn);
        _approveSolverSide(wethOut, WETH);

        Order memory order = _plainSwapOrder(0, usdcIn, wethOut);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, usdcIn)[0];

        assertEq(paid, wethOut, "solver paid exactly wethOut");
        assertEq(IERC20(WETH).balanceOf(maker), wethOut, "7702 maker received WETH");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver received USDC");
    }

    // ──────────────────── Partial fills across DIFFERENT dutch ticks ────────────────────

    /// @dev The realistic dutch flow: fill part early (high price), let the
    ///      auction decay, fill the rest later (lower price). Each fill is priced
    ///      at its OWN tick; the two output slices are independent, not a single
    ///      averaged rate.
    /// @dev Builds a linear-decay swap order: USDC → WETH, decaying startOut →
    ///      endOut over 100s from `block.timestamp`.
    function _dutchSwapOrder(uint256 nonce, uint256 usdcIn, uint256 startOut, uint256 endOut)
        internal
        view
        returns (Order memory)
    {
        return Order({
            maker: maker,
            side: OrderSide.SELL,
            nonce: nonce,
            deadline: block.timestamp + 1 hours,
            tokenIn: _a1(USDC),
            tokenOut: _a1(WETH),
            startAmountIn: _u1(usdcIn),
            endAmountIn: _u1(usdcIn),
            decayStartTime: uint32(block.timestamp),
            decayDuration: 100,
            startAmountOut: _u1(startOut),
            endAmountOut: _u1(endOut),
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

    function test_plain_swap_partialFills_acrossDutchTicks() public {
        uint256 usdcIn = 2_000e6;

        deal(USDC, maker, usdcIn);
        deal(WETH, solver, 1 ether); // enough for the worst case
        _approveMakerPlainSwap(usdcIn);
        _approveSolverSide(1 ether, WETH);

        Order memory order = _dutchSwapOrder(7, usdcIn, 1 ether, 0.8 ether);
        bytes memory sig = _sign(order);

        // First half at t+25 → price 0.95.
        vm.warp(block.timestamp + 25);
        vm.prank(solver);
        uint256 paid1 = settlement.fill(order, sig, usdcIn / 2)[0];
        assertEq(paid1, (usdcIn / 2 * 0.95 ether + usdcIn - 1) / usdcIn, "first half at 0.95 tick");
        assertEq(settlement.remaining(order), usdcIn / 2, "half remaining");

        // Second half at t+75 → price 0.85 (strictly cheaper for the solver).
        vm.warp(block.timestamp + 50);
        vm.prank(solver);
        uint256 paid2 = settlement.fill(order, sig, usdcIn - usdcIn / 2)[0];
        assertEq(paid2, ((usdcIn - usdcIn / 2) * 0.85 ether + usdcIn - 1) / usdcIn, "second half at 0.85 tick");

        assertLt(paid2, paid1, "later fill priced strictly lower");
        assertEq(settlement.remaining(order), 0, "fully filled");
        assertEq(IERC20(WETH).balanceOf(maker), paid1 + paid2, "maker WETH = sum of two ticks");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver paid full USDC across fills");
    }

    // ──────────────────── Exclusive filler fills DURING the window ────────────────────

    /// @dev Positive case: the nominated exclusive filler CAN fill inside the
    ///      window (the blocked/after-window cases are covered elsewhere).
    function test_plain_swap_exclusiveFiller_fillsDuringWindow() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;

        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);
        _approveMakerPlainSwap(usdcIn);
        _approveSolverSide(wethOut, WETH);

        Order memory order = _plainSwapOrder(8, usdcIn, wethOut);
        order.exclusiveFiller = solver;
        order.exclusivityEndTime = uint32(block.timestamp + 100);
        bytes memory sig = _sign(order);

        // Still inside the exclusivity window — the nominated filler fills fine.
        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, usdcIn)[0];
        assertEq(paid, wethOut, "exclusive filler filled during window");
        assertEq(IERC20(WETH).balanceOf(maker), wethOut, "maker received WETH");
    }

    // ──────────────────── Stranded tail (0 < minFill < amountIn) ────────────────────

    /// @dev Documented caveat lock-in: a partial fill can leave a remainder
    ///      smaller than `minFillAmountIn`, which is then permanently unfillable —
    ///      too small to pass the floor, and filling more would over-fill.
    function test_plain_swap_strandedTail_belowMinFill() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;
        uint256 minFill = 1_500e6; // 0 < minFill < amountIn

        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);
        _approveMakerPlainSwap(usdcIn);
        _approveSolverSide(wethOut, WETH);

        Order memory order = _plainSwapOrder(9, usdcIn, wethOut);
        order.minFillAnchor = minFill;
        bytes memory sig = _sign(order);

        // Fill the minimum → leaves a 500e6 tail, below the floor.
        vm.prank(solver);
        settlement.fill(order, sig, minFill);
        uint256 tail = settlement.remaining(order);
        assertEq(tail, usdcIn - minFill, "500 USDC tail remains");

        // The tail can't be filled: below the min-fill floor …
        vm.prank(solver);
        vm.expectRevert(UniversalSettlement.FillTooSmall.selector);
        settlement.fill(order, sig, tail);

        // … and filling the floor amount would over-fill the order.
        vm.prank(solver);
        vm.expectRevert(UniversalSettlement.OverFill.selector);
        settlement.fill(order, sig, minFill);
    }
}
