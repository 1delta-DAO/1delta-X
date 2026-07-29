// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {Order} from "@core/settlement/Settlement.sol";
import {BaseFlashSolver} from "@solvers/base/BaseFlashSolver.sol";
import {IEulerFlashVault} from "@solvers/single-input/EulerFlashSolver.sol";

/// @title EulerMultiInputFlashSolver
/// @notice Euler EVK flash-loan solver for MULTI-INPUT orders (see
///         `MultiInputLeverageSolver` for the Balancer sibling). Flashes the
///         collateral from a specific EVK vault, opens the levered position,
///         swaps EVERY received input leg back to the collateral, and repays by
///         transfer (Euler flash loans are fee-free).
contract EulerMultiInputFlashSolver is BaseFlashSolver {

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
        uint24[] calldata dexFees,
        uint256[] calldata minSwapOuts
    ) external initiatesFlash {
        bytes memory data =
            abi.encode(flashVault, flashAmount, order, sig, fillAmountIn, dexFees, minSwapOuts);
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
        _sweep(order.legsOut[0].token, msg.sender);
    }

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
            uint24[] memory dexFees,
            uint256[] memory minSwapOuts
        ) = abi.decode(data, (address, uint256, Order, bytes, uint256, uint24[], uint256[]));

        address tokenOut = IEulerFlashVault(flashVault).asset();
        _fillAndSwapAll(order, sig, fillAmountIn, tokenOut, dexFees, minSwapOuts);

        _ensureRepayable(tokenOut, flashAmount);
        SafeTransferLib.safeTransfer(tokenOut, flashVault, flashAmount);
    }
}
