// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {IFundingSource} from "@core/interfaces/IFundingSource.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";

import {IEulerVault} from "./interfaces/IEulerV2.sol";
import {EulerSubAccount} from "./EulerV2Modules.sol";

// ──────────────── Euler V2 PRE-FUNDED one-sided modules ────────────────
//
// "Deposit whatever the conversion delivered" and "repay whatever the conversion
// delivered", with ZERO receive-side approvals: the maker signs the converted
// output leg with `recipient = module` and a pre-funded `MAKE` item whose
// leg-reference descriptor points at it. The core sizes `forAmount` to exactly
// what the fill delivered here ({Base._forSlice} → the delivery ledger), auction
// decay included, and this module deposits/repays it from its own balance.
//
//  Why Euler needed this (review 2026-10-18, M-1)
//  ──────────────────────────────────────────────
//  {EulerV2DepositModule} and {EulerV2RepayModule} are PULL makers: they draw the
//  delivered token back out of the maker's wallet through a Permit3 allowance to
//  the module. On the zero-capital path that is the late sink of the two acyclic
//  position shapes —
//
//      open:  borrow TAKE (early, pays the input) → swap → DEPOSIT (late)
//      close: withdraw TAKE (early, pays the input) → swap → REPAY (late)
//
//  — so every such order needed the maker to approve, through Permit3, a token
//  they never held. Fourteen other venues fill those shapes with no receive-side
//  grant at all; this is the Euler one.
//
//  WHAT THE MAKER GRANTS: NOTHING NEW. Value flowing INTO an EVK vault is
//  authenticated as the CALLER (called directly, the vault's `callThroughEVC`
//  routes so the authenticated account is `msg.sender`, i.e. this module), and
//  `deposit` / `repay` credit an arbitrary `receiver`. So — exactly like the two
//  pull makers — these ops need no EVC operator status, and unlike them they need
//  no Permit3 token allowance either. This contract is deliberately NOT folded into
//  {EulerV2OperatorModule}: that address is the maker's unscoped
//  `setAccountOperator` grant, and the merge rule is "group by the standing grant
//  a module consumes". This one consumes none, so it stays out of the redeploy
//  unit whose fixes would force a re-grant.
//
//  Why these ride the MAKE seam: these ops move NOTHING out of the position. See
//  {AaveV3PreFundModule} for the full argument; in short, Settlement dispatches
//  `MAKE` DIRECTLY, so the caller pin is `msg.sender` (asserted by the EVM, no
//  permissionless hub in front, F27/C-1 does not exist here), no taker allowance is
//  granted or spent, and `item.amount` is unread so F27/C-2 cannot be expressed.
//
//  LEG-REFERENCE ONLY, enforced ({_gatePreFundMake}). A LITERAL descriptor would
//  instruct amounts this module has no delivery for, and a BALANCE one reads the
//  MAKER's wallet while this module funds from its own.
//
//  ⚠ THE VAULT IS MAKER-NAMED. EVK vaults are created permissionlessly and the
//  vault rides in `data`, so from this contract's point of view it is
//  attacker-choosable. Three consequences, all handled below:
//    • the spent asset is the VAULT's `asset()`, and {PreFundGuard.floorOf} binds it
//      to the descriptor's signed funding token — a vault whose asset is not the
//      delivered leg's token reverts `FundingTokenMismatch`;
//    • every approval is SCOPED (exactly `forAmount` / `toRepay`) and CLEARED
//      (F25 / A-3), never a standing max;
//    • the remainder is MEASURED against the pre-delivery floor and swept to the
//      maker — never sized from the vault's return value (F27/C-3), never from the
//      pre-call clamp (F27/M-1). A vault that pulls less than instructed returns the
//      rest to the maker; one that reports a fake number changes nothing.
//    ⚠ FoT: {PreFundGuard.floorOf} documents why a fee-on-transfer vault asset can
//      fail closed (or draw wei-scale residue) on this maker-named-vault venue.
//      Accepted and documented; the core stays asset-general.
//
//  NETTED PATH. On `matchSettle` another order's delivery can be parked on this
//  singleton between its DELIVER and its ITEM. The floor is taken BEFORE the vault
//  call and the sweep returns only what lies above it, so an item spends exactly
//  its own delivery and leaves a sibling's untouched. An item scheduled before its
//  own DELIVER finds an empty ledger and the CORE fails it closed
//  (`Base.ForLegInvalid`). Pinned by `test/netted/NettedPreFund.t.sol`.

