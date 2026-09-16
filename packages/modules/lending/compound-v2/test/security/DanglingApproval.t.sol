// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CompoundV2RepayModule} from "../../src/CompoundV2Modules.sol";

/// @dev Minimal ERC-20 with a real allowance ledger — the point of this test.
contract ApprovalERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev A `cToken` that reports a debt, accepts the repay and pulls NOTHING — the
///      case that leaves a standing allowance behind. `cToken` is order-supplied,
///      so an attacker-authored order can name exactly this.
contract NonConsumingCToken {
    uint256 public debt;

    constructor(uint256 debt_) {
        debt = debt_;
    }

    function borrowBalanceCurrent(address) external view returns (uint256) {
        return debt;
    }

    function repayBorrowBehalf(address, uint256) external pure returns (uint256) {
        return 0;
    }
}

contract Permit3Stub {
    function transferFrom(address from, address to, address token, uint160 amount) external {
        ApprovalERC20(token).transferFrom(from, to, amount);
    }
}

/// @title CompoundV2DanglingApprovalTest
/// @notice F25 / lead A-3 for the Compound v2 repay maker — the sibling the six-site
///         fix missed (2026-09-12 audit, finding 5). Mirrors
///         aave-v3/test/unit/DanglingApproval.t.sol: the clear must be unconditional,
///         so the target here consumes nothing at all.
contract CompoundV2DanglingApprovalTest is Test {
    ApprovalERC20 underlying;
    NonConsumingCToken cToken;
    Permit3Stub permit3;
    CompoundV2RepayModule module;

    address settlement = address(0x5E77);
    address maker = address(0xABCD);
    uint256 constant AMOUNT = 1_000e18;

    function setUp() public {
        underlying = new ApprovalERC20();
        cToken = new NonConsumingCToken(AMOUNT);
        permit3 = new Permit3Stub();
        module = new CompoundV2RepayModule(address(permit3), settlement);

        underlying.mint(maker, AMOUNT);
        vm.prank(maker);
        underlying.approve(address(permit3), AMOUNT);
    }

    function test_repay_clearsEvenWhenTheTargetConsumesNothing() public {
        bytes memory data = abi.encode(address(cToken), address(underlying));

        vm.prank(settlement);
        module.makeOnBehalf(maker, AMOUNT, data);

        // The un-consumed pull was swept back to the maker (SweepToUser)...
        assertEq(underlying.balanceOf(maker), AMOUNT, "residual swept back");
        assertEq(underlying.balanceOf(address(module)), 0, "module ends empty");
        // ...and the order-supplied cToken holds NO standing claim on future balances.
        assertEq(underlying.allowance(address(module), address(cToken)), 0, "allowance cleared");
    }
}
