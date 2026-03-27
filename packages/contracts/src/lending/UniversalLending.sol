// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ILendingModule} from "../interfaces/ILendingModule.sol";

/// @title UniversalLendingModule
/// @notice ILendingModule router that delegates to protocol-specific modules.
///         Instead of deploying this as a single module, the Settlement can
///         whitelist each protocol module independently. This contract is provided
///         as an optional aggregator for setups that prefer a single module address.
/// @dev `data` encoding:
///      abi.encode(uint16 lenderId, bytes innerData)
///        - lenderId: protocol identifier (see LenderId enum)
///        - innerData: protocol-specific data, forwarded to the sub-module
contract UniversalLendingModule is ILendingModule {
    enum LenderId {
        AAVE_V3,        // 0
        AAVE_V2,        // 1
        COMPOUND_V3,    // 2
        COMPOUND_V2,    // 3
        MORPHO,         // 4
        SILO_V2         // 5
    }

    /// @notice lenderId → module address
    mapping(uint256 => address) public modules;
    address public owner;

    error UnknownLender();
    error OnlyOwner();

    constructor() {
        owner = msg.sender;
    }

    function setLenderModule(uint256 lenderId, address module) external {
        if (msg.sender != owner) revert OnlyOwner();
        modules[lenderId] = module;
    }

    // ── ILendingModule delegation ──

    function deposit(address asset, uint256 amount, address onBehalfOf, bytes calldata data) external override {
        (uint16 lenderId, bytes memory innerData) = abi.decode(data, (uint16, bytes));
        address module = _getModule(lenderId);

        IERC20(asset).approve(module, amount);
        ILendingModule(module).deposit(asset, amount, onBehalfOf, innerData);
    }

    function withdraw(address asset, uint256 amount, address onBehalfOf, address to, bytes calldata data)
        external
        override
    {
        (uint16 lenderId, bytes memory innerData) = abi.decode(data, (uint16, bytes));
        address module = _getModule(lenderId);

        ILendingModule(module).withdraw(asset, amount, onBehalfOf, to, innerData);
    }

    function borrow(address asset, uint256 amount, address onBehalfOf, address to, bytes calldata data)
        external
        override
    {
        (uint16 lenderId, bytes memory innerData) = abi.decode(data, (uint16, bytes));
        address module = _getModule(lenderId);

        ILendingModule(module).borrow(asset, amount, onBehalfOf, to, innerData);
    }

    function repay(address asset, uint256 amount, address onBehalfOf, bytes calldata data) external override {
        (uint16 lenderId, bytes memory innerData) = abi.decode(data, (uint16, bytes));
        address module = _getModule(lenderId);

        IERC20(asset).approve(module, amount);
        ILendingModule(module).repay(asset, amount, onBehalfOf, innerData);
    }

    // ── Balance views (delegated) ──

    function getCollateralBalance(address asset, address user, bytes calldata data)
        external
        view
        override
        returns (uint256)
    {
        (uint16 lenderId, bytes memory innerData) = abi.decode(data, (uint16, bytes));
        return ILendingModule(_getModule(lenderId)).getCollateralBalance(asset, user, innerData);
    }

    function getDebtBalance(address asset, address user, bytes calldata data)
        external
        view
        override
        returns (uint256)
    {
        (uint16 lenderId, bytes memory innerData) = abi.decode(data, (uint16, bytes));
        return ILendingModule(_getModule(lenderId)).getDebtBalance(asset, user, innerData);
    }

    function getLendingBalance(address asset, address user, bytes calldata data)
        external
        view
        override
        returns (uint256)
    {
        (uint16 lenderId, bytes memory innerData) = abi.decode(data, (uint16, bytes));
        return ILendingModule(_getModule(lenderId)).getLendingBalance(asset, user, innerData);
    }

    function _getModule(uint16 lenderId) internal view returns (address module) {
        module = modules[lenderId];
        if (module == address(0)) revert UnknownLender();
    }
}
