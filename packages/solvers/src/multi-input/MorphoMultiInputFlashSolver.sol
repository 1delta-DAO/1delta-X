// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedArraysMem} from "@core/settlement/PackedArraysMem.sol";

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {Order} from "@core/settlement/Settlement.sol";
import {BaseFlashSolver} from "@solvers/base/BaseFlashSolver.sol";
import {IMorphoFlash} from "@solvers/single-input/MorphoFlashSolver.sol";

/// @title MorphoMultiInputFlashSolver
/// @notice Morpho Blue flash-loan solver for MULTI-INPUT orders (see
///         `MultiInputLeverageSolver` for the Balancer sibling). Flashes the
///         collateral from the singleton Morpho contract (fee-free), opens the
///         levered position, swaps EVERY received input leg back to the
///         collateral, and repays via approve-pull.
contract MorphoMultiInputFlashSolver is BaseFlashSolver {
    IMorphoFlash public immutable morpho;

    error OnlyMorpho();

    constructor(address _permit3, address _settlement, address _morpho, address _router)
        BaseFlashSolver(_permit3, _settlement, _router)
    {
        morpho = IMorphoFlash(_morpho);
    }

    /// @param flashToken  the collateral asset to flash (equals `PackedArraysMem.legOutToken(order.legsOut, 0)`)
    function executeFill(
        address flashToken,
        uint256 flashAmount,
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmountIn,
        uint24[] calldata dexFees,
        uint256[] calldata minSwapOuts
    ) external initiatesFlash {
        bytes memory data = abi.encode(flashToken, order, sig, fillAmountIn, dexFees, minSwapOuts);
        morpho.flashLoan(flashToken, flashAmount, data);

        // Surplus collateral is the fill's profit — sweep it to the caller so no
        // balance accumulates in this permissionless solver.
        _sweep(PackedArraysMem.legOutToken(order.legsOut, 0), msg.sender);
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        if (msg.sender != address(morpho)) revert OnlyMorpho();
        _requireInFlash();

        (
            address flashToken,
            Order memory order,
            bytes memory sig,
            uint256 fillAmountIn,
            uint24[] memory dexFees,
            uint256[] memory minSwapOuts
        ) = abi.decode(data, (address, Order, bytes, uint256, uint24[], uint256[]));

        _fillAndSwapAll(order, sig, fillAmountIn, flashToken, dexFees, minSwapOuts);

        _ensureRepayable(flashToken, assets);
        SafeTransferLib.forceApprove(flashToken, address(morpho), assets); // Morpho pulls on return
    }
}
