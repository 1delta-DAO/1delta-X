// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Order} from "../settlement/UniversalSettlement.sol";
import {BaseFlashSolver} from "./BaseFlashSolver.sol";
import {IBalancerVault} from "./LimitOrderLeverageSolver.sol";

/// @notice One output leg's flash + buyback plan.
/// @dev  `token`/`flashAmount` describe the Balancer flash (legs MUST be sorted
///       ascending by `token` — Balancer's requirement — and cover `tokenOut`).
///       `dexFee`/`spendIn`/`minOut` describe the Uniswap v3 buyback that repays
///       it: swap `spendIn` of the input token → `token`, requiring ≥ `minOut`
///       (which must be ≥ `flashAmount`).
struct OutputLeg {
    address token;
    uint256 flashAmount;
    uint24 dexFee;
    uint256 spendIn;
    uint256 minOut;
}

/// @title MultiOutputFlashSolver
/// @notice Fills a MULTI-OUTPUT order with no inventory. Where the leverage
///         solvers flash a single collateral, this one flash-loans the whole
///         OUTPUT basket (`tokenOut[]`) from Balancer, lets Settlement deliver it
///         to the maker, receives the maker's input, and buys each output token
///         back from that input to repay the flash.
///
///  Flow (per `executeFill`):
///
///    1. Balancer flash-loan the output basket (one `OutputLeg` per token).
///    2. `receiveFlashLoan`:
///         a. `settlement.fill` — Settlement pulls each output leg from here via
///            Permit3, delivers it to the maker, and pays us the input token.
///         b. For each leg, swap `spendIn` of the input → that output on Uniswap
///            v3, then repay the flashed amount.
///    3. Leftover input / surplus outputs stay here as solver profit.
///
///  The input side is single-source: `order.tokenIn[0]` funds every buyback.
///  Holds no funds between fills; callable by anyone.
contract MultiOutputFlashSolver is BaseFlashSolver {
    IBalancerVault public immutable vault;

    error OnlyVault();

    constructor(address _permit3, address _settlement, address _vault, address _router)
        BaseFlashSolver(_permit3, _settlement, _router)
    {
        vault = IBalancerVault(_vault);
    }

    /// @param order   the maker's signed multi-output order
    /// @param legs    per-output flash + buyback plan (sorted asc by token)
    function executeFill(Order calldata order, bytes calldata sig, uint256 fillAmountIn, OutputLeg[] calldata legs)
        external
        initiatesFlash
    {
        uint256 n = legs.length;
        address[] memory tokens = new address[](n);
        uint256[] memory amounts = new uint256[](n);
        for (uint256 i; i < n; i++) {
            tokens[i] = legs[i].token;
            amounts[i] = legs[i].flashAmount;
        }
        bytes memory userData = abi.encode(order, sig, fillAmountIn, legs);
        vault.flashLoan(address(this), tokens, amounts, userData);
    }

    /// @dev Balancer v2 callback.
    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory feeAmounts,
        bytes memory userData
    ) external {
        if (msg.sender != address(vault)) revert OnlyVault();
        _requireInFlash();

        (Order memory order, bytes memory sig, uint256 fillAmountIn, OutputLeg[] memory legs) =
            abi.decode(userData, (Order, bytes, uint256, OutputLeg[]));

        address tokenIn = order.tokenIn[0]; // single-source buyback currency

        // Delivers every output leg to the maker (from the flashed basket) and
        // pays us `tokenIn`.
        settlement.fill(order, sig, fillAmountIn);

        // Buy each output back from the received input and repay the flash.
        for (uint256 i; i < tokens.length; i++) {
            OutputLeg memory leg = legs[i];
            if (leg.spendIn != 0) {
                _swapExactIn(tokenIn, leg.token, leg.spendIn, leg.dexFee, leg.minOut);
            }
            uint256 owed = amounts[i] + feeAmounts[i]; // Balancer v2 mainnet fee: 0
            _ensureRepayable(leg.token, owed);
            IERC20(leg.token).transfer(address(vault), owed);
        }
        // Leftover input + surplus outputs stay here as solver profit.
    }
}
