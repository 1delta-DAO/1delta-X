// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {IPositionSource} from "@core/interfaces/IPositionSource.sol";
import {ITakerForModule} from "@core/interfaces/ITakerForModule.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {IFundingSource} from "@core/interfaces/IFundingSource.sol";
import {IProceedsAsset} from "@core/interfaces/IProceedsAsset.sol";
import {DustHandler} from "@lib/DustHandler.sol";
import {DelegationHelper} from "@lib/DelegationHelper.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";
import {Narrow160} from "@lib/Narrow160.sol";
import {FundingPreflight} from "@lib/FundingPreflight.sol";

import {IEulerVault, IEVC} from "./interfaces/IEulerV2.sol";

// ════════════════════════════════════════════════════════════════════════════
//  Euler V2 (EVK + EVC) modules
//
//  Euler vaults are ERC-4626 + a borrowing extension, fronted by the EVC for
//  authentication and batching. Two facts shape these modules:
//
//   1. A vault pulls/credits the *authenticated account*, not raw `msg.sender`.
//      Called directly, the vault's `callThroughEVC` modifier routes the call so
//      the authenticated account is `msg.sender` — i.e. THIS module. So a
//      module-funded `deposit`/`repay` pulls the underlying from the module (it
//      holds it via a Permit3 pull) while crediting the *user's* position.
//
//   2. Value-out (`borrow`, `withdraw`) must be authenticated as the owner
//      account. The module routes those via `EVC.call(vault, user, …)`, which
//      requires the user to have granted the module operator rights once
//      (`EVC.setAccountOperator(user, module, true)`) and enabled the controller
//      / collateral — the Euler analogue of Aave `approveDelegation`.
//
//  Level A = deposit/repay makers + a single combined `EulerV2TakerModule` that
//  multiplexes the two value-out legs (borrow/withdraw) behind a leading `op`
//  flag. Level B = `EulerV2BatchModule`, which fuses a value-in and a value-out
//  leg into ONE `EVC.batch` so they share a single deferred liquidity check — the
//  payoff of Euler's architecture.
// ════════════════════════════════════════════════════════════════════════════

// ──────────────────── Euler V2 deposit maker module ────────────────────
//
// Single-op module: pulls the vault's `asset()` from the user via Permit3, then
// supplies it into `vault` crediting shares to the user. Called directly, so the
// authenticated (funding) account is this module while the shares land on the
// user. No EVC operator status is needed (value flows *into* the protocol).
// `data = abi.encode(vault)`.
//
contract EulerV2DepositModule is IMakerModule {
    IPermit3 public immutable permit3;
    address public immutable settlement;

    error NotSettlement();

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();
        address vault = abi.decode(data, (address));
        address asset = IEulerVault(vault).asset();

        permit3.transferFrom(onBehalfOf, address(this), asset, uint160(amount));
        SafeTransferLib.forceApprove(asset, vault, amount);
        IEulerVault(vault).deposit(amount, onBehalfOf);
        // Clear the scoped grant: `vault` is decoded from the order's `data` on a
        // SHARED singleton, so it is attacker-choosable — anyone can author an
        // order naming themselves as maker. A target that consumes less than
        // approved would leave a standing third-party claim on any FUTURE balance
        // of this module, which is what turns a later stranded-balance bug into a
        // theft. {SafeTransferLib.ensureApproval} forbids this shape. F25 / A-3.
        SafeTransferLib.forceApprove(asset, vault, 0);
    }
}

