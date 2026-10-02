// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";
import {DustHandler} from "@lib/DustHandler.sol";
import {Narrow160} from "@lib/Narrow160.sol";
import {FundingPreflight} from "@lib/FundingPreflight.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {ITakerForModule} from "@core/interfaces/ITakerForModule.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {IFundingSource} from "@core/interfaces/IFundingSource.sol";
import {IProceedsAsset} from "@core/interfaces/IProceedsAsset.sol";

import {IFluidVault, IFluidVaultFactory, IWrappedNative} from "./interfaces/IFluid.sol";

// ════════════════════════════════════════════════════════════════════════════
//  Fluid (Vault protocol) modules
//
//  Every Fluid position mutation flows through ONE function,
//  `operate(nftId, newCol, newDebt, to)`, which applies a collateral leg and a
//  debt leg and runs a SINGLE health check at the end. The single-op modules
//  each submit a one-leg `operate`; the Level B `FluidOperateModule` submits a
//  two-leg `operate` (supply+borrow or payback+withdraw) so the legs share that
//  one check — the payoff of Fluid's architecture.
//
//  Two Fluid facts shape every module here:
//
//   1. Funding (supply / payback) is pulled by the *Liquidity* layer via the
//      vault's `liquidityCallback`, executed BY the vault and sourced from
//      `operate`'s `msg.sender`. So a funding module holds the token (pulled via
//      Permit3) and approves the VAULT — never the Liquidity layer. Supply and
//      payback are PERMISSIONLESS (no owner check), so the maker (deposit/repay)
//      modules need no NFT grant.
//
//   2. Value-out (borrow / withdraw) is authorised by a STRICT owner check inside
//      `operate`: `VAULT_FACTORY.ownerOf(nftId) != msg.sender` reverts, and Fluid
//      never consults ERC721 approvals. So a module can only borrow/withdraw if it
//      *is* the owner. Rather than take permanent custody, the taker modules do it
//      just-in-time: `transferFrom(user → module)` → `operate(... to = receiver)`
//      → `transferFrom(module → user)` in one call. This needs a one-time
//      `factory.setApprovalForAll(module, true)` from the user — the Fluid
//      analogue of Aave `approveDelegation`, but broader (it covers all the user's
//      positions on that factory; the Permit3 amount-gate + pinned `nftId` bound
//      each op). `setApprovalForAll` survives transfers, so one grant works across
//      fills.
//
//  `data` pins the vault/factory/token addresses the maker signed; Permit3
//  token/taker allowances are the per-fill gates.
//
//  ⚠ THE CUSTODY ROOT IS AN IMMUTABLE, NOT THE BLOB (2026-09-30 audit L-FSE-1).
//  "The signer pins their own vault, so pinning is self-authorising" holds only
//  for positions the SIGNER owns. Fluid authorises value-out by
//  `VAULT_FACTORY.ownerOf(nftId) == msg.sender`, so for an NFT that sits in a
//  module the MODULE is the authority, whoever signed. With `factory` and `vault`
//  taken from `data`, a module-resident NFT was claimable by anyone: (a) a no-op
//  FAKE factory made the custody pull a no-op while the REAL vault operated the
//  module-owned id; (b) a LYING vault on the `nftId == 0` open path returned a
//  module-owned id that the REAL factory then transferred out. So every custody
//  module ({FluidCustodyBase}) now pins the chain's one VaultFactory as an
//  immutable, requires the signed `factory` word to equal it, and binds the signed
//  `vault` to it (`factory.getVaultAddress(vault.VAULT_ID()) == vault`). With the
//  real factory, the pull `transferFrom(onBehalfOf, module, id)` reverts for an id
//  `onBehalfOf` does not own, and a factory-deployed vault mints honestly.
//
//  Amounts use `FluidBase.FLUID_ALL` (`type(uint256).max`) as the "all" sentinel,
//  mapping to Fluid's `type(int256).min` (withdraw-all collateral / repay-all
//  debt) — the same primitive the 1delta composer uses for full closes.
//
//  Scope: ERC20-token funding legs. Native-token (ETH) supply / payback needs
//  `msg.value` and is out of scope (it fails closed). Native-token VALUE-OUT
//  (withdraw from a native-collateral vault, borrow from a native-debt vault) is
//  delivered WRAPPED: the module routes `operate`'s `to_` to itself, measures the
//  ETH it received, wraps it and forwards the signed amount of WETH to `receiver`
//  (2026-09-30 audit L-FSE-3). Raw ETH could not reach the classic recipient-0
//  flow — Settlement has no `receive()` and core has no native path, so the
//  native send reverted the whole fill — and the family rule (C10) is that native
//  assets are wrapped inside modules, as CompoundV2Native / ListaNative do. A
//  native leg is therefore a WETH leg in the order.
// ════════════════════════════════════════════════════════════════════════════

