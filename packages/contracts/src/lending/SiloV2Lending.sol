// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ILendingModule} from "../interfaces/ILendingModule.sol";

/// @notice Minimal Silo V2 interface
interface ISiloV2 {
    // Deposit variants
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function deposit(uint256 assets, address receiver, uint256 collateralType) external returns (uint256 shares);

    // Withdraw variants
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner, uint256 collateralType)
        external
        returns (uint256 shares);

    // Borrow
    function borrow(uint256 assets, address receiver, address borrower) external returns (uint256 shares);
    function borrowShares(uint256 shares, address receiver, address borrower) external returns (uint256 assets);

    // Repay
    function repay(uint256 assets, address borrower) external returns (uint256 shares);
    function maxRepay(address borrower) external view returns (uint256);

    // Balance views
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
    function maxWithdraw(address owner) external view returns (uint256);
}

/// @title SiloV2LendingModule
/// @notice ILendingModule adapter for Silo V2 markets.
/// @dev `data` encoding:
///      abi.encode(address silo, uint8 collateralType)
///        - silo: the Silo V2 market contract
///        - collateralType: 0=protected, 1=default (non-protected), 2+=other
///          collateralType=1 uses the simpler function signatures without the enum param
contract SiloV2LendingModule is ILendingModule {
    function deposit(address asset, uint256 amount, address onBehalfOf, bytes calldata data) external override {
        (address silo, uint8 collateralType) = abi.decode(data, (address, uint8));

        IERC20(asset).approve(silo, amount);

        if (collateralType == 1) {
            ISiloV2(silo).deposit(amount, onBehalfOf);
        } else {
            ISiloV2(silo).deposit(amount, onBehalfOf, collateralType);
        }
    }

    function withdraw(address asset, uint256 amount, address onBehalfOf, address to, bytes calldata data)
        external
        override
    {
        (address silo, uint8 collateralType) = abi.decode(data, (address, uint8));

        if (collateralType == 1) {
            ISiloV2(silo).withdraw(amount, to, onBehalfOf);
        } else {
            ISiloV2(silo).withdraw(amount, to, onBehalfOf, collateralType);
        }
    }

    function borrow(address asset, uint256 amount, address onBehalfOf, address to, bytes calldata data)
        external
        override
    {
        (address silo,) = abi.decode(data, (address, uint8));

        ISiloV2(silo).borrow(amount, to, onBehalfOf);
    }

    function repay(address asset, uint256 amount, address onBehalfOf, bytes calldata data) external override {
        (address silo,) = abi.decode(data, (address, uint8));

        IERC20(asset).approve(silo, amount);
        ISiloV2(silo).repay(amount, onBehalfOf);
    }

    // ── Balance views ──

    /// @notice Returns the user's collateral in underlying (silo share → asset conversion)
    function getCollateralBalance(address, address user, bytes calldata data)
        external
        view
        override
        returns (uint256)
    {
        (address silo,) = abi.decode(data, (address, uint8));
        return ISiloV2(silo).maxWithdraw(user);
    }

    /// @notice Returns the user's max repayable debt
    function getDebtBalance(address, address user, bytes calldata data)
        external
        view
        override
        returns (uint256)
    {
        (address silo,) = abi.decode(data, (address, uint8));
        return ISiloV2(silo).maxRepay(user);
    }

    /// @notice For Silo V2, lending balance = collateral balance (same share token)
    function getLendingBalance(address, address user, bytes calldata data)
        external
        view
        override
        returns (uint256)
    {
        (address silo,) = abi.decode(data, (address, uint8));
        return ISiloV2(silo).maxWithdraw(user);
    }
}