// ──────────────────── Euler V2 repay maker module ────────────────────
//
// Closes the user's borrow in `vault`, handling interest-accrual over-repay with
// a pull-exact strategy: read the live debt, repay `min(amount, debt)`. EVK's
// `repay` itself caps at the debt, but pulling only what we need keeps the
// over-repay buffer out of this contract entirely (SweepToUser), removing the
// "stray dust a caller can redirect" vector at the source. On Recycle the module
// takes the full signed ceiling, repays the debt, and re-supplies the surplus as
// a lend balance into the same vault for the user — best-effort, sweep fallback.
//
// Repay is permissionless on behalf of the user, so no EVC operator status is
// needed; the module funds the repay as the authenticated account.
//
// `nonReentrant` guards weird-token transfer hooks.
// `data = abi.encode(vault[, DustHandler.DustAction])` — trailing action
// optional; absent ⇒ SweepToUser.
//
contract EulerV2RepayModule is IMakerModule {
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

        address vault = abi.decode(data, (address));
        address asset = IEulerVault(vault).asset();
        DustHandler.DustAction action = DustHandler.readAction(data, 32); // base = (address)

        // The balance this module held BEFORE the pull. Everything below disposes of
        // the DELTA over it, never the whole balance: a module address can be sent
        // tokens by anyone, and "sweep everything to the user" pays that to whoever
        // happens to be filling. See the floor overload of {DustHandler.disposeResidual}.
        uint256 floor = IERC20(asset).balanceOf(address(this));

        _pullAndRepay(vault, asset, amount, onBehalfOf, action == DustHandler.DustAction.Recycle);
        _disposeResidual(vault, asset, onBehalfOf, action, floor);

        _locked = 1;
    }

    /// @dev Pull the funding token and repay. SweepToUser pulls only `toRepay`, so
    ///      the buffer never enters this contract; Recycle pulls the full signed
    ///      ceiling so the surplus can be redirected into the user's position.
    function _pullAndRepay(address vault, address asset, uint256 amount, address onBehalfOf, bool recycle) private {
        uint256 toRepay;
        {
            uint256 debt = IEulerVault(vault).debtOf(onBehalfOf);
            toRepay = amount < debt ? amount : debt;
        }
        {
            uint256 toPull = recycle ? amount : toRepay;
            if (toPull > 0) permit3.transferFrom(onBehalfOf, address(this), asset, uint160(toPull));
        }
        if (toRepay > 0) {
            SafeTransferLib.forceApprove(asset, vault, toRepay);
            IEulerVault(vault).repay(toRepay, onBehalfOf);
            // Clear the scoped grant: `vault` is decoded from the order's `data` on a
            // SHARED singleton, so it is attacker-choosable — anyone can author an
            // order naming themselves as maker. A target that consumes less than
            // approved would leave a standing third-party claim on any FUTURE balance
            // of this module, which is what turns a later stranded-balance bug into a
            // theft. {SafeTransferLib.ensureApproval} forbids this shape. F25 / A-3.
            SafeTransferLib.forceApprove(asset, vault, 0);
        }
    }

    /// @dev Re-supply (opt-in) the residual as a lend balance in the same vault,
    ///      else sweep to the user. Best-effort recycle with a guaranteed sweep.
    function _disposeResidual(
        address vault,
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
            vault,
            abi.encodeCall(IEulerVault.deposit, (residual, onBehalfOf))
        );
    }
}

