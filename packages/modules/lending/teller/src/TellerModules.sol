// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {PermitHelper} from "@lib/PermitHelper.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

import {ITellerPool, ITellerV2, TellerPayment} from "./interfaces/ITeller.sol";

// ════════════════════════════════════════════════════════════════════════════
//  Teller V2 modules — value-in only
//
//  Teller's borrow (forwarder ERC-2771 attribution + oracle firewall +
//  attestation) and pool withdraw (per-owner cooldown) cannot be expressed as
//  atomic on-behalf module ops, so this package ships only the two value-in
//  legs: pool supply (oracle-firewalled — the module must be registered, see the
//  deposit module below) and loan repay (permissionless). Both are MAKE modules
//  (gated by `msg.sender == settlement`); there is no taker module.
// ════════════════════════════════════════════════════════════════════════════

/// @title TellerRepayLib
/// @notice The one repay dispatch both Teller repay modules share.
/// @dev THE LIVE-DEBT CLAMP LIVES HERE, NOT IN THE VENUE (2026-09-30 audit,
///      L-CMT-1). Both modules used to hand `repayLoan(bidId, X)` the WHOLE amount
///      they held and rely on TellerV2 to take only what is owed, so the floor sweep
///      afterwards would return the rest to the maker. The deployed TellerV2 does not
///      do that: it transfers the uncapped `X` to the lender and marks the loan PAID
///      (see {ITellerV2.repayLoan}), so the "unused buffer is swept back" promise
///      paid the maker's surplus to the lender instead. Every sibling clamps at the
///      live debt before calling its venue (Comet `min(forAmount, borrowBalanceOf)`,
///      Morpho's full-vs-partial branch); Teller was the N-th sibling that did not.
///
///      Routing: `full`, or `amount ≥ owed` → `repayLoanFull`, which pulls EXACTLY
///      the live owed amount, so the module's delta sweep returns `amount − owed`.
///      Otherwise → `repayLoan(bidId, amount)`, which can no longer overshoot.
///      The approval is scoped to `amount` and cleared after: `tellerV2` is
///      maker-data-choosable on a shared singleton (F25 / lead A-3), and a
///      `full` close whose `amount` is below the owed figure fails closed on that
///      allowance rather than reaching for any other balance.
library TellerRepayLib {
    function repay(address tellerV2, address token, uint256 bidId, bool full, uint256 amount) internal {
        SafeTransferLib.forceApprove(token, tellerV2, amount);
        if (full || amount >= _owed(tellerV2, bidId)) {
            ITellerV2(tellerV2).repayLoanFull(bidId);
        } else {
            ITellerV2(tellerV2).repayLoan(bidId, amount);
        }
        SafeTransferLib.forceApprove(token, tellerV2, 0);
    }

    function _owed(address tellerV2, uint256 bidId) private view returns (uint256) {
        TellerPayment memory p = ITellerV2(tellerV2).calculateAmountOwed(bidId, block.timestamp);
        return p.principal + p.interest;
    }
}

