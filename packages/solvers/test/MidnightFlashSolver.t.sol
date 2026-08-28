// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, LegIn} from "@core/settlement/Settlement.sol";
import {BaseFlashSolver} from "@solvers/base/BaseFlashSolver.sol";
import {MidnightFlashSolver} from "@solvers/single-input/MidnightFlashSolver.sol";

import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";

interface IMidnightFlashLoanReceiver {
    function onFlashLoan(address caller, address[] calldata tokens, uint256[] calldata assets, bytes calldata data)
        external
        returns (bytes32);
}

/// @dev Stand-in for the Morpho Midnight singleton's flash-loan surface, matching
///      `morpho-org/midnight` and the mock the modules-morpho-midnight suite uses:
///      push each `assets[i]`, invoke the callback, require the success sentinel,
///      then pull each amount back via `transferFrom` — no fee.
///
///      Midnight is not deployed at a pinned mainnet address the way Balancer /
///      Aave / Morpho Blue are, so the provider is mocked while EVERYTHING else in
///      this suite is real forked mainnet: Settlement, Permit3, WETH, USDC and the
///      Uniswap v3 router the repayment swap routes through.
///
///      Records what it was called with so the tests can pin the solver's side of
///      the ABI (single-element arrays) and the exact sentinel it returns.
contract MidnightFlashMock {
    bytes32 public constant CALLBACK_SUCCESS = keccak256("morpho.midnight.callbackSuccess");

    address[] public lastTokens;
    uint256[] public lastAssets;
    bytes32 public lastReturn;

    function flashLoan(address[] calldata tokens, uint256[] calldata assets, address callback, bytes calldata data)
        external
    {
        lastTokens = tokens;
        lastAssets = assets;

        for (uint256 i; i < tokens.length; i++) {
            IERC20(tokens[i]).transfer(callback, assets[i]);
        }

        lastReturn = IMidnightFlashLoanReceiver(callback).onFlashLoan(msg.sender, tokens, assets, data);
        require(lastReturn == CALLBACK_SUCCESS, "bad-callback");

        // Fee-free: exactly what was lent is pulled back.
        for (uint256 i; i < tokens.length; i++) {
            IERC20(tokens[i]).transferFrom(callback, address(this), assets[i]);
        }
    }

    function lastTokensLength() external view returns (uint256) {
        return lastTokens.length;
    }
}

