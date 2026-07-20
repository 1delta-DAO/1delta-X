// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Order} from "@core/settlement/Settlement.sol";
import {BaseFlashSolver} from "@solvers/base/BaseFlashSolver.sol";

/// @notice Balancer v2 vault flash-loan callback shape.
interface IBalancerVault {
    function flashLoan(address recipient, address[] memory tokens, uint256[] memory amounts, bytes memory userData)
        external;
}

/// @title LimitOrderLeverageSolver
/// @notice Balancer v2 implementation of the leverage-fill solver family
///         (`BaseFlashSolver`). Fills a `Settlement` order with no
///         inventory by flash-loaning the collateral from Balancer (fee-free on
///         mainnet), letting Settlement route it through the maker's deposit leg,
///         then repaying via a Uniswap v3 swap of the borrow proceeds.
///
///  Flow (per `executeFill`):
///
///    1. Balancer flash-loan `tokenOut` (e.g. WETH) for `flashAmount`.
///    2. `receiveFlashLoan`:
///         a. `_fillAndSwap` — Settlement pulls the flash-loaned WETH via Permit3,
///            supplies it as the maker's collateral, borrows `tokenIn` (USDC) on
///            the maker's behalf, hands it back, and we swap USDC → WETH on Uni v3.
///         b. Transfer `flashAmount` back to the vault. Surplus WETH stays here as
///            solver profit.
///
///  Holds no funds between fills; callable by anyone (the maker's signed order +
///  Permit3 allowances are the only gate).
contract LimitOrderLeverageSolver is BaseFlashSolver {
    IBalancerVault public immutable vault;

    error OnlyVault();

    constructor(address _permit3, address _settlement, address _vault, address _router)
        BaseFlashSolver(_permit3, _settlement, _router)
    {
        vault = IBalancerVault(_vault);
    }

    /// @notice Fill a leverage-style order with no starting inventory.
    /// @param flashToken   the collateral asset (equals `order.tokenOut`)
    /// @param flashAmount  amount to flash-loan — should cover Settlement's pull
    /// @param order        the maker's signed order
    /// @param sig          EIP-712 signature
    /// @param fillAmountIn slice of amountIn to fill this call
    /// @param dexFee       Uniswap v3 pool fee tier for the repayment swap
    /// @param minSwapOut   min collateral out of the proceeds swap (slippage guard)
    function executeFill(
        address flashToken,
        uint256 flashAmount,
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmountIn,
        uint24 dexFee,
        uint256 minSwapOut
    ) external initiatesFlash {
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = flashToken;
        amounts[0] = flashAmount;

        bytes memory userData = abi.encode(order, sig, fillAmountIn, dexFee, minSwapOut);
        vault.flashLoan(address(this), tokens, amounts, userData);
    }

    /// @dev Balancer v2 callback.
    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external {
        if (msg.sender != address(vault)) revert OnlyVault();
        _requireInFlash();

        (Order memory order, bytes memory sig, uint256 fillAmountIn, uint24 dexFee, uint256 minSwapOut) =
            abi.decode(userData, (Order, bytes, uint256, uint24, uint256));

        address tokenOut = tokens[0]; // collateral the solver is fronting
        uint256 owed = amounts[0] + feeAmounts[0]; // Balancer v2 mainnet fee: 0

        _fillAndSwap(order, sig, fillAmountIn, tokenOut, dexFee, minSwapOut);

        _ensureRepayable(tokenOut, owed);
        IERC20(tokenOut).transfer(address(vault), owed);
        // Any surplus `tokenOut` stays here as solver profit.
    }
}
