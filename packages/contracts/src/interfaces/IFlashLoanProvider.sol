// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Minimal flash loan interface (Aave V3 style)
interface IFlashLoanProvider {
    function flashLoan(address receiver, address[] calldata assets, uint256[] calldata amounts, bytes calldata params)
        external;
}

/// @notice Callback interface the flash loan provider calls
interface IFlashLoanReceiver {
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool);
}
