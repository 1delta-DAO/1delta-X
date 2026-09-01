// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {ITakerForModule} from "@core/interfaces/ITakerForModule.sol";
import {IFundingSource} from "@core/interfaces/IFundingSource.sol";
import {IProceedsAsset} from "@core/interfaces/IProceedsAsset.sol";
import {DelegationHelper} from "@lib/DelegationHelper.sol";
import {FundingPreflight} from "@lib/FundingPreflight.sol";

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
                // Scoped approve + CLEAR, not a standing grant. `pool` is decoded from the
                // order's `data` on a SHARED singleton module, so it is attacker-choosable —
                // anyone can author an order naming themselves as maker. A target that
                // consumes less than approved would leave this module holding a permanent
                // third-party claim on any FUTURE balance of `collateralAsset`, which is what turns a
                // later residual-stranding bug into a theft. {SafeTransferLib.ensureApproval}'s
                // own note forbids exactly this shape, and every Midnight module already
                // clears. F25 / lead A-3.
                SafeTransferLib.forceApprove(collateralAsset, pool, collateral);
                IAaveV3Pool(pool).supply(collateralAsset, collateral, onBehalfOf, 0);
                SafeTransferLib.forceApprove(collateralAsset, pool, 0);
            }
        }
        {
            (, address borrowAsset, uint256 rateMode) = abi.decode(data, (address, address, uint256));

            // ── leg 2: draw the debt against it, in the same call ──
            // Optional delegation-with-sig, block at 192: (debtToken, deadline, v, r, s).
            DelegationHelper.replayAaveDelegation(data, 192, onBehalfOf, address(this), amount);
            // Measure the delta rather than assuming the requested `amount` arrived:
            // an under-delivering borrow (fee-on-transfer underlying, a capped or
            // partially-filled reserve) would otherwise be topped up from any balance
            // the module happens to hold and paid to the solver, while the user keeps
            // the full debt — the H-3 River shape. Fail closed instead. Matches
            // {AaveV4BorrowModule}, which already carried this guard.
            uint256 balBefore = IERC20(borrowAsset).balanceOf(address(this));
            IAaveV3Pool(pool).borrow(borrowAsset, amount, rateMode, 0, onBehalfOf);
            uint256 received = IERC20(borrowAsset).balanceOf(address(this)) - balBefore;
            require(received >= amount, "insufficient borrowed");
            SafeTransferLib.safeTransfer(borrowAsset, receiver, amount);
            if (received > amount) {
                SafeTransferLib.safeTransfer(borrowAsset, onBehalfOf, received - amount);
            }
        }
    }

    /// @dev ceil(a / b), b > 0 — mirrors {Pricing.ceilDiv}. Rounds the collateral
    ///      up so a partial fill is never under-collateralised by rounding.
    function _ceilDiv(uint256 a, uint256 b) private pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}

