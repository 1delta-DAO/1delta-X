// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ILendingModule
/// @notice Interface for lending protocol adapters.
///         Each supported lending protocol (Aave, Compound, Morpho, etc.) gets a module
///         that implements this interface. The Settlement contract calls these
///         modules to execute lending operations on behalf of makers.
/// @dev Modules must be approved/whitelisted by the Settlement owner.
///      Users must pre-approve the module for token transfers and credit delegation.
///      The `data` parameter is protocol-specific and opaque to the Settlement.
///      Examples:
///        - Aave V3: abi.encode(interestRateMode)      // 1=stable, 2=variable
///        - Morpho:  abi.encode(MarketParams)           // full market identification
///        - Compound V3: abi.encode(cometAddress)       // specific Comet market
interface ILendingModule {
    /// @notice Deposit asset as collateral on behalf of `onBehalfOf`
    function deposit(address asset, uint256 amount, address onBehalfOf, bytes calldata data) external;

    /// @notice Withdraw collateral to `to`
    function withdraw(address asset, uint256 amount, address onBehalfOf, address to, bytes calldata data) external;

    /// @notice Borrow asset on behalf of `onBehalfOf`, sending proceeds to `to`
    function borrow(address asset, uint256 amount, address onBehalfOf, address to, bytes calldata data) external;

    /// @notice Repay debt on behalf of `onBehalfOf`
    function repay(address asset, uint256 amount, address onBehalfOf, bytes calldata data) external;

    /// @notice Get the user's collateral balance for an asset in the protocol
    /// @return The collateral balance in underlying asset units
    function getCollateralBalance(address asset, address user, bytes calldata data) external view returns (uint256);

    /// @notice Get the user's debt balance for an asset in the protocol
    /// @return The debt balance in underlying asset units
    function getDebtBalance(address asset, address user, bytes calldata data) external view returns (uint256);

    /// @notice Get the user's lending/supply balance (non-collateral deposits, e.g. Morpho loan-token supply)
    /// @return The supply balance in underlying asset units
    function getLendingBalance(address asset, address user, bytes calldata data) external view returns (uint256);
}
