// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Order} from "../types/DataTypes.sol";
import {IFlashLoanProvider} from "../interfaces/IFlashLoanProvider.sol";
import {SolverBase} from "./SolverBase.sol";

/// @title LeverageSolver
/// @notice Concrete solver that creates leveraged lending positions.
///
///  Example: 3× long ETH/USDC
///  ───────────────────────────
///  User has 1 WETH and signs an order for:
///    - Deposit 3 WETH to Aave
///    - Borrow 2 WETH-equivalent USDC from Aave
///    - Conversion: USDC→WETH at dutch-auction rate
///
///  Solver calls `executeLeverage()`:
///    1. Flash-loan 4000 USDC from Aave
///    2. In callback:
///       a. Swap 4000 USDC → ~2 WETH on DEX
///       b. Approve Settlement for the 2 WETH
///       c. settlement.settle(order, sig) executes:
///          - Pulls 2 WETH from solver → maker (conversion)
///          - Deposits 3 WETH (1 maker + 2 from solver) into Aave
///          - Borrows 4000 USDC from Aave → Settlement → solver
///       d. Repay flash-loan (4000 USDC + premium)
///    3. Solver profits from spread between dutch-auction rate and actual DEX rate
///
contract LeverageSolver is SolverBase {
    IFlashLoanProvider public flashLoanProvider;
    address public dexAggregator;

    constructor(address _settlement, address _operator, address _flashLoanProvider, address _dexAggregator)
        SolverBase(_settlement, _operator)
    {
        flashLoanProvider = IFlashLoanProvider(_flashLoanProvider);
        dexAggregator = _dexAggregator;
    }

    /// @notice Entry point: initiate a leverage position via flash loan
    /// @param order    The maker-signed order
    /// @param sig      EIP-712 signature
    /// @param flashAssets  Assets to flash-loan
    /// @param flashAmounts Amounts to flash-loan
    /// @param routeData    DEX swap calldata (encoded by off-chain solver)
    function executeLeverage(
        Order calldata order,
        bytes calldata sig,
        address[] calldata flashAssets,
        uint256[] calldata flashAmounts,
        bytes calldata routeData
    ) external onlyOperator {
        // Encode everything the callback needs
        bytes memory params = abi.encode(order, sig, routeData);

        // Initiate flash loan — callback will handle the rest
        flashLoanProvider.flashLoan(address(this), flashAssets, flashAmounts, params);
    }

    /// @dev Called inside the flash-loan callback.
    ///      At this point we hold the flash-loaned tokens.
    function _executeStrategy(
        Order memory order,
        bytes memory sig,
        address[] calldata flashAssets,
        uint256[] calldata flashAmounts,
        uint256[] calldata, /* flashPremiums */
        bytes memory strategyData
    ) internal override {
        bytes memory routeData = strategyData;

        // Step 1: Swap flash-loaned tokens → conversion tokenOut
        // e.g. USDC → WETH (the collateral the maker needs)
        address tokenIn = flashAssets[0];
        address tokenOut = order.conversions[0].tokenOut;
        uint256 swapOut = _swap(dexAggregator, tokenIn, tokenOut, flashAmounts[0], routeData);

        // Step 2: Approve Settlement to pull the swapped tokens from us
        IERC20(tokenOut).approve(address(settlement), swapOut);

        // Step 3: Settle the order
        //   - Settlement pulls tokenOut (WETH) from us → sends to maker
        //   - Settlement deposits maker's WETH into lending protocol
        //   - Settlement borrows USDC on maker's behalf → sends to us
        _settleOrder(order, sig);

        // After settlement, we hold the borrowed tokens (e.g. USDC).
        // The flash-loan callback in SolverBase will approve repayment.
        // Any surplus after repayment is profit.
    }
}