// ──────────────────── Euler V2 combined taker module ────────────────────
//
// Fuses the borrow and withdraw value-out legs into a SINGLE contract. A leading
// `op` flag in `data` selects the leg, so a user who runs the full leverage
// round-trip authorizes ONE module address instead of two — a single
// `EVC.setAccountOperator(user, module, true)` covers both borrow and withdraw,
// and the EVC operator surface shrinks accordingly.
//
// Safety is unchanged from the split modules: the Permit3 taker allowance is
// keyed by `ref = keccak256(data)`, and `op` is the first word of `data`, so
// borrow-data and withdraw-data hash to DIFFERENT refs. The user therefore still
// grants a separate amount-gated allowance per leg — the flag cannot be flipped
// to spend a borrow allowance on a withdraw (or vice-versa). The only thing
// shared is the coarse EVC operator grant, which is per-address by construction.
//
// Both legs route value-out through the EVC as the user account; the user must
// have enabled the borrow vault as their controller / the collateral vault in
// their set, and granted this module operator rights once.
//
// Byte map (op first; old single-op offsets shift +32):
//   base:           op@0, vault@32                     (base length 64)
//   op = 0 (Borrow):
//     data = abi.encode(uint8(0), vault)
//   op = 1 (Withdraw):
//     data = abi.encode(uint8(1), vault[, BalanceMode[, total]]) — BalanceMode@64
//       — total@96, and MANDATORY whenever the mode is `Full`: the maker-signed
//         full item amount, which {FullFillGuard.requireFullFillFromData} compares
//         the slice against. It FAILS CLOSED when the word is absent, so a `Full`
//         order encoded from a map that omits it is one no filler can ever settle.
//         (Undeclared here until now — the same drift F25/A-2 corrected on
//         {AaveV3WithdrawModule}.)
//
contract EulerV2TakerModule is ITakerModule, IPositionSource {
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
        return (
            IEulerVault(vault).asset(),
            IEulerVault(vault).convertToAssets(IEulerVault(vault).balanceOf(user))
        );
    }

    error OnlyPermit3();
    error BadOp(uint8 op);

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        // op@0, vault@32 — both static, so a prefix decode is sound even when
        // op-specific trailing fields follow.
        (uint8 op, address vault) = abi.decode(data, (uint8, address));

        if (op == uint8(Op.Borrow)) {
            IEVC(IEulerVault(vault).EVC())
                .call(vault, onBehalfOf, 0, abi.encodeCall(IEulerVault.borrow, (amount, receiver)));
        } else if (op == uint8(Op.Withdraw)) {
            // BalanceMode slot at offset 64 (op@0 + vault@32).
            if (DustHandler.readBalanceMode(data, 64) == DustHandler.BalanceMode.Full) {
                // `Full` liquidates the user's ENTIRE live balance, so it cannot be
                // pro-rated — a sliced fill would unwind the whole position and brick
                // the rest of the order. Require the slice to be the whole item.
                FullFillGuard.requireFullFillFromData(data, 96, amount);
                _withdrawFull(vault, onBehalfOf, amount, receiver);
            } else {
                IEVC(IEulerVault(vault).EVC())
                    .call(vault, onBehalfOf, 0, abi.encodeCall(IEulerVault.withdraw, (amount, receiver, onBehalfOf)));
            }
        } else {
            revert BadOp(op);
        }
    }

    /// @dev Full mode: EXACT amounts straight to their destinations — the signed
    ///      `amount` to `receiver`, the remainder back to `onBehalfOf`. The vault's
    ///      ERC4626 `withdraw` takes a receiver (the Exact branch above uses it the
    ///      same way), the module DOES take custody between the withdraw and the
        // split, which is why the floor + cap + bound below are load-bearing. A position below `amount` reverts in the vault. Its own frame
    ///      keeps the stack shallow.
    function _withdrawFull(address vault, address onBehalfOf, uint256 amount, address receiver) private {
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
        address evc = IEulerVault(vault).EVC();
        address asset = IEulerVault(vault).asset();
        uint256 floor = IERC20(asset).balanceOf(address(this));
        (, uint256 bal) = _vaultPositionOf(vault, onBehalfOf);
        IEVC(evc).call(vault, onBehalfOf, 0, abi.encodeCall(IEulerVault.withdraw, (bal, address(this), onBehalfOf)));
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

// ──────────────────── Euler V2 batch taker module (Level B) ────────────────────
//
// Composite module that fuses a value-in and a value-out leg into a SINGLE
// `EVC.batch`, so both share one deferred account/vault status check instead of
// one per leg — the architectural payoff of Euler's design. Two shapes:
//
//   • Open  — deposit `sideAmount` collateral into `collateralVault` (module-
//             funded via Permit3) + borrow `amount` from `borrowVault` to
//             `receiver`. The deposit credits the user's collateral and the
//             borrow draws against it under one check.
//   • Close — repay up to `sideAmount` of the user's `borrowVault` debt (module-
//             funded via Permit3, capped at live debt) + withdraw `amount`
//             collateral from `collateralVault` to `receiver`. The single check
//             sees the debt reduced before validating the collateral withdrawal.
//
// Trade-off vs single-op: one module signs a whole batch (deposit+borrow or
// repay+withdraw) under one `keccak256(data)` taker ref. It is still fully
// maker-signed and amount-gated, but it deliberately gives up the "one module =
// one protocol action" blast-radius invariant the single-op modules hold. The
// user must grant operator rights and enable the controller/collateral once.
//
// `data = abi.encode(BatchMode mode, address collateralVault, address borrowVault, uint256 sideAmount)`.
// `amount`/`receiver` carry the value-out leg (borrow for Open, collateral for Close).
//
contract EulerV2BatchModule is ITakerModule {
    IPermit3 public immutable permit3;

    enum BatchMode {
        Open, // 0 — deposit collateral + borrow
        Close // 1 — repay debt + withdraw collateral
    }

    struct BatchData {
        uint256 mode;
        address collateralVault;
        address borrowVault;
        uint256 sideAmount;
        /// @dev The item's FULL maker-signed amount. Composite ops are full-fill
        ///      only — see {FullFillGuard}.
        uint256 totalAmount;
    }

    error OnlyPermit3();

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        BatchData memory p = abi.decode(data, (BatchData));

        // Composite items execute a multi-leg position op whose side leg lives in
        // `data` and does NOT pro-rate. Reject a sliced fill outright — see {FullFillGuard}.
        FullFillGuard.requireFullFill(amount, p.totalAmount);

        if (BatchMode(uint8(p.mode)) == BatchMode.Open) {
            _open(p, onBehalfOf, receiver, amount);
        } else {
            _close(p, onBehalfOf, receiver, amount);
        }
    }

    /// @dev deposit `sideAmount` collateral (module-funded) + borrow `borrowAmount`
    ///      in one batch. Item 0 is authenticated as this module (the funder) so
    ///      the collateral is pulled from here; item 1 as the user so the debt and
    ///      the single liquidity check land on the user's account.
    function _open(BatchData memory p, address user, address receiver, uint256 borrowAmount) private {
        address collateralAsset = IEulerVault(p.collateralVault).asset();
        permit3.transferFrom(user, address(this), collateralAsset, Narrow160.to160(p.sideAmount));
        SafeTransferLib.forceApprove(collateralAsset, p.collateralVault, p.sideAmount);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            targetContract: p.collateralVault,
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeCall(IEulerVault.deposit, (p.sideAmount, user))
        });
        items[1] = IEVC.BatchItem({
            targetContract: p.borrowVault,
            onBehalfOfAccount: user,
            value: 0,
            data: abi.encodeCall(IEulerVault.borrow, (borrowAmount, receiver))
        });
        IEVC(IEulerVault(p.borrowVault).EVC()).batch(items);
        // Clear the scoped grant. The vault is decoded from the order's `data` on a
        // SHARED singleton, so it is attacker-choosable — anyone can author an order
        // naming themselves as maker. A target consuming less than approved would
        // leave a standing third-party claim on any FUTURE balance of this module.
        // {SafeTransferLib.ensureApproval} forbids this shape. F26/2c.
        SafeTransferLib.forceApprove(collateralAsset, p.collateralVault, 0);
    }

    /// @dev repay up to `sideAmount` (capped at live debt, module-funded) +
    ///      withdraw `collateralAmount` to `receiver` in one batch.
    function _close(BatchData memory p, address user, address receiver, uint256 collateralAmount) private {
        address borrowAsset = IEulerVault(p.borrowVault).asset();
        uint256 debt = IEulerVault(p.borrowVault).debtOf(user);
        uint256 toRepay = p.sideAmount < debt ? p.sideAmount : debt;

        if (toRepay > 0) {
            permit3.transferFrom(user, address(this), borrowAsset, Narrow160.to160(toRepay));
            SafeTransferLib.forceApprove(borrowAsset, p.borrowVault, toRepay);
        }

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](2);
        items[0] = IEVC.BatchItem({
            targetContract: p.borrowVault,
            onBehalfOfAccount: address(this),
            value: 0,
            data: abi.encodeCall(IEulerVault.repay, (toRepay, user))
        });
        items[1] = IEVC.BatchItem({
            targetContract: p.collateralVault,
            onBehalfOfAccount: user,
            value: 0,
            data: abi.encodeCall(IEulerVault.withdraw, (collateralAmount, receiver, user))
        });
        IEVC(IEulerVault(p.borrowVault).EVC()).batch(items);
        // Clear the scoped grant. The vault is decoded from the order's `data` on a
        // SHARED singleton, so it is attacker-choosable — anyone can author an order
        // naming themselves as maker. A target consuming less than approved would
        // leave a standing third-party claim on any FUTURE balance of this module.
        // {SafeTransferLib.ensureApproval} forbids this shape. F26/2c.
        if (toRepay > 0) SafeTransferLib.forceApprove(borrowAsset, p.borrowVault, 0);
    }
}

