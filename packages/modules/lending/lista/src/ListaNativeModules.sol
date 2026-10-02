// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {IPositionSource} from "@core/interfaces/IPositionSource.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {DelegationHelper} from "@lib/DelegationHelper.sol";
import {DustHandler} from "@lib/DustHandler.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";
import {PermitHelper} from "@lib/PermitHelper.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

import {IMoolah, IListaNativeProvider, MarketParams, MarketParamsLib} from "./interfaces/ILista.sol";

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

// ════════════════════════════════════════════════════════════════════════════
//  Lista NATIVE-provider collateral modules (the WBNB/WETH-collateral markets)
//
//  Lista's native provider (BSC `0x3673…`, WBNB/lisUSD) is NOT an ERC20
//  forwarder like the slisBNB provider: `supplyCollateral` is a 3-arg PAYABLE
//  whose amount is `msg.value` (the 4-arg Morpho shape reverts), and
//  `withdrawCollateral` keeps Morpho's 4-arg selector but UNWRAPS and pays
//  `receiver` raw native. Moolah itself rejects any non-provider caller on the
//  market ("not provider"), so an ERC20-only module cannot touch this
//  collateral at all — the same structural wall the SmartLP markets had.
//
//  These modules bridge wrapped↔native AT THE PROVIDER BOUNDARY ONLY (the
//  cEther pattern from the compound-v2 package): the maker's funds flow as the
//  wrapped native (== `mp.collateralToken`, so no extra token word) through
//  Permit3/Settlement, unwrap for the payable supply, and the withdrawn native
//  is wrapped back before it is forwarded ERC20 to `receiver`. The maker and
//  solver never handle raw native.
//
//  F19 floors: every native/token sweep is measured against the pre-call
//  balance — the module ends where it started, never "empty" (a stray balance
//  on a shared module is claimable by whoever fills next otherwise).
// ════════════════════════════════════════════════════════════════════════════

// ──────────────────── native-provider supply-collateral maker module ────────────────────
//
// Pulls the wrapped native via Permit3, unwraps, and supplies it through the
// provider's payable entrypoint on the maker's behalf. Supply is permissionless
// on behalf — no Moolah authorization on the receive side.
// `data = abi.encode(provider, MarketParams[, deadline, v, r, s])` — base = 192
// (the same byte map as {ListaSupplyCollateralModule}, venue word first).
//
// EIP-2612 permit block @192 (+ signedValue@320): `(deadline, v, r, s)` = 128 bytes, plus an OPTIONAL
// trailing `signedValue` word. Without it the signature commits to THIS fill's slice
// and verifies only on a full fill; sign `signedValue = item total` for partial fills
// ({PermitHelper}, audit 2026-09-30 L-AAVE-2).
contract ListaNativeSupplyCollateralModule is IMakerModule {
    IPermit3 public immutable permit3;
    address public immutable settlement;

    error NotSettlement();

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();

        (address provider, MarketParams memory mp) = abi.decode(data, (address, MarketParams));
        // The market's collateral token IS the wrapped native — the maker-signed
        // `mp` carries it, so no separate token word (a wrong market fails at
        // the provider, which checks `mp` against its own market binding).
        address wnative = mp.collateralToken;

        PermitHelper.replayIfPresent(data, 192, wnative, onBehalfOf, address(permit3), amount);

        uint256 ethFloor = address(this).balance;
        permit3.transferFrom(onBehalfOf, address(this), wnative, uint160(amount));
        IWETH(wnative).withdraw(amount);
        // SPEND THE MEASURED DELTA, NOT THE SIGNED AMOUNT. `wnative` is
        // `mp.collateralToken` — decoded from order `data` on a SHARED singleton, so
        // it is attacker-choosable (anyone may author an order naming themselves
        // maker). A fake wrapper makes `withdraw` a no-op, and the `{value: amount}`
        // below would then be paid out of native this module ALREADY held: `ethFloor`
        // guarded only the refund branch, never the spend. Requiring the unwrap to
        // have actually credited `amount` is what binds the two.
        //
        // Supply the MEASURED unwrap delta, never the nominal `amount`: a fake
        // `wnative` makes `withdraw` a no-op, and spending `{value: amount}` would
        // then draw on native this module already held. Spending `received` binds
        // the payable supply to what the unwrap actually produced.
        uint256 received = address(this).balance - ethFloor;
        IListaNativeProvider(provider).supplyCollateral{value: received}(mp, onBehalfOf, "");
        // Residue above the pre-call floor (none expected) wraps back to the maker.
        uint256 bal = address(this).balance;
        if (bal > ethFloor) {
            IWETH(wnative).deposit{value: bal - ethFloor}();
            SafeTransferLib.safeTransfer(wnative, onBehalfOf, bal - ethFloor);
        }
    }

    receive() external payable {} // native from IWETH.withdraw
}

