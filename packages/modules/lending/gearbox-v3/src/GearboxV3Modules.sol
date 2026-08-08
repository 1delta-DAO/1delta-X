// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {DustHandler} from "@core/dust/DustHandler.sol";
import {FullFillGuard} from "@core/utils/FullFillGuard.sol";
import {PermitHelper} from "@core/utils/PermitHelper.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

import {
    IGearboxPoolV3,
    IGearboxCreditFacadeV3,
    IGearboxCreditFacadeV3Multicall,
    ICreditAccountV3,
    ICreditManagerV3,
    IGearboxBot,
    MultiCall
} from "./interfaces/IGearboxV3.sol";

// ════════════════════════════════════════════════════════════════════════════
//  Gearbox V3 modules
//
//  Two surfaces (see IGearboxV3):
//    • PoolV3 (ERC-4626)  — passive supply. Deposit MAKE / Withdraw TAKE, clean.
//    • Credit account      — leverage via `botMulticall`, gated by the account
//      owner's `setBotPermissions(module, permissions)`.
//
//  The credit-account modules mirror the 1delta composer's Gearbox integration
//  (`contracts/1delta/composer/lending/GEARBOX.md`), including its authorization
//  model — see {GearboxCreditAuth}. Three things the composer learned the hard way
//  are reproduced here: the CA-rooted auth chain, the exact-match bot mask, and
//  approving the CREDIT MANAGER rather than the facade (the manager runs
//  `addCollateral`'s `transferFrom`).
//
//  ⚠️ STILL UNVALIDATED ON A FORK: the multicall fund-flow. The authorization
//  model is now covered by unit tests (`test/security/CreditAccountAuth.t.sol`),
//  but no test has executed these modules against real Gearbox contracts, so the
//  end-to-end deposit/borrow flow — HF checks, the once-per-block debt-update
//  rule, quota handling — is still unproven. Fork-test before mainnet use.
// ════════════════════════════════════════════════════════════════════════════

/// @title GearboxCreditAuth
/// @notice The authorization chain for every credit-account op. This is the
///         security core of the Gearbox integration; read it before the modules.
///
///  The problem
///  ───────────
///  Gearbox authorises the BOT, never the beneficiary. `botMulticall` asks only
///  "is `msg.sender` a bot registered on this account?" and has no parameter that
///  could carry the user the module is acting for. A module is a shared singleton
///  registered against EVERY user who onboards, so that check passes for every
///  account in its victim set.
///
///  Meanwhile Permit3's taker book is keyed by the APPROVER
///  (`_takerAllowance[user][spender][ref]`, `ref = keccak256(data)`), so an
///  attacker can self-approve any `ref` — including one computed over a VICTIM's
///  credit account — and sign their own order carrying it. `ref` proves the bytes
///  were authorised by someone; it says nothing about who owns the account named
///  inside them.
///
///  Without the check below the composition is a full drain: the attacker signs an
///  order whose TAKE item names the victim's `creditAccount`, Permit3's gate
///  passes on the attacker's own allowance, and the module runs
///  `increaseDebt + withdrawCollateral` on the victim's account with the proceeds
///  routed to the attacker. The victim keeps the debt.
///
///  The fix — root the whole chain at `creditAccount`
///  ─────────────────────────────────────────────────
///  `creditAccount` is the ONLY address a caller supplies; the manager and facade
///  are derived from it on-chain, and the borrower is read from that derived
///  manager. An attacker controlling the one input cannot split the chain:
///    • a REAL account resolves to the real manager, whose `getBorrowerOrRevert`
///      returns the real owner — a non-owner fails the equality check;
///    • a FABRICATED account either is not in the real manager's registry
///      (`getBorrowerOrRevert` reverts) or resolves into a wholly attacker-owned
///      chain, which has no reach into real Gearbox — dispatch goes to the
///      attacker's own facade and bot permissions are keyed on the real manager.
///
///  Taking the facade (or manager) from calldata instead re-opens exactly this
///  split, letting authorization read one contract while dispatch hits another.
///  The composer shipped and then removed both variants (GEARBOX.md rows A2/A3);
///  do not reintroduce them.
library GearboxCreditAuth {
    /// @dev The Permit3 principal is not the owner of `creditAccount`.
    error InvalidCaller();

    // Gearbox V3 bot permission bits (BotListV3).
    uint192 internal constant ADD_COLLATERAL_PERMISSION = 1 << 0;
    uint192 internal constant INCREASE_DEBT_PERMISSION = 1 << 1;
    uint192 internal constant DECREASE_DEBT_PERMISSION = 1 << 2;
    uint192 internal constant WITHDRAW_COLLATERAL_PERMISSION = 1 << 5;
    uint192 internal constant UPDATE_QUOTA_PERMISSION = 1 << 6;

    /// @notice Derive `(creditManager, creditFacade)` from `creditAccount` and
    ///         require `principal` to be the account's borrower.
    /// @param  creditAccount the only caller-supplied address on the auth path
    /// @param  principal     the user whose Permit3 allowance funds this op
    ///                       (`onBehalfOf` — always `order.maker` from Settlement)
    function authorize(address creditAccount, address principal)
        internal
        view
        returns (address creditManager, address creditFacade)
    {
        creditManager = ICreditAccountV3(creditAccount).creditManager();
        creditFacade = ICreditManagerV3(creditManager).creditFacade();
        if (ICreditManagerV3(creditManager).getBorrowerOrRevert(creditAccount) != principal) revert InvalidCaller();
    }
}

