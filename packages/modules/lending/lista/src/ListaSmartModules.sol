// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {IProceedsAsset} from "@core/interfaces/IProceedsAsset.sol";
import {ITakeFloor} from "@lib/interfaces/ITakeFloor.sol";
import {DelegationHelper} from "@lib/DelegationHelper.sol";
import {PermitHelper} from "@lib/PermitHelper.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

import {IListaSmartProvider, IListaStableSwap, MarketParams} from "./interfaces/ILista.sol";

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
// EIP-2612 permit block @288 (+ signedValue@416): `(deadline, v, r, s)` = 128 bytes, plus an OPTIONAL
// trailing `signedValue` word. Without it the signature commits to THIS fill's slice
// and verifies only on a full fill; sign `signedValue = item total` for partial fills
// ({PermitHelper}, audit 2026-09-30 L-AAVE-2).
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
// ⚠ THE LEG IS PRICED IN COIN, THE ITEM IN LP (review 2026-10-06). The core prices
// `legsIn[0]` (coin) and measures the coin that lands; `item.amount` is LP. Nothing
// on-chain ties the two, so the maker's signature has to: sign
// `minOutRateE18 · item.amount / 1e18 ≥ legsIn[0].start` — then a one-coin removal
// that pays MORE than the leg is refunded to the maker and one that pays LESS cannot
// happen (the provider reverts under the rate). Signed looser, the shortfall
// between what landed and `legsIn[0]`'s `owed` is pulled from the maker's WALLET
// by {Core._payInputsToSolver} / `Batch._stepPull`. A StableSwap one-coin removal
// never yields exactly `owed`, so over-delivery is the normal case: on `matchSettle`
// it is refunded since core B-1 (2026-10-06); before that the netted path reverted.
// The lens now holds the maker to both halves (task 11, 2026-10-06), with no change
// to the blob: {proceedsAsset} reads the coin THROUGH the provider
// (`IListaSmartProvider(provider).dex().coins(coinIndex)`), so the stranded-proceeds
// preflight runs for this item; and {takeFloored} ({ITakeFloor}) reports
// `minOutRateE18 · item.amount / 1e18 ≥ legsIn[0].start ∧ legsIn[0].token == coin`,
// which `SettlementLensChecks.validateOrder` flags when false.
//
// `data = abi.encode(provider, moolah, coinIndex, minOutRateE18, MarketParams[, nonce, deadline, v, r, s])`
//   — provider@0, moolah@32, coinIndex@64, minOutRate@96, MarketParams@128
//     (base = 288); optional 160-byte {DelegationHelper.replayMorphoAuth}
//     block@288 (total 448).
//
contract ListaSmartTakerModule is ITakerModule, IProceedsAsset, ITakeFloor {
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

    /// @inheritdoc IProceedsAsset
    /// @dev The coin the provider pays out, read THROUGH the signed provider — the
    ///      blob names neither the dex nor the coin, and re-encoding it to carry one
    ///      would be BREAKING for every signed order. `dex().coins(i)` is the same
    ///      roster the provider itself pays from, so it cannot disagree with the
    ///      delivery. An out-of-range `coinIndex` reverts (the lens reads that as
    ///      "unknown"); the fill reverts on it too. A native index reports the
    ///      0xEeee… sentinel, which no ERC-20 leg can match — flagged, correctly.
    function proceedsAsset(bytes calldata data) public view override returns (address) {
        (address provider,, uint256 coinIndex) = abi.decode(data, (address, address, uint256));
        return IListaStableSwap(IListaSmartProvider(provider).dex()).coins(coinIndex);
    }

    /// @inheritdoc ITakeFloor
    /// @dev The LP→coin bridge the core cannot see (see the header): the full-fill
    ///      floor `item.amount · minOutRateE18 / 1e18` must cover `legsIn[0].start`,
    ///      and the leg must be denominated in the coin paid out. Floors computed
    ///      exactly as {takeOnBehalf} computes them; a rate whose multiply would
    ///      overflow reverts every fill, so it reports `false` rather than reverting.
    function takeFloored(uint256 amount, address legToken, uint256 legStart, bytes calldata data)
        external
        view
        override
        returns (bool)
    {
        uint256 rate = uint256(bytes32(data[96:128]));
        if (rate != 0 && amount > type(uint256).max / rate) return false;
        return amount * rate / 1e18 >= legStart && legToken == proceedsAsset(data);
    }
}
