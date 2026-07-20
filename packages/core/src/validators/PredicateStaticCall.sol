// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOrderValidator} from "../interfaces/IOrderValidator.sol";
import {Order} from "../settlement/Settlement.sol";

/// @title PredicateStaticCall
/// @notice Escape-hatch validator for arbitrary read-only predicates.
///         Staticcalls `(target, data)` and passes iff the returned
///         first 32 bytes decode to a non-zero uint256.
/// @dev    `data = abi.encode(address target, bytes calldata)`
contract PredicateStaticCall is IOrderValidator {
    function validate(Order calldata, address, bytes calldata data, bytes calldata) external view override returns (bool) {
        (address target, bytes memory call) = abi.decode(data, (address, bytes));
        (bool ok, bytes memory ret) = target.staticcall(call);
        return ok && ret.length >= 32 && abi.decode(ret, (uint256)) != 0;
    }
}
