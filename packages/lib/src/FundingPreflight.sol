// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

/// @title FundingPreflight
/// @notice The `available` half of {ITakerForModule.fundingSource}, for the modules
///         whose funding leg is an ERC-20 pulled with `permit3.transferFrom` — which
///         is every composite module in this repo today.
///
/// @dev    Shared rather than copied because a preflight that disagrees with the
///         pull it predicts is worse than no preflight: it either previews a
///         fillable order as broken (and an orderbook drops it) or previews a
///         broken one as fillable (and the maker learns from a revert, which is the
///         gap the function exists to close). One implementation, one answer.
///
///         Two things the naive `tokenAllowance` read gets wrong, both mirrored
///         from {SettlementLens._makerFillableCap}:
///
///           • an EXPIRED allowance is not a small allowance, it is none. Permit3
///             stores the amount and the expiry separately and checks the expiry at
///             spend time, so a lapsed grant still reads back its old amount.
///           • an allowance the maker cannot BACK is not spendable. The pull moves
///             real tokens, so the binding constraint is the min of the two, and
///             reporting the allowance alone would preview an empty wallet as
///             fully funded.
///
///         Deliberately NO direct-ERC20 fallback term. {SettlementLens} takes the
///         max of the Permit3 book and a plain approval to the settler, because
///         {Permit3TransferLib.transferFromWithFallback} genuinely funds the same
///         pull either way. The composite modules call `permit3.transferFrom`
///         DIRECTLY, with no fallback, so an ERC-20 approval to the module funds
///         nothing and counting it would preview a broken order as fillable.
library FundingPreflight {
    /// @param module the module that will be the SPENDER of the pull — pass
    ///        `address(this)`, not the settler: the grant is `(user, module, token)`.
    function pullable(IPermit3 permit3, address module, address user, address token)
        internal
        view
        returns (uint256)
    {
        (uint160 allowed, uint48 expiration) = permit3.tokenAllowance(user, module, token);
        if (expiration != 0 && expiration < block.timestamp) return 0;
        uint256 bal = SafeTransferLib.balanceOf(token, user);
        return bal < allowed ? bal : allowed;
    }
}
