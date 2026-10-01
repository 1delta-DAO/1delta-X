// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {Order} from "@core/settlement/Settlement.sol";
import {BaseFlashSolver, FlashOpts} from "@solvers/base/BaseFlashSolver.sol";
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

    /// @param flashSource the collateral asset to flash (equals `PackedArraysMem.legOutToken(order.legsOut, 0)`)
    function executeFill(
        address flashSource,
        uint256 flashAmount,
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmountIn,
        uint24[] calldata dexFees,
        uint256[] calldata minSwapOuts
    ) external {
        _executeFill(flashSource, flashAmount, order, address(0), abi.encode(flashSource, order, sig, fillAmountIn, dexFees, minSwapOuts, bytes("")));
    }

    /// @notice {executeFill} with a profit recipient and a `takerData` blob — see
    ///         {FlashOpts}.
    function executeFill(
        address flashSource,
        uint256 flashAmount,
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmountIn,
        uint24[] calldata dexFees,
        uint256[] calldata minSwapOuts,
        FlashOpts calldata opts
    ) external {
        _executeFill(flashSource, flashAmount, order, opts.recipient, abi.encode(flashSource, order, sig, fillAmountIn, dexFees, minSwapOuts, opts.takerData));
    }

    /// @dev Shared body of both overloads. The provider payload is encoded by the
    ///      callers so this frame stays inside the legacy profile's stack limit.
    function _executeFill(
        address flashSource,
        uint256 flashAmount,
        Order calldata order,
        address recipient,
        bytes memory payload
    ) private initiatesFlash {
        _requireNoSettleItems(order);
        address to = _profitRecipient(recipient);
        morpho.flashLoan(flashSource, flashAmount, payload);
        _providerReturned();

        // Surplus collateral is the fill's profit — sweep it out so no balance
        // accumulates in this permissionless solver.
        _sweepProfit(flashSource, order, to);
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
            uint256[] memory minSwapOuts,
            bytes memory takerData
        ) = abi.decode(data, (address, Order, bytes, uint256, uint24[], uint256[], bytes));

        _fillAndSwapAll(order, sig, fillAmountIn, flashToken, dexFees, minSwapOuts, takerData);

        _ensureRepayable(flashToken, assets);
        SafeTransferLib.forceApprove(flashToken, address(morpho), assets); // Morpho pulls on return
    }
}
