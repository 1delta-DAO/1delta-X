// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {IPositionSource} from "@core/interfaces/IPositionSource.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";

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
//  These adapters expose Midnight to `Settlement` in the same MAKE/TAKE
//  idiom as the Aave/Morpho/Venus packages:
//
//    MAKE (value-in, Permit3 token allowance gate + Midnight `setIsAuthorized`):
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
//  Authorization — EVERY module here needs the maker's Midnight grant. Every
//  position-writing entrypoint of the deployed venue (`morpho-org/midnight`
//  `Midnight.sol`; Base singleton 0xAded…A18A) opens with
//  `require(onBehalf == msg.sender || isAuthorized[onBehalf][msg.sender])` — the
//  value-IN `supplyCollateral` ("to prevent activated collateral poisoning") and
//  `repay` included, and `take` gates any `taker != msg.sender` the same way. The
//  maker must therefore once call `midnight.setIsAuthorized(module, true, maker)`
//  for EACH module they use: supply-collateral, repay, lend, taker, borrow, the
//  pre-fund module and the loop callback alike. ⚠ Midnight's grant is FULL
//  position control (withdraw, borrow-as-taker, `setConsumed`, and re-delegation
//  via `setIsAuthorized`). These contracts only ever exercise the one op their
//  code performs, on maker-signed data, behind the Settlement / Permit3 caller
//  pins; none calls `setIsAuthorized`, `setConsumed` or `multicall`, and none is a
//  ratifier. (The value-in modules used to be documented as needing no grant —
//  true of the old test mock, false on the venue; audit 2026-09-30 L-ML-1.) The
//  Permit3 taker allowance (keyed by `ref = keccak256(data)`) caps the per-fill
//  amount of the value-out legs.
//
//  Strict blob heads. `abi.decode` of a tuple whose first member is DYNAMIC
//  (`Market`, `Offer`) does not require that member's head offset to point past
//  the head, so a blob built for an older, shorter layout decodes "successfully"
//  with the trailing `totalAmount` read out of the first tail word (a market's
//  `chainId`, an offer's inner offset 0x1e0) — a constant a dust slice can match
//  ({FullFillGuard}). {MidnightBlob.requireHead} pins the offset to the full head
//  size first, so a short blob fails closed (audit 2026-09-30 G-BYTE_MAP-1).
// ════════════════════════════════════════════════════════════════════════════

/// @notice Strict head check for the dynamic-first Midnight blobs (G-BYTE_MAP-1).
/// @dev    solc's decoder accepts a dynamic member's head offset anywhere at or
///         after the minimum head, so a blob encoded with FEWER head words than the
///         decode tuple aliases the missing trailing word onto the first tail word.
///         Pinning the dynamic member's offset to the exact head size of the
///         current layout makes any older/shorter layout fail closed.
library MidnightBlob {
    error MalformedData();

    /// @param at   byte position of the dynamic member's head word.
    /// @param head the full head size of the expected tuple, in bytes.
    function requireHead(bytes calldata data, uint256 at, uint256 head) internal pure {
        if (data.length < at + 32 || uint256(bytes32(data[at:at + 32])) != head) revert MalformedData();
    }
}

