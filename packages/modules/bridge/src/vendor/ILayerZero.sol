// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ILayerZeroComposer
/// @notice Destination-side compose callback (LayerZero V2). The endpoint calls
///         this in a transaction SEPARATE from the one that delivered the tokens.
/// @dev    `lzReceive` credits `to` with the tokens and stores the compose
///         message; an executor then calls `endpoint.lzCompose`, which lands
///         here. Because that is a second transaction, a permanent revert in
///         this function strands the already-delivered tokens at `to` with no
///         attribution — which is why {BridgedOrderInbox.lzCompose} never
///         reverts on business-logic failure.
interface ILayerZeroComposer {
    function lzCompose(
        address _from,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) external payable;
}

/// @title IOFT
/// @notice The OFT (LayerZero omnichain fungible token) send surface, shared by
///         plain OFT deployments (USDT0 and friends) and Stargate V2 pools —
///         `IStargate` is `IOFT`-shaped, so one calling module covers both.
/// @dev    ABI RISK — pin before mainnet. Stargate V2 additionally exposes
///         `sendToken`, which returns a third `Ticket` value used by bus mode.
///         This package uses `send` with an empty `oftCmd` (taxi / immediate) for
///         both, so the shared `IOFT` surface suffices; adding bus mode means
///         switching to `sendToken` and verifying compose delivery in that mode.
interface IOFT {
    struct SendParam {
        uint32 dstEid; //          destination LayerZero endpoint id (NOT a chain id)
        bytes32 to; //             destination receiver, left-padded address
        uint256 amountLD; //       amount in local decimals
        uint256 minAmountLD; //    enforced floor on the delivered amount
        bytes extraOptions; //     executor options; MUST budget lzCompose gas
        bytes composeMsg; //       non-empty ⇒ the receiver's lzCompose is scheduled
        bytes oftCmd; //           empty = taxi (Stargate); ignored by plain OFT
    }

    struct MessagingFee {
        uint256 nativeFee;
        uint256 lzTokenFee;
    }

    struct MessagingReceipt {
        bytes32 guid;
        uint64 nonce;
        MessagingFee fee;
    }

    struct OFTReceipt {
        uint256 amountSentLD;
        uint256 amountReceivedLD;
    }

    /// @notice The ERC20 this OFT/pool moves. For an OFTAdapter (lockbox) this is
    ///         the underlying canonical token; for a native OFT it is the OFT itself.
    function token() external view returns (address);

    /// @notice False for a native OFT that burns from `msg.sender` (no ERC20
    ///         allowance needed); true for an adapter that pulls the underlying.
    function approvalRequired() external view returns (bool);

    function quoteSend(SendParam calldata _sendParam, bool _payInLzToken)
        external
        view
        returns (MessagingFee memory);

    function send(SendParam calldata _sendParam, MessagingFee calldata _fee, address _refundAddress)
        external
        payable
        returns (MessagingReceipt memory, OFTReceipt memory);
}

/// @title OFTComposeMsgCodec
/// @notice Minimal reader for the compose payload LayerZero hands to
///         {ILayerZeroComposer.lzCompose}. Vendored as calldata slicing (the
///         upstream library is memory-based and pulls in the whole OApp tree).
///
///         Layout, big-endian:
///           [0  : 8 )  nonce        uint64
///           [8  : 12)  srcEid       uint32
///           [12 : 44)  amountLD     uint256
///           [44 : 76)  composeFrom  bytes32   (sender on the SOURCE chain)
///           [76 :   )  composeMsg   bytes     (our commitment)
library OFTComposeMsgCodec {
    /// @dev Everything before the caller-supplied compose payload.
    uint256 internal constant HEADER_LENGTH = 76;

    uint256 internal constant AMOUNT_LD_OFFSET = 12;
    uint256 internal constant COMPOSE_FROM_OFFSET = 44;

    function srcEid(bytes calldata _msg) internal pure returns (uint32) {
        return uint32(bytes4(_msg[8:12]));
    }

    function amountLD(bytes calldata _msg) internal pure returns (uint256) {
        return uint256(bytes32(_msg[AMOUNT_LD_OFFSET:COMPOSE_FROM_OFFSET]));
    }

    function composeFrom(bytes calldata _msg) internal pure returns (bytes32) {
        return bytes32(_msg[COMPOSE_FROM_OFFSET:HEADER_LENGTH]);
    }

    function composeMsg(bytes calldata _msg) internal pure returns (bytes calldata) {
        return _msg[HEADER_LENGTH:];
    }

    /// @dev True iff the payload is long enough to read the header. Callers on the
    ///      compose path MUST check this instead of slicing blindly — an
    ///      out-of-range slice reverts, and a revert in `lzCompose` strands funds.
    function isWellFormed(bytes calldata _msg) internal pure returns (bool) {
        return _msg.length >= HEADER_LENGTH;
    }
}
