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

import {IMoolah, IListaBroker, MarketParams, Position, Id, MarketParamsLib} from "./interfaces/ILista.sol";

// ════════════════════════════════════════════════════════════════════════════
//  Lista DAO (Moolah + LendingBroker) modules
//
//  Collateral lives in the Moolah singleton (a Morpho fork), so the
//  supply-collateral / withdraw-collateral legs mirror the Morpho Blue modules
//  and are gated by Moolah `setAuthorization(module, true)`. The debt side of a
//  brokered market runs through a `LendingBroker`:
//
//    supply-collateral / repay → value-in  (MAKE)
//    broker-borrow / withdraw-collateral → value-out (TAKE), forwarded to `receiver`
//
//  Only the FIXED-term broker borrow is delegable; the flex borrow is
//  `msg.sender`-only (out of scope). All market/broker/term identifiers are
//  maker-signed in `data`.
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

// ──────────────────── Lista broker repay maker module ────────────────────
//
// Closes (up to `amount`) of the user's broker debt. Pulls the maker-signed
// ceiling, approves the broker, then calls `repay(amount, …)` — the broker
// `transferFrom`s the LITERAL amount, consumes up to the live debt
// (interest-first, early-repay penalty included) and refunds the surplus to its
// caller, i.e. back here, which is then swept to the user (or recycled).
// NOT `repay(0, …)`: every deployed broker reverts `ZeroAmount()` on a zero
// amount (source-verified on the chain-1 impl 0x63fa…96f0 and fork-measured on
// BSC — there is no "0 = repay from balance" convention on the broker; the
// same correction the pre-fund sibling {ListaPreFundBrokerRepayModule} carries).
// `loanId == type(uint128).max` selects the flex position;
// `loanId == type(uint256).max` closes EVERYTHING via `repayAll` — dynamic +
// every fixed position by shares, immune to the refinance-bot race. `repayAll`
// pulls EXACTLY the live total debt (no refund), capped by this module's
// approval at the maker-signed ceiling, so a ceiling short of the live debt
// fails closed in the broker's `transferFrom` and the un-pulled remainder
// sweeps back to the maker. Any other `loanId` targets a fixed position.
//
// `nonReentrant` guards weird-token transfer hooks.
// `data = abi.encode(broker, loanToken, loanId[, DustAction[, deadline, v, r, s]])`
//   — base = 96; DustAction@96; permit@128.
//
contract ListaBrokerRepayModule is IMakerModule {
    uint256 private constant DYNAMIC_LOAN = type(uint128).max;
    /// @dev Full-close sentinel — maps to `repayAll(onBehalf)`. Fixed posIds are
    ///      small sequential uuids, so neither sentinel can collide with one.
    uint256 private constant REPAY_ALL = type(uint256).max;

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

        (address broker, address loanToken, uint256 loanId) = abi.decode(data, (address, address, uint256));
        DustHandler.DustAction action = DustHandler.readAction(data, 96);
        PermitHelper.replayIfPresent(data, 128, loanToken, onBehalfOf, address(permit3), amount);

        // Balance held BEFORE the pull. Sweeping `balanceOf(this)` outright would pay
        // out anything already stranded at this shared module address, and anyone can
        // be the maker of a one-unit order against it — so a stray balance would be
        // claimable by whoever fills next. The invariant is "the module ends where it
        // started", not "ends empty" (F19; {DustHandler.disposeResidual}'s floor).
        uint256 floor = IERC20(loanToken).balanceOf(address(this));
        if (amount > 0) {
            permit3.transferFrom(onBehalfOf, address(this), loanToken, uint160(amount));
            SafeTransferLib.forceApprove(loanToken, broker, amount);
            // `repay(amount, …)` ⇒ the broker pulls the literal ceiling, repays up
            // to the live debt, refunds the rest here (swept below). `repay(0, …)`
            // reverts `ZeroAmount()` on every deployed broker — see the header.
            if (loanId == REPAY_ALL) {
                // Pulls exactly the live total debt (dynamic + every fixed, by
                // shares) — no literal amount, the approval above is the cap.
                IListaBroker(broker).repayAll(onBehalfOf);
            } else if (loanId == DYNAMIC_LOAN) {
                IListaBroker(broker).repay(amount, onBehalfOf);
            } else {
                IListaBroker(broker).repay(amount, loanId, onBehalfOf);
            }
            SafeTransferLib.forceApprove(loanToken, broker, 0);
        }

        uint256 bal = IERC20(loanToken).balanceOf(address(this));
        if (bal > floor) SafeTransferLib.safeTransfer(loanToken, onBehalfOf, bal - floor);
        // (action reserved for a future in-position recycle; broker has no
        //  re-supply target, so residual always sweeps to the user.)
        action;

        _locked = 1;
    }
}

// ──────────────────── Lista combined taker module ────────────────────
//
// Fuses the FIXED-term broker borrow and the Moolah withdraw-collateral value-out
// legs behind a leading `op` flag. Borrow-data and withdraw-data hash to
// different `keccak256(data)` refs (separate amount-gated taker allowances); both
// legs share the one Moolah `setAuthorization(module)` grant, per-address by
// construction.
//
//   op = 0 (Broker borrow):  data = abi.encode(uint8(0), broker, termId[, moolah, nonce, deadline, v, r, s])
//     — base = 96. Optional signature-only Moolah grant: base data carries no
//       moolah word (the borrow itself routes through the broker), so the tail
//       prefixes it — moolah@96, then the standard 160-byte
//       {DelegationHelper.replayMorphoAuth} block @128 (tail = 192 bytes,
//       total 288). Verified on the deployed BSC Moolah: `setAuthorizationWithSig`
//       is byte-identical to Morpho Blue's (typehash, struct, Signature tuple,
//       sequential `nonce(address)`, Morpho's chainId+contract domain scheme —
//       only the domain VIEW is renamed `domainSeparator()`), so the Morpho
//       helper is reused unchanged. Everything in the tail is maker-signed via
//       `data`; a wrong moolah address just makes the best-effort replay a no-op.
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
        Borrow, // 0 — fixed-term broker borrow
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

        if (op == uint8(Op.Borrow)) {
            (, address broker, uint256 termId) = abi.decode(data, (uint8, address, uint256));
            // Optional signature-only Moolah grant (see the header byte map):
            // maker-signed moolah@96, auth block@128. The broker's on-behalf
            // borrow is gated by the maker's Moolah authorization of this module.
            if (data.length >= 288) {
                address moolah = abi.decode(data[96:128], (address));
                DelegationHelper.replayMorphoAuth(data, 128, moolah, onBehalfOf, address(this));
            }
            IListaBroker(broker).borrow(amount, termId, onBehalfOf, receiver);
        } else if (op == uint8(Op.WithdrawCollateral)) {
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
        address collateralToken = mp.collateralToken;
        uint256 bal = IMoolah(moolah).position(mp.id(), onBehalfOf).collateral;
        uint256 before = IERC20(collateralToken).balanceOf(address(this));
        IMoolah(venue).withdrawCollateral(mp, bal, onBehalfOf, address(this));
        uint256 received = IERC20(collateralToken).balanceOf(address(this)) - before;
        require(received >= amount, "insufficient withdrawn");
        SafeTransferLib.safeTransfer(collateralToken, receiver, amount);
        if (received > amount) SafeTransferLib.safeTransfer(collateralToken, onBehalfOf, received - amount);
    }
}
