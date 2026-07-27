// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {DustHandler} from "@core/dust/DustHandler.sol";
import {PermitHelper} from "@core/utils/PermitHelper.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

import {
    IGearboxPoolV3,
    IGearboxCreditFacadeV3,
    IGearboxCreditFacadeV3Multicall,
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
//  ⚠️ The credit-account modules are BEST-EFFORT: the bot-permission bitmask, the
//  credit-account address resolution and the multicall fund-flow need validation
//  on a mainnet fork before use. The pool modules are the solid, self-contained
//  core.
// ════════════════════════════════════════════════════════════════════════════

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
// BEST-EFFORT. Pulls `token` via Permit3, then `botMulticall([addCollateral])`
// into the maker's `creditAccount`. Requires the account owner to have
// `setBotPermissions(module, ADD_COLLATERAL)`.
// `data = abi.encode(facade, creditAccount, token[, deadline, v, r, s])` — base = 96.
//
contract GearboxCreditAddCollateralModule is IMakerModule {
    IPermit3 public immutable permit3;
    address public immutable settlement;

    error NotSettlement();

    constructor(address _permit3, address _settlement) {
        permit3 = IPermit3(_permit3);
        settlement = _settlement;
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();

        (address facade, address creditAccount, address token) = abi.decode(data, (address, address, address));
        PermitHelper.replayIfPresent(data, 96, token, onBehalfOf, address(permit3), amount);

        permit3.transferFrom(onBehalfOf, address(this), token, uint160(amount));
        SafeTransferLib.forceApprove(token, facade, amount);

        MultiCall[] memory calls = new MultiCall[](1);
        calls[0] = MultiCall({
            target: facade,
            callData: abi.encodeCall(IGearboxCreditFacadeV3Multicall.addCollateral, (token, amount))
        });
        IGearboxCreditFacadeV3(facade).botMulticall(creditAccount, calls);
    }
}

// ──────────────────── Gearbox credit-account borrow taker module ────────────────────
//
// BEST-EFFORT. `botMulticall([increaseDebt(amount), withdrawCollateral(asset,
// amount, receiver)])` — draw more debt on the maker's credit account and route
// it to `receiver`. Requires the account owner to have
// `setBotPermissions(module, INCREASE_DEBT | WITHDRAW_COLLATERAL)`.
// `data = abi.encode(facade, creditAccount, asset)`.
//
contract GearboxCreditBorrowModule is ITakerModule {
    IPermit3 public immutable permit3;

    error OnlyPermit3();

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();
        onBehalfOf; // the account is identified by `creditAccount` in data (owner-bound off-chain)

        (address facade, address creditAccount, address asset) = abi.decode(data, (address, address, address));

        MultiCall[] memory calls = new MultiCall[](2);
        calls[0] = MultiCall({
            target: facade,
            callData: abi.encodeCall(IGearboxCreditFacadeV3Multicall.increaseDebt, (amount))
        });
        calls[1] = MultiCall({
            target: facade,
            callData: abi.encodeCall(IGearboxCreditFacadeV3Multicall.withdrawCollateral, (asset, amount, receiver))
        });
        IGearboxCreditFacadeV3(facade).botMulticall(creditAccount, calls);
    }
}
