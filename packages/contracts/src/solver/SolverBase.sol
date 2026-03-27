// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Order} from "../types/DataTypes.sol";
import {Settlement} from "../settlement/Settlement.sol";
import {IFlashLoanReceiver} from "../interfaces/IFlashLoanProvider.sol";
import {IDexAggregator} from "../interfaces/IDexAggregator.sol";

/// @title SolverBase
/// @notice Example base contract for solvers participating in the lending settlement.
///
///  Flash-loan composition pattern
///  ──────────────────────────────
///  For a leverage-long (e.g. 3× ETH/USDC on Aave):
///
///    ┌─ Solver calls executeLeverage() ──────────────────────────────────────┐
///    │                                                                       │
///    │  1. Flash-loan USDC from Aave/Balancer                               │
///    │  2. Swap USDC → WETH via DEX aggregator                              │
///    │  3. Approve Settlement for the WETH                                  │
///    │  4. Settlement.settle(order, sig)                                     │
///    │     ├── pulls WETH from solver → sends to maker                      │
///    │     ├── deposits WETH into lending protocol (maker's collateral)     │
///    │     ├── borrows USDC from lending protocol (maker's debt)            │
///    │     └── sends borrowed USDC to solver                                │
///    │  5. Repay flash-loan with received USDC + premium                    │
///    │  6. Keep any remaining profit                                        │
///    │                                                                       │
///    └──────────────────────────────────────────────────────────────────────┘
///
///  For a deleverage / unwind the flow is reversed:
///
///    1. Flash-loan USDC
///    2. Settlement.settle() → repays maker's USDC debt, withdraws WETH collateral
///    3. Swap WETH → USDC via DEX
///    4. Repay flash-loan
///
///  The Settlement contract never sees the flash loan — it only validates
///  the signed lending operations and conversion rates.
///
abstract contract SolverBase is IFlashLoanReceiver {
    Settlement public immutable settlement;
    address public operator;

    error OnlyOperator();
    error OnlyFlashLoanProvider();
    error FlashLoanFailed();

    modifier onlyOperator() {
        if (msg.sender != operator) revert OnlyOperator();
        _;
    }

    constructor(address _settlement, address _operator) {
        settlement = Settlement(_settlement);
        operator = _operator;
    }

    // ──────────────────── Flash-loan callback ────────────────────

    /// @notice Called by the flash-loan provider during executeOperation.
    ///         Decodes params to determine which settlement strategy to run.
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external virtual override returns (bool) {
        // Decode the settlement payload
        (Order memory order, bytes memory sig, bytes memory strategyData) =
            abi.decode(params, (Order, bytes, bytes));

        // Execute the strategy (leverage, deleverage, migrate, etc.)
        _executeStrategy(order, sig, assets, amounts, premiums, strategyData);

        // Approve flash-loan repayment (principal + premium)
        for (uint256 i; i < assets.length; i++) {
            IERC20(assets[i]).approve(msg.sender, amounts[i] + premiums[i]);
        }

        return true;
    }

    // ──────────────────── Strategy execution ────────────────────

    /// @dev Override in concrete solver implementations.
    ///      This is called inside the flash-loan callback with full liquidity available.
    function _executeStrategy(
        Order memory order,
        bytes memory sig,
        address[] calldata flashAssets,
        uint256[] calldata flashAmounts,
        uint256[] calldata flashPremiums,
        bytes memory strategyData
    ) internal virtual;

    // ──────────────────── Helpers ────────────────────

    /// @dev Approve and call settlement. Calldata order required for settle().
    function _settleOrder(Order memory order, bytes memory sig) internal {
        // We need to encode as calldata for the settlement — use a low-level call
        // since Settlement.settle expects calldata Order
        (bool ok,) = address(settlement).call(
            abi.encodeWithSelector(Settlement.settle.selector, order, sig)
        );
        if (!ok) revert FlashLoanFailed();
    }

    /// @dev Swap via DEX aggregator
    function _swap(address dex, address tokenIn, address tokenOut, uint256 amountIn, bytes memory routeData)
        internal
        returns (uint256 amountOut)
    {
        IERC20(tokenIn).approve(dex, amountIn);
        amountOut = IDexAggregator(dex).swap(tokenIn, tokenOut, amountIn, 0, routeData);
    }

    /// @dev Rescue tokens accidentally sent to this contract
    function rescueTokens(address token, uint256 amount) external onlyOperator {
        IERC20(token).transfer(operator, amount);
    }
}