/// @dev Shared funding / custody helpers.
abstract contract FluidBase {
    IPermit3 public immutable permit3;

    /// @dev "All" sentinel → Fluid's `type(int256).min` (withdraw-all / repay-all).
    uint256 internal constant FLUID_ALL = type(uint256).max;

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    /// @dev Pull `amount` of `token` from `user` and approve the VAULT to collect
    ///      it during `operate` — the vault's `liquidityCallback` runs the actual
    ///      `transferFrom(module → Liquidity)`, so the vault is the ERC20 spender.
    /// @dev ONE narrowing for both halves. The pull clips to `uint160` and the
    ///      approve did not, so a `data`-supplied amount just over 2^160 (the
    ///      composite paths pass `p.sideAmount`) pulled one wei while approving
    ///      ~1.46e48 to a `data`-chosen vault. F26/2d.
    function _pullAndApprove(address token, uint256 amount, address user, address vault) internal {
        permit3.transferFrom(user, address(this), token, Narrow160.to160(amount));
        SafeTransferLib.forceApprove(token, vault, amount);
    }

    /// @dev Return everything this module gained in `token` over an operation, and
    ///      only that, to `user`. `floor` is the balance held BEFORE it began.
    ///
    ///      ⚠ A DELTA, NOT THE WHOLE BALANCE. A funding module is pull-exact, so on
    ///      the normal path `floor` is 0 and this is the plain sweep it replaces. The
    ///      difference shows when it is not: a module address can be sent tokens by
    ///      anyone, and "sweep everything to the user" pays that to whoever happens
    ///      to be filling — and since anyone may be the maker of a one-unit order
    ///      against this module and asset, a stranded balance is claimable rather
    ///      than merely lost. The invariant worth holding is "the module ends where
    ///      it started", not "the module ends empty". Destination is still always
    ///      `user`, never a caller-chosen address.
    ///
    ///      Also clears the vault allowance — UNCONDITIONALLY, so no standing grant
    ///      outlives the call that needed it.
    ///
    ///      ⚠ The clear used to sit inside the refund branch, on the premise that
    ///      "nothing left over" means "the vault spent the whole approval". That
    ///      holds only for CONSERVING tokens: with a fee-on-transfer token the module
    ///      approves the nominal amount, receives less, an order-chosen vault pulls
    ///      the delta, the balance returns to `floor` — and the difference stayed
    ///      granted to that vault (2026-09-30 audit X-TOKENS-8). Every sibling clears
    ///      unconditionally (F25/A-3).
    function _returnUnused(address token, address user, address vault, uint256 floor) internal {
        SafeTransferLib.forceApprove(token, vault, 0);
        uint256 bal = SafeTransferLib.balanceOf(token, address(this));
        if (bal <= floor) return;
        unchecked {
            SafeTransferLib.safeTransfer(token, user, bal - floor); // bal > floor
        }
    }

    /// @dev A single-op module was handed the "open a fresh position" sentinel.
    error FreshPositionUnsupported();

    /// @dev Reject `nftId == 0` on the single-op legs. Fluid treats `0` as "mint a
    ///      NEW position", and `operate` mints it to `msg.sender` — this module.
    ///      These legs never take NFT custody and have no hand-off step, so the
    ///      freshly minted position (and the collateral just supplied into it)
    ///      would be stranded in the module permanently, owned by a contract with
    ///      no transfer path — the user's funds are gone, which is worse than a
    ///      revert. (Before the custody modules pinned the VaultFactory, a
    ///      module-resident NFT was not even "merely lost": anyone could operate it
    ///      through a custody module — see {FluidCustodyBase}.)
    ///
    ///      Opening a position is `FluidOperateModule`'s Open path, which is built
    ///      for it: it captures the minted `id` from `operate`'s return value and
    ///      hands the NFT to the user in the same call.
    function _requireExistingPosition(uint256 nftId) internal pure {
        if (nftId == 0) revert FreshPositionUnsupported();
    }

    /// @dev The signed position is not the maker's.
    error NotPositionOwner(uint256 nftId, address owner);

    /// @dev Bind a VALUE-IN leg's `nftId` to the maker (2026-09-30 audit L-CENSUS-8
    ///      (3)). Supply and payback are permissionless on Fluid, so a signed id that
    ///      is not the maker's — a typo, a stale id after a close — used to spend the
    ///      maker's funds on a stranger's position. The owner is read from the
    ///      vault's OWN factory (`constantsView().factory`): `vault` is maker-signed
    ///      and this leg only ever moves the maker's money, so a lying vault can
    ///      only misdirect its own signer's funds — the same posture as before, minus
    ///      the honest-mistake gift. The "cheap insurance" Liquity and Gearbox take.
    function _requirePositionOwner(address vault, uint256 nftId, address user) internal view {
        (, address factory,,,,) = IFluidVault(vault).constantsView();
        address owner = IFluidVaultFactory(factory).ownerOf(nftId);
        if (owner != user) revert NotPositionOwner(nftId, owner);
    }

    /// @dev `uint256 → int256` guarding the high bit (always true for real amounts).
    function _signed(uint256 x) internal pure returns (int256) {
        require(x <= uint256(type(int256).max), "amount overflow");
        return int256(x);
    }

    /// @dev A negative (withdraw / payback) delta, mapping `FLUID_ALL` to Fluid's
    ///      `type(int256).min` max sentinel.
    function _negDelta(uint256 amount) internal pure returns (int256) {
        return amount == FLUID_ALL ? type(int256).min : -_signed(amount);
    }
}

