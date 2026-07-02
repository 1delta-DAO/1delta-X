// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPermit3} from "../interfaces/IPermit3.sol";
import {UniversalSettlement, Order} from "../settlement/UniversalSettlement.sol";

/// @notice Uniswap v3 `exactInputSingle` shape — used to swap the borrow proceeds
///         back to the collateral asset that sources the flash repayment.
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

/// @title BaseFlashSolver
/// @notice Shared machinery for the leverage-fill solver family. Each concrete
///         solver sources the collateral inventory from a DIFFERENT flash-loan
///         provider — Balancer v2, Aave v3, Euler EVK, Morpho Blue — but the
///         fill→swap→repay core is identical and lives here.
///
///  Every solver exposes the SAME entrypoint:
///
///    executeFill(flashSource, flashAmount, order, sig, fillAmountIn, dexFee, minSwapOut)
///
///  where `flashSource` is the provider-specific handle (the asset to borrow for
///  the singleton providers, or the EVK vault for Euler). The body always:
///
///    1. flash-loan `flashAmount` of the collateral asset (`order.tokenOut`),
///    2. inside the provider callback, run `_fillAndSwap`:
///         a. `settlement.fill` — Settlement pulls the collateral from this solver
///            via Permit3, supplies it on the maker's behalf, borrows
///            `order.tokenIn` and routes the proceeds back here,
///         b. swap the borrow proceeds → collateral on Uniswap v3,
///    3. repay the flash per the provider's convention (transfer-back or approve-pull).
///
///  Trust model: these contracts hold no funds between fills and are callable by
///  anyone — the security boundary is the maker's signed order + their Permit3
///  allowances. The `initiatesFlash` guard makes `executeFill` non-reentrant and
///  ensures a provider callback can only run inside a flash THIS solver started.
abstract contract BaseFlashSolver {
    IPermit3 public immutable permit3;
    UniversalSettlement public immutable settlement;
    IUniV3Router public immutable router;

    /// @dev 1 = idle, 2 = inside a flash this solver initiated.
    uint256 private _flashActive = 1;

    error FlashLoanNotRepaid();
    error NotInFlash();
    /// @dev This solver only routes a single debt leg (`tokenIn[0]`); a
    ///      multi-input order would strand legs [1..] as maker shortfalls.
    error MultiInputUnsupported();

    constructor(address _permit3, address _settlement, address _router) {
        permit3 = IPermit3(_permit3);
        settlement = UniversalSettlement(_settlement);
        router = IUniV3Router(_router);
    }

    /// @dev Wrap `executeFill`: non-reentrant + arms the callback guard for the
    ///      duration of the provider's flash callback.
    modifier initiatesFlash() {
        if (_flashActive != 1) revert NotInFlash();
        _flashActive = 2;
        _;
        _flashActive = 1;
    }

    /// @dev A provider callback MUST call this first — it only passes while a flash
    ///      initiated by this solver is in flight, so a stray external call to the
    ///      callback (with attacker-crafted data) reverts.
    function _requireInFlash() internal view {
        if (_flashActive != 2) revert NotInFlash();
    }

    /// @notice Grant this contract's ERC20 + Permit3 allowances for `token` so
    ///         Settlement can pull the flash-loaned collateral during `fill`.
    ///         Permissionless — only this contract's own (transient) funds are at risk.
    function setupTokenApproval(address token) external {
        IERC20(token).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), token, type(uint160).max, 0);
    }

    /// @dev The leverage core: run the maker fill, then swap the borrow proceeds
    ///      (`order.tokenIn`) back to `tokenOut` (the flash-loaned collateral) so the
    ///      caller can repay. Leaves all proceeds in `tokenOut` denomination here.
    function _fillAndSwap(
        Order memory order,
        bytes memory sig,
        uint256 fillAmountIn,
        address tokenOut,
        uint24 dexFee,
        uint256 minSwapOut
    ) internal {
        // Leverage solvers consume single-debt orders: the borrow proceeds are
        // the first (and only) input leg. A multi-input order would collect only
        // tokenIn[0] here and turn legs [1..] into maker shortfalls, so reject it.
        if (order.tokenIn.length != 1) revert MultiInputUnsupported();

        settlement.fill(order, sig, fillAmountIn);

        address tokenIn = order.tokenIn[0];
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
    }

    /// @dev Revert unless this solver holds at least `owed` of `token` post fill+swap.
    function _ensureRepayable(address token, uint256 owed) internal view {
        if (IERC20(token).balanceOf(address(this)) < owed) revert FlashLoanNotRepaid();
    }
}
