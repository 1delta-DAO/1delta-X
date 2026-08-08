// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MarketParams} from "../../src/interfaces/IMorphoBlue.sol";

// ── Shared mocks + helper for the Morpho taker-module unit tests ──────────────
//
// This file holds the mocks (`MockERC20`, `MockMorpho`, `MockPermit3`) and the
// `dummyMarketParams` helper imported by `MorphoBlueCombinedTakerModule.t.sol`.
// Keep the symbols + import path stable so that test still compiles.

// ── Mocks ────────────────────────────────────────────────────────────────────

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

    struct Signature {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct Position {
        uint256 supplyShares;
        uint128 borrowShares;
        uint128 collateral;
    }

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

    // Test helper: seed loan-supply state (1 share == 1 asset in this mock).
    function setPositionSupplyShares(MarketParams memory mp, address user, uint256 shares) external {
        positions[keccak256(abi.encode(mp))][user].supplyShares = shares;
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

    // Earn-side supply: record the call + credit shares (1 share == 1 asset).
    // Permissive on token custody — the unit layer tests module WIRING; real
    // token flow is the fork suites' job.
    address public lastSupplyOnBehalf;
    uint256 public lastSupplyAssets;

    function supply(MarketParams memory mp, uint256 assets, uint256 shares, address onBehalf, bytes calldata)
        external
        returns (uint256, uint256)
    {
        require((assets == 0) != (shares == 0), "morpho: inconsistent input");
        positions[keccak256(abi.encode(mp))][onBehalf].supplyShares += assets;
        lastSupplyOnBehalf = onBehalf;
        lastSupplyAssets = assets;
        return (assets, assets);
    }

    // Loan-asset withdraw: exact-assets XOR by-shares, like the real singleton.
    // 1 share == 1 asset keeps the unit math trivial.
    function withdraw(MarketParams memory mp, uint256 assets, uint256 shares, address onBehalf, address receiver)
        external
        returns (uint256, uint256)
    {
        require(authorization[onBehalf][msg.sender], "morpho: not authorized");
        require((assets == 0) != (shares == 0), "morpho: inconsistent input");
        uint256 out = assets != 0 ? assets : shares;
        positions[keccak256(abi.encode(mp))][onBehalf].supplyShares -= out;
        loanToken.mint(receiver, out);
        return (out, out);
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