/// @dev The JIT-custody modules' shared root: the TRUSTED VaultFactory and the
///      wrapped-native token, both immutables — never read from order `data`.
///
///      Why the factory cannot come from `data` (2026-09-30 audit L-FSE-1): Fluid's
///      value-out check is `VAULT_FACTORY.ownerOf(nftId) == msg.sender`, so for an
///      NFT a module ITSELF owns the module is the authority whoever signed. A
///      blob-supplied factory turned the custody pull into a no-op (fake factory +
///      real vault drained a module-resident position), and a blob-supplied vault
///      on the fresh-open path could return a module-owned id that the real
///      factory then transferred out. {_bindVault} closes both: the signed factory
///      must BE the pinned one, and the signed vault must be a vault that factory
///      deployed. With the real factory the custody pull reverts for any id
///      `onBehalfOf` does not own, and a factory-deployed vault mints honestly.
///
///      The native delivery helpers live here too (L-FSE-3): see {_operateOut}.
abstract contract FluidCustodyBase is FluidBase {
    /// @notice The chain's Fluid VaultFactory — the only custody root these modules
    ///         accept.
    address public immutable vaultFactory;
    /// @notice The wrapped-native token a native value-out is delivered in (WETH).
    address public immutable wrappedNative;

    /// @dev Fluid's native-token sentinel in `constantsView`.
    address internal constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @dev The signed `factory` word is not the pinned VaultFactory.
    error WrongFactory(address signed, address pinned);
    /// @dev The signed `vault` was not deployed by the pinned VaultFactory.
    error UnknownVault(address vault);
    /// @dev A native value-out delivered less ETH than the signed amount.
    error ShortNativeDelivery(uint256 received, uint256 amount);

    constructor(address _permit3, address _vaultFactory, address _wrappedNative) FluidBase(_permit3) {
        vaultFactory = _vaultFactory;
        wrappedNative = _wrappedNative;
    }

    /// @dev Native value-out lands here (`operate(..., to = this)`), measured as a
    ///      delta around the venue call — a stray ETH balance is never forwarded.
    receive() external payable {}

    /// @dev Bind the order-named `factory` and `vault` to the pinned VaultFactory.
    function _bindVault(address vault, address factory) internal view {
        if (factory != vaultFactory) revert WrongFactory(factory, vaultFactory);
        if (IFluidVaultFactory(vaultFactory).getVaultAddress(IFluidVault(vault).VAULT_ID()) != vault) {
            revert UnknownVault(vault);
        }
    }

    /// @dev `operate` with the value-out leg delivered as an ERC-20 to `receiver`.
    ///
    ///      The value-out token is the vault's BORROW token when `newDebt > 0` (a
    ///      borrow), else its SUPPLY token (a withdraw). When that token is NATIVE,
    ///      Fluid would send raw ETH to `to_` — which reverts against Settlement (no
    ///      `receive()`, no native path in core), the classic recipient-0 flow. So
    ///      the ETH is routed HERE, measured as a delta, wrapped, and exactly
    ///      `amount` of WETH goes to `receiver`; a short delivery reverts rather than
    ///      letting core bill the gap to the maker's wallet (I-8); any excess (only a
    ///      mid-call donation could make one) goes back to `onBehalfOf`.
    function _operateOut(
        address vault,
        uint256 nftId,
        int256 newCol,
        int256 newDebt,
        uint256 amount,
        address receiver,
        address onBehalfOf
    ) internal returns (uint256 id) {
        bool native;
        if (amount != 0) {
            (,,,, address supplyToken, address borrowToken) = IFluidVault(vault).constantsView();
            native = (newDebt > 0 ? borrowToken : supplyToken) == NATIVE;
        }
        if (!native) {
            (id,,) = IFluidVault(vault).operate(nftId, newCol, newDebt, receiver);
            return id;
        }
        uint256 ethBefore = address(this).balance;
        (id,,) = IFluidVault(vault).operate(nftId, newCol, newDebt, address(this));
        uint256 received = address(this).balance - ethBefore;
        if (received < amount) revert ShortNativeDelivery(received, amount);
        IWrappedNative(wrappedNative).deposit{value: received}();
        SafeTransferLib.safeTransfer(wrappedNative, receiver, amount);
        if (received > amount) SafeTransferLib.safeTransfer(wrappedNative, onBehalfOf, received - amount);
    }
}

