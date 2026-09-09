// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {ITakerForModule} from "@core/interfaces/ITakerForModule.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";
import {IFundingSource} from "@core/interfaces/IFundingSource.sol";
import {IProceedsAsset} from "@core/interfaces/IProceedsAsset.sol";
import {DelegationHelper} from "@lib/DelegationHelper.sol";
import {FundingPreflight} from "@lib/FundingPreflight.sol";
import {Narrow160} from "@lib/Narrow160.sol";

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
contract AaveV3LeverageModule is PreFundModuleBase, ITakerModule, ITakerForModule, IFundingSource, IProceedsAsset {
    /// @dev The RATIO-sized `take` seam was handed a zero borrow total, so the
    ///      collateral figure it derives is undefined.
    error InvalidRatio();

    constructor(address _permit3, address _settlement) PreFundModuleBase(_permit3, _settlement) {}

    /// @param spender   the `Permit3.takeFor` caller, pinned to Settlement.
    /// @param amount    this fill's slice of the BORROW leg (what the taker
    ///                  allowance gates).
    /// @param forAmount this fill's COLLATERAL, computed by the core from the
    ///                  signed descriptor — no ratio, no second signed total.
    /// @param receiver  where the borrow proceeds land.
    /// @dev BOTH FUNDING SHAPES, selected by descriptor bit 253. The two used to be
    ///      separate contracts differing by ONE line in the collateral leg:
    ///      `transferFrom` out of the maker's wallet (PULL) versus a balance floor
    ///      over a delivery already addressed here (PRE-FUND). Everything else — the
    ///      borrow leg, the delta check, the proceeds split — was duplicated
    ///      verbatim. See {PreFundModuleBase._fundingShape} for why one signed bit can
    ///      carry the choice safely.
    function takeForOnBehalf(
        address spender,
        address onBehalfOf,
        uint256 amount,
        uint256 forAmount,
        address receiver,
        bytes calldata data
    ) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();
        // Pinned for BOTH shapes. The pull shape does not strictly need it — there
        // the value comes out of `onBehalfOf`'s own wallet, so a self-granting
        // caller only robs themselves — but Settlement is the sole legitimate
        // spender either way, and one unconditional check beats a branch that has
        // to be right (F27/C-1).
        PreFundGuard.requireSettlement(spender, settlement);
        // Pin the funding half of the data space: leg-reference or balance, never
        // LITERAL. Literal is the one form that overlaps a plain-`take` blob
        // (`>> 253` of 0..3 versus 0), and this contract hosts both entrypoints, so
        // one `ref` must not be able to authorise both. Costs this op the literal
        // descriptor — which it never wanted: its whole point is a core-sized
        // funding leg.
        PreFundGuard.requireFundingDescriptor(data);

        // Leg 1 in its own frame: the shape branch plus this decode overflows the
        // stack when inlined alongside the borrow leg.
        //
        // ⚠ The original rationale — "these packages compile WITHOUT the optimizer in
        // their fork profile" — no longer holds: `modules-aave-v3-fork` was the ONLY
        // profile setting `optimizer = false`, and that flag made the profile fail to
        // compile outright (core outgrew the unoptimised stack in `Base._forSlice`),
        // so its 56 fork tests were not running. The flag is gone. The split stays —
        // it is free and keeps this function readable — but do not cite a profile
        // setting that no longer exists as the reason for it.
        address pool = _supplyLeg(onBehalfOf, forAmount, data);
        {
            (,,, address borrowAsset, uint256 rateMode) =
                abi.decode(data, (uint256, uint256, address, address, uint256));

            // ── leg 2: draw the debt against it, in the same call ──
            // Optional delegation-with-sig, block at 192: (debtToken, deadline, v, r, s).
            DelegationHelper.replayAaveDelegation(data, 192, onBehalfOf, address(this), amount);
            // Measure the delta rather than assuming the requested `amount` arrived:
            // an under-delivering borrow would otherwise be topped up from any
            // balance the module happens to hold and paid to the solver while the
            // user keeps the full debt — the H-3 River shape. Fail closed instead.
            uint256 balBefore = IERC20(borrowAsset).balanceOf(address(this));
            IAaveV3Pool(pool).borrow(borrowAsset, amount, rateMode, 0, onBehalfOf);
            uint256 received = IERC20(borrowAsset).balanceOf(address(this)) - balBefore;
            // Deliver the measured proceeds, capped at the signed amount; any excess
            // goes to the maker below. Never exceeds `received`, so a short delivery
            // (a fake/under-delivering venue) can never be topped up from a stray
            // balance the module holds — it simply delivers less and the fill's
            // output check fails downstream. Replaces a `received >= amount` gate.
            SafeTransferLib.safeTransfer(borrowAsset, receiver, received < amount ? received : amount);
            if (received > amount) {
                SafeTransferLib.safeTransfer(borrowAsset, onBehalfOf, received - amount);
            }
        }
    }

    /// @dev The collateral leg, and the ONE line where the two funding shapes
    ///      differ. Returns the pool so the borrow leg does not re-decode it.
    function _supplyLeg(address onBehalfOf, uint256 forAmount, bytes calldata data) private returns (address pool) {
        address collateralAsset;
        (,, pool,,, collateralAsset) = abi.decode(data, (uint256, uint256, address, address, uint256, address));
        // A dust slice can floor the funding leg to zero while the borrow leg still
        // rounds up. Skip rather than revert: it accumulates exactly across fills,
        // the same posture {Base._runItem} takes on a zero slice.
        if (forAmount == 0) return pool;
        uint256 floor;
        bool preFund = _fundingShape(data);
        if (preFund) {
            // PRE-FUND: the delivery must have landed HERE, in THIS token — the core
            // binds the leg's recipient (bit 253) but not its token (F27/H-1).
            // Underflows if it did not.
            //
            // ⚠ THE FLOOR IS KEPT, NOT DISCARDED. This half used the weaker
            // `requireDelivered`, which proves the same thing and throws the number
            // away; a venue consuming LESS than instructed then left the remainder
            // resident on a SHARED SINGLETON. {AaveV3PreFundModule._supply} was
            // migrated off exactly this shape and states the reason — residue on a
            // pre-fund singleton is the precondition the unbound-token drain
            // monetised. This is the last body in the package still on the old form.
            floor = PreFundGuard.floorOf(data, collateralAsset, forAmount);
        } else {
            // PULL: the classic shape — the leg was delivered to the maker's wallet
            // and is drawn back through their Permit3 token allowance.
            permit3.transferFrom(onBehalfOf, address(this), collateralAsset, uint160(forAmount));
        }
        // Scoped approve + CLEAR, not a standing grant. `pool` is decoded from the
        // order's `data` on a SHARED singleton, so it is attacker-choosable — anyone
        // can author an order naming themselves as maker. F25 / A-3.
        SafeTransferLib.forceApprove(collateralAsset, pool, forAmount);
        IAaveV3Pool(pool).supply(collateralAsset, forAmount, onBehalfOf, 0);
        SafeTransferLib.forceApprove(collateralAsset, pool, 0);
        // PRE-FUND only: the pull shape drew exactly `forAmount` from the maker's
        // wallet, so there is no pre-existing floor to sweep down to.
        if (preFund) PreFundGuard.sweepSurplus(collateralAsset, onBehalfOf, floor);
    }

    /// @dev WHICH OF THIS CONTRACT'S TWO `data` LAYOUTS `data` IS IN, and the reason
    ///      the views below cannot decode blindly. This is the one shipped module
    ///      hosting BOTH taker seams, and their byte maps are not aligned:
    ///
    ///        TAKE_FOR   0=forDesc 1=forCap 2=pool   3=borrowAsset    4=rateMode 5=collateralAsset
    ///        plain TAKE 0=pool    1=borrow 2=rate   3=collateralAsset 4=collTotal 5=borrowTotal
    ///
    ///      Field 3 is the borrow asset in one and the collateral asset in the other,
    ///      and a plain-TAKE blob decodes CLEANLY against the TAKE_FOR map (`rateMode`
    ///      is 1 or 2, a valid `address`), so a single decode does not revert — it
    ///      returns the wrong token, silently, which is worse. {SettlementLens} runs
    ///      `_proceedsItemAt` for `TAKE` as well as `TAKE_FOR`, so the §F22
    ///      stranded-proceeds preflight was reading `collateralAsset` and answering
    ///      about the wrong leg in both directions.
    ///
    ///      The discriminator is the one the ENTRYPOINTS already enforce, so the views
    ///      and the dispatch cannot disagree: {takeOnBehalf} pins
    ///      `PreFundGuard.requirePlainTake` (`word0 >> 253 == 0` — word 0 is a `pool`
    ///      address) and {takeForOnBehalf} pins `requireFundingDescriptor` (bit 255
    ///      set, i.e. `>> 253` in 4..7). The two spaces are disjoint by construction,
    ///      which is the same property that keeps one `ref` from authorising both.
    function _isRatioLayout(bytes calldata data) private pure returns (bool) {
        return uint256(bytes32(data[0:32])) >> 253 == 0;
    }

    /// @inheritdoc IFundingSource
    /// @dev The COLLATERAL asset — field 5 on the `takeFor` map, field 3 on the ratio
    ///      map. The ONE place this module's funding asset is named, and the one the
    ///      lens cross-checks against the leg the amount was sized by. `available` is
    ///      shape-dependent: a wallet/allowance read would preview a PRE-FUND
    ///      (self-funding) order as short.
    function fundingSource(address onBehalfOf, bytes calldata data)
        external
        view
        override
        returns (address asset, uint256 available)
    {
        if (_isRatioLayout(data)) {
            (,,, asset) = abi.decode(data, (uint256, uint256, uint256, address));
        } else {
            (,,,,, asset) = abi.decode(data, (uint256, uint256, address, address, uint256, address));
        }
        available = _fundingShape(data)
            ? type(uint256).max
            : FundingPreflight.pullable(permit3, address(this), onBehalfOf, asset);
    }

    /// @inheritdoc IProceedsAsset
    /// @dev The BORROW asset — what lands on `receiver`. Field 3 on the `takeFor` map,
    ///      field 1 on the ratio map. Its funding counterpart, the collateral, is the
    ///      other of the two; they must not be confused, which is precisely why both
    ///      are declared rather than inferred — and why {_isRatioLayout} exists.
    function proceedsAsset(bytes calldata data) external pure override returns (address asset) {
        if (_isRatioLayout(data)) {
            (, asset) = abi.decode(data, (uint256, address));
        } else {
            (,,, asset) = abi.decode(data, (uint256, uint256, address, address));
        }
    }

    // ──────────────── the RATIO-sized sibling, on the plain `take` seam ────────────────
    //
    // Same position, same borrow leg, same delta check. The ONLY difference is
    // where the collateral figure comes from: here a maker-signed RATIO of the
    // borrow, above the core's own sizing of the funding leg. That is why the two
    // existed as separate contracts, and it is not a reason to deploy twice.

    /// @param amount   this fill's slice of the BORROW leg (what the taker
    ///                 allowance gates).
    /// @param receiver where the borrow proceeds land — Settlement on the netted
    ///                 path, so they fund the rest of the match.
    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();
        // Pin the plain-take half of the data space. Word 0 here is `pool`, an
        // address, so `>> 253 == 0` — and excluding the LITERAL funding form on
        // the `takeFor` side below leaves the two provably disjoint, which is
        // what lets one `ref` mean exactly one dispatch.
        PreFundGuard.requirePlainTake(data);

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
                permit3.transferFrom(onBehalfOf, address(this), collateralAsset, Narrow160.to160(collateral));
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
            // Measure the borrow's delta (`balBefore` excludes residue) and deliver
            // that measured amount, capped at `amount`, below — never a nominal top-up
            // from a stray balance; a short/fake-pool borrow delivers less and fails
            // the output check downstream. (No FoT borrow reserves by policy.)
            uint256 balBefore = IERC20(borrowAsset).balanceOf(address(this));
            IAaveV3Pool(pool).borrow(borrowAsset, amount, rateMode, 0, onBehalfOf);
            uint256 received = IERC20(borrowAsset).balanceOf(address(this)) - balBefore;
            // Deliver the measured proceeds, capped at the signed amount; any excess
            // goes to the maker below. Never exceeds `received`, so a short delivery
            // (a fake/under-delivering venue) can never be topped up from a stray
            // balance the module holds — it simply delivers less and the fill's
            // output check fails downstream. Replaces a `received >= amount` gate.
            SafeTransferLib.safeTransfer(borrowAsset, receiver, received < amount ? received : amount);
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