/// @dev Coverage for {MidnightFlashSolver}, the last member of the
/// `BaseFlashSolver` family that had none. The other single-input solvers are
/// exercised by the modules-aave-v3 `FlashProviders` suite against their real
/// mainnet providers; Midnight has no such address, so the provider is mocked and
/// everything else stays real.
///
/// The fill is a zero-inventory single-output flash: the maker sells USDC for
/// WETH, the solver owns neither, and it
///
///   1. flashes the WETH output from Midnight,
///   2. lets Settlement pull that WETH (Permit3) and deliver it to the maker,
///      routing the maker's USDC back to the solver,
///   3. swaps the USDC → WETH on Uniswap v3 and approves Midnight to pull the
///      flash back on return,
///   4. sweeps the leftover WETH to the caller.
///
/// Covered: the happy loop and its fund flow, the single-element array the solver
/// hands Midnight, the exact `CALLBACK_SUCCESS` sentinel, no surviving allowance
/// or residue, and the four revert paths (`OnlyMidnight`, `NotInFlash`,
/// `MultiInputUnsupported`, `FlashLoanNotRepaid`) plus the swap slippage bound.
///
/// Note there is no `FlashCallbackMissing` case to test here: `midnight` is an
/// immutable pinned at construction, not a per-call argument, so the
/// `_armProvider` / `_requireCallbackRan` machinery that guards the per-call
/// providers does not apply.
contract MidnightFlashSolverTest is CoreSettlementBase {
    /// @dev Uniswap v3 SwapRouter (mainnet) — the repayment-swap venue.
    address constant UNI_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    /// @dev At the pinned fork block 1 WETH costs ~2143 USDC, so 2600 USDC buys
    ///      ~1.21 WETH: comfortably above the 1 WETH flash, with the remainder
    ///      landing as the caller's profit.
    uint256 constant USDC_IN = 2_600e6;
    uint256 constant WETH_OUT = 1 ether;

    MidnightFlashSolver flashSolver;
    MidnightFlashMock midnight;

    function setUp() public override {
        super.setUp();
        midnight = new MidnightFlashMock();
        flashSolver = new MidnightFlashSolver(address(permit3), address(settlement), address(midnight), UNI_ROUTER);
        vm.label(address(midnight), "midnight");
        vm.label(address(flashSolver), "midnightFlashSolver");

        // The flash source needs inventory to lend.
        deal(WETH, address(midnight), 10 ether);
    }

    function _order() internal view returns (Order memory) {
        return _sellOrder(0, maker, USDC, WETH, USDC_IN, WETH_OUT, new Item[](0));
    }

    /// @dev Maker funded + approved, solver registered for the output token. No
    ///      inventory is ever dealt to the solver.
    function _prepare(uint256 usdcIn) internal {
        deal(USDC, maker, usdcIn);
        _approveMakerToSettlement(USDC, usdcIn);
        flashSolver.setupTokenApproval(WETH);
    }

    // ══════════════════════ Happy path ══════════════════════

    function test_midnight_zeroInventory_flashFill() public {
        _prepare(USDC_IN);

        Order memory order = _order();
        bytes memory sig = _sign(order);

        uint256 midnightWethBefore = IERC20(WETH).balanceOf(address(midnight));

        flashSolver.executeFill(WETH, WETH_OUT, order, sig, USDC_IN, 500, 0);

        // Maker got the whole output leg and paid the whole input leg.
        assertEq(IERC20(WETH).balanceOf(maker), WETH_OUT, "maker received WETH");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "maker USDC spent");

        // Flash repaid in full, fee-free — the provider is exactly whole again.
        assertEq(IERC20(WETH).balanceOf(address(midnight)), midnightWethBefore, "flash repaid, no fee");

        // The approve-pull repayment leaves nothing standing behind it.
        assertEq(IERC20(WETH).allowance(address(flashSolver), address(midnight)), 0, "no surviving allowance");

        // Profit-residue rule (same as the rest of the family): the permissionless
        // solver keeps NO balance between fills — the surplus goes to the caller —
        // so a later attacker-crafted order cannot drain residue through the
        // standing max Permit3 allowance `setupTokenApproval` leaves.
        assertEq(IERC20(WETH).balanceOf(address(flashSolver)), 0, "no WETH residue in solver");
        assertEq(IERC20(USDC).balanceOf(address(flashSolver)), 0, "solver USDC fully swapped");
        assertGt(IERC20(WETH).balanceOf(address(this)), 0, "surplus swept to the caller");

        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
    }

    /// @dev Midnight's flash surface is multi-token; this solver borrows one asset,
    ///      so it must wrap the collateral in a one-element array. Pin that, and pin
    ///      the sentinel `onFlashLoan` returns — a wrong constant would make every
    ///      real Midnight flash revert `bad-callback`.
    function test_midnight_callShape_singleAssetAndSentinel() public {
        _prepare(USDC_IN);

        Order memory order = _order();
        flashSolver.executeFill(WETH, WETH_OUT, order, _sign(order), USDC_IN, 500, 0);

        assertEq(midnight.lastTokensLength(), 1, "one token flashed");
        assertEq(midnight.lastTokens(0), WETH, "flashed the output-leg collateral");
        assertEq(midnight.lastAssets(0), WETH_OUT, "flashed the requested amount");
        assertEq(midnight.lastReturn(), keccak256("morpho.midnight.callbackSuccess"), "Midnight success sentinel");
    }

    // ══════════════════════ Callback authentication ══════════════════════
    //
    // `onFlashLoan` pins the Midnight singleton as the sole caller and then
    // requires a flash THIS solver started. Together they stop a stray call from
    // driving `settlement.fill` out of band with attacker-crafted callback data.

    function test_midnight_callbackFromNonMidnight_revertsOnlyMidnight() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(MidnightFlashSolver.OnlyMidnight.selector);
        flashSolver.onFlashLoan(address(this), _a1(WETH), _u1(WETH_OUT), "");
    }

    function test_midnight_strayCallbackFromMidnight_revertsNotInFlash() public {
        vm.prank(address(midnight));
        vm.expectRevert(BaseFlashSolver.NotInFlash.selector);
        flashSolver.onFlashLoan(address(this), _a1(WETH), _u1(WETH_OUT), "");
    }

    // ══════════════════════ MultiInputUnsupported ══════════════════════
    //
    // The single-debt core only routes `legsIn[0]`; a second input leg would be
    // collected by nobody and become a maker shortfall. The check fires inside the
    // callback, before `settlement.fill`, so the whole flash unwinds.

    function test_midnight_multiInputOrder_revertsMultiInputUnsupported() public {
        _prepare(USDC_IN);

        Order memory order = _order();
        LegIn[] memory legsIn = new LegIn[](2);
        legsIn[0] = LegIn(USDC, USDC_IN, 0);
        legsIn[1] = LegIn(WETH, 1 ether, 0);
        order.legsIn = PackedEncode.legsIn(legsIn);
        // Sign BEFORE arming expectRevert — `_sign` makes a cheatcode call.
        bytes memory sig = _sign(order);

        vm.expectRevert(BaseFlashSolver.MultiInputUnsupported.selector);
        flashSolver.executeFill(WETH, WETH_OUT, order, sig, USDC_IN, 500, 0);
    }

    // ══════════════════════ Repayment floor ══════════════════════

    /// @dev The maker sells far too little USDC to buy the flashed WETH back, so
    ///      the post-swap balance cannot cover the repayment and `_ensureRepayable`
    ///      reverts before Midnight ever tries its pull. Proves the floor bites
    ///      rather than leaning on the provider's own transferFrom to fail.
    function test_midnight_underwaterFill_revertsFlashLoanNotRepaid() public {
        uint256 tinyIn = 100e6; // ~0.047 WETH at the fork block, against a 1 WETH flash
        _prepare(tinyIn);

        Order memory order = _sellOrder(0, maker, USDC, WETH, tinyIn, WETH_OUT, new Item[](0));
        bytes memory sig = _sign(order);

        vm.expectRevert(BaseFlashSolver.FlashLoanNotRepaid.selector);
        flashSolver.executeFill(WETH, WETH_OUT, order, sig, tinyIn, 500, 0);
    }

    /// @dev `minSwapOut` is the solver's own slippage bound on the repayment swap.
    ///      Demand an impossible amount and the router aborts, unwinding the flash;
    ///      we assert only that it reverts, not the router's message.
    function test_midnight_slippage_reverts() public {
        _prepare(USDC_IN);

        Order memory order = _order();
        bytes memory sig = _sign(order);

        vm.expectRevert();
        flashSolver.executeFill(WETH, WETH_OUT, order, sig, USDC_IN, 500, 1_000 ether);
    }
}