// ──────────────────── Fluid deposit maker module ────────────────────
//
// Single-op maker: pulls the vault's collateral token from the user via Permit3,
// then supplies it into the user's existing position. Permissionless on Fluid's
// side — no NFT grant needed; only a Permit3 token allowance. `nftId` must be an
// existing position — `nftId == 0` (Fluid's "mint a fresh position" sentinel) is
// REJECTED, since the new NFT would mint to this module and strand the supplied
// collateral; open a new position via `FluidOperateModule` Open instead. ERC20
// collateral only.
//
// `data = abi.encode(address vault, address collateralToken, uint256 nftId)`.
//
contract FluidDepositModule is IMakerModule, FluidBase {
    error NotSettlement();

    address public immutable settlement;

    constructor(address _permit3, address _settlement) FluidBase(_permit3) {
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();

        (address vault, address collateralToken, uint256 nftId) = abi.decode(data, (address, address, uint256));
        _requireExistingPosition(nftId);
        _requirePositionOwner(vault, nftId, onBehalfOf);

        uint256 floor = SafeTransferLib.balanceOf(collateralToken, address(this));
        _pullAndApprove(collateralToken, amount, onBehalfOf, vault);
        IFluidVault(vault).operate(nftId, _signed(amount), 0, address(0));
        // Return what `operate` did not consume AND clear the vault grant. The
        // composite `_open` path was already fixed for exactly this ("a short pull
        // stranded the difference here permanently along with a live vault allowance
        // over it. Symmetric now") — these two single-op makers were never migrated,
        // so `vault`, decoded from order `data` on a shared singleton, kept a
        // standing claim and any short-pull was stranded forever. F26/2c.
        _returnUnused(collateralToken, onBehalfOf, vault, floor);
    }
}

// ──────────────────── Fluid repay maker module ────────────────────
//
// Single-op maker: pays back the user's debt. Payback is permissionless on Fluid
// ⇒ no NFT grant, but the position must be the MAKER's ({_requirePositionOwner}).
// `nonReentrant` guards weird-token transfer hooks during the Permit3 pull.
//
//   `Exact` (default): pays back exactly `amount`, pull-exact. `amount` must not
//     exceed the live debt — Fluid reverts an over-payback of a literal amount.
//   `Full` (the TAGGED mode word, `DustHandler.encodeMode(Full)` = 0xB0DE0001):
//     THE LIVE-DEBT CLAMP (2026-09-30 audit L-CENSUS-8 (4)). `amount` is a CEILING:
//     the module pulls it, pays back with Fluid's repay-ALL sentinel
//     (`type(int256).min`, so the vault consumes exactly the live debt), and returns
//     the unused buffer to the maker. A debt above the ceiling fails closed on the
//     scoped vault approval. FULL-FILL ONLY: `totalAmount`@128 is mandatory and the
//     slice must equal it ({FullFillGuard}) — a slice of a ceiling is not a ceiling.
//     Interest accrued between signing and fill is no longer a revert.
//
// `data = abi.encode(address vault, address debtToken, uint256 nftId[, uint256 mode[, uint256 totalAmount]])`
//   — vault@0, debtToken@32, nftId@64 (base = 96); mode@96; totalAmount@128.
//
contract FluidRepayModule is IMakerModule, FluidBase {
    uint256 private _locked = 1;

    error Reentrancy();
    error NotSettlement();

    address public immutable settlement;

    constructor(address _permit3, address _settlement) FluidBase(_permit3) {
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();
        if (_locked != 1) revert Reentrancy();
        _locked = 2;

        (address vault, address debtToken, uint256 nftId) = abi.decode(data, (address, address, uint256));
        _requireExistingPosition(nftId);
        _requirePositionOwner(vault, nftId, onBehalfOf);
        bool full = DustHandler.readBalanceMode(data, 96) == DustHandler.BalanceMode.Full;
        if (full) FullFillGuard.requireFullFillFromData(data, 128, amount);

        if (amount > 0) {
            uint256 floor = SafeTransferLib.balanceOf(debtToken, address(this));
            _pullAndApprove(debtToken, amount, onBehalfOf, vault);
            // `Full`: repay-ALL — the vault takes exactly the live debt, bounded by
            // the `amount` approval just granted; the rest is returned below.
            IFluidVault(vault).operate(nftId, 0, full ? type(int256).min : -_signed(amount), address(0));
        // Return what `operate` did not consume AND clear the vault grant. The
        // composite `_open` path was already fixed for exactly this ("a short pull
        // stranded the difference here permanently along with a live vault allowance
        // over it. Symmetric now") — these two single-op makers were never migrated,
        // so `vault`, decoded from order `data` on a shared singleton, kept a
        // standing claim and any short-pull was stranded forever. F26/2c.
            _returnUnused(debtToken, onBehalfOf, vault, floor);
        }

        _locked = 1;
    }
}

