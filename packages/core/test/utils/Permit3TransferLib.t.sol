// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {Permit3TransferLib} from "@core/utils/Permit3TransferLib.sol";

// ──────────────────── Minimal mocks (no fork, no real Permit3) ────────────────────

/// @dev Bare ERC20 sufficient for allowance/transferFrom branch coverage.
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "ERC20: allowance");
        require(balanceOf[from] >= amount, "ERC20: balance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Stand-in for the Permit3 hub. `succeed` toggles whether the single-leg
///      `transferFrom` moves tokens (settling from a Permit3-internal allowance,
///      here simplified to a direct ERC20 pull) or reverts — which is exactly the
///      condition the library's fallback keys off. `calls` counts invocations so
///      a test can prove the Permit3 leg was (or was not) attempted.
contract MockPermit3 {
    bool public succeed;
    uint256 public calls;

    constructor(bool _succeed) {
        succeed = _succeed;
    }

    function setSucceed(bool s) external {
        succeed = s;
    }

    function transferFrom(address from, address to, address token, uint160 amount) external {
        calls++;
        if (!succeed) revert("permit3: no allowance");
        // Emulate Permit3 pulling on the user's behalf; the mock is the spender.
        MockERC20(token).transferFrom(from, to, amount);
    }
}

/// @dev Thin harness so the library's `internal` call runs with THIS contract as
///      `msg.sender` toward both Permit3 and the ERC20 — i.e. it is the spender,
///      mirroring how Settlement calls the library.
contract LibHarness {
    function pull(IPermit3 permit3, address token, address from, address to, uint256 amount) external {
        Permit3TransferLib.transferFromWithFallback(permit3, token, from, to, amount);
    }
}

contract Permit3TransferLibTest is Test {
    LibHarness harness;
    MockERC20 token;

    address payer = address(0xA11CE);
    address recipient = address(0xB0B);

    function setUp() public {
        harness = new LibHarness();
        token = new MockERC20();
        token.mint(payer, 1_000 ether);
    }

    // ── Permit3 path succeeds → no fallback, ERC20 spender-allowance untouched ──
    function test_permit3Path_succeeds() public {
        MockPermit3 p3 = new MockPermit3(true);
        // Payer authorizes the Permit3 hub (the mock) to pull.
        vm.prank(payer);
        token.approve(address(p3), 100 ether);

        harness.pull(IPermit3(address(p3)), address(token), payer, recipient, 100 ether);

        assertEq(p3.calls(), 1, "permit3 leg attempted");
        assertEq(token.balanceOf(recipient), 100 ether, "recipient funded via permit3");
        assertEq(token.balanceOf(payer), 900 ether, "payer debited");
    }

    // ── Permit3 reverts, direct approval to the harness present → fallback fires ──
    function test_fallback_onPermit3Failure_withDirectApproval() public {
        MockPermit3 p3 = new MockPermit3(false); // always reverts
        // Payer approved the HARNESS (the spender) directly, not the Permit3 hub.
        vm.prank(payer);
        token.approve(address(harness), 100 ether);

        harness.pull(IPermit3(address(p3)), address(token), payer, recipient, 100 ether);

        // Note: `p3.calls()` cannot witness the attempt here — the Permit3 leg
        // reverts, and the EVM rolls back its `calls++` storage write. That the
        // fallback fired at all (amount ≤ uint160, so Permit3 was NOT skipped) is
        // itself proof the Permit3 leg was tried and failed.
        assertEq(token.balanceOf(recipient), 100 ether, "recipient funded via fallback");
        assertEq(token.allowance(payer, address(harness)), 0, "direct allowance consumed");
    }

    // ── Permit3 reverts AND no direct approval → terminal TransferFromFailed ──
    function test_reverts_whenPermit3Fails_andNoDirectApproval() public {
        MockPermit3 p3 = new MockPermit3(false);
        // No approvals of any kind.
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        harness.pull(IPermit3(address(p3)), address(token), payer, recipient, 100 ether);
    }

    // ── amount > uint160 max → Permit3 skipped entirely, straight to fallback ──
    function test_amountExceedsUint160_skipsPermit3() public {
        MockPermit3 p3 = new MockPermit3(true); // would succeed if called
        uint256 big = uint256(type(uint160).max) + 1;
        token.mint(payer, big);
        vm.prank(payer);
        token.approve(address(harness), big);

        harness.pull(IPermit3(address(p3)), address(token), payer, recipient, big);

        assertEq(p3.calls(), 0, "permit3 skipped for > uint160 amount");
        assertEq(token.balanceOf(recipient), big, "recipient funded via fallback");
    }

    // ── Zero amount is a no-op via Permit3 (mock succeeds, moves nothing) ──
    function test_zeroAmount_noop() public {
        MockPermit3 p3 = new MockPermit3(true);
        harness.pull(IPermit3(address(p3)), address(token), payer, recipient, 0);
        assertEq(token.balanceOf(recipient), 0, "nothing moved");
        assertEq(p3.calls(), 1, "permit3 leg still attempted with 0");
    }
}
