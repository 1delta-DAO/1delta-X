// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ISignatureTransfer
/// @notice One-shot signed transfers — the second half of the Permit2 model,
///         ported to Permit3. A signature authorises a SINGLE transfer of a
///         bounded amount to a spender-chosen recipient and leaves NO standing
///         allowance behind. Nothing is written to either allowance book.
///
///         Complements {IPermit3}'s `permitBatch`, which does the opposite: it
///         grants a standing allowance the spender draws down later. Pick by
///         lifetime — one payment now, or a budget over time.
///
/// @dev    The signed `spender` is always `msg.sender` at the point of
///         consumption; it is never a caller-supplied argument. A signature that
///         leaks is therefore useless to anyone but the intended spender.
///
///         Nonces share Permit3's single per-owner unordered bitmap with the
///         allowance permits, so `invalidateUnorderedNonces` cancels both kinds
///         and one nonce value can never be spent twice, whichever flow spends
///         it. Off-chain nonce allocation must therefore be per-owner, not
///         per-flow.
///
///  PROVENANCE — Permit2 `src/interfaces/ISignatureTransfer.sol` (Uniswap, MIT).
///  The four structs and the four function signatures are Permit2's, unchanged.
///  Deviations: `SignatureExpired` is declared here rather than in a shared
///  `PermitErrors.sol`, `DOMAIN_SEPARATOR` is not redeclared (it lives on
///  `IPermit3`), and the permit arguments are `calldata`. See
///  {SignatureTransfer} for the behavioural notes.
interface ISignatureTransfer {
    /// @notice The token and the maximum amount the signature authorises.
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    /// @notice A signed single-transfer authorisation.
    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

    /// @notice A signed multi-transfer authorisation — one `TokenPermissions`
    ///         per leg, all covered by one signature and one nonce.
    struct PermitBatchTransferFrom {
        TokenPermissions[] permitted;
        uint256 nonce;
        uint256 deadline;
    }

    /// @notice The spender-chosen half of a transfer: where the tokens go and how
    ///         much of the signed allowance to actually use. NOT signed over — the
    ///         signature caps `requestedAmount` but does not fix it, so a spender
    ///         may draw less than authorised (and only less).
    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    /// @notice Thrown when the permit deadline has passed.
    error SignatureExpired(uint256 deadline);
    /// @notice Thrown when `requestedAmount` exceeds the signed `permitted.amount`.
    error InvalidAmount(uint256 maxAmount);
    /// @notice Thrown when a batch's `permitted` and `transferDetails` lengths differ.
    error LengthMismatch();

    /// @notice Consume a signed single-transfer authorisation.
    /// @param permit          the signed authorisation
    /// @param transferDetails recipient + amount to draw (≤ `permit.permitted.amount`)
    /// @param owner           the signer, and the payer
    /// @param signature       EIP-712 signature over `permit` bound to `msg.sender`
    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;

    /// @notice Same, with an arbitrary caller-defined `witness` (e.g. an order
    ///         hash) folded into the signed digest.
    /// @dev    `witnessTypeString` follows the Permit2 convention: the caller
    ///         supplies the EIP-712 type definitions for the witness *and* for
    ///         `TokenPermissions`, in alphabetical order, starting from
    ///         `"<fieldName> <Type>)"`.
    function permitWitnessTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external;

    /// @notice Batched form — one signature, one nonce, N transfers.
    function permitTransferFrom(
        PermitBatchTransferFrom calldata permit,
        SignatureTransferDetails[] calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;

    /// @notice Batched witness-bound form.
    function permitWitnessTransferFrom(
        PermitBatchTransferFrom calldata permit,
        SignatureTransferDetails[] calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external;
}