// ──────────────────── native-provider withdraw-collateral taker module ────────────────────
//
// Withdraws the maker's wrapped-native collateral through the provider — which
// pays NATIVE — wraps it back, and forwards the wrapped native ERC20 to
// `receiver`. Gated by `Moolah.isAuthorized(onBehalfOf, module)` (the provider
// checks the singleton), grantable signature-only via the auth tail (target =
// the Moolah singleton, NOT the provider).
//
// `data = abi.encode(provider, moolah, MarketParams[, BalanceMode[, total][, auth]])`
//   — provider@0, moolah@32, MarketParams@64 (base = 224); BalanceMode@224;
//     `Exact` auth@256; `Full` total@256, auth@288 (the op-1/op-2 tail rule:
//     mode word explicit whenever a tail follows).
//
contract ListaNativeCollateralTakerModule is ITakerModule, IPositionSource {
    using MarketParamsLib for MarketParams;

    IPermit3 public immutable permit3;

    error OnlyPermit3();

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    /// @inheritdoc IPositionSource
    /// @dev The RAW Moolah collateral position in the WRAPPED native token — what
    ///      this module delivers (it wraps the provider's native payout), so the
    ///      units match `legsIn[0].token`. The `Full` branch reads the same
    ///      function (audit 2026-09-30 L-LIB-8).
    function positionOf(address user, bytes calldata data)
        public
        view
        override
        returns (address asset, uint256 amount)
    {
        (, address moolah, MarketParams memory mp) = abi.decode(data, (address, address, MarketParams));
        return (mp.collateralToken, IMoolah(moolah).position(mp.id(), user).collateral);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        (address provider, address moolah, MarketParams memory mp) =
            abi.decode(data, (address, address, MarketParams));

        uint256 burn = amount;
        bool full = DustHandler.readBalanceMode(data, 224) == DustHandler.BalanceMode.Full;
        if (full) {
            // Full liquidates the ENTIRE live balance — cannot be pro-rated
            // (op-1's rule); the maker-signed total pins the slice to the item.
            FullFillGuard.requireFullFillFromData(data, 256, amount);
            DelegationHelper.replayMorphoAuth(data, 288, moolah, onBehalfOf, address(this));
            (, burn) = positionOf(onBehalfOf, data);
        } else {
            DelegationHelper.replayMorphoAuth(data, 256, moolah, onBehalfOf, address(this));
        }

        // The provider unwraps and pays native — receive it HERE, wrap, and
        // forward ERC20: `receiver` (a solver contract, the settlement, or a
        // recipient without a payable fallback) must never be handed raw native.
        address wnative = mp.collateralToken;
        uint256 ethFloor = address(this).balance;
        IListaNativeProvider(provider).withdrawCollateral(mp, burn, onBehalfOf, address(this));
        uint256 received = address(this).balance - ethFloor;
        IWETH(wnative).deposit{value: received}();
        // Full mode's lower bound (I-8). The Exact branch is sized at `amount` and
        // the provider reverts on a short position; Full burns the LIVE collateral,
        // so nothing reverts on a short and {Core._payInputsToSolver} would bill the
        // shortfall to the MAKER'S WALLET. Safe on Full only: there `amount` is the
        // signed TOTAL, never a pro-rated slice. (2026-09-12 audit.)
        if (full) FullFillGuard.requireDelivered(received, amount);
        // Deliver the measured (wrapped) proceeds, capped at the signed amount; the
        // excess goes to the maker below. Never exceeds what this unwrap produced.
        SafeTransferLib.safeTransfer(wnative, receiver, received < amount ? received : amount);
        // Full mode's excess over the signed amount goes to the MAKER, never a caller.
        if (received > amount) SafeTransferLib.safeTransfer(wnative, onBehalfOf, received - amount);
    }

    receive() external payable {} // native from the provider's unwrap
}
