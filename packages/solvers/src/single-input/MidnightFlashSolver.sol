// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {Order} from "@core/settlement/Settlement.sol";
import {BaseFlashSolver} from "@solvers/base/BaseFlashSolver.sol";

/// @notice Morpho Midnight MULTI-token flash-loan surface. `flashLoan` transfers
///         each `assets[i]` of `tokens[i]` to `callback`, invokes
///         `callback.onFlashLoan(msg.sender, tokens, assets, data)` (which must
///         return `CALLBACK_SUCCESS`), then pulls each amount back via
///         `transferFrom(callback, ...)` — so the borrower approves Midnight
///         (fee-free).
interface IMidnightFlash {
    function flashLoan(address[] calldata tokens, uint256[] calldata assets, address callback, bytes calldata data)
        external;
}

/// @title MidnightFlashSolver
/// @notice Morpho Midnight implementation of the leverage-fill solver family
///         (`BaseFlashSolver`). Sources the collateral via Midnight's fee-free
///         multi-token `flashLoan` — wrapping the single collateral asset in a
///         one-element array — and repays by approving Midnight to pull the
///         borrowed amount back at the end of the callback.
contract MidnightFlashSolver is BaseFlashSolver {
    IMidnightFlash public immutable midnight;

    /// @dev The sentinel `Midnight.flashLoan` requires `onFlashLoan` to return.
    ///      Equals `keccak256("morpho.midnight.callbackSuccess")`.
    bytes32 private constant CALLBACK_SUCCESS = keccak256("morpho.midnight.callbackSuccess");

    error OnlyMidnight();

    constructor(address _permit3, address _settlement, address _midnight, address _router)
        BaseFlashSolver(_permit3, _settlement, _router)
    {
        midnight = IMidnightFlash(_midnight);
    }

    /// @param flashToken  the collateral asset to flash (equals `order.legsOut[0].token`)
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
        tokens[0] = flashToken;
        uint256[] memory assets = new uint256[](1);
        assets[0] = flashAmount;
        bytes memory data = abi.encode(flashToken, order, sig, fillAmountIn, dexFee, minSwapOut);
        midnight.flashLoan(tokens, assets, address(this), data);

        // Surplus collateral is the fill's profit — sweep it to the caller so no
        // balance accumulates in this permissionless solver.
        _sweep(order.legsOut[0].token, msg.sender);
    }

    /// @dev Midnight callback. `assets[0]` of `tokens[0]` is here; Midnight pulls
    ///      exactly that back via transferFrom on return (no fee), so we approve
    ///      it and return the success sentinel.
    function onFlashLoan(address, address[] calldata tokens, uint256[] calldata assets, bytes calldata data)
        external
        returns (bytes32)
    {
        if (msg.sender != address(midnight)) revert OnlyMidnight();
        _requireInFlash();

        (address flashToken, Order memory order, bytes memory sig, uint256 fillAmountIn, uint24 dexFee, uint256 minSwapOut)
        = abi.decode(data, (address, Order, bytes, uint256, uint24, uint256));

        _fillAndSwap(order, sig, fillAmountIn, flashToken, dexFee, minSwapOut);

        _ensureRepayable(tokens[0], assets[0]);
        SafeTransferLib.forceApprove(tokens[0], address(midnight), assets[0]); // Midnight pulls on return
        return CALLBACK_SUCCESS;
    }
}
