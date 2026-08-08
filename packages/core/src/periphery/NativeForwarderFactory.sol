// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "../utils/SafeTransferLib.sol";

interface IWETHUnwrap {
    function withdraw(uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
}

/// @title WethUnwrapForwarder
/// @notice The maker-side NATIVE-OUT primitive the core deliberately lacks: a
///         per-maker forwarder a signed output leg can name as `recipient`, so a
///         WETH delivery becomes raw ETH in the maker's wallet. Deployed (once
///         per maker) at a CREATE2 address that is computable BEFORE deployment —
///         legs may pay the predicted address first; deployment and sweeping are
///         both permissionless because the money can only ever move to `MAKER`.
///
///  Flow: sign `legsOut[j].recipient = factory.forwarderFor(maker)` → the fill
///  delivers WETH there → anyone (typically the filler, right after the fill, or
///  the maker's own keeper) calls `sweep()`: the forwarder unwraps its entire
///  WETH balance and pushes all ETH to the maker.
///
/// @dev    Trust argument: `MAKER` and `WETH` are immutable; there is no other
///         code path, no owner, no arbitrary call — a hostile `sweep()` caller
///         can only accelerate the maker's payout. A contract maker must accept
///         plain ETH (`receive`), else `sweep` reverts and the funds simply wait
///         (retriable; nothing is stranded irrecoverably — WETH could also be
///         re-wrapped by nobody, so pick this recipient only for ETH-capable
///         accounts; the SDK's shape checks flag it). Non-WETH tokens sent here
///         by mistake are NOT recoverable — name this address only on WETH legs.
contract WethUnwrapForwarder {
    IWETHUnwrap public immutable WETH;
    address payable public immutable MAKER;

    error EthSendFailed();

    constructor(address weth, address payable maker) {
        WETH = IWETHUnwrap(weth);
        MAKER = maker;
    }

    /// @dev Accept the WETH unwrap (and any direct ETH, equally sweepable).
    receive() external payable {}

    /// @notice Unwrap every WETH held and push ALL ETH to the maker. Permissionless.
    function sweep() external {
        uint256 wethBal = WETH.balanceOf(address(this));
        if (wethBal != 0) WETH.withdraw(wethBal);
        uint256 bal = address(this).balance;
        if (bal != 0) {
            (bool ok,) = MAKER.call{value: bal}("");
            if (!ok) revert EthSendFailed();
        }
    }
}

/// @title NativeForwarderFactory
/// @notice CREATE2 factory + address book for {WethUnwrapForwarder}. The
///         forwarder address depends only on (factory, WETH, maker), so wallets
///         and the SDK can compute it off-chain and sign orders against it
///         before it exists; `deploy` is permissionless and idempotent-safe
///         (second deploy for the same maker reverts on the CREATE2 collision —
///         call `forwarderFor` first).
contract NativeForwarderFactory {
    address public immutable WETH;

    event ForwarderDeployed(address indexed maker, address forwarder);

    constructor(address weth) {
        WETH = weth;
    }

    /// @notice The (deployed or future) forwarder address for `maker`.
    function forwarderFor(address maker) public view returns (address) {
        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(WethUnwrapForwarder).creationCode, abi.encode(WETH, maker)));
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(this), bytes32(uint256(uint160(maker))), initCodeHash)
                    )
                )
            )
        );
    }

    /// @notice Deploy `maker`'s forwarder (anyone may; it can only pay the maker).
    function deploy(address payable maker) external returns (address forwarder) {
        forwarder = address(new WethUnwrapForwarder{salt: bytes32(uint256(uint160(address(maker))))}(WETH, maker));
        emit ForwarderDeployed(maker, forwarder);
    }
}
