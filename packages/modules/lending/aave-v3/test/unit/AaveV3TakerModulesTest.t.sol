// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AaveV3WithdrawModule} from "../../src/AaveV3Modules.sol";
import {AaveV3CreditModule} from "../../src/AaveV3CreditModule.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";

// ── Mocks ────────────────────────────────────────────────────────────────────

/// @dev ERC-20 + EIP-2612 mock (aToken). Skips sig verification — unit tests
///      focus on module logic, not protocol cryptography.
contract MockAToken {
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

    // EIP-2612: skip sig verification — just set allowance.
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8, bytes32, bytes32) external {
        require(block.timestamp <= deadline, "aToken permit: expired");
        allowance[owner][spender] = value;
    }
}

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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
        uint8,
        bytes32,
        bytes32
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

    function repay(address, uint256, uint256, address) external returns (uint256) {
        return 0;
    }
}

contract MockPermit3 {
    function transferFrom(address from, address to, address token, uint160 amount) external {
        MockAToken(token).transferFrom(from, to, amount);
    }
}

// ── AaveV3CreditModule: Op.Borrow ─────────────────────────────────────────────

contract AaveV3CreditModuleBorrowTest is Test {
    MockERC20 asset;
    MockDebtToken debtToken;
    MockAaveV3Pool pool;
    MockPermit3 permit3;
    AaveV3CreditModule module;

    address user = address(0xABCD);
    address receiver = address(0xCAFE);
    address settlement = address(0x5E77);
    uint256 constant AMOUNT = 500e18;

    /// @dev Word 0 of a plain-`take` blob IS the op. Small enough that `>> 253 == 0`,
    ///      which is what {PreFundGuard.requirePlainTake} demands — so the
    ///      discriminator doubles as the data-space pin.
    uint256 constant OP_BORROW = uint256(AaveV3CreditModule.Op.Borrow);

    function setUp() public {
        asset = new MockERC20();
        debtToken = new MockDebtToken();
        pool = new MockAaveV3Pool(asset, new MockAToken());
        permit3 = new MockPermit3();
        module = new AaveV3CreditModule(address(permit3), settlement);
    }

    function test_borrow_withDelegationSig() public {
        // data = abi.encode(op, pool, asset, rateMode, debtToken, deadline, v, r, s)
        bytes memory data = abi.encode(
            OP_BORROW,
            address(pool),
            address(asset),
            uint256(2),
            address(debtToken),
            block.timestamp + 1 hours,
            uint8(27),
            bytes32(0),
            bytes32(0)
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
        bytes memory data = abi.encode(OP_BORROW, address(pool), address(asset), uint256(2));

        vm.prank(address(permit3));
        module.takeOnBehalf(user, AMOUNT, receiver, data);

        assertFalse(debtToken.delegationCalled(), "delegation should not be called");
        assertEq(asset.balanceOf(receiver), AMOUNT);
    }

    function test_borrow_revertsIfNotPermit3() public {
        bytes memory data = abi.encode(OP_BORROW, address(pool), address(asset), uint256(2));
        vm.expectRevert(PreFundModuleBase.OnlyPermit3.selector);
        module.takeOnBehalf(user, AMOUNT, receiver, data);
    }

    /// @dev An op this seam does not implement is rejected by NAME, not left to a
    ///      decode that happens to fail. The merge's whole safety argument is that
    ///      the op is inside `data` and therefore inside `ref = keccak256(data)`;
    ///      that only holds if an unknown op is a hard error rather than a silent
    ///      fall-through to op 0.
    function test_borrow_revertsOnUnknownOp() public {
        bytes memory data = abi.encode(uint256(7), address(pool), address(asset), uint256(2));
        vm.prank(address(permit3));
        vm.expectRevert(abi.encodeWithSelector(AaveV3CreditModule.BadOp.selector, uint256(7)));
        module.takeOnBehalf(user, AMOUNT, receiver, data);
    }

    /// @dev The plain seam must refuse a blob carrying a FUNDING DESCRIPTOR in word 0.
    ///      Without this the two data spaces overlap and one `approveTaker` could
    ///      authorise either dispatch — the ambiguity
    ///      {PreFundGuard.requirePlainTake} exists to close, now load-bearing on this
    ///      contract because it hosts both entrypoints.
    function test_borrow_revertsOnFundingDescriptorBlob() public {
        bytes memory data =
            abi.encode((uint256(1) << 255) | (uint256(1) << 253), address(pool), address(asset), uint256(2));
        vm.prank(address(permit3));
        vm.expectRevert(PreFundGuard.PreFundDescriptorNotAllowed.selector);
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
            address(pool),
            address(asset),
            address(aToken),
            uint8(0), // BalanceMode = Exact, explicit slot required when permit present
            block.timestamp + 1 hours,
            uint8(27),
            bytes32(0),
            bytes32(0)
        );

        vm.prank(address(permit3));
        module.takeOnBehalf(user, AMOUNT, receiver, data);

        // Permit set allowance for permit3 to pull aTokens — pool.withdraw delivered asset
        assertEq(asset.balanceOf(receiver), AMOUNT);
    }

    function test_withdraw_withoutPermit_standingApproval() public {
        // User pre-approves THE MODULE for aTokens at ERC-20 level — the aToken pull
        // is a direct ERC-20 transferFrom on the module's own allowance, not a Permit3
        // pull (the position-access grant lives on the aToken itself).
        vm.prank(user);
        aToken.approve(address(module), type(uint256).max);

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
