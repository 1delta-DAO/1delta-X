// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

/// @dev USDT, faithfully: `approve`/`transfer` return NOTHING, and `approve`
///      reverts on a non-zero → non-zero change (the classic approve race).
///      Solidity's ABI decoder requires 32 bytes back from a `bool`-declared
///      call, so a plain `IERC20(usdt).approve(...)` reverts on the decode —
///      which is why the entire solver family could not fill a USDT leg.
contract UsdtLikeToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address spender, uint256 amount) external {
        require(amount == 0 || allowance[msg.sender][spender] == 0, "USDT: unsafe approve");
        allowance[msg.sender][spender] = amount;
        // no return value
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        // no return value
    }

    function transferFrom(address from, address to, uint256 amount) external {
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        // no return value
    }
}

/// @dev A token that returns `false` instead of reverting — the other
///      non-standard shape a raw call would silently treat as success.
contract FalseReturningToken {
    mapping(address => uint256) public balanceOf;

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }

    function approve(address, uint256) external pure returns (bool) {
        return false;
    }
}

/// @dev Minimal stand-in for what the solvers do with a token: the raw path uses
///      the bool-returning interface the solver package used to use; the safe path
///      uses the library it uses now.
interface IBoolERC20 {
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

contract SolverTokenHarness {
    function rawApprove(address token, address spender, uint256 amount) external {
        IBoolERC20(token).approve(spender, amount);
    }

    function rawTransfer(address token, address to, uint256 amount) external {
        IBoolERC20(token).transfer(to, amount);
    }

    function safeApprove(address token, address spender, uint256 amount) external {
        SafeTransferLib.forceApprove(token, spender, amount);
    }

    function safeTransfer(address token, address to, uint256 amount) external {
        SafeTransferLib.safeTransfer(token, to, amount);
    }
}

/// @title SolverNonStandardTokenTest
/// @notice Pins the reason the solver package moved to {SafeTransferLib}.
///
///         Every ERC20 call in `packages/solvers/src` used the bool-returning
///         `IERC20` with no return handling. Against USDT — the single most common
///         debt asset for a levered WETH position — the approve inside
///         `setupTokenApproval` and `_swapExactIn` reverts on the ABI decode, so no
///         solver in the family could fill a USDT leg at all. Against a
///         `false`-returning token the same call succeeded silently, turning the
///         repayment transfer into a no-op.
contract SolverNonStandardTokenTest is Test {
    SolverTokenHarness harness;
    UsdtLikeToken usdt;
    FalseReturningToken liar;

    address spender = address(0x59E);
    address recipient = address(0xFEE);

    function setUp() public {
        harness = new SolverTokenHarness();
        usdt = new UsdtLikeToken();
        liar = new FalseReturningToken();
        usdt.mint(address(harness), 1_000e6);
    }

    // ──────────────── The break, demonstrated ────────────────

    /// The old code path: reverts on the missing return value.
    function test_rawApprove_revertsOnUsdt() public {
        vm.expectRevert();
        harness.rawApprove(address(usdt), spender, 1_000e6);
    }

    function test_rawTransfer_revertsOnUsdt() public {
        vm.expectRevert();
        harness.rawTransfer(address(usdt), recipient, 100e6);
    }

    // ──────────────── The fix ────────────────

    function test_safeApprove_worksOnUsdt() public {
        harness.safeApprove(address(usdt), spender, 1_000e6);
        assertEq(usdt.allowance(address(harness), spender), 1_000e6, "allowance set");
    }

    function test_safeTransfer_worksOnUsdt() public {
        harness.safeTransfer(address(usdt), recipient, 100e6);
        assertEq(usdt.balanceOf(recipient), 100e6, "transfer landed");
    }

    /// `forceApprove` also clears the approve race: a solver re-approving a token
    /// whose allowance is already non-zero (every repeat `setupTokenApproval`, and
    /// the per-swap approve in `_swapExactIn`) would otherwise revert on USDT.
    function test_safeApprove_handlesTheApproveRace() public {
        harness.safeApprove(address(usdt), spender, 500e6);

        // A raw re-approve is exactly what USDT rejects.
        vm.expectRevert();
        harness.rawApprove(address(usdt), spender, 1_000e6);

        // forceApprove resets to zero and retries.
        harness.safeApprove(address(usdt), spender, 1_000e6);
        assertEq(usdt.allowance(address(harness), spender), 1_000e6, "re-approve succeeded");
    }

    // ──────────────── The silent-failure shape ────────────────

    /// A `false`-returning token used to make the repayment transfer a silent
    /// no-op. It must revert instead.
    function test_safeTransfer_revertsOnFalseReturn() public {
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        harness.safeTransfer(address(liar), recipient, 1);
    }

    function test_rawTransfer_silentlySucceedsOnFalseReturn() public {
        // The old behaviour: no revert, no transfer — the failure is invisible.
        harness.rawTransfer(address(liar), recipient, 1);
        assertEq(liar.balanceOf(recipient), 0, "nothing moved, yet the call 'succeeded'");
    }
}
