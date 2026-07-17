// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

import {IMidnight, Market, Offer, MidnightIdLib} from "./interfaces/IMidnight.sol";

// ════════════════════════════════════════════════════════════════════════════
//  Morpho Midnight settlement modules
//
//  Midnight is a fixed-rate, fixed-maturity, ORDER-BOOK lending primitive — NOT
//  a Morpho Blue fork. There is no pool `supply`/`borrow`; lending and borrowing
//  happen through `take` against an off-chain-signed maker `Offer`. Position
//  lifecycle is `supplyCollateral` / `withdrawCollateral` / `repay` / `withdraw`
//  (credit redemption).
//
//  These adapters expose Midnight to `UniversalSettlement` in the same MAKE/TAKE
//  idiom as the Aave/Morpho/Venus packages:
//
//    MAKE (value-in, Permit3 token allowance gate):
//      • MidnightSupplyCollateralModule  supplyCollateral(onBehalf = maker)
//      • MidnightRepayModule             repay(onBehalf = maker)          (cap at debt)
//      • MidnightLendModule              take(offer.buy=false, taker = maker)  — buy credit units
//
//    TAKE (value-out, Permit3 taker allowance gate + Midnight `setIsAuthorized`):
//      • MidnightTakerModule             withdrawCollateral / withdraw     (combined, op-flag)
//      • MidnightBorrowModule            take(offer.buy=true,  taker = maker)  — sell debt units
//
//  Midnight structs embed a dynamic `CollateralParams[]` (and `Offer` embeds a
//  `Market` + dynamic `bytes`), so — unlike the static Morpho `MarketParams` —
//  the modules decode fully-typed tuples rather than fixed-offset blobs, and any
//  op/balance-mode flag rides INSIDE the tuple (there is no static base to append
//  a trailing raw word past). The taker ref is still `keccak256(data)`, so every
//  field the module decodes is part of the maker-approved bytes.
//
//  Authorization. The value-out legs act on the maker's position with the module
//  as `msg.sender`, so the maker must once call
//  `midnight.setIsAuthorized(module, true, maker)`. The Permit3 taker allowance
//  (keyed by `ref = keccak256(data)`) caps the per-fill amount. Midnight's
//  `take` gates ANY `taker != msg.sender` on that same authorization, so the
//  lend leg (a MAKE) ALSO requires the maker to authorize `MidnightLendModule` —
//  unusual for a value-in module, but intrinsic to routing the bought credit to
//  the maker rather than to the module.
// ════════════════════════════════════════════════════════════════════════════

// ──────────────────── Midnight supply-collateral maker module ────────────────────
//
// Single-op MAKE: pulls the indexed collateral token from the maker via Permit3
// and supplies it into the market on the maker's behalf. Supply is a benign
// inflow (it only credits collateral), so no protocol delegation is needed —
// the Permit3 token allowance is the whole gate.
//
// `data = abi.encode(Market market, uint256 collateralIndex)`.
//
contract MidnightSupplyCollateralModule is IMakerModule {
    IPermit3 public immutable permit3;
    IMidnight public immutable midnight;
    address public immutable settlement;

    error NotSettlement();

    constructor(address _permit3, address _midnight, address _settlement) {
        permit3 = IPermit3(_permit3);
        midnight = IMidnight(_midnight);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();

        (Market memory market, uint256 collateralIndex) = abi.decode(data, (Market, uint256));
        address collateralToken = market.collateralParams[collateralIndex].token;

        permit3.transferFrom(onBehalfOf, address(this), collateralToken, uint160(amount));
        // `midnight` is an immutable, trusted target → a standing max approval is
        // safe and skips the approve SSTORE on repeat supplies.
        SafeTransferLib.ensureApproval(collateralToken, address(midnight), amount);
        midnight.supplyCollateral(market, collateralIndex, amount, onBehalfOf);
    }
}

// ──────────────────── Midnight repay maker module ────────────────────
//
// Closes (part of) the maker's borrow with a pull-exact strategy. Midnight's
// `repay(units)` reverts on over-repay (it does not cap at the live debt), so we
// read the live `debt(id, maker)` and repay `min(amount, debt)` — 1 unit == 1
// loan token at repayment. Only the exact repaid amount is pulled, so nothing
// sits in the module for a caller to redirect and no dust sweep is needed. The
// Midnight-side `callback` is forced to zero, so Midnight pulls the loan token
// straight from this module (never a caller-supplied repay callback).
//
// Repay is a benign inflow (it only shrinks debt), so no delegation is needed.
// `nonReentrant` guards against weird-token transfer hooks.
// `data = abi.encode(Market market)`.
//
contract MidnightRepayModule is IMakerModule {
    IPermit3 public immutable permit3;
    IMidnight public immutable midnight;
    address public immutable settlement;

    uint256 private _locked = 1;

    error Reentrancy();
    error NotSettlement();

    constructor(address _permit3, address _midnight, address _settlement) {
        permit3 = IPermit3(_permit3);
        midnight = IMidnight(_midnight);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();
        if (_locked != 1) revert Reentrancy();
        _locked = 2;

        Market memory market = abi.decode(data, (Market));

        uint256 debtUnits = midnight.debt(MidnightIdLib.toId(market), onBehalfOf);
        uint256 toRepay = amount < debtUnits ? amount : debtUnits;
        if (toRepay > 0) {
            address loanToken = market.loanToken;
            permit3.transferFrom(onBehalfOf, address(this), loanToken, uint160(toRepay));
            SafeTransferLib.ensureApproval(loanToken, address(midnight), toRepay);
            // callback = 0 ⇒ Midnight pulls the loan token from this module.
            midnight.repay(market, toRepay, onBehalfOf, address(0), "");
        }

        _locked = 1;
    }
}

