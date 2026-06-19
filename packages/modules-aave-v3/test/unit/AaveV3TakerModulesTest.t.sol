// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AaveV3BorrowModule, AaveV3WithdrawModule} from "../../src/AaveV3Modules.sol";

// ── Mocks ────────────────────────────────────────────────────────────────────

/// @dev ERC-20 + EIP-2612 mock (aToken). Skips sig verification — unit tests
///      focus on module logic, not protocol cryptography.
contract MockAToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }

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

    // EIP-2612: skip sig verification — just set allowance.
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8, bytes32, bytes32) external {
        require(block.timestamp <= deadline, "aToken permit: expired");
        allowance[owner][spender] = value;
    }
}

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }

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

/// @dev Aave V3 variable/stable debt token mock. Records delegation calls;
///      skips sig verification.
contract MockDebtToken {
    mapping(address => mapping(address => uint256)) public borrowAllowance;
    bool public delegationCalled;
    address public lastDelegator;
    address public lastDelegatee;
    uint256 public lastValue;

    function delegationWithSig(
        address delegator,
        address delegatee,
        uint256 value,
        uint256, // deadline — not verified in mock
        uint8, bytes32, bytes32
    ) external {
        delegationCalled = true;
        lastDelegator = delegator;
        lastDelegatee = delegatee;
        lastValue = value;
        borrowAllowance[delegator][delegatee] = value;
    }
}

contract MockAaveV3Pool {
    MockERC20 public asset;
    MockAToken public aToken;

    constructor(MockERC20 _asset, MockAToken _aToken) {
        asset = _asset;
        aToken = _aToken;
    }

    function borrow(address _asset, uint256 amount, uint256, uint16, address) external {
        MockERC20(_asset).mint(msg.sender, amount);
    }

    function withdraw(address _asset, uint256 amount, address to) external returns (uint256) {
        // Simplified: pool holds backing asset, transfer it out.
        MockERC20(_asset).transfer(to, amount);
        return amount;
    }

    function supply(address, uint256, address, uint16) external {}
    function repay(address, uint256, uint256, address) external returns (uint256) { return 0; }
}

contract MockPermit3 {
    function transferFrom(address from, address to, address token, uint160 amount) external {
        MockAToken(token).transferFrom(from, to, amount);
    }
}

// ── AaveV3BorrowModule tests ──────────────────────────────────────────────────

contract AaveV3BorrowModuleTest is Test {
    MockERC20 asset;
    MockDebtToken debtToken;
    MockAaveV3Pool pool;
    MockPermit3 permit3;
    AaveV3BorrowModule module;

    address user = address(0xABCD);
    address receiver = address(0xCAFE);
    uint256 constant AMOUNT = 500e18;

    function setUp() public {
        asset = new MockERC20();
        debtToken = new MockDebtToken();
        pool = new MockAaveV3Pool(asset, new MockAToken());
        permit3 = new MockPermit3();
        module = new AaveV3BorrowModule(address(permit3));
    }

    function test_borrow_withDelegationSig() public {
        // data = abi.encode(pool, asset, rateMode, debtToken, deadline, v, r, s)
        bytes memory data = abi.encode(
            address(pool), address(asset), uint256(2),
            address(debtToken), block.timestamp + 1 hours, uint8(27), bytes32(0), bytes32(0)
        );

        vm.prank(address(permit3));
        module.takeOnBehalf(user, AMOUNT, receiver, data);

        assertTrue(debtToken.delegationCalled(), "delegation was not called");
        assertEq(debtToken.lastDelegator(), user);
        assertEq(debtToken.lastDelegatee(), address(module));
        assertEq(debtToken.lastValue(), AMOUNT);
        assertEq(asset.balanceOf(receiver), AMOUNT);
    }

    function test_borrow_withoutDelegationSig_standingAuth() public {
        // No delegation block — relies on standing approveDelegation.
        bytes memory data = abi.encode(address(pool), address(asset), uint256(2));

        vm.prank(address(permit3));
        module.takeOnBehalf(user, AMOUNT, receiver, data);

        assertFalse(debtToken.delegationCalled(), "delegation should not be called");
        assertEq(asset.balanceOf(receiver), AMOUNT);
    }

    function test_borrow_revertsIfNotPermit3() public {
        bytes memory data = abi.encode(address(pool), address(asset), uint256(2));
        vm.expectRevert(AaveV3BorrowModule.OnlyPermit3.selector);
        module.takeOnBehalf(user, AMOUNT, receiver, data);
    }
}

// ── AaveV3WithdrawModule tests ────────────────────────────────────────────────

contract AaveV3WithdrawModuleTest is Test {
    MockERC20 asset;
    MockAToken aToken;
    MockAaveV3Pool pool;
    MockPermit3 permit3;
    AaveV3WithdrawModule module;

    address user = address(0xABCD);
    address receiver = address(0xCAFE);
    uint256 constant AMOUNT = 1000e6;

    function setUp() public {
        asset = new MockERC20();
        aToken = new MockAToken();
        pool = new MockAaveV3Pool(asset, aToken);
        permit3 = new MockPermit3();
        module = new AaveV3WithdrawModule(address(permit3));

        // Give pool backing assets to pay out
        asset.mint(address(pool), AMOUNT * 10);
        // Give user aTokens
        aToken.mint(user, AMOUNT);
    }

    function test_withdraw_withATokenPermit() public {
        // data = abi.encode(pool, asset, aToken, BalanceMode=0, deadline, v, r, s)
        bytes memory data = abi.encode(
            address(pool), address(asset), address(aToken),
            uint8(0), // BalanceMode = Exact, explicit slot required when permit present
            block.timestamp + 1 hours, uint8(27), bytes32(0), bytes32(0)
        );

        vm.prank(address(permit3));
        module.takeOnBehalf(user, AMOUNT, receiver, data);

        // Permit set allowance for permit3 to pull aTokens — pool.withdraw delivered asset
        assertEq(asset.balanceOf(receiver), AMOUNT);
    }

    function test_withdraw_withoutPermit_standingApproval() public {
        // User pre-approves permit3 for aTokens at ERC-20 level.
        vm.prank(user);
        aToken.approve(address(permit3), type(uint256).max);

        bytes memory data = abi.encode(address(pool), address(asset), address(aToken));

        vm.prank(address(permit3));
        module.takeOnBehalf(user, AMOUNT, receiver, data);

        assertEq(asset.balanceOf(receiver), AMOUNT);
    }

    function test_withdraw_revertsIfNotPermit3() public {
        bytes memory data = abi.encode(address(pool), address(asset), address(aToken));
        vm.expectRevert(AaveV3WithdrawModule.OnlyPermit3.selector);
        module.takeOnBehalf(user, AMOUNT, receiver, data);
    }
}
