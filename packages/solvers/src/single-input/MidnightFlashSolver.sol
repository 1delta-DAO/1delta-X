// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {Order} from "@core/settlement/Settlement.sol";
import {BaseFlashSolver, FlashOpts} from "@solvers/base/BaseFlashSolver.sol";

/// @notice Morpho Midnight MULTI-token flash-loan surface. `flashLoan` transfers
///         each `assets[i]` of `tokens[i]` to `callback`, invokes
///         `callback.onFlashLoan(msg.sender, tokens, assets, data)` (which must
///         return `CALLBACK_SUCCESS`), then pulls each amount back via
///         `transferFrom(callback, ...)` — so the borrower approves Midnight
///         (fee-free).
interface IMidnightFlash {
    function flashLoan(address[] calldata tokens, uint256[] calldata assets, address callback, bytes calldata data)
        external;
}

/// @title MidnightFlashSolver
/// @notice Morpho Midnight implementation of the leverage-fill solver family
///         (`BaseFlashSolver`). Sources the collateral via Midnight's fee-free
///         multi-token `flashLoan` — wrapping the single collateral asset in a
///         one-element array — and repays by approving Midnight to pull the
///         borrowed amount back at the end of the callback.
contract MidnightFlashSolver is BaseFlashSolver {
    IMidnightFlash public immutable midnight;

    /// @dev The sentinel `Midnight.flashLoan` requires `onFlashLoan` to return.
    ///      Equals `keccak256("morpho.midnight.callbackSuccess")`.
    bytes32 private constant CALLBACK_SUCCESS = keccak256("morpho.midnight.callbackSuccess");

    error OnlyMidnight();
    /// @dev A Midnight flash loan that some OTHER contract started named this solver
    ///      as its callback.
    error ForeignInitiator();

    constructor(address _permit3, address _settlement, address _midnight, address _router)
        BaseFlashSolver(_permit3, _settlement, _router)
    {
        midnight = IMidnightFlash(_midnight);
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
        _executeFill(flashToken, flashAmount, order, address(0), abi.encode(flashToken, order, sig, fillAmountIn, dexFee, minSwapOut, bytes("")));
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
        _executeFill(flashToken, flashAmount, order, opts.recipient, abi.encode(flashToken, order, sig, fillAmountIn, dexFee, minSwapOut, opts.takerData));
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
        _flash(flashToken, flashAmount, payload);
        _providerReturned();

        // Surplus collateral is the fill's profit — sweep it out so no balance
        // accumulates in this permissionless solver.
        _sweepProfit(flashToken, order, to);
    }

    function _flash(address flashToken, uint256 flashAmount, bytes memory data) private {
        address[] memory tokens = new address[](1);
        tokens[0] = flashToken;
        uint256[] memory assets = new uint256[](1);
        assets[0] = flashAmount;
        midnight.flashLoan(tokens, assets, address(this), data);
    }

    /// @dev Midnight callback. `assets[0]` of `tokens[0]` is here; Midnight pulls
    ///      exactly that back via transferFrom on return (no fee), so we approve
    ///      it and return the success sentinel.
    function onFlashLoan(address caller, address[] calldata tokens, uint256[] calldata assets, bytes calldata data)
        external
        returns (bytes32)
    {
        if (msg.sender != address(midnight)) revert OnlyMidnight();
        // THE INITIATOR, not just the lender (re-audit F30). `midnight.flashLoan`
        // takes ANY `callback`, and `_flashActive` stays armed for the whole of
        // the provider call — so while a fill is in flight (e.g. inside its Uniswap swap,
        // where a hostile token in the route gets control and Settlement is no
        // longer locked) a stranger could start their own Midnight loan naming THIS
        // solver as callback, and run a nested fill with their payload as filler.
        // The Aave sibling checks `initiator == this` for the same reason.
        if (caller != address(this)) revert ForeignInitiator();
        _requireInFlash();

        (
            address flashToken,
            Order memory order,
            bytes memory sig,
            uint256 fillAmountIn,
            uint24 dexFee,
            uint256 minSwapOut,
            bytes memory takerData
        ) = abi.decode(data, (address, Order, bytes, uint256, uint24, uint256, bytes));

        _fillAndSwap(order, sig, fillAmountIn, flashToken, dexFee, minSwapOut, takerData);

        _ensureRepayable(tokens[0], assets[0]);
        SafeTransferLib.forceApprove(tokens[0], address(midnight), assets[0]); // Midnight pulls on return
        return CALLBACK_SUCCESS;
    }
}
