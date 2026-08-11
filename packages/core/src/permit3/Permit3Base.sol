// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPermit3} from "../interfaces/IPermit3.sol";
import {EIP712} from "./EIP712.sol";

/// @title Permit3Base
/// @notice Common base of every Permit3 layer: the external interface plus the
///         EIP-712 domain. It exists to resolve the `DOMAIN_SEPARATOR` diamond in
///         ONE place — `IPermit3` declares it and `EIP712` implements it, so every
///         contract inheriting both would otherwise have to re-override it.
///
/// @dev    Holds no state, so it contributes no storage slots and inheriting it is
///         free. All Permit3 layers derive from this rather than from `IPermit3`
///         directly.
///
///  PROVENANCE — NEW IN PERMIT3, and only because of the extra layers. Permit2
///  needs no equivalent: it has exactly two leaves and each inherits `EIP712`
///  directly. Permit3 has four, so the diamond is resolved once, here.
abstract contract Permit3Base is IPermit3, EIP712 {
    /// @dev Delegates to the EIP712 base — which caches the separator as an
    ///      immutable and recomputes it if `block.chainid` changes.
    function DOMAIN_SEPARATOR() public view override(IPermit3, EIP712) returns (bytes32) {
        return EIP712.DOMAIN_SEPARATOR();
    }
}
