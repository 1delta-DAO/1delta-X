// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";
import {IFundingSource} from "@core/interfaces/IFundingSource.sol";

import {
    IGearboxPoolV3,
    IGearboxCreditFacadeV3,
    IGearboxCreditFacadeV3Multicall,
    ICreditManagerV3,
    IGearboxBot,
    MultiCall
} from "./interfaces/IGearboxV3.sol";
import {GearboxCreditAuth} from "./GearboxV3Modules.sol";

// ──────────────── Gearbox V3 PRE-FUNDED one-sided module ────────────────
//
// "Deposit whatever the conversion delivered" into the passive PoolV3 (ERC-4626)
// supply side, with ZERO receive-side approvals: the maker signs the converted
// output leg with `recipient = module` and a pre-funded `MAKE` item whose
// leg-reference descriptor points at it. The core sizes `forAmount` to exactly
// what the fill delivered here ({Base._forSlice} → {Pricing.outputAt}), auction
// decay included, and this module supplies it from its own balance. The maker's
// only grant is the one they had anyway: the ERC20+Permit3 approval on the asset
// they are CONVERTING FROM (the input leg). No taker allowance is granted or spent
// — Settlement dispatches a `MAKE` directly. The received
// asset needs nothing — it never transits the maker's wallet, and PoolV3's
// `deposit(assets, receiver)` is PERMISSIONLESS on someone else's behalf, so the
// receive side is empty end to end.
//
//  The credit-account surface: {GearboxCreditPreFundModule}, below
//  ──────────────────────────────────────────────────────────────────
//  This section used to read "POOL SIDE ONLY — the credit-account surface is
//  deliberately SKIPPED", for four venue rules a core-sized delivery cannot respect
//  blind. Review 2026-10-18 M-1 graduated the credit side, because each of the four
//  turns out to FAIL CLOSED or to stay on the maker's own account, never to strand
//  value on the singleton or hand it to a filler:
//    • once-per-block debt update — only `Repay` touches debt, once; a shape that
//      also borrows on the same account in the same block reverts in Gearbox;
//    • `debtLimits` — a repay whose delivery leaves a residual debt in (0, minDebt)
//      reverts `BorrowAmountOutOfLimitsException` (a delivery AT or ABOVE the total
//      debt closes it to zero, the one sub-minDebt state Gearbox accepts);
//    • quotas — adding a quoted token without a quota does not revert, it simply
//      does not count as collateral until the maker quotas it; the tokens are on the
//      maker's own account either way;
//    • the forced-`Recycle` repay cap — `decreaseDebt` caps at the total debt, and
//      the uncapped part of the delivery, already moved in by `addCollateral`,
//      stays on the maker's account as underlying collateral (exactly the pull
//      sibling's {GearboxCreditRepayModule} posture). Nothing reaches this module's
//      sweep, nothing reaches the filler.
//  It mirrors {GearboxCreditAddCollateralModule}'s CA-rooted auth chain
//  ({GearboxCreditAuth.authorize}) verbatim — the borrower check is what keeps a
//  shared bot singleton from acting on a victim's account.
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
    /// @dev One op today. Read and checked like the other 15 pre-fund contracts
    ///      (audit 2026-09-30 L-CENSUS-8): an unchecked op would let any of the 256
    ///      descriptor values through as "deposit", and a blob signed for a FUTURE
    ///      sibling op would replay here.
    enum Op {
        Deposit
    }

    /// @dev The descriptor named an op this module does not implement.
    error BadOp(uint256 op);

    constructor(address _permit3, address _settlement) PreFundModuleBase(_permit3, _settlement) {}

    /// @param onBehalfOf the maker — whose pool (dToken) balance receives the supply.
    /// @param forAmount  this fill's delivered output leg, core-sized; supplied
    ///                   from this module's own balance.
    function makeOnBehalf(address onBehalfOf, uint256 forAmount, bytes calldata data) external override {
        _gatePreFundMake(data);
        uint256 op = _preFundOp(data);
        if (op != uint256(Op.Deposit)) revert BadOp(op);
        // A dust slice can floor the funding leg to zero; skip, as every composite
        // module does — it accumulates exactly across fills.
        if (forAmount == 0) return;
        (, address pool, address asset) = abi.decode(data, (uint256, address, address));
        // Scoped approve + CLEAR: `pool` is decoded from order data on a shared
        // singleton, so it is attacker-choosable (F25 / lead A-3).
        // The delivery must have landed HERE, in THIS token — the funding leg's
        // recipient is bound by the core (descriptor bit 253) and CONSUMED
        // ({Base.ForLegInvalid}), but its TOKEN is not (F27/H-1). Underflows if
        // it did not; sound because `msg.sender == settlement` pins `forAmount`.
        // KEEP THE FLOOR, DO NOT DISCARD IT. `requireDelivered` proves the same delivery
        // and throws the number away; a venue that consumes LESS than instructed then
        // leaves the remainder resident on a SHARED SINGLETON — the residue that every
        // pre-fund drain so far has monetised. Measured against the pre-delivery floor,
        // never sized from the venue's return value (F27/C-3). Aligned with the aave-v3
        // sibling and every `_repay` half (F28, 2026-09-12).
        uint256 floor = PreFundGuard.floorOf(data, asset, forAmount);
        SafeTransferLib.forceApprove(asset, pool, forAmount);
        IGearboxPoolV3(pool).deposit(forAmount, onBehalfOf);
        SafeTransferLib.forceApprove(asset, pool, 0);
        PreFundGuard.sweepSurplus(asset, onBehalfOf, floor);
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

// ──────────────── Gearbox V3 PRE-FUNDED credit-account module ────────────────
//
// The credit-account twin of the pool module above: add the delivered collateral to,
// or repay debt on, the maker's credit account from this module's own balance, with
// ZERO receive-side approvals (no Permit3 token allowance to the module, no ERC20
// approve of the delivered token). Closes review 2026-10-18 M-1 for Gearbox credit,
// whose add-collateral and repay makers were pull-only — so a zero-capital netted
// fill needed the maker to approve the module for a token they never held.
//
// Two ops, one STANDING GRANT — merged by the grant a maker hands over, the
// credit-module rule (`credit-module-grant-merge`): both are value-IN only and both
// fit inside ONE bot mask, `ADD_COLLATERAL | DECREASE_DEBT` (0x05). The op rides in
// descriptor bits [244,252), inside the signed order, so a delivery signed for
// "add collateral" cannot be retired as debt.
//
//   • AddCollateral (0): `botMulticall([addCollateral(token, forAmount)])`.
//   • Repay (1):         `botMulticall([addCollateral(underlying, forAmount),
//                                       decreaseDebt(forAmount)])` — fund the account
//                        and burn that much debt in one atomic multicall. Gearbox caps
//                        `decreaseDebt` at the TOTAL debt (principal + accrued
//                        interest + fees), so a delivery signed with headroom is a full
//                        close: the over-delivery stays on the account as collateral
//                        (forced `Recycle`, see the header). `token` must be the suite's
//                        `underlying` — `decreaseDebt` burns the underlying, and with any
//                        other token the multicall would retire debt out of the maker's
//                        EXISTING underlying while parking the delivery as collateral.
//
// The acyclic deleverage / close this unlocks: {GearboxCreditWithdrawModule} TAKE early
// (headroom carries the debt for one step), convert, deliver the underlying here, `Repay`
// late. The acyclic open: {GearboxCreditBorrowModule} TAKE early against existing
// collateral, convert, deliver the collateral here, `AddCollateral` late.
//
// Grant: `facade.multicall(ca, [setBotPermissions(module, 0x05)])` — once per account.
// Approval goes to the CREDIT MANAGER (it runs `addCollateral`'s `transferFrom` with this
// module as payer), scoped to `forAmount` and cleared after.
//
// `data = abi.encode(forDesc, creditAccount, token)` — forDesc@0 (op in bits [244,252)),
// creditAccount@32, token@64; 96 bytes for both ops.
contract GearboxCreditPreFundModule is PreFundModuleBase, IMakerModule, IFundingSource, IGearboxBot {
    enum Op {
        AddCollateral, // 0
        Repay // 1
    }

    /// @dev The descriptor named an op this module does not implement.
    error BadOp(uint256 op);
    /// @dev A `Repay` named a token other than the suite's debt asset.
    error NotUnderlying(address token, address underlying);

    constructor(address _permit3, address _settlement) PreFundModuleBase(_permit3, _settlement) {}

    /// @inheritdoc IGearboxBot
    /// @dev Value-IN only — no borrow bit, no collateral-out bit. Gearbox enforces the
    ///      exact match, so this grant can never be widened by accident.
    function requiredPermissions() external pure override returns (uint192) {
        return GearboxCreditAuth.ADD_COLLATERAL_PERMISSION | GearboxCreditAuth.DECREASE_DEBT_PERMISSION;
    }

    /// @param onBehalfOf the maker — the credit account's borrower.
    /// @param forAmount  this fill's delivered output leg, core-sized; spent from this
    ///                   module's own balance. `item.amount` is not read on this seam.
    function makeOnBehalf(address onBehalfOf, uint256 forAmount, bytes calldata data) external override {
        _gatePreFundMake(data);
        uint256 op = _preFundOp(data);
        if (op > uint256(Op.Repay)) revert BadOp(op);
        // A dust slice can floor the funding leg to zero; skip — it accumulates
        // exactly across fills.
        if (forAmount == 0) return;

        (, address creditAccount, address token) = abi.decode(data, (uint256, address, address));
        // The borrower check: a shared bot singleton is registered on EVERY onboarded
        // account, so without it an order could name a victim's account.
        (address creditManager, address facade) = GearboxCreditAuth.authorize(creditAccount, onBehalfOf);
        // The delivery must have landed HERE, in THIS token (descriptor-bound by
        // {PreFundGuard.floorOf}); sound because `msg.sender == settlement` pins
        // `forAmount`. KEPT: on the netted path another order's delivery may be parked
        // on this singleton, and the floor is what keeps it out of this sweep.
        uint256 floor = PreFundGuard.floorOf(data, token, forAmount);

        MultiCall[] memory calls;
        if (op == uint256(Op.AddCollateral)) {
            calls = new MultiCall[](1);
        } else {
            address underlying = ICreditManagerV3(creditManager).underlying();
            if (token != underlying) revert NotUnderlying(token, underlying);
            calls = new MultiCall[](2);
            calls[1] = MultiCall({
                target: facade, callData: abi.encodeCall(IGearboxCreditFacadeV3Multicall.decreaseDebt, (forAmount))
            });
        }
        calls[0] = MultiCall({
            target: facade, callData: abi.encodeCall(IGearboxCreditFacadeV3Multicall.addCollateral, (token, forAmount))
        });

        // Scoped approve + CLEAR to the manager derived from the account (never from
        // `data`).
        SafeTransferLib.forceApprove(token, creditManager, forAmount);
        IGearboxCreditFacadeV3(facade).botMulticall(creditAccount, calls);
        SafeTransferLib.forceApprove(token, creditManager, 0);
        // The manager pulls exactly `forAmount`, so on an honest venue this sweeps
        // nothing; measured against the pre-delivery floor all the same (F27/C-3).
        PreFundGuard.sweepSurplus(token, onBehalfOf, floor);
    }

    /// @inheritdoc IFundingSource
    /// @dev Funded by the fill's OWN delivery — a wallet/allowance read would preview a
    ///      self-funding order as short.
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
