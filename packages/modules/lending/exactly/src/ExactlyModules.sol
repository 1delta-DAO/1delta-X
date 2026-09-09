// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {DustHandler} from "@lib/DustHandler.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";
import {ProratedBound} from "@lib/ProratedBound.sol";
import {Narrow160} from "@lib/Narrow160.sol";
import {PermitHelper} from "@lib/PermitHelper.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

import {IExactlyMarket} from "./interfaces/IExactly.sol";

// ════════════════════════════════════════════════════════════════════════════
//  Exactly (ERC-4626 fixed/floating pool) modules
//
//  One Market per asset. `maturity == 0` ⇒ floating pool; a non-zero unix
//  timestamp ⇒ that fixed pool. Because `borrow`/`withdraw` carry a `receiver`,
//  the value-out legs forward straight to the order's `receiver` — the clean
//  case. Cross-margin: collateral counts only once the maker has
//  `Auditor.enterMarket(market)` (a maker-side permission, not a module call).
//
//  Authorisation:
//    • deposit / repay — permissionless value-in; no grant.
//    • borrow / withdraw — the maker signs one `market.approve(module, max)`
//      (ERC-4626 share allowance); Exactly consumes it when principal != caller.
//      The Permit3 taker allowance bounds the per-fill amount. SIGNATURE-ONLY
//      alternative: the Market's shares are EIP-2612 (solmate ERC20 base), so the
//      approval can instead ride inside the order as an optional permit tail on
//      the taker data — see {ExactlyTakerModule}. No on-chain grant remains.
// ════════════════════════════════════════════════════════════════════════════

// ──────────────────── Exactly deposit maker module ────────────────────
//
// Pulls `asset` via Permit3 and supplies it into `market` crediting the user.
// `maturity == 0` ⇒ floating `deposit`; else `depositAtMaturity` with the
// maker-signed `minAssetsRequired` floor. Optional EIP-2612 permit replay.
//
// `data = abi.encode(market, asset, maturity, minAssetsRequired[, deadline, v, r, s])`
//   — base = 128 bytes.
//
contract ExactlyDepositModule is IMakerModule {
    IPermit3 public immutable permit3;
    address public immutable settlement;

    error NotSettlement();

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();

        (address market, address asset, uint256 maturity, uint256 minAssetsRequired) =
            abi.decode(data, (address, address, uint256, uint256));

        PermitHelper.replayIfPresent(data, 128, asset, onBehalfOf, address(permit3), amount);

        permit3.transferFrom(onBehalfOf, address(this), asset, uint160(amount));
        SafeTransferLib.forceApprove(asset, market, amount);

        if (maturity == 0) {
            IExactlyMarket(market).deposit(amount, onBehalfOf);
        } else {
            IExactlyMarket(market).depositAtMaturity(maturity, amount, minAssetsRequired, onBehalfOf);
        }
        // Clear the scoped grant: `market` is decoded from the order's `data` on a
        // SHARED singleton, so it is attacker-choosable — anyone can author an order
        // naming themselves as maker. A target that consumes less than approved would
        // leave a standing third-party claim on any FUTURE balance of this module,
        // which is what turns a later stranded-balance bug into a theft.
        // {SafeTransferLib.ensureApproval} forbids this shape. F25 / A-3.
        SafeTransferLib.forceApprove(asset, market, 0);
    }
}

