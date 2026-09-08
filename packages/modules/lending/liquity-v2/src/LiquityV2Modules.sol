// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {DustHandler} from "@lib/DustHandler.sol";
import {PermitHelper} from "@lib/PermitHelper.sol";
import {ProratedBound} from "@lib/ProratedBound.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

import {
    ICollateralRegistry,
    ILiquityV2BorrowerOperations,
    ILiquityV2TroveManager,
    ITroveNFT,
    LatestTroveData
} from "./interfaces/ILiquityV2.sol";

/// @title LiquityV2TroveAuth
/// @notice The ownership binding for every trove op. Security core of this
///         package; read it before the modules.
///
///  The problem
///  ───────────
///  Liquity authorises the MANAGER, never the beneficiary. `withdrawBold(troveId,
///  …)` checks "is `msg.sender` this trove's remove manager?" and has no parameter
///  that could carry the user the module is acting for. A module is a shared
///  singleton, granted by every user who onboards via
///  `setRemoveManagerWithReceiver(troveId, module, module)` — so that check passes
///  for every trove in the module's victim set.
///
///  Meanwhile Permit3's taker book is keyed by the APPROVER
///  (`_takerAllowance[user][spender][ref]`, `ref = keccak256(data)`), so an
///  attacker can self-approve a `ref` computed over a VICTIM's `troveId` and sign
///  their own order carrying it. `ref` proves the bytes were authorised by
///  someone; it says nothing about who owns the trove named inside them.
///
///  Without the check below that composition is a full drain: the attacker's order
///  names the victim's trove, Permit3's gate passes on the attacker's own
///  allowance, and the module runs `withdrawBold`/`withdrawColl` against the
///  victim's trove with the proceeds forwarded to the attacker. The victim keeps
///  the debt.
///
///  The fix — root the chain at an IMMUTABLE registry
///  ─────────────────────────────────────────────────
///  ⚠ THIS PARAGRAPH REPLACES A PREVIOUS FIX THAT WAS UNSOUND. The chain used to
///  be rooted at a `troveManager` taken from `data`, on the argument that deriving
///  the ownership oracle AND the dispatch target from one address "makes a split
///  impossible: a fabricated root sends the op into attacker-land, where there is
///  no real trove to drain".
///
///  That is false, and `test/unit/ForgedRootAuth.t.sol` proves it. A shared root
///  forces consistency only when the root is TRUSTED. An attacker-deployed root
///  has two independent return statements:
///
///      troveNFT()           -> a puppet that answers `ownerOf(anything) = attacker`
///      borrowerOperations() -> the REAL BorrowerOperations
///
///  The op does not go into attacker-land — it goes to the real protocol, which
///  permits it because this module genuinely IS the victim's registered remove
///  manager. Every trove that onboarded was drainable by anyone, for gas, with no
///  order and no maker signature (Permit3's `approveTaker` lets a caller name
///  itself spender, so `take` is reachable without Settlement).
///
///  The root is now the branch REGISTRY, held as an immutable set at construction:
///
///      troveManager       := collateralRegistry.getTroveManager(branchIndex)   // TRUSTED
///      troveNFT           := troveManager.troveNFT()
///      ownerOf(troveId)   must equal the principal
///      borrowerOperations := troveManager.borrowerOperations()
///
///  `data` now carries a branch INDEX rather than an address, so a caller chooses
///  WHICH branch to act on and cannot invent one. The index occupies the same slot
///  the address did, so every downstream offset (permit blocks included) is
///  unchanged. Registry verified on Ethereum mainnet:
///  0xf949982B91C8c61e952B3bA942cbbfaef5386684, `getTroveManager(0)` =
///  0x7bcb64B2c9206a5B699eD43363f6F98D4776Cf5A (the WETH branch pinned by
///  `test/fork/LiquityV2ForkAuth.t.sol`), `totalCollaterals()` = 3.
///
///  Why not BorrowerOperations as the root: mainnet BorrowerOperations exposes
///  almost no public getters — `troveManager()`, `troveNFT()`, `boldToken()` and
///  `collToken()` all revert.
///
///  Same lesson the 1delta composer learned on Gearbox (`GEARBOX.md` rows A2/A3).
///  Note {GearboxCreditAuth} survives the same attack for a DIFFERENT reason: its
///  caller-supplied `creditAccount` is also the dispatch PARAMETER, so the real
///  facade re-validates it. Where the oracle and the dispatch target can decouple,
///  a caller-supplied root is never sufficient — it must be an immutable.
library LiquityV2TroveAuth {
    /// @dev The Permit3 principal does not own `troveId`.
    error InvalidCaller();
    /// @dev `branchIndex` names no branch the immutable registry knows.
    error UnknownBranch();

    /// @param registry    the IMMUTABLE branch registry, fixed at construction —
    ///                    the trusted root. NEVER take this from `data`.
    /// @param branchIndex which branch to act on, from the maker-signed `data`
    /// @param troveId     the position, as an ERC-721 token id
    /// @param principal   the user whose Permit3 allowance funds this op
    ///                    (`onBehalfOf` — always `order.maker` from Settlement)
    /// @return borrowerOps  the derived branch entrypoint to dispatch the op to
    /// @return troveManager the resolved branch manager, returned so a caller that
    ///                      needs it (the debt read on the repay leg) uses THIS
    ///                      trusted resolution rather than re-deriving its own
    function authorizeTrove(address registry, uint256 branchIndex, uint256 troveId, address principal)
        internal
        view
        returns (address borrowerOps, address troveManager)
    {
        // The caller picks WHICH branch; it cannot invent one. This single line is
        // what the whole binding rests on — see the header for the forged-root
        // attack it replaces.
        troveManager = ICollateralRegistry(registry).getTroveManager(branchIndex);
        if (troveManager == address(0)) revert UnknownBranch();
        address troveNFT = ILiquityV2TroveManager(troveManager).troveNFT();
        // Reverts for a non-existent trove (ERC-721 `ownerOf`), so a fabricated id
        // fails closed instead of resolving to `address(0)`.
        if (ITroveNFT(troveNFT).ownerOf(troveId) != principal) revert InvalidCaller();
        borrowerOps = ILiquityV2TroveManager(troveManager).borrowerOperations();
    }
}

