// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

import {IMidnight, Market} from "./interfaces/IMidnight.sol";
import {ISellCallback} from "./interfaces/ICallbacks.sol";

/// @notice Uniswap v3 `exactInputSingle` shape — used to swap the borrowed loan
///         token into the collateral asset. Same surface the leverage-fill
///         solvers use, so a deployment can point it at SwapRouter02.
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

/// @title MidnightLoopCallback
/// @notice A maker-side "borrow and loop" callback for Morpho Midnight. A
///         borrower signs a resting `Offer{ buy: false }` (offer a rate to
///         borrow) with `callback = this` and `receiverIfMakerIsSeller = this`.
///         When ANY lender fills the offer via `midnight.take`, Midnight routes
///         the borrowed loan token here and fires {onSell} — BEFORE its post-fill
///         solvency check. This contract swaps those proceeds into the market's
///         collateral asset and supplies them into the borrower's own position,
///         so the freshly borrowed debt is backed by collateral in the SAME fill
///         (a one-transaction leverage build, driven purely by the offer being
///         hit — no solver, no settlement, no per-fill signature).
///
///  Trust model. This contract holds no funds between fills and is only ever
///  invoked by Midnight (the `onlyMidnight` gate). It acts on `seller`'s position
///  through `supplyCollateral`, which is a PERMISSIONLESS inflow (anyone may add
///  collateral to anyone) — so, unlike the value-out modules, it needs NO
///  `setIsAuthorized` grant. The maker-signed `callbackData` is the only tunable:
///  it names the collateral index, the swap pool fee, and a slippage floor, all
///  bound into the offer the maker signed.
///
///  ⚠ `minCollateralOut` IS THE REAL SLIPPAGE BOUND — Midnight's solvency check is
///  NOT a backstop for it. This note used to claim a too-thin floor "simply fails
///  Midnight's solvency check and reverts the whole fill". That holds only for a
///  position with no pre-existing headroom: the check is against the WHOLE
///  position, so a borrower who already has collateral can be sandwiched for the
///  full headroom while the fill still succeeds. The offer is fillable by ANY
///  lender, so the sandwicher and the filler need not be the same party. Size the
///  floor properly; do not rely on the solvency check to catch a loose one.
///  Corrected in F25 (see `docs/audit-2026-09-leads.md` C).
contract MidnightLoopCallback is ISellCallback {
    IMidnight public immutable midnight;
    IUniV3Router public immutable router;

    /// @dev Sentinel a Midnight fill callback must return.
    ///      `keccak256("morpho.midnight.callbackSuccess")`.
    bytes32 private constant CALLBACK_SUCCESS = keccak256("morpho.midnight.callbackSuccess");

    error OnlyMidnight();

    constructor(address _midnight, address _router) {
        midnight = IMidnight(_midnight);
        router = IUniV3Router(_router);
    }

    /// @inheritdoc ISellCallback
    /// @dev `data = abi.encode(uint256 collateralIndex, uint24 dexFee, uint256 minCollateralOut)`.
    ///      The borrowed `sellerAssets` (loan token) are already sitting in this
    ///      contract when Midnight calls in — but ONLY when we are the fill's
    ///      `receiver`, which is why the check below exists.
    function onSell(
        bytes32,
        Market memory market,
        uint256 sellerAssets,
        uint256,
        uint256,
        address seller,
        address receiver,
        bytes memory data
    ) external override returns (bytes32) {
        if (msg.sender != address(midnight)) revert OnlyMidnight();
        // ⚠ `msg.sender == midnight` is NOT sufficient. Midnight dispatches whatever
        // `offer.callback` names, and the offer is authored by the COUNTERPARTY. An
        // offer can therefore name this contract as the sell-side callback while
        // routing the borrowed proceeds to `receiverIfMakerIsSeller = attacker`.
        // `_swap` spends `sellerAssets` of `loanToken` OUT OF THIS CONTRACT, so
        // without this check such an offer buys the attacker collateral using any
        // balance this contract happens to hold. The interface hands us `receiver`
        // precisely so the assumption above can be asserted rather than assumed.
        if (receiver != address(this)) revert OnlyMidnight();

        (uint256 collateralIndex, uint24 dexFee, uint256 minCollateralOut) =
            abi.decode(data, (uint256, uint24, uint256));

        address collateralToken = market.collateralParams[collateralIndex].token;

        // Swap the entire borrowed budget into the collateral asset...
        uint256 collateralOut = _swap(market.loanToken, collateralToken, sellerAssets, dexFee, minCollateralOut);

        // ...and supply it into the borrower's position BEFORE Midnight's solvency
        // check, so the new debt is collateralized within the same fill.
        // `supplyCollateral` is a benign inflow → no borrower authorization needed.
        // Scoped approve + clear rather than a standing max grant: Midnight's
        // `take` lets an arbitrary caller nominate the payer via `takerCallback`,
        // so a lingering allowance from this contract to Midnight is pullable by
        // anyone. This contract is meant to hold no funds between fills, and the
        // cleared approval is what keeps that true even if a swap leaves residue.
        SafeTransferLib.forceApprove(collateralToken, address(midnight), collateralOut);
        midnight.supplyCollateral(market, collateralIndex, collateralOut, seller);
        SafeTransferLib.forceApprove(collateralToken, address(midnight), 0);

        return CALLBACK_SUCCESS;
    }

    /// @dev Isolated in its own frame to keep {onSell} under the stack limit
    ///      without via-IR (matches the package's non-via-IR build).
    function _swap(address tokenIn, address tokenOut, uint256 amountIn, uint24 fee, uint256 minOut)
        private
        returns (uint256)
    {
        // `router` is immutable, but the allowance is still scoped to this swap and
        // cleared by the router consuming exactly `amountIn`; approving max here
        // would leave a permanent grant over a token this contract may later hold.
        SafeTransferLib.forceApprove(tokenIn, address(router), amountIn);
        return router.exactInputSingle(
            IUniV3Router.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
    }
}
