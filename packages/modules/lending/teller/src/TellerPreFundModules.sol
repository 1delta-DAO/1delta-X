// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";
import {IFundingSource} from "@core/interfaces/IFundingSource.sol";

import {ITellerPool, ITellerV2} from "./interfaces/ITeller.sol";

// ──────────────── Teller V2 PRE-FUNDED one-sided modules ────────────────
//
// "Deposit whatever the conversion delivered" and "repay whatever the conversion
// delivered", with ZERO receive-side approvals: the maker signs the converted
// output leg with `recipient = module` and a `TAKE_FOR` item whose leg-reference
// descriptor points at it. The core sizes `forAmount` to exactly what the fill
// delivered here ({Base._forSlice} → {Pricing.outputAt}), auction decay included,
// and this module supplies/repays it from its own balance. The maker's only
// grants are the ones they had anyway: the ERC20+Permit3 approval on the asset
// they are CONVERTING FROM (the input leg), and the taker allowance below. The
// received asset needs nothing — it never transits the maker's wallet, and both
// Teller ops (`deposit(assets, receiver)`, `repayLoan`/`repayLoanFull`) are
// PERMISSIONLESS on someone else's behalf, so the receive side is empty end to
// end. These are pre-fund variants of exactly the two ops {TellerModules} ships —
// pool supply and loan repay; borrow and pool withdraw stay unwired for the
// protocol reasons the package README gives.
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


/// @notice ONE contract for every pre-funded one-sided op on Teller.
/// @dev    Replaces {TellerPreFundPoolDepositModule}, {TellerPreFundRepayModule}. `Op` rides in
///         descriptor bits [244,252) — see {PreFundModuleBase._preFundOp} for why the
///         discriminator lives in the word the maker already signs rather than in a
///         new `data` field. Merging is safe because the op is INSIDE `data`, and `data` is
///         inside the maker's ORDER signature: an item signed for one op cannot be
///         executed as another. Each op keeps its own decode, so the
///         per-op `data` layouts are unchanged apart from the descriptor bits.
contract TellerPreFundModule is PreFundModuleBase, IMakerModule, IFundingSource {
    enum Op {
        PoolDeposit,
        Repay
    }

    /// @dev The descriptor named an op this module does not implement.
    error BadOp(uint256 op);


    constructor(address _permit3, address _settlement) PreFundModuleBase(_permit3, _settlement) {}

    /// @param onBehalfOf the maker — whose position this fill acts on.
    /// @param forAmount  this fill's delivered output leg, core-sized; supplied
    ///                   from this module's own balance.
    function makeOnBehalf(address onBehalfOf, uint256 forAmount, bytes calldata data) external override {
        _gatePreFundMake(data);
        // A dust slice can floor the funding leg to zero; skip, as every composite
        // module does — it accumulates exactly across fills.
        if (forAmount == 0) return;
        uint256 op = _preFundOp(data);
        if (op == uint256(Op.PoolDeposit)) {
        (, address pool, address asset) = abi.decode(data, (uint256, address, address));
        // Scoped approve + CLEAR: `pool` is decoded from order data on a shared
        // singleton, so it is attacker-choosable (F25 / lead A-3). `deposit`
        // consumes exactly `forAmount`, so no sweep is needed.
        // The delivery must have landed HERE, in THIS token — the funding leg's
        // recipient is bound by the core (descriptor bit 253) and CONSUMED
        // ({Base.ForLegReused}), but its TOKEN is not (F27/H-1). Underflows if
        // it did not; sound because `msg.sender == settlement` pins `forAmount`.
        PreFundGuard.requireDelivered(data, asset, forAmount);
        SafeTransferLib.forceApprove(asset, pool, forAmount);
        ITellerPool(pool).deposit(forAmount, onBehalfOf);
        SafeTransferLib.forceApprove(asset, pool, 0);
        } else if (op == uint256(Op.Repay)) {
        // Its own frame: the fork profiles compile without the optimizer, where the
        // five-field decode plus the repay-and-sweep logic overflows this stack.
        _repayAndSweep(onBehalfOf, forAmount, data);
        } else {
            revert BadOp(op);
        }
    }


    function _repayAndSweep(address onBehalfOf, uint256 forAmount, bytes calldata data) private {
        (, address tellerV2, address principalToken) = abi.decode(data, (uint256, address, address));
        // The pre-existing floor: this fill's delivery (`forAmount`) is already on
        // the balance, so `entry − forAmount` is what was here before. A leg NOT
        // addressed to this module leaves `entry < forAmount` and this underflows —
        // the mis-pairing fails closed, as the pre-fund shape requires.
        uint256 floor = PreFundGuard.floorOf(data, principalToken, forAmount);
        {
            // Tail decode (bidId @96, full @128) via a calldata slice, as
            // {TellerRepayModule} keeps its frame flat with a single decode.
            (uint256 bidId, bool full) = abi.decode(data[96:], (uint256, bool));
            // Scoped approve + CLEAR — `tellerV2` is maker-data-choosable on a
            // shared singleton (F25 / lead A-3).
            SafeTransferLib.forceApprove(principalToken, tellerV2, forAmount);
            if (full) {
                ITellerV2(tellerV2).repayLoanFull(bidId);
            } else {
                ITellerV2(tellerV2).repayLoan(bidId, forAmount);
            }
            SafeTransferLib.forceApprove(principalToken, tellerV2, 0);
        }
        // Sweep the unused buffer — the DELTA this fill produced, never the floor.
        uint256 bal = IERC20(principalToken).balanceOf(address(this));
        if (bal > floor) SafeTransferLib.safeTransfer(principalToken, onBehalfOf, bal - floor);
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
