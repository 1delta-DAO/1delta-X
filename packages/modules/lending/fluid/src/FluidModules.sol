// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {FullFillGuard} from "@core/utils/FullFillGuard.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";

import {IFluidVault, IFluidVaultFactory} from "./interfaces/IFluid.sol";

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
//  `data` pins the vault/factory/token addresses (the position owner signs their
//  own order, so pinning is self-authorising and robust across Fluid's vault
//  variants; Permit3 token/taker allowances are the real gates).
//
//  Amounts use `FluidBase.FLUID_ALL` (`type(uint256).max`) as the "all" sentinel,
//  mapping to Fluid's `type(int256).min` (withdraw-all collateral / repay-all
//  debt) — the same primitive the 1delta composer uses for full closes.
//
//  Scope: ERC20-token funding legs. Native-token (ETH) supply needs `msg.value`
//  and is out of scope; native-token *withdraw* still works (it flows straight to
//  `receiver` via `operate`'s `to_`, the module never touches the token).
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
    function _pullAndApprove(address token, uint256 amount, address user, address vault) internal {
        permit3.transferFrom(user, address(this), token, uint160(amount));
        SafeTransferLib.forceApprove(token, vault, amount);
    }

    /// @dev A single-op module was handed the "open a fresh position" sentinel.
    error FreshPositionUnsupported();

    /// @dev Reject `nftId == 0` on the single-op legs. Fluid treats `0` as "mint a
    ///      NEW position", and `operate` mints it to `msg.sender` — this module.
    ///      These legs never take NFT custody and have no hand-off step, so the
    ///      freshly minted position (and the collateral just supplied into it)
    ///      would be stranded in the module permanently, owned by a contract with
    ///      no transfer path. It is not a theft — nobody can reach it either — but
    ///      the user's funds are gone, which is worse than a revert.
    ///
    ///      Opening a position is `FluidOperateModule`'s Open path, which is built
    ///      for it: it captures the minted `id` from `operate`'s return value and
    ///      hands the NFT to the user in the same call.
    function _requireExistingPosition(uint256 nftId) internal pure {
        if (nftId == 0) revert FreshPositionUnsupported();
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

        _pullAndApprove(collateralToken, amount, onBehalfOf, vault);
        IFluidVault(vault).operate(nftId, _signed(amount), 0, address(0));
    }
}

// ──────────────────── Fluid repay maker module ────────────────────
//
// Single-op maker: pays back `amount` of the user's debt, pull-exact (pulls
// exactly what it pays, so the module never holds a residual). `amount` must not
// exceed the live debt — Fluid reverts an over-payback of a literal amount; the
// off-chain layer sizes it under the debt (a full close is the `FluidOperateModule`
// Close path, which over-pulls a ceiling, uses the repay-all sentinel, and sweeps
// the residual). Payback is permissionless ⇒ no NFT grant. `nonReentrant` guards
// weird-token transfer hooks during the Permit3 pull.
//
// `data = abi.encode(address vault, address debtToken, uint256 nftId)`.
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

        if (amount > 0) {
            _pullAndApprove(debtToken, amount, onBehalfOf, vault);
            IFluidVault(vault).operate(nftId, 0, -_signed(amount), address(0));
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
// withdraw sends collateral straight to `receiver` (Fluid sends it via `operate`'s
// `to_`, so the module never holds the token — native-collateral vaults work too).
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
contract FluidTakerModule is ITakerModule, FluidBase {
    enum Op {
        Borrow, // 0 — borrow debt to receiver
        Withdraw // 1 — withdraw collateral to receiver

    }

    error OnlyPermit3();
    error BadOp(uint8 op);

    constructor(address _permit3) FluidBase(_permit3) {}

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        (uint8 op, address vault, address factory, uint256 nftId) =
            abi.decode(data, (uint8, address, address, uint256));

        IFluidVaultFactory(factory).transferFrom(onBehalfOf, address(this), nftId);
        if (op == uint8(Op.Borrow)) {
            IFluidVault(vault).operate(nftId, 0, _signed(amount), receiver);
        } else if (op == uint8(Op.Withdraw)) {
            IFluidVault(vault).operate(nftId, -_signed(amount), 0, receiver);
        } else {
            revert BadOp(op);
        }
        IFluidVaultFactory(factory).transferFrom(address(this), onBehalfOf, nftId);
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
contract FluidOperateModule is ITakerModule, FluidBase {
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

    constructor(address _permit3) FluidBase(_permit3) {}

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();
        if (_locked != 1) revert Reentrancy();
        _locked = 2;

        OperateData memory p = abi.decode(data, (OperateData));

        // Composite items execute a multi-leg position op whose side leg lives in
        // `data` and does NOT pro-rate. Reject a sliced fill outright — see {FullFillGuard}.
        FullFillGuard.requireFullFill(amount, p.totalAmount);

        if (Mode(uint8(p.mode)) == Mode.Open) {
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
        _pullAndApprove(p.fundingToken, p.sideAmount, user, p.vault);

        if (p.nftId != 0) IFluidVaultFactory(p.factory).transferFrom(user, address(this), p.nftId);
        (uint256 id,,) = IFluidVault(p.vault).operate(p.nftId, _signed(p.sideAmount), _signed(borrowAmount), receiver);
        uint256 outId = p.nftId != 0 ? p.nftId : id;
        IFluidVaultFactory(p.factory).transferFrom(address(this), user, outId);
    }

    /// @dev pay back `sideAmount` debt (module-funded; repay-all over-pulls
    ///      `repayCeiling` and sweeps the residual back to the user) + withdraw
    ///      `colAmount` collateral to `receiver` in one operate.
    function _close(OperateData memory p, address user, address receiver, uint256 colAmount) private {
        uint256 pullAmt = p.sideAmount == FLUID_ALL ? p.repayCeiling : p.sideAmount;
        if (pullAmt > 0) _pullAndApprove(p.fundingToken, pullAmt, user, p.vault);

        IFluidVaultFactory(p.factory).transferFrom(user, address(this), p.nftId);
        IFluidVault(p.vault).operate(p.nftId, -_signed(colAmount), _negDelta(p.sideAmount), receiver);
        IFluidVaultFactory(p.factory).transferFrom(address(this), user, p.nftId);

        // Sweep any over-pulled repay buffer back to the user (always the user,
        // never a caller-chosen address).
        uint256 left = IERC20(p.fundingToken).balanceOf(address(this));
        if (left > 0) SafeTransferLib.safeTransfer(p.fundingToken, user, left);
    }
}
