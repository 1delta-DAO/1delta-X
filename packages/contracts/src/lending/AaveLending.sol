// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ILendingModule} from "../interfaces/ILendingModule.sol";

/// @notice Minimal Aave V3 Pool interface
interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        returns (uint256);
    function getReserveData(address asset) external view returns (AaveReserveData memory);
}

struct AaveReserveData {
    uint256 configuration;
    uint128 liquidityIndex;
    uint128 currentLiquidityRate;
    uint128 variableBorrowIndex;
    uint128 currentVariableBorrowRate;
    uint128 currentStableBorrowRate;
    uint40 lastUpdateTimestamp;
    uint16 id;
    address aTokenAddress;
    address stableDebtTokenAddress;
    address variableDebtTokenAddress;
    address interestRateStrategyAddress;
    uint128 accruedToTreasury;
    uint128 unbacked;
    uint128 isolationModeTotalDebt;
}

/// @notice Minimal Aave V2 Pool interface (different function signatures)
interface IAaveV2Pool {
    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;
    function repay(address asset, uint256 amount, uint256 rateMode, address onBehalfOf) external returns (uint256);
}

/// @title AaveLendingModule
/// @notice ILendingModule adapter for Aave V2 and V3 pools.
/// @dev `data` encoding:
///      abi.encode(address pool, uint8 version, uint256 interestRateMode)
///        - pool: the Aave pool/lending-pool address
///        - version: 2 for Aave V2 forks, 3 for Aave V3 (default)
///        - interestRateMode: 0=none (some forks), 1=stable, 2=variable
///      For deposits and withdrawals, interestRateMode is ignored.
///      For Aave V3 forks that dropped the IR mode param, set mode=0.
contract AaveLendingModule is ILendingModule {
    function deposit(address asset, uint256 amount, address onBehalfOf, bytes calldata data) external override {
        (address pool, uint8 version,) = abi.decode(data, (address, uint8, uint256));

        IERC20(asset).approve(pool, amount);

        if (version == 2) {
            IAaveV2Pool(pool).deposit(asset, amount, onBehalfOf, 0);
        } else {
            IAaveV3Pool(pool).supply(asset, amount, onBehalfOf, 0);
        }
    }

    function withdraw(address asset, uint256 amount, address onBehalfOf, address to, bytes calldata data)
        external
        override
    {
        (address pool,,) = abi.decode(data, (address, uint8, uint256));
        // Aave withdraw sends to `to` directly; caller must hold aTokens or have allowance
        // onBehalfOf is the aToken holder — the settlement transferFrom'd aTokens if needed
        IAaveV3Pool(pool).withdraw(asset, amount, to);
    }

    function borrow(address asset, uint256 amount, address onBehalfOf, address to, bytes calldata data)
        external
        override
    {
        (address pool,, uint256 interestRateMode) = abi.decode(data, (address, uint8, uint256));

        // Aave borrows on behalf of the user (requires credit delegation to this module)
        IAaveV3Pool(pool).borrow(asset, amount, interestRateMode, 0, onBehalfOf);

        // Transfer borrowed tokens to the intended receiver
        if (to != address(this)) {
            IERC20(asset).transfer(to, amount);
        }
    }

    function repay(address asset, uint256 amount, address onBehalfOf, bytes calldata data) external override {
        (address pool,, uint256 interestRateMode) = abi.decode(data, (address, uint8, uint256));

        IERC20(asset).approve(pool, amount);
        IAaveV3Pool(pool).repay(asset, amount, interestRateMode, onBehalfOf);
    }

    // ── Balance views ──

    /// @notice Returns aToken balance (collateral position)
    function getCollateralBalance(address asset, address user, bytes calldata data)
        external
        view
        override
        returns (uint256)
    {
        (address pool,,) = abi.decode(data, (address, uint8, uint256));
        AaveReserveData memory reserve = IAaveV3Pool(pool).getReserveData(asset);
        return IERC20(reserve.aTokenAddress).balanceOf(user);
    }

    /// @notice Returns variable + stable debt token balance
    function getDebtBalance(address asset, address user, bytes calldata data)
        external
        view
        override
        returns (uint256)
    {
        (address pool,, uint256 interestRateMode) = abi.decode(data, (address, uint8, uint256));
        AaveReserveData memory reserve = IAaveV3Pool(pool).getReserveData(asset);
        if (interestRateMode == 1) {
            return IERC20(reserve.stableDebtTokenAddress).balanceOf(user);
        }
        return IERC20(reserve.variableDebtTokenAddress).balanceOf(user);
    }

    /// @notice For Aave, lending balance is the same as collateral (aToken)
    function getLendingBalance(address asset, address user, bytes calldata data)
        external
        view
        override
        returns (uint256)
    {
        (address pool,,) = abi.decode(data, (address, uint8, uint256));
        AaveReserveData memory reserve = IAaveV3Pool(pool).getReserveData(asset);
        return IERC20(reserve.aTokenAddress).balanceOf(user);
    }
}