// ════════════════════════════════════════════════════════════════════════════
//  Liquity V2 CDP modules
//
//  Troves are ERC-721 sub-accounts under a per-branch `BorrowerOperations`. The
//  per-trove manager delegation maps directly onto MAKE/TAKE:
//    • the maker grants `setAddManager(troveId, module)` → the module may run the
//      MAKE legs (addColl / repayBold);
//    • the maker grants `setRemoveManagerWithReceiver(troveId, module, module)` →
//      the module may run the TAKE legs (withdrawColl / withdrawBold) with the
//      proceeds routed to the module, which forwards them to the order `receiver`.
//
//  The value-out ops carry no receiver; the module MEASURES what actually landed
//  (robust to a mis-set receiver — reverts cleanly if the grant is missing) and
//  forwards exactly `amount`, sweeping any excess to the maker. `troveId` and the
//  branch contracts are maker-signed in `data`.
// ════════════════════════════════════════════════════════════════════════════

// ──────────────────── Liquity V2 add-collateral maker module ────────────────────
//
// Pulls collateral via Permit3 and adds it to the user's trove (needs the
// add-manager grant). `data = abi.encode(branchIndex, troveId, collateralToken[, deadline, v, r, s])`
//   — base = 96. BREAKING: the leading word is a branch INDEX resolved through the
//   immutable {ICollateralRegistry}, not a caller-supplied TroveManager address.
//   Same slot width, so downstream offsets are unchanged. See {LiquityV2TroveAuth}.
//
contract LiquityV2AddCollModule is IMakerModule {
    IPermit3 public immutable permit3;
    address public immutable settlement;
    /// @dev The trusted branch root. Immutable by construction — see {LiquityV2TroveAuth}.
    address public immutable collateralRegistry;

    error NotSettlement();

    constructor(address _permit3, address _settlement, address _collateralRegistry) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
        collateralRegistry = _collateralRegistry;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();

        (uint256 branchIndex, uint256 troveId, address collateralToken) = abi.decode(data, (uint256, uint256, address));
        // Bind the trove to the payer: without it an attacker could shove a
        // victim's pre-approved collateral into a trove of the attacker's choosing.
        // Both the oracle and `borrowerOps` derive from the IMMUTABLE registry.
        (address borrowerOps,) = LiquityV2TroveAuth.authorizeTrove(collateralRegistry, branchIndex, troveId, onBehalfOf);

        PermitHelper.replayIfPresent(data, 96, collateralToken, onBehalfOf, address(permit3), amount);

        // Balance held BEFORE the operation. Sweeping `balanceOf(this)` outright
        // would pay out anything already stranded at this shared module, and anyone
        // can be the maker of a one-unit order against it. "The module ends where it
        // started", not "ends empty" — F19 / F25 G-1.
        uint256 floor = IERC20(collateralToken).balanceOf(address(this));
        permit3.transferFrom(onBehalfOf, address(this), collateralToken, uint160(amount));
        SafeTransferLib.forceApprove(collateralToken, borrowerOps, amount);
        ILiquityV2BorrowerOperations(borrowerOps).addColl(troveId, amount);

        // End holding nothing and granting nothing: a standing allowance on this
        // shared module would be a claim on any future balance it holds.
        SafeTransferLib.forceApprove(collateralToken, borrowerOps, 0);
        uint256 bal = IERC20(collateralToken).balanceOf(address(this));
        if (bal > floor) SafeTransferLib.safeTransfer(collateralToken, onBehalfOf, bal - floor);
    }
}

