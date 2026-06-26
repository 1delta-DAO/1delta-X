// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CometBorrowModule, CometWithdrawModule, CometTakeBase} from "../../src/CompoundV3Modules.sol";

// ── Mocks ────────────────────────────────────────────────────────────────────

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Comet mock. Records allowBySig calls; skips sig verification.
///      Enforces the isAllowed flag on withdrawFrom so we can test the module
///      only succeeds after delegation is set up.
contract MockComet {
    mapping(address => mapping(address => bool)) public isAllowed;
    bool public allowBySigCalled;
    address public lastOwner;
    address public lastManager;
    MockERC20 public baseToken;
    mapping(address => mapping(address => uint128)) public collateralBalances;

    constructor(MockERC20 _baseToken) { baseToken = _baseToken; }

    function setCollateral(address user, address asset, uint128 amount) external {
        collateralBalances[user][asset] = amount;
    }

    // EIP-712 allow-by-sig: skip sig verification, just record and set flag.
    function allowBySig(
        address owner,
        address manager,
        bool _isAllowed,
        uint256, // nonce
        uint256, // expiry
        uint8, bytes32, bytes32
    ) external {
        allowBySigCalled = true;
        lastOwner = owner;
        lastManager = manager;
        isAllowed[owner][manager] = _isAllowed;
    }

    function allow(address manager, bool _isAllowed) external {
        isAllowed[msg.sender][manager] = _isAllowed;
    }

    function withdrawFrom(address src, address to, address asset, uint256 amount) external {
        require(isAllowed[src][msg.sender], "comet: not authorized");
        MockERC20(asset).transferFrom(src, to, amount);
    }

    function collateralBalanceOf(address account, address asset) external view returns (uint128) {
        return collateralBalances[account][asset];
    }

    function borrowBalanceOf(address) external pure returns (uint256) { return 0; }
}

contract MockPermit3 {
    function transferFrom(address from, address to, address token, uint160 amount) external {
        MockERC20(token).transferFrom(from, to, amount);
    }
}

// ── CometBorrowModule tests ───────────────────────────────────────────────────

contract CometBorrowModuleTest is Test {
    MockERC20 asset;
    MockComet comet;
    MockPermit3 permit3;
    CometBorrowModule module;

    address user = address(0xABCD);
    address receiver = address(0xCAFE);
    uint256 constant AMOUNT = 1000e6;

    function setUp() public {
        asset = new MockERC20();
        comet = new MockComet(asset);
        permit3 = new MockPermit3();
        module = new CometBorrowModule(address(permit3));

        asset.mint(user, AMOUNT * 10);
        vm.prank(user);
        asset.approve(address(comet), type(uint256).max);
    }

    function test_borrow_withAllowBySig() public {
        // data = abi.encode(comet, asset, nonce, expiry, v, r, s)
        bytes memory data = abi.encode(
            address(comet), address(asset),
            uint256(0), block.timestamp + 1 hours, uint8(27), bytes32(0), bytes32(0)
        );

        vm.prank(address(permit3));
        module.takeOnBehalf(user, AMOUNT, receiver, data);

        assertTrue(comet.allowBySigCalled(), "allowBySig was not called");
        assertEq(comet.lastOwner(), user);
        assertEq(comet.lastManager(), address(module));
        assertEq(asset.balanceOf(receiver), AMOUNT);
    }

    function test_borrow_withoutSig_standingAllow() public {
        // Pre-authorize module via on-chain allow().
        vm.prank(user);
        comet.allow(address(module), true);

        bytes memory data = abi.encode(address(comet), address(asset));

        vm.prank(address(permit3));
        module.takeOnBehalf(user, AMOUNT, receiver, data);

        assertFalse(comet.allowBySigCalled());
        assertEq(asset.balanceOf(receiver), AMOUNT);
    }

    function test_borrow_revertsIfNotAuthorizedAndNoSig() public {
        // No delegation and no standing allow — comet should revert.
        bytes memory data = abi.encode(address(comet), address(asset));

        vm.prank(address(permit3));
        vm.expectRevert("comet: not authorized");
        module.takeOnBehalf(user, AMOUNT, receiver, data);
    }

    function test_borrow_revertsIfNotPermit3() public {
        bytes memory data = abi.encode(address(comet), address(asset));
        vm.expectRevert(CometTakeBase.OnlyPermit3.selector);
        module.takeOnBehalf(user, AMOUNT, receiver, data);
    }
}

// ── CometWithdrawModule tests ─────────────────────────────────────────────────

contract CometWithdrawModuleTest is Test {
    MockERC20 asset;
    MockComet comet;
    MockPermit3 permit3;
    CometWithdrawModule module;

    address user = address(0xABCD);
    address receiver = address(0xCAFE);
    uint256 constant AMOUNT = 800e6;

    function setUp() public {
        asset = new MockERC20();
        comet = new MockComet(asset);
        permit3 = new MockPermit3();
        module = new CometWithdrawModule(address(permit3));

        asset.mint(user, AMOUNT * 10);
        comet.setCollateral(user, address(asset), uint128(AMOUNT * 10));
        vm.prank(user);
        asset.approve(address(comet), type(uint256).max);
    }

    function test_withdraw_withAllowBySig() public {
        // data = abi.encode(comet, asset, BalanceMode=0, nonce, expiry, v, r, s)
        bytes memory data = abi.encode(
            address(comet), address(asset),
            uint8(0), // explicit BalanceMode = Exact
            uint256(0), block.timestamp + 1 hours, uint8(27), bytes32(0), bytes32(0)
        );

        vm.prank(address(permit3));
        module.takeOnBehalf(user, AMOUNT, receiver, data);

        assertTrue(comet.allowBySigCalled());
        assertEq(comet.lastOwner(), user);
        assertEq(comet.lastManager(), address(module));
        assertEq(asset.balanceOf(receiver), AMOUNT);
    }

    function test_withdraw_withoutSig_standingAllow() public {
        vm.prank(user);
        comet.allow(address(module), true);

        bytes memory data = abi.encode(address(comet), address(asset));

        vm.prank(address(permit3));
        module.takeOnBehalf(user, AMOUNT, receiver, data);

        assertFalse(comet.allowBySigCalled());
        assertEq(asset.balanceOf(receiver), AMOUNT);
    }

    function test_withdraw_revertsIfNotPermit3() public {
        bytes memory data = abi.encode(address(comet), address(asset));
        vm.expectRevert(CometTakeBase.OnlyPermit3.selector);
        module.takeOnBehalf(user, AMOUNT, receiver, data);
    }
}