// ──────────── Euler V2 TAKE_FOR open module (core-funded collateral) ────────────
//
// The same one-`EVC.batch` deposit+borrow as {EulerV2BatchModule}'s Open path, with
// the collateral amount supplied by the settler rather than pinned in `data`.
//
// Euler is the EASY case for this, and that is the point: an Euler position has no
// identity object. It is just the balances of an EVC account, so `deposit` +
// `borrow` may be applied to it any number of times. {EulerV2BatchModule}'s
// {FullFillGuard} was therefore never a protocol constraint — it existed only
// because a constant `sideAmount` in `data` cannot pro-rate. With `forAmount` sized
// by the core, the guard has nothing left to protect and is GONE: this module
// partial-fills freely, and every slice is its own two-item batch sharing ONE
// deferred account/vault status check.
//
// Item 0 is authenticated as this module (the funder, so the collateral is pulled
// from here); item 1 as the user, so the debt and the single liquidity check land
// on the user's account. A zero funding slice degenerates to a one-item batch
// rather than a `deposit(0)`.
//
// `data = abi.encode(OpenData{forDesc, forCap, collateralVault, borrowVault})` —
// `forDesc` first and `forCap` second, the two words {Base._forSlice} reads.
//
// Auth is unchanged from the batch module: `setAccountOperator(user, module, true)`
// plus `enableController`/`enableCollateral`, once — all of it survives slicing.
//
contract EulerV2TakeForModule is ITakerForModule, IFundingSource, IProceedsAsset {
    IPermit3 public immutable permit3;

    /// @dev The ONLY spender allowed to reach this module. `Permit3.takeFor` is a
    ///      PERMISSIONLESS entrypoint and `approveTaker` lets a caller name ITSELF
    ///      spender, so `msg.sender == permit3` authorises nothing on its own
    ///      (F27/C-1). Every sibling `takeForOnBehalf` in the tree pins this
    ///      unconditionally; this one did not.
    address public immutable settlement;

    struct OpenData {
        uint256 forDesc; // word 0 — the funding descriptor
        uint256 forCap; //  word 1 — the balance form's mandatory cap
        address collateralVault;
        address borrowVault;
    }

    error OnlyPermit3();

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    function takeForOnBehalf(
        address spender,
        address onBehalfOf,
        uint256 amount,
        uint256 forAmount,
        address receiver,
        bytes calldata data
    ) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();
        // See {settlement}. The PULL shape does not strictly need this — the funding
        // comes out of `onBehalfOf`'s own wallet under their own allowance, so a
        // self-granting caller only robs themselves — but one unconditional check
        // beats a premise that has to keep holding across future edits, which is the
        // rule {AaveV3LeverageModule} states and all four siblings follow.
        PreFundGuard.requireSettlement(spender, settlement);

        OpenData memory p = abi.decode(data, (OpenData));
        // THIS MODULE IS PULL-ONLY, SO IT MUST REFUSE THE PUSH DESCRIPTOR.
        // Bit 253 makes {Base._forSlice} require `legsOut[j].recipient == module` and
        // deliver the funding leg HERE. This body then pull-funds anyway, charging the
        // maker a SECOND copy and stranding the delivered one on a shared singleton
        // with no sweep — verbatim the pairing the core's own note says bit 253 exists
        // to prevent. The core cannot know a module's funding shape; the module is the
        // only place that can refuse. Siblings that serve BOTH shapes branch here
        // instead ({PreFundModuleBase._fundingShape}); this one serves one, so it
        // rejects.
        if (p.forDesc >> 253 == 5) revert PreFundGuard.PreFundDescriptorNotAllowed();

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](forAmount == 0 ? 1 : 2);
        uint256 k;
        address fundedAsset; // hoisted so the grant can be cleared after the batch
        if (forAmount != 0) {
            address collateralAsset = IEulerVault(p.collateralVault).asset();
            fundedAsset = collateralAsset;
            permit3.transferFrom(onBehalfOf, address(this), collateralAsset, uint160(forAmount));
            SafeTransferLib.forceApprove(collateralAsset, p.collateralVault, forAmount);
            items[k++] = IEVC.BatchItem({
                targetContract: p.collateralVault,
                onBehalfOfAccount: address(this),
                value: 0,
                data: abi.encodeCall(IEulerVault.deposit, (forAmount, onBehalfOf))
            });
        }
        items[k] = IEVC.BatchItem({
            targetContract: p.borrowVault,
            onBehalfOfAccount: onBehalfOf,
            value: 0,
            data: abi.encodeCall(IEulerVault.borrow, (amount, receiver))
        });
        IEVC(IEulerVault(p.borrowVault).EVC()).batch(items);
        // Clear the scoped grant. The vault is decoded from the order's `data` on a
        // SHARED singleton, so it is attacker-choosable — anyone can author an order
        // naming themselves as maker. A target consuming less than approved would
        // leave a standing third-party claim on any FUTURE balance of this module.
        // {SafeTransferLib.ensureApproval} forbids this shape. F26/2c.
        if (fundedAsset != address(0)) SafeTransferLib.forceApprove(fundedAsset, p.collateralVault, 0);
    }

    /// @inheritdoc IFundingSource
    /// @dev DERIVED, not decoded: Euler names the collateral VAULT in `data` and the
    ///      underlying is `vault.asset()`. That is strictly better than a decoded
    ///      field — the asset cannot disagree with the vault the deposit lands in —
    ///      but it is still a second identity next to `legsOut[j].token`, which is
    ///      the one the lens checks.
    function fundingSource(address onBehalfOf, bytes calldata data)
        external
        view
        override
        returns (address asset, uint256 available)
    {
        asset = IEulerVault(abi.decode(data, (OpenData)).collateralVault).asset();
        available = FundingPreflight.pullable(permit3, address(this), onBehalfOf, asset);
    }

    /// @inheritdoc IProceedsAsset
    /// @dev Derived from the BORROW vault, as the funding side is derived from the
    ///      collateral vault — Euler names vaults, not assets.
    function proceedsAsset(bytes calldata data) external view override returns (address) {
        return IEulerVault(abi.decode(data, (OpenData)).borrowVault).asset();
    }
}