// ──────────────────── Exactly repay maker module ────────────────────
//
// Closes the user's borrow in `market`. Floating: read the live debt
// (`previewDebt`) and repay `min(amount, debt)` — SweepToUser never pulls the
// over-repay buffer. Fixed: repay `amount` face at `maturity`, bounded by the
// maker-signed `maxAssets`; any unspent buffer is disposed to the user (or
// recycled). Either way disposal is locked to `onBehalfOf` / the market.
//
// `nonReentrant` guards weird-token transfer hooks.
// `data = abi.encode(market, asset, maturity, maxAssets[, DustAction[, deadline, v, r, s]])`
//   — base = 128; DustAction@128; permit@160.
//
contract ExactlyRepayModule is IMakerModule {
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

        (address market, address asset, uint256 maturity, uint256 maxAssets) =
            abi.decode(data, (address, address, uint256, uint256));
        DustHandler.DustAction action = DustHandler.readAction(data, 128);
        PermitHelper.replayIfPresent(data, 160, asset, onBehalfOf, address(permit3), amount);

        // The balance this module held BEFORE the pull. Everything below disposes of
        // the DELTA over it, never the whole balance: a module address can be sent
        // tokens by anyone, and "sweep everything to the user" pays that to whoever
        // happens to be filling. See the floor overload of {DustHandler.disposeResidual}.
        uint256 floor = IERC20(asset).balanceOf(address(this));

        _pullAndRepay(market, asset, maturity, amount, maxAssets, onBehalfOf, action == DustHandler.DustAction.Recycle);
        _disposeResidual(market, asset, onBehalfOf, action, floor);

        _locked = 1;
    }

    function _pullAndRepay(
        address market,
        address asset,
        uint256 maturity,
        uint256 amount,
        uint256 maxAssets,
        address onBehalfOf,
        bool recycle
    ) private {
        if (maturity == 0) {
            // Floating: pull-exact against the live debt.
            uint256 debt = IExactlyMarket(market).previewDebt(onBehalfOf);
            uint256 toRepay = amount < debt ? amount : debt;
            uint256 toPull = recycle ? amount : toRepay;
            if (toPull > 0) permit3.transferFrom(onBehalfOf, address(this), asset, uint160(toPull));
            if (toRepay > 0) {
                SafeTransferLib.forceApprove(asset, market, toRepay);
                IExactlyMarket(market).repay(toRepay, onBehalfOf);
            }
        } else {
            // Fixed: `amount` = face to repay; `maxAssets` bounds the transfer.
            // Pull the bound, let the Market take only what it needs; the surplus
            // is disposed below.
            if (maxAssets > 0) {
                permit3.transferFrom(onBehalfOf, address(this), asset, Narrow160.to160(maxAssets));
                SafeTransferLib.forceApprove(asset, market, maxAssets);
            }
            IExactlyMarket(market).repayAtMaturity(maturity, amount, maxAssets, onBehalfOf);
        }
    }

    /// @dev Re-supply (opt-in) the residual into the user's floating position,
    ///      else sweep to the user. Best-effort recycle with a guaranteed sweep.
    function _disposeResidual(
        address market,
        address asset,
        address onBehalfOf,
        DustHandler.DustAction action,
        uint256 floor
    ) private {
        // The delta THIS call produced, not the module's whole balance — `floor` is
        // what it already held. On the normal path a module is pull-exact and starts
        // empty, so `floor` is 0 and this is behaviour-preserving.
        uint256 bal = IERC20(asset).balanceOf(address(this));
        if (bal <= floor) return;
        uint256 residual;
        unchecked {
            residual = bal - floor; // bal > floor
        }
        SafeTransferLib.forceApprove(asset, market, 0); // clear the repay approval first
        DustHandler.disposeResidual(
            asset,
            residual,
            floor,
            onBehalfOf,
            action,
            market,
            abi.encodeWithSignature("deposit(uint256,address)", residual, onBehalfOf)
        );
    }
}

