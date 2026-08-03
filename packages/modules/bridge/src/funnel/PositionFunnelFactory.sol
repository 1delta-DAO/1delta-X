// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PositionFunnel} from "./PositionFunnel.sol";

/// @title PositionFunnelFactory
/// @notice Deterministic, permissionless deployer for {PositionFunnel} clones,
///         using clone-with-immutable-args so a funnel costs ONE CREATE2 and
///         nothing else.
///
///  Why immutable args rather than a plain EIP-1167 clone
///  ────────────────────────────────────────────────────
///  A 1167 clone has empty storage, so the owner has to be written by an
///  `initialize` call: an extra CALL plus a cold zero→non-zero SSTORE, about 23k
///  gas, on top of the deploy. Baking the owner into the proxy's runtime code
///  instead costs 29 extra bytes of code deposit (~5.8k) and removes both — a net
///  saving of roughly 17k gas per funnel, and it deletes the initialise step
///  entirely, so there is no window in which an uninitialised clone exists.
///
///  The proxy appends those 20 bytes to the calldata of every delegatecall, and
///  {PositionFunnel.owner} reads them off the end.
///
///  Counterfactual delivery
///  ───────────────────────
///  Tokens may be bridged to a funnel that does not exist yet — an address with no
///  code holds ERC20 balances perfectly well, and the clone is deployed later by
///  whoever fills. That is why this factory must be treated as permanent
///  infrastructure:
///
///    • it is NOT upgradeable and has no owner;
///    • {IMPLEMENTATION} is fixed at construction, so the init code — and
///      therefore every predicted address — can never change;
///    • deploy this factory itself through a deterministic deployer so it lands on
///      the same address on every chain, or the source chain cannot predict the
///      destination funnel.
///
///  If any of those were violated, funds already sitting at counterfactual
///  addresses would become unreachable. Nothing here should ever be "migrated".
contract PositionFunnelFactory {
    /// @notice The clone target. Immutable, so the init code is fixed forever.
    address public immutable IMPLEMENTATION;

    event FunnelDeployed(address indexed funnel, address indexed owner, bytes32 salt);

    error DeployFailed();

    constructor(address permit3, address settlement, address lens, address grantModule) {
        IMPLEMENTATION = address(new PositionFunnel(permit3, settlement, lens, grantModule));
    }

    /// @notice The funnel address for `(owner, userSalt)`, deployed or not.
    /// @dev    The owner is bound TWICE — once through the salt and once through
    ///         the init code, which literally contains the address. Either alone
    ///         would suffice; both is cheap.
    function funnelFor(address owner, bytes32 userSalt) public view returns (address) {
        bytes32 h = keccak256(
            abi.encodePacked(bytes1(0xff), address(this), _salt(owner, userSalt), _initCodeHash(owner))
        );
        return address(uint160(uint256(h)));
    }

    function isDeployed(address owner, bytes32 userSalt) external view returns (bool) {
        return funnelFor(owner, userSalt).code.length != 0;
    }

    /// @notice The CREATE2 salt for `(owner, userSalt)`. Exposed so an off-chain
    ///         implementation can reproduce {funnelFor} and be checked against it
    ///         rather than trusted to have got the derivation right.
    function saltFor(address owner, bytes32 userSalt) external pure returns (bytes32) {
        return _salt(owner, userSalt);
    }

    /// @notice The init code hash for `owner`'s funnel — owner-dependent, because
    ///         the address is baked into the proxy's code.
    ///
    ///         Publish this alongside the factory address per chain. Together with
    ///         {saltFor} it is everything needed to derive a funnel address
    ///         off-chain, and a mismatch against a published value is the signal
    ///         that a chain's deployment is NOT the canonical one — which, given
    ///         funds are bridged to counterfactual addresses, is the difference
    ///         between a delivery and a loss.
    function initCodeHashFor(address owner) external view returns (bytes32) {
        return _initCodeHash(owner);
    }

    /// @notice Deploy the funnel for `(owner, userSalt)` if it does not exist.
    ///         Permissionless and idempotent — a solver calls this in the same
    ///         transaction as the fill, so the user never sends one.
    ///
    ///         Anyone may deploy anyone's funnel; this grants nothing, because the
    ///         owner is fixed by the init code the address is derived from.
    function deploy(address owner, bytes32 userSalt) public returns (address funnel) {
        funnel = funnelFor(owner, userSalt);
        if (funnel.code.length != 0) return funnel;

        bytes32 salt = _salt(owner, userSalt);
        uint256 ptr;
        assembly {
            ptr := mload(0x40)
        }
        _writeInitCode(ptr, IMPLEMENTATION, owner);
        assembly {
            funnel := create2(0, ptr, 0x5b, salt)
        }
        if (funnel == address(0)) revert DeployFailed();
        emit FunnelDeployed(funnel, owner, userSalt);
    }

    /// @notice Deploy-if-needed and wire the tokens an incoming fill will pull.
    ///         The one call a solver makes before settling a bridged order.
    function deployAndEnable(address owner, bytes32 userSalt, address[] calldata tokens)
        external
        returns (address funnel)
    {
        funnel = deploy(owner, userSalt);
        if (tokens.length != 0) PositionFunnel(payable(funnel)).enableTokens(tokens);
    }

    // ──────────────────── Init code ────────────────────
    //
    // 91-byte init code returning an 81-byte runtime: a minimal proxy that copies
    // the caller's calldata, appends the 20-byte owner from its own code, and
    // delegatecalls the implementation — except for a plain value transfer, which
    // it accepts directly. Layout, byte offsets into the INIT CODE:
    //
    //   [0x00, 0x0a)  3d605180600a3d3981f3   constructor: return code[10:91]
    //   [0x0a, 0x22)  runtime prologue (24 bytes, detailed below)
    //   [0x22, 0x36)  implementation address (20 bytes)
    //   [0x36, 0x47)  runtime epilogue (17 bytes)
    //   [0x47, 0x5b)  owner address (20 bytes)  ← the immutable argument
    //
    // Runtime (81 bytes, offsets relative to the RUNTIME):
    //
    //   36 15 603b 57      if calldatasize == 0, jump to 0x3b            ← see below
    //   36 3d 3d 37        CALLDATACOPY(0, 0, calldatasize)      copy the real calldata
    //   6014               PUSH1 20                              args length
    //   603d               PUSH1 0x3d                            args offset within the runtime
    //   36                 CALLDATASIZE                          destination = right after calldata
    //   39                 CODECOPY                              append the owner
    //   3d 3d 3d           three zeroes: spare, retSize, retOffset
    //   6014 36 01         PUSH1 20, CALLDATASIZE, ADD           argsSize = calldatasize + 20
    //   3d                 argsOffset = 0
    //   73 <impl> 5a f4    DELEGATECALL(gas, impl, ...)
    //   3d 82 80 3e        RETURNDATACOPY(0, 0, returndatasize)
    //   90 3d 91 6039 57   jump to 0x39 when the call succeeded
    //   fd                 REVERT(0, returndatasize)
    //   5b f3              0x39: JUMPDEST; RETURN(0, returndatasize)
    //   5b 00              0x3b: JUMPDEST; STOP                          ← the value-transfer path
    //
    // THE EMPTY-CALLDATA SHORT CIRCUIT is the reason this is not stock EIP-1167.
    // Appending an immutable argument means every delegatecall carries at least 20
    // bytes, so a bare value transfer would otherwise arrive at the implementation
    // with a non-empty calldata that its dispatcher tries to read as a selector —
    // `receive()` becomes unreachable, and a first-four-bytes-of-owner collision
    // could invoke a real function. Terminating here instead means a plain transfer
    // never reaches the implementation at all: it costs about 19 gas, so it fits
    // inside a 2300-gas `transfer`/`send` stipend, and no selector is ever read.
    //
    // The delegatecall tail mirrors EIP-1167's exactly. `0x3d` is the offset of the
    // argument inside the runtime, `0x39` the success JUMPDEST and `0x3b` the stop
    // JUMPDEST — all three shift if any byte above changes.

    function _writeInitCode(uint256 ptr, address impl, address owner) private pure {
        assembly {
            mstore(ptr, 0x3d605180600a3d3981f33615603b57363d3d376014603d36393d3d3d60143601)
            mstore(add(ptr, 0x20), 0x3d73000000000000000000000000000000000000000000000000000000000000)
            mstore(add(ptr, 0x22), shl(0x60, impl))
            mstore(add(ptr, 0x36), 0x5af43d82803e903d91603957fd5bf35b00000000000000000000000000000000)
            mstore(add(ptr, 0x47), shl(0x60, owner))
        }
    }

    function _initCodeHash(address owner) internal view returns (bytes32 hash) {
        address impl = IMPLEMENTATION;
        uint256 ptr;
        assembly {
            ptr := mload(0x40)
        }
        _writeInitCode(ptr, impl, owner);
        assembly {
            hash := keccak256(ptr, 0x5b)
        }
    }

    /// @dev Binding `owner` into the salt as well as the init code is belt and
    ///      braces: an address predicted for one user can never be deployed
    ///      holding another user's ownership.
    function _salt(address owner, bytes32 userSalt) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner, userSalt));
    }
}