// ──────────────────── Gearbox pool deposit maker module ────────────────────
//
// Pulls `asset` via Permit3 and supplies it into the ERC-4626 `pool` crediting
// the user. `data = abi.encode(pool, asset[, deadline, v, r, s])` — base = 64.
//
contract GearboxPoolDepositModule is IMakerModule {
    IPermit3 public immutable permit3;
    address public immutable settlement;

    error NotSettlement();

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();

        (address pool, address asset) = abi.decode(data, (address, address));
        PermitHelper.replayIfPresent(data, 64, asset, onBehalfOf, address(permit3), amount);

        permit3.transferFrom(onBehalfOf, address(this), asset, uint160(amount));
        SafeTransferLib.forceApprove(asset, pool, amount);
        IGearboxPoolV3(pool).deposit(amount, onBehalfOf);
    }
}

// ──────────────────── Gearbox pool withdraw taker module ────────────────────
//
// ERC-4626 owner-allowance withdrawal: the maker grants `pool.approve(module,
// max)`; the module burns the maker's shares and sends the underlying to
// `receiver`. `data = abi.encode(pool, asset[, BalanceMode])` — base = 64.
//
contract GearboxPoolWithdrawModule is ITakerModule {
    IPermit3 public immutable permit3;

    error OnlyPermit3();

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        (address pool, address asset) = abi.decode(data, (address, address));

        if (DustHandler.readBalanceMode(data, 64) == DustHandler.BalanceMode.Full) {
            // `Full` liquidates the user's ENTIRE live balance, so it cannot be
            // pro-rated — a sliced fill would unwind the whole position and brick
            // the rest of the order. Require the slice to be the whole item.
            FullFillGuard.requireFullFillFromData(data, 96, amount);
            uint256 max = IGearboxPoolV3(pool).maxWithdraw(onBehalfOf);
            uint256 before = IERC20(asset).balanceOf(address(this));
            IGearboxPoolV3(pool).withdraw(max, address(this), onBehalfOf);
            uint256 received = IERC20(asset).balanceOf(address(this)) - before;
            require(received >= amount, "insufficient withdrawn");
            SafeTransferLib.safeTransfer(asset, receiver, amount);
            if (received > amount) SafeTransferLib.safeTransfer(asset, onBehalfOf, received - amount);
        } else {
            IGearboxPoolV3(pool).withdraw(amount, receiver, onBehalfOf);
        }
    }
}

