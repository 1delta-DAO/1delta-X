// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item} from "@core/settlement/Settlement.sol";
import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

/// @dev Direct-approval fallback — the Euler EVK `SafeERC20Lib.safeTransferFrom`
///      pattern ported into `Settlement._transferFromWithFallback`. The
///      two REGULAR transfer legs (solver→maker `tokenOut` delivery and
///      maker→solver `tokenIn` shortfall) try Permit3 first and fall back to a
///      plain ERC20 `transferFrom` when the payer approved Settlement directly
///      instead of routing through Permit3.
///
///      These lock in the *successful* fallback path (the guard test
///      `SettlementGuards.test_fillWithPermit_insufficientAllowance_reverts`
///      covers the both-empty terminal revert). The taker book (`take`) is
///      deliberately NOT covered by the fallback and stays Permit3-gated, so it
///      is not exercised here.
///
///   tokenIn  = USDC   (maker gives, solver receives)
///   tokenOut = WETH   (solver gives, maker receives — straight to wallet)
interface IERC2612Like {
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;
    function nonces(address owner) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

contract DirectApprovalFallbackTest is CoreSettlementBase {
    function _plainSwapOrder(uint256 nonce, uint256 usdcIn, uint256 wethOut) internal view returns (Order memory) {
        return _order(maker, nonce, USDC, WETH, usdcIn, wethOut, new Item[](0));
    }

    /// @dev `setUp` grants the solver a standing Permit3 allowance to Settlement.
    ///      Revoke it so a leg has no choice but to fall through to the direct
    ///      ERC20 path, and assert it is genuinely zero.
    function _revokeSolverPermit3(address token) internal {
        vm.prank(solver);
        permit3.revokeToken(address(settlement), token);
        (uint160 amt,) = permit3.tokenAllowance(solver, address(settlement), token);
        assertEq(amt, 0, "solver Permit3 allowance revoked");
    }

    // ──────────────── Solver delivers tokenOut via a DIRECT approval ────────────────

    /// @dev The solver never grants Permit3 for `tokenOut`; it approves Settlement
    ///      directly. `_deliverOutputs` tries Permit3, catches the failure, and
    ///      falls back to a plain `transferFrom(solver → maker)`.
    function test_solver_tokenOut_directApproval_fallback() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;

        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);

        // Maker funds tokenIn the normal way (Permit3).
        vm.prank(maker);
        permit3.approveToken(address(settlement), USDC, uint160(usdcIn), 0);

        // Solver funds tokenOut WITHOUT Permit3: revoke the standing allowance,
        // grant a plain ERC20 approval to Settlement instead.
        _revokeSolverPermit3(WETH);
        vm.prank(solver);
        IERC20(WETH).approve(address(settlement), wethOut);