// ──────────── Euler V2 PRE-FUNDED TAKE_FOR open module ────────────
//
// The same one-`EVC.batch` deposit+borrow as {EulerV2TakeForModule}, with the
// collateral PUSHED to this module by the fill instead of pulled back out of the
// maker's wallet: the maker signs the collateral output leg with `recipient =
// address(this module)` and `forDesc` pointing at it ({Base._forSlice} admits the
// item's own module as a leg recipient). The pattern is
// {AaveV3PreFundLeverageModule}'s, ported onto Euler's EVC batch.
//
// Why: the APPROVAL SURFACE. Under the pull shape the funding leg needs TWO maker
// grants on the collateral token — the Permit3 token allowance to this module
// and, beneath it, an on-chain ERC20 approve of that token to Permit3 — for a
// token the maker may never have held (the delivered collateral on a cross-asset
// open). Pre-funded, the receive side needs NOTHING: no Permit3 book entry, no
// ERC20 approve, and the fill makes one less ERC20 transfer (solver → module,
// instead of solver → maker → module). The maker's only grants are the borrow's
// taker allowance plus the one-time EVC operator/controller/collateral setup.
//
// Soundness is the TAKE_FOR seam's, argued in {ITakerForModule}'s "Pull-funded vs
// PRE-FUNDED" section: every module-addressed delivery is paid by that fill's
// solver, and every `forAmount` deposited here is CORE-SIZED to that same order's
// own enforced leg — deposits instructed == deliveries enforced, per token, per
// order, so one order's item can never consume another order's delivery.
//
// Pairing rule: sign this module ONLY with a module-addressed funding leg. A
// maker-addressed leg leaves this module unfunded and the deposit reverts — fail
// closed, nothing stranded. `data` is byte-identical to {EulerV2TakeForModule}'s
// {OpenData}, so off-chain builders switch variants by switching the module
// address and the leg recipient, nothing else. A partial fill's per-fill CEIL can
// leave a wei of dust here; it is consumed by the next slice's deposit.
//
// OPTIONAL EVC-PERMIT TAIL — the maker's entire Euler auth surface, signature-
// only. `data` may extend past the 128-byte {OpenData} head with a
// {DelegationHelper.replayEvcPermit} block: an EVC `permit` the maker signed
// whose self-call grants this module operator rights and enables the
// controller / collateral — the three on-chain transactions the pull/batch
// variants require up front. The replay runs BEFORE the batch that needs the
// grants, best-effort (a front-runner landing the lifted permit leaves exactly
// the grants the fill wanted — see the DelegationHelper header). Combined with
// the pre-funding shape, a maker opens a levered Euler position with ZERO
// prior on-chain transactions: order sig + EVC permit sig (+ a Permit3 witness
// batch for the allowances). Orders without the tail behave exactly as before —
// the replay is a no-op and the pre-granted path is untouched.
//
contract EulerV2PreFundTakeForModule is ITakerForModule, IFundingSource, IProceedsAsset {
    IPermit3 public immutable permit3;
    /// @dev The ONLY spender allowed to reach this module's pre-funding.
    ///      `Permit3.takeFor` is permissionless (F27/C-1).
    address public immutable settlement;

    struct OpenData {
        uint256 forDesc; // word 0 — the funding descriptor
        uint256 forCap; //  word 1 — the balance form's mandatory cap
        address collateralVault;
        address borrowVault;
    }

    error OnlyPermit3();

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    /// @param amount    this fill's slice of the BORROW leg (what the taker
    ///                  allowance gates).
    /// @param forAmount this fill's COLLATERAL — core-sized to the module-addressed
    ///                  output leg the fill just delivered HERE.
    /// @param receiver  where the borrow proceeds land.
    function takeForOnBehalf(
        address spender,
        address onBehalfOf,
        uint256 amount,
        uint256 forAmount,
        address receiver,
        bytes calldata data
    ) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();
        PreFundGuard.requireSettlement(spender, settlement);
        PreFundGuard.requireLegRef(data);

        // {OpenData} is 4 static words — the decode reads only the 128-byte head,
        // so the optional EVC-permit tail behind it passes through untouched.
        OpenData memory p = abi.decode(data, (OpenData));
        address evc = IEulerVault(p.borrowVault).EVC();

        // Optional EVC-permit tail at 128 — replayed BEFORE the batch that needs
        // the grants (operator / controller / collateral), best-effort, `onBehalfOf`
        // as the permit signer. No tail ⇒ no-op. See the module header.
        DelegationHelper.replayEvcPermit(data, 128, evc, onBehalfOf);

        IEVC.BatchItem[] memory items = new IEVC.BatchItem[](forAmount == 0 ? 1 : 2);
        uint256 k;
        address fundedAsset; // hoisted so the grant can be cleared after the batch
        if (forAmount != 0) {
            // No pull: the order's module-addressed output leg already landed the
            // collateral here, sized by the same {Pricing.outputAt} call that sized
            // `forAmount`. An unfunded balance (a mis-paired maker-addressed leg)
            // makes the deposit revert — fail closed.
            address collateralAsset = IEulerVault(p.collateralVault).asset();
            fundedAsset = collateralAsset;
            // The delivery must have landed HERE, in THIS token (F27/C-1, B).
            // Underflows if it did not.
            PreFundGuard.requireDelivered(data, collateralAsset, forAmount);
            SafeTransferLib.forceApprove(collateralAsset, p.collateralVault, forAmount);
            items[k++] = IEVC.BatchItem({
                targetContract: p.collateralVault,
                onBehalfOfAccount: address(this),
                value: 0,
                data: abi.encodeCall(IEulerVault.deposit, (forAmount, onBehalfOf))
            });
        }
        items[k] = IEVC.BatchItem({
            targetContract: p.borrowVault,
            onBehalfOfAccount: onBehalfOf,
            value: 0,
            data: abi.encodeCall(IEulerVault.borrow, (amount, receiver))
        });
        IEVC(evc).batch(items);
        // Clear the scoped grant. The vault is decoded from the order's `data` on a
        // SHARED singleton, so it is attacker-choosable — anyone can author an order
        // naming themselves as maker. A target consuming less than approved would
        // leave a standing third-party claim on any FUTURE balance of this module.
        // {SafeTransferLib.ensureApproval} forbids this shape. F26/2c.
        if (fundedAsset != address(0)) SafeTransferLib.forceApprove(fundedAsset, p.collateralVault, 0);
    }

    /// @inheritdoc IFundingSource
    /// @dev Same DERIVED asset as the pull variant (`vault.asset()`, so it cannot
    ///      disagree with the vault the deposit lands in). `available` is reported
    ///      as unbounded: this module is funded by the fill's OWN delivery, not by
    ///      a wallet balance or allowance that could be previewed short. A wallet
    ///      read here would preview a self-funding order as a shortfall.
    function fundingSource(address, bytes calldata data)
        external
        view
        override
        returns (address asset, uint256 available)
    {
        asset = IEulerVault(abi.decode(data, (OpenData)).collateralVault).asset();
        available = type(uint256).max;
    }

    /// @inheritdoc IProceedsAsset
    /// @dev Derived from the BORROW vault, as the funding side is derived from the
    ///      collateral vault — Euler names vaults, not assets.
    function proceedsAsset(bytes calldata data) external view override returns (address) {
        return IEulerVault(abi.decode(data, (OpenData)).borrowVault).asset();
    }
}
