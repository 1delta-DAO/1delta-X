// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Order} from "@core/settlement/Settlement.sol";
import {BaseFlashSolver} from "@solvers/base/BaseFlashSolver.sol";

/// @notice Morpho Blue flash-loan surface. `flashLoan` transfers `assets` of
///         `token` to the caller, invokes `onMorphoFlashLoan(assets, data)`, then
///         pulls `assets` back via transferFrom — so the borrower approves Morpho
///         (fee-free).
interface IMorphoFlash {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

/// @title MorphoFlashSolver
/// @notice Morpho Blue implementation of the leverage-fill solver family
///         (`BaseFlashSolver`). Sources the collateral via the singleton Morpho
///         contract's fee-free `flashLoan` and repays by approving Morpho to pull
///         `assets` at the end of the callback.
contract MorphoFlashSolver is BaseFlashSolver {
    IMorphoFlash public immutable morpho;

    error OnlyMorpho();

    constructor(address _permit3, address _settlement, address _morpho, address _router)
        BaseFlashSolver(_permit3, _settlement, _router)
    {
        morpho = IMorphoFlash(_morpho);
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
        bytes memory data = abi.encode(flashToken, order, sig, fillAmountIn, dexFee, minSwapOut);
        morpho.flashLoan(flashToken, flashAmount, data);

        // Surplus collateral is the fill's profit — sweep it to the caller so no
        // balance accumulates in this permissionless solver.
        _sweep(order.legsOut[0].token, msg.sender);
    }

    /// @dev Morpho Blue callback. `assets` of `flashToken` are here; Morpho pulls
    ///      exactly `assets` back via transferFrom on return (no fee).
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        if (msg.sender != address(morpho)) revert OnlyMorpho();
        _requireInFlash();

        (address flashToken, Order memory order, bytes memory sig, uint256 fillAmountIn, uint24 dexFee, uint256 minSwapOut)
        = abi.decode(data, (address, Order, bytes, uint256, uint24, uint256));

        _fillAndSwap(order, sig, fillAmountIn, flashToken, dexFee, minSwapOut);

        _ensureRepayable(flashToken, assets);
        IERC20(flashToken).approve(address(morpho), assets); // Morpho pulls on return
    }
}
