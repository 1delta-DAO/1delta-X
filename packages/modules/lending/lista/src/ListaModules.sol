// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {DelegationHelper} from "@lib/DelegationHelper.sol";
import {DustHandler} from "@lib/DustHandler.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";
import {PermitHelper} from "@lib/PermitHelper.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

import {IMoolah, MarketParams, Position, Id, MarketParamsLib} from "./interfaces/ILista.sol";

// ════════════════════════════════════════════════════════════════════════════
//  Lista DAO (Moolah + LendingBroker) modules
//
//  Lista splits its lending stack in two, and so do these modules. COLLATERAL
//  lives in the Moolah singleton (a Morpho Blue fork) and is what THIS file
//  covers; DEBT lives in a `LendingBroker` and is served, in full, by
//  {ListaBrokerModule}.
//
//    supply-collateral   → value-in  (MAKE)
//    withdraw-collateral → value-out (TAKE), forwarded to `receiver`
//
//  Both legs mirror the Morpho Blue modules and are gated by Moolah
//  `setAuthorization(module, true)`. All market identifiers are maker-signed in
//  `data`.
//
//  ⚠ The broker BORROW used to live here as this file's taker op 0. It moved to
//  {ListaBrokerModule} so that every broker call — borrow and both funding
//  shapes of repay — sits in one contract and cannot drift apart again. Op 0 is
//  RESERVED below rather than reused, so ops 1 and 2 keep their wire values.
// ════════════════════════════════════════════════════════════════════════════

// ──────────────────── Lista supply-collateral maker module ────────────────────
//
// Pulls `collateralToken` via Permit3 and supplies it into the Moolah market on
// the user's behalf. Optional EIP-2612 permit replay.
// `data = abi.encode(moolah, MarketParams[, deadline, v, r, s])` — base = 192.
// The venue word also serves ERC20-FORWARDING collateral providers (the slisBNB
// provider — supply is permissionless on behalf and the selector is forwarded
// token-for-token, fork-verified): on a provider-gated market encode the
// PROVIDER here, since Moolah itself reverts "not provider" for module callers.
// NOT the native or SmartLP providers — those take {ListaNativeModules} /
// {ListaSmartModules}.
//
contract ListaSupplyCollateralModule is IMakerModule {
    IPermit3 public immutable permit3;
    address public immutable settlement;

    error NotSettlement();

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();

        (address moolah, MarketParams memory mp) = abi.decode(data, (address, MarketParams));

        // base = op-less: (address, MarketParams(5 words)) = 32 + 160 = 192 bytes.
        PermitHelper.replayIfPresent(data, 192, mp.collateralToken, onBehalfOf, address(permit3), amount);

        permit3.transferFrom(onBehalfOf, address(this), mp.collateralToken, uint160(amount));
        SafeTransferLib.forceApprove(mp.collateralToken, moolah, amount);
        IMoolah(moolah).supplyCollateral(mp, amount, onBehalfOf, "");
        // Clear the scoped grant: the target is decoded from the order's `data` on a
        // SHARED singleton, so it is attacker-choosable. A target consuming less than
        // approved leaves a standing third-party claim on any FUTURE balance of this
        // module. {SafeTransferLib.ensureApproval} forbids this shape. F26/2c.
        SafeTransferLib.forceApprove(mp.collateralToken, moolah, 0);
    }
}