// ──────────────── Aave v3 TAKE_FOR leverage module (core-funded) ────────────────
//
// The same one-call supply+borrow as {AaveV3FusedLeverageModule} above, but the
// collateral amount is handed in by the SETTLER instead of being re-derived here.
//
//  What changes, and why it matters
//  ────────────────────────────────
//  The fused module carries the maker's two TOTALS in `data` and re-derives
//  `collateral = ceil(amount · collateralTotal / borrowTotal)`. The arithmetic is
//  sound — the borrow decimals cancel — but `collateralTotal` is a SECOND COPY of
//  a number the order already signs as an output leg, sitting in a blob the core
//  never decodes and nothing cross-checks. A mis-scaled copy is silent: too large
//  and the supply leg pulls up to the maker's standing Permit3 token allowance,
//  too small and the position is under-collateralised or the borrow reverts. The
//  ceil is also per-fill, so a partially-filled order over-supplies by up to one
//  unit per slice.
//
//  Here the amount arrives as `forAmount`, resolved by {Base._forSlice} from the
//  descriptor the maker signed. Point it at the collateral OUTPUT LEG and there is
//  exactly one copy of the number, with its token and decimals beside it in a
//  typed leg — the leg the solver just delivered to the maker, which this call
//  supplies straight back into Aave. It also prices a DECAYING collateral leg
//  correctly, which a fixed ratio cannot.
//
//  `data = abi.encode(forDesc, forCap, pool, borrowAsset, rateMode, collateralAsset
//                     [, debtToken, deadline, v, r, s])`
//    — base = 192 bytes; the optional Aave credit-delegation block follows it,
//      exactly as in {AaveV3BorrowModule} and the fused module above.
//    — `forDesc` selects where the collateral amount comes from:
//        `(1 << 255) | legIndex`            fund from `legsOut[legIndex]` — the
//                                           levered shape, nothing duplicated;
//        `(3 << 254) | (floorBps << 160)
//                     | uint160(token)`      fund with `min(balance, forCap)`, and
//                                           revert below `floorBps` of the cap —
//                                           the NO-CONVERSION shape (deposit what
//                                           I hold), full-fill only;
//        a plain total                      a fixed wallet-funded amount, sliced
//                                           pro-rata by the core.
//    — `forCap` is the mandatory cap for the balance form and is IGNORED (pass 0)
//      by the other two. It is carried unconditionally so this module has ONE
//      `data` layout instead of one per funding mode.
//    — rateMode: 1 = stable, 2 = variable (must match `debtToken` if delegating).
//
contract AaveV3TakeForLeverageModule is ITakerForModule, IFundingSource, IProceedsAsset {
    IPermit3 public immutable permit3;

    error OnlyPermit3();

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    /// @param amount    this fill's slice of the BORROW leg (what the taker
    ///                  allowance gates).
    /// @param forAmount this fill's COLLATERAL, computed by the core from the
    ///                  signed descriptor — no ratio, no second signed total.
    /// @param receiver  where the borrow proceeds land.
    function takeForOnBehalf(
        address onBehalfOf,
        uint256 amount,
        uint256 forAmount,
        address receiver,
        bytes calldata data
    ) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        // Decoded in two scopes, as in the fused module above: these packages
        // compile WITHOUT the optimizer in their fork profile, where one flat
        // decode of this many fields overflows the stack.
        address pool;
        {
            (,, address p,,, address collateralAsset) =
                abi.decode(data, (uint256, uint256, address, address, uint256, address));
            pool = p;

            // ── leg 1: supply the collateral the core sized ──
            // A dust slice can floor the funding leg to zero while the borrow leg
            // still rounds up. Skip rather than revert: it accumulates exactly
            // across fills, the same posture {Base._runItem} takes on a zero slice.
            if (forAmount != 0) {
                permit3.transferFrom(onBehalfOf, address(this), collateralAsset, uint160(forAmount));
                // Scoped approve + CLEAR, not a standing grant. `pool` is decoded from the
                // order's `data` on a SHARED singleton module, so it is attacker-choosable —
                // anyone can author an order naming themselves as maker. A target that
                // consumes less than approved would leave this module holding a permanent
                // third-party claim on any FUTURE balance of `collateralAsset`, which is what turns a
                // later residual-stranding bug into a theft. {SafeTransferLib.ensureApproval}'s
                // own note forbids exactly this shape, and every Midnight module already
                // clears. F25 / lead A-3.
                SafeTransferLib.forceApprove(collateralAsset, pool, forAmount);
                IAaveV3Pool(pool).supply(collateralAsset, forAmount, onBehalfOf, 0);
                SafeTransferLib.forceApprove(collateralAsset, pool, 0);
            }
        }
        {
            (,,, address borrowAsset, uint256 rateMode) =
                abi.decode(data, (uint256, uint256, address, address, uint256));

            // ── leg 2: draw the debt against it, in the same call ──
            // Optional delegation-with-sig, block at 192: (debtToken, deadline, v, r, s).
            DelegationHelper.replayAaveDelegation(data, 192, onBehalfOf, address(this), amount);
            // Measure the delta rather than assuming the requested `amount` arrived:
            // an under-delivering borrow (fee-on-transfer underlying, a capped or
            // partially-filled reserve) would otherwise be topped up from any balance
            // the module happens to hold and paid to the solver, while the user keeps
            // the full debt — the H-3 River shape. Fail closed instead. Matches
            // {AaveV4BorrowModule}, which already carried this guard.
            uint256 balBefore = IERC20(borrowAsset).balanceOf(address(this));
            IAaveV3Pool(pool).borrow(borrowAsset, amount, rateMode, 0, onBehalfOf);
            uint256 received = IERC20(borrowAsset).balanceOf(address(this)) - balBefore;
            require(received >= amount, "insufficient borrowed");
            SafeTransferLib.safeTransfer(borrowAsset, receiver, amount);
            if (received > amount) {
                SafeTransferLib.safeTransfer(borrowAsset, onBehalfOf, received - amount);
            }
        }
    }

    /// @inheritdoc IFundingSource
    /// @dev `collateralAsset` is field 5 of the layout above — the ONE place this
    ///      module's funding asset is named, and the one the lens cross-checks
    ///      against the leg the amount was sized by.
    function fundingSource(address onBehalfOf, bytes calldata data)
        external
        view
        override
        returns (address asset, uint256 available)
    {
        (,,,,, asset) = abi.decode(data, (uint256, uint256, address, address, uint256, address));
        available = FundingPreflight.pullable(permit3, address(this), onBehalfOf, asset);
    }

    /// @inheritdoc IProceedsAsset
    /// @dev The BORROW asset (field 3) — what lands on `receiver`. Its funding
    ///      counterpart, the collateral, is field 5; the two must not be confused,
    ///      which is precisely why both are declared rather than inferred.
    function proceedsAsset(bytes calldata data) external pure override returns (address asset) {
        (,,, asset) = abi.decode(data, (uint256, uint256, address, address));
    }
}
