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

    /// @dev A taker allowance now names the MODULE it authorises, not just the
    ///      `ref = keccak256(data)` position key. The book is keyed
    ///      `(user, spender, module, ref)`, so approving a borrow module can never
    ///      be consumed dispatching a different module that happens to share the
    ///      same `data` bytes. `module` is its own signed field so a wallet can
    ///      render "authorise <module> for <amount>" rather than an opaque hash.
    struct TakerPermit {
        address spender;
        address module;
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

    /// @notice Taker-book analogue of `TokenSpenderPair` — a (spender, module, ref)
    ///         triple to revoke in a taker-book `lockdownTakers`.
    struct SpenderRefPair {
        address spender;
        address module;
        bytes32 ref;
    }

    /// @notice One-shot signed taker dispatch — the taker-book analogue of
    ///         `PermitTransferFrom`. Authorises ONE `take`-style module dispatch
    ///         and leaves no standing allowance behind. `spender` is NOT a field:
    ///         it is always `msg.sender` at consumption, exactly like a signature
    ///         transfer, so a leaked signature is useless to anyone else.
    struct PermitTake {
        address module;
        bytes32 ref;
        uint160 amount;
        uint256 nonce;
        uint256 deadline;
    }

    // ──────────────────── Events ────────────────────

    event TokenApproval(
        address indexed user, address indexed spender, address indexed token, uint160 amount, uint48 expiration
    );
    event TakerApproval(
        address indexed user,
        address indexed spender,
        bytes32 indexed ref,
        address module,
        uint160 amount,
        uint48 expiration
    );
    /// @dev A taker dispatch actually occurred. The taker book is the novel half
    ///      of Permit3 and — unlike the token book, covered by ERC20 `Transfer`
    ///      events — has no protocol-level trace of its own. Emitted by `take`.
    event Taken(
        address indexed user, address indexed spender, bytes32 indexed ref, address module, uint160 amount, address receiver
    );
    event PermitBatchApplied(address indexed owner, uint256 indexed nonce);
    /// @dev Token-book lockdown. Matches Permit2's `Lockdown` event shape.
    event Lockdown(address indexed owner, address token, address spender);
    /// @dev Taker-book lockdown (Permit3 extension).
    event TakerLockdown(address indexed owner, address spender, address module, bytes32 ref);
    /// @dev Emitted when an unordered permit nonce word/mask is invalidated.
    ///      Matches Permit2's `UnorderedNonceInvalidation` event shape.
    event UnorderedNonceInvalidation(address indexed owner, uint256 word, uint256 mask);
    /// @dev A user toggled strict mode — see {strictMode}.
    event StrictModeSet(address indexed user, bool enabled);

    // ──────────────────── Errors ────────────────────

    error AllowanceExpired(uint48 expiration);
    error InsufficientAllowance(uint160 amount);
    error Reentrancy();
    error PermitExpired();
    error PermitNonceUsed();
    /// @dev A `take`/`transferFrom` with `amount == 0` — rejected so an
    ///      unauthorised caller cannot reach a module's `takeOnBehalf` (or make
    ///      Permit3 issue an arbitrary zero-value `transferFrom`) with a zero
    ///      amount: the allowance gate does not decrement on zero and so would not
    ///      stop it.
    error ZeroAmount();
    /// @dev The Permit3 leg of {Permit3TransferLib.transferFromWithFallback}
    ///      failed and the payer has {strictMode} enabled, so the direct-approval
    ///      fallback is refused rather than silently consulted.
    error Permit3Denied();
    /// @dev A {permitTake} was presented with `keccak256(data) != permit.ref` — the
    ///      dispatched position does not match the one the owner signed.
    error RefMismatch();
    /// @dev {lockdownAll}'s parallel nonce word/mask arrays are different lengths.
    error NonceArrayLengthMismatch();

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
        returns (uint160 amount, uint48 expiration);

    /// @notice Opt in to STRICT MODE. When enabled for `msg.sender`, the
    ///         direct-ERC20-approval fallback in
    ///         {Permit3TransferLib.transferFromWithFallback} is refused for that
    ///         payer: a fill that cannot be funded through Permit3's own allowance
    ///         book reverts {Permit3Denied} instead of falling through to a plain
    ///         `transferFrom`. This makes `revokeToken`/`lockdown`/an expiry an
    ///         actual kill switch for a payer who also holds a direct approval.
    ///         Off by default, so it costs nothing on the hot path for anyone who
    ///         never opts in.
    function setStrictMode(bool enabled) external;

    /// @notice Whether `user` has opted into strict mode (see {setStrictMode}).
    function strictMode(address user) external view returns (bool);

    // ──────────────────── Taker side ────────────────────
    //
    // The taker book mirrors the token book: it is keyed by `spender` (the
    // approved caller of `take`, e.g. the Settlement contract), so only that
    // spender can consume the allowance. `ref = keccak256(data)` is the
    // module-defined position key (reproducible off-chain); the dispatched module
    // is bound by the maker's signed order, so it need not enter `ref`. Asset
    // identity is encoded inside `data`.

    function approveTaker(address spender, address module, bytes32 ref, uint160 amount, uint48 expiration) external;

    /// @notice Amount-gated dispatch: decrements the user's allowance on
    ///         (user, msg.sender, module, ref) where `ref = keccak256(data)`, then
    ///         invokes `module.takeOnBehalf(user, amount, receiver, data)`. Only a
    ///         spender the user approved can call — the security boundary is the
    ///         maker's per-(spender, module) allowance, exactly like the token
    ///         book. `receiver` is chosen by that trusted spender.
    function take(address module, address user, uint160 amount, address receiver, bytes calldata data) external;

    function takerAllowance(address user, address spender, address module, bytes32 ref)
        external
        view
        returns (uint160 amount, uint48 expiration);

    /// @notice The taker-book position key for a `(module, data)` pair —
    ///         `ref = keccak256(data)`. Exposed so integrators never hand-roll the
    ///         hash (and never silently key an approval to the wrong bytes); the
    ///         allowance itself is keyed `(user, spender, module, ref)`.
    function refFor(bytes calldata data) external pure returns (bytes32 ref);

    // ──────────────────── Revocation ────────────────────

    function revokeToken(address spender, address token) external;

    function revokeTaker(address spender, address module, bytes32 ref) external;

    /// @notice Atomically zero a batch of token-book allowances. Ported from
    ///         Permit2's `lockdown(TokenSpenderPair[])` — actually revokes
    ///         on-chain (not an event-only signal).
    function lockdown(TokenSpenderPair[] calldata approvals) external;

    /// @notice Taker-book analogue of `lockdown` — atomically zero a batch of
    ///         taker allowances (Permit3 extension).
    function lockdownTakers(SpenderRefPair[] calldata approvals) external;

    /// @notice One transaction that revokes across BOTH books AND invalidates signed
    ///         permit nonces — the "revoke everything at Permit3" primitive. Collapses
    ///         `lockdown` + `lockdownTakers` + `invalidateUnorderedNonces` so a maker
    ///         responding to a compromise does not run a four-step checklist. (The
    ///         protocol-native delegation — `approveDelegation`/`comet.allow`/
    ///         `setAuthorization` — is the only leg that must still be revoked
    ///         per-protocol; nothing at Permit3 can reach it.)
    function lockdownAll(
        TokenSpenderPair[] calldata tokens,
        SpenderRefPair[] calldata takers,
        uint256[] calldata nonceWords,
        uint256[] calldata nonceMasks
    ) external;

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

    /// @notice IDEMPOTENT `permitBatchWithWitness`. The signature is verified on
    ///         every call — so it can never authorise a batch the owner did not
    ///         sign — but if `batch.nonce` was already spent the call returns
    ///         quietly WITHOUT re-applying the grants, instead of reverting
    ///         {PermitNonceUsed}.
    ///
    ///         This is what makes a single-signature `fillWithPermit` safe to
    ///         partial-fill and impossible to grief: anyone can land the permit
    ///         first (front-run, failed relay), but doing so no longer bricks the
    ///         order — the next fill re-presents the same signature, finds the
    ///         nonce spent, skips the grant, and proceeds against the allowances
    ///         the first application left. The verification stays unconditional, so
    ///         the nonce spend and the grant are the ONLY steps skipped.
    function permitBatchWithWitnessIfNeeded(
        address owner,
        PermitBatch calldata batch,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata sig
    ) external;

    /// @notice One-shot signed taker dispatch — the taker-book analogue of
    ///         `permitTransferFrom`. Verifies `owner`'s signature over `permit`
    ///         (whose signed spender is `msg.sender`), spends the nonce, and
    ///         dispatches `module.takeOnBehalf(owner, permit.amount, receiver,
    ///         data)` — leaving NO standing allowance behind. `keccak256(data)`
    ///         must equal `permit.ref`. Reverts {ZeroAmount} on a zero amount.
    function permitTake(PermitTake calldata permit, address owner, address receiver, bytes calldata data, bytes calldata sig)
        external;

    /// @notice Witness-bound {permitTake}: binds the dispatch to an arbitrary
    ///         caller-defined `witness` (e.g. an order hash), so one maker
    ///         signature authorises both the order and the single position pull it
    ///         consumes, with no allowance left over.
    function permitTakeWithWitness(
        PermitTake calldata permit,
        address owner,
        address receiver,
        bytes calldata data,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata sig
    ) external;

    /// @notice ERC-5267 domain descriptor — lets wallets and signing tooling
    ///         auto-derive the EIP-712 domain instead of being told it out of band.
    function eip712Domain()
        external
        view
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        );

    function isPermitNonceUsed(address owner, uint256 nonce) external view returns (bool);

    /// @notice Invalidate unordered permit nonces in bulk by OR-ing `mask` into
    ///         the bitmap word at `wordPos`. Ported from Permit2's
    ///         `invalidateUnorderedNonces` — lets a signer cancel signed
    ///         permits before they are consumed.
    function invalidateUnorderedNonces(uint256 wordPos, uint256 mask) external;
}
