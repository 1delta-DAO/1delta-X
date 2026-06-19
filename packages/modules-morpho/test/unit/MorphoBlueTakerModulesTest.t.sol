// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MorphoBlueBorrowModule, MorphoBlueWithdrawCollateralModule} from "../../src/MorphoBlueModules.sol";
import {MarketParams} from "../../src/interfaces/IMorphoBlue.sol";

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

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Morpho Blue mock. Records setAuthorizationWithSig calls; skips sig
///      verification. Enforces the authorization flag on borrow/withdrawCollateral.
contract MockMorpho {
    struct Authorization {
        address authorizer;
        address authorized;
        bool isAuthorized;
        uint256 nonce;
        uint256 deadline;
    }
    struct Signature { uint8 v; bytes32 r; bytes32 s; }
    struct Position { uint256 supplyShares; uint128 borrowShares; uint128 collateral; }

    mapping(address => mapping(address => bool)) public authorization;
    bool public authWithSigCalled;
    address public lastAuthorizer;
    address public lastAuthorized;

    mapping(bytes32 => mapping(address => Position)) public positions;
    MockERC20 public loanToken;
    MockERC20 public collateralToken;

    constructor(MockERC20 _loanToken, MockERC20 _collateralToken) {
        loanToken = _loanToken;
        collateralToken = _collateralToken;
    }

    // Test helper: seed collateral state keyed by the same ID the module computes.
    function setPositionCollateral(MarketParams memory mp, address user, uint128 amount) external {
        positions[keccak256(abi.encode(mp))][user].collateral = amount;
    }

    // EIP-712 auth-with-sig: skip sig verification, just record and set flag.
    function setAuthorizationWithSig(Authorization calldata auth, Signature calldata) external {
        authWithSigCalled = true;
        lastAuthorizer = auth.authorizer;
        lastAuthorized = auth.authorized;
        authorization[auth.authorizer][auth.authorized] = auth.isAuthorized;
    }

    function setAuthorization(address authorized, bool isAuthorized) external {
        authorization[msg.sender][authorized] = isAuthorized;
    }

    function borrow(MarketParams memory, uint256 assets, uint256, address onBehalf, address receiver)
        external
        returns (uint256, uint256)
    {
        require(authorization[onBehalf][msg.sender], "morpho: not authorized");
        loanToken.mint(receiver, assets);
        return (assets, 0);
    }

    function withdrawCollateral(MarketParams memory mp, uint256 assets, address onBehalf, address receiver) external {
        require(authorization[onBehalf][msg.sender], "morpho: not authorized");
        positions[keccak256(abi.encode(mp))][onBehalf].collateral -= uint128(assets);
        collateralToken.mint(receiver, assets);
    }

    // Called by the module as: morpho.position(marketParams.id(), user)
    // MarketParamsLib.id() = Id.wrap(keccak256(abi.encode(mp))).
    // Since Id is `type Id is bytes32`, ABI signature is position(bytes32,address).
    function position(bytes32 id, address user) external view returns (Position memory) {
        return positions[id][user];
    }
}

contract MockPermit3 {
    function transferFrom(address, address, address, uint160) external {}
}

// ── Helper: build a MarketParams ─────────────────────────────────────────────

function dummyMarketParams(address loanToken, address collateralToken) pure returns (MarketParams memory) {
    return MarketParams({
        loanToken: loanToken,
        collateralToken: collateralToken,
        oracle: address(0x0001),
        irm: address(0x0002),
        lltv: 0.8e18
    });
}

// ── MorphoBlueBorrowModule tests ──────────────────────────────────────────────

