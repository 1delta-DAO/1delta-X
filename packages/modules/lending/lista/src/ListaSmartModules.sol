// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {DelegationHelper} from "@lib/DelegationHelper.sol";
import {PermitHelper} from "@lib/PermitHelper.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

import {IListaSmartProvider, MarketParams} from "./interfaces/ILista.sol";

// ════════════════════════════════════════════════════════════════════════════
//  Lista SmartLP collateral modules (`SmartProvider` markets)
//
//  A SmartLP market's collateral token is a receipt over a two-coin StableSwap
//  LP that ONLY Moolah can hold (`mint`/`burn` minter-only, `transfer`
//  `onlyMoolah`) — no user, module, or composer can ever hold or approve it. So
//  the Morpho-shaped collateral modules are structurally unusable here, and the
//  legs run on the SmartProvider's OWN ABI instead ({IListaSmartProvider}):
//  deposits take a POOL COIN, withdrawals pay one back out.
//
//  This is exactly the seam the calldata-sdk's SmartLP route matrix says needs
//  "a dedicated adapter the user authorizes instead of the forwarder" — a
//  standing Moolah grant to a shared arbitrary-calldata forwarder would let
//  anyone drain the position, but a grant to THESE modules authorises only
//  maker-signed, settlement-dispatched calls: the Permit3 taker allowance keys
//  on `(module, keccak256(data), amount)`, so market, provider, coin index and
//  slippage floor are all frozen under the maker's signature.
//
//  ONE COIN PER LEG. An order leg is single-asset, so v1 ships the one-sided
//  shapes only: `supplyCollateral` with the other coin's amount = 0, and
//  `withdrawCollateralOneCoin`. Balanced two-coin entry/exit (and `supplyDexLp`
//  for accounts that somehow hold pool LP) stay out of scope. Native-coin pools
//  (the 0xEeee… sentinel coin, e.g. slisBNB & BNB) can only be entered/exited
//  through their ERC20 coin — the provider requires the native coin's amount to
//  equal `msg.value`, which a token-funded module never sends, so a native coin
//  index fails closed at the provider.
//
//  RATE-SCALED SLIPPAGE FLOORS. MAKE/TAKE amounts pro-rate per fill slice while
//  `data` is static, so absolute `minLp`/`minCoinOut` figures cannot be signed.
//  Both modules sign a RATE instead — floor-units per input-unit, 1e18-scaled —
//  and compute the per-slice floor as `amount * rate / 1e18`. StableSwap
//  one-sided adds/removes are near-linear at fill sizes; the maker prices the
//  margin into the rate.
// ════════════════════════════════════════════════════════════════════════════

// ──────────────────── SmartLP supply-collateral maker module ────────────────────
//
// Pulls `amount` of ONE pool coin from the maker via Permit3 and zaps it into
// the market's LP collateral on the maker's behalf. `supplyCollateral` has NO
// auth gate on the provider (anyone may fund anyone), so the receive side needs
// no Moolah authorization — only the coin approvals.
//
// `coin` MUST be `dex.coins(coinIndex)` (never derived from the symbol; the
// roster's coin order is authoritative). A mismatch fails closed: the provider
// `transferFrom`s the REAL pool coin from this module, which never approved it.
//
// `data = abi.encode(provider, coin, coinIndex, minLpRateE18, MarketParams[, deadline, v, r, s])`
//   — provider@0, coin@32, coinIndex@64, minLpRate@96, MarketParams@128
//     (base = 288); optional EIP-2612 permit@288.
//
contract ListaSmartSupplyCollateralModule is IMakerModule {
    IPermit3 public immutable permit3;
    address public immutable settlement;

    error NotSettlement();

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();

        (address provider, address coin, uint256 coinIndex, uint256 minLpRate, MarketParams memory mp) =
            abi.decode(data, (address, address, uint256, uint256, MarketParams));

        PermitHelper.replayIfPresent(data, 288, coin, onBehalfOf, address(permit3), amount);

        permit3.transferFrom(onBehalfOf, address(this), coin, uint160(amount));
        // Scoped approve + CLEAR: `provider` is decoded from order data on a
        // shared singleton, so it is attacker-choosable (F26/2c — same rule as
        // every venue approval in this package).
        SafeTransferLib.forceApprove(coin, provider, amount);
        // Per-slice floor: the position is credited with the LP ACTUALLY minted
        // (a balance delta on the provider side); `minLpRate` is the maker's
        // signed LP-per-coin floor. Checked math: a maker-authored overflowing
        // rate reverts the fill — fail closed.
        IListaSmartProvider(provider).supplyCollateral(
            mp,
            onBehalfOf,
            coinIndex == 0 ? amount : 0,
            coinIndex == 1 ? amount : 0,
            amount * minLpRate / 1e18
        );
        SafeTransferLib.forceApprove(coin, provider, 0);
    }
}

// ──────────────────── SmartLP withdraw-collateral taker module ────────────────────
//
// Burns `amount` LP units (the receipt Moolah accounts the position in) from the
// maker's position and pays ONE pool coin to `receiver`. ⚠ `amount` is
// denominated in LP UNITS — `Moolah.position(id, user).collateral` — while what
// `receiver` gets is the coin; `minOutRateE18` (coin-wei per LP-wei, 1e18-scaled)
// is the signed price floor between the two.
//
// The withdraw gates on `Moolah.isAuthorized(onBehalfOf, module)` (checked by
// the provider), so the maker's grant is the SAME Moolah authorization every
// other value-out leg in this package rides — grantable signature-only via the
// optional auth tail (target = the Moolah singleton, NOT the provider).
//
// Exact amounts only — no BalanceMode. Moolah collateral is static outside
// liquidation (no interest accrual on the receipt), so a full close sizes
// `amount` to the live position off-chain; if a liquidation moved the balance
// first, the burn reverts — fail closed, nothing partial.
//
// `data = abi.encode(provider, moolah, coinIndex, minOutRateE18, MarketParams[, nonce, deadline, v, r, s])`
//   — provider@0, moolah@32, coinIndex@64, minOutRate@96, MarketParams@128
//     (base = 288); optional 160-byte {DelegationHelper.replayMorphoAuth}
//     block@288 (total 448).
//
contract ListaSmartTakerModule is ITakerModule {
    IPermit3 public immutable permit3;

    error OnlyPermit3();

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        (address provider, address moolah, uint256 coinIndex, uint256 minOutRate, MarketParams memory mp) =
            abi.decode(data, (address, address, uint256, uint256, MarketParams));

        // Optional signature-only Moolah grant — best-effort, target is the
        // SINGLETON: the provider checks `Moolah.isAuthorized` but has no
        // sig-auth entrypoint of its own.
        DelegationHelper.replayMorphoAuth(data, 288, moolah, onBehalfOf, address(this));

        IListaSmartProvider(provider).withdrawCollateralOneCoin(
            mp, amount, coinIndex, amount * minOutRate / 1e18, onBehalfOf, receiver
        );
    }
}
