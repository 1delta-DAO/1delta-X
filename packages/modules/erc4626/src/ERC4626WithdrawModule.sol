// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";

import {ITimelockERC4626} from "./interfaces/ITimelockERC4626.sol";

// ──────────────────── ERC-4626 two-phase withdraw module ────────────────────
//
// Handles time-locked ERC-4626 vault withdrawals in two separate limit-order
// executions:
//
//   Phase 1 — Request  (MakerModule, Settlement-gated)
//   ─────────────────────────────────────────────────
//   Settlement calls `makeOnBehalf(user, shares, data)`.
//   The module pulls vault shares from the user via the Permit3 token allowance,
//   approves the vault, submits `vault.requestRedeem(shares)`, and stores the
//   resulting `requestId` alongside who initiated it and when the lock expires.
//
//   `data = abi.encode(vault, shareToken)`
//
//   Phase 2 — Claim  (TakerModule, Permit3-gated)
//   ──────────────────────────────────────────────
//   After the vault's lock duration, Permit3 calls
//   `takeOnBehalf(user, amount, receiver, data)`.
//   The module verifies the caller is the original requester, checks the
//   module-level unlock timestamp (fast early-exit), then delegates to
//   `vault.claimRedeem` — which enforces the lock on-chain as the final gate.
//   `amount` is the Permit3 CAP on value forwarded to `receiver`; anything the
//   vault returns above it goes to the beneficiary. `minAssets` (maker-signed,
//   inside `data`) is the separate slippage floor.
//
//   `data = abi.encode(vault, requestId, minAssets, totalAmount)`
//
//   `totalAmount` (trailing word) is the item's FULL maker-signed amount and the
//   slice must equal it ({FullFillGuard.requireFullFillFromData}): the claim is
//   INDIVISIBLE — it consumes the whole matured request and deletes it — while the
//   core pro-rates `amount`, so without the gate a 1-wei fill claimed everything,
//   forwarded 1 wei, returned the rest to the maker in-kind and bricked the rest
//   of the order (`NoPendingWithdrawal`). No theft, but any filler could unwind a
//   maker's Phase-2 order for one unit of allowance — the exact class the guard
//   exists for on `BalanceMode.Full` legs (F28, 2026-09-12). BREAKING: a
//   three-word blob now reverts `PartialFillUnsupported(amount, 0)`.
//
//   BREAKING vs. the previous `abi.encode(vault, asset, requestId)`: `asset` is
//   now READ FROM THE VAULT rather than supplied by the caller, and `minAssets`
//   moved out of the `amount` argument into `data`. Both changes are load-bearing:
//
//     • A caller-supplied `asset` was a free transfer of any token this module
//       held. `received` comes from `claimRedeem`, but the token it was paid in
//       was whatever `data` said — so anyone holding a valid pending request could
//       name a token with a stray module balance and have it sent to their own
//       receiver. Reading `vault.asset()` makes the token an intrinsic property of
//       the position.
//     • Using `amount` as a FLOOR inverted the taker allowance. Permit3 decremented
//       `amount` and the module then forwarded the ENTIRE claim, however large — so
//       a user who capped their allowance at 1 wei to bound exposure was in fact
//       authorising an unbounded claim, while a user wanting a tight slippage floor
//       was forced to grant a maximal allowance. The two safety properties were in
//       direct opposition. `amount` is now the cap that {ITakerModule} documents.
//
// Trust model
// ───────────
//  • Phase 1 is gated by `msg.sender == settlement` (same as all MakerModules).
//  • Phase 2 is gated by `msg.sender == permit3` (same as all TakerModules).
//  • The two phases are bound through `pendingWithdrawals[vault][requestId]`,
//    which records the beneficiary and unlock time at request submission.
//  • The module is the vault's registered requester for every pending entry,
//    so only this contract can call `vault.claimRedeem` for those requests.
//
// The reentrancy guard is shared across both entry points — a nested call into
// either phase during execution of the other will revert.
//
// Byte maps — Phase 1 (MAKE): vault@0, shareToken@32 (base = 64).
//             Phase 2 (TAKE): vault@0, requestId@32, minAssets@64, totalAmount@96 (base = 128).
contract ERC4626WithdrawModule is IMakerModule, ITakerModule {
    // ── Immutables ────────────────────────────────────────────────────────────

    IPermit3 public immutable permit3;
    address public immutable settlement;

    // ── Storage ───────────────────────────────────────────────────────────────

    struct PendingWithdrawal {
        address beneficiary; // user on whose behalf the request was made
        uint256 unlocksAt; // block.timestamp at request + vault.lockDuration()
    }

    // vault address → vault-issued requestId → pending withdrawal details
    mapping(address => mapping(uint256 => PendingWithdrawal)) public pendingWithdrawals;

    uint256 private _locked = 1;

    // ── Events ────────────────────────────────────────────────────────────────

    event WithdrawRequested(
        address indexed vault, uint256 indexed requestId, address indexed beneficiary, uint256 shares, uint256 unlocksAt
    );

    event WithdrawClaimed(
        address indexed vault, uint256 indexed requestId, address indexed beneficiary, uint256 assets, address receiver
    );

    // ── Errors ────────────────────────────────────────────────────────────────

    error NotSettlement();
    error OnlyPermit3();
    error Reentrancy();
    error NoPendingWithdrawal();
    error NotBeneficiary();
    error TimelockActive(uint256 unlocksAt, uint256 currentTime);
    error InsufficientAssets(uint256 received, uint256 minAssets);
    /// @dev The vault reused a `requestId` that already has a live pending entry.
    ///      Overwriting it would make the FIRST beneficiary's claim revert
    ///      `NotBeneficiary` forever — and since this module is the vault's only
    ///      authorised claimer for that request, their shares would be
    ///      unrecoverable. Vaults following the ERC-7540 `REQUEST_ID_0` convention
    ///      (every request shares id 0, tracked per-controller) hit this on the
    ///      SECOND user, so failing closed is mandatory, not defensive.
    error RequestIdCollision(address vault, uint256 requestId);
    /// @dev The vault call reduced this module's balance of `token` below what it
    ///      held before the call: the vault consumed stray balance that belongs to
    ///      no order of this maker (MISC-MOD-3).
    error ForeignBalanceConsumed(address token, uint256 consumed);

    // ── Constructor ───────────────────────────────────────────────────────────

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    // ── Phase 1: Request (IMakerModule) ───────────────────────────────────────

    /// @notice Initiate a time-locked vault withdrawal on behalf of a user.
    /// @param onBehalfOf User whose shares are being redeemed.
    /// @param amount     Number of vault shares to submit for redemption.
    /// @param data       `abi.encode(vault, shareToken)`
    ///                   • vault      — ITimelockERC4626 vault address
    ///                   • shareToken — ERC-20 address of the vault's share token
    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();
        if (_locked != 1) revert Reentrancy();
        _locked = 2;

        (address vault, address shareToken) = abi.decode(data, (address, address));

        // FLOOR FIRST. The sweep below is a whole-balance read, so without this any
        // stray/donated `shareToken` on this shared singleton is claimable by
        // whoever authors the next one-wei order against it. "The module ends
        // EMPTY" is the wrong invariant; "ends where it started" is the right one.
        uint256 shareFloor = SafeTransferLib.balanceOf(shareToken, address(this));
        // ...and on the VAULT'S OWN token too (audit 2026-09-30 MISC-MOD-3).
        // `shareToken` is data-named and nothing binds it to what the vault really
        // consumes: an ERC-4626/7540 vault IS its share ERC-20 and may move the
        // caller's own shares with an internal `_transfer`/`_burn`, no allowance
        // needed. A self-order naming a junk `shareToken` would then redeem the
        // module's STRAY vault shares while the floor watched the junk token. Both
        // balances must end at or above their floors; any surplus goes to the user.
        // `SafeTransferLib.balanceOf` reads 0 for a vault that is not a token, which
        // makes the extra check a no-op there.
        uint256 vaultShareFloor = vault == shareToken ? 0 : SafeTransferLib.balanceOf(vault, address(this));

        // Pull shares from the user via Permit3 token allowance.
        permit3.transferFrom(onBehalfOf, address(this), shareToken, uint160(amount));

        // Approve the vault to pull the shares from this module.
        SafeTransferLib.forceApprove(shareToken, vault, amount);

        // Submit the redeem request. The vault pulls shares from this module
        // and records this module as the authorized claimer for the returned requestId.
        uint256 requestId = ITimelockERC4626(vault).requestRedeem(amount);

        // Leave no residue and no standing approval. A vault that clamps the
        // request (per-epoch or queue caps) would otherwise strand un-pulled shares
        // here alongside a live allowance — which is exactly the balance the old
        // caller-supplied `asset` let someone else walk off with.
        SafeTransferLib.forceApprove(shareToken, vault, 0);
        _restoreFloor(shareToken, shareFloor, onBehalfOf);
        if (vault != shareToken) _restoreFloor(vault, vaultShareFloor, onBehalfOf);

        // Record the beneficiary and the earliest valid claim time.
        // The vault's claimRedeem is the authoritative lock enforcer; this
        // timestamp gives a cheaper early-exit path and a descriptive error.
        uint256 unlocksAt = block.timestamp + ITimelockERC4626(vault).lockDuration();
        // Never silently reassign a live request — see {RequestIdCollision}. The
        // uniqueness of `requestId` is a property of the EXTERNAL vault, so it has
        // to be checked here rather than assumed.
        if (pendingWithdrawals[vault][requestId].beneficiary != address(0)) {
            revert RequestIdCollision(vault, requestId);
        }
        pendingWithdrawals[vault][requestId] = PendingWithdrawal({beneficiary: onBehalfOf, unlocksAt: unlocksAt});

        emit WithdrawRequested(vault, requestId, onBehalfOf, amount, unlocksAt);

        _locked = 1;
    }

    // ── Phase 2: Claim (ITakerModule) ─────────────────────────────────────────

    /// @notice Claim a matured vault withdrawal and forward assets to `receiver`.
    ///         Called by Permit3 after the user's taker allowance gate is checked.
    /// @param onBehalfOf User who initiated the withdrawal (must match the stored beneficiary).
    /// @param amount     Permit3 allowance CAP on assets forwarded to `receiver`;
    ///                   the surplus goes to `onBehalfOf`.
    /// @param receiver   Destination for the claimed assets.
    /// @param data       `abi.encode(vault, requestId, minAssets, totalAmount)`
    ///                   • vault       — ITimelockERC4626 vault address
    ///                   • requestId   — ID returned by the vault during Phase 1
    ///                   • minAssets   — maker-signed slippage floor on the claim
    ///                   • totalAmount — the item's full signed amount; the slice
    ///                     must equal it (a three-word blob reverts
    ///                     `PartialFillUnsupported(amount, 0)`)
    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();
        if (_locked != 1) revert Reentrancy();
        _locked = 2;

        (address vault, uint256 requestId, uint256 minAssets) = abi.decode(data, (address, uint256, uint256));
        // The claim is indivisible: the slice must be the whole item (see header).
        FullFillGuard.requireFullFillFromData(data, 96, amount);

        PendingWithdrawal storage pw = pendingWithdrawals[vault][requestId];

        if (pw.beneficiary == address(0)) revert NoPendingWithdrawal();
        if (pw.beneficiary != onBehalfOf) revert NotBeneficiary();
        if (block.timestamp < pw.unlocksAt) revert TimelockActive(pw.unlocksAt, block.timestamp);

        // Clear before the external call (checks-effects-interactions).
        delete pendingWithdrawals[vault][requestId];

        (address asset, uint256 received) = _claimMeasured(vault, requestId, onBehalfOf);

        if (received < minAssets) revert InsufficientAssets(received, minAssets);
        // I-8: the slice IS the signed total (gated above), so a claim short of it
        // must revert here rather than have {Core._payInputsToSolver} bill the
        // shortfall to the maker's wallet. `minAssets` is the maker's own, possibly
        // stricter, floor; this one is the funding leg's.
        FullFillGuard.requireDelivered(received, amount);

        // `amount` is the Permit3 allowance CAP: forward at most that much, and
        // return anything the vault yielded above it to the beneficiary. Yield
        // accrues during the lock, so over-delivery is the normal case and must not
        // revert — matching the `_withdrawFull` discipline used across the repo.
        uint256 toReceiver = received > amount ? amount : received;
        SafeTransferLib.safeTransfer(asset, receiver, toReceiver);
        unchecked {
            if (received > toReceiver) SafeTransferLib.safeTransfer(asset, onBehalfOf, received - toReceiver);
        }

        emit WithdrawClaimed(vault, requestId, onBehalfOf, toReceiver, receiver);

        _locked = 1;
    }

    /// @dev Claim `requestId` from `vault` and return the asset and the MEASURED
    ///      amount received.
    function _claimMeasured(address vault, uint256 requestId, address beneficiary)
        private
        returns (address asset, uint256 received)
    {
        // Claim from the vault. The vault sends assets to this module;
        // it will revert if the lock has not elapsed on-chain.
        // The asset is an intrinsic property of the vault, never caller-supplied.
        asset = ITimelockERC4626(vault).asset();

        // ⚠ MEASURE, DO NOT TRUST THE RETURN VALUE. `vault` is maker-signed on a
        // shared singleton and `Permit3.take` is a permissionless entrypoint, so a
        // fake vault can report a large claim while transferring nothing — and the
        // payout would then come out of this module's own balance. Every other
        // `received` in the tree is a balance delta against a pre-call floor; this
        // was the one sized from what the venue said. F27/C-3.
        uint256 assetFloor = SafeTransferLib.balanceOf(asset, address(this));
        // A vault may hand back unfulfilled SHARES on a partially honoured claim.
        // Floor its share token here and return any increase to the beneficiary,
        // rather than leaving it on the singleton as residue (MISC-MOD-3).
        uint256 vaultShareFloor = SafeTransferLib.balanceOf(vault, address(this));
        ITimelockERC4626(vault).claimRedeem(requestId, address(this));
        received = SafeTransferLib.balanceOf(asset, address(this)) - assetFloor;
        if (vault != asset) _restoreFloor(vault, vaultShareFloor, beneficiary);
    }

    /// @dev This module's `token` balance must end at or above `floor` (what it held
    ///      before the venue call) — a drop means the venue consumed balance that was
    ///      not this order's. Any increase is this order's and goes to `to`.
    function _restoreFloor(address token, uint256 floor, address to) private {
        uint256 bal = SafeTransferLib.balanceOf(token, address(this));
        if (bal < floor) revert ForeignBalanceConsumed(token, floor - bal);
        if (bal > floor) SafeTransferLib.safeTransfer(token, to, bal - floor);
    }
}
