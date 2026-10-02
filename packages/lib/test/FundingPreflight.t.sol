// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {FundingPreflight} from "@lib/FundingPreflight.sol";

/// @dev The two reads FundingPreflight makes on Permit3's book, nothing else.
contract BookStub20260930 {
    uint160 public amount;
    uint48 public exp;

    function set(uint160 a, uint48 e) external {
        amount = a;
        exp = e;
    }

    function tokenAllowance(address, address, address) external view returns (uint160, uint48) {
        return (amount, exp);
    }
}

contract Erc20Stub20260930 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function setBalance(address u, uint256 b) external {
        balanceOf[u] = b;
    }

    function setAllowance(address o, address s, uint256 a) external {
        allowance[o][s] = a;
    }
}

/// @dev A token with no `allowance` view at all.
contract NoAllowanceToken20260930 {
    mapping(address => uint256) public balanceOf;

    function setBalance(address u, uint256 b) external {
        balanceOf[u] = b;
    }
}

contract FundingPreflightProbe20260930 {
    function pullable(address permit3, address user, address token) external view returns (uint256) {
        return FundingPreflight.pullable(IPermit3(permit3), address(this), user, token);
    }

    function pullableAtFill(address permit3, address user, address token) external view returns (uint256) {
        return FundingPreflight.pullable(IPermit3(permit3), address(this), user, token, true);
    }
}

/// @title FundingPreflight — audit 2026-09-30 G-LENS_PARITY-1
/// @notice `available` must be `min(book, balance, allowance(user, PERMIT3))`: Permit3
///         spends a book entry through the user's plain approval TO PERMIT3, so a
///         revoked approval funds nothing whatever the book says.
contract FundingPreflightTest is Test {
    BookStub20260930 book;
    Erc20Stub20260930 token;
    FundingPreflightProbe20260930 probe;
    address user = address(0xA11CE);

    function setUp() public {
        book = new BookStub20260930();
        token = new Erc20Stub20260930();
        probe = new FundingPreflightProbe20260930();
        book.set(100e18, 0);
        token.setBalance(user, 80e18);
    }

    function test_audit_G_LENS_PARITY_1_revokedPermit3ApprovalFundsNothing() public {
        token.setAllowance(user, address(book), 0); // the hub kill switch
        assertEq(probe.pullable(address(book), user, address(token)), 0, "revoked approval: nothing pullable");

        token.setAllowance(user, address(book), 30e18);
        assertEq(probe.pullable(address(book), user, address(token)), 30e18, "capped by the approval");

        token.setAllowance(user, address(book), type(uint256).max);
        assertEq(probe.pullable(address(book), user, address(token)), 80e18, "then by the balance");
    }

    function test_audit_G_LENS_PARITY_1_permitInDataSkipsTheApprovalTerm() public view {
        // No approval yet, but the item carries a 2612 permit that grants it at fill.
        assertEq(probe.pullableAtFill(address(book), user, address(token)), 80e18);
    }

    function test_audit_G_LENS_PARITY_1_unreadableAllowanceIsZero() public {
        NoAllowanceToken20260930 t = new NoAllowanceToken20260930();
        t.setBalance(user, 80e18);
        assertEq(probe.pullable(address(book), user, address(t)), 0, "a failed read is 0, never max");
    }

    function test_audit_G_LENS_PARITY_1_expiredBookIsZero() public {
        token.setAllowance(user, address(book), type(uint256).max);
        vm.warp(1_000);
        book.set(100e18, 999);
        assertEq(probe.pullable(address(book), user, address(token)), 0);
    }
}
