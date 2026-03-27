// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ILendingModule} from "../../src/interfaces/ILendingModule.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Minimal mock that simulates a lending protocol.
///         Tracks deposits/borrows per user for test assertions.
///         Moves real (mock) ERC20 tokens so balance checks work.
contract MockLendingModule is ILendingModule {
    struct Position {
        uint256 deposited;
        uint256 borrowed;
    }

    /// @notice user → asset → position
    mapping(address => mapping(address => Position)) public positions;

    /// @notice Last `data` received per call (for testing that data is forwarded correctly)
    bytes public lastData;

    // ── ILendingModule ──

    function deposit(address asset, uint256 amount, address onBehalfOf, bytes calldata data) external override {
        lastData = data;
        MockERC20(asset).transferFrom(msg.sender, address(this), amount);
        positions[onBehalfOf][asset].deposited += amount;
    }

    function withdraw(address asset, uint256 amount, address onBehalfOf, address to, bytes calldata data)
        external
        override
    {
        lastData = data;
        positions[onBehalfOf][asset].deposited -= amount;
        MockERC20(asset).transfer(to, amount);
    }

    function borrow(address asset, uint256 amount, address onBehalfOf, address to, bytes calldata data)
        external
        override
    {
        lastData = data;
        positions[onBehalfOf][asset].borrowed += amount;
        MockERC20(asset).transfer(to, amount);
    }

    function repay(address asset, uint256 amount, address onBehalfOf, bytes calldata data) external override {
        lastData = data;
        MockERC20(asset).transferFrom(msg.sender, address(this), amount);
        positions[onBehalfOf][asset].borrowed -= amount;
    }

    // ── Balance views ──

    function getCollateralBalance(address asset, address user, bytes calldata) external view override returns (uint256) {
        return positions[user][asset].deposited;
    }

    function getDebtBalance(address asset, address user, bytes calldata) external view override returns (uint256) {
        return positions[user][asset].borrowed;
    }

    function getLendingBalance(address asset, address user, bytes calldata) external view override returns (uint256) {
        return positions[user][asset].deposited;
    }
}
