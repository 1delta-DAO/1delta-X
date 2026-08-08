// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC1271} from "@core/interfaces/IERC1271.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {SignatureVerification} from "@core/permit3/SignatureVerification.sol";

/// @title PositionFunnel
/// @notice A minimal, user-owned account on the DESTINATION chain: it catches
///         bridged funds, is the `maker` of the destination order, and ends up
///         holding whatever position that order opens.
///
///  Why this exists
///  ───────────────
///  Settlement runs an order's items with `onBehalfOf = order.maker` and pulls
///  `legsIn` from `order.maker`. So the maker IS the funnel — whatever address a
///  destination order names is where the funds come from and where any position
///  lands. The shared {BridgedOrderInbox} can only ever host orders WITHOUT items
///  for that reason: a leverage loop under a pooled escrow would open a position
///  owned by the pool and collateralised by everyone's funds. One funnel per user
///  removes the conflict entirely, which is why this contract carries none of the
///  inbox's machinery — no liability accounting, no funding invariant, no
///  permissionless refund, no guardian rescue. A stray or orphaned delivery here
///  is simply the owner's, and they withdraw it.
///
///  No bridge message needed
///  ────────────────────────
///  The inbox needs a bridged commitment because it must be told which order it
///  is allowed to authorise. A funnel does not: its owner has a key, so the
///  destination order is a NORMALLY SIGNED order whose maker is this contract and
///  whose signature validates through {isValidSignature}. That collapses the
///  destination side to a plain transfer — Across sends with an empty `message`,
///  LayerZero with an empty `composeMsg` — so on the LayerZero paths there is no
///  `lzCompose` at all, and with it none of the orphan risk that asymmetry
///  creates. The bridge just moves tokens to an address.
///
///  Two signatures, zero destination transactions
///  ─────────────────────────────────────────────
///    1. the destination ORDER, verified here via EIP-1271;
///    2. one {executeSigned} batch granting whatever the order's items need —
///       Permit3 taker allowances for TAKE legs, plus protocol-level on-behalf
///       grants (Aave credit delegation, a Liquity add/remove manager, a Morpho
///       authorisation). Anyone may relay it.
///
///  Both are produced off-chain with the key the user already has. They never
///  need gas on this chain, and {enableToken} is permissionless so a solver can
///  wire the Permit3 side while filling.
///
///  Cancellation
///  ────────────
///  {withdraw} is the cancel primitive: pull the funds and every pending order
///  against them stops being fillable, because Settlement's pull reverts and the
///  lens already reports `fillableAmount` capped by balance. No nonce burn, no
///  signature, no on-chain order state. Note this covers IDLE balance only — once
///  collateral backs debt it is not withdrawable, and unwinding is a real
///  operation done through {execute}.
///  Deployment shape
///  ────────────────
///  Clones carry their owner as an IMMUTABLE ARGUMENT appended to the proxy's
///  runtime code, not in storage. {PositionFunnelFactory} bakes it into the init
///  code, so a funnel costs one CREATE2 and nothing else — no `initialize` call,
///  no 20k cold SSTORE, and no window in which an uninitialised clone exists to be
///  front-run. `owner` is read straight off the end of calldata, which the proxy
///  appends on every delegatecall.
///
///  Because every delegatecall then carries at least {ARGS_LENGTH} bytes, a bare
///  value transfer could never reach a `receive()` here. The proxy solves that on
///  its own side by terminating on empty calldata, so a funnel accepts ether by
///  any means and this contract needs no `receive()` at all — see {fallback}.
contract PositionFunnel is IERC1271 {
    IPermit3 public immutable PERMIT3;
    address public immutable SETTLEMENT;
    /// @notice The {SettlementLens}. Not used for settlement — it is allowed to
    ///         consume this funnel's EIP-1271 signatures so off-chain preflight
    ///         (`getOrderRelevantState`) can attest an order the same way the
    ///         settler will. Without it the orderbook would read every funnel order
    ///         as unsigned and drop it.
    address public immutable LENS;
    /// @notice The one contract allowed to call {grant}. Immutable and shared by
    ///         every clone, so a funnel needs no per-user setup to use it.
    address public immutable GRANT_MODULE;
    /// @dev This implementation's own address. Used to reject calls made directly
    ///      to it rather than through a clone: called directly, `owner()` reads
    ///      whatever the caller put in the last 20 bytes of calldata, so without
    ///      this guard anyone could pass the owner check on the implementation.
    ///      It holds no funds or allowances, but the guard costs almost nothing.
    address private immutable _SELF;

    /// @notice Bytes of immutable argument the proxy appends: one address.
    uint256 internal constant ARGS_LENGTH = 20;

    /// @notice Consumed {executeSigned} nonces.
    mapping(uint256 => bool) public execNonceUsed;

    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _HASHED_NAME = keccak256("PositionFunnel");
    bytes32 private constant _HASHED_VERSION = keccak256("1");
    bytes32 private constant _CALL_TYPEHASH = keccak256("Call(address target,uint256 value,bytes data)");
    bytes32 private constant _EXECUTE_TYPEHASH = keccak256(
        "ExecuteBatch(Call[] calls,uint256 nonce,uint256 deadline)Call(address target,uint256 value,bytes data)"
    );

    event TokenEnabled(address indexed token);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event Executed(uint256 indexed nonce, uint256 callCount);

    error NotProxy();
    error UnknownSelector();
    error NotGrantModule();
    error GrantsDisabled();
    error AmountOverflow();
    error NotOwner();
    error CallFailed(uint256 index, bytes ret);
    error ExecExpired();
    error NonceUsed();
    error BadSignature();
    error Reentrancy();
    error NativeTransferFailed();

    /// @dev UNLOCKED is 0 as well as 1. A clone starts with entirely zero storage —
    ///      no initializer of the implementation ever runs for it — so a guard
    ///      written as `_lock != 1` would treat every fresh funnel as already
    ///      entered and brick `withdraw`, `execute`, and `executeSigned` forever.
    ///      Only the explicit ENTERED value is rejected.
    uint256 private constant _ENTERED = 2;
    uint256 private _lock;

    modifier onlyOwner() {
        if (address(this) == _SELF) revert NotProxy();
        if (msg.sender != owner()) revert NotOwner();
        _;
    }

    modifier onlyProxy() {
        if (address(this) == _SELF) revert NotProxy();
        _;
    }

    modifier nonReentrant() {
        if (_lock == _ENTERED) revert Reentrancy();
        _lock = _ENTERED;
        _;
        _lock = 1;
    }

    constructor(address permit3, address settlement, address lens, address grantModule) {
        PERMIT3 = IPermit3(permit3);
        SETTLEMENT = settlement;
        LENS = lens;
        GRANT_MODULE = grantModule;
        _SELF = address(this);
    }

    // ──────────────────── Just-in-time allowances ────────────────────

    /// @notice Owner circuit breaker for {grant}. Default false (grants enabled);
    ///         the funnel still works with ordinary standing allowances if set.
    bool public grantsDisabled;

    event GrantsDisabledSet(bool disabled);

    function setGrantsDisabled(bool disabled) external onlyOwner {
        grantsDisabled = disabled;
        emit GrantsDisabledSet(disabled);
    }

    /// @notice Install a Permit3 allowance that the REST OF THIS FILL consumes.
    ///         Called by {FunnelGrantModule} from a grant item the owner signed,
    ///         so a leverage order needs no standing approvals and no second
    ///         signature — the order itself is the authorisation.
    ///
    ///  Why this cannot be used to drain the funnel
    ///  ───────────────────────────────────────────
    ///    1. `msg.sender` must be {GRANT_MODULE}, an immutable address.
    ///    2. That module only runs from `Settlement._executeItem(s)`, which it gates
    ///       on `msg.sender == SETTLEMENT`.
    ///    3. Settlement reaches items ONLY after verifying the maker — every entry
    ///       point (`fill`, `fillUpTo`, `fillSelf`/`batchFill`, `batchSettle`,
    ///       `matchSettle`) calls `_verifySignature`, and `fillWithPermit` binds the
    ///       order hash as a Permit3 witness. For a funnel that check is
    ///       {isValidSignature}, i.e. the owner's key. (`matchSettle` verifies in
    ///       its contract-owned OPEN phase, before any schedule step runs — its
    ///       solver-supplied schedule can reorder items but can never reach one
    ///       whose order was not opened and verified first.)
    ///    4. `_executeItem` passes `order.maker` as the module's `onBehalfOf`, and
    ///       the module targets THAT address — never one taken from item data. So a
    ///       grant item in an ATTACKER's order can only ever touch the attacker's
    ///       own funnel.
    ///
    ///  And what it can do is bounded even so:
    ///    • it can only create a Permit3 allowance — it cannot transfer, and it
    ///      cannot call anything else;
    ///    • `amount` is the item's pro-rata slice, so a partial fill grants exactly
    ///      the fraction the paired item will pull;
    ///    • the expiry is THIS BLOCK. The pull happens later in the same
    ///      transaction, so nothing needs to outlive it, and a leftover from an
    ///      under-pulling module is dead by the next block rather than dangling.
    ///
    ///  The residual is the ordinary one: an owner who signs an order whose grant
    ///  item names a hostile spender has authorised it. That is exactly the trust
    ///  every item already carries — a module's authority lives in maker-signed
    ///  `data` throughout this protocol (`FluidModules.OperateData` names the vault,
    ///  `RiverModules.BorrowParams` the trove manager, and {GenericCallModule}
    ///  carries an arbitrary call TARGET). Against that precedent this module is
    ///  strictly narrower: it can only ever create a Permit3 allowance.
    function grant(address spender, address token, uint160 amount, bool taker, bytes32 ref) external onlyProxy {
        if (msg.sender != GRANT_MODULE) revert NotGrantModule();
        if (grantsDisabled) revert GrantsDisabled();

        // Valid for this block only — `_spend` treats `expiration == 0` as "never
        // expires", so a real timestamp is what bounds it.
        uint48 exp = uint48(block.timestamp);
        if (taker) {
            PERMIT3.approveTaker(spender, ref, amount, exp);
        } else {
            // The ERC20 approval goes to PERMIT3 — a pinned immutable, which is the
            // only case `ensureApproval` is safe for. The caller-supplied `spender`
            // never receives an ERC20 allowance, only a capped, same-block Permit3 one.
            SafeTransferLib.ensureApproval(token, address(PERMIT3), amount);
            PERMIT3.approveToken(spender, token, amount, exp);
        }
    }

    /// @notice The user this funnel belongs to, read from the immutable argument
    ///         the proxy appends to every call rather than from storage.
    /// @dev    Returns garbage (whatever the caller placed there) when the
    ///         IMPLEMENTATION is called directly, which is why every state-changing
    ///         entry point carries {onlyProxy} or {onlyOwner}.
    function owner() public pure returns (address o) {
        assembly {
            o := shr(96, calldataload(sub(calldatasize(), 20)))
        }
    }

    /// @dev Unmatched selectors fail loudly rather than succeeding silently.
    ///
    ///      Plain value transfers do NOT come through here: the proxy terminates on
    ///      empty calldata before it ever delegatecalls, so a funnel accepts ether
    ///      from any sender and by any means — `call`, `transfer`, `send`,
    ///      selfdestruct, a block reward — for about 19 gas, comfortably inside the
    ///      2300-gas stipend. That short circuit exists precisely so this contract
    ///      does not have to reason about a value transfer arriving disguised as a
    ///      20-byte calldata; see the init-code notes in {PositionFunnelFactory}.
    fallback() external {
        revert UnknownSelector();
    }

    // ──────────────────── Order authorisation ────────────────────

    /// @notice Contracts allowed to consume this funnel's EIP-1271 signatures,
    ///         beyond the three built in. Owner-extensible, per funnel.
    mapping(address => bool) public extraSigConsumer;

    event SigConsumerSet(address indexed consumer, bool allowed);

    /// @notice Add or remove an EIP-1271 consumer. See {isValidSignature} for why
    ///         the set is closed by default.
    function setSigConsumer(address consumer, bool allowed) external onlyOwner {
        extraSigConsumer[consumer] = allowed;
        emit SigConsumerSet(consumer, allowed);
    }

    /// @dev Settlement verifies order signatures, Permit3 verifies permits, and the
    ///      lens runs the same check for off-chain preflight. Anything else must be
    ///      opted into.
    function _isSigConsumer(address c) internal view returns (bool) {
        return c == SETTLEMENT || c == address(PERMIT3) || c == LENS || extraSigConsumer[c];
    }

    /// @inheritdoc IERC1271
    /// @dev What makes this contract usable as a `maker`. The destination order is
    ///      signed off-chain by the owner over Settlement's domain; the shared
    ///      verifier tries ECDSA first, fails to match this contract, and falls
    ///      through to here.
    ///
    ///      CLOSED BY DEFAULT. A general-purpose 1271 returns the magic value for
    ///      any digest the owner signed, which is fine for a domain that binds the
    ///      chain — every domain in this protocol does. It is not fine for a third
    ///      party whose domain omits `chainId`: this funnel sits at the SAME address
    ///      on every chain and holds funds on each, so one such signature would be
    ///      replayable somewhere real. Restricting the consumer set makes the funnel
    ///      unusable as a roaming signing identity, which it was never meant to be.
    ///
    ///      Within the allowed set the posture is the ordinary smart-account one,
    ///      the same a Safe or a 7702 account has: an owner who signs a hostile
    ///      payload has authorised it.
    function isValidSignature(bytes32 hash, bytes memory signature) external view returns (bytes4) {
        if (!_isSigConsumer(msg.sender)) return 0xffffffff;
        address o = owner();
        if (signature.length == 65 || signature.length == 64) {
            if (_recover(hash, signature) == o) return IERC1271.isValidSignature.selector;
        }
        // An owner that is itself a contract wallet — nested 1271.
        if (o.code.length != 0) {
            try IERC1271(o).isValidSignature(hash, signature) returns (bytes4 magic) {
                if (magic == IERC1271.isValidSignature.selector) return IERC1271.isValidSignature.selector;
            } catch {}
        }
        return 0xffffffff;
    }

    // ──────────────────── Permit3 wiring ────────────────────

    /// @notice Wire a token so an order's inputs can be pulled: ERC20 approval to
    ///         Permit3, then the standing Permit3 allowance to Settlement.
    ///
    ///         Permissionless by design — it grants Settlement nothing it could not
    ///         already claim, because every pull still requires an order the owner
    ///         signed. Letting a solver call it is what keeps the user's
    ///         destination-chain transaction count at zero.
    function enableToken(address token) public onlyProxy {
        SafeTransferLib.forceApprove(token, address(PERMIT3), type(uint256).max);
        PERMIT3.approveToken(SETTLEMENT, token, type(uint160).max, 0);
        emit TokenEnabled(token);
    }

    function enableTokens(address[] calldata tokens) external {
        for (uint256 i; i < tokens.length; i++) {
            enableToken(tokens[i]);
        }
    }

    // ──────────────────── Owner actions ────────────────────

    /// @notice Withdraw idle balance. Doubles as order cancellation — see the
    ///         contract notes.
    function withdraw(address token, uint256 amount, address to) external onlyOwner nonReentrant {
        SafeTransferLib.safeTransfer(token, to, amount);
        emit Withdrawn(token, to, amount);
    }

    function withdrawNative(uint256 amount, address to) external onlyOwner nonReentrant {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
        emit Withdrawn(address(0), to, amount);
    }

    /// @notice Arbitrary calls under the funnel's own authority — protocol grants,
    ///         position management, unwinding. Direct owner path.
    function execute(Call[] calldata calls) external onlyOwner nonReentrant returns (bytes[] memory rets) {
        rets = _run(calls);
    }

    /// @notice {execute} authorised by an owner SIGNATURE rather than an owner
    ///         transaction, so anyone can relay it. This is what lets a user who
    ///         has never touched this chain grant Permit3 taker allowances and
    ///         protocol on-behalf permissions for a leverage order.
    function executeSigned(Call[] calldata calls, uint256 nonce, uint256 deadline, bytes calldata sig)
        external
        onlyProxy
        nonReentrant
        returns (bytes[] memory rets)
    {
        if (block.timestamp > deadline) revert ExecExpired();
        if (execNonceUsed[nonce]) revert NonceUsed();
        execNonceUsed[nonce] = true;

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), _hashBatch(calls, nonce, deadline)));
        address o = owner();
        // Reuse the shared verifier so an owner that is a contract wallet or a
        // 7702 account works exactly as it does everywhere else in the protocol.
        try this.checkOwnerSignature(digest, sig, o) {}
        catch {
            revert BadSignature();
        }

        rets = _run(calls);
        emit Executed(nonce, calls.length);
    }

    /// @dev External so the (reverting) verifier can be wrapped in try/catch.
    function checkOwnerSignature(bytes32 digest, bytes calldata sig, address expected) external view {
        SignatureVerification.verify(sig, digest, expected);
    }

    // ──────────────────── EIP-712 ────────────────────

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(abi.encode(_DOMAIN_TYPEHASH, _HASHED_NAME, _HASHED_VERSION, block.chainid, address(this)));
    }

    function _hashBatch(Call[] calldata calls, uint256 nonce, uint256 deadline) internal pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](calls.length);
        for (uint256 i; i < calls.length; i++) {
            h[i] = keccak256(abi.encode(_CALL_TYPEHASH, calls[i].target, calls[i].value, keccak256(calls[i].data)));
        }
        return keccak256(abi.encode(_EXECUTE_TYPEHASH, keccak256(abi.encodePacked(h)), nonce, deadline));
    }

    // ──────────────────── Internals ────────────────────

    function _run(Call[] calldata calls) private returns (bytes[] memory rets) {
        rets = new bytes[](calls.length);
        for (uint256 i; i < calls.length; i++) {
            (bool ok, bytes memory ret) = calls[i].target.call{value: calls[i].value}(calls[i].data);
            if (!ok) revert CallFailed(i, ret);
            rets[i] = ret;
        }
    }

    function _recover(bytes32 hash, bytes memory sig) private pure returns (address) {
        bytes32 r;
        bytes32 s;
        uint8 v;
        if (sig.length == 65) {
            assembly {
                r := mload(add(sig, 0x20))
                s := mload(add(sig, 0x40))
                v := byte(0, mload(add(sig, 0x60)))
            }
        } else {
            bytes32 vs;
            assembly {
                r := mload(add(sig, 0x20))
                vs := mload(add(sig, 0x40))
            }
            s = vs & bytes32(0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);
            v = uint8(uint256(vs >> 255)) + 27;
        }
        return ecrecover(hash, v, r, s);
    }
}
