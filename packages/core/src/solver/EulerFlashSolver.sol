// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {LimitOrder} from "../settlement/LimitOrderSettlement.sol";
import {BaseFlashSolver} from "./BaseFlashSolver.sol";

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
    error OnlyFlashVault();

    constructor(address _permit3, address _settlement, address _router)
        BaseFlashSolver(_permit3, _settlement, _router)
    {}

    /// @param flashVault  the EVK vault whose `asset()` is the collateral to flash
    function executeFill(
        address flashVault,
        uint256 flashAmount,
        LimitOrder calldata order,
        bytes calldata sig,
        uint256 fillAmountIn,
        uint24 dexFee,
        uint256 minSwapOut
    ) external initiatesFlash {
        bytes memory data = abi.encode(flashVault, flashAmount, order, sig, fillAmountIn, dexFee, minSwapOut);
        IEulerFlashVault(flashVault).flashLoan(flashAmount, data);
    }

    /// @dev EVK callback. `asset()` of the vault has been transferred here; we owe
    ///      exactly `flashAmount` back to the vault.
    function onFlashLoan(bytes calldata data) external {
        _requireInFlash();

        (
            address flashVault,
            uint256 flashAmount,
            LimitOrder memory order,
            bytes memory sig,
            uint256 fillAmountIn,
            uint24 dexFee,
            uint256 minSwapOut
        ) = abi.decode(data, (address, uint256, LimitOrder, bytes, uint256, uint24, uint256));

        if (msg.sender != flashVault) revert OnlyFlashVault();

        address tokenOut = IEulerFlashVault(flashVault).asset();
        _fillAndSwap(order, sig, fillAmountIn, tokenOut, dexFee, minSwapOut);

        _ensureRepayable(tokenOut, flashAmount);
        IERC20(tokenOut).transfer(flashVault, flashAmount);
    }
}
