// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {PermitHelper} from "@lib/PermitHelper.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

import {ITellerPool, ITellerV2} from "./interfaces/ITeller.sol";

// ════════════════════════════════════════════════════════════════════════════
//  Teller V2 modules — value-in only
//
//  Teller's borrow (forwarder ERC-2771 attribution + oracle firewall +
//  attestation) and pool withdraw (per-owner cooldown) cannot be expressed as
//  atomic on-behalf module ops, so this package ships only the two
//  permissionless value-in legs: pool supply and loan repay. Both are MAKE
//  modules (gated by `msg.sender == settlement`); there is no taker module.
// ════════════════════════════════════════════════════════════════════════════

// ──────────────────── Teller pool deposit maker module ────────────────────
//
// Pulls `asset` (the pool's principal token) via Permit3 and supplies it into the
// V2/V3 ERC-4626 `pool` crediting the user.
// `data = abi.encode(pool, asset[, deadline, v, r, s])` — base = 64.
//
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
    }
}

// ──────────────────── Teller repay maker module ────────────────────
//
// Repays the maker's loan (permissionless on Teller). Pulls the maker-signed
// `amount` of the principal token and calls `repayLoanFull` (full close) or
// `repayLoan(bidId, amount)` (partial). Any unspent buffer is swept back to the
// maker. `full` is a maker-signed flag in `data`.
//
// `nonReentrant` guards weird-token transfer hooks.
// `data = abi.encode(tellerV2, principalToken, bidId, full[, deadline, v, r, s])`
//   — base = 128.
//
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

        if (amount > 0) {
            permit3.transferFrom(onBehalfOf, address(this), principalToken, uint160(amount));
            SafeTransferLib.forceApprove(principalToken, tellerV2, amount);
            if (full) {
                ITellerV2(tellerV2).repayLoanFull(bidId);
            } else {
                ITellerV2(tellerV2).repayLoan(bidId, amount);
            }
            SafeTransferLib.forceApprove(principalToken, tellerV2, 0);
        }

        // Sweep the unused buffer (repayLoanFull pulls only what is owed).
        uint256 residual = IERC20(principalToken).balanceOf(address(this));
        if (residual != 0) SafeTransferLib.safeTransfer(principalToken, onBehalfOf, residual);

        _locked = 1;
    }
}
