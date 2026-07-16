// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Order} from "@core/settlement/UniversalSettlement.sol";
import {BaseFlashSolver} from "@solvers/base/BaseFlashSolver.sol";
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

    /// @param flashToken  the collateral asset to flash (equals `order.tokenOut[0]`)
    function executeFill(
        address flashToken,
        uint256 flashAmount,
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmountIn,
        uint24[] calldata dexFees,
        uint256[] calldata minSwapOuts
    ) external initiatesFlash {
        bytes memory params = abi.encode(order, sig, fillAmountIn, dexFees, minSwapOuts);
        pool.flashLoanSimple(address(this), flashToken, flashAmount, params, 0);
    }

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

        (
            Order memory order,
            bytes memory sig,
            uint256 fillAmountIn,
            uint24[] memory dexFees,
            uint256[] memory minSwapOuts
        ) = abi.decode(params, (Order, bytes, uint256, uint24[], uint256[]));

        _fillAndSwapAll(order, sig, fillAmountIn, asset, dexFees, minSwapOuts);

        uint256 owed = amount + premium;
        _ensureRepayable(asset, owed);
        IERC20(asset).approve(address(pool), owed); // Pool pulls on return
        return true;
    }
}
