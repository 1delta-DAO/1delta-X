// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {DustHandler} from "@lib/DustHandler.sol";
import {PermitHelper} from "@lib/PermitHelper.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

import {
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
///  The fix — root the chain at `troveManager`
///  ──────────────────────────────────────────
///  `troveId` is a bare uint256 and proves nothing on its own, so ONE contract
///  address has to come from `data`. Everything else — the ownership oracle AND
///  the dispatch target — is derived from it:
///
///      troveNFT          := troveManager.troveNFT()
///      ownerOf(troveId)  must equal the principal
///      borrowerOperations := troveManager.borrowerOperations()
///
///  The shared root is the load-bearing part. Taking the TroveNFT from `data`
///  instead would let an attacker pair a lying NFT contract with the REAL
///  `borrowerOperations`, so the check would read attacker-controlled state while
///  the withdrawal hit the victim's real trove. Deriving both from one address
///  makes that split impossible: a fabricated root sends the op into attacker-land,
///  where there is no real trove to drain.
///
///  Why the root is the TroveManager and not BorrowerOperations (which is what is
///  actually dispatched to): mainnet BorrowerOperations exposes almost no public
///  getters — `troveManager()`, `troveNFT()`, `boldToken()` and `collToken()` all
///  revert. The TroveManager exposes both `troveNFT()` and `borrowerOperations()`,
///  so it is the only viable root. Verified on Ethereum mainnet against the WETH
///  branch (TroveManager 0x7bcb64B2c9206a5B699eD43363f6F98D4776Cf5A) and pinned by
///  `test/fork/LiquityV2ForkAuth.t.sol`.
///
///  Same lesson the 1delta composer learned on Gearbox (`GEARBOX.md` rows A2/A3)
///  and the same shape as {GearboxCreditAuth}. Do not reintroduce a second
///  caller-supplied address on this path.
library LiquityV2TroveAuth {
    /// @dev The Permit3 principal does not own `troveId`.
    error InvalidCaller();

    /// @param troveManager the branch manager — the single caller-supplied root
    /// @param troveId      the position, as an ERC-721 token id
    /// @param principal    the user whose Permit3 allowance funds this op
    ///                     (`onBehalfOf` — always `order.maker` from Settlement)
    /// @return borrowerOps the derived branch entrypoint to dispatch the op to
    function authorizeTrove(address troveManager, uint256 troveId, address principal)
        internal
        view
        returns (address borrowerOps)
    {
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
// add-manager grant). `data = abi.encode(troveManager, troveId, collateralToken[, deadline, v, r, s])`
//   — base = 96. BREAKING: the leading address is the TroveManager, not
//   BorrowerOperations (which has no usable getters on mainnet).
//
contract LiquityV2AddCollModule is IMakerModule {
    IPermit3 public immutable permit3;
    address public immutable settlement;

    error NotSettlement();

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();

        (address troveManager, uint256 troveId, address collateralToken) = abi.decode(data, (address, uint256, address));
        // Bind the trove to the payer: without it an attacker could shove a
        // victim's pre-approved collateral into a trove of the attacker's choosing.
        // `borrowerOps` is DERIVED from the same root, never taken from `data`.
        address borrowerOps = LiquityV2TroveAuth.authorizeTrove(troveManager, troveId, onBehalfOf);

        PermitHelper.replayIfPresent(data, 96, collateralToken, onBehalfOf, address(permit3), amount);

        permit3.transferFrom(onBehalfOf, address(this), collateralToken, uint160(amount));
        SafeTransferLib.forceApprove(collateralToken, borrowerOps, amount);
        ILiquityV2BorrowerOperations(borrowerOps).addColl(troveId, amount);

        // End holding nothing and granting nothing: a standing allowance on this
        // shared module would be a claim on any future balance it holds.
        SafeTransferLib.forceApprove(collateralToken, borrowerOps, 0);
        uint256 left = IERC20(collateralToken).balanceOf(address(this));
        if (left != 0) SafeTransferLib.safeTransfer(collateralToken, onBehalfOf, left);
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
// `data = abi.encode(troveManager, troveId, boldToken)` — base = 96.
// (BREAKING vs. the previous 128-byte layout: `borrowerOps` was removed — it is
// now derived from `troveManager`, so the debt read, the repay and the ownership
// check all share one root. See {LiquityV2TroveAuth}.)
//
contract LiquityV2RepayModule is IMakerModule {
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

        (address troveManager, uint256 troveId, address boldToken) = abi.decode(data, (address, uint256, address));
        // `borrowerOps` is DERIVED (it used to be a second calldata field), so the
        // debt read, the repay and the ownership check all share one root.
        address borrowerOps = LiquityV2TroveAuth.authorizeTrove(troveManager, troveId, onBehalfOf);

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
//   op = 0 (Borrow):       data = abi.encode(uint8(0), troveManager, troveId, boldToken, maxUpfrontFee)
//   op = 1 (WithdrawColl):  data = abi.encode(uint8(1), troveManager, troveId, collateralToken)
//
// BREAKING: the leading address is now the TroveManager, not BorrowerOperations —
// BorrowerOperations has no usable getters on mainnet. See {LiquityV2TroveAuth}.
//
contract LiquityV2TakerModule is ITakerModule {
    IPermit3 public immutable permit3;

    enum Op {
        Borrow, // 0
        WithdrawColl // 1
    }

    error OnlyPermit3();
    error BadOp(uint8 op);

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        uint8 op = uint8(uint256(bytes32(data[:32])));

        if (op == uint8(Op.Borrow)) {
            (, address troveManager, uint256 troveId, address boldToken, uint256 maxUpfrontFee) =
                abi.decode(data, (uint8, address, uint256, address, uint256));
            // The value-OUT legs are what an attacker wants. Liquity will happily
            // authorise this module against ANY trove that granted it the remove-
            // manager role, so this check is the only thing standing between a
            // maker's trove and any filler who knows its id.
            address borrowerOps = LiquityV2TroveAuth.authorizeTrove(troveManager, troveId, onBehalfOf);
            _withdrawAndForward(boldToken, onBehalfOf, amount, receiver, borrowerOps, troveId, maxUpfrontFee, true);
        } else if (op == uint8(Op.WithdrawColl)) {
            (, address troveManager, uint256 troveId, address collateralToken) =
                abi.decode(data, (uint8, address, uint256, address));
            address borrowerOps = LiquityV2TroveAuth.authorizeTrove(troveManager, troveId, onBehalfOf);
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
