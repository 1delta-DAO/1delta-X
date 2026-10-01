// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {Order} from "@core/settlement/Settlement.sol";
import {BaseFlashSolver, FlashOpts} from "@solvers/base/BaseFlashSolver.sol";
import {IAaveV3Pool} from "@solvers/single-input/AaveV3FlashSolver.sol";

/// @title AaveV3MultiInputFlashSolver
/// @notice Aave v3 flash-loan solver for MULTI-INPUT orders (see
///         `MultiInputLeverageSolver` for the Balancer sibling). Sources the
///         collateral via `flashLoanSimple`, opens the levered position, then
///         swaps EVERY received input leg back to the collateral and repays
///         `amount + premium` via approve-pull.
contract AaveV3MultiInputFlashSolver is BaseFlashSolver {
    IAaveV3Pool public immutable pool;

    error OnlyPool();
    error BadInitiator();

    constructor(address _permit3, address _settlement, address _pool, address _router)
        BaseFlashSolver(_permit3, _settlement, _router)
    {
        pool = IAaveV3Pool(_pool);
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
        _executeFill(flashSource, flashAmount, order, address(0), abi.encode(order, sig, fillAmountIn, dexFees, minSwapOuts, bytes("")));
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
        _executeFill(flashSource, flashAmount, order, opts.recipient, abi.encode(order, sig, fillAmountIn, dexFees, minSwapOuts, opts.takerData));
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
        pool.flashLoanSimple(address(this), flashSource, flashAmount, payload, 0);
        _providerReturned();

        // Surplus collateral is the fill's profit — sweep it out so no balance
        // accumulates in this permissionless solver.
        _sweepProfit(flashSource, order, to);
    }

    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        returns (bool)
    {
        if (msg.sender != address(pool)) revert OnlyPool();
        if (initiator != address(this)) revert BadInitiator();
        _requireInFlash();

        _fillAndSwapAllEncoded(params, asset);

        uint256 owed = amount + premium;
        _ensureRepayable(asset, owed);
        SafeTransferLib.forceApprove(asset, address(pool), owed); // Pool pulls on return
        return true;
    }
}
