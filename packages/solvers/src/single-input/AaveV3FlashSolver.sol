// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {Order} from "@core/settlement/Settlement.sol";
import {BaseFlashSolver, FlashOpts} from "@solvers/base/BaseFlashSolver.sol";

/// @notice Aave v3 single-asset flash-loan surface.
interface IAaveV3Pool {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

/// @title AaveV3FlashSolver
/// @notice Aave v3 implementation of the leverage-fill solver family
///         (`BaseFlashSolver`). Sources the collateral via `flashLoanSimple` and
///         repays `amount + premium` (Aave charges ~0.05%) by approving the Pool
///         to pull at the end of `executeOperation`.
contract AaveV3FlashSolver is BaseFlashSolver {
    IAaveV3Pool public immutable pool;

    error OnlyPool();
    error BadInitiator();

    constructor(address _permit3, address _settlement, address _pool, address _router)
        BaseFlashSolver(_permit3, _settlement, _router)
    {
        pool = IAaveV3Pool(_pool);
    }

    /// @param flashToken  the collateral asset to flash (equals `PackedArraysMem.legOutToken(order.legsOut, 0)`)
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
        pool.flashLoanSimple(address(this), flashToken, flashAmount, payload, 0);
        _providerReturned();

        // Surplus collateral is the fill's profit — sweep it out so no balance
        // accumulates in this permissionless solver.
        _sweepProfit(flashToken, order, to);
    }

    /// @dev Aave v3 callback. The Pool has already transferred `amount` of `asset`
    ///      here; it will pull `amount + premium` back via transferFrom on return.
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        returns (bool)
    {
        if (msg.sender != address(pool)) revert OnlyPool();
        if (initiator != address(this)) revert BadInitiator();
        _requireInFlash();

        _fillAndSwapEncoded(params, asset);

        uint256 owed = amount + premium;
        _ensureRepayable(asset, owed);
        SafeTransferLib.forceApprove(asset, address(pool), owed); // Pool pulls on return
        return true;
    }
}
