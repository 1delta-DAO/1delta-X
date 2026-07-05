// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IMakerModule} from "../interfaces/IMakerModule.sol";
import {IPermit3} from "../interfaces/IPermit3.sol";
import {SafeTransferLib} from "../utils/SafeTransferLib.sol";

/// @title GenericCallModule
/// @notice Escape-hatch MAKE module: executes ONE arbitrary, maker-signed
///         contract call as a fill item, optionally funded by a Permit3 pull of
///         a single token from the maker. The state-mutating analogue of
///         {PredicateStaticCall} (which does the read-only version for
///         validators).
///
///  This is the "inject a solver callback via a module" path: a solver that
///  wants custom logic composed into a fill ships (or reuses) this module and
///  the maker signs an `Item{op: MAKE, module: GenericCallModule, data: CallSpec}`.
///  On fill, Settlement dispatches here and the maker-authored call runs inline —
///  arbitrary composability with NO change to the settlement core.
///
///  Trust model
///  ───────────
///  Two independent gates, mirroring the rest of the protocol:
///
///    1. `msg.sender == SETTLEMENT`. Load-bearing. Settlement only dispatches
///       items whose `(module, amount, data)` are inside the maker's signed
///       order hash, so binding the caller to Settlement makes the maker's
///       signature the authority over `spec.target`/`spec.callData`. Without
///       this gate a direct `makeOnBehalf(victim, amount, attackerData)` could
///       run an attacker-chosen call funded by the victim's module allowance.
///
///    2. The Permit3 token allowance the maker granted THIS module
///       (`approveToken(genericCallModule, token, cap, expiry)`) caps what the
///       call can spend. This module holds no Settlement allowances and is not
///       an approved Permit3 spender for anyone, so the arbitrary call cannot
///       reach any book beyond the maker's own per-module cap.
///
///  Any funding token pulled and not consumed by the call is swept back to the
///  maker, so the module always ends a fill empty.
contract GenericCallModule is IMakerModule {
    IPermit3 public immutable PERMIT3;
    address public immutable SETTLEMENT;

    error OnlySettlement();
    error CallFailed(bytes ret);

    /// @param token    funding token to pull from the maker via Permit3 before
    ///                 the call (`address(0)` ⇒ pull nothing; a pure side-effect
    ///                 call). The module approves `target` for exactly `amount`.
    /// @param target   contract to invoke.
    /// @param callData exact calldata for `target`. Part of the maker-signed
    ///                 `Item.data`, so authorised by construction.
    struct CallSpec {
        address token;
        address target;
        bytes callData;
    }

    constructor(address permit3, address settlement) {
        PERMIT3 = IPermit3(permit3);
        SETTLEMENT = settlement;
    }

    /// @inheritdoc IMakerModule
    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != SETTLEMENT) revert OnlySettlement();

        CallSpec memory spec = abi.decode(data, (CallSpec));

        bool funded = spec.token != address(0) && amount != 0;
        if (funded) {
            // Gated by the maker's Permit3 token allowance to THIS module.
            PERMIT3.transferFrom(onBehalfOf, address(this), spec.token, uint160(amount));
            SafeTransferLib.forceApprove(spec.token, spec.target, amount);
        }

        (bool ok, bytes memory ret) = spec.target.call(spec.callData);
        if (!ok) revert CallFailed(ret);

        if (funded) {
            SafeTransferLib.forceApprove(spec.token, spec.target, 0); // no dangling allowance
            // Sweep anything the call didn't consume back to the maker — never a
            // caller-chosen address — so the module ends empty.
            uint256 left = IERC20(spec.token).balanceOf(address(this));
            if (left != 0) SafeTransferLib.safeTransfer(spec.token, onBehalfOf, left);
        }
    }
}
