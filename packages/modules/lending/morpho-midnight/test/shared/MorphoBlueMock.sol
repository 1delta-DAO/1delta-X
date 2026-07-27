// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MarketParams, Position, Id, MarketParamsLib} from "../../../morpho-blue/src/interfaces/IMorphoBlue.sol";

interface IERC20Min {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

/// @notice Minimal Morpho Blue singleton stand-in — just the DESTINATION surface a
///         Midnight→Blue migration touches: `supplyCollateral` (permissionless
///         inflow) and `borrow` (gated by Morpho-native `setAuthorization`). 1:1
///         asset↔share accounting, no interest accrual (Morpho's concern, not the
///         migration's), real token pulls/pushes so fund-flow can be asserted, and
///         positions keyed by the same `MarketParamsLib.id` the Blue modules
///         compute. Mirrors the mock-based approach of {MidnightMock}; the fork
///         suite in the morpho-blue package covers real Morpho economics.
contract MorphoBlueMock {
    using MarketParamsLib for MarketParams;

    // id → user → position
    mapping(bytes32 => mapping(address => Position)) internal _pos;
    // onBehalf → operator → allowed
    mapping(address => mapping(address => bool)) public isAuthorized;

    string public lastFn;
    address public lastReceiver;

    error Unauthorized();

    function setAuthorization(address authorized, bool newIsAuthorized) external {
        isAuthorized[msg.sender][authorized] = newIsAuthorized;
    }

    function position(Id id, address user) external view returns (Position memory) {
        return _pos[Id.unwrap(id)][user];
    }

    /// @dev Permissionless inflow: pulls `assets` collateral from `msg.sender` and
    ///      credits it to `onBehalf`.
    function supplyCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, bytes memory)
        external
    {
        lastFn = "supplyCollateral";
        IERC20Min(marketParams.collateralToken).transferFrom(msg.sender, address(this), assets);
        _pos[Id.unwrap(marketParams.id())][onBehalf].collateral += uint128(assets);
    }

    /// @dev Value-out: `msg.sender == onBehalf` or `isAuthorized[onBehalf][sender]`.
    ///      1:1 shares↔assets; sends `assets` loan token to `receiver`.
    function borrow(MarketParams memory marketParams, uint256 assets, uint256, address onBehalf, address receiver)
        external
        returns (uint256, uint256)
    {
        if (msg.sender != onBehalf && !isAuthorized[onBehalf][msg.sender]) revert Unauthorized();
        lastFn = "borrow";
        lastReceiver = receiver;
        _pos[Id.unwrap(marketParams.id())][onBehalf].borrowShares += uint128(assets);
        IERC20Min(marketParams.loanToken).transfer(receiver, assets);
        return (assets, assets);
    }

    // ──────────────────── test-only reads ────────────────────

    function collateralOf(MarketParams memory marketParams, address user) external view returns (uint256) {
        return _pos[Id.unwrap(marketParams.id())][user].collateral;
    }

    function borrowSharesOf(MarketParams memory marketParams, address user) external view returns (uint256) {
        return _pos[Id.unwrap(marketParams.id())][user].borrowShares;
    }
}