// ──────────────────── Liquity V2 repay maker module ────────────────────
//
// Partial repay of the trove's BOLD debt (repay is free — no upfront fee, no
// approval; BOLD is a privileged burn). Reads the live debt and repays
// `min(amount, debt)`. BOLD is pulled to the module and burned by
// BorrowerOperations; any residual is swept back to the maker. A full close is
// `closeTrove`, wired separately.
//
// `nonReentrant` guards weird-token transfer hooks.
// `data = abi.encode(branchIndex, troveId, boldToken)` — base = 96.
// (BREAKING: the leading word is a branch INDEX resolved through the immutable
// {ICollateralRegistry}. The debt read, the repay and the ownership check all
// derive from that trusted root. See {LiquityV2TroveAuth}.)
//
contract LiquityV2RepayModule is IMakerModule {
    IPermit3 public immutable permit3;
    address public immutable settlement;
    /// @dev The trusted branch root. Immutable by construction — see {LiquityV2TroveAuth}.
    address public immutable collateralRegistry;

    uint256 private _locked = 1;

    error Reentrancy();
    error NotSettlement();

    constructor(address _permit3, address _settlement, address _collateralRegistry) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
        collateralRegistry = _collateralRegistry;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();
        if (_locked != 1) revert Reentrancy();
        _locked = 2;

        (uint256 branchIndex, uint256 troveId, address boldToken) = abi.decode(data, (uint256, uint256, address));
        // `borrowerOps` is DERIVED (it used to be a second calldata field), so the
        // debt read, the repay and the ownership check all share one root.
        (address borrowerOps, address troveManager) =
            LiquityV2TroveAuth.authorizeTrove(collateralRegistry, branchIndex, troveId, onBehalfOf);

        // Balance held BEFORE the pull. Sweeping `balanceOf(this)` outright would pay
        // out anything already stranded at this shared module address, and anyone can
        // be the maker of a one-unit order against it — so a stray balance would be
        // claimable by whoever fills next. The invariant is "the module ends where it
        // started", not "ends empty" (F19; {DustHandler.disposeResidual}'s floor).
        uint256 floor = IERC20(boldToken).balanceOf(address(this));
        LatestTroveData memory d = ILiquityV2TroveManager(troveManager).getLatestTroveData(troveId);
        uint256 toRepay = amount < d.entireDebt ? amount : d.entireDebt;

        if (toRepay > 0) {
            permit3.transferFrom(onBehalfOf, address(this), boldToken, uint160(toRepay));
            // BOLD needs no ERC20 approval (BorrowerOperations burns it directly).
            ILiquityV2BorrowerOperations(borrowerOps).repayBold(troveId, toRepay);
        }

        uint256 bal = IERC20(boldToken).balanceOf(address(this));
        if (bal > floor) SafeTransferLib.safeTransfer(boldToken, onBehalfOf, bal - floor);

        _locked = 1;
    }
}