// ──────────────────── Fluid combined taker module ────────────────────
//
// Fuses the borrow and withdraw value-out legs into a SINGLE contract. A leading
// `op` flag in `data` selects the leg, so a user who runs the full leverage
// round-trip authorises ONE module address instead of two — a single
// `factory.setApprovalForAll(this, true)` covers both borrow and withdraw, and the
// broad ERC721 operator grant the value-out modules rely on is granted just once.
//
// Both legs use the same just-in-time NFT custody: pull the position NFT in,
// `operate`, hand it back. Borrow sends the borrowed debt token to `receiver`;
// withdraw sends collateral straight to `receiver` (Fluid sends an ERC-20 via
// `operate`'s `to_`, so the module never holds it). A NATIVE value-out is routed
// through the module and delivered as WETH — see {FluidCustodyBase._operateOut}.
// `factory` must be the pinned VaultFactory and `vault` one it deployed
// ({FluidCustodyBase._bindVault}).
// The withdrawal is exact; a true "withdraw all" is the `FluidOperateModule` Close
// path (where the debt leg's repay-all clears the position first).
//
// Safety is unchanged from the split modules: the Permit3 taker allowance is keyed
// by `ref = keccak256(data)`, and `op` is the first word of `data`, so borrow-data
// and withdraw-data hash to DIFFERENT refs. The user therefore still grants a
// separate amount-gated allowance per leg — the pinned `nftId` is the position the
// user authorised, and the flag cannot be flipped to spend a borrow allowance on a
// withdraw (or vice-versa).
//
//   data byte-map (op first; old single-op offsets shift +32):
//     op@0, vault@32, factory@64, nftId@96  → base length 128 (no trailing fields).
//
//   op = 0 (Borrow):   operate(nftId, 0, +amount, receiver)            — borrow debt.
//   op = 1 (Withdraw): operate(nftId, -amount, 0, receiver)            — withdraw collateral.
//
//   data = abi.encode(uint8 op, address vault, address factory, uint256 nftId).
//
contract FluidTakerModule is ITakerModule, FluidCustodyBase {
    enum Op {
        Borrow, // 0 — borrow debt to receiver
        Withdraw // 1 — withdraw collateral to receiver
    }

    /// @dev Same guard as {FluidOperateModule} / {FluidTakeForModule} (2026-09-30
    ///      audit L-CENSUS-8 (5)): the NFT sits in this module between the custody
    ///      pull and the hand-back, and `_operateOut` makes an external call to the
    ///      vault and, on a native leg, to `receiver` via WETH in between. The
    ///      Permit3 take lock covers the shipped path; this keeps the module sound on
    ///      its own rather than by an outer contract's invariant.
    uint256 private _locked = 1;

    error OnlyPermit3();
    error BadOp(uint8 op);
    error Reentrancy();

    constructor(address _permit3, address _vaultFactory, address _wrappedNative)
        FluidCustodyBase(_permit3, _vaultFactory, _wrappedNative)
    {}

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();
        if (_locked != 1) revert Reentrancy();
        _locked = 2;

        (uint8 op, address vault, address factory, uint256 nftId) = abi.decode(data, (uint8, address, address, uint256));
        if (op > uint8(Op.Withdraw)) revert BadOp(op);
        _bindVault(vault, factory);

        IFluidVaultFactory(vaultFactory).transferFrom(onBehalfOf, address(this), nftId);
        if (op == uint8(Op.Borrow)) {
            _operateOut(vault, nftId, 0, _signed(amount), amount, receiver, onBehalfOf);
        } else {
            _operateOut(vault, nftId, -_signed(amount), 0, amount, receiver, onBehalfOf);
        }
        IFluidVaultFactory(vaultFactory).transferFrom(address(this), onBehalfOf, nftId);
        _locked = 1;
    }
}

