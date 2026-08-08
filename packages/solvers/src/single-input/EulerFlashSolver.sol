// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedArraysMem} from "@core/settlement/PackedArraysMem.sol";

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {Order} from "@core/settlement/Settlement.sol";
import {BaseFlashSolver} from "@solvers/base/BaseFlashSolver.sol";

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
    ) external initiatesFlash {
        bytes memory data = abi.encode(flashVault, flashAmount, order, sig, fillAmountIn, dexFee, minSwapOut);
        // Pin the provider BEFORE the external call so the callback can be
        // authenticated against it rather than against its own payload.
        _armProvider(flashVault);
        IEulerFlashVault(flashVault).flashLoan(flashAmount, data);
        // A "vault" that returns without calling back never validated the order,
        // so falling through to the sweep below would move funds on an unsigned
        // order. Assert the callback actually ran.
        _requireCallbackRan();

        // Surplus collateral is the fill's profit — sweep it to the caller so no
        // balance accumulates in this permissionless solver.
        _sweep(PackedArraysMem.legOutToken(order.legsOut, 0), msg.sender);
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
            uint256 minSwapOut
        ) = abi.decode(data, (address, uint256, Order, bytes, uint256, uint24, uint256));

        address tokenOut = IEulerFlashVault(flashVault).asset();
        _fillAndSwap(order, sig, fillAmountIn, tokenOut, dexFee, minSwapOut);

        _ensureRepayable(tokenOut, flashAmount);
        SafeTransferLib.safeTransfer(tokenOut, flashVault, flashAmount);
    }
}
