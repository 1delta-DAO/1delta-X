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
///  through `supplyCollateral`, and ⚠ THAT IS NOT PERMISSIONLESS on the deployed
///  venue: `morpho-org/midnight` gates `supplyCollateral` on `onBehalf ==
///  msg.sender || isAuthorized[onBehalf][msg.sender]` ("to prevent activated
///  collateral poisoning"; verified on the Base singleton 0xAded…A18A, which
///  reverts `Unauthorized()` 0x82b42900). The borrower MUST therefore call
///  `midnight.setIsAuthorized(thisCallback, true, borrower)` before resting the
///  offer — and Midnight treats that grant as FULL position control (withdraw,
///  borrow-as-taker, re-delegation). This contract never uses it for anything but
///  the `supplyCollateral` below: `onSell` is Midnight-pinned with `receiver ==
///  this`, `seller` is supplied by Midnight, and the contract has no `take`,
///  `setIsAuthorized`, `setConsumed`, `multicall`, ratifier or fallback surface.
///  (This header used to claim no grant was needed; audit 2026-09-30 L-ML-1.)
///  The maker-signed `callbackData` is the only tunable: it names the collateral
///  index, the swap pool fee, and a slippage RATE floor, all bound into the offer
///  the maker signed.
///
///  ⚠ THE FLOOR IS THE REAL SLIPPAGE BOUND — Midnight's solvency check is NOT a
///  backstop for it. The check is against the WHOLE position, so a borrower who
///  already has collateral can be sandwiched for the full headroom while the fill
///  still succeeds. The offer is fillable by ANY lender, so the sandwicher and the
///  filler need not be the same party. Corrected in F25 (see
///  `docs/audit-2026-09-leads.md` C).
///
///  ⚠ AND IT IS A RATE, NOT AN ABSOLUTE FIGURE (audit 2026-09-30 L-ML-4). Midnight
///  lets ANY lender take ANY `units` up to the offer's remaining caps, and the
///  swapped `sellerAssets` scale with them — so an absolute `minCollateralOut`
///  either reverts every partial take (sized for the whole offer) or protects a
///  large take only down to a small figure (sized for a small one). The signed
///  `minRateWad` is collateral-token wei per loan-token wei, 1e18-scaled (decimals
///  are folded into the rate), and the floor applied to THIS take is
///  `ceil(sellerAssets · minRateWad / 1e18)` — the same per-fill guarantee at every
///  take size (the `ProratedBound` rule: sign a rate, never an absolute).
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
    /// @dev `data = abi.encode(uint256 collateralIndex, uint24 dexFee, uint256 minRateWad)` —
    ///      `minRateWad` = minimum collateral wei out per loan-token wei in, 1e18-scaled.
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

        (uint256 collateralIndex, uint24 dexFee, uint256 minRateWad) = abi.decode(data, (uint256, uint24, uint256));

        address collateralToken = market.collateralParams[collateralIndex].token;

        // Swap the entire borrowed budget into the collateral asset, floored at the
        // signed RATE scaled to THIS take's size (rounded up — never below the rate).
        uint256 collateralOut = _swap(market.loanToken, collateralToken, sellerAssets, dexFee, minRateWad);

        // ...and supply it into the borrower's position BEFORE Midnight's solvency
        // check, so the new debt is collateralized within the same fill. Requires the
        // borrower's `setIsAuthorized(this)` grant — see the header (L-ML-1).
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
    ///      The floor is `ceil(amountIn · minRateWad / 1e18)` — see the header (L-ML-4).
    function _swap(address tokenIn, address tokenOut, uint256 amountIn, uint24 fee, uint256 minRateWad)
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
                amountOutMinimum: (amountIn * minRateWad + 1e18 - 1) / 1e18,
                sqrtPriceLimitX96: 0
            })
        );
    }
}
