// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ILendingModule} from "../interfaces/ILendingModule.sol";

/// @notice Minimal Compound V3 (Comet) interface
interface IComet {
    function supplyTo(address dst, address asset, uint256 amount) external;
    function withdrawFrom(address src, address dst, address asset, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function borrowBalanceOf(address account) external view returns (uint256);
    function userCollateral(address account, address asset) external view returns (uint128, uint128);
}

/// @title CompoundV3LendingModule
/// @notice ILendingModule adapter for Compound V3 (Comet) markets.
/// @dev `data` encoding:
///      abi.encode(address comet)
///        - comet: the specific Comet market contract (e.g. USDC market, WETH market)
///      Compound V3 uses the same supplyTo/withdrawFrom for both base and collateral assets.
///      The comet contract distinguishes internally based on whether the asset is the base token.
contract CompoundV3LendingModule is ILendingModule {
    function deposit(address asset, uint256 amount, address onBehalfOf, bytes calldata data) external override {
        address comet = abi.decode(data, (address));

        IERC20(asset).approve(comet, amount);
        IComet(comet).supplyTo(onBehalfOf, asset, amount);
    }

    function withdraw(address asset, uint256 amount, address onBehalfOf, address to, bytes calldata data)
        external
        override
    {
        address comet = abi.decode(data, (address));

        // Requires that the settlement/module has been allowed via Comet's allow() by the user
        IComet(comet).withdrawFrom(onBehalfOf, to, asset, amount);
    }

    function borrow(address asset, uint256 amount, address onBehalfOf, address to, bytes calldata data)
        external
        override
    {
        address comet = abi.decode(data, (address));

        // In Compound V3, borrow = withdraw of the base asset
        IComet(comet).withdrawFrom(onBehalfOf, to, asset, amount);
    }

    function repay(address asset, uint256 amount, address onBehalfOf, bytes calldata data) external override {
        address comet = abi.decode(data, (address));

        // In Compound V3, repay = supply of the base asset on behalf of the borrower
        IERC20(asset).approve(comet, amount);
        IComet(comet).supplyTo(onBehalfOf, asset, amount);
    }

    // ── Balance views ──

    /// @notice Returns the user's collateral balance for a specific asset in the Comet market
    function getCollateralBalance(address asset, address user, bytes calldata data)
        external
        view
        override
        returns (uint256)
    {
        address comet = abi.decode(data, (address));
        (uint128 balance,) = IComet(comet).userCollateral(user, asset);
        return balance;
    }

    /// @notice Returns the user's borrow balance (base asset debt)
    function getDebtBalance(address, address user, bytes calldata data)
        external
        view
        override
        returns (uint256)
    {
        address comet = abi.decode(data, (address));
        return IComet(comet).borrowBalanceOf(user);
    }

    /// @notice Returns the user's base asset supply balance (lending)
    function getLendingBalance(address, address user, bytes calldata data)
        external
        view
        override
        returns (uint256)
    {
        address comet = abi.decode(data, (address));
        return IComet(comet).balanceOf(user);
    }
}
