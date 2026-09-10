// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {IPositionSource} from "@core/interfaces/IPositionSource.sol";
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
        // ⚠ BRANCH-SCOPED TAIL. The FIXED branch carries a maker-signed `totalAmount`
        // at 160 (it needs one — see {_scaledBound}), so its permit tail sits at 192.
        // The floating branch has no total and keeps the permit at 160. Same rule the
        // Comet/Morpho/Lista taker maps already use for their `Full` tails.
        PermitHelper.replayIfPresent(data, maturity == 0 ? 160 : 192, asset, onBehalfOf, address(permit3), amount);

        // The balance this module held BEFORE the pull. Everything below disposes of
        // the DELTA over it, never the whole balance: a module address can be sent
        // tokens by anyone, and "sweep everything to the user" pays that to whoever
        // happens to be filling. See the floor overload of {DustHandler.disposeResidual}.
        uint256 floor = IERC20(asset).balanceOf(address(this));

        // The FIXED branch's `maxAssets` is scaled HERE, where `data` is still in
        // scope — see {_scaledBound}. Reassigned in place rather than passed as a
        // ternary: this function is already at the legacy codegen stack limit.
        // The floating branch has no absolute bound to scale.
        if (maturity != 0) maxAssets = _scaledBound(data, maxAssets, amount);

        _pullAndRepay(market, asset, maturity, amount, maxAssets, onBehalfOf, action == DustHandler.DustAction.Recycle);
        _disposeResidual(market, asset, onBehalfOf, action, floor);

        _locked = 1;
    }

    /// @dev Reads the maker-signed `totalAmount@160` and scales an absolute bound
    ///      with the slice. Fails closed when the word is absent — an order without
    ///      a total is exactly the order that was unprotected. Mirrors
    ///      {ExactlyTakerModule._scaledBound}.
    function _scaledBound(bytes calldata data, uint256 bound, uint256 amount) private pure returns (uint256) {
        if (data.length < 192) revert ProratedBound.BoundTotalMissing();
        return ProratedBound.scale(bound, amount, uint256(bytes32(data[160:192])));
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
            // Floating: pull-exact against the live FLOATING debt.
            //
            // ⚠ NOT `previewDebt`, which is floating + EVERY fixed-maturity
            // position. `repay` settles the FLOATING book only, so clamping against
            // the combined figure measures against a book this call does not touch:
            // a maker holding both would have their floating debt zeroed while the
            // whole fixed position stands, and the `[repay, withdraw]` close then
            // reverts on health with nothing to point at. The over-read direction
            // was never a loss (the Market caps at the borrower's own shares and the
            // surplus is swept), but the module's idea of "the debt" was wrong.
            uint256 debt = IExactlyMarket(market).previewRefund(
                IExactlyMarket(market).floatingBorrowShares(onBehalfOf)
            );
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
            // ⚠ SCALE THE BOUND WITH THE SLICE. `maxAssets` is an ABSOLUTE
            // slippage ceiling and `amount` is a pro-rated face, so passing the
            // whole order's ceiling to every slice lets a filler-chosen slice count
            // N multiply the maker's signed tolerance by N — and post-maturity,
            // where Exactly charges a PENALTY rather than a discount, that is a
            // straight overpay. The pull is scaled too, or N slices would draw
            // N x maxAssets from the maker's allowance. {ProratedBound} is already
            // applied to `borrowAtMaturity` in this same file.
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
contract ExactlyTakerModule is ITakerModule, IPositionSource {
    IPermit3 public immutable permit3;

    enum Op {
        Borrow, // 0
        Withdraw // 1
    }

    /// @inheritdoc IPositionSource
    /// @dev `maxWithdraw` — not `convertToAssets(balanceOf)` — is deliberate, and is
    ///      the same reader the `Full` branch uses. It is already denominated in the
    ///      vault's ASSET (so it needs no conversion to leg units) and it already
    ///      accounts for the constraints that would make a larger withdraw revert: a
    ///      borrow against the position, or vault illiquidity. Sizing off the raw
    ///      share balance would price a withdraw the venue then refuses.
    ///
    ///      `asset` comes from the VAULT, never from `data`: it is the token the
    ///      withdraw actually pays out, so it is the only honest answer to the
    ///      caller's units check.
    function positionOf(address user, bytes calldata data)
        public
        view
        override
        returns (address asset, uint256 amount)
    {
        // ⚠ TWO DISCRIMINATORS, NOT ONE. Exactly keeps a FLOATING ERC-4626 book and
        // a separate FIXED book per maturity, and `takeOnBehalf` branches on
        // `maturity` BEFORE it looks at anything else. `_vaultPositionOf` reads the
        // floating book only — which is why the `Full` branch that shares it sits
        // behind `maturity == 0`. Sizing a fixed-maturity exit off the floating
        // ledger would price the fill against a position the item never touches, so
        // refuse it: {IPositionSource} requires a revert, not a plausible number.
        (uint256 op, address vault,, uint256 maturity) = abi.decode(data, (uint8, address, address, uint256));
        if (op != uint256(Op.Withdraw) || maturity != 0) revert BadOp(uint8(op));
        return _vaultPositionOf(vault, user);
    }

    /// @dev The vault read itself, taking the vault address so the internal `Full`
    ///      path can share it — that path has already decoded the blob and cannot
    ///      hand a calldata slice back.
    function _vaultPositionOf(address vault, address user) private view returns (address asset, uint256 amount) {
        return (
            IExactlyMarket(vault).asset(),
            IExactlyMarket(vault).previewRedeem(IExactlyMarket(vault).balanceOf(user))
        );
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
    ///      DOES take custody between the withdraw and the split, which is why the
    ///      floor, the `min(received, amount)` cap and the `requireDelivered` bound
    ///      below are all load-bearing rather than defence-in-depth. A
    ///      stray module balance can never become part of the payout. A position
    ///      smaller than `amount` reverts in the vault — fail closed, no gate.
    function _withdrawFull(address market, address, address onBehalfOf, uint256 amount, address receiver)
        private
    {
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
        // Through the same reader {positionOf} uses, so a fill priced against the
        // position withdraws exactly that number.
        (, uint256 max) = _vaultPositionOf(market, onBehalfOf);
        address asset = IExactlyMarket(market).asset();
        uint256 floor = IERC20(asset).balanceOf(address(this));
        IExactlyMarket(market).withdraw(max, address(this), onBehalfOf);
        uint256 received = IERC20(asset).balanceOf(address(this)) - floor;
        // The lower bound the venue used to enforce. Before the split rewrite the
        // venue call was sized at `amount`, so a short position reverted inside it;
        // now nothing does, and {Core._payInputsToSolver} would bill the shortfall to
        // the MAKER'S WALLET. Safe here and only here: `Full` is full-fill, so
        // `amount` is the signed TOTAL, never a pro-rated slice.
        FullFillGuard.requireDelivered(received, amount);
        SafeTransferLib.safeTransfer(asset, receiver, received < amount ? received : amount);
        if (received > amount) SafeTransferLib.safeTransfer(asset, onBehalfOf, received - amount);
    }
}
