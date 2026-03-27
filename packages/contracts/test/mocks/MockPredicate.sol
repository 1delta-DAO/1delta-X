// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Mock predicate contract for testing arbitrary staticcall conditions.
contract MockPredicate {
    bool public result;

    constructor(bool _result) {
        result = _result;
    }

    function setResult(bool _result) external {
        result = _result;
    }

    /// @notice Returns 1 if result is true, 0 otherwise.
    function check() external view returns (uint256) {
        return result ? 1 : 0;
    }

    /// @notice Returns 1 if the health factor is below the threshold.
    ///         Simulates a health-factor check predicate.
    function healthFactorBelow(uint256 currentHF, uint256 threshold) external pure returns (uint256) {
        return currentHF < threshold ? 1 : 0;
    }
}