/// @notice ONE contract for both pre-funded one-sided ops on Euler v2.
/// @dev    `Op` rides in descriptor bits [244,252) — see {PreFundModuleBase._preFundOp}.
///         Both ops share ONE layout:
///
///           `abi.encode(forDesc, vault[, subId])`
///
///         `subId` is OPTIONAL (< 256, absent ⇒ 0 ⇒ the primary account): the op
///         then credits / repays the maker's EVC SUB-ACCOUNT `maker ^ subId` — the
///         same trailing-word convention as {EulerV2DepositModule} /
///         {EulerV2RepayModule}, so a builder switches funding shape by swapping the
///         module and prefixing the descriptor, nothing else. The sweep always goes
///         to the maker's OWN wallet: a sub-account address holds no keys and cannot
///         move an ERC-20 it is sent.
// Byte map — forDesc@0, vault@32 (base = 64); subId@64 optional.
contract EulerV2PreFundModule is PreFundModuleBase, IMakerModule, IFundingSource {
    enum Op {
        Deposit, // 0 — supply the delivery as a lend balance (collateral) in `vault`
        Repay //    1 — repay the maker's `vault` debt, clamped to the live debt
    }

    /// @dev The descriptor named an op this module does not implement.
    error BadOp(uint256 op);

    constructor(address _permit3, address _settlement) PreFundModuleBase(_permit3, _settlement) {}

    /// @param onBehalfOf the maker — whose (sub-)account is credited or repaid.
    /// @param forAmount  this fill's delivered output leg, core-sized from the pre-fund
    ///                   descriptor; spent from this module's own balance. It is the
    ///                   item's ONLY amount — `item.amount` is not read on this seam.
    function makeOnBehalf(address onBehalfOf, uint256 forAmount, bytes calldata data) external override {
        _gatePreFundMake(data);
        // A dust slice can floor the funding leg to zero; skip — it accumulates
        // exactly across fills.
        if (forAmount == 0) return;
        uint256 op = _preFundOp(data);
        if (op == uint256(Op.Deposit)) {
            _deposit(onBehalfOf, forAmount, data);
        } else if (op == uint256(Op.Repay)) {
            _repay(onBehalfOf, forAmount, data);
        } else {
            revert BadOp(op);
        }
    }

    function _deposit(address onBehalfOf, uint256 forAmount, bytes calldata data) private {
        (, address vault) = abi.decode(data, (uint256, address));
        // Validated before any balance moves: a bad `subId` reverts here.
        address account = EulerSubAccount.account(onBehalfOf, data, 64);
        address asset = IEulerVault(vault).asset();
        // The delivery must have landed HERE, in THIS token — the core binds the
        // funding leg's RECIPIENT (bit 253) and CONSUMES it ({Base.ForLegInvalid}); the
        // token binding is {PreFundGuard.floorOf}'s. Underflows if it did not; sound
        // because `msg.sender == settlement` pins `forAmount` to the core. The floor is
        // KEPT for the sweep below (F28: every pre-fund deposit sweeps).
        uint256 floor = PreFundGuard.floorOf(data, asset, forAmount);
        // Scoped approve + CLEAR: `vault` is maker-named on a shared singleton.
        SafeTransferLib.forceApprove(asset, vault, forAmount);
        IEulerVault(vault).deposit(forAmount, account);
        SafeTransferLib.forceApprove(asset, vault, 0);
        // Anything the vault did not take belongs to the maker — MEASURED.
        PreFundGuard.sweepSurplus(asset, onBehalfOf, floor);
    }

    /// @dev Over-delivery (the auction cleared above the live debt, or the maker
    ///      padded for interest) is swept to the maker: the solver already paid it.
    function _repay(address onBehalfOf, uint256 forAmount, bytes calldata data) private {
        (, address vault) = abi.decode(data, (uint256, address));
        address account = EulerSubAccount.account(onBehalfOf, data, 64);
        address asset = IEulerVault(vault).asset();
        // The pre-existing floor — fails closed on a funding leg not addressed to THIS
        // module in THIS token, and bounds the sweep below.
        uint256 floor = PreFundGuard.floorOf(data, asset, forAmount);
        // LOAD-BEARING CLAMP: EVK `repay` does NOT cap at the debt — any finite amount
        // above it reverts `E_RepayTooMuch`. `debtOf` is the same `toAssetsUp` figure
        // `repay` checks in the same block, so the clamp is exact. A zero debt (the
        // position was closed under us) repays nothing and sweeps the whole delivery
        // back — never a revert that strands the rest of the fill.
        uint256 debt = IEulerVault(vault).debtOf(account);
        uint256 toRepay = forAmount < debt ? forAmount : debt;
        if (toRepay != 0) {
            SafeTransferLib.forceApprove(asset, vault, toRepay);
            IEulerVault(vault).repay(toRepay, account);
            SafeTransferLib.forceApprove(asset, vault, 0);
        }
        // Everything above the floor is this fill's unconsumed remainder — MEASURED,
        // never sized from the clamp or the vault's return value (F27/C-3, M-1).
        PreFundGuard.sweepSurplus(asset, onBehalfOf, floor);
    }

    /// @inheritdoc IFundingSource
    /// @dev Funded by the fill's OWN delivery — a wallet/allowance read would preview
    ///      a self-funding order as short. Both ops spend the vault's asset.
    function fundingSource(address, bytes calldata data)
        external
        view
        override
        returns (address asset, uint256 available)
    {
        (, address vault) = abi.decode(data, (uint256, address));
        asset = IEulerVault(vault).asset();
        available = type(uint256).max;
    }
}
