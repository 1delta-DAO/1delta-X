// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
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
//   op = 1 (Withdraw):  data = abi.encode(uint8(1), silo, asset[, BalanceMode])
//     — BalanceMode@96. `Full` ⇒ withdraw the entire position and sweep the
//       excess back to the user (fill-or-kill; only after debt is cleared).
//
contract SiloTakerModule is ITakerModule {
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

    /// @dev Full mode: withdraw the user's entire (liquidity-bounded) position to
    ///      this module, forward the signed `amount` to `receiver`, and sweep the
    ///      excess back to the user — always to `onBehalfOf`, never a caller.
    ///      Measures what actually landed rather than trusting the static `amount`.
    function _withdrawFull(address silo, address asset, address onBehalfOf, uint256 amount, address receiver) private {
        uint256 max = ISilo(silo).maxWithdraw(onBehalfOf);
        uint256 before = IERC20(asset).balanceOf(address(this));
        ISilo(silo).withdraw(max, address(this), onBehalfOf);
        uint256 received = IERC20(asset).balanceOf(address(this)) - before;
        require(received >= amount, "insufficient withdrawn");
        SafeTransferLib.safeTransfer(asset, receiver, amount);
        if (received > amount) SafeTransferLib.safeTransfer(asset, onBehalfOf, received - amount);
    }
}
