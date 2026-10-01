// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {Settlement} from "@core/settlement/Settlement.sol";

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
    mapping(address => bool) public strictMode;
    mapping(address => mapping(address => bool)) public strictModeToken;

    constructor(bool _succeed) {
        succeed = _succeed;
    }

    function setSucceed(bool s) external {
        succeed = s;
    }

    function setStrict(address user, bool on) external {
        strictMode[user] = on;
    }

    function setStrictToken(address user, address token, bool on) external {
        strictModeToken[user][token] = on;
    }

    /// @dev What the library actually consults — the global flag OR the per-token
    ///      one, mirroring {AllowanceTransfer.isStrict}.
    function isStrict(address user, address token) external view returns (bool) {
        return strictMode[user] || strictModeToken[user][token];
    }

    function transferFrom(address from, address to, address token, uint160 amount) external {
        calls++;
        if (!succeed) revert("permit3: no allowance");
        // Emulate Permit3 pulling on the user's behalf; the mock is the spender.
        MockERC20(token).transferFrom(from, to, amount);
    }
}

/// @dev Harness over the SHIPPED pull — {Base._pullViaPermit3}, the hand-encoded copy
///      every Settlement maker/filler pull runs through (Core `_deliverOutputs`,
///      `_payInputsToSolver`, Batch `_stepPull`). It replaced
///      `Permit3TransferLib.transferFromWithFallback` in 2770c45, after which the
///      library had no production caller and these tests pinned a copy nothing ran
///      (audit 2026-09-30 P3-2). The library is deleted; the same cases now drive the
///      live code, with this harness (a real Settlement) as the spender.
contract PullHarness is Settlement {
    constructor(address permit3) Settlement(permit3) {}

    function pull(address token, address from, address to, uint256 amount) external {
        _pullViaPermit3(token, from, to, amount);
    }
}

contract PullViaPermit3Test is Test {
    MockERC20 token;

    address payer = address(0xA11CE);
    address recipient = address(0xB0B);

    function setUp() public {
        token = new MockERC20();
        token.mint(payer, 1_000 ether);
    }

    // ── Permit3 path succeeds → no fallback, ERC20 spender-allowance untouched ──
    function test_permit3Path_succeeds() public {
        MockPermit3 p3 = new MockPermit3(true);
        PullHarness harness = new PullHarness(address(p3));
        // Payer authorizes the Permit3 hub (the mock) to pull.
        vm.prank(payer);
        token.approve(address(p3), 100 ether);

        harness.pull(address(token), payer, recipient, 100 ether);

        assertEq(p3.calls(), 1, "permit3 leg attempted");
        assertEq(token.balanceOf(recipient), 100 ether, "recipient funded via permit3");
        assertEq(token.balanceOf(payer), 900 ether, "payer debited");
    }

    // ── Permit3 reverts, direct approval to the harness present → fallback fires ──
    function test_fallback_onPermit3Failure_withDirectApproval() public {
        MockPermit3 p3 = new MockPermit3(false); // always reverts
        PullHarness harness = new PullHarness(address(p3));
        // Payer approved the HARNESS (the spender) directly, not the Permit3 hub.
        vm.prank(payer);
        token.approve(address(harness), 100 ether);

        harness.pull(address(token), payer, recipient, 100 ether);

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
        PullHarness harness = new PullHarness(address(p3));
        // No approvals of any kind.
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        harness.pull(address(token), payer, recipient, 100 ether);
    }

    // ── amount > uint160 max → refused; the book must not be routed around ──
    /// A move too wide for the allowance book is REFUSED, not silently routed around
    /// it. It used to fall through to the direct-approval fallback, which skips the
    /// book's cap, expiration, `revokeToken` and `lockdown` with no signal.
    function test_audit_P3_2_amountExceedsUint160_reverts() public {
        MockPermit3 p3 = new MockPermit3(true); // would succeed if called
        PullHarness harness = new PullHarness(address(p3));
        uint256 big = uint256(type(uint160).max) + 1;
        token.mint(payer, big);
        vm.prank(payer);
        token.approve(address(harness), big);

        vm.expectRevert(IPermit3.Permit3Denied.selector);
        harness.pull(address(token), payer, recipient, big);

        assertEq(p3.calls(), 0, "permit3 not called");
        assertEq(token.balanceOf(recipient), 0, "nothing moved around the book");
    }

    // ── Zero amount is a pure no-op: NEITHER leg runs ──
    function test_zeroAmount_noop() public {
        MockPermit3 p3 = new MockPermit3(true);
        PullHarness harness = new PullHarness(address(p3));
        harness.pull(address(token), payer, recipient, 0);
        assertEq(token.balanceOf(recipient), 0, "nothing moved");
        // The library short-circuits amount==0 before touching either leg, so the
        // Permit3 hub (which now reverts ZeroAmount) is never called, and no direct
        // `transferFrom(_, _, 0)` — which strict tokens reject — is attempted.
        assertEq(p3.calls(), 0, "no permit3 leg on a zero amount");
    }

    // ── Strict mode: a failed Permit3 leg does NOT fall through to a direct pull ──
    function test_strictMode_refusesFallback() public {
        MockPermit3 p3 = new MockPermit3(false); // Permit3 leg always reverts
        PullHarness harness = new PullHarness(address(p3));
        p3.setStrict(payer, true);
        // Payer HAS a direct approval that would ordinarily fund the fallback.
        vm.prank(payer);
        token.approve(address(harness), 100 ether);

        vm.expectRevert(IPermit3.Permit3Denied.selector);
        harness.pull(address(token), payer, recipient, 100 ether);

        assertEq(token.balanceOf(recipient), 0, "strict mode blocked the fallback");
    }

    // ── PER-TOKEN strict mode: binds on the named token, and ONLY on it ──
    //
    // The global flag is all-or-nothing, so a payer who wants Permit3's caps to
    // actually bind on one token used to have to surrender the direct-approval
    // fallback on every other token too. These two pin the finer switch.
    function test_audit_P3_2_strictModeToken_refusesFallbackForThatToken() public {
        MockPermit3 p3 = new MockPermit3(false); // Permit3 leg always reverts
        PullHarness harness = new PullHarness(address(p3));
        // NOT globally strict — only this one token.
        p3.setStrictToken(payer, address(token), true);
        vm.prank(payer);
        token.approve(address(harness), 100 ether);

        vm.expectRevert(IPermit3.Permit3Denied.selector);
        harness.pull(address(token), payer, recipient, 100 ether);

        assertEq(token.balanceOf(recipient), 0, "per-token strict blocked the fallback");
        assertFalse(p3.strictMode(payer), "the global flag was never set");
    }

    function test_audit_P3_2_strictModeToken_leavesOtherTokensAlone() public {
        MockPermit3 p3 = new MockPermit3(false);
        PullHarness harness = new PullHarness(address(p3));
        MockERC20 other = new MockERC20();
        other.mint(payer, 100 ether);
        // Strict on `token`, silent on `other`.
        p3.setStrictToken(payer, address(token), true);
        vm.prank(payer);
        other.approve(address(harness), 100 ether);

        // The unhardened token still falls back to the direct approval, exactly as
        // it did before the per-token flag existed.
        harness.pull(address(other), payer, recipient, 100 ether);

        assertEq(other.balanceOf(recipient), 100 ether, "other token still falls back");
    }
}
