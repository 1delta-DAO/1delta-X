// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";

import {IMorphoBlue, MarketParams, Position, Id, MarketParamsLib} from "./interfaces/IMorphoBlue.sol";

// ──────────────────── Morpho Blue supply-collateral maker module ────────────────────
//
// Single-op module: pulls `collateralToken` from the user via Permit3, then
// supplies it as collateral into the market on the user's behalf. Morpho's
// `supplyCollateral` has no shares variant and never accrues interest, so the
// pulled amount maps 1:1 to deposited collateral. `data = abi.encode(MarketParams)`.
//
contract MorphoBlueSupplyCollateralModule is IMakerModule {
    IPermit3 public immutable permit3;
    IMorphoBlue public immutable morpho;

    constructor(address _permit3, address _morpho) {
        permit3 = IPermit3(_permit3);
        morpho = IMorphoBlue(_morpho);
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        MarketParams memory marketParams = abi.decode(data, (MarketParams));

        permit3.transferFrom(onBehalfOf, address(this), marketParams.collateralToken, uint160(amount));
        IERC20(marketParams.collateralToken).approve(address(morpho), amount);
        morpho.supplyCollateral(marketParams, amount, onBehalfOf, "");
    }
}

// ──────────────────── Morpho Blue repay maker module ────────────────────
//
// Closes the user's borrow in a market, handling interest-accrual over-repay
// cleanly. Unlike Aave, Morpho's `repay(assets=…)` does NOT cap at the live
// debt — overshooting by assets reverts (share underflow). So a full close must
// repay by *shares*:
//
//   1. Pull `amount` (a user-signed buffered value) from the user via Permit3.
//   2. Read the live `borrowShares` and `repay(shares = borrowShares)`. Morpho
//      accrues interest, converts shares→assets (rounding up) and pulls exactly
//      that from this contract — never more than the buffer.
//   3. Any residual buffer left here is swept back to `onBehalfOf` — the refund
//      destination is the function argument, not a field of `data`, closing the
//      "anyone can redirect the dust" vector without a sender gate.
//
// `nonReentrant` guards against weird-token transfer hooks.
// `data = abi.encode(MarketParams)`.
//
contract MorphoBlueRepayModule is IMakerModule {
    using MarketParamsLib for MarketParams;

    IPermit3 public immutable permit3;
    IMorphoBlue public immutable morpho;

    uint256 private _locked = 1;

    error Reentrancy();

    constructor(address _permit3, address _morpho) {
        permit3 = IPermit3(_permit3);
        morpho = IMorphoBlue(_morpho);
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;

        MarketParams memory marketParams = abi.decode(data, (MarketParams));
        address loanToken = marketParams.loanToken;

        permit3.transferFrom(onBehalfOf, address(this), loanToken, uint160(amount));
        IERC20(loanToken).approve(address(morpho), amount);

        // Repay the entire debt by shares. Morpho accrues first, so reading the
        // shares here and repaying them closes the position exactly; the buffered
        // pull covers the assets Morpho rounds up to.
        Id id = marketParams.id();
        uint256 borrowShares = morpho.position(id, onBehalfOf).borrowShares;
        if (borrowShares > 0) {
            morpho.repay(marketParams, 0, borrowShares, onBehalfOf, "");
        }

        // Sweep residual (over-repay buffer) back to the user. `balanceOf` avoids
        // depending on Morpho's return value.
        uint256 residual = IERC20(loanToken).balanceOf(address(this));
        if (residual > 0) IERC20(loanToken).transfer(onBehalfOf, residual);

        _locked = 1;
    }
}

// ──────────────────── Morpho Blue withdraw-collateral taker module ────────────────────
//
// Single-op taker module. Permit3 decrements the taker allowance on
// `keccak256(data)`, then invokes `takeOnBehalf` here. Morpho collateral is not
// tokenised, so — unlike the Aave withdraw module — there is NO receipt token to
// pull: the module simply calls `withdrawCollateral`, which Morpho authorises via
// the maker's prior `setAuthorization(module, true)` and sends straight to
// `receiver`.
//
// `data = abi.encode(MarketParams)`.
//
contract MorphoBlueWithdrawCollateralModule is ITakerModule {
    IPermit3 public immutable permit3;
    IMorphoBlue public immutable morpho;

    error OnlyPermit3();

    constructor(address _permit3, address _morpho) {
        permit3 = IPermit3(_permit3);
        morpho = IMorphoBlue(_morpho);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        MarketParams memory marketParams = abi.decode(data, (MarketParams));
        morpho.withdrawCollateral(marketParams, amount, onBehalfOf, receiver);
    }
}

// ──────────────────── Morpho Blue borrow taker module ────────────────────
//
// Single-op taker module. Issues a borrow on behalf of the user and Morpho
// sends the loan token straight to `receiver` — no intermediate forwarding.
// The user must have called `morpho.setAuthorization(module, true)` so Morpho
// permits the module to incur debt on their account.
//
// `data = abi.encode(MarketParams)`.
//
contract MorphoBlueBorrowModule is ITakerModule {
    IPermit3 public immutable permit3;
    IMorphoBlue public immutable morpho;

    error OnlyPermit3();

    constructor(address _permit3, address _morpho) {
        permit3 = IPermit3(_permit3);
        morpho = IMorphoBlue(_morpho);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        MarketParams memory marketParams = abi.decode(data, (MarketParams));
        // Morpho delivers `amount` of loanToken directly to `receiver`.
        morpho.borrow(marketParams, amount, 0, onBehalfOf, receiver);
    }
}
