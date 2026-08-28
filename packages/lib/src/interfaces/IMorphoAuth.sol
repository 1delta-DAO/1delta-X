// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Minimal Morpho Blue interface for EIP-712 authorization-with-sig.
///         Grants `authorized` (the module) permission to borrow or withdraw
///         collateral on the `authorizer`'s behalf — without a prior
///         `setAuthorization` call. Authorization is coarse (all markets);
///         the Permit3 taker allowance caps the per-fill amount.
interface IMorphoAuth {
    struct Authorization {
        address authorizer;
        address authorized;
        bool isAuthorized;
        uint256 nonce;
        uint256 deadline;
    }

    struct Signature {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    function setAuthorizationWithSig(Authorization calldata authorization, Signature calldata signature) external;
}