// ──────────────────── Exactly combined taker module ────────────────────
//
// Fuses borrow and withdraw behind a leading `op` flag. Borrow-data and
// withdraw-data hash to different `keccak256(data)` refs, so the maker grants a
// separate amount-gated taker allowance per leg; the shared ERC-4626 share
// allowance (`market.approve(module, max)`) is per-address by construction.
//
//   base: op@0, market@32, asset@64, maturity@96, bound@128, totalAmount@160
//         (base length 192)
//     — `bound` = maxAssets (borrow-at-maturity) / minAssetsRequired (withdraw-at-maturity).
//     — `totalAmount` is the item's FULL maker-signed amount. BREAKING (F26): it is
//       new, and it is MANDATORY on the at-maturity borrow leg, where it scales the
//       absolute `maxAssets` ceiling with the slice ({ProratedBound}). One field
//       serves both users of a total: the `Full` withdraw guard now reads it at 160
//       instead of carrying a second copy at 192.
//   op = 0 (Borrow):    data = abi.encode(uint8(0), market, asset, maturity, maxAssets, totalAmount[, value, deadline, v, r, s])
//   op = 1 (Withdraw):  data = abi.encode(uint8(1), market, asset, maturity, minAssets, totalAmount[, BalanceMode[, value, deadline, v, r, s]])
//     — BalanceMode@192 (floating only). `Full` withdraws the whole floating
//       position and sweeps the excess to the user.
//
//  Optional SHARE-PERMIT tail — the signature-only grant. Exactly's Market is
//  solmate ERC4626, so its shares are EIP-2612: instead of a prior on-chain
//  `market.approve(module, …)`, the maker can sign a 2612 permit over the
//  MARKET's shares approving THIS MODULE and append it to the data:
//    `(uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)` — 160 bytes,
//    at a FIXED offset: Borrow ⇒ @192; Withdraw ⇒ @224 (i.e. AFTER the
//    BalanceMode slot, which MUST then be encoded — pad 0 = Exact — even on the
//    at-maturity leg, where it is otherwise ignored). Absent tail ⇒ byte-exact
//    no-op: the module falls back to the standing share allowance.
//    The module replays `market.permit(onBehalfOf, module, value, …)` BEST-EFFORT
//    (see {PermitHelper}) before the venue call — a front-run replay of the
//    lifted permit leaves exactly the allowance the fill wants, and the Market's
//    own allowance check is the real gate.
//
//  Sizing `value` (the maker's call): the allowance goes only to this
//  maker-signed module, and every spend through it is gated by the Permit3 taker
//  book, so `type(uint256).max` is defensible — but signing the order's actual
//  SHARE cap is tighter. Beware the units: the order is denominated in ASSETS
//  while the Market debits the allowance in SHARE units at its own conversion
//  (`previewWithdraw(assets)` for withdraw / borrowAtMaturity, `previewBorrow`
//  — floating-borrow shares — for floating borrow), and the shares:assets rate
//  DRIFTS as interest accrues between signing and fill. Both share prices start
//  at 1 and rise with accrual, so the share cost of a fixed asset amount falls
//  over time and `value = the order's total asset amount` is a natural
//  over-approximation; `convertToShares`/preview at signing plus rounding margin
//  is tighter but leans on the price never dipping (an extreme bad-debt event
//  could move it). An under-sized `value` fails CLOSED: the Market reverts on
//  allowance, killing the fill — never over-spending.
//
contract ExactlyTakerModule is ITakerModule {
    IPermit3 public immutable permit3;

    enum Op {
        Borrow, // 0
        Withdraw // 1
    }

    error OnlyPermit3();
    error BadOp(uint8 op);

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        // NOTE: `totalAmount@160` is deliberately NOT in this tuple. Adding a sixth
        // local pushes this frame over the stack limit on the legacy (non-via-IR)
        // profile these packages build with, so the branch that needs it reads it
        // straight from calldata instead.
        (uint8 op, address market, address asset, uint256 maturity, uint256 bound) =
            abi.decode(data, (uint8, address, address, uint256, uint256));

        // Optional share-permit tail (see the header): replay the maker's 2612
        // signature over the MARKET's shares approving this module, best-effort,
        // so no prior on-chain `market.approve` is needed. Borrow data has no
        // BalanceMode slot, so its tail sits one word earlier.
        PermitHelper.replayValueIfPresent(
            data, op == uint8(Op.Borrow) ? 192 : 224, market, onBehalfOf, address(this)
        );

        if (op == uint8(Op.Borrow)) {
            if (maturity == 0) {
                IExactlyMarket(market).borrow(amount, receiver, onBehalfOf);
            } else {
                // `maxAssets` is an ABSOLUTE ceiling the maker sized against the whole
                // item, and the FILLER chooses how many slices to fill it in. Passing
                // it unscaled multiplied the maker's signed slippage tolerance by N.
                // Scale it with the slice; see {ProratedBound} for the full write-up.
                // Reuses `bound`'s slot rather than introducing a local: an extra
                // stack item here overflows the legacy profile's frame.
                bound = _scaledBound(data, bound, amount);
                IExactlyMarket(market).borrowAtMaturity(maturity, amount, bound, receiver, onBehalfOf);
            }
        } else if (op == uint8(Op.Withdraw)) {
            if (maturity != 0) {
                // NOT scaled, deliberately. Here `bound` is `minAssetsRequired` — a
                // FLOOR. Applied unscaled to a slice it is STRICTER than the maker
                // asked for, so a partial fill reverts: fail-closed. Scaling it would
                // loosen a guard that is currently safe, and separately would enable
                // partial fills on a leg that does not support them today. See the
                // ⚠ note in {ProratedBound}.
                IExactlyMarket(market).withdrawAtMaturity(maturity, amount, bound, receiver, onBehalfOf);
            } else if (DustHandler.readBalanceMode(data, 192) == DustHandler.BalanceMode.Full) {
                // `Full` liquidates the user's ENTIRE live balance, so it cannot be
                // pro-rated — a sliced fill would unwind the whole position and brick
                // the rest of the order. Require the slice to be the whole item.
                FullFillGuard.requireFullFillFromData(data, 160, amount);
                _withdrawFull(market, asset, onBehalfOf, amount, receiver);
            } else {
                IExactlyMarket(market).withdraw(amount, receiver, onBehalfOf);
            }
        } else {
            revert BadOp(op);
        }
    }

    /// @dev Reads the maker-signed `totalAmount@160` and scales an absolute max
    ///      bound with the slice. Its own frame so `takeOnBehalf` stays under the
    ///      legacy profile's stack limit. Fails closed when the word is absent —
    ///      an order without a total is exactly the order that was unprotected.
    function _scaledBound(bytes calldata data, uint256 bound, uint256 amount) private pure returns (uint256) {
        if (data.length < 192) revert ProratedBound.BoundTotalMissing();
        return ProratedBound.scale(bound, amount, uint256(bytes32(data[160:192])));
    }

    /// @dev Full mode (floating): unwind the user's entire position with
    ///      EXACT amounts sent straight to their destinations — the signed `amount`
    ///      to `receiver`, the remainder back to `onBehalfOf`. ERC-4626 `withdraw`
    ///      burns the OWNER's shares and pays `receiver` directly, so the module
    ///      never takes custody: no delta measurement, no split transfers, and a
    ///      stray module balance can never become part of the payout. A position
    ///      smaller than `amount` reverts in the vault — fail closed, no gate.
    function _withdrawFull(address market, address, address onBehalfOf, uint256 amount, address receiver)
        private
    {
        uint256 max = IExactlyMarket(market).maxWithdraw(onBehalfOf);
        IExactlyMarket(market).withdraw(amount, receiver, onBehalfOf);
        if (max > amount) IExactlyMarket(market).withdraw(max - amount, onBehalfOf, onBehalfOf);
    }
}
