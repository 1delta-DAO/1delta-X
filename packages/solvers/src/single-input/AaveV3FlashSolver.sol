// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Order} from "@core/settlement/Settlement.sol";
import {BaseFlashSolver} from "@solvers/base/BaseFlashSolver.sol";

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
        bytes memory params = abi.encode(order, sig, fillAmountIn, dexFee, minSwapOut);
        pool.flashLoanSimple(address(this), flashToken, flashAmount, params, 0);
    }

    /// @dev Aave v3 callback. The Pool has already transferred `amount` of `asset`
    ///      here; it will pull `amount + premium` back via transferFrom on return.
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        if (msg.sender != address(pool)) revert OnlyPool();
        if (initiator != address(this)) revert BadInitiator();
        _requireInFlash();

        (Order memory order, bytes memory sig, uint256 fillAmountIn, uint24 dexFee, uint256 minSwapOut) =
            abi.decode(params, (Order, bytes, uint256, uint24, uint256));

        _fillAndSwap(order, sig, fillAmountIn, asset, dexFee, minSwapOut);

        uint256 owed = amount + premium;
        _ensureRepayable(asset, owed);
        IERC20(asset).approve(address(pool), owed); // Pool pulls on return
        return true;
    }
}