// ──────────────────── Teller pool deposit maker module ────────────────────
//
// Pulls `asset` (the pool's principal token) via Permit3 and supplies it into the
// V2/V3 ERC-4626 `pool` crediting the user.
// ⚠ The pool's `deposit` is Hypernative-firewalled (`onlyOracleApprovedAllowEOA`):
// this module's address must be registered with the chain's SmartCommitmentForwarder
// oracle (`oracleRegister(module)`, public) and past its threshold, or every deposit
// reverts "Account not registered". A per-chain deploy step — see the README.
// `data = abi.encode(pool, asset[, deadline, v, r, s])` — base = 64.
//
// EIP-2612 permit block @64 (+ signedValue@192): `(deadline, v, r, s)` = 128 bytes, plus an OPTIONAL
// trailing `signedValue` word. Without it the signature commits to THIS fill's slice
// and verifies only on a full fill; sign `signedValue = item total` for partial fills
// ({PermitHelper}, audit 2026-09-30 L-AAVE-2).
contract TellerPoolDepositModule is IMakerModule {
    IPermit3 public immutable permit3;
    address public immutable settlement;

    error NotSettlement();

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();

        (address pool, address asset) = abi.decode(data, (address, address));
        PermitHelper.replayIfPresent(data, 64, asset, onBehalfOf, address(permit3), amount);

        permit3.transferFrom(onBehalfOf, address(this), asset, uint160(amount));
        SafeTransferLib.forceApprove(asset, pool, amount);
        ITellerPool(pool).deposit(amount, onBehalfOf);
        // Clear the scoped grant: `pool` is decoded from the order's `data` on a
        // SHARED singleton, so it is attacker-choosable — anyone can author an
        // order naming themselves as maker. A target that consumes less than
        // approved would leave a standing third-party claim on any FUTURE balance
        // of this module, which is what turns a later stranded-balance bug into a
        // theft. {SafeTransferLib.ensureApproval} forbids this shape. F25 / A-3.
        SafeTransferLib.forceApprove(asset, pool, 0);
    }
}

// ──────────────────── Teller repay maker module ────────────────────
//
// Repays the maker's loan (permissionless on Teller). Pulls the maker-signed
// `amount` of the principal token and calls `repayLoanFull` (full close — also
// whenever `amount` covers the LIVE owed amount) or `repayLoan(bidId, amount)`
// (a partial strictly below it). Any unspent buffer is swept back to the maker.
// `full` is a maker-signed flag in `data`: `true` REQUIRES a close (reverts when
// `amount` is short of the owed figure); `false` repays up to `amount` and closes
// the loan if `amount` covers it. See {TellerRepayLib} for why the module, not
// the venue, clamps.
//
// `nonReentrant` guards weird-token transfer hooks.
// `data = abi.encode(tellerV2, principalToken, bidId, full[, deadline, v, r, s])`
//   — base = 128.
//
// EIP-2612 permit block @128 (+ signedValue@256): `(deadline, v, r, s)` = 128 bytes, plus an OPTIONAL
// trailing `signedValue` word. Without it the signature commits to THIS fill's slice
// and verifies only on a full fill; sign `signedValue = item total` for partial fills
// ({PermitHelper}, audit 2026-09-30 L-AAVE-2).
contract TellerRepayModule is IMakerModule {
    IPermit3 public immutable permit3;
    address public immutable settlement;

    uint256 private _locked = 1;

    error Reentrancy();
    error NotSettlement();

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();
        if (_locked != 1) revert Reentrancy();
        _locked = 2;

        (address tellerV2, address principalToken, uint256 bidId, bool full) =
            abi.decode(data, (address, address, uint256, bool));
        PermitHelper.replayIfPresent(data, 128, principalToken, onBehalfOf, address(permit3), amount);

        // Balance held BEFORE the pull. Sweeping `balanceOf(this)` outright would pay
        // out anything already stranded at this shared module address, and anyone can
        // be the maker of a one-unit order against it — so a stray balance would be
        // claimable by whoever fills next. The invariant is "the module ends where it
        // started", not "ends empty" (F19; {DustHandler.disposeResidual}'s floor).
        uint256 floor = IERC20(principalToken).balanceOf(address(this));
        if (amount > 0) {
            permit3.transferFrom(onBehalfOf, address(this), principalToken, uint160(amount));
            // Clamped at the LIVE debt — the venue does not clamp (L-CMT-1).
            TellerRepayLib.repay(tellerV2, principalToken, bidId, full, amount);
        }

        // Sweep the unused buffer (`repayLoanFull` pulls only what is owed, and an
        // `amount` at or above the owed figure is routed there) — the DELTA this
        // call produced, never the pre-existing `floor`.
        uint256 bal = IERC20(principalToken).balanceOf(address(this));
        if (bal > floor) SafeTransferLib.safeTransfer(principalToken, onBehalfOf, bal - floor);

        _locked = 1;
    }
}