// ──────────────────── Midnight lend maker module ────────────────────
//
// Buys zero-coupon credit units for the maker against a maker-signed `Offer`
// with `offer.buy == false` (the maker is the buyer/lender). A MAKE value-in
// leg: the module pulls the loan-token budget (`amount`) from the maker via
// Permit3, approves Midnight, and calls `take` with `takerCallback = 0` so
// Midnight pulls exactly `buyerAssets` (≤ budget) straight from this module. The
// unspent budget is swept back to the maker.
//
// Because `take` routes the resulting credit to `taker = maker` while the module
// is `msg.sender`, the maker MUST have authorized this module on Midnight
// (`setIsAuthorized(module, true, maker)`) — atypical for a MAKE module.
//
// `data = abi.encode(Offer offer, bytes ratifierData, uint256 units)`.
//
contract MidnightLendModule is IMakerModule {
    IPermit3 public immutable permit3;
    IMidnight public immutable midnight;
    address public immutable settlement;

    uint256 private _locked = 1;

    error Reentrancy();
    error NotSettlement();

    constructor(address _permit3, address _midnight, address _settlement) {
        permit3 = IPermit3(_permit3);
        midnight = IMidnight(_midnight);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();
        if (_locked != 1) revert Reentrancy();
        _locked = 2;

        (Offer memory offer, bytes memory ratifierData, uint256 units) = abi.decode(data, (Offer, bytes, uint256));
        address loanToken = offer.market.loanToken;

        // Pull the maker-signed loan-token budget; Midnight pulls the exact
        // `buyerAssets` (≤ budget) from this module via the zero-callback path.
        permit3.transferFrom(onBehalfOf, address(this), loanToken, uint160(amount));
        SafeTransferLib.ensureApproval(loanToken, address(midnight), amount);
        // taker = maker (gains the credit); receiver arg is the seller-side sink,
        // unused on the buy side; takerCallback = 0 ⇒ module is the payer.
        midnight.take(offer, ratifierData, units, onBehalfOf, address(0), address(0), "");

        // Sweep the unspent budget back to the maker (never to a caller).
        uint256 residual = IERC20(loanToken).balanceOf(address(this));
        if (residual > 0) SafeTransferLib.safeTransfer(loanToken, onBehalfOf, residual);

        _locked = 1;
    }
}