contract MorphoBlueBorrowModuleTest is Test {
    MockERC20 loanToken;
    MockERC20 collateralToken;
    MockMorpho morpho;
    MockPermit3 permit3;
    MorphoBlueBorrowModule module;
    MarketParams market;

    address user = address(0xABCD);
    address receiver = address(0xCAFE);
    uint256 constant AMOUNT = 1000e6;

    function setUp() public {
        loanToken = new MockERC20();
        collateralToken = new MockERC20();
        morpho = new MockMorpho(loanToken, collateralToken);
        permit3 = new MockPermit3();
        module = new MorphoBlueBorrowModule(address(permit3), address(morpho));
        market = dummyMarketParams(address(loanToken), address(collateralToken));
    }

    function test_borrow_withAuthSig() public {
        // data = abi.encode(MarketParams, nonce, deadline, v, r, s)
        bytes memory data = abi.encode(market, uint256(0), block.timestamp + 1 hours, uint8(27), bytes32(0), bytes32(0));

        vm.prank(address(permit3));
        module.takeOnBehalf(user, AMOUNT, receiver, data);

        assertTrue(morpho.authWithSigCalled(), "setAuthorizationWithSig not called");
        assertEq(morpho.lastAuthorizer(), user);
        assertEq(morpho.lastAuthorized(), address(module));
        assertEq(loanToken.balanceOf(receiver), AMOUNT);
    }

    function test_borrow_withoutSig_standingAuth() public {
        // Pre-authorize via on-chain call.
        vm.prank(user);
        morpho.setAuthorization(address(module), true);

        bytes memory data = abi.encode(market);

        vm.prank(address(permit3));
        module.takeOnBehalf(user, AMOUNT, receiver, data);

        assertFalse(morpho.authWithSigCalled());
        assertEq(loanToken.balanceOf(receiver), AMOUNT);
    }

    function test_borrow_revertsIfNotAuthorizedAndNoSig() public {
        bytes memory data = abi.encode(market);
        vm.prank(address(permit3));
        vm.expectRevert("morpho: not authorized");
        module.takeOnBehalf(user, AMOUNT, receiver, data);
    }

    function test_borrow_revertsIfNotPermit3() public {
        bytes memory data = abi.encode(market);
        vm.expectRevert(MorphoBlueBorrowModule.OnlyPermit3.selector);
        module.takeOnBehalf(user, AMOUNT, receiver, data);
    }
}

// ── MorphoBlueWithdrawCollateralModule tests ──────────────────────────────────

contract MorphoBlueWithdrawCollateralModuleTest is Test {
    MockERC20 loanToken;
    MockERC20 collateralToken;
    MockMorpho morpho;
    MockPermit3 permit3;
    MorphoBlueWithdrawCollateralModule module;
    MarketParams market;

    address user = address(0xABCD);
    address receiver = address(0xCAFE);
    uint256 constant AMOUNT = 500e18;

    function setUp() public {
        loanToken = new MockERC20();
        collateralToken = new MockERC20();
        morpho = new MockMorpho(loanToken, collateralToken);
        permit3 = new MockPermit3();
        module = new MorphoBlueWithdrawCollateralModule(address(permit3), address(morpho));
        market = dummyMarketParams(address(loanToken), address(collateralToken));

        morpho.setPositionCollateral(market, user, uint128(AMOUNT * 10));
    }

    function test_withdrawCollateral_withAuthSig() public {
        // data = abi.encode(MarketParams, BalanceMode=0, nonce, deadline, v, r, s)
        bytes memory data = abi.encode(
            market,
            uint8(0), // BalanceMode = Exact, explicit slot required
            uint256(0), block.timestamp + 1 hours, uint8(27), bytes32(0), bytes32(0)
        );

        vm.prank(address(permit3));
        module.takeOnBehalf(user, AMOUNT, receiver, data);

        assertTrue(morpho.authWithSigCalled());
        assertEq(morpho.lastAuthorizer(), user);
        assertEq(morpho.lastAuthorized(), address(module));
        assertEq(collateralToken.balanceOf(receiver), AMOUNT);
    }

    function test_withdrawCollateral_withoutSig_standingAuth() public {
        vm.prank(user);
        morpho.setAuthorization(address(module), true);

        bytes memory data = abi.encode(market);

        vm.prank(address(permit3));
        module.takeOnBehalf(user, AMOUNT, receiver, data);

        assertFalse(morpho.authWithSigCalled());
        assertEq(collateralToken.balanceOf(receiver), AMOUNT);
    }

    function test_withdrawCollateral_revertsIfNotAuthorizedAndNoSig() public {
        bytes memory data = abi.encode(market);
        vm.prank(address(permit3));
        vm.expectRevert("morpho: not authorized");
        module.takeOnBehalf(user, AMOUNT, receiver, data);
    }

    function test_withdrawCollateral_revertsIfNotPermit3() public {
        bytes memory data = abi.encode(market);
        vm.expectRevert(MorphoBlueWithdrawCollateralModule.OnlyPermit3.selector);
        module.takeOnBehalf(user, AMOUNT, receiver, data);
    }
}
