// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedArrays} from "@core/settlement/PackedArrays.sol";
import {DutchAuction} from "@core/settlement/DutchAuction.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {Order, OrderSide} from "@core/settlement/Structs.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

import {CommitmentCodec} from "./CommitmentCodec.sol";
import {IAcrossMessageHandler} from "./vendor/IAcross.sol";
import {ILayerZeroComposer, OFTComposeMsgCodec} from "./vendor/ILayerZero.sol";

/// @dev The settlement surface the inbox uses. `approveOrder` is the existing
///      signature-less authorization path (`OrderState.approveOrder`), keyed by
///      `msg.sender` and requiring `order.maker == msg.sender` — which is exactly
///      what the inbox is.
interface ISettlementApprove {
    function approveOrder(Order calldata order) external returns (bytes32 orderHash);
    function revokeOrderApproval(bytes32 orderHash) external;
    function filled(bytes32 orderHash) external view returns (uint256);
}

/// @title BridgedOrderInbox
/// @notice Destination-chain endpoint for the sequential cross-chain order flow,
///         and the MAKER of every order it settles.
///
///  The flow
///  ────────
///    1. On chain X the maker's order settles normally, and one of its items
///       bridges the proceeds here, carrying a 64-byte {CommitmentCodec}
///       commitment naming the destination order's hash.
///    2. The bridge delivers tokens + commitment; `_credit` records them.
///    3. Anyone calls {activate} with the destination ORDER — its hash must match
///       the commitment. The inbox authorizes it on-chain via the settlement's
///       signature-less `approveOrder`.
///    4. A solver fills it like any other order. The end user is simply
///       `legsOut[j].recipient`, so they need no allowances, no balance, and no
///       prior interaction with this chain at all.
///    5. Anything unfilled by the deadline is claimable by the bridged
///       `beneficiary` via {settle}.
///
///  Why the inbox is the maker
///  ──────────────────────────
///  The settlement's on-chain approval mapping is `msg.sender`-keyed, so nobody
///  can authorize an order on another maker's behalf — correctly. A destination
///  order whose maker were the end user therefore could not be authorized by a
///  bridge message at all, and the user would additionally need Permit3
///  allowances on a chain they may never have touched. Making the inbox the maker
///  removes both problems: it holds the funds, it holds the allowances, and the
///  user is only ever an output recipient.
///
///  The funding invariant
///  ─────────────────────
///  The inbox grants Settlement a standing Permit3 allowance over its whole
///  balance, and Settlement pulls a fill's inputs WITHOUT consulting any
///  bookkeeping here. Per-order accounting inside this contract therefore cannot
///  constrain a pull. The isolation comes from a single rule in {activate}:
///
///      an order is approved only once `credited >= _legInStart(order.legsIn, 0)`
///
///  The settlement caps cumulative fills at the anchor, which for the constrained
///  shape below IS `legsIn[0].start`. So for every approved order
///  `filled <= anchor <= credited`, and summing over all orders, total pulled
///  never exceeds total received. One user's order can never reach another's
///  funds — not by bookkeeping, but by construction.
///
///  The practical consequence is that a destination order must be authored
///  against the bridge's GUARANTEED delivery floor, never its expected amount.
///  All three supported bridges provide one: Across enforces `outputAmount`
///  exactly, Stargate enforces `minAmountLD`, and a plain OFT delivers the sent
///  amount minus deterministic shared-decimal dust. Surplus above the floor stays
///  credited and refunds to the beneficiary via {settle}.
///
///  Note this satisfies the LayerZero guidance to enforce a minimum in the message
///  payload rather than through executor options: the floor is `legsIn[0].start` of
///  the maker-signed order the commitment names, checked on-chain in {activate}.
///  Executor options are an off-chain agreement and are never relied on here.
///
///  Trust assumptions — this contract is a CUSTODIAN
///  ────────────────────────────────────────────────
///  Between delivery and fill it holds user funds, so its trust surface is worth
///  stating plainly:
///
///    1. THE REGISTERED BRIDGE ENDPOINTS ARE TRUSTED TO REPORT AMOUNTS HONESTLY.
///       `SPOKE_POOL` and each {setComposeSource} entry assert how much they
///       delivered, and this contract credits that figure. It cannot independently
///       measure the arrival: on the LayerZero path the tokens land in an earlier
///       transaction, so no balance delta is observable here. A source that
///       inflated its amount would let one commitment over-claim against the pool.
///       This is inherent to every bridge integration; the mitigation is
///       operational — register only canonical, verified addresses.
///    2. The owner controls that registry, so a compromised owner key is a fund-
///       loss path. Ownership therefore moves in two steps ({transferOwnership} /
///       {acceptOwnership}), and {rescue} is bounded by `balance - liability` so it
///       can never reach funds owed to a live commitment.
///    3. Settlement and Permit3 are trusted (the standing allowance is to
///       Settlement alone, and only for tokens {enableToken} has wired).
contract BridgedOrderInbox is IAcrossMessageHandler, ILayerZeroComposer {
    using DutchAuction for Order; // `side` now lives in `timing` bit 101
    IPermit3 public immutable PERMIT3;
    ISettlementApprove public immutable SETTLEMENT;

    /// @notice Across SpokePool authorized to call {handleV3AcrossMessage}.
    ///         `address(0)` disables the Across path on this deployment.
    address public immutable SPOKE_POOL;
    /// @notice LayerZero V2 endpoint authorized to call {lzCompose}.
    ///         `address(0)` disables the LayerZero path on this deployment.
    address public immutable LZ_ENDPOINT;

    address public owner;
    /// @notice Nominee from {transferOwnership}, pending {acceptOwnership}.
    ///         Ownership moves in two steps because a typo in a one-step transfer
    ///         would strand the {rescue} escape hatch permanently.
    address public pendingOwner;

    struct Commit {
        address token; //         the credited ERC20; fixed by the first credit
        address beneficiary; //   refund target, from the bridged commitment
        uint256 credited; //      total arrived for this order hash
        uint256 spentAccounted; //`filled` already reflected in `liability`; see {sync}
        uint64 expiry; //         bridged fallback unlock, used until an order activates
        uint64 deadline; //       the activated order's deadline; authoritative once set
        bool approved; //         {activate} has run
        bool settled; //          {settle} has run; terminal
    }

    /// @notice destination order hash → escrow record.
    mapping(bytes32 => Commit) public commits;

    /// @notice token → funds this contract still holds on behalf of live commits.
    ///         Balance above this is unattributed and is what {rescue} may take.
    ///         Kept current against fills by {sync}, which {settle} calls and which
    ///         anyone may call directly — without it a filled-but-unsettled order
    ///         would leave the figure permanently overstated and the escape hatch
    ///         unusable.
    mapping(address => uint256) public liability;

    /// @notice Tokens wired for settlement (ERC20 → Permit3, Permit3 → Settlement).
    mapping(address => bool) public tokenEnabled;

    /// @notice LayerZero compose payloads already consumed, keyed by
    ///         `keccak256(guid, message)`.
    ///
    ///         NOT keyed by GUID alone. The endpoint's `composeQueue` is keyed by
    ///         (sender, receiver, guid, INDEX), so one send can carry several
    ///         compose messages under a single GUID — and `lzCompose` is not handed
    ///         the index. Deduping on the GUID would silently drop every message
    ///         after the first and orphan its tokens. The base OFT only ever emits
    ///         index 0, so this is latent rather than live, but it is the exact
    ///         shape of bug that surfaces when a pool starts batching.
    ///
    ///         Defensive in any case: the endpoint clears a compose message once it
    ///         executes, so a true replay should be unreachable.
    mapping(bytes32 => bool) public composeConsumed;

    /// @notice Trusted LayerZero compose senders — the Stargate pool or OFT on
    ///         THIS chain — mapped to the ERC20 they deliver.
    mapping(address => address) public composeSourceToken;

    event Credited(bytes32 indexed orderHash, address indexed token, uint256 amount, address beneficiary);
    event Activated(bytes32 indexed orderHash, address indexed token, uint256 anchor, uint64 refundAfter);
    event Settled(bytes32 indexed orderHash, address indexed beneficiary, uint256 spent, uint256 refunded);
    /// @notice A compose delivery this contract will never accept — malformed,
    ///         wrong-chain, unknown token, or against a settled commitment. Emitted
    ///         INSTEAD of reverting, because the tokens landed in an earlier
    ///         transaction and a revert would leave them unreachable. Recoverable
    ///         via {rescue}. Distinct from a compose that simply has not run yet,
    ///         which needs no recovery at all — see the note on {rescue}.
    event Orphaned(bytes32 indexed guid, address indexed token, uint256 amount, bytes reason);
    /// @notice {sync} moved `delta` out of `liability` after observing fills.
    event Synced(bytes32 indexed orderHash, uint256 spent, uint256 delta);
    event Rescued(address indexed token, address indexed to, uint256 amount);
    event TokenEnabled(address indexed token);
    event ComposeSourceSet(address indexed source, address indexed token);
    event OwnerSet(address indexed owner);
    event OwnershipTransferStarted(address indexed pendingOwner);

    error NotOwner();
    error NotPendingOwner();
    error NotSpokePool();
    error NotEndpoint();
    error UntrustedComposeSource();
    error BadCommitment();
    error WrongChain();
    error TokenMismatch();
    error TokenNotEnabled();
    error AlreadySettled();
    error Underfunded();
    error NotYetRefundable();
    error UnsupportedOrderShape();
    error NothingToRescue();
    error Reentrancy();

    uint256 private _lock = 1;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev Applied to the two functions that move tokens out. Deliberately NOT
    ///      applied to {lzCompose}: a guard there could make it revert, and a
    ///      reverting compose handler is the one failure this contract is built to
    ///      avoid. That path holds no such risk anyway — it makes no external call.
    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(address permit3, address settlement, address spokePool, address lzEndpoint, address _owner) {
        PERMIT3 = IPermit3(permit3);
        SETTLEMENT = ISettlementApprove(settlement);
        SPOKE_POOL = spokePool;
        LZ_ENDPOINT = lzEndpoint;
        owner = _owner;
        emit OwnerSet(_owner);
    }

    // ──────────────────── Admin ────────────────────

    /// @notice Wire a token for settlement: ERC20 approval to Permit3, then the
    ///         standing Permit3 allowance to Settlement that lets an approved
    ///         order's inputs be pulled. Permissionless would be fine (it grants
    ///         nothing an order cannot already claim), but keeping it owned makes
    ///         the supported set explicit and auditable.
    function enableToken(address token) external onlyOwner {
        if (tokenEnabled[token]) return;
        tokenEnabled[token] = true;
        SafeTransferLib.forceApprove(token, address(PERMIT3), type(uint256).max);
        PERMIT3.approveToken(address(SETTLEMENT), token, type(uint160).max, 0);
        emit TokenEnabled(token);
    }

    /// @notice Register a LayerZero compose sender (a Stargate pool or an OFT on
    ///         this chain) and the ERC20 it delivers. Only registered sources may
    ///         drive {lzCompose}; the token is taken from here rather than from
    ///         the message, so a compose payload can never name a token it did not
    ///         actually deliver.
    function setComposeSource(address source, address token) external onlyOwner {
        composeSourceToken[source] = token;
        emit ComposeSourceSet(source, token);
    }

    /// @notice Step one of a two-step ownership handover. Nothing changes until the
    ///         nominee calls {acceptOwnership}, so a mistyped address cannot strand
    ///         {rescue} — the only way orphaned deliveries are ever recovered.
    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnerSet(owner);
    }

    // ──────────────────── Bridge inbound: Across ────────────────────

    /// @inheritdoc IAcrossMessageHandler
    /// @dev Tokens and message arrive together in the relayer's fill transaction,
    ///      so this can and SHOULD revert on a bad payload: the fill unwinds, the
    ///      relayer skips the deposit, and it refunds to the depositor on the
    ///      origin chain after `fillDeadline`. Nothing is ever stranded here.
    ///
    ///      `message` is declared `calldata` (the upstream interface says
    ///      `memory`); the external ABI is identical and calldata slicing is what
    ///      {CommitmentCodec} reads.
    function handleV3AcrossMessage(address tokenSent, uint256 amount, address, bytes calldata message) external {
        if (msg.sender != SPOKE_POOL) revert NotSpokePool();
        (bool ok, CommitmentCodec.Commitment memory c) = CommitmentCodec.tryDecode(message);
        if (!ok) revert BadCommitment();
        if (c.dstChainId != block.chainid) revert WrongChain();
        if (!tokenEnabled[tokenSent]) revert TokenNotEnabled();
        _credit(c, tokenSent, amount);
    }

    // ──────────────────── Bridge inbound: LayerZero (Stargate + OFT) ────────────────────

    /// @inheritdoc ILayerZeroComposer
    /// @dev NEVER reverts on business-logic failure. The tokens were already
    ///      delivered in the preceding `lzReceive` transaction, so a permanent
    ///      revert here would strand them at this address with no attribution.
    ///      Malformed, wrong-chain, or unknown-token deliveries are parked as
    ///      orphans ({Orphaned}) and recoverable only via {rescue}.
    ///
    ///      The authorization checks DO revert — a call that is not from the
    ///      endpoint, or claims an unregistered compose source, delivered nothing
    ///      to strand.
    function lzCompose(address _from, bytes32 _guid, bytes calldata _message, address, bytes calldata)
        external
        payable
    {
        if (msg.sender != LZ_ENDPOINT) revert NotEndpoint();
        address token = composeSourceToken[_from];
        if (token == address(0)) revert UntrustedComposeSource();

        // Keyed by (guid, payload), not guid alone — see {composeConsumed}.
        bytes32 composeKey = keccak256(abi.encodePacked(_guid, _message));
        if (composeConsumed[composeKey]) return; // defensive; endpoint should prevent replay
        composeConsumed[composeKey] = true;

        if (!OFTComposeMsgCodec.isWellFormed(_message)) {
            emit Orphaned(_guid, token, 0, "header");
            return;
        }
        uint256 amount = OFTComposeMsgCodec.amountLD(_message);
        (bool ok, CommitmentCodec.Commitment memory c) =
            CommitmentCodec.tryDecode(OFTComposeMsgCodec.composeMsg(_message));
        if (!ok) {
            emit Orphaned(_guid, token, amount, "payload");
            return;
        }
        if (c.dstChainId != block.chainid) {
            emit Orphaned(_guid, token, amount, "chain");
            return;
        }
        if (!tokenEnabled[token]) {
            emit Orphaned(_guid, token, amount, "token");
            return;
        }
        Commit storage existing = commits[c.orderHash];
        if (existing.settled || (existing.token != address(0) && existing.token != token)) {
            emit Orphaned(_guid, token, amount, "commit");
            return;
        }
        _credit(c, token, amount);
    }

    // ──────────────────── Escrow accounting ────────────────────

    /// @dev Additive. Several deliveries may back one destination order — a
    ///      partially-filled source order bridges more than once, and each
    ///      delivery simply accumulates until {activate} can be satisfied.
    function _credit(CommitmentCodec.Commitment memory c, address token, uint256 amount) internal {
        Commit storage k = commits[c.orderHash];
        if (k.settled) revert AlreadySettled();
        if (k.token == address(0)) {
            k.token = token;
            k.beneficiary = c.beneficiary;
        } else if (k.token != token) {
            revert TokenMismatch();
        }
        k.credited += amount;
        if (c.expiry > k.expiry) k.expiry = c.expiry;
        liability[token] += amount;
        emit Credited(c.orderHash, token, amount, k.beneficiary);
    }

    /// @notice Authorize a fully-funded destination order on-chain. Permissionless
    ///         and preimage-gated: the caller supplies the ORDER, the inbox hashes
    ///         it and matches against what the bridge committed. A caller can
    ///         therefore only ever activate the exact order the source chain named.
    ///
    ///         Idempotent — safe to call again once more funds have landed, and a
    ///         no-op once approved.
    ///
    /// @dev    `approveOrder` runs before the funding check purely to reuse the
    ///         hash it returns; a failed check reverts the whole call, so the
    ///         approval never survives an invalid activation.
    function activate(Order calldata order) external returns (bytes32 orderHash) {
        _checkShape(order);

        orderHash = SETTLEMENT.approveOrder(order); // reverts unless order.maker == this
        Commit storage k = commits[orderHash];
        if (k.settled) revert AlreadySettled();
        if (k.credited == 0) revert BadCommitment(); // nothing was ever bridged for this hash
        if (PackedArrays.legInToken(order.legsIn, 0) != k.token) revert TokenMismatch();
        if (!tokenEnabled[k.token]) revert TokenNotEnabled();

        // THE funding invariant. See the contract-level note: this, plus the
        // settlement's own `filled <= anchor` cap, is what makes cross-order
        // isolation hold without any pull-time bookkeeping.
        uint256 anchor = _legInStart(order.legsIn, 0);
        if (k.credited < anchor) revert Underfunded();

        k.approved = true;
        // The order's own deadline now governs the refund gate, replacing rather
        // than extending the bridged fallback expiry. Past the deadline the
        // settlement itself refuses to fill, so nothing is gained by holding the
        // beneficiary's funds any longer — and the fallback is typically the more
        // distant of the two.
        k.deadline = uint64(order.deadline);
        emit Activated(orderHash, k.token, anchor, k.deadline);
    }

    /// @notice Terminal wind-up: send the beneficiary everything the order did not
    ///         consume, and clear the liability. Permissionless — the recipient is
    ///         fixed by the bridged commitment, so the caller has no discretion.
    ///
    ///         Gated on {refundAfter}: the activated order's deadline when there
    ///         is one, the commitment's own expiry when no order ever showed up.
    ///         Past the deadline the settlement itself refuses to fill, so there
    ///         is no race with an in-flight solver.
    function settle(bytes32 orderHash) external nonReentrant returns (uint256 refunded) {
        Commit storage k = commits[orderHash];
        if (k.settled) revert AlreadySettled();
        if (k.credited == 0) revert BadCommitment();
        if (block.timestamp <= refundAfter(orderHash)) revert NotYetRefundable();

        // Bring `liability` current with whatever fills already took, then release
        // only what is left. Total released across sync + settle is exactly
        // `credited`, so the figure lands at zero for this commit either way.
        uint256 spent = sync(orderHash);
        refunded = k.credited - spent;

        k.settled = true;
        liability[k.token] -= refunded;

        // Withdraw the standing approval so a late `approveOrder` record cannot
        // be re-used against a re-credited hash.
        if (k.approved) SETTLEMENT.revokeOrderApproval(orderHash);
        if (refunded != 0) SafeTransferLib.safeTransfer(k.token, k.beneficiary, refunded);
        emit Settled(orderHash, k.beneficiary, spent, refunded);
    }

    /// @notice Emergency recovery of UNATTRIBUTED balance — tokens delivered to
    ///         this contract without a usable commitment. In practice that means
    ///         a LayerZero delivery whose compose never landed or was orphaned;
    ///         the Across path cannot produce one, because it reverts instead.
    ///
    ///         RECOVERY ORDER. Reach for this LAST. A compose message that the
    ///         executor never ran is not lost: the endpoint stores it in
    ///         `composeQueue` whether or not the send budgeted an lzCompose option,
    ///         and `endpoint.lzCompose` is PERMISSIONLESS — anyone can execute it
    ///         and pay the gas, after which the delivery credits normally. Rescue
    ///         is for payloads this contract will never accept (malformed,
    ///         wrong-chain, unknown token), not for slow ones.
    ///
    ///         Bounded by `balance - liability`, so funds owed to a live commit
    ///         are unreachable from here regardless of owner intent. Call {sync} on
    ///         any filled-but-unsettled commits first — until then their spent
    ///         portion still counts as owed and the bound reads low.
    function rescue(address token, address to) external onlyOwner nonReentrant returns (uint256 amount) {
        uint256 bal = SafeTransferLib.balanceOf(token, address(this));
        uint256 owed = liability[token];
        if (bal <= owed) revert NothingToRescue();
        amount = bal - owed;
        SafeTransferLib.safeTransfer(token, to, amount);
        emit Rescued(token, to, amount);
    }

    /// @notice Reconcile `liability` with what fills have already pulled for one
    ///         commit. Permissionless and idempotent.
    ///
    ///         Settlement moves an approved order's inputs through Permit3 without
    ///         calling this contract, so nothing here observes a fill as it happens.
    ///         Left unreconciled, `liability` keeps counting funds that are long
    ///         gone, which understates {rescuable} — and since there is usually
    ///         SOME filled-but-unsettled commit, that would keep the escape hatch
    ///         pinned at zero exactly when it is needed. {settle} calls this, but
    ///         waiting for a deadline is too late for a recovery path.
    /// @return spent Cumulative amount this order has pulled, in `token` units.
    function sync(bytes32 orderHash) public returns (uint256 spent) {
        Commit storage k = commits[orderHash];
        if (!k.approved || k.settled) return k.spentAccounted;
        // For the shape `_checkShape` enforces, `filled` is denominated in
        // `legsIn[0]` units — it IS the amount of `token` pulled from here.
        // Clamped because a cancelled order parks `filled` at the uint256 sentinel.
        spent = SETTLEMENT.filled(orderHash);
        if (spent > k.credited) spent = k.credited;
        uint256 delta = spent - k.spentAccounted;
        if (delta != 0) {
            k.spentAccounted = spent;
            liability[k.token] -= delta;
            emit Synced(orderHash, spent, delta);
        }
    }

    // ──────────────────── Views ────────────────────

    /// @notice When {settle} unlocks for a commitment. Once an order is approved
    ///         its deadline is authoritative — it is the moment the order stops
    ///         being fillable. Before that there is no deadline to key on, so the
    ///         bridged fallback expiry applies.
    function refundAfter(bytes32 orderHash) public view returns (uint64) {
        Commit storage k = commits[orderHash];
        return k.approved ? k.deadline : k.expiry;
    }

    /// @notice What {rescue} would currently release; 0 when nothing is loose.
    function rescuable(address token) external view returns (uint256) {
        uint256 bal = SafeTransferLib.balanceOf(token, address(this));
        uint256 owed = liability[token];
        return bal > owed ? bal - owed : 0;
    }

    /// @notice Still-missing funding for a destination order, in `legsIn[0]` units.
    ///         Zero means {activate} will succeed on shape alone. The off-chain
    ///         book uses this to keep a bridged order pending rather than dropping
    ///         it while the bridge is in flight.
    function missingFunding(bytes32 orderHash, uint256 anchor) external view returns (uint256) {
        uint256 credited = commits[orderHash].credited;
        return credited >= anchor ? 0 : anchor - credited;
    }

    // ──────────────────── Order shape ────────────────────

    /// @dev The inbox only makes a deliberately narrow kind of order, because it
    ///      is a shared escrow rather than a wallet:
    ///
    ///        SELL + exactly one input leg — makes the settlement's `filled`
    ///          counter denominated in the credited token, which is what both the
    ///          funding invariant and {settle}'s accounting rely on.
    ///        no fill module, no fillTotal — either would decouple the fill delta
    ///          from the leg anchor and break that denomination.
    ///        no items — an item executes under the maker's authority, and this
    ///          maker's authority is a pooled escrow. Nothing it could legitimately
    ///          want to do requires one.
    ///        at least one output, none addressed to address(0) or to this
    ///          contract — `address(0)` means "the maker", which would deliver the
    ///          user's proceeds back into the escrow where only {rescue} could
    ///          reach them.
    ///        a live deadline — {settle}'s refund gate keys on it.
    function _checkShape(Order calldata order) internal view {
        if (order.side() != OrderSide.SELL) revert UnsupportedOrderShape();
        // A FILL-ONCE order ({DutchAuction.useNonceInvalidator}, `timing` bit 100)
        // records its progress by consuming the maker's NONCE instead of writing
        // `filled[orderHash]`, which stays 0 forever. This inbox's refund accounting
        // reads exactly that counter — `sync` treats `filled` as "the amount of
        // `token` pulled from here" — so such an order would be filled AND refunded
        // in full: the escrow pays out twice for one commitment, and the excess comes
        // out of OTHER commitments' pooled balance. Reject the shape outright; the
        // nonce bitmap is not amount-denominated, so `sync` could not be taught to
        // read it (it can only say filled/not-filled, and `credited` may legitimately
        // exceed the anchor).
        if (order.useNonceInvalidator()) revert UnsupportedOrderShape();
        if (PackedArrays.countUnchecked(order.legsIn) != 1) revert UnsupportedOrderShape();
        if (PackedArrays.countUnchecked(order.legsOut) == 0) revert UnsupportedOrderShape();
        if (PackedArrays.countUnchecked(order.items) != 0) revert UnsupportedOrderShape();
        if (order.fillModule != address(0) || order.fillTotal != 0) revert UnsupportedOrderShape();
        if (_legInStart(order.legsIn, 0) == 0) revert UnsupportedOrderShape();
        if (order.deadline <= block.timestamp) revert UnsupportedOrderShape();
        for (uint256 j; j < PackedArrays.countUnchecked(order.legsOut); j++) {
            address to = _legOutRecipient(order.legsOut, j);
            if (to == address(0) || to == address(this)) revert UnsupportedOrderShape();
        }
    }

    /// @dev `startAmount` of packed input leg `i` — the leg's other fields are unused
    ///      here, so this keeps the call sites from destructuring a 3-tuple each time.
    function _legInStart(bytes calldata legs, uint256 i) private pure returns (uint256 v) {
        (, v,) = PackedArrays.legIn(legs, i);
    }

    /// @dev `recipient` of packed output leg `j`.
    function _legOutRecipient(bytes calldata legs, uint256 j) private pure returns (address r) {
        (,,, r) = PackedArrays.legOut(legs, j);
    }
}
