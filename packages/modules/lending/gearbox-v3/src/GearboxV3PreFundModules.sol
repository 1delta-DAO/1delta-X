// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";
import {IFundingSource} from "@core/interfaces/IFundingSource.sol";

import {IGearboxPoolV3} from "./interfaces/IGearboxV3.sol";

// ──────────────── Gearbox V3 PRE-FUNDED one-sided module ────────────────
//
// "Deposit whatever the conversion delivered" into the passive PoolV3 (ERC-4626)
// supply side, with ZERO receive-side approvals: the maker signs the converted
// output leg with `recipient = module` and a `TAKE_FOR` item whose leg-reference
// descriptor points at it. The core sizes `forAmount` to exactly what the fill
// delivered here ({Base._forSlice} → {Pricing.outputAt}), auction decay included,
// and this module supplies it from its own balance. The maker's only grants are
// the ones they had anyway: the ERC20+Permit3 approval on the asset they are
// CONVERTING FROM (the input leg), and the taker allowance below. The received
// asset needs nothing — it never transits the maker's wallet, and PoolV3's
// `deposit(assets, receiver)` is PERMISSIONLESS on someone else's behalf, so the
// receive side is empty end to end.
//
//  ⚠ POOL SIDE ONLY — the credit-account surface is deliberately SKIPPED.
//  ─────────────────────────────────────────────────────────────────────
//  The credit-account modules in {GearboxV3Modules} run through `botMulticall`
//  under the bot-permission model, which this repo treats as best-effort
//  (fund-flow "still unvalidated on a fork" per that file's header, the
//  once-per-block debt-update rule, quota handling). A pre-fund composite whose
//  funding number is core-enforced deserves a venue op that is not best-effort,
//  so no pre-funded add-collateral / credit-repay variant ships here. If the
//  credit side ever graduates, mirror {GearboxCreditAddCollateralModule}'s
//  CA-rooted auth chain ({GearboxCreditAuth.authorize}) verbatim — the borrower
//  check is what keeps a shared bot singleton from acting on a victim's account.
//
//  Why these ride the MAKE seam
//  ────────────────────────────
//  These ops move NOTHING out of the position — they supply or retire whatever the
//  conversion delivered — so they ARE `MAKE` items, and until 2026-09 they could
//  not say so. A `MAKE` amount was a maker-signed total, pro-rated blind: it could
//  not track an auctioned delivery, and a module funding from its own balance
//  against a number the core did not size to an ENFORCED delivery lets one order's
//  item consume another order's delivery. The pre-fund leg-reference descriptor is now
//  that channel on BOTH seams — {Base._runItem} sizes a pre-funded `MAKE` through
//  {Base._forSlice}, exactly as it sizes a `TAKE_FOR`'s funding side — so the
//  composite costume these wore is gone.
//
//  What the move buys, beyond the honesty
//  ──────────────────────────────────────
//  Settlement dispatches `MAKE` DIRECTLY; `TAKE_FOR` goes through Permit3. So the
//  caller pin is `msg.sender`, asserted by the EVM, rather than a forwarded
//  `spender` word every module had to remember to compare — F27/C-1's channel does
//  not exist on this seam at all, because there is no permissionless entrypoint in
//  front of it. No taker allowance is granted or spent for a book whose purpose is
//  bounding what LEAVES a position. And `item.amount` stops being a "pacing figure"
//  distinct from the funded one: it is UNREAD here, so F27/C-2's two-denominator
//  strand cannot be expressed. Measured on Aave v3, the same swap-and-deposit fill:
//  860,684 → 820,877 gas.
//
//  LEG-REFERENCE ONLY, enforced. A LITERAL descriptor would instruct amounts this
//  module has no delivery for (its balance fails closed, but the revert is
//  clearer here), and a BALANCE descriptor reads the MAKER's wallet while this
//  module funds from its own — a mis-pairing by construction. Both are rejected
//  up front.
//
// `data = abi.encode(forDesc, pool, asset)` — descriptor word FIRST (forDesc@0),
// the PoolV3 vault @32, its underlying @64; 96 bytes total.
/// @dev ON {PreFundModuleBase}, like every other pre-fund module. It used to
///      hand-roll the pin and the descriptor check — the same two lines, spelled
///      differently — which is how a seam invariant becomes 16 independent chances
///      to get it wrong. `tools/check-module-shapes.py` now enforces the shared
///      helper, and this contract was the one thing it found.
contract GearboxPoolPreFundDepositModule is PreFundModuleBase, IMakerModule, IFundingSource {
    constructor(address _permit3, address _settlement) PreFundModuleBase(_permit3, _settlement) {}

    /// @param onBehalfOf the maker — whose pool (dToken) balance receives the supply.
    /// @param forAmount  this fill's delivered output leg, core-sized; supplied
    ///                   from this module's own balance.
    function makeOnBehalf(address onBehalfOf, uint256 forAmount, bytes calldata data) external override {
        _gatePreFundMake(data);
        // A dust slice can floor the funding leg to zero; skip, as every composite
        // module does — it accumulates exactly across fills.
        if (forAmount == 0) return;
        (, address pool, address asset) = abi.decode(data, (uint256, address, address));
        // Scoped approve + CLEAR: `pool` is decoded from order data on a shared
        // singleton, so it is attacker-choosable (F25 / lead A-3).
        // The delivery must have landed HERE, in THIS token — the funding leg's
        // recipient is bound by the core (descriptor bit 253) and CONSUMED
        // ({Base.ForLegReused}), but its TOKEN is not (F27/H-1). Underflows if
        // it did not; sound because `msg.sender == settlement` pins `forAmount`.
        PreFundGuard.requireDelivered(data, asset, forAmount);
        SafeTransferLib.forceApprove(asset, pool, forAmount);
        IGearboxPoolV3(pool).deposit(forAmount, onBehalfOf);
        SafeTransferLib.forceApprove(asset, pool, 0);
    }

    /// @inheritdoc IFundingSource
    /// @dev Funded by the fill's OWN delivery — a wallet/allowance read would
    ///      preview a self-funding order as short.
    function fundingSource(address, bytes calldata data)
        external
        pure
        override
        returns (address asset, uint256 available)
    {
        (,, asset) = abi.decode(data, (uint256, address, address));
        available = type(uint256).max;
    }
}
