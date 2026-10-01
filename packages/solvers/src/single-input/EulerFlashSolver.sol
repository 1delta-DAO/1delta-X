// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {Order} from "@core/settlement/Settlement.sol";
import {BaseFlashSolver, FlashOpts} from "@solvers/base/BaseFlashSolver.sol";

/// @notice Euler EVK vault flash-loan surface. `flashLoan` transfers `amount` of
///         the vault's `asset()` to the caller, invokes `onFlashLoan(data)`, then
///         requires its cash restored — so repayment is a plain transfer back to
///         the vault (fee-free).
interface IEulerFlashVault {
    function flashLoan(uint256 amount, bytes calldata data) external;
    function asset() external view returns (address);
}

/// @title EulerFlashSolver
/// @notice Euler EVK implementation of the leverage-fill solver family
///         (`BaseFlashSolver`). Unlike the singleton providers, the flash source
///         is a specific EVK vault (one per asset), passed per call as
///         `flashVault`. Repays by transferring the borrowed `amount` straight
///         back to that vault — Euler flash loans carry no fee.
contract EulerFlashSolver is BaseFlashSolver {
    constructor(address _permit3, address _settlement, address _router)
        BaseFlashSolver(_permit3, _settlement, _router)
    {}

    /// @param flashVault  the EVK vault whose `asset()` is the collateral to flash
    function executeFill(
        address flashVault,
        uint256 flashAmount,
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmountIn,
        uint24 dexFee,
        uint256 minSwapOut
    ) external {
        _executeFill(flashVault, flashAmount, order, address(0), abi.encode(flashVault, flashAmount, order, sig, fillAmountIn, dexFee, minSwapOut, bytes("")));
    }

    /// @notice {executeFill} with a profit recipient and a `takerData` blob — see
    ///         {FlashOpts}.
    function executeFill(
        address flashVault,
        uint256 flashAmount,
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmountIn,
        uint24 dexFee,
        uint256 minSwapOut,
        FlashOpts calldata opts
    ) external {
        _executeFill(flashVault, flashAmount, order, opts.recipient, abi.encode(flashVault, flashAmount, order, sig, fillAmountIn, dexFee, minSwapOut, opts.takerData));
    }

    /// @dev Shared body of both overloads. The provider payload is encoded by the
    ///      callers so this frame stays inside the legacy profile's stack limit.
    function _executeFill(
        address flashVault,
        uint256 flashAmount,
        Order calldata order,
        address recipient,
        bytes memory payload
    ) private initiatesFlash {
        _requireNoSettleItems(order);
        address to = _profitRecipient(recipient);
        // The asset the flash is repaid in — where the surplus lands — read BEFORE
        // the flash, from the vault the caller named (audit 2026-09-30 FLASH-3).
        address asset = IEulerFlashVault(flashVault).asset();
        // Pin the provider BEFORE the external call so the callback can be
        // authenticated against it rather than against its own payload.
        _armProvider(flashVault);
        IEulerFlashVault(flashVault).flashLoan(flashAmount, payload);
        _providerReturned();
        // A "vault" that returns without calling back never validated the order,
        // so falling through to the sweep below would move funds on an unsigned
        // order. Assert the callback actually ran.
        _requireCallbackRan();

        // Surplus collateral is the fill's profit — sweep it out so no balance
        // accumulates in this permissionless solver.
        _sweepProfit(asset, order, to);
    }

    /// @dev EVK callback. `asset()` of the vault has been transferred here; we owe
    ///      exactly `flashAmount` back to the vault.
    function onFlashLoan(bytes calldata data) external {
        // NOTE: deliberately NOT `msg.sender == <flashVault decoded from data>` —
        // that compares an attacker-supplied value against another attacker-supplied
        // value. Authenticate against the armed provider instead.
        _requireInFlashFromArmed();

        (
            address flashVault,
            uint256 flashAmount,
            Order memory order,
            bytes memory sig,
            uint256 fillAmountIn,
            uint24 dexFee,
            uint256 minSwapOut,
            bytes memory takerData
        ) = abi.decode(data, (address, uint256, Order, bytes, uint256, uint24, uint256, bytes));

        address tokenOut = IEulerFlashVault(flashVault).asset();
        _fillAndSwap(order, sig, fillAmountIn, tokenOut, dexFee, minSwapOut, takerData);

        _ensureRepayable(tokenOut, flashAmount);
        SafeTransferLib.safeTransfer(tokenOut, flashVault, flashAmount);
    }
}
