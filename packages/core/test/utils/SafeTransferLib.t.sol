// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

// ──────────────────── Non-standard token mocks ────────────────────

/// @dev Standard ERC20: returns a boolean.
contract StdToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }
}

/// @dev USDT/BNB-style: returns NOTHING (must be treated as success).
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function transfer(address to, uint256 a) external {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
    }

    function transferFrom(address f, address t, uint256 a) external {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
    }

    function approve(address s, uint256 a) external {
        allowance[msg.sender][s] = a;
    }
}

/// @dev Returns `false` instead of reverting — the silent-fail trap.
contract FalseToken {
    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }

    function approve(address, uint256) external pure returns (bool) {
        return false;
    }
}

/// @dev Reverts on everything.
contract RevertToken {
    function transfer(address, uint256) external pure returns (bool) {
        revert("nope");
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        revert("nope");
    }
}

/// @dev USDT approve-race: rejects a non-zero → non-zero approve.
contract UsdtApproveToken {
    mapping(address => mapping(address => uint256)) public allowance;

    function approve(address s, uint256 a) external returns (bool) {
        require(allowance[msg.sender][s] == 0 || a == 0, "USDT approve race");
        allowance[msg.sender][s] = a;
        return true;
    }
}

/// @dev Calls the internal library so `msg.sender`/`address(this)` is the harness.
contract Harness {
    function transfer(address t, address to, uint256 a) external {
        SafeTransferLib.safeTransfer(t, to, a);
    }

    function transferFrom(address t, address f, address to, uint256 a) external {
        SafeTransferLib.safeTransferFrom(t, f, to, a);
    }

    function forceApprove(address t, address s, uint256 a) external {
        SafeTransferLib.forceApprove(t, s, a);
    }

    function bal(address t, address who) external view returns (uint256) {
        return SafeTransferLib.balanceOf(t, who);
    }
}

contract SafeTransferLibTest is Test {
    Harness h;
    address recipient = address(0xB0B);

    function setUp() public {
        h = new Harness();
    }

    // ── safeTransfer ──
    function test_transfer_standard() public {
        StdToken t = new StdToken();
        t.mint(address(h), 100);
        h.transfer(address(t), recipient, 40);
        assertEq(t.balanceOf(recipient), 40);
        assertEq(t.balanceOf(address(h)), 60);
    }

    function test_transfer_noReturn_treatedAsSuccess() public {
        NoReturnToken t = new NoReturnToken();
        t.mint(address(h), 100);
        h.transfer(address(t), recipient, 40); // must NOT revert despite no return value
        assertEq(t.balanceOf(recipient), 40);
    }

    function test_transfer_falseReturn_reverts() public {
        FalseToken t = new FalseToken();
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        h.transfer(address(t), recipient, 1);
    }

    function test_transfer_revertingToken_reverts() public {
        RevertToken t = new RevertToken();
        vm.expectRevert();
        h.transfer(address(t), recipient, 1);
    }

    function test_transfer_noCodeToken_reverts() public {
        // A token address with no code must fail (Solady's extcodesize guard).
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        h.transfer(address(0xdead), recipient, 1);
    }

    // ── safeTransferFrom ──
    function test_transferFrom_standard() public {
        StdToken t = new StdToken();
        t.mint(address(this), 100);
        t.approve(address(h), 100);
        h.transferFrom(address(t), address(this), recipient, 40);
        assertEq(t.balanceOf(recipient), 40);
    }

    function test_transferFrom_noReturn_treatedAsSuccess() public {
        NoReturnToken t = new NoReturnToken();
        t.mint(address(this), 100);
        t.approve(address(h), 100);
        h.transferFrom(address(t), address(this), recipient, 40);
        assertEq(t.balanceOf(recipient), 40);
    }

    function test_transferFrom_falseReturn_reverts() public {
        FalseToken t = new FalseToken();
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        h.transferFrom(address(t), address(this), recipient, 1);
    }

    // ── balanceOf ──
    function test_balanceOf_standard() public {
        StdToken t = new StdToken();
        t.mint(recipient, 123);
        assertEq(h.bal(address(t), recipient), 123);
    }

    function test_balanceOf_noCode_returnsZero() public view {
        assertEq(h.bal(address(0xdead), recipient), 0);
    }

    // ── forceApprove (with USDT-style reset+retry) ──
    function test_forceApprove_standard() public {
        StdToken t = new StdToken();
        h.forceApprove(address(t), recipient, 500);
        assertEq(t.allowance(address(h), recipient), 500);
    }

    function test_forceApprove_usdtRace_resetsAndRetries() public {
        UsdtApproveToken t = new UsdtApproveToken();
        h.forceApprove(address(t), recipient, 100); // 0 -> 100 ok
        assertEq(t.allowance(address(h), recipient), 100);
        // 100 -> 200 would revert on the first approve; forceApprove resets to 0 then retries.
        h.forceApprove(address(t), recipient, 200);
        assertEq(t.allowance(address(h), recipient), 200);
    }

    function test_forceApprove_falseReturn_reverts() public {
        FalseToken t = new FalseToken();
        vm.expectRevert(SafeTransferLib.ApproveFailed.selector);
        h.forceApprove(address(t), recipient, 1);
    }
}