// ──────────────────── Fluid operate taker module (Level B) ────────────────────
//
// Composite module that fuses a collateral leg and a debt leg into a SINGLE
// `operate`, so both share Fluid's one health check instead of one per leg — the
// architectural payoff of Fluid's design. Two shapes:
//
//   • Open  — supply `sideAmount` collateral (module-funded via Permit3) + borrow
//             `amount` to `receiver`. `nftId == 0` opens a FRESH position: `operate`
//             mints it to this module, which then hands it to the user. `nftId != 0`
//             adds to an existing position (NFT pulled in / handed back).
//   • Close — pay back `sideAmount` of debt (module-funded) + withdraw `amount`
//             collateral to `receiver`. `sideAmount == FLUID_ALL` repays ALL debt:
//             the module pulls `repayCeiling` as a buffer, Fluid consumes the exact
//             live debt, and the residual is swept back to the user — the 1delta
//             composer's full-close pattern. The collateral withdrawal is the exact,
//             Permit3-gated `amount`. Fluid applies the payback before the withdraw,
//             so the single health check sees the reduced debt.
//
// Trade-off vs single-op: one module signs a whole two-leg operate under one
// `keccak256(data)` taker ref, deliberately giving up the "one module = one action"
// blast-radius invariant. The user grants `setApprovalForAll` once (not needed for
// Open-fresh, which has no NFT to pull in).
//
contract FluidOperateModule is ITakerModule, FluidCustodyBase {
    enum Mode {
        Open, // 0 — supply collateral + borrow
        Close // 1 — payback debt + withdraw collateral
    }

    struct OperateData {
        uint256 mode;
        address vault;
        address factory;
        address fundingToken; // Open: collateral token; Close: debt token (pulled + residual swept)
        uint256 nftId; // 0 ⇒ Open a fresh position
        uint256 sideAmount; // Open: collateral to supply; Close: debt to repay (FLUID_ALL ⇒ repay-all)
        uint256 repayCeiling; // Close + repay-all only: buffer to pull (ignored otherwise)
        /// @dev The item's FULL maker-signed amount. Composite ops are full-fill
        ///      only — see {FullFillGuard}.
        uint256 totalAmount;
    }

    error OnlyPermit3();

    uint256 private _locked = 1;

    error Reentrancy();

    constructor(address _permit3, address _vaultFactory, address _wrappedNative)
        FluidCustodyBase(_permit3, _vaultFactory, _wrappedNative)
    {}

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();
        if (_locked != 1) revert Reentrancy();
        _locked = 2;

        OperateData memory p = abi.decode(data, (OperateData));

        // Composite items execute a multi-leg position op whose side leg lives in
        // `data` and does NOT pro-rate. Reject a sliced fill outright — see {FullFillGuard}.
        FullFillGuard.requireFullFill(amount, p.totalAmount);

        // `Mode(p.mode)` straight from the uint256 is range-checked (Panic 0x21 on
        // anything but 0/1); `Mode(uint8(p.mode))` first truncated mod 256, so
        // `mode = 256` ran Open while off-chain decoders rejected it (re-audit F30).
        Mode mode = Mode(p.mode);
        // The custody root and the vault are bound BEFORE either path touches an NFT
        // (L-FSE-1) — see {FluidCustodyBase._bindVault}.
        _bindVault(p.vault, p.factory);
        if (mode == Mode.Open) {
            _open(p, onBehalfOf, receiver, amount);
        } else {
            _close(p, onBehalfOf, receiver, amount);
        }

        _locked = 1;
    }

    /// @dev supply `sideAmount` collateral (module-funded) + borrow `borrowAmount`
    ///      to `receiver` in one operate. A fresh position (`nftId == 0`) mints to
    ///      this module then is handed to the user; an existing position is pulled
    ///      in and handed back.
    function _open(OperateData memory p, address user, address receiver, uint256 borrowAmount) private {
        // The Open path had NO residual handling at all, where Close has always had
        // one. `operate` is expected to consume the whole supply leg, but "expected
        // to" is not an invariant this module can enforce from the outside, and the
        // asymmetry meant a short pull stranded the difference here permanently
        // along with a live vault allowance over it. Symmetric now.
        uint256 floor = SafeTransferLib.balanceOf(p.fundingToken, address(this));
        _pullAndApprove(p.fundingToken, p.sideAmount, user, p.vault);

        if (p.nftId != 0) IFluidVaultFactory(vaultFactory).transferFrom(user, address(this), p.nftId);
        uint256 id = _operateOut(
            p.vault, p.nftId, _signed(p.sideAmount), _signed(borrowAmount), borrowAmount, receiver, user
        );
        uint256 outId = p.nftId != 0 ? p.nftId : id;
        IFluidVaultFactory(vaultFactory).transferFrom(address(this), user, outId);

        _returnUnused(p.fundingToken, user, p.vault, floor);
    }

    /// @dev pay back `sideAmount` debt (module-funded; repay-all over-pulls
    ///      `repayCeiling` and sweeps the residual back to the user) + withdraw
    ///      `colAmount` collateral to `receiver` in one operate.
    function _close(OperateData memory p, address user, address receiver, uint256 colAmount) private {
        uint256 floor = SafeTransferLib.balanceOf(p.fundingToken, address(this));
        uint256 pullAmt = p.sideAmount == FLUID_ALL ? p.repayCeiling : p.sideAmount;
        if (pullAmt > 0) _pullAndApprove(p.fundingToken, pullAmt, user, p.vault);

        IFluidVaultFactory(vaultFactory).transferFrom(user, address(this), p.nftId);
        _operateOut(p.vault, p.nftId, -_signed(colAmount), _negDelta(p.sideAmount), colAmount, receiver, user);
        IFluidVaultFactory(vaultFactory).transferFrom(address(this), user, p.nftId);

        // Return the over-pulled repay buffer (always the user, never a
        // caller-chosen address) — measured as the delta over what this module held
        // before the pull, not as its whole balance. See {_returnUnused}.
        _returnUnused(p.fundingToken, user, p.vault, floor);
    }
}

