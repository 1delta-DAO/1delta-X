// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Order, LendingItem, LendingOp, ConversionItem} from "../types/DataTypes.sol";

/// @title MakerChecks
/// @notice View helpers that verify a maker has the required token approvals
///         and balances before an order can be settled.
///         Intended for off-chain use by UIs and solver bots.
library MakerChecks {
    struct CheckResult {
        bool ready;
        string reason;
    }

    /// @notice Check whether a maker can fulfil the token requirements of an order.
    ///         Does NOT check lending-protocol-level delegation (credit delegation, etc.)
    ///         because that is protocol-specific and handled by modules.
    function checkOrder(Order calldata order, address settlement) internal view returns (CheckResult memory) {
        // Check balances and approvals for deposit/repay items (maker must fund these)
        for (uint256 i; i < order.items.length; i++) {
            LendingItem calldata item = order.items[i];

            if (item.operation == LendingOp.DEPOSIT || item.operation == LendingOp.REPAY) {
                uint256 bal = IERC20(item.asset).balanceOf(order.maker);
                if (bal < item.amount) {
                    return CheckResult(false, "insufficient balance for deposit/repay");
                }

                uint256 allowance = IERC20(item.asset).allowance(order.maker, settlement);
                if (allowance < item.amount) {
                    return CheckResult(false, "insufficient allowance for deposit/repay");
                }
            }
        }

        return CheckResult(true, "");
    }
}
