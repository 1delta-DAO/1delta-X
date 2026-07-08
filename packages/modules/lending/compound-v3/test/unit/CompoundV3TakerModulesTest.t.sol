// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {CometTakerModule} from "../../src/CompoundV3Modules.sol";

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

// ── CometTakerModule (combined borrow + withdraw) tests ───────────────────────
//
// The combined module multiplexes both taker legs behind a leading `op` flag.
// These tests assert: (1) each op reaches the right Comet `withdrawFrom`, (2) the
// op flag shifts every downstream offset by 32 bytes (allow block / BalanceMode),
// and (3) an unknown op fails closed.
contract CometTakerModuleTest is Test {
    MockERC20 asset;
    MockComet comet;
    MockPermit3 permit3;
    CometTakerModule module;

    address user = address(0xABCD);
    address receiver = address(0xCAFE);
    uint256 constant AMOUNT = 800e6;

    uint8 constant OP_BORROW = 0;
    uint8 constant OP_WITHDRAW = 1;

    function setUp() public {
        asset = new MockERC20();
        comet = new MockComet(asset);
        permit3 = new MockPermit3();
        module = new CometTakerModule(address(permit3));

        asset.mint(user, AMOUNT * 10);
        comet.setCollateral(user, address(asset), uint128(AMOUNT * 10));
        vm.prank(user);
        asset.approve(address(comet), type(uint256).max);
    }

    // ── Borrow leg (op = 0) ───────────────────────────────────────────────────

    function test_borrow_withAllowBySig() public {
        // data = abi.encode(op, comet, asset, nonce, expiry, v, r, s)
        bytes memory data = abi.encode(
            OP_BORROW, address(comet), address(asset),
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

        bytes memory data = abi.encode(OP_BORROW, address(comet), address(asset));

        vm.prank(address(permit3));
        module.takeOnBehalf(user, AMOUNT, receiver, data);

        assertFalse(comet.allowBySigCalled());
        assertEq(asset.balanceOf(receiver), AMOUNT);
    }

    function test_borrow_revertsIfNotAuthorizedAndNoSig() public {
        // No delegation and no standing allow — comet should revert.
        bytes memory data = abi.encode(OP_BORROW, address(comet), address(asset));

        vm.prank(address(permit3));
        vm.expectRevert("comet: not authorized");
        module.takeOnBehalf(user, AMOUNT, receiver, data);
    }

    // ── Withdraw leg (op = 1) ─────────────────────────────────────────────────

    function test_withdraw_withAllowBySig() public {
        // data = abi.encode(op, comet, asset, BalanceMode=0, nonce, expiry, v, r, s)
        bytes memory data = abi.encode(
            OP_WITHDRAW, address(comet), address(asset),
            uint8(0), // explicit BalanceMode = Exact, slot required ahead of the allow block
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

        bytes memory data = abi.encode(OP_WITHDRAW, address(comet), address(asset));

        vm.prank(address(permit3));
        module.takeOnBehalf(user, AMOUNT, receiver, data);

        assertFalse(comet.allowBySigCalled());
        assertEq(asset.balanceOf(receiver), AMOUNT);
    }

    function test_withdraw_fullMode_sweepsExcess() public {
        vm.prank(user);
        comet.allow(address(module), true);

        // BalanceMode = Full (1): withdraw the entire collateral, forward `amount`,
        // sweep the rest back to the user. Collateral seeded = AMOUNT * 10.
        // In this Comet mock the user's collateral IS their wallet balance
        // (withdrawFrom pulls via transferFrom), so a full withdraw removes the
        // whole balance and sweeps the excess back. Assert absolute end-balances:
        // the user nets out at total − AMOUNT, receiver gets AMOUNT, module keeps 0.
        uint256 total = AMOUNT * 10;
        bytes memory data = abi.encode(OP_WITHDRAW, address(comet), address(asset), uint8(1));

        vm.prank(address(permit3));
        module.takeOnBehalf(user, AMOUNT, receiver, data);

        assertEq(asset.balanceOf(receiver), AMOUNT, "receiver got signed amount");
        assertEq(asset.balanceOf(user), total - AMOUNT, "excess swept to user");
        assertEq(asset.balanceOf(address(module)), 0, "module retains nothing");
    }

    // ── Cross-cutting ─────────────────────────────────────────────────────────

    function test_revertsIfNotPermit3() public {
        bytes memory data = abi.encode(OP_BORROW, address(comet), address(asset));
        vm.expectRevert(CometTakerModule.OnlyPermit3.selector);
        module.takeOnBehalf(user, AMOUNT, receiver, data);
    }

    function test_revertsOnUnknownOp() public {
        bytes memory data = abi.encode(uint8(2), address(comet), address(asset));
        vm.prank(address(permit3));
        vm.expectRevert(abi.encodeWithSelector(CometTakerModule.BadOp.selector, uint8(2)));
        module.takeOnBehalf(user, AMOUNT, receiver, data);
    }

    /// @dev Borrow-data and withdraw-data must hash to different Permit3 refs —
    ///      the whole point of putting the op flag inside `data`.
    function test_opFlagSeparatesRefs() public view {
        bytes memory borrowData = abi.encode(OP_BORROW, address(comet), address(asset));
        bytes memory withdrawData = abi.encode(OP_WITHDRAW, address(comet), address(asset));
        assertTrue(keccak256(borrowData) != keccak256(withdrawData), "refs must differ by op");
    }
}