// ──────────────── Fluid TAKE_FOR open module (core-funded collateral) ────────────────
//
// The same one-`operate` supply+borrow as {FluidOperateModule}'s Open path, but the
// collateral amount arrives as the settler's `forAmount` instead of a `sideAmount`
// constant sitting in `data`. Fluid is the sharpest test of that difference,
// because Fluid is where the constant hurt most:
//
//  1. `operate` applies the collateral leg and the debt leg under ONE health check,
//     so fusing them is the architectural payoff — unchanged here.
//  2. But `sideAmount` does not pro-rate, so {FluidOperateModule} had to reject
//     every partial fill ({FullFillGuard}) even on an EXISTING position, where
//     Fluid is perfectly happy to be added to repeatedly. `forAmount` is sliced by
//     the core, so that restriction lifts: an existing-position open now partial-
//     fills, one `operate` per slice, each supplying exactly what it borrowed
//     against.
//  3. `nftId == 0` is genuinely different and STAYS full-fill only. A fresh
//     `operate` MINTS a position, so N slices make N positions rather than one
//     partially-opened one. That is position IDENTITY, not arithmetic — no amount
//     encoding can fix it, which is exactly the case {FullFillGuard} was written
//     for and the case it is still right for.
//
// `data = abi.encode(OpenData{forDesc, forCap, vault, factory, collateralToken,
//                             nftId, totalAmount})` — `forDesc` FIRST and `forCap`
// second because {Base._forSlice} reads words 0 and 1 of the blob.
//   • forDesc `(1 << 255) | j`            fund from `legsOut[j]` (the levered shape)
//   • forDesc `(3 << 254) | (floorBps << 160) | uint160(tok)` fund with
//     `min(balance, forCap)`, reverting below `floorBps` of the cap — the
//                                         no-conversion "deposit what I hold" shape,
//                                         which the core makes full-fill only
//   • forDesc a plain total               a fixed amount, sliced pro-rata
//   • totalAmount                         only read on the `nftId == 0` path
//
// Close (payback + withdraw) is mechanically the same call with the signs flipped;
// it stays on {FluidOperateModule} because its useful mode is repay-ALL, which is a
// live-debt sentinel plus an over-pull buffer rather than a settler-sized amount.
//
contract FluidTakeForModule is ITakerForModule, IFundingSource, IProceedsAsset, FluidCustodyBase {
    /// @dev The ONLY spender allowed to reach this module's PRE-FUND funding.
    ///      `Permit3.takeFor` is permissionless (F27/C-1).
    address public immutable settlement;

    error OnlyPermit3();
    error Reentrancy();

    uint256 private _locked = 1;

    struct OpenData {
        uint256 forDesc; //        word 0 — the funding descriptor {Base._forSlice} reads
        uint256 forCap; //         word 1 — the balance form's mandatory cap
        address vault;
        address factory;
        address collateralToken;
        uint256 nftId; //          0 ⇒ open a FRESH position (full-fill only)
        uint256 totalAmount; //    the item's full signed amount; fresh-open path only
    }

    constructor(address _permit3, address _settlement, address _vaultFactory, address _wrappedNative)
        FluidCustodyBase(_permit3, _vaultFactory, _wrappedNative)
    {
        settlement = _settlement;
    }

    /// @param amount    this fill's slice of the BORROW leg (taker-allowance gated).
    /// @param forAmount this fill's COLLATERAL, sized by the core.
    function takeForOnBehalf(
        address spender,
        address onBehalfOf,
        uint256 amount,
        uint256 forAmount,
        address receiver,
        bytes calldata data
    ) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();
        // Pinned for BOTH shapes: Settlement is the sole legitimate spender
        // either way, and one unconditional check beats a branch (F27/C-1).
        PreFundGuard.requireSettlement(spender, settlement);
        if (_locked != 1) revert Reentrancy();
        _locked = 2;

        OpenData memory p = abi.decode(data, (OpenData));
        _bindVault(p.vault, p.factory);

        // See note 3 in the header: a fresh mint cannot be sliced, whatever the
        // amounts say. An existing position is added to and slices freely.
        if (p.nftId == 0) FullFillGuard.requireFullFill(amount, p.totalAmount);

        // ⚠ THE FLOOR MUST BE THE *PRE-DELIVERY* BALANCE, AND ON THE PUSH SHAPE THAT
        // IS NOT WHAT `balanceOf` READS. Settlement delivers output legs BEFORE it
        // runs items, so by the time this module has control the pre-funded leg has
        // already landed: a plain `balanceOf` here is `preExisting + forAmount`. With
        // that as the floor, `bal <= floor` held for EVERY outcome, so
        // `_returnUnused` short-circuited unconditionally — the maker never got the
        // unconsumed remainder back, and the scoped `forceApprove(vault, 0)` that
        // lives inside its taken branch was unreachable, leaving a standing grant to
        // an order-decoded (attacker-choosable) `vault`. Subtracting the delivery
        // restores both: an under-consuming `operate` now leaves `bal > floor`, which
        // refunds the maker AND clears the grant.
        bool isPreFund = uint256(bytes32(data[0:32])) >> 253 == 5;
        uint256 floor = isPreFund
            ? PreFundGuard.floorOf(data, p.collateralToken, forAmount)
            : SafeTransferLib.balanceOf(p.collateralToken, address(this));
        if (forAmount != 0) {
            if (isPreFund) {
                // PRE-FUND: the delivery already landed here, and `floor` above
                // subtracted it — so the floor really is the pre-existing balance and
                // the delta accounting below is exact. The vault's
                // `liquidityCallback` still pulls via the approval.
                SafeTransferLib.forceApprove(p.collateralToken, p.vault, forAmount);
            } else {
                // PULL: drawn out of the maker's wallet, then approved to the vault.
                _pullAndApprove(p.collateralToken, forAmount, onBehalfOf, p.vault);
            }
        }

        _custodyOperate(p, onBehalfOf, amount, forAmount, receiver);

        // Anything `operate` did not take is returned, and the vault allowance dies
        // with the call — see {FluidBase._returnUnused}.
        _returnUnused(p.collateralToken, onBehalfOf, p.vault, floor);

        _locked = 1;
    }

    /// @dev Strict-ownerOf: take custody just-in-time, `operate`, hand it straight
    ///      back (the freshly minted id on the `nftId == 0` path). Its own frame —
    ///      the native-delivery arguments overflow the entrypoint's stack.
    function _custodyOperate(
        OpenData memory p,
        address onBehalfOf,
        uint256 amount,
        uint256 forAmount,
        address receiver
    ) private {
        if (p.nftId != 0) IFluidVaultFactory(vaultFactory).transferFrom(onBehalfOf, address(this), p.nftId);
        uint256 id = _operateOut(p.vault, p.nftId, _signed(forAmount), _signed(amount), amount, receiver, onBehalfOf);
        IFluidVaultFactory(vaultFactory).transferFrom(address(this), onBehalfOf, p.nftId != 0 ? p.nftId : id);
    }

    /// @inheritdoc IFundingSource
    /// @dev Reports the COLLATERAL token only. The position NFT is also pulled from
    ///      the maker (strict-`ownerOf` custody, handed straight back), but it is not
    ///      the funding leg: it carries no amount, it is never what a descriptor
    ///      sizes, and it is authorised by an ERC-721 approval rather than the
    ///      Permit3 book. Reporting it here would make the lens compare an ERC-721
    ///      against `legsOut[j].token` and reject every well-formed Fluid order.
    function fundingSource(address onBehalfOf, bytes calldata data)
        external
        view
        override
        returns (address asset, uint256 available)
    {
        asset = abi.decode(data, (OpenData)).collateralToken;
        available = uint256(bytes32(data[0:32])) >> 253 == 5
            ? type(uint256).max
            : FundingPreflight.pullable(permit3, address(this), onBehalfOf, asset);
    }

    /// @inheritdoc IProceedsAsset
    /// @dev The vault's BORROW token, read from the vault itself (`constantsView`)
    ///      rather than signed — so it cannot disagree with what `operate` pays out.
    ///      A native-debt vault reports the WRAPPED native token, which is what
    ///      {FluidCustodyBase._operateOut} delivers.
    function proceedsAsset(bytes calldata data) external view override returns (address) {
        (,,,,, address borrowToken) = IFluidVault(abi.decode(data, (OpenData)).vault).constantsView();
        return borrowToken == NATIVE ? wrappedNative : borrowToken;
    }
}
