// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";

import {IAcrossMessageHandler} from "../../src/vendor/IAcross.sol";
import {ILayerZeroComposer, IOFT} from "../../src/vendor/ILayerZero.sol";

/// @dev Across SpokePool stand-in. `depositV3` takes custody exactly as the real
///      one does; `relay` plays the destination-side relayer — deliver the tokens
///      and invoke the message handler IN THE SAME CALL, which is the atomicity
///      the real protocol provides and the reason a reverting handler is safe.
contract MockSpokePool {
    struct Deposit {
        address depositor;
        address recipient;
        address inputToken;
        address outputToken;
        uint256 inputAmount;
        uint256 outputAmount;
        uint256 dstChainId;
        address exclusiveRelayer;
        uint32 quoteTimestamp;
        uint32 fillDeadline;
        uint32 exclusivityDeadline;
        bytes message;
    }

    Deposit[] internal _deposits;

    function depositCount() external view returns (uint256) {
        return _deposits.length;
    }

    function depositAt(uint256 i) external view returns (Deposit memory) {
        return _deposits[i];
    }

    function depositV3(
        address depositor,
        address recipient,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        address exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes calldata message
    ) external payable {
        MockERC20(inputToken).transferFrom(msg.sender, address(this), inputAmount);
        _deposits.push(
            Deposit(
                depositor,
                recipient,
                inputToken,
                outputToken,
                inputAmount,
                outputAmount,
                destinationChainId,
                exclusiveRelayer,
                quoteTimestamp,
                fillDeadline,
                exclusivityDeadline,
                message
            )
        );
    }

    /// @dev The destination-side fill. A relayer fronts `outputAmount` and calls
    ///      the handler in the same transaction.
    function relay(uint256 i) external {
        Deposit memory d = _deposits[i];
        MockERC20(d.outputToken).mint(d.recipient, d.outputAmount);
        // Matches the real relayer: the handler is only invoked when a message was
        // attached. A funnel-addressed deposit carries none, so the delivery is a
        // plain transfer and the recipient needs no hook at all.
        if (d.message.length != 0) {
            IAcrossMessageHandler(d.recipient)
                .handleV3AcrossMessage(d.outputToken, d.outputAmount, address(this), d.message);
        }
    }

    /// @dev Relay with a hand-crafted message — for replay / wrong-chain coverage.
    function relayWith(uint256 i, bytes calldata message) external {
        Deposit memory d = _deposits[i];
        MockERC20(d.outputToken).mint(d.recipient, d.outputAmount);
        IAcrossMessageHandler(d.recipient).handleV3AcrossMessage(d.outputToken, d.outputAmount, address(this), message);
    }
}

/// @dev LayerZero V2 endpoint stand-in, reduced to the one thing the inbox cares
///      about: it is the only address allowed to drive `lzCompose`.
contract MockLzEndpoint {
    function deliverCompose(address to, address from, bytes32 guid, bytes calldata message) external {
        ILayerZeroComposer(to).lzCompose(from, guid, message, address(0), "");
    }

    /// @dev Build the payload LayerZero wraps a compose message in.
    ///      nonce(8) | srcEid(4) | amountLD(32) | composeFrom(32) | composeMsg
    function encodeCompose(uint64 nonce, uint32 srcEid, uint256 amountLD, bytes32 composeFrom, bytes memory inner)
        external
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(nonce, srcEid, amountLD, composeFrom, inner);
    }
}

/// @dev OFT / Stargate-pool stand-in in ADAPTER shape (`token() != address(this)`),
///      so the calling module's approve path is exercised. Delivery is split into
///      two steps to mirror LayerZero: `deliverTokens` is the `lzReceive` leg and
///      the endpoint's `deliverCompose` is the separate compose transaction.
contract MockOFT {
    address public token;
    uint256 public fee;
    MockLzEndpoint public endpoint;

    struct Sent {
        uint32 dstEid;
        bytes32 to;
        uint256 amountLD;
        uint256 minAmountLD;
        bytes extraOptions;
        bytes composeMsg;
        uint256 nativeFee;
        address refundAddress;
    }

    Sent[] internal _sent;

    error SlippageExceeded();

    constructor(address _token, uint256 _fee, MockLzEndpoint _endpoint) {
        token = _token;
        fee = _fee;
        endpoint = _endpoint;
    }

    function setFee(uint256 f) external {
        fee = f;
    }

    function sentCount() external view returns (uint256) {
        return _sent.length;
    }

    function sentAt(uint256 i) external view returns (Sent memory) {
        return _sent[i];
    }

    function approvalRequired() external pure returns (bool) {
        return true;
    }

    function quoteSend(IOFT.SendParam calldata, bool) external view returns (IOFT.MessagingFee memory) {
        return IOFT.MessagingFee({nativeFee: fee, lzTokenFee: 0});
    }

    function send(IOFT.SendParam calldata p, IOFT.MessagingFee calldata f, address refundAddress)
        external
        payable
        returns (IOFT.MessagingReceipt memory r, IOFT.OFTReceipt memory o)
    {
        // The pool enforces the delivery floor, which is what makes `minAmountLD`
        // usable as the destination order's guaranteed input.
        if (p.amountLD < p.minAmountLD) revert SlippageExceeded();
        MockERC20(token).transferFrom(msg.sender, address(this), p.amountLD);
        _sent.push(
            Sent(p.dstEid, p.to, p.amountLD, p.minAmountLD, p.extraOptions, p.composeMsg, f.nativeFee, refundAddress)
        );
        r.guid = keccak256(abi.encode(address(this), _sent.length));
        o.amountSentLD = p.amountLD;
        o.amountReceivedLD = p.amountLD;
    }

    /// @dev The `lzReceive` leg: tokens land at the receiver, no message yet.
    function deliverTokens(uint256 i, uint256 amountReceived) external {
        Sent memory s = _sent[i];
        MockERC20(token).mint(address(uint160(uint256(s.to))), amountReceived);
    }

    /// @dev The separate compose transaction.
    function deliverCompose(uint256 i, uint256 amountReceived) external {
        Sent memory s = _sent[i];
        bytes memory payload = endpoint.encodeCompose(
            uint64(i + 1), 1, amountReceived, bytes32(uint256(uint160(address(this)))), s.composeMsg
        );
        endpoint.deliverCompose(address(uint160(uint256(s.to))), address(this), bytes32(uint256(i + 1)), payload);
    }
}

/// @dev Circle CCTP v1 TokenMessenger. Records the burn and actually takes the
///      tokens, so a test can assert both what was requested and that the module
///      ends up holding nothing.
contract MockTokenMessenger {
    struct Burn {
        uint256 amount;
        uint32 destinationDomain;
        bytes32 mintRecipient;
        address burnToken;
    }

    Burn[] internal _burns;
    uint64 internal _nonce;

    function burnCount() external view returns (uint256) {
        return _burns.length;
    }

    function burnAt(uint256 i) external view returns (Burn memory) {
        return _burns[i];
    }

    function depositForBurn(uint256 amount, uint32 destinationDomain, bytes32 mintRecipient, address burnToken)
        external
        returns (uint64)
    {
        _burns.push(Burn(amount, destinationDomain, mintRecipient, burnToken));
        // CCTP pulls the burn amount from the caller's balance.
        IERC20Like(burnToken).transferFrom(msg.sender, address(this), amount);
        unchecked {
            return ++_nonce;
        }
    }
}

interface IERC20Like {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}
