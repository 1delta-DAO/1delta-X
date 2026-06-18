// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title IPermit3
/// @notice Dual-allowance hub:
///         • token book — Permit2-equivalent. Spender pulls ERC20 via transferFrom.
///         • taker book — Taker module pulls value from a user's position
///           (borrow, withdraw, unstake, claim, …) via Permit3.take(…).
///
///         Users approve Permit3 once per asset/module and tune caps per order.
interface IPermit3 {
    struct PackedAllowance {
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }

    // ──────────────────── Permit structs (signed) ────────────────────

    struct TokenPermit {
        address spender;
        address token;
        uint160 amount;
        uint48 expiration;
    }

    struct TakerPermit {
        address spender;
        bytes32 ref;
        uint160 amount;
        uint48 expiration;
    }

    struct PermitBatch {
        TokenPermit[] tokens;
        TakerPermit[] takers;
        uint256 nonce;
        uint256 deadline;
    }

    // ──────────────────── Batch-transfer / lockdown structs ────────────────────

    /// @notice Mirrors Permit2's `AllowanceTransferDetails` — one leg of a
    ///         batched `transferFrom`.
    struct AllowanceTransferDetails {
        address from;
        address to;
        uint160 amount;
        address token;
    }

    /// @notice Mirrors Permit2's `TokenSpenderPair` — a (token, spender) pair to
    ///         revoke in a token-book `lockdown`.
    struct TokenSpenderPair {
        address token;
        address spender;
    }

    /// @notice Taker-book analogue of `TokenSpenderPair` — a (spender, ref) pair
    ///         to revoke in a taker-book `lockdownTakers`.
    struct SpenderRefPair {
        address spender;
        bytes32 ref;
    }

    // ──────────────────── Events ────────────────────

    event TokenApproval(
        address indexed user, address indexed spender, address indexed token, uint160 amount, uint48 expiration
    );
    event TakerApproval(
        address indexed user, address indexed spender, bytes32 indexed ref, uint160 amount, uint48 expiration
    );
    event PermitBatchApplied(address indexed owner, uint256 indexed nonce);
    /// @dev Token-book lockdown. Matches Permit2's `Lockdown` event shape.
    event Lockdown(address indexed owner, address token, address spender);
    /// @dev Taker-book lockdown (Permit3 extension).
    event TakerLockdown(address indexed owner, address spender, bytes32 ref);
    /// @dev Emitted when an unordered permit nonce word/mask is invalidated.
    ///      Matches Permit2's `UnorderedNonceInvalidation` event shape.
    event UnorderedNonceInvalidation(address indexed owner, uint256 word, uint256 mask);

    // ──────────────────── Errors ────────────────────

    error AllowanceExpired(uint48 expiration);
    error InsufficientAllowance(uint160 amount);
    error Reentrancy();
    error PermitExpired();
    error PermitNonceUsed();

    // ──────────────────── Token side ────────────────────

    function approveToken(address spender, address token, uint160 amount, uint48 expiration) external;

    function transferFrom(address user, address to, address token, uint160 amount) external;

    /// @notice Batched token-book transfer. Mirrors Permit2's
    ///         `transferFrom(AllowanceTransferDetails[])`. Each leg is gated by
    ///         the (from, msg.sender, token) allowance independently.
    function transferFrom(AllowanceTransferDetails[] calldata transferDetails) external;

    function tokenAllowance(address user, address spender, address token)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);

    // ──────────────────── Taker side ────────────────────
    //
    // The taker book mirrors the token book: it is keyed by `spender` (the
    // approved caller of `take`, e.g. the Settlement contract), so only that
    // spender can consume the allowance. `ref = keccak256(data)` is the
    // module-defined position key (reproducible off-chain); the dispatched module
    // is bound by the maker's signed order, so it need not enter `ref`. Asset
    // identity is encoded inside `data`.

    function approveTaker(address spender, bytes32 ref, uint160 amount, uint48 expiration) external;

    /// @notice Amount-gated dispatch: decrements the user's allowance on
    ///         (user, msg.sender, ref) where `ref = keccak256(data)`, then
    ///         invokes `module.takeOnBehalf(user, amount, receiver, data)`. Only a
    ///         spender the user approved can call — the security boundary is the
    ///         maker's per-spender allowance, exactly like the token book.
    ///         `receiver` is chosen by that trusted spender.
    function take(address module, address user, uint160 amount, address receiver, bytes calldata data) external;

    function takerAllowance(address user, address spender, bytes32 ref)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);

    // ──────────────────── Revocation ────────────────────

    function revokeToken(address spender, address token) external;

    function revokeTaker(address spender, bytes32 ref) external;

    /// @notice Atomically zero a batch of token-book allowances. Ported from
    ///         Permit2's `lockdown(TokenSpenderPair[])` — actually revokes
    ///         on-chain (not an event-only signal).
    function lockdown(TokenSpenderPair[] calldata approvals) external;

    /// @notice Taker-book analogue of `lockdown` — atomically zero a batch of
    ///         taker allowances (Permit3 extension).
    function lockdownTakers(SpenderRefPair[] calldata approvals) external;

    // ──────────────────── Signed permits ────────────────────

    function DOMAIN_SEPARATOR() external view returns (bytes32);

    /// @notice Apply a batch of signed token + taker permits in one call.
    ///         The signature is over the EIP-712 hash of `batch` under
    ///         Permit3's domain separator.
    function permitBatch(address owner, PermitBatch calldata batch, bytes calldata sig) external;

    /// @notice Same as `permitBatch` but binds the signature to an
    ///         arbitrary caller-defined `witness` (e.g. an order hash).
    ///         The same signature can never be reused for a different
    ///         witness even if `batch` and `nonce` match.
    /// @dev    `witnessTypeString` follows the Permit2 convention: the
    ///         caller provides the EIP-712 type definitions for the
    ///         witness *and* for `TokenPermit` and `TakerPermit`, in
    ///         alphabetical order, starting from `"<fieldName> <Type>)"`.
    ///         Permit3 prepends a stub of the form
    ///         `"PermitBatchWitness(TokenPermit[] tokens,TakerPermit[] takers,uint256 nonce,uint256 deadline,"`.
    function permitBatchWithWitness(
        address owner,
        PermitBatch calldata batch,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata sig
    ) external;

    function isPermitNonceUsed(address owner, uint256 nonce) external view returns (bool);

    /// @notice Invalidate unordered permit nonces in bulk by OR-ing `mask` into
    ///         the bitmap word at `wordPos`. Ported from Permit2's
    ///         `invalidateUnorderedNonces` — lets a signer cancel signed
    ///         permits before they are consumed.
    function invalidateUnorderedNonces(uint256 wordPos, uint256 mask) external;
}