        Order memory order = _plainSwapOrder(0, usdcIn, wethOut);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, usdcIn)[0];

        assertEq(paid, wethOut, "solver paid exactly wethOut via direct-approval fallback");
        assertEq(IERC20(WETH).balanceOf(maker), wethOut, "maker received WETH");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver received USDC");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
    }

    // ──────────────── Maker funds tokenIn via a DIRECT approval ────────────────

    /// @dev The maker never grants Permit3 for `tokenIn`; it approves Settlement
    ///      directly. With no items, `_payInputsToSolver` has zero TAKE proceeds,
    ///      so it must pull the full `owed` from the maker — Permit3 fails and it
    ///      falls back to a plain `transferFrom(maker → solver)`.
    function test_maker_tokenIn_directApproval_fallback() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;

        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);

        // Maker funds tokenIn WITHOUT Permit3: no `approveToken`, just a direct
        // ERC20 approval to Settlement. (The bare approve to Permit3 from setUp
        // is a different spender and does not help here.)
        vm.prank(maker);
        IERC20(USDC).approve(address(settlement), usdcIn);
        (uint160 makerP3,) = permit3.tokenAllowance(maker, address(settlement), USDC);
        assertEq(makerP3, 0, "maker granted no Permit3 allowance to Settlement");

        // Solver funds tokenOut the normal way (standing Permit3 allowance).
        Order memory order = _plainSwapOrder(1, usdcIn, wethOut);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, usdcIn)[0];

        assertEq(paid, wethOut, "solver paid exactly wethOut");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver received USDC via direct-approval fallback");
        assertEq(IERC20(WETH).balanceOf(maker), wethOut, "maker received WETH");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
    }

    // ──────────────── Maker funds tokenIn GASLESSLY: a relayed ERC-2612 permit ────────────────

    /// @dev The off-chain gasless-funding path (docs/gasless-permit-relay.md §7): the
    ///      maker never sends a transaction. It signs an EIP-2612 permit with
    ///      `spender = Settlement` next to the order; a THIRD PARTY (the filler, or
    ///      anyone who saw it in the book) submits `permit`, which creates exactly the
    ///      direct allowance the fallback pulls against. Mainnet USDC implements
    ///      EIP-2612, like USD₮0 on Rootstock. Also pins: a replay of the spent permit
    ///      reverts (the filler must re-read the nonce, not assume), and the fill uses
    ///      the allowance up exactly.
    function test_maker_tokenIn_relayedErc2612PermitToSettlement() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;
        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);

        Order memory order = _plainSwapOrder(3, usdcIn, wethOut);
        bytes memory sig = _sign(order);

        IERC2612Like t = IERC2612Like(USDC);
        uint256 nonce = t.nonces(maker);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                maker,
                address(settlement),
                usdcIn,
                nonce,
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s_) =
            vm.sign(makerPk, keccak256(abi.encodePacked("\x19\x01", t.DOMAIN_SEPARATOR(), structHash)));

        assertEq(IERC20(USDC).allowance(maker, address(settlement)), 0, "no allowance before the relay");
        vm.prank(address(0xF00D)); // anyone may relay it
        t.permit(maker, address(settlement), usdcIn, deadline, v, r, s_);
        assertEq(IERC20(USDC).allowance(maker, address(settlement)), usdcIn, "the permit set exactly the order input");

        vm.prank(address(0xF00D));
        vm.expectRevert();
        t.permit(maker, address(settlement), usdcIn, deadline, v, r, s_);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, usdcIn)[0];
        assertEq(paid, wethOut, "solver paid exactly wethOut");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "maker USDC pulled through the permit's direct allowance");
        assertEq(IERC20(WETH).balanceOf(maker), wethOut, "maker received WETH");
        assertEq(IERC20(USDC).allowance(maker, address(settlement)), 0, "the allowance is used up exactly");
    }

    // ──────────────── Fully Permit3-free swap (both legs fall back) ────────────────

    /// @dev Neither party touches the Permit3 token book: both approve Settlement
    ///      directly. Both regular legs fall back, so the entire fill settles on
    ///      plain ERC20 allowances — the integration path for a taker/maker who
    ///      never wants to interact with Permit3.
    function test_bothSides_directApproval_permit3Free() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;

        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);

        // Maker: direct approval only.
        vm.prank(maker);
        IERC20(USDC).approve(address(settlement), usdcIn);

        // Solver: revoke standing Permit3, direct approval only.
        _revokeSolverPermit3(WETH);
        vm.prank(solver);
        IERC20(WETH).approve(address(settlement), wethOut);

        Order memory order = _plainSwapOrder(2, usdcIn, wethOut);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, usdcIn)[0];

        assertEq(paid, wethOut, "swap settled with zero Permit3 involvement");
        assertEq(IERC20(WETH).balanceOf(maker), wethOut, "maker received WETH");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver received USDC");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
    }

    // ──────────────── Permit3 still takes priority when both are granted ────────────────

    /// @dev When the solver holds BOTH a Permit3 allowance and a direct approval,
    ///      the Permit3 leg succeeds first and the direct allowance is untouched —
    ///      confirming the fallback only fires on Permit3 failure.
    function test_permit3_takesPriority_overDirectApproval() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;

        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);

        vm.prank(maker);
        permit3.approveToken(address(settlement), USDC, uint160(usdcIn), 0);

        // Solver keeps its standing Permit3 allowance AND adds a direct approval.
        vm.prank(solver);
        IERC20(WETH).approve(address(settlement), wethOut);

        Order memory order = _plainSwapOrder(3, usdcIn, wethOut);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, usdcIn);

        // The direct ERC20 approval was never spent — Permit3 handled delivery.
        assertEq(IERC20(WETH).allowance(solver, address(settlement)), wethOut, "direct approval untouched");
        assertEq(IERC20(WETH).balanceOf(maker), wethOut, "maker received WETH");
    }
}
