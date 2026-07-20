// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Order} from "@core/settlement/Settlement.sol";
import {BaseFlashSolver} from "@solvers/base/BaseFlashSolver.sol";
import {IBalancerVault} from "@solvers/single-input/LimitOrderLeverageSolver.sol";

/// @title MultiInputLeverageSolver
/// @notice Balancer v2 leverage-fill solver for MULTI-INPUT orders. Unlike
///         `LimitOrderLeverageSolver` (single debt leg), this one accepts an
///         order whose `legsIn` carries several legs — e.g. a "dual
///         conversion": borrow proceeds (USDC) *and* the maker's equity (DAI)
///         both flow to the solver in exchange for the collateral it fronts.
///
///  Flow (per `executeFill`):
///
///    1. Balancer flash-loan `flashToken` (the collateral, `order.legsOut[0].token`).
///    2. `receiveFlashLoan`:
///         a. `_fillAndSwapAll` — Settlement pulls the flash-loaned collateral via
///            Permit3, routes it through the maker's deposit leg, opens the
///            leverage (borrow), and hands every input leg back here; we then swap
///            EACH input → collateral on Uniswap v3.
///         b. Repay `flashAmount` to the vault; surplus collateral is profit.
///
///  Holds no funds between fills; callable by anyone (the maker's signed order +
///  Permit3 allowances are the only gate).
contract MultiInputLeverageSolver is BaseFlashSolver {
    IBalancerVault public immutable vault;

    error OnlyVault();

    constructor(address _permit3, address _settlement, address _vault, address _router)
        BaseFlashSolver(_permit3, _settlement, _router)
    {
        vault = IBalancerVault(_vault);
    }

    /// @notice Fill a multi-input leverage order with no starting inventory.
    /// @param flashToken   the collateral asset (equals `order.legsOut[0].token`)
    /// @param flashAmount  amount to flash-loan — should cover Settlement's pull
    /// @param order        the maker's signed order (may have many `legsIn`)
    /// @param sig          EIP-712 signature
    /// @param fillAmountIn slice of amountIn[0] to fill this call
    /// @param dexFees      per-input Uniswap v3 fee tiers (aligned with tokenIn)
    /// @param minSwapOuts  per-input min collateral out (slippage guards)
    function executeFill(
        address flashToken,
        uint256 flashAmount,
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmountIn,
        uint24[] calldata dexFees,
        uint256[] calldata minSwapOuts
    ) external initiatesFlash {
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = flashToken;
        amounts[0] = flashAmount;

        bytes memory userData = abi.encode(order, sig, fillAmountIn, dexFees, minSwapOuts);
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

        (
            Order memory order,
            bytes memory sig,
            uint256 fillAmountIn,
            uint24[] memory dexFees,
            uint256[] memory minSwapOuts
        ) = abi.decode(userData, (Order, bytes, uint256, uint24[], uint256[]));

        address tokenOut = tokens[0]; // collateral the solver is fronting
        uint256 owed = amounts[0] + feeAmounts[0]; // Balancer v2 mainnet fee: 0

        _fillAndSwapAll(order, sig, fillAmountIn, tokenOut, dexFees, minSwapOuts);

        _ensureRepayable(tokenOut, owed);
        IERC20(tokenOut).transfer(address(vault), owed);
        // Any surplus `tokenOut` stays here as solver profit.
    }
}
