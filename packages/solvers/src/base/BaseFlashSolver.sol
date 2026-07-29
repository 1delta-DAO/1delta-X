// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {Settlement, Order} from "@core/settlement/Settlement.sol";

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
///    1. flash-loan `flashAmount` of the collateral asset (`order.legsOut[0].token`),
///    2. inside the provider callback, run `_fillAndSwap`:
///         a. `settlement.fill` — Settlement pulls the collateral from this solver
///            via Permit3, supplies it on the maker's behalf, borrows
///            `order.legsIn[0].token` and routes the proceeds back here,
///         b. swap the borrow proceeds → collateral on Uniswap v3,
///    3. repay the flash per the provider's convention (transfer-back or approve-pull).
///
///  Trust model: these contracts hold no funds between fills and are callable by
///  anyone — the security boundary is the maker's signed order + their Permit3
///  allowances. The `initiatesFlash` guard makes `executeFill` non-reentrant and
///  ensures a provider callback can only run inside a flash THIS solver started.
abstract contract BaseFlashSolver {
    IPermit3 public immutable permit3;
    Settlement public immutable settlement;
    IUniV3Router public immutable router;

    /// @dev 1 = idle, 2 = inside a flash this solver initiated.
    uint256 private _flashActive = 1;

    /// @dev The provider `executeFill` actually called, recorded when the flash is
    ///      armed. Callbacks whose provider address is not an immutable MUST
    ///      authenticate against THIS, never against a value decoded from the
    ///      callback payload — see {_requireInFlashFrom}.
    address private _armedProvider;

    /// @dev Set by the callback, asserted after the provider call — see
    ///      {_requireCallbackRan}.
    bool private _callbackRan;

    error FlashLoanNotRepaid();
    error NotInFlash();
    /// @dev A callback arrived from an address that is not the provider this
    ///      solver actually called.
    error UnexpectedFlashProvider();
    /// @dev The provider returned without invoking the callback, so the order was
    ///      never validated and no flash actually happened.
    error FlashCallbackMissing();
    /// @dev This solver only routes a single debt leg (`legsIn[0]`); a
    ///      multi-input order would strand legs [1..] as maker shortfalls.
    error MultiInputUnsupported();

    constructor(address _permit3, address _settlement, address _router) {
        permit3 = IPermit3(_permit3);
        settlement = Settlement(_settlement);
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

    /// @dev Record the provider this fill is about to call. Only needed where the
    ///      provider is chosen per call rather than pinned as an immutable.
    function _armProvider(address provider) internal {
        _armedProvider = provider;
    }

    /// @dev Callback authentication for a per-call provider: in-flash AND from the
    ///      exact address `executeFill` called.
    ///
    ///      This exists because deriving the expected provider from the callback's
    ///      own payload is circular and therefore no check at all. When both the
    ///      provider argument and the callback data are attacker-supplied — as they
    ///      are for a per-call flash source — `msg.sender == decoded.provider` is
    ///      trivially satisfied by a contract the attacker wrote, which then drives
    ///      an arbitrary `settlement.fill` with THIS SOLVER as the filler and no
    ///      repayment floor. Comparing against storage written before the external
    ///      call closes it: an attacker can still call their own fake provider, but
    ///      the callback then arrives from an address that matches, and it is their
    ///      own contract they are looping through — no reach into this solver's
    ///      identity, because the fake provider is never `_armedProvider` for any
    ///      call the solver did not itself make.
    function _requireInFlashFromArmed() internal {
        if (_flashActive != 2) revert NotInFlash();
        if (msg.sender != _armedProvider) revert UnexpectedFlashProvider();
        _callbackRan = true;
    }

    /// @dev Assert the provider actually called back, then reset. Required after a
    ///      per-call provider, because a "provider" that simply returns without
    ///      invoking the callback would otherwise fall straight through to the
    ///      profit sweep — and the sweep names a token from an `order` that, on
    ///      that path, was NEVER signature-checked (the order is only validated
    ///      inside the callback). That made the tail sweep a signature-free
    ///      "send me your balance of any token I name" primitive.
    function _requireCallbackRan() internal {
        if (!_callbackRan) revert FlashCallbackMissing();
        _callbackRan = false;
    }

    /// @notice Grant this contract's ERC20 + Permit3 allowances for `token` so
    ///         Settlement can pull the flash-loaned collateral during `fill`.
    ///         Permissionless — only this contract's own (transient) funds are at risk.
    function setupTokenApproval(address token) external {
        SafeTransferLib.forceApprove(token, address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), token, type(uint160).max, 0);
    }

    /// @dev The leverage core: run the maker fill, then swap the borrow proceeds
    ///      (`order.legsIn[0].token`) back to `tokenOut` (the flash-loaned collateral) so the
    ///      caller can repay. Leaves all proceeds in `tokenOut` denomination here.
    function _fillAndSwap(
        Order memory order,
        bytes memory sig,
        uint256 fillAmountIn,
        address tokenOut,
        uint24 dexFee,
        uint256 minSwapOut
    ) internal {
        // Single-debt core: the borrow proceeds are the first (and only) input
        // leg. A multi-input order would collect only legsIn[0] here and turn
        // legs [1..] into maker shortfalls, so reject it (see _fillAndSwapAll for
        // the multi-input variant).
        if (order.legsIn.length != 1) revert MultiInputUnsupported();

        settlement.fill(order, sig, fillAmountIn);

        address tokenIn = order.legsIn[0].token;
        _swapExactIn(tokenIn, tokenOut, IERC20(tokenIn).balanceOf(address(this)), dexFee, minSwapOut);
    }

    /// @dev Multi-input leverage core: run the maker fill, then swap EVERY
    ///      received input leg back to `tokenOut` (the flash-loaned collateral)
    ///      so the caller can repay. Input legs already denominated in `tokenOut`
    ///      are left as-is. `dexFees`/`minSwapOuts` are aligned with
    ///      `order.legsIn[0].token`; entries for a skipped leg are ignored.
    function _fillAndSwapAll(
        Order memory order,
        bytes memory sig,
        uint256 fillAmountIn,
        address tokenOut,
        uint24[] memory dexFees,
        uint256[] memory minSwapOuts
    ) internal {
        settlement.fill(order, sig, fillAmountIn);

        uint256 n = order.legsIn.length;
        for (uint256 i; i < n; i++) {
            address tokenIn = order.legsIn[i].token;
            if (tokenIn == tokenOut) continue; // already the collateral asset
            uint256 bal = IERC20(tokenIn).balanceOf(address(this));
            if (bal == 0) continue;
            _swapExactIn(tokenIn, tokenOut, bal, dexFees[i], minSwapOuts[i]);
        }
    }

    /// @dev Swap `amountIn` of `tokenIn` → `tokenOut` on Uniswap v3 (single hop).
    function _swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, uint24 dexFee, uint256 minOut)
        internal
    {
        SafeTransferLib.forceApprove(tokenIn, address(router), amountIn);
        router.exactInputSingle(
            IUniV3Router.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: dexFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
    }

    /// @dev Revert unless this solver holds at least `owed` of `token` post fill+swap.
    function _ensureRepayable(address token, uint256 owed) internal view {
        if (IERC20(token).balanceOf(address(this)) < owed) revert FlashLoanNotRepaid();
    }

    /// @dev Sweep the solver's ENTIRE residual balance of `token` to `to` (no-op
    ///      if zero). Run at the end of every `executeFill` so this contract never
    ///      carries a balance between fills. `executeFill` is permissionless and
    ///      `setupTokenApproval` leaves Settlement a standing max Permit3 allowance,
    ///      so any surplus left parked here could be drained by a later attacker-
    ///      crafted order routed through the same permissionless entrypoint. Sending
    ///      the fill's profit to the caller (`msg.sender`) closes that window — the
    ///      `initiatesFlash` guard already blocks a transfer-hook reentry into
    ///      `executeFill` during the sweep.
    function _sweep(address token, address to) internal {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal != 0) SafeTransferLib.safeTransfer(token, to, bal);
    }
}
