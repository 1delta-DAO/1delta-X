// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {Order} from "@core/settlement/Settlement.sol";
import {BaseFlashSolver, FlashOpts} from "@solvers/base/BaseFlashSolver.sol";

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
///         b. Transfer `flashAmount` back to the vault. `executeFill` then sweeps
///            the surplus WETH to the caller (no residue accumulates here).
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
    /// @param flashToken   the collateral asset (equals `PackedArraysMem.legOutToken(order.legsOut, 0)`)
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
    ) external {
        _executeFill(flashToken, flashAmount, order, address(0), abi.encode(order, sig, fillAmountIn, dexFee, minSwapOut, bytes("")));
    }

    /// @notice {executeFill} with a profit recipient and a `takerData` blob — see
    ///         {FlashOpts}.
    function executeFill(
        address flashToken,
        uint256 flashAmount,
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmountIn,
        uint24 dexFee,
        uint256 minSwapOut,
        FlashOpts calldata opts
    ) external {
        _executeFill(flashToken, flashAmount, order, opts.recipient, abi.encode(order, sig, fillAmountIn, dexFee, minSwapOut, opts.takerData));
    }

    /// @dev Shared body of both overloads. The provider payload is encoded by the
    ///      callers so this frame stays inside the legacy profile's stack limit.
    function _executeFill(
        address flashToken,
        uint256 flashAmount,
        Order calldata order,
        address recipient,
        bytes memory payload
    ) private initiatesFlash {
        _requireNoSettleItems(order);
        address to = _profitRecipient(recipient);
        _flash(flashToken, flashAmount, payload);
        _providerReturned();

        // Surplus collateral is the fill's profit — sweep it out so no balance
        // accumulates in this permissionless solver.
        _sweepProfit(flashToken, order, to);
    }

    /// @dev The Balancer call, payload-committed — see {BaseFlashSolver._commitFlash}.
    function _flash(address flashToken, uint256 flashAmount, bytes memory userData) private {
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = flashToken;
        amounts[0] = flashAmount;
        _commitFlash(keccak256(userData));
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
        // Balancer names no initiator: bind the callback to the payload we sent.
        _consumeFlashCommit(keccak256(userData));

        (
            Order memory order,
            bytes memory sig,
            uint256 fillAmountIn,
            uint24 dexFee,
            uint256 minSwapOut,
            bytes memory takerData
        ) = abi.decode(userData, (Order, bytes, uint256, uint24, uint256, bytes));

        address tokenOut = tokens[0]; // collateral the solver is fronting
        uint256 owed = amounts[0] + feeAmounts[0]; // Balancer v2 mainnet fee: 0

        _fillAndSwap(order, sig, fillAmountIn, tokenOut, dexFee, minSwapOut, takerData);

        _ensureRepayable(tokenOut, owed);
        SafeTransferLib.safeTransfer(tokenOut, address(vault), owed);
        // Surplus `tokenOut` is swept to the executeFill caller (see _sweep).
    }
}
