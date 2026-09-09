// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {IPositionSource} from "@core/interfaces/IPositionSource.sol";
import {DustHandler} from "@lib/DustHandler.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";
import {PermitHelper} from "@lib/PermitHelper.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

import {ISilo} from "./interfaces/ISilo.sol";

// ════════════════════════════════════════════════════════════════════════════
//  Silo v2 (ERC-4626 + borrow extension) modules
//
//  Each Silo is an ERC-4626 vault for one asset; a market pairs two of them. The
//  single-op modules drive the common Collateral leg:
//
//    deposit / repay  → value-in  (MAKE): the module funds the silo (Permit3 pull)
//    borrow  / withdraw → value-out (TAKE): forwarded straight to `receiver`
//
//  Authorisation splits by direction, exactly like Aave:
//    • deposit / repay — permissionless value-in, no grant.
//    • borrow  — the maker grants the module a debt-share *receive allowance*
//                (`setReceiveApproval(module, cap)`); Silo's own solvency check +
//                the Permit3 taker allowance bound the fill.
//    • withdraw — the maker grants the module a standing ERC-4626 share allowance
//                (`silo.approve(module, max)`); the Permit3 taker allowance bounds
//                the fill.
//
//  `silo`/`asset` are maker-signed (pinned into the order hash / taker ref), so
//  the solver cannot repoint which silo or asset is touched.
// ════════════════════════════════════════════════════════════════════════════

// ──────────────────── Silo v2 deposit maker module ────────────────────
//
// Pulls `asset` from the user via Permit3 and supplies it as Collateral into
// `silo` on the user's behalf. Optional EIP-2612 permit replay for gasless
// deposits. `data = abi.encode(silo, asset[, deadline, v, r, s])` — base = 64.
//
contract SiloDepositModule is IMakerModule {
    IPermit3 public immutable permit3;
    address public immutable settlement;

    error NotSettlement();

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();

        (address silo, address asset) = abi.decode(data, (address, address));

        // Optional permit: approves Permit3 at ERC-20 level. base = 64 bytes.
        PermitHelper.replayIfPresent(data, 64, asset, onBehalfOf, address(permit3), amount);

        permit3.transferFrom(onBehalfOf, address(this), asset, uint160(amount));
        SafeTransferLib.forceApprove(asset, silo, amount);
        ISilo(silo).deposit(amount, onBehalfOf);
        // Clear the scoped grant: `silo` is decoded from the order's `data` on a
        // SHARED singleton, so it is attacker-choosable — anyone can author an
        // order naming themselves as maker. A target that consumes less than
        // approved would leave a standing third-party claim on any FUTURE balance
        // of this module, which is what turns a later stranded-balance bug into a
        // theft. {SafeTransferLib.ensureApproval} forbids this shape. F25 / A-3.
        SafeTransferLib.forceApprove(asset, silo, 0);
    }
}

// ──────────────────── Silo v2 repay maker module ────────────────────
//
// Closes the user's borrow in `silo`, handling interest-accrual over-repay with a
// pull-exact strategy: read the live debt (`maxRepay`) and repay
// `min(amount, debt)`. SweepToUser pulls only what the debt needs, so the
// over-repay buffer never enters this contract (the "stray dust a caller can
// redirect" vector is removed at the source). Recycle takes the full signed
// ceiling, repays, and re-supplies the surplus as a Collateral balance into the
// same silo — best-effort with a guaranteed sweep fallback.
//
// `nonReentrant` guards weird-token transfer hooks.
// `data = abi.encode(silo, asset[, DustHandler.DustAction[, deadline, v, r, s]])`.
//
contract SiloRepayModule is IMakerModule {
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

        (address silo, address asset) = abi.decode(data, (address, address));
        // base = (address,address) = 64 bytes; DustAction at 64, permit at 96.
        DustHandler.DustAction action = DustHandler.readAction(data, 64);
        PermitHelper.replayIfPresent(data, 96, asset, onBehalfOf, address(permit3), amount);

        // The balance this module held BEFORE the pull. Everything below disposes of
        // the DELTA over it, never the whole balance: a module address can be sent
        // tokens by anyone, and "sweep everything to the user" pays that to whoever
        // happens to be filling. See the floor overload of {DustHandler.disposeResidual}.
        uint256 floor = IERC20(asset).balanceOf(address(this));

        _pullAndRepay(silo, asset, amount, onBehalfOf, action == DustHandler.DustAction.Recycle);
        _disposeResidual(silo, asset, onBehalfOf, action, floor);

        _locked = 1;
    }

    /// @dev SweepToUser pulls only `toRepay`; Recycle pulls the full ceiling so
    ///      the surplus can be redirected into the user's position.
    function _pullAndRepay(address silo, address asset, uint256 amount, address onBehalfOf, bool recycle) private {
        uint256 debt = ISilo(silo).maxRepay(onBehalfOf);
        uint256 toRepay = amount < debt ? amount : debt;

        uint256 toPull = recycle ? amount : toRepay;
        if (toPull > 0) permit3.transferFrom(onBehalfOf, address(this), asset, uint160(toPull));

        if (toRepay > 0) {
            SafeTransferLib.forceApprove(asset, silo, toRepay);
            ISilo(silo).repay(toRepay, onBehalfOf);
            // Clear the scoped grant: `silo` is decoded from the order's `data` on a
            // SHARED singleton, so it is attacker-choosable — anyone can author an
            // order naming themselves as maker. A target that consumes less than
            // approved would leave a standing third-party claim on any FUTURE balance
            // of this module, which is what turns a later stranded-balance bug into a
            // theft. {SafeTransferLib.ensureApproval} forbids this shape. F25 / A-3.
            SafeTransferLib.forceApprove(asset, silo, 0);
        }
    }

    /// @dev Re-supply (opt-in) the residual as a Collateral balance in the same
    ///      silo, else sweep to the user. Best-effort recycle with a guaranteed
    ///      sweep floor.
    function _disposeResidual(
        address silo,
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
        DustHandler.disposeResidual(
            asset,
            residual,
            floor,
            onBehalfOf,
            action,
            silo,
            // `deposit` is overloaded → address it by explicit signature.
            abi.encodeWithSignature("deposit(uint256,address)", residual, onBehalfOf)
        );
    }
}

