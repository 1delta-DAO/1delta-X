// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";
import {IFundingSource} from "@core/interfaces/IFundingSource.sol";

import {ICErc20, ICEther} from "./interfaces/ICompoundV2.sol";
import {IWETH} from "./CompoundV2NativeModules.sol";

// ──────────────── Compound v2 PRE-FUNDED one-sided modules ────────────────
//
// "Deposit whatever the conversion delivered" and "repay whatever the conversion
// delivered", with ZERO receive-side approvals: the maker signs the converted
// output leg with `recipient = module` and a pre-funded `MAKE` item whose leg-reference
// descriptor points at it. The core sizes `forAmount` to exactly what the fill
// delivered here ({Base._forSlice} → {Pricing.outputAt}), auction decay included,
// and this module mints/repays it from its own balance. The maker's only grants
// are the ones they had anyway: the ERC20+Permit3 approval on the asset they are
// CONVERTING FROM (the input leg), and NO taker allowance (Settlement dispatches the `MAKE` directly). The received
// asset needs nothing — it never transits the maker's wallet, and both venue ops
// are permissionless value-in (`mint` funded by the caller with the receipt
// forwarded; `repayBorrowBehalf` is Compound v2's one native on-behalf call).
//
// {CompoundV2PreFundModule} serves ERC20 underlyings; the cEther market's value-in
// calls take native ETH via `msg.value`, so its pre-funded twin is a separate
// contract below ({CompoundV2NativePreFundModule}): the delivered leg is WETH, and
// the module unwraps EXACTLY `forAmount` inside the item for the payable call.
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
// `data = abi.encode(forDesc, cToken, underlying)` for both modules — descriptor
// word FIRST (forDesc@0), cToken@32, underlying@64; 96 bytes total.
//
// Compound forks return a `uint` error code (0 == success); every call's code is
// checked and reverts with `CompoundV2Error(code)` on failure.


