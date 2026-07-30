// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOrderValidator} from "../interfaces/IOrderValidator.sol";
import {Order} from "../settlement/Structs.sol";

/// @title TimestampValidator
/// @notice Time-window gate: passes iff `notBefore <= block.timestamp <= notAfter`
///         (either bound 0 ⇒ unbounded on that side). The "not fillable before T"
///         primitive the core deliberately lacks — `Order.deadline` only bounds
///         the END, and `decayStartTime` gates pricing, not fillability. Typical
///         uses: an order that opens at a known listing/unlock time, a
///         maintenance window, or staging a queue of orders that activate in
///         sequence.
/// @dev    `data = abi.encode(uint256 notBefore, uint256 notAfter)`. Stateless,
///         ownerless, `takerData` ignored. For pure end-bounds prefer the signed
///         `Order.deadline` (checked on the hot path for free) — use `notAfter`
///         here only when composing a window tighter than the deadline.
contract TimestampValidator is IOrderValidator {
    function validate(Order calldata, address, bytes calldata data, bytes calldata)
        external
        view
        override
        returns (bool)
    {
        (uint256 notBefore, uint256 notAfter) = abi.decode(data, (uint256, uint256));
        if (block.timestamp < notBefore) return false;
        if (notAfter != 0 && block.timestamp > notAfter) return false;
        return true;
    }
}