// ──────────────────── Liquity V2 combined taker module ────────────────────
//
// Fuses borrow (`withdrawBold`) and collateral-withdraw (`withdrawColl`) behind a
// leading `op` flag. With `setRemoveManagerWithReceiver(troveId, module, module)`
// the proceeds land on this module; it forwards exactly `amount` to `receiver`
// and sweeps any excess to the maker. Borrow-data and withdraw-data hash to
// different taker refs (separate amount-gated allowances).
//
//   op = 0 (Borrow):       data = abi.encode(uint8(0), branchIndex, troveId, boldToken, maxUpfrontFee, totalAmount)
//   op = 1 (WithdrawColl):  data = abi.encode(uint8(1), branchIndex, troveId, collateralToken)
//
// BREAKING (F26): the borrow leg carries a MANDATORY `totalAmount@160` — the item's
// full maker-signed amount. `maxUpfrontFee` is an absolute BOLD ceiling sized for
// the whole borrow, and the FILLER chooses the slice count, so passing it unscaled
// multiplied the maker's signed fee tolerance by N. See {ProratedBound}.
//
// BREAKING: the second word is a branch INDEX resolved through the immutable
// {ICollateralRegistry}, not a caller-supplied address. See {LiquityV2TroveAuth}
// for the forged-root attack this replaces.
//
contract LiquityV2TakerModule is ITakerModule {
    IPermit3 public immutable permit3;
    /// @dev The trusted branch root. Immutable by construction — see {LiquityV2TroveAuth}.
    address public immutable collateralRegistry;

    enum Op {
        Borrow, // 0
        WithdrawColl // 1
    }

    error OnlyPermit3();
    error BadOp(uint8 op);

    constructor(address _permit3, address _collateralRegistry) {
        permit3 = IPermit3(_permit3);
        collateralRegistry = _collateralRegistry;
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        uint8 op = uint8(uint256(bytes32(data[:32])));

        if (op == uint8(Op.Borrow)) {
            (, uint256 branchIndex, uint256 troveId, address boldToken, uint256 maxUpfrontFee, uint256 totalAmount) =
                abi.decode(data, (uint8, uint256, uint256, address, uint256, uint256));
            // Scale the absolute fee ceiling with the slice — unscaled it bounded a
            // 1/N borrow by the WHOLE order's tolerance. See {ProratedBound}.
            maxUpfrontFee = ProratedBound.scale(maxUpfrontFee, amount, totalAmount);
            // The value-OUT legs are what an attacker wants. Liquity will happily
            // authorise this module against ANY trove that granted it the remove-
            // manager role, so this check is the only thing standing between a
            // maker's trove and any filler who knows its id.
            (address borrowerOps,) = LiquityV2TroveAuth.authorizeTrove(collateralRegistry, branchIndex, troveId, onBehalfOf);
            _withdrawAndForward(boldToken, onBehalfOf, amount, receiver, borrowerOps, troveId, maxUpfrontFee, true);
        } else if (op == uint8(Op.WithdrawColl)) {
            (, uint256 branchIndex, uint256 troveId, address collateralToken) =
                abi.decode(data, (uint8, uint256, uint256, address));
            (address borrowerOps,) =
                LiquityV2TroveAuth.authorizeTrove(collateralRegistry, branchIndex, troveId, onBehalfOf);
            _withdrawAndForward(collateralToken, onBehalfOf, amount, receiver, borrowerOps, troveId, 0, false);
        } else {
            revert BadOp(op);
        }
    }

    /// @dev Run the value-out op (proceeds → this module via the remove-manager
    ///      receiver), then forward exactly `amount` to `receiver` and sweep the
    ///      excess to the maker. Measuring the delta reverts cleanly if the
    ///      remove-manager grant is missing (nothing landed).
    function _withdrawAndForward(
        address token,
        address onBehalfOf,
        uint256 amount,
        address receiver,
        address borrowerOps,
        uint256 troveId,
        uint256 maxUpfrontFee,
        bool isBorrow
    ) private {
        uint256 before = IERC20(token).balanceOf(address(this));
        if (isBorrow) {
            ILiquityV2BorrowerOperations(borrowerOps).withdrawBold(troveId, amount, maxUpfrontFee);
        } else {
            ILiquityV2BorrowerOperations(borrowerOps).withdrawColl(troveId, amount);
        }
        uint256 received = IERC20(token).balanceOf(address(this)) - before;
        require(received >= amount, "proceeds not received");
        SafeTransferLib.safeTransfer(token, receiver, amount);
        if (received > amount) SafeTransferLib.safeTransfer(token, onBehalfOf, received - amount);
    }
}