// ──────────────────── Lista Moolah collateral taker module ────────────────────
//
// The Moolah withdraw-collateral value-out legs behind a leading `op` flag: the
// direct form and the provider-forwarded one. They hash to different
// `keccak256(data)` refs (separate amount-gated taker allowances) and share the
// one Moolah `setAuthorization(module)` grant, per-address by construction.
//
//   op = 0: RESERVED — the fixed-term broker borrow that used to live here, now
//       in {ListaBrokerModule}. Reverts `BadOp(0)`. The slot is not reused so
//       ops 1 and 2 keep their on-the-wire values, and so a borrow blob signed
//       for the broker module can never be reinterpreted against a grant here.
//   op = 1 (Withdraw coll):   data = abi.encode(uint8(1), moolah, MarketParams[, BalanceMode[, ...]])
//     — op@0, moolah@32, MarketParams@64 (base = 224); BalanceMode@224.
//       ⚠ THE OPTIONAL AUTH BLOCK IS BRANCH-SCOPED AND ITS OFFSET DIFFERS PER
//       MODE (same layout rule as MorphoBlueTakerModule): `Full` carries the
//       maker-signed `totalAmount` at 256 ({FullFillGuard}) so the auth block
//       moves to 288; `Exact` keeps it at 256. When an auth block follows, the
//       BalanceMode slot MUST be encoded explicitly (as 0 = Exact) so the block
//       starts at a fixed offset. Absent tails are byte-exact no-ops.
//   op = 2 (Withdraw coll via PROVIDER): data = abi.encode(uint8(2), provider,
//       moolah, MarketParams[, BalanceMode[, total][, auth]])
//     — op@0, provider@32, moolah@64, MarketParams@96 (base = 256);
//       BalanceMode@256; `Exact` auth@288; `Full` total@288, auth@320.
//       For Lista's ERC20-FORWARDING provider markets (the slisBNB provider
//       0x33f7…, 5 markets): when `Moolah.providers(id, collateralToken)` is
//       set, Moolah itself rejects any non-provider caller ("not provider")
//       and the withdraw must be sent to the provider, which forwards Moolah's
//       own `withdrawCollateral` selector token-for-token (fork-verified; the
//       auth gate stays `Moolah.isAuthorized`). op 1 can also be pointed at a
//       provider, but its single address word then makes the sig-auth tail
//       target the provider (a swallowed no-op) — op 2 splits VENUE (provider)
//       from AUTH TARGET (the Moolah singleton) so the signature-only grant
//       works here too.
//       ⚠ NOT for the NATIVE provider (0x3673…, WBNB/lisUSD) — it keeps the
//       4-arg withdraw selector but UNWRAPS and pays `receiver` raw native
//       (and its supply is payable-only): use {ListaNativeModules}. And NOT
//       for SmartLP providers — different ABI, see {ListaSmartModules}.
//
contract ListaTakerModule is ITakerModule {
    using MarketParamsLib for MarketParams;

    IPermit3 public immutable permit3;

    enum Op {
        /// @dev 0 — the fixed-term broker borrow, MOVED to {ListaBrokerModule}
        ///      together with the rest of the broker surface. The slot is KEPT so
        ///      ops 1 and 2 retain their on-the-wire values; op 0 now reverts
        ///      {BadOp} here, which is what stops a borrow blob from being
        ///      reinterpreted as a withdraw against this module's grant.
        MovedToBrokerModule_Borrow,
        WithdrawCollateral, // 1 — Moolah collateral, direct
        ProviderWithdrawCollateral // 2 — provider-gated markets (Morpho-shaped forwarders)
    }

    error OnlyPermit3();
    error BadOp(uint8 op);

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        uint8 op = uint8(uint256(bytes32(data[:32])));

        if (op == uint8(Op.WithdrawCollateral)) {
            (, address moolah, MarketParams memory mp) = abi.decode(data, (uint8, address, MarketParams));
            if (DustHandler.readBalanceMode(data, 224) == DustHandler.BalanceMode.Full) {
                // `Full` liquidates the user's ENTIRE live balance, so it cannot be
                // pro-rated — a sliced fill would unwind the whole position and brick
                // the rest of the order. Require the slice to be the whole item.
                // Checked BEFORE the auth replay: a bad slice should fail without
                // spending an external call. `Full`'s total occupies 256, so the
                // auth block sits at 288 — never share the total's offset, or the
                // guard would read the auth `nonce` as the maker's signed total.
                FullFillGuard.requireFullFillFromData(data, 256, amount);
                DelegationHelper.replayMorphoAuth(data, 288, moolah, onBehalfOf, address(this));
                _withdrawFull(moolah, moolah, mp, onBehalfOf, amount, receiver);
            } else {
                DelegationHelper.replayMorphoAuth(data, 256, moolah, onBehalfOf, address(this));
                IMoolah(moolah).withdrawCollateral(mp, amount, onBehalfOf, receiver);
            }
        } else if (op == uint8(Op.ProviderWithdrawCollateral)) {
            (, address provider, address moolah, MarketParams memory mp) =
                abi.decode(data, (uint8, address, address, MarketParams));
            // Same branch-scoped tail rule as op 1, shifted by the provider word
            // (base = 256). The VENUE call goes to the provider; the sig-auth
            // replay goes to the Moolah SINGLETON — the provider forwards the
            // withdraw but the `isAuthorized` gate lives on Moolah.
            if (DustHandler.readBalanceMode(data, 256) == DustHandler.BalanceMode.Full) {
                FullFillGuard.requireFullFillFromData(data, 288, amount);
                DelegationHelper.replayMorphoAuth(data, 320, moolah, onBehalfOf, address(this));
                _withdrawFull(provider, moolah, mp, onBehalfOf, amount, receiver);
            } else {
                DelegationHelper.replayMorphoAuth(data, 288, moolah, onBehalfOf, address(this));
                IMoolah(provider).withdrawCollateral(mp, amount, onBehalfOf, receiver);
            }
        } else {
            revert BadOp(op);
        }
    }

    /// @dev Full mode: withdraw the user's entire collateral to this module,
    ///      forward the signed `amount` to `receiver`, sweep the excess back to
    ///      the user — always to `onBehalfOf`, never a caller. The position is
    ///      ALWAYS read from the Moolah singleton; `venue` is where the withdraw
    ///      call goes (Moolah itself on op 1, the market's Morpho-shaped
    ///      collateral provider on op 2).
    function _withdrawFull(
        address venue,
        address moolah,
        MarketParams memory mp,
        address onBehalfOf,
        uint256 amount,
        address receiver
    ) private {
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
        address collateralToken = mp.collateralToken;
        uint256 floor = IERC20(collateralToken).balanceOf(address(this));
        uint256 bal = IMoolah(moolah).position(mp.id(), onBehalfOf).collateral;
        IMoolah(venue).withdrawCollateral(mp, bal, onBehalfOf, address(this));
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
}