// ──────────────────── Silo v2 combined taker module ────────────────────
//
// Fuses the borrow and withdraw value-out legs into a SINGLE contract behind a
// leading `op` flag, so the full leverage round-trip authorises ONE module
// address. Safety is unchanged from split modules: the Permit3 taker allowance is
// keyed by `ref = keccak256(data)`, and `op` is the first word, so borrow-data
// and withdraw-data hash to DIFFERENT refs — a separate amount-gated allowance
// per leg. The per-leg protocol grants (debt-share receive allowance for borrow,
// share allowance for withdraw) are per-address by construction.
//
//   base: op@0, silo@32, asset@64 (base length 96)
//   op = 0 (Borrow):    data = abi.encode(uint8(0), silo, asset)
//   op = 1 (Withdraw):  data = abi.encode(uint8(1), silo, asset[, BalanceMode[, total]])
//     — BalanceMode@96. `Full` ⇒ withdraw the entire position and sweep the
//       excess back to the user (fill-or-kill; only after debt is cleared).
//     — total@128, and MANDATORY whenever the mode is `Full`: the maker-signed
//       full item amount, which {FullFillGuard.requireFullFillFromData} compares
//       the slice against. It FAILS CLOSED when the word is absent, so a `Full`
//       order encoded from a map that omits it is one no filler can ever settle.
//       (Undeclared here until now — the same drift F25/A-2 corrected on
//       {AaveV3WithdrawModule}.)
//
contract SiloTakerModule is ITakerModule, IPositionSource {
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
        (uint256 op, address vault) = abi.decode(data, (uint8, address));
        if (op != uint256(Op.Withdraw)) revert BadOp(uint8(op));
        return _vaultPositionOf(vault, user);
    }

    /// @dev The vault read itself, taking the vault address so the internal `Full`
    ///      path can share it — that path has already decoded the blob and cannot
    ///      hand a calldata slice back.
    function _vaultPositionOf(address vault, address user) private view returns (address asset, uint256 amount) {
        return (ISilo(vault).asset(), ISilo(vault).maxWithdraw(user));
    }

    error OnlyPermit3();
    error BadOp(uint8 op);

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        // op@0, silo@32, asset@64 — all static, so a prefix decode is sound.
        (uint8 op, address silo, address asset) = abi.decode(data, (uint8, address, address));

        if (op == uint8(Op.Borrow)) {
            // Debt lands on the maker; proceeds go straight to `receiver`.
            ISilo(silo).borrow(amount, receiver, onBehalfOf);
        } else if (op == uint8(Op.Withdraw)) {
            if (DustHandler.readBalanceMode(data, 96) == DustHandler.BalanceMode.Full) {
                // `Full` liquidates the user's ENTIRE live balance, so it cannot be
                // pro-rated — a sliced fill would unwind the whole position and brick
                // the rest of the order. Require the slice to be the whole item.
                FullFillGuard.requireFullFillFromData(data, 128, amount);
                _withdrawFull(silo, asset, onBehalfOf, amount, receiver);
            } else {
                // ERC-4626 owner allowance: burns the maker's shares, sends to receiver.
                ISilo(silo).withdraw(amount, receiver, onBehalfOf);
            }
        } else {
            revert BadOp(op);
        }
    }

    /// @dev Full mode: unwind the user's entire (liquidity-bounded) position with
    ///      EXACT amounts sent straight to their destinations — the signed `amount`
    ///      to `receiver`, the remainder back to `onBehalfOf`. ERC-4626 `withdraw`
    ///      burns the OWNER's shares and pays `receiver` directly, so the module
    ///      never takes custody: no delta measurement, no split transfers, and a
    ///      stray module balance can never become part of the payout. A position
    ///      smaller than `amount` makes the first call revert in the vault — fail
    ///      closed, no gate needed.
    function _withdrawFull(address silo, address, address onBehalfOf, uint256 amount, address receiver) private {
        // Through {positionOf}, so the number a fill is priced against and the
        // number this branch withdraws are the same function.
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
        (, uint256 max) = _vaultPositionOf(silo, onBehalfOf);
        address asset = ISilo(silo).asset();
        uint256 floor = IERC20(asset).balanceOf(address(this));
        ISilo(silo).withdraw(max, address(this), onBehalfOf);
        uint256 received = IERC20(asset).balanceOf(address(this)) - floor;
        SafeTransferLib.safeTransfer(asset, receiver, received < amount ? received : amount);
        if (received > amount) SafeTransferLib.safeTransfer(asset, onBehalfOf, received - amount);
    }
}