// ──────────────────── Midnight supply-collateral maker module ────────────────────
//
// Single-op MAKE: pulls the indexed collateral token from the maker via Permit3
// and supplies it into the market on the maker's behalf. ⚠ Midnight gates
// `supplyCollateral` on `isAuthorized[maker][module]` (collateral-poisoning
// guard), so the maker must `setIsAuthorized(this, true, maker)` — see the file
// header. The Permit3 token allowance caps the amount.
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
        // Scoped approve + clear, NOT a standing max approval.
        //
        // ⚠ THE ORIGINAL JUSTIFICATION HERE WAS WRONG, and the corrected one is
        // weaker — kept because the practice is still right. This comment used to
        // claim that "any external account can call `take` designating THIS module
        // as the payer, and a standing allowance is what would let that pull
        // succeed". Read against the deployed source (morpho-org/midnight
        // `Midnight.sol`), a standing allowance is NOT sufficient and never was:
        //
        //   address payer = buyerCallback != address(0) ? buyerCallback : ...
        //   if (buyerCallback != address(0)) require(IBuyCallback(buyerCallback)
        //       .onBuy(...) == CALLBACK_SUCCESS, WrongBuyCallbackReturnValue());
        //   SafeTransferLib.safeTransferFrom(loanToken, payer, ...);   // AFTER
        //
        // Naming an address as payer means naming it as the CALLBACK, and Midnight
        // invokes it and requires the success sentinel BEFORE it pulls. The same
        // shape holds on every other payer path — `repay` (onRepay), `liquidate`
        // (onLiquidate), `flashLoan` (onFlashLoan). No module in this package
        // implements any of them, so no module can be named as payer by anyone.
        //
        // What the scoping still buys: defence in depth if a module ever gains a
        // callback, and no residual allowance outliving the call that needed it.
        // See `docs/audit-2026-09-leads.md` D-1 for the full resolution.
        SafeTransferLib.forceApprove(collateralToken, address(midnight), amount);
        midnight.supplyCollateral(market, collateralIndex, amount, onBehalfOf);
        SafeTransferLib.forceApprove(collateralToken, address(midnight), 0);
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
// ⚠ Midnight gates `repay` on `isAuthorized[maker][module]` too, so the maker
// must `setIsAuthorized(this, true, maker)` — see the file header.
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
            // Scoped, then cleared — see the supply module for why a standing max
            // approval to Midnight is not safe despite `midnight` being immutable.
            SafeTransferLib.forceApprove(loanToken, address(midnight), toRepay);
            // callback = 0 ⇒ Midnight pulls the loan token from this module.
            midnight.repay(market, toRepay, onBehalfOf, address(0), "");
            SafeTransferLib.forceApprove(loanToken, address(midnight), 0);
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
// ⚠ FULL-FILL ONLY. `units` is a side leg: it lives in `data`, which is constant
// across fills, while `amount` is this fill's pro-rated slice. Every slice would
// therefore `take` the SAME `units` again — an N-slice fill buys N × the credit
// the maker signed for, paid out of N × the budget, bounded only by their Permit3
// allowance. So the maker signs `totalAmount` alongside it and the slice is
// required to equal it; see {FullFillGuard}, which every other composite module
// in this repo already uses. This was previously stated in prose only.
//
// `data = abi.encode(Offer offer, bytes ratifierData, uint256 units, uint256 totalAmount)`.
//
contract MidnightLendModule is IMakerModule {
    IPermit3 public immutable permit3;
    IMidnight public immutable midnight;
    address public immutable settlement;

    uint256 private _locked = 1;

    error Reentrancy();
    error NotSettlement();
    error WrongOfferSide();

    constructor(address _permit3, address _midnight, address _settlement) {
        permit3 = IPermit3(_permit3);
        midnight = IMidnight(_midnight);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();
        if (_locked != 1) revert Reentrancy();
        _locked = 2;

        // 4 head words: (Offer, bytes, units, totalAmount) — see {MidnightBlob}.
        MidnightBlob.requireHead(data, 0, 0x80);
        (Offer memory offer, bytes memory ratifierData, uint256 units, uint256 totalAmount) =
            abi.decode(data, (Offer, bytes, uint256, uint256));
        // This module is the LEND leg: the taker must be the buyer/lender, which
        // Midnight selects with `offer.buy == false`. The flag is decoded from the
        // order's `data` and drives the entire meaning of the `take` below, but
        // nothing downstream re-derives it — so an order carrying `buy == true`
        // silently inverts the leg. The maker would become the SELLER/borrower:
        // they would take on debt instead of lending, and the `sellerAssets`
        // proceeds would route to `receiverIfTakerIsSeller`, which this call
        // hard-codes to `address(0)` — the borrowed funds are burned and the
        // maker keeps the debt. Assert the side rather than trusting the encoder.
        if (offer.buy) revert WrongOfferSide();
        // `units` does not pro-rate — see the contract note. Reject a sliced fill.
        // AFTER the side assertion: a wrong-side offer is malformed whatever the
        // slice, and {WrongOfferSide} says so far more precisely than a size error.
        FullFillGuard.requireFullFill(amount, totalAmount);
        address loanToken = offer.market.loanToken;

        // Balance held BEFORE the pull. Sweeping `balanceOf(this)` outright would
        // pay out anything already stranded at this shared module address, and
        // "anyone can be the maker of a one-unit order against that module and
        // asset" -- so a stray balance would be claimable by whoever fills next.
        // The invariant is "the module ends where it started", not "ends empty":
        // the same floor every sibling repay/withdraw module takes.
        uint256 floor = IERC20(loanToken).balanceOf(address(this));
        // Pull the maker-signed loan-token budget; Midnight pulls the exact
        // `buyerAssets` (≤ budget) from this module via the zero-callback path.
        permit3.transferFrom(onBehalfOf, address(this), loanToken, uint160(amount));
        // Approve EXACTLY the budget and clear the remainder afterwards. A standing
        // max approval would let any later `take` — under a different maker's offer
        // in a different fill — pull this module's whole balance, and `take`'s payer
        // on the buy side is simply `msg.sender`, i.e. this module. Scoping the
        // allowance to the amount actually funded keeps a fill's exposure to the
        // funds that fill pulled in.
        SafeTransferLib.forceApprove(loanToken, address(midnight), amount);
        // taker = maker (gains the credit); receiver arg is the seller-side sink,
        // unused on the buy side; takerCallback = 0 ⇒ module is the payer.
        midnight.take(offer, ratifierData, units, onBehalfOf, address(0), address(0), "");
        SafeTransferLib.forceApprove(loanToken, address(midnight), 0);

        // Sweep the unspent budget back to the maker (never to a caller), and only
        // the DELTA this call produced -- never the pre-existing `floor`.
        uint256 bal = IERC20(loanToken).balanceOf(address(this));
        if (bal > floor) SafeTransferLib.safeTransfer(loanToken, onBehalfOf, bal - floor);

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
// `data = abi.encode(uint8 op, Market market, uint256 collateralIndex,
//                    uint8 balanceMode, uint256 totalAmount)`
//
// `balanceMode` (a tuple field, not a trailing word — the base is dynamic):
//   0 (Exact): move exactly `amount`.
//   1 (Full):  move the maker's ENTIRE live balance to this module, forward the
//              signed `amount` to `receiver`, sweep the excess back to the maker.
//              Measures the actually-received amount via a balanceOf snapshot, so
//              a fee-on-transfer / rounding shortfall can't over-forward.
//              ⚠ FULL-FILL ONLY, AND NOW ENFORCED via the signed `totalAmount`
//              field: `Full` reads a LIVE balance, so a 1-unit slice would
//              force-close the whole position and leave nothing for the rest of
//              the order. Every sibling package guards this with
//              {FullFillGuard.requireFullFillFromData}; Midnight cannot use the
//              trailing-word variant (its base tuple is dynamic, so the offset is
//              not fixed), so the total is a named field instead. `Exact` ignores
//              it — encode 0. Pair
//              with a fill-or-kill order (a dynamic full balance can't be
//              pro-rata'd across partial fills).
//              Credit (`op = 1`) is sized from `updatePosition`, NOT the raw
//              `credit()` getter: Midnight's `credit()` is the STORED value, and
//              `withdraw` first applies the loss-factor slash and the accrued
//              continuous fee — withdrawing the stale figure underflows the
//              moment either is non-zero (audit 2026-09-30 L-ML-3).
//   any other value reverts {BadBalanceMode} (the field is untagged, so 2..255
//   must not silently mean Exact).
//
contract MidnightTakerModule is ITakerModule, IPositionSource {
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
    error BadOp(uint8 op);
    error BadBalanceMode(uint8 mode);

    constructor(address _permit3, address _midnight) {
        permit3 = IPermit3(_permit3);
        midnight = IMidnight(_midnight);
    }

    /// @inheritdoc IPositionSource
    /// @dev The RAW live position behind either op (audit 2026-09-30 L-LIB-8):
    ///        • op 0 — `collateral(id, user, index)` of the indexed collateral token
    ///          (a plain amount that does not accrue);
    ///        • op 1 — the UPDATED credit from `updatePositionView`, the view twin of
    ///          the `updatePosition` the `Full` withdraw sizes from (the stored
    ///          `credit()` is stale — L-ML-3), in loan-token units (credit units
    ///          redeem 1:1, as `withdraw(market, amount, …)` takes them).
    ///      Not bounded by the module's Midnight authorization.
    function positionOf(address user, bytes calldata data)
        external
        view
        override
        returns (address asset, uint256 amount)
    {
        MidnightBlob.requireHead(data, 32, 0xa0);
        (uint8 op, Market memory market, uint256 collateralIndex,,) =
            abi.decode(data, (uint8, Market, uint256, uint8, uint256));
        bytes32 id = MidnightIdLib.toId(market);
        if (op == uint8(Op.WithdrawCollateral)) {
            return (market.collateralParams[collateralIndex].token, midnight.collateral(id, user, collateralIndex));
        }
        if (op == uint8(Op.Withdraw)) {
            (uint256 credit,,) = midnight.updatePositionView(market, id, user);
            return (market.loanToken, credit);
        }
        revert BadOp(op);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        // 5 head words: (op, Market, collateralIndex, balanceMode, totalAmount).
        MidnightBlob.requireHead(data, 32, 0xa0);
        (uint8 op, Market memory market, uint256 collateralIndex, uint8 balanceMode, uint256 totalAmount) =
            abi.decode(data, (uint8, Market, uint256, uint8, uint256));
        if (balanceMode > uint8(BalanceMode.Full)) revert BadBalanceMode(balanceMode);

        // `Full` liquidates the maker's ENTIRE live balance, so it cannot be
        // pro-rated: a sliced fill unwinds the whole position and bricks every later
        // fill of the same order. Asserted HERE rather than inside the two helpers so
        // their signatures (and this package's non-via-IR stack budget) are untouched.
        if (balanceMode == uint8(BalanceMode.Full)) FullFillGuard.requireFullFill(amount, totalAmount);

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
        // ONE venue withdraw, then an ERC-20 SPLIT — the whole position lands here and
        // the signed `amount` goes on to `receiver`, the rest back to `onBehalfOf`. A
        // second venue withdraw would re-do the venue's burn and accounting; a transfer
        // does not.
        //
        // ⚠ THE CAP IS WHAT MAKES THE CUSTODY SAFE, and it is not optional here: the
        // module holds the asset between the withdraw and the split, so `floor` excludes
        // any balance already sitting here and `min(received, amount)` makes it
        // structurally impossible for a short or fake-venue delivery to be topped up out
        // of it. A nominal `safeTransfer(receiver, amount)` would be the H-3 drain.
        address collateralToken = market.collateralParams[collateralIndex].token;
        uint256 floor = IERC20(collateralToken).balanceOf(address(this));
        uint256 bal = midnight.collateral(MidnightIdLib.toId(market), onBehalfOf, collateralIndex);
        midnight.withdrawCollateral(market, collateralIndex, bal, onBehalfOf, address(this));
        uint256 received = IERC20(collateralToken).balanceOf(address(this)) - floor;
        // The lower bound the venue used to enforce. Before the split rewrite the
        // venue call was sized at `amount`, so a short position reverted inside it;
        // now nothing does, and {Core._payInputsToSolver} would bill the shortfall to
        // the MAKER'S WALLET. Safe here and only here: `Full` is full-fill, so
        // `amount` is the signed TOTAL, never a pro-rated slice.
        FullFillGuard.requireDelivered(received, amount);
        SafeTransferLib.safeTransfer(collateralToken, receiver, received < amount ? received : amount);
        if (received > amount) SafeTransferLib.safeTransfer(collateralToken, onBehalfOf, received - amount);
    }

    function _withdraw(Market memory market, address onBehalfOf, uint256 amount, address receiver, uint8 balanceMode)
        private
    {
        if (balanceMode != uint8(BalanceMode.Full)) {
            midnight.withdraw(market, amount, onBehalfOf, receiver);
            return;
        }
        // ONE venue withdraw, then an ERC-20 SPLIT — the whole position lands here and
        // the signed `amount` goes on to `receiver`, the rest back to `onBehalfOf`. A
        // second venue withdraw would re-do the venue's burn and accounting; a transfer
        // does not.
        //
        // ⚠ THE CAP IS WHAT MAKES THE CUSTODY SAFE, and it is not optional here: the
        // module holds the asset between the withdraw and the split, so `floor` excludes
        // any balance already sitting here and `min(received, amount)` makes it
        // structurally impossible for a short or fake-venue delivery to be topped up out
        // of it. A nominal `safeTransfer(receiver, amount)` would be the H-3 drain.
        address loanToken = market.loanToken;
        uint256 floor = IERC20(loanToken).balanceOf(address(this));
        // The LIVE credit: `updatePosition` (permissionless) applies the slash and
        // the accrued continuous fee and returns the updated figure, so the
        // `withdraw` below — which updates first too — sees exactly this credit.
        // The raw `credit()` getter is stale and over-sized the call (L-ML-3).
        (uint256 bal,,) = midnight.updatePosition(market, onBehalfOf);
        midnight.withdraw(market, bal, onBehalfOf, address(this));
        uint256 received = IERC20(loanToken).balanceOf(address(this)) - floor;
        // The lower bound the venue used to enforce. Before the split rewrite the
        // venue call was sized at `amount`, so a short position reverted inside it;
        // now nothing does, and {Core._payInputsToSolver} would bill the shortfall to
        // the MAKER'S WALLET. Safe here and only here: `Full` is full-fill, so
        // `amount` is the signed TOTAL, never a pro-rated slice.
        FullFillGuard.requireDelivered(received, amount);
        SafeTransferLib.safeTransfer(loanToken, receiver, received < amount ? received : amount);
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
// ⚠ FULL-FILL ONLY, AND NOW ENFORCED. `units` is fixed in the maker-signed data, so a borrow item MUST be part of a
// fill-or-kill order (a fixed unit count can't be pro-rata'd across partial
// fills). The maker must have authorized this module on Midnight
// (`setIsAuthorized(module, true, maker)`); `takerCallback` is forced to zero.
//
// ⚠ DELIVERY-BOUNDED. `take` is sized by `units`, not by `amount`: the proceeds
// are `units · (price − settlementFee(ttm))`, and Midnight's `feeSetter` can raise
// the fee at any time (no timelock; breakpoints need not be monotone). A short
// delivery used to be forwarded as-is and the core billed the gap to the maker's
// WALLET (I-8). The leg now reverts unless the proceeds cover the signed
// `amount` ({FullFillGuard.requireDelivered}; audit 2026-09-30 L-CV2-1.v2) —
// sound because `requireFullFill` already pinned `amount` to the signed total.
//
// `data = abi.encode(Offer offer, bytes ratifierData, uint256 units, uint256 totalAmount)`.
//
contract MidnightBorrowModule is ITakerModule {
    IPermit3 public immutable permit3;
    IMidnight public immutable midnight;

    error OnlyPermit3();
    error WrongOfferSide();

    constructor(address _permit3, address _midnight) {
        permit3 = IPermit3(_permit3);
        midnight = IMidnight(_midnight);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        // 4 head words: (Offer, bytes, units, totalAmount) — see {MidnightBlob}.
        MidnightBlob.requireHead(data, 0, 0x80);
        (Offer memory offer, bytes memory ratifierData, uint256 units, uint256 totalAmount) =
            abi.decode(data, (Offer, bytes, uint256, uint256));
        // The BORROW leg's mirror of the lend-side assertion: the taker must be the
        // seller/borrower, i.e. `offer.buy == true`. With `buy == false` the maker
        // becomes the buyer/lender and Midnight pulls `buyerAssets` from the payer
        // (`msg.sender` — this module) instead of paying out, so a value-OUT leg
        // silently turns into a value-IN one. It only fails closed today by
        // accident: the module keeps no allowance to Midnight, so the pull reverts.
        // Assert the side so the leg's direction never rests on that.
        if (!offer.buy) revert WrongOfferSide();
        // `units` is constant across fills while `amount` is this fill's slice, so a
        // sliced fill would sell `units` of debt AGAIN on every slice — N × the debt
        // the maker signed for, with the excess handed back as loose tokens. The
        // header has always said a borrow item must be full-fill; this enforces it.
        // Ordered after the side assertion for the reason given in {MidnightLendModule}.
        FullFillGuard.requireFullFill(amount, totalAmount);
        address loanToken = offer.market.loanToken;

        uint256 before = IERC20(loanToken).balanceOf(address(this));
        // taker = maker (incurs the debt); route the seller-side proceeds here so
        // we measure what actually landed; takerCallback = 0.
        midnight.take(offer, ratifierData, units, onBehalfOf, address(this), address(0), "");
        uint256 received = IERC20(loanToken).balanceOf(address(this)) - before;
        // The lower bound: a venue fee rise between signing and fill must revert the
        // leg, not bill the maker's wallet for the gap (L-CV2-1.v2).
        FullFillGuard.requireDelivered(received, amount);

        // Deliver the measured proceeds, capped at the signed amount; excess to the
        // maker below. Never exceeds `received`, so an under-delivering venue
        // cannot be topped up from a stray module balance.
        SafeTransferLib.safeTransfer(loanToken, receiver, received < amount ? received : amount);
        if (received > amount) SafeTransferLib.safeTransfer(loanToken, onBehalfOf, received - amount);
    }
}
