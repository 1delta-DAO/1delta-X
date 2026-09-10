// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IFundingSource} from "@core/interfaces/IFundingSource.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {DelegationHelper} from "@lib/DelegationHelper.sol";
import {DustHandler} from "@lib/DustHandler.sol";
import {PermitHelper} from "@lib/PermitHelper.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";

import {IListaBroker} from "./interfaces/ILista.sol";

// ════════════════════════════════════════════════════════════════════════════
//  Lista LendingBroker — ONE module for the whole broker surface
//
//  Lista splits its lending stack in two: COLLATERAL lives in the Moolah
//  singleton (a Morpho Blue fork) and DEBT lives in a `LendingBroker`. The
//  Moolah half is served by {ListaSupplyCollateralModule} / {ListaTakerModule};
//  this contract is the broker half, all of it:
//
//    MAKE  op 0  Repay   — value-in.  Pull-funded OR pre-funded (see below).
//    TAKE  op 1  Borrow  — value-out. Fixed-term, forwarded to `receiver`.
//
//  Why one contract
//  ────────────────
//  The broker repay branch used to be written TWICE — once on a pull-funded
//  maker module and once inside the pre-funded sibling — and it drifted: the
//  `repayAll` full-close sentinel landed on the pull twin and not on the
//  pre-funded one, so a maker signing the documented sentinel handed the broker
//  `type(uint256).max` as a LITERAL fixed-position id. That is the standing
//  "patch hit one sibling, missed the neighbour" failure. {PreFundModuleBase}
//  already carries the discriminator that makes the duplication unnecessary
//  ({_fundingShape}, bit 253 of the maker-signed descriptor — the SAME bit the
//  core reads in {Base._forSlice}), so the two funding shapes now share one
//  body and can no longer disagree about what a `loanId` means.
//
//  The two seams in one contract, and why that is safe
//  ───────────────────────────────────────────────────
//  `makeOnBehalf` is dispatched by Settlement DIRECTLY and spends the Permit3
//  TOKEN book; `takeOnBehalf` is dispatched by Permit3 and spends the TAKER
//  book. They are different books, so unlike the `take`/`takeFor` pair (I-3)
//  no single grant can be ambiguous between them. The op word makes it
//  structurally impossible anyway: each entrypoint asserts its OWN op and
//  reverts {BadOp} on the other's, so a borrow blob cannot be executed as a
//  repay or vice versa, and the op rides inside `keccak256(data)` — the maker's
//  order signature and their taker grant both bind it.
//
//  Data layouts
//  ────────────
//    MAKE, pull-funded:
//      `abi.encode(uint8(Op.Repay), broker, loanToken, loanId
//                  [, DustAction[, deadline, v, r, s]])`
//      — base = 128; DustAction@128; EIP-2612 permit@160.
//      Word 0 is a `uint8` op, so `>> 253 == 0`: never mistaken for a
//      descriptor by {Base._isPreFundDesc} or by {_fundingShape} below.
//
//    MAKE, pre-funded:
//      `abi.encode(forDesc, broker, loanToken, loanId)` — 128 bytes.
//      Word 0 is the leg-reference descriptor (`>> 253 == 5`); the op rides in
//      its bits [244,252) and must be `Op.Repay`. Leg-reference ONLY: a LITERAL
//      descriptor would instruct an amount this module has no delivery for, and
//      a BALANCE descriptor reads the MAKER's wallet while this module funds
//      from its own — {_gatePreFundMake} rejects both.
//
//    TAKE (borrow):
//      `abi.encode(uint8(Op.Borrow), broker, termId
//                  [, moolah, nonce, deadline, v, r, s])`
//      — base = 96; optional signature-only Moolah grant with moolah@96 and the
//      standard 160-byte {DelegationHelper.replayMorphoAuth} block @128 (total
//      288). The base carries no moolah word because the borrow itself routes
//      through the broker, so the tail prefixes it. Verified on the deployed BSC
//      Moolah: `setAuthorizationWithSig` is byte-identical to Morpho Blue's
//      (typehash, struct, `Signature` tuple, sequential `nonce(address)`,
//      Morpho's chainId+contract domain scheme — only the domain VIEW is renamed
//      `domainSeparator()`), so the Morpho helper is reused unchanged. Everything
//      in the tail is maker-signed via `data`; a wrong moolah address just makes
//      the best-effort replay a no-op.
//
//  Repay semantics (identical on both funding shapes)
//  ──────────────────────────────────────────────────
//  The broker `transferFrom`s the LITERAL amount, consumes up to the live debt
//  (interest-first, early-repay penalty included) and refunds the surplus to its
//  caller — i.e. back here — which is then swept to the maker. NOT `repay(0, …)`:
//  every deployed broker reverts `ZeroAmount()` on a zero amount (source-verified
//  on the chain-1 impl 0x63fa…96f0 and fork-measured on BSC; there is no
//  "0 = repay from balance" convention on the broker).
//
//    `loanId == type(uint128).max` → the DYNAMIC (flex) position.
//    `loanId == type(uint256).max` → `repayAll`: the dynamic position AND every
//        fixed one, BY SHARES, so no dust remains and the refinance-bot race
//        cannot leave a stub behind. `repayAll` pulls EXACTLY the live total debt
//        (no refund), capped by the scoped approval at the signed ceiling — so a
//        ceiling short of the live debt fails closed inside the broker's
//        `transferFrom` and the un-pulled remainder sweeps back to the maker.
//    anything else → that fixed position. Fixed posIds are small sequential
//        uuids, so neither sentinel can collide with one.
//
//  Only the FIXED-term broker borrow is delegable; the flex borrow is
//  `msg.sender`-only and out of scope. All broker/term/loan identifiers are
//  maker-signed in `data`.
// ════════════════════════════════════════════════════════════════════════════
contract ListaBrokerModule is PreFundModuleBase, IMakerModule, IFundingSource, ITakerModule {
    /// @dev Ops are numbered ACROSS both seams, not per-seam, and each entrypoint
    ///      asserts its own. That is what keeps the MAKE and TAKE data spaces
    ///      disjoint on a contract that hosts both.
    enum Op {
        Repay, // 0 — MAKE (value-in)
        Borrow // 1 — TAKE (value-out)
    }

    /// @dev Sentinel `loanId` meaning "the broker's dynamic (flex) position".
    uint256 private constant DYNAMIC_LOAN = type(uint128).max;
    /// @dev Full-close sentinel — maps to `repayAll(onBehalf)`.
    uint256 private constant REPAY_ALL = type(uint256).max;

    uint256 private _locked = 1;

    error Reentrancy();
    /// @dev The blob named an op this entrypoint does not serve.
    error BadOp(uint256 op);

    constructor(address _permit3, address _settlement) PreFundModuleBase(_permit3, _settlement) {}

    // ──────────────────── MAKE: broker repay ────────────────────

    /// @notice Retire up to `amount` of the maker's broker debt.
    /// @param onBehalfOf the maker — whose debt this fill retires.
    /// @param amount     pull-funded: the maker-signed ceiling, pro-rated by the
    ///                   fill. Pre-funded: this fill's delivered output leg,
    ///                   core-sized ({Base._forSlice} → {Pricing.outputAt}).
    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;

        if (_fundingShape(data)) {
            // Folds the `msg.sender == settlement` pin and the leg-reference
            // descriptor check. The op lives in the descriptor the maker signed.
            _gatePreFundMake(data);
            uint256 op = _preFundOp(data);
            if (op != uint256(Op.Repay)) revert BadOp(op);
            // A dust slice can floor the funding leg to zero; skip, as every
            // composite module does — it accumulates exactly across fills.
            if (amount != 0) _repayPreFunded(onBehalfOf, amount, data);
        } else {
            PreFundGuard.requireSettlement(msg.sender, settlement);
            _repayPull(onBehalfOf, amount, data);
        }

        _locked = 1;
    }

    /// @dev PULL shape: the funds come out of the maker's wallet through Permit3,
    ///      so the ceiling is the Permit3 token allowance and the module ends
    ///      holding nothing it did not start with.
    function _repayPull(address onBehalfOf, uint256 amount, bytes calldata data) private {
        uint256 op = _word0(data);
        if (op != uint256(Op.Repay)) revert BadOp(op);
        (, address broker, address loanToken, uint256 loanId) =
            abi.decode(data, (uint256, address, address, uint256));

        DustHandler.DustAction action = DustHandler.readAction(data, 128);
        PermitHelper.replayIfPresent(data, 160, loanToken, onBehalfOf, address(permit3), amount);

        // Balance held BEFORE the pull. Sweeping `balanceOf(this)` outright would
        // pay out anything already stranded at this shared module address, and
        // anyone can be the maker of a one-unit order against it — so a stray
        // balance would be claimable by whoever fills next. The invariant is "the
        // module ends where it started", not "ends empty" (F19; the floor overload
        // of {DustHandler.disposeResidual}).
        uint256 floor = IERC20(loanToken).balanceOf(address(this));
        if (amount > 0) {
            permit3.transferFrom(onBehalfOf, address(this), loanToken, uint160(amount));
            _brokerRepay(broker, loanToken, loanId, onBehalfOf, amount);
        }

        uint256 bal = IERC20(loanToken).balanceOf(address(this));
        if (bal > floor) SafeTransferLib.safeTransfer(loanToken, onBehalfOf, bal - floor);
        // (action reserved for a future in-position recycle; the broker has no
        //  re-supply target, so the residual always sweeps to the user.)
        action;
    }

    /// @dev PRE-FUND shape: the funds are already HERE, delivered by this fill's
    ///      own output leg, so there is no pull — only a floor and a sweep.
    function _repayPreFunded(address onBehalfOf, uint256 forAmount, bytes calldata data) private {
        (, address broker, address loanToken, uint256 loanId) =
            abi.decode(data, (uint256, address, address, uint256));

        // The pre-existing floor — see {PreFundGuard}. A funding leg not addressed
        // to THIS module in THIS token underflows here, so the mis-pairing fails
        // closed; sound because `msg.sender == settlement` pins `forAmount` to the
        // core (F27/C-1, C-4). No extra token-binding argument is needed: the
        // broker pulls through the scoped approval below, so the token it takes and
        // the token measured here are the same by construction. (H-2 is specific to
        // a venue that moves value WITHOUT an approval.)
        uint256 floor = PreFundGuard.floorOf(data, loanToken, forAmount);
        _brokerRepay(broker, loanToken, loanId, onBehalfOf, forAmount);
        // The delivered surplus belongs to the maker, not to this singleton.
        PreFundGuard.sweepSurplus(loanToken, onBehalfOf, floor);
    }

    /// @dev The one place the broker's repay ABI is expressed. Both funding shapes
    ///      reach it with the same three-way `loanId` meaning, which is the point
    ///      of merging them — see the header.
    ///
    ///      Scoped approve + CLEAR, not a standing grant: `broker` is decoded from
    ///      the order's `data` on a SHARED singleton, so it is attacker-choosable —
    ///      anyone can author an order naming themselves as maker. A target
    ///      consuming less than approved would leave a standing third-party claim on
    ///      any FUTURE balance of this module, which is what turns a later
    ///      stranded-balance bug into a theft. {SafeTransferLib.ensureApproval}
    ///      forbids this shape. F25 / F26/2c / lead A-3.
    ///
    ///      The approval is ALSO the cap on `repayAll`, which takes no amount.
    function _brokerRepay(address broker, address loanToken, uint256 loanId, address onBehalfOf, uint256 amount)
        private
    {
        SafeTransferLib.forceApprove(loanToken, broker, amount);
        if (loanId == REPAY_ALL) {
            IListaBroker(broker).repayAll(onBehalfOf);
        } else if (loanId == DYNAMIC_LOAN) {
            IListaBroker(broker).repay(amount, onBehalfOf);
        } else {
            IListaBroker(broker).repay(amount, loanId, onBehalfOf);
        }
        SafeTransferLib.forceApprove(loanToken, broker, 0);
    }

    /// @dev Word 0 as a plain integer, length-guarded.
    ///
    ///      Read BEFORE any `abi.decode`, and that ordering is the whole point: a
    ///      blob addressed to the WRONG seam has the wrong length and the wrong
    ///      field widths, so a decode-first version dies inside ABI validation
    ///      with EMPTY returndata — no selector, no op, nothing telling the caller
    ///      they hit the other entrypoint. Reading the discriminator first turns
    ///      every one of those into a named {BadOp}, which is also what makes the
    ///      op wall between the two seams testable rather than incidental.
    ///
    ///      Decoding the op field as `uint256` rather than `uint8` is part of the
    ///      same choice: `uint8` makes the decoder reject a dirty high word before
    ///      this check can name it.
    function _word0(bytes calldata data) private pure returns (uint256 w) {
        /// @solidity memory-safe-assembly
        assembly {
            w := mul(gt(data.length, 31), calldataload(data.offset))
        }
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
        (,, asset,) = abi.decode(data, (uint256, address, address, uint256));
        available = type(uint256).max;
    }

    // ──────────────────── TAKE: fixed-term broker borrow ────────────────────

    /// @notice Draw a fixed-term broker loan on the maker's behalf, paid to `receiver`.
    /// @dev The broker's on-behalf borrow is gated by the maker's Moolah
    ///      authorization of THIS module; the Permit3 taker allowance on
    ///      `keccak256(data)` caps the amount.
    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        // Pins the hub AND the plain-take half of the data space, so no
        // pre-funded repay blob can be executed through this entrypoint.
        _gateTake(data);

        uint256 op = _word0(data);
        if (op != uint256(Op.Borrow)) revert BadOp(op);
        (, address broker, uint256 termId) = abi.decode(data, (uint256, address, uint256));

        // Optional signature-only Moolah grant (see the header byte map):
        // maker-signed moolah@96, auth block@128.
        if (data.length >= 288) {
            address moolah = abi.decode(data[96:128], (address));
            DelegationHelper.replayMorphoAuth(data, 128, moolah, onBehalfOf, address(this));
        }
        IListaBroker(broker).borrow(amount, termId, onBehalfOf, receiver);
    }
}