// ──────────────────── Gearbox credit-account add-collateral maker module ────────────────────
//
// Pulls `token` via Permit3, then `botMulticall([addCollateral])` into the maker's
// `creditAccount`. The maker must first grant this module the bot role with a mask
// EXACTLY equal to `requiredPermissions()`:
//   facade.multicall(ca, [setBotPermissions(module, 0x01)])
// `data = abi.encode(creditAccount, token[, deadline, v, r, s])` — base = 64.
//
// The facade is NOT in `data`: it is derived from `creditAccount` on-chain (see
// {GearboxCreditAuth}). Approval goes to the CREDIT MANAGER, not the facade —
// `addCollateral` is executed by the manager, which runs the `transferFrom` with
// this module as payer.
//
contract GearboxCreditAddCollateralModule is IMakerModule, IGearboxBot {
    IPermit3 public immutable permit3;
    address public immutable settlement;

    error NotSettlement();

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    /// @inheritdoc IGearboxBot
    /// @dev Deposit-only: this module can never draw debt or move collateral out.
    ///      Gearbox enforces an exact match, so a maker granting this bot cannot
    ///      accidentally hand it borrow rights — the narrow mask IS the guarantee.
    function requiredPermissions() external pure override returns (uint192) {
        return GearboxCreditAuth.ADD_COLLATERAL_PERMISSION;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();

        (address creditAccount, address token) = abi.decode(data, (address, address));
        (address creditManager, address facade) = GearboxCreditAuth.authorize(creditAccount, onBehalfOf);

        PermitHelper.replayIfPresent(data, 64, token, onBehalfOf, address(permit3), amount);
        permit3.transferFrom(onBehalfOf, address(this), token, uint160(amount));
        SafeTransferLib.forceApprove(token, creditManager, amount);

        MultiCall[] memory calls = new MultiCall[](1);
        calls[0] = MultiCall({
            target: facade, callData: abi.encodeCall(IGearboxCreditFacadeV3Multicall.addCollateral, (token, amount))
        });
        IGearboxCreditFacadeV3(facade).botMulticall(creditAccount, calls);

        // End holding nothing and granting nothing: clear the allowance and return
        // any amount the manager did not pull, so no residual is left for a later
        // order to name.
        SafeTransferLib.forceApprove(token, creditManager, 0);
        uint256 left = IERC20(token).balanceOf(address(this));
        if (left != 0) SafeTransferLib.safeTransfer(token, onBehalfOf, left);
    }
}

