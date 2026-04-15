// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPermit3} from "../interfaces/IPermit3.sol";
import {
    LimitOrderSettlement, LimitOrder, Item, ItemOp
} from "../settlement/LimitOrderSettlement.sol";

/// @notice Balancer v2 vault flash-loan callback shape.
interface IBalancerVault {
    function flashLoan(
        address recipient,
        address[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) external;
}

/// @notice Uniswap v3 swap router exactInputSingle shape.
interface IUniV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256);
}

/// @title LimitOrderLeverageSolver
/// @notice Reference solver that fills a `LimitOrderSettlement` order with
///         no inventory by flash-loaning the collateral from Balancer,
///         letting Settlement route it through the maker's deposit leg,
///         then repaying via a Uniswap v3 swap of the borrow proceeds.
///
///  Flow (per `executeFill`):
///
///    1. Balancer flash-loan `tokenOut` (e.g. WETH) for `flashAmount`.
///    2. Vault callback:
///         a. Permit3 sees this contract's pre-approved token allowance
///            for `tokenOut`; Settlement pulls the flash-loaned WETH →
///            maker during `fill`.
///         b. MAKE item supplies the WETH as collateral.
///         c. TAKE item borrows `tokenIn` (USDC) on the maker's behalf
///            and routes proceeds back here via `permit3.take`'s
///            `receiver = settlement` then `_payTokenInToSolver`.
///         d. Swap the USDC proceeds → WETH on Uniswap v3.
///         e. Transfer `flashAmount` back to the vault. Surplus WETH (if
///            any) stays in this contract as solver profit.
///
///  This contract holds no funds between fills. It's callable by anyone:
///  the security boundary is the maker's signed order + their Permit3
///  allowances. There is no operator gate.
contract LimitOrderLeverageSolver {
    IPermit3 public immutable permit3;
    LimitOrderSettlement public immutable settlement;
    IBalancerVault public immutable vault;
    IUniV3Router public immutable router;

    error OnlyVault();
    error FlashLoanNotRepaid();

    constructor(address _permit3, address _settlement, address _vault, address _router) {
        permit3 = IPermit3(_permit3);
        settlement = LimitOrderSettlement(_settlement);
        vault = IBalancerVault(_vault);
        router = IUniV3Router(_router);
    }

    /// @notice Grant this contract's ERC20 + Permit3 allowances for a token.
    ///         Permissionless — only this contract's own funds are at risk.
    function setupTokenApproval(address token) external {
        IERC20(token).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), token, type(uint160).max, 0);
    }

    /// @notice Fill a leverage-style order with no starting inventory.
    /// @param flashToken    the collateral asset (equals order.tokenOut)
    /// @param flashAmount   amount to flash-loan — should cover Settlement's pull
    /// @param order         the maker's signed order
    /// @param sig           EIP-712 signature
    /// @param fillAmountIn  slice of amountIn to fill this call
    /// @param dexFee        Uniswap v3 pool fee tier for the repayment swap
    /// @param minSwapOut    min WETH expected from the USDC→WETH swap (slippage guard)
    function executeFill(
        address flashToken,
        uint256 flashAmount,
        LimitOrder calldata order,
        bytes calldata sig,
        uint256 fillAmountIn,
        uint24 dexFee,
        uint256 minSwapOut
    ) external {
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = flashToken;
        amounts[0] = flashAmount;

        bytes memory userData = abi.encode(order, sig, fillAmountIn, dexFee, minSwapOut);
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

        (
            LimitOrder memory order,
            bytes memory sig,
            uint256 fillAmountIn,
            uint24 dexFee,
            uint256 minSwapOut
        ) = abi.decode(userData, (LimitOrder, bytes, uint256, uint24, uint256));

        address tokenOut = tokens[0]; //         collateral the solver is fronting
        uint256 flashAmt = amounts[0];
        uint256 fee = feeAmounts[0]; //           Balancer v2 mainnet: 0

        // 1. Execute the fill — Settlement pulls tokenOut from us via Permit3,
        //    deposits it to the lender on maker's behalf, borrows tokenIn
        //    against it and hands tokenIn back to us.
        settlement.fill(order, sig, fillAmountIn);

        // 2. Swap borrow proceeds → tokenOut to source repayment.
        address tokenIn = order.tokenIn;
        uint256 tokenInBal = IERC20(tokenIn).balanceOf(address(this));
        IERC20(tokenIn).approve(address(router), tokenInBal);

        router.exactInputSingle(
            IUniV3Router.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: dexFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: tokenInBal,
                amountOutMinimum: minSwapOut,
                sqrtPriceLimitX96: 0
            })
        );

        // 3. Repay flash loan (Balancer v2: transfer back to vault).
        uint256 owed = flashAmt + fee;
        if (IERC20(tokenOut).balanceOf(address(this)) < owed) revert FlashLoanNotRepaid();
        IERC20(tokenOut).transfer(address(vault), owed);
        // Any surplus `tokenOut` stays here as solver profit.
    }
}