// ──────────────────── Midnight combined taker module ────────────────────
//
// Fuses the two collateral/credit value-out legs behind a leading `op` flag, so
// the close-flow round-trip authorizes ONE module address on Midnight
// (`setIsAuthorized(this, true, maker)`) covering both `withdrawCollateral` and
// `withdraw`. `op` is the first tuple field, so the two legs hash to DIFFERENT
// Permit3 taker refs (`ref = keccak256(data)`); each therefore carries its own
// per-market, amount-gated allowance. Only the coarse Midnight authorization
// boolean is shared.
//
//   op = 0 (WithdrawCollateral): send the indexed collateral to `receiver`.
//   op = 1 (Withdraw):           redeem credit units for the loan token.
//
// `balanceMode` (a tuple field, not a trailing word — the base is dynamic):
//   0 (Exact): move exactly `amount`.
//   1 (Full):  move the maker's ENTIRE live balance to this module, forward the
//              signed `amount` to `receiver`, sweep the excess back to the maker.
//              Measures the actually-received amount via a balanceOf snapshot, so
//              a fee-on-transfer / rounding shortfall can't over-forward. Pair
//              with a fill-or-kill order (a dynamic full balance can't be
//              pro-rata'd across partial fills).
//
// `data = abi.encode(uint8 op, Market market, uint256 collateralIndex, uint8 balanceMode)`.
//
contract MidnightTakerModule is ITakerModule {
    IPermit3 public immutable permit3;
    IMidnight public immutable midnight;

    enum Op {
        WithdrawCollateral, // 0
        Withdraw // 1 — redeem credit (earn position)
    }

    enum BalanceMode {
        Exact, // 0
        Full // 1
    }

    error OnlyPermit3();
    error InsufficientWithdrawn();
    error BadOp(uint8 op);

    constructor(address _permit3, address _midnight) {
        permit3 = IPermit3(_permit3);
        midnight = IMidnight(_midnight);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data)
        external
        override
    {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        (uint8 op, Market memory market, uint256 collateralIndex, uint8 balanceMode) =
            abi.decode(data, (uint8, Market, uint256, uint8));

        if (op == uint8(Op.WithdrawCollateral)) {
            _withdrawCollateral(market, collateralIndex, onBehalfOf, amount, receiver, balanceMode);
        } else if (op == uint8(Op.Withdraw)) {
            _withdraw(market, onBehalfOf, amount, receiver, balanceMode);
        } else {
            revert BadOp(op);
        }
    }

    function _withdrawCollateral(
        Market memory market,
        uint256 collateralIndex,
        address onBehalfOf,
        uint256 amount,
        address receiver,
        uint8 balanceMode
    ) private {
        if (balanceMode != uint8(BalanceMode.Full)) {
            midnight.withdrawCollateral(market, collateralIndex, amount, onBehalfOf, receiver);
            return;
        }
        address collateralToken = market.collateralParams[collateralIndex].token;
        uint256 bal = midnight.collateral(MidnightIdLib.toId(market), onBehalfOf, collateralIndex);
        uint256 before = IERC20(collateralToken).balanceOf(address(this));
        midnight.withdrawCollateral(market, collateralIndex, bal, onBehalfOf, address(this));
        uint256 received = IERC20(collateralToken).balanceOf(address(this)) - before;
        if (received < amount) revert InsufficientWithdrawn();
        SafeTransferLib.safeTransfer(collateralToken, receiver, amount);
        if (received > amount) SafeTransferLib.safeTransfer(collateralToken, onBehalfOf, received - amount);
    }

    function _withdraw(Market memory market, address onBehalfOf, uint256 amount, address receiver, uint8 balanceMode)
        private
    {
        if (balanceMode != uint8(BalanceMode.Full)) {
            midnight.withdraw(market, amount, onBehalfOf, receiver);
            return;
        }
        address loanToken = market.loanToken;
        uint256 bal = midnight.credit(MidnightIdLib.toId(market), onBehalfOf);
        uint256 before = IERC20(loanToken).balanceOf(address(this));
        midnight.withdraw(market, bal, onBehalfOf, address(this));
        uint256 received = IERC20(loanToken).balanceOf(address(this)) - before;
        if (received < amount) revert InsufficientWithdrawn();
        SafeTransferLib.safeTransfer(loanToken, receiver, amount);
        if (received > amount) SafeTransferLib.safeTransfer(loanToken, onBehalfOf, received - amount);
    }
}

// ──────────────────── Midnight borrow taker module ────────────────────
//
// The borrow leg: sells debt units for the maker against a maker-signed `Offer`
// with `offer.buy == true` (the maker is the seller/borrower). A TAKE value-out
// leg — Midnight routes the resulting `sellerAssets` (loan token) to this module,
// which forwards the signed `amount` to `receiver` (Settlement, for the order's
// `tokenIn` payout) and sweeps any excess back to the maker.
//
// `units` is fixed in the maker-signed data, so a borrow item MUST be part of a
// fill-or-kill order (a fixed unit count can't be pro-rata'd across partial
// fills). The maker must have authorized this module on Midnight
// (`setIsAuthorized(module, true, maker)`); `takerCallback` is forced to zero.
//
// `data = abi.encode(Offer offer, bytes ratifierData, uint256 units)`.
//
contract MidnightBorrowModule is ITakerModule {
    IPermit3 public immutable permit3;
    IMidnight public immutable midnight;

    error OnlyPermit3();
    error InsufficientProceeds();

    constructor(address _permit3, address _midnight) {
        permit3 = IPermit3(_permit3);
        midnight = IMidnight(_midnight);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data)
        external
        override
    {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        (Offer memory offer, bytes memory ratifierData, uint256 units) = abi.decode(data, (Offer, bytes, uint256));
        address loanToken = offer.market.loanToken;

        uint256 before = IERC20(loanToken).balanceOf(address(this));
        // taker = maker (incurs the debt); route the seller-side proceeds here so
        // we measure what actually landed; takerCallback = 0.
        midnight.take(offer, ratifierData, units, onBehalfOf, address(this), address(0), "");
        uint256 received = IERC20(loanToken).balanceOf(address(this)) - before;

        if (received < amount) revert InsufficientProceeds();
        SafeTransferLib.safeTransfer(loanToken, receiver, amount);
        if (received > amount) SafeTransferLib.safeTransfer(loanToken, onBehalfOf, received - amount);
    }
}