// ──────────────────── Gearbox credit-account repay maker module ────────────────────
//
// The previously-missing REPAY leg: pulls the debt `asset` via Permit3, then
// `botMulticall([addCollateral(asset, amount), decreaseDebt(amount)])` — fund the
// maker's `creditAccount` and burn that much debt in one atomic multicall. The
// maker must first grant this module the bot role with a mask EXACTLY equal to
// `requiredPermissions()`:
//   facade.multicall(ca, [setBotPermissions(module, 0x05)])
// `data = abi.encode(creditAccount, asset[, deadline, v, r, s])` — base = 64.
//
// Semantics are EXACT-amount: `amount` is the maker-signed repay size, pro-rated
// by partial fills like every MAKE item. A slice exceeding the live debt reverts
// inside Gearbox (`decreaseDebt` does not cap) — the conservative direction; for
// a full close, sign the order full-fill and size `amount` off the accrued debt
// with headroom on the collateral side instead. Approval goes to the CREDIT
// MANAGER (it runs `addCollateral`'s transferFrom), is reset after, and any
// unpulled residual returns to the maker — same end-holding-nothing posture as
// the add-collateral module. Same best-effort caveat as the other credit-account
// modules: authorization is unit-tested, the multicall fund-flow awaits fork
// validation.
//
contract GearboxCreditRepayModule is IMakerModule, IGearboxBot {
    IPermit3 public immutable permit3;
    address public immutable settlement;

    error NotSettlement();

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    /// @inheritdoc IGearboxBot
    /// @dev Repay-only: fund the account + burn debt. No borrow bit, no
    ///      collateral-out bit — a maker granting this bot hands it strictly
    ///      value-IN authority (Gearbox enforces the exact mask match).
    function requiredPermissions() external pure override returns (uint192) {
        return GearboxCreditAuth.ADD_COLLATERAL_PERMISSION | GearboxCreditAuth.DECREASE_DEBT_PERMISSION;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();

        (address creditAccount, address asset) = abi.decode(data, (address, address));
        (address creditManager, address facade) = GearboxCreditAuth.authorize(creditAccount, onBehalfOf);

        PermitHelper.replayIfPresent(data, 64, asset, onBehalfOf, address(permit3), amount);
        permit3.transferFrom(onBehalfOf, address(this), asset, uint160(amount));
        SafeTransferLib.forceApprove(asset, creditManager, amount);

        MultiCall[] memory calls = new MultiCall[](2);
        calls[0] = MultiCall({
            target: facade, callData: abi.encodeCall(IGearboxCreditFacadeV3Multicall.addCollateral, (asset, amount))
        });
        calls[1] = MultiCall({
            target: facade, callData: abi.encodeCall(IGearboxCreditFacadeV3Multicall.decreaseDebt, (amount))
        });
        IGearboxCreditFacadeV3(facade).botMulticall(creditAccount, calls);

        // End holding nothing and granting nothing.
        SafeTransferLib.forceApprove(asset, creditManager, 0);
        uint256 left = IERC20(asset).balanceOf(address(this));
        if (left != 0) SafeTransferLib.safeTransfer(asset, onBehalfOf, left);
    }
}

// ──────────────────── Gearbox credit-account borrow taker module ────────────────────
//
// `botMulticall([increaseDebt(amount), withdrawCollateral(asset, amount,
// receiver)])` — draw more debt on the maker's credit account and route it to
// `receiver`. The maker must first grant this module the bot role with a mask
// EXACTLY equal to `requiredPermissions()`:
//   facade.multicall(ca, [setBotPermissions(module, 0x22)])
// `data = abi.encode(creditAccount, asset)` — base = 64.
//
// This is the value-OUT leg, so the {GearboxCreditAuth} borrower check is what
// stands between a maker's account and any filler who knows its address. The
// facade is derived, never taken from `data`.
//
contract GearboxCreditBorrowModule is ITakerModule, IGearboxBot {
    IPermit3 public immutable permit3;

    error OnlyPermit3();

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    /// @inheritdoc IGearboxBot
    /// @dev Borrow-only: `INCREASE_DEBT | WITHDRAW_COLLATERAL`. Deliberately
    ///      narrower than the composer's monolithic `0x67` — because Gearbox
    ///      matches the mask exactly and this module is a separate contract from
    ///      the deposit one, a maker grants borrow rights to THIS address only.
    function requiredPermissions() external pure override returns (uint192) {
        return GearboxCreditAuth.INCREASE_DEBT_PERMISSION | GearboxCreditAuth.WITHDRAW_COLLATERAL_PERMISSION;
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        (address creditAccount, address asset) = abi.decode(data, (address, address));
        // Binds the account to the Permit3 principal. Gearbox authorises this
        // module as a bot on EVERY onboarded account, so without this an attacker
        // could name a victim's account here and route the proceeds to themselves.
        (, address facade) = GearboxCreditAuth.authorize(creditAccount, onBehalfOf);

        MultiCall[] memory calls = new MultiCall[](2);
        calls[0] = MultiCall({
            target: facade, callData: abi.encodeCall(IGearboxCreditFacadeV3Multicall.increaseDebt, (amount))
        });
        calls[1] = MultiCall({
            target: facade,
            callData: abi.encodeCall(IGearboxCreditFacadeV3Multicall.withdrawCollateral, (asset, amount, receiver))
        });
        IGearboxCreditFacadeV3(facade).botMulticall(creditAccount, calls);
    }
}