/// @notice ONE contract for every pre-funded one-sided op on Compound v2.
/// @dev    Replaces {CompoundV2PreFundDepositModule}, {CompoundV2PreFundRepayModule}. `Op` rides in
///         descriptor bits [244,252) — see {PreFundModuleBase._preFundOp} for why the
///         discriminator lives in the word the maker already signs rather than in a
///         new `data` field. Merging is safe because the op is INSIDE `data`, and `data` is
///         inside the maker's ORDER signature: an item signed for one op cannot be
///         executed as another. Each op keeps its own decode, so the
///         per-op `data` layouts are unchanged apart from the descriptor bits.
contract CompoundV2PreFundModule is PreFundModuleBase, IMakerModule, IFundingSource {
    enum Op {
        Deposit,
        Repay
    }

    /// @dev The descriptor named an op this module does not implement.
    error BadOp(uint256 op);

    error CompoundV2Error(uint256 code);

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
        if (op == uint256(Op.Deposit)) {
        _mintAndForward(onBehalfOf, forAmount, data);
        } else if (op == uint256(Op.Repay)) {
        // Its own frame: the fork profile can compile without the optimizer, where
        // the decode plus the repay-and-sweep logic overflows this function's stack.
        _repayAndSweep(onBehalfOf, forAmount, data);
        } else {
            revert BadOp(op);
        }
    }


    /// @dev Its own frame: the fork profile can compile without the optimizer,
    ///      where the decode plus the mint-measure-forward sequence is too much
    ///      for one stack.
    function _mintAndForward(address onBehalfOf, uint256 forAmount, bytes calldata data) private {
        (, address cToken, address underlying) = abi.decode(data, (uint256, address, address));
        // cToken balance held BEFORE the mint — forward only THIS MINT's receipt.
        uint256 floor = IERC20(cToken).balanceOf(address(this));
        // Scoped approve + CLEAR: `cToken` is decoded from order data on a shared
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
        uint256 uFloor = PreFundGuard.floorOf(data, underlying, forAmount);
        SafeTransferLib.forceApprove(underlying, cToken, forAmount);
        uint256 err = ICErc20(cToken).mint(forAmount);
        if (err != 0) revert CompoundV2Error(err);
        SafeTransferLib.forceApprove(underlying, cToken, 0);
        PreFundGuard.sweepSurplus(underlying, onBehalfOf, uFloor);
        uint256 bal = IERC20(cToken).balanceOf(address(this));
        if (bal > floor) SafeTransferLib.safeTransfer(cToken, onBehalfOf, bal - floor);
    }

    function _repayAndSweep(address onBehalfOf, uint256 forAmount, bytes calldata data) private {
        (, address cToken, address underlying) = abi.decode(data, (uint256, address, address));
        // The pre-existing floor: this fill's delivery is already on the balance,
        // so `entry - forAmount` is what was here before. A funding leg not
        // addressed to THIS module in THIS token underflows here — the mis-pairing
        // fails closed. Sound because `msg.sender == settlement` pins `forAmount` to
        // the core; with a caller-chosen `forAmount` the same subtraction proves
        // nothing (F27/C-1, C-4).
        uint256 floor = PreFundGuard.floorOf(data, underlying, forAmount);
        uint256 toRepay;
        {
            // Cap at the LIVE debt — accrued to this block, the exact figure the
            // repay settles against ({CompoundV2RepayModule._pullAndRepay}).
            uint256 debt = ICErc20(cToken).borrowBalanceCurrent(onBehalfOf);
            toRepay = forAmount < debt ? forAmount : debt;
        }
        if (toRepay != 0) {
            // Scoped approve + CLEAR — `cToken` is maker-data-choosable on a
            // shared singleton (F25 / lead A-3).
            SafeTransferLib.forceApprove(underlying, cToken, toRepay);
            uint256 err = ICErc20(cToken).repayBorrowBehalf(onBehalfOf, toRepay);
            if (err != 0) revert CompoundV2Error(err);
            SafeTransferLib.forceApprove(underlying, cToken, 0);
        }
        // The delivered surplus belongs to the maker, not to this singleton. Sweep
        // exactly this fill's excess (`forAmount − toRepay`), never the whole
        // balance — a wei of another fill's dust may legitimately sit here.
        PreFundGuard.sweepSurplus(underlying, onBehalfOf, floor);
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

// ──────────────── Compound v2 NATIVE (cEther) PRE-FUNDED one-sided module ────────────────
//
// The pre-funded twin of {CompoundV2NativeDepositModule} / {CompoundV2NativeRepayModule}
// (review 2026-10-18 M-5): those PULL WETH from the maker through a Permit3 token
// allowance, so a zero-capital "sell X, deposit/repay ETH" order needed the maker
// to approve the module for a token they never held. Here the maker signs the WETH
// output leg with `recipient = module` and a pre-funded `MAKE` item whose
// leg-reference descriptor points at it; the core sizes `forAmount` to exactly
// that delivery (`ctx.outs`), and the module unwraps it and calls cEther.
//
//    Deposit → weth.withdraw(forAmount) → cEther.mint{value}      (cTokens forwarded)
//    Repay   → weth.withdraw(min(forAmount, debt)) → cEther.repayBorrowBehalf{value}
//              (the unused WETH is swept back to the maker, still WRAPPED)
//
// WHY THE UNWRAP IS EXACT, AND NOT A BALANCE SWEEP. Two makers' WETH deliveries can
// sit on this singleton at once on the netted path (`matchSettle` delivers, then
// runs items, in a solver-chosen order). The module therefore unwraps the core-sized
// `forAmount` (or less) and never "whatever WETH is here" — the {NativeUnwrapModule}
// rule. And since the size comes from the delivery LEDGER rather than from a
// pro-rated `item.amount`, the leg-vs-item rounding asymmetry that module documents
// (SELL legs ceil per fill, items floor cumulatively) does not arise: what was
// delivered is what is unwrapped.
//
// `weth` is an IMMUTABLE, so `withdraw(x)` credits exactly `x` native; the descriptor's
// funding token must equal it ({PreFundGuard.floorOf} reverts `FundingTokenMismatch`
// otherwise). `cEther` is maker-named: a fake one can swallow the ETH it is handed,
// but that is this fill's own delivery — nothing below the floors is reachable.
// Native and WETH sweeps are both floored at their pre-call balances (F19 / F26/2a),
// and the ETH side wraps before it leaves, so the maker never receives raw native.
//
// Both ops are permissionless on-behalf at the venue (`mint` is funded by the
// caller with the receipt forwarded; `repayBorrowBehalf` is Compound v2's native
// on-behalf call): the receive side needs NO grant of any kind.
//
// `data = abi.encode(forDesc, cEther)` — descriptor word FIRST (forDesc@0, op in bits
// [244,252), funding token = `weth` in bits [16,176)), cEther@32; 64 bytes.

/// @notice The pre-funded cEther deposit / repay ops, funded by a delivered WETH leg.
contract CompoundV2NativePreFundModule is PreFundModuleBase, IMakerModule, IFundingSource {
    enum Op {
        Deposit,
        Repay
    }

    /// @dev The wrapped native token the funding leg must be denominated in.
    IWETH public immutable weth;

    /// @dev The descriptor named an op this module does not implement.
    error BadOp(uint256 op);

    constructor(address _permit3, address _settlement, address _weth) PreFundModuleBase(_permit3, _settlement) {
        weth = IWETH(_weth);
    }

    /// @param onBehalfOf the maker — whose position this fill acts on.
    /// @param forAmount  this fill's delivered WETH leg, core-sized; unwrapped and
    ///                   spent from this module's own balance.
    function makeOnBehalf(address onBehalfOf, uint256 forAmount, bytes calldata data) external override {
        _gatePreFundMake(data);
        // A dust slice can floor the funding leg to zero; skip — it accumulates
        // exactly across fills.
        if (forAmount == 0) return;
        uint256 op = _preFundOp(data);
        if (op == uint256(Op.Deposit)) {
            _mintAndForward(onBehalfOf, forAmount, data);
        } else if (op == uint256(Op.Repay)) {
            _repayAndSweep(onBehalfOf, forAmount, data);
        } else {
            revert BadOp(op);
        }
    }

    /// @dev Unwrap exactly the delivery, mint cEther to THIS module (no `mintBehalf`),
    ///      forward only this mint's receipt.
    function _mintAndForward(address onBehalfOf, uint256 forAmount, bytes calldata data) private {
        (, address cEther) = abi.decode(data, (uint256, address));
        // The delivery must have landed HERE, in WETH — the descriptor's token is
        // pinned to the immutable `weth`, so a leg in any other token reverts
        // `FundingTokenMismatch`, and one not addressed here underflows. KEEP the
        // floor: it is what bounds the sweep below to this fill's own WETH.
        uint256 wFloor = PreFundGuard.floorOf(data, address(weth), forAmount);
        uint256 cFloor = IERC20(cEther).balanceOf(address(this));
        uint256 ethFloor = address(this).balance;
        weth.withdraw(forAmount);
        ICEther(cEther).mint{value: forAmount}(); // reverts on error
        uint256 cBal = IERC20(cEther).balanceOf(address(this));
        if (cBal > cFloor) SafeTransferLib.safeTransfer(cEther, onBehalfOf, cBal - cFloor);
        _sweepNativeAsWeth(onBehalfOf, ethFloor);
        PreFundGuard.sweepSurplus(address(weth), onBehalfOf, wFloor);
    }

    /// @dev Repay `min(forAmount, live debt)` in native; the unused delivery goes
    ///      back to the maker as WETH.
    function _repayAndSweep(address onBehalfOf, uint256 forAmount, bytes calldata data) private {
        (, address cEther) = abi.decode(data, (uint256, address));
        uint256 wFloor = PreFundGuard.floorOf(data, address(weth), forAmount);
        // Taken BEFORE the venue call, and load-bearing: a zero live debt skips the
        // repay, and an unfloored sweep would then pay out every wei of ETH resident
        // on this singleton (F26/2a, the {CompoundV2NativeRepayModule} note).
        uint256 ethFloor = address(this).balance;
        uint256 toRepay;
        {
            // cEther reverts on an over-send, so the cap is mandatory, not a nicety.
            uint256 debt = ICEther(cEther).borrowBalanceCurrent(onBehalfOf);
            toRepay = forAmount < debt ? forAmount : debt;
        }
        if (toRepay != 0) {
            weth.withdraw(toRepay);
            ICEther(cEther).repayBorrowBehalf{value: toRepay}(onBehalfOf); // reverts on error
        }
        _sweepNativeAsWeth(onBehalfOf, ethFloor);
        // `forAmount − toRepay` of the delivery, still wrapped — measured against the
        // pre-delivery floor, never sized from the venue's behaviour (F27/C-3).
        PreFundGuard.sweepSurplus(address(weth), onBehalfOf, wFloor);
    }

    /// @dev Wrap and return the native THIS CALL left above `floor` (none on an
    ///      honest cEther). Wrapping keeps the sweep reentrancy-free and the maker
    ///      on the ERC20 side; see {CompoundV2NativeDepositModule._sweepNativeAsWeth}
    ///      for why the floor is not optional.
    function _sweepNativeAsWeth(address to, uint256 floor) private {
        uint256 bal = address(this).balance;
        if (bal > floor) {
            unchecked {
                uint256 delta = bal - floor;
                weth.deposit{value: delta}();
                SafeTransferLib.safeTransfer(address(weth), to, delta);
            }
        }
    }

    /// @inheritdoc IFundingSource
    /// @dev Funded by the fill's OWN delivery — a wallet/allowance read would
    ///      preview a self-funding order as short.
    function fundingSource(address, bytes calldata)
        external
        view
        override
        returns (address asset, uint256 available)
    {
        asset = address(weth);
        available = type(uint256).max;
    }

    receive() external payable {} // ETH from weth.withdraw — must stay empty (WETH9 pays via `transfer`)
}
