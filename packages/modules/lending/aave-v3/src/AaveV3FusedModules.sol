// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {DelegationHelper} from "@core/utils/DelegationHelper.sol";

import {IAaveV3Pool} from "./interfaces/IAaveV3.sol";

// ──────────────────── Aave v3 FUSED leverage module ────────────────────
//
// One item that supplies collateral AND draws debt, instead of the MAKE(deposit)
// + TAKE(borrow) pair every leverage order carries today.
//
//  Why fuse
//  ────────
//  1. ATOMICITY BY CONSTRUCTION. Aave checks health inside `borrow`, so the supply
//     must precede it. As two items that is a SCHEDULING obligation — the solver
//     must keep them adjacent and in order, and `matchSettle` can only enforce it
//     if the maker opted into {ItemPolicy.ATOMIC}. Fused, the ordering lives inside
//     one call: no schedule can split it and no policy flag is needed.
//  2. ONE DISPATCH INSTEAD OF TWO. The pair costs three CALLs (Settlement→deposit
//     module, Settlement→Permit3→borrow module). Fused it costs two, plus one less
//     item slice, one less schedule step, and one less completeness bit.
//  3. A SMALLER APPROVAL SURFACE. The maker grants the token allowance and the
//     taker allowance to ONE module rather than two.
//
//  Why it is a TAKE
//  ────────────────
//  The gated leg is always the value-OUT one. Permit3's taker book is what
//  authorises drawing debt, so `amount` is denominated in the BORROW asset and the
//  taker allowance caps it. The collateral leg is derived (below) and is separately
//  capped by the maker's ordinary token allowance to this module — so both legs
//  stay bounded by something the maker signed.
//
//  Deriving the collateral from the sliced amount
//  ─────────────────────────────────────────────
//  Settlement pro-rates `item.amount` across partial fills but never tells a module
//  the fill fraction, so a fused item cannot carry two independent amounts. It
//  carries the maker's intended TOTALS instead and re-derives:
//
//      collateral = ceil(amount · collateralTotal / borrowTotal)
//
//  At a full fill `amount == borrowTotal`, so the collateral is exactly
//  `collateralTotal` — no drift on the common case. Across partial fills the
//  rounding is per-fill and rounds UP, i.e. always toward more collateral, so a
//  partially-filled position is never *under*-collateralised by the arithmetic.
//
//  `data = abi.encode(pool, borrowAsset, rateMode, collateralAsset,
//                     collateralTotal, borrowTotal
//                     [, debtToken, deadline, v, r, s])`
//    — base = 192 bytes; the optional Aave credit-delegation block sits after it,
//      exactly as in {AaveV3BorrowModule}, so a maker needs no prior on-chain
//      `approveDelegation`.
//    — rateMode: 1 = stable, 2 = variable (must match `debtToken` if delegating).
//
contract AaveV3FusedLeverageModule is ITakerModule {
    IPermit3 public immutable permit3;

    error OnlyPermit3();
    /// @dev `borrowTotal` was zero — the ratio would divide by zero. A maker-signed
    ///      field, so this is a malformed order rather than an adversarial input.
    error InvalidRatio();

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    /// @param amount   this fill's slice of the BORROW leg (what the taker
    ///                 allowance gates).
    /// @param receiver where the borrow proceeds land — Settlement on the netted
    ///                 path, so they fund the rest of the match.
    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        // The two legs are scoped separately, and `data` is decoded twice, so the
        // six maker-signed fields are never all live at once. Module packages
        // compile WITHOUT the optimizer in their fork profile, where a flat decode
        // of this many fields overflows the stack.
        address pool;
        {
            (address p,,, address collateralAsset, uint256 collateralTotal, uint256 borrowTotal) =
                abi.decode(data, (address, address, uint256, address, uint256, uint256));
            if (borrowTotal == 0) revert InvalidRatio();
            pool = p;

            // ── leg 1: supply the pro-rata collateral on the maker's behalf ──
            uint256 collateral = _ceilDiv(amount * collateralTotal, borrowTotal);
            if (collateral != 0) {
                permit3.transferFrom(onBehalfOf, address(this), collateralAsset, uint160(collateral));
                SafeTransferLib.forceApprove(collateralAsset, pool, collateral);
                IAaveV3Pool(pool).supply(collateralAsset, collateral, onBehalfOf, 0);
            }
        }
        {
            (, address borrowAsset, uint256 rateMode) = abi.decode(data, (address, address, uint256));

            // ── leg 2: draw the debt against it, in the same call ──
            // Optional delegation-with-sig, block at 192: (debtToken, deadline, v, r, s).
            DelegationHelper.replayAaveDelegation(data, 192, onBehalfOf, address(this), amount);
            IAaveV3Pool(pool).borrow(borrowAsset, amount, rateMode, 0, onBehalfOf);
            SafeTransferLib.safeTransfer(borrowAsset, receiver, amount);
        }
    }

    /// @dev ceil(a / b), b > 0 — mirrors {Pricing.ceilDiv}. Rounds the collateral
    ///      up so a partial fill is never under-collateralised by rounding.
    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
