// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";
import {IFundingSource} from "@core/interfaces/IFundingSource.sol";

import {IMoolah, IListaBroker, MarketParams} from "./interfaces/ILista.sol";

// ──────────────── Lista (Moolah + LendingBroker) PRE-FUNDED one-sided modules ────────────────
//
// "Supply-collateral whatever the conversion delivered" and "repay whatever the
// conversion delivered", with ZERO receive-side approvals: the maker signs the
// converted output leg with `recipient = module` and a `TAKE_FOR` item whose
// leg-reference descriptor points at it. The core sizes `forAmount` to exactly
// what the fill delivered here ({Base._forSlice} → {Pricing.outputAt}), auction
// decay included, and this module supplies/repays it from its own balance. The
// maker's only grants are the ones they had anyway: the ERC20+Permit3 approval
// on the asset they are CONVERTING FROM (the input leg), and the taker allowance
// below. The received asset needs nothing — it never transits the maker's
// wallet, and both value-in venue ops are PERMISSIONLESS on someone else's
// behalf (Moolah `supplyCollateral(…, onBehalf, …)` is Morpho-shaped; the
// broker's `repay(amount, [loanId,] onBehalf)` takes anyone's money), so unlike the
// borrow/withdraw taker legs these need no Moolah `setAuthorization` either:
// the receive side is empty end to end.
//
//  ⚠ Provider-gated markets. Lista's Moolah diverges from Morpho Blue with a
//  per-market `providers[id][token]` gate: when a provider is registered for a
//  market's COLLATERAL token, `supplyCollateral` requires `msg.sender ==
//  provider` and reverts `"not provider"` for any module — the same structural
//  exclusion the pull-funded {ListaSupplyCollateralModule} documents. Off-chain
//  order construction must check `providers[id][collateralToken] == 0` before
//  offering the pre-funded supply-collateral leg on a Lista market.
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
//  module has no delivery for, and a BALANCE descriptor reads the MAKER's wallet
//  while this module funds from its own — a mis-pairing by construction. Both are
//  rejected up front.
//
// `data = abi.encode(forDesc, moolah, MarketParams)` — descriptor word FIRST
// (forDesc@0), the Moolah singleton @32, `MarketParams` (5 static words) @64;
// 224 bytes total — the same byte map as the Morpho Blue pre-fund siblings.


/// @notice ONE contract for every pre-funded one-sided op on Lista.
/// @dev    Replaces {ListaPreFundSupplyCollateralModule}, {ListaPreFundBrokerRepayModule}. `Op` rides in
///         descriptor bits [244,252) — see {PreFundModuleBase._preFundOp} for why the
///         discriminator lives in the word the maker already signs rather than in a
///         new `data` field. Merging is safe because the op is INSIDE `data`, and `data` is
///         inside the maker's ORDER signature: an item signed for one op cannot be
///         executed as another. Each op keeps its own decode, so the
///         per-op `data` layouts are unchanged apart from the descriptor bits.
contract ListaPreFundModule is PreFundModuleBase, IMakerModule, IFundingSource {
    enum Op {
        SupplyCollateral,
        BrokerRepay
    }

    /// @dev Sentinel `loanId` meaning "the broker's dynamic loan", mirroring
    ///      {ListaModules}' private constant of the same name.
    uint256 private constant DYNAMIC_LOAN = type(uint128).max;

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
        if (op == uint256(Op.SupplyCollateral)) {
        _supplyCollateral(onBehalfOf, forAmount, data);
        } else if (op == uint256(Op.BrokerRepay)) {
        // Its own frame — see the supply sibling.
        _repay(onBehalfOf, forAmount, data);
        } else {
            revert BadOp(op);
        }
    }


    /// @dev Its own frame: the fork profiles elsewhere compile without the
    ///      optimizer, where the struct decode plus the venue call is too much
    ///      for one stack.
    function _supplyCollateral(address onBehalfOf, uint256 forAmount, bytes calldata data) private {
        (, address moolah, MarketParams memory mp) = abi.decode(data, (uint256, address, MarketParams));
        // Scoped approve + CLEAR: `moolah` is decoded from order data on a shared
        // singleton, so it is attacker-choosable (F25 / lead A-3).
        // The delivery must have landed HERE, in THIS token — the funding leg's
        // recipient is bound by the core (descriptor bit 253) and CONSUMED
        // ({Base.ForLegReused}), but its TOKEN is not (F27/H-1). Underflows if
        // it did not; sound because `msg.sender == settlement` pins `forAmount`.
        PreFundGuard.requireDelivered(data, mp.collateralToken, forAmount);
        SafeTransferLib.forceApprove(mp.collateralToken, moolah, forAmount);
        IMoolah(moolah).supplyCollateral(mp, forAmount, onBehalfOf, "");
        SafeTransferLib.forceApprove(mp.collateralToken, moolah, 0);
    }

    function _repay(address onBehalfOf, uint256 forAmount, bytes calldata data) private {
        (, address broker, address loanToken, uint256 loanId) =
            abi.decode(data, (uint256, address, address, uint256));
        // The pre-existing floor — see {PreFundGuard}. A funding leg not addressed to
        // THIS module in THIS token underflows here, so the mis-pairing fails
        // closed; sound because `msg.sender == settlement` pins `forAmount` to the
        // core (F27/C-1, C-4). Unlike Liquity's sibling this module needs no extra
        // token-binding argument: the venue pulls through the scoped approval
        // below, so the token it takes and the token measured here are the same by
        // construction. (H-2 is specific to a venue that moves value WITHOUT an
        // approval — `repayBold` burns directly from `msg.sender`.)
        uint256 floor = PreFundGuard.floorOf(data, loanToken, forAmount);
        // The broker pulls the LITERAL amount and refunds what the debt did not
        // consume, so the consumed amount has to be MEASURED. The approval caps
        // the pull at `forAmount`, so the delta can never dip into another
        // fill's dust.
        // Scoped approve + CLEAR: `broker` is decoded from order data on a shared
        // singleton, so it is attacker-choosable (F25 / lead A-3).
        SafeTransferLib.forceApprove(loanToken, broker, forAmount);
        // `repay(forAmount, …)` ⇒ repay up to the live debt, refund the rest here.
        // NOT `repay(0, …)`: the deployed broker reverts `ZeroAmount()` on it —
        // see the header.
        if (loanId == DYNAMIC_LOAN) {
            IListaBroker(broker).repay(forAmount, onBehalfOf);
        } else {
            IListaBroker(broker).repay(forAmount, loanId, onBehalfOf);
        }
        SafeTransferLib.forceApprove(loanToken, broker, 0);
        // The delivered surplus belongs to the maker, not to this singleton.
        PreFundGuard.sweepSurplus(loanToken, onBehalfOf, floor);
    }


    /// @inheritdoc IFundingSource
    /// @dev Funded by the fill's OWN delivery — a wallet/allowance read would
    ///      preview a self-funding order as short. PER-OP: SupplyCollateral's third field is a `MarketParams` STRUCT and
    ///      BrokerRepay's is a plain `address`, so one decode cannot serve both —
    ///      reading the repay blob as a struct would follow a head offset into
    ///      nonsense.
    function fundingSource(address, bytes calldata data)
        external
        pure
        override
        returns (address asset, uint256 available)
    {
        if (_preFundOp(data) == uint256(Op.BrokerRepay)) {
            (,, asset,) = abi.decode(data, (uint256, address, address, uint256));
        } else {
            (,, MarketParams memory mp) = abi.decode(data, (uint256, address, MarketParams));
            asset = mp.collateralToken;
        }
        available = type(uint256).max;
    }
}
