// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ILendingModule} from "../interfaces/ILendingModule.sol";

/// @notice Minimal Compound V2 / Venus cToken interface
interface ICToken {
    function mint(uint256 mintAmount) external returns (uint256);
    function mintBehalf(address receiver, uint256 mintAmount) external returns (uint256);
    function redeem(uint256 redeemTokens) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
    function borrowBehalf(address borrower, uint256 borrowAmount) external returns (uint256);
    function repayBorrowBehalf(address borrower, uint256 repayAmount) external returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function balanceOfUnderlying(address owner) external returns (uint256);
    function borrowBalanceStored(address account) external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
}

/// @title CompoundV2LendingModule
/// @notice ILendingModule adapter for Compound V2, Venus, and forks.
/// @dev `data` encoding:
///      abi.encode(address cToken, uint8 variant)
///        - cToken: the cToken/vToken contract address
///        - variant: 0=Venus (mintBehalf/borrowBehalf), 1=classic Compound (mint/borrow), 2=iToken style
contract CompoundV2LendingModule is ILendingModule {
    function deposit(address asset, uint256 amount, address onBehalfOf, bytes calldata data) external override {
        (address cToken, uint8 variant) = abi.decode(data, (address, uint8));

        IERC20(asset).approve(cToken, amount);

        if (variant == 0) {
            // Venus-style: mintBehalf deposits directly to receiver
            ICToken(cToken).mintBehalf(onBehalfOf, amount);
        } else {
            // Classic: mint to this contract, then transfer cTokens
            ICToken(cToken).mint(amount);
            if (onBehalfOf != address(this)) {
                uint256 cBalance = ICToken(cToken).balanceOf(address(this));
                IERC20(cToken).transfer(onBehalfOf, cBalance);
            }
        }
    }

    function withdraw(address asset, uint256 amount, address onBehalfOf, address to, bytes calldata data)
        external
        override
    {
        (address cToken,) = abi.decode(data, (address, uint8));

        // Transfer cTokens from user to this contract, then redeem
        // (Requires the settlement to have transferred cTokens here already,
        //  or the user to have approved this module for cToken transfers)
        ICToken(cToken).redeemUnderlying(amount);

        if (to != address(this)) {
            IERC20(asset).transfer(to, amount);
        }
    }

    function borrow(address asset, uint256 amount, address onBehalfOf, address to, bytes calldata data)
        external
        override
    {
        (address cToken,) = abi.decode(data, (address, uint8));

        ICToken(cToken).borrowBehalf(onBehalfOf, amount);

        if (to != address(this)) {
            IERC20(asset).transfer(to, amount);
        }
    }

    function repay(address asset, uint256 amount, address onBehalfOf, bytes calldata data) external override {
        (address cToken,) = abi.decode(data, (address, uint8));

        IERC20(asset).approve(cToken, amount);
        ICToken(cToken).repayBorrowBehalf(onBehalfOf, amount);
    }

    // ── Balance views ──

    /// @notice Returns collateral in underlying units: cToken.balanceOf * exchangeRate / 1e18
    function getCollateralBalance(address, address user, bytes calldata data)
        external
        view
        override
        returns (uint256)
    {
        (address cToken,) = abi.decode(data, (address, uint8));
        uint256 cBalance = ICToken(cToken).balanceOf(user);
        uint256 rate = ICToken(cToken).exchangeRateStored();
        return (cBalance * rate) / 1e18;
    }

    /// @notice Returns the stored borrow balance (without accruing interest first)
    function getDebtBalance(address, address user, bytes calldata data)
        external
        view
        override
        returns (uint256)
    {
        (address cToken,) = abi.decode(data, (address, uint8));
        return ICToken(cToken).borrowBalanceStored(user);
    }

    /// @notice For Compound V2, lending = collateral (same cToken)
    function getLendingBalance(address asset, address user, bytes calldata data)
        external
        view
        override
        returns (uint256)
    {
        (address cToken,) = abi.decode(data, (address, uint8));
        uint256 cBalance = ICToken(cToken).balanceOf(user);
        uint256 rate = ICToken(cToken).exchangeRateStored();
        return (cBalance * rate) / 1e18;
    }
}
