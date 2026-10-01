// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedArrays} from "@core/settlement/PackedArrays.sol";
import {OrderHash} from "@core/settlement/OrderHash.sol";
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
///  ⚠ The middle step — `filled <= anchor` ⟹ *pulled* `<= anchor` — holds ONLY for
///  a FIXED input leg. `filled` is anchor-denominated, but the amount actually
///  pulled is {Pricing.inputOwed}, and a RISING leg (`legsIn[0].end != 0`) is
///  charged at the decayed tick, reaching `end` while `filled` still reads `start`.
///  `_checkShape` therefore rejects a rising input leg, and that rejection is
///  load-bearing for everything in this paragraph — see the check for the full
///  argument.
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
///       loss path: register an attacker contract as a compose source, have it
///       `sendCompose` a fabricated credit (the LayerZero endpoint relays a compose
///       from ANY sender), and {activate} an inbox-made order paying the attacker
///       out of other depositors' funds. ADDING a source is therefore TIMELOCKED
///       ({COMPOSE_SOURCE_DELAY}, queued by {setComposeSource}, applied by anyone
///       via {applyComposeSource}), so the addition is public for a full delay
///       before it can credit anything — the Drift/KelpDAO lesson (re-audit
///       2026-09-25): one compromised key must not mean "all funds move" at once.
///       REMOVING a source stays instant, since revocation only ever narrows trust.
///       Ownership moves in two steps ({transferOwnership} / {acceptOwnership}).
///
///       The owner's two recovery paths are bounded so that neither can reach a
///       delivery that is merely IN FLIGHT (audit 2026-09-30 BRIDGE-A-1). On the
///       LayerZero path tokens land in `lzReceive` and are credited by a LATER
///       `lzCompose`; until then they sit outside `liability` — and that window is
///       not only "the executor has not run yet": a delivery through a source that
///       is still QUEUED ({setComposeSource}, a whole {COMPOSE_SOURCE_DELAY}) or was
///       just REMOVED reverts in `lzCompose` and stays in the endpoint's queue,
///       uncredited, until the source is live again. An unbounded
///       `balance - liability` sweep took those deliveries, and the later compose
///       then credited a row nothing backed, paid out of other users' escrow.
///         • {rescue} releases only what an {Orphaned} event ANNOUNCED — the
///           `orphaned[token]` ledger — and never more than `balance - liability`.
///         • Anything else (a donation, an Across deposit with no message, a
///           `header` orphan whose amount is unknown, positive rebase yield) goes
///           through {queueStrayRescue} / {executeStrayRescue}: public for a full
///           {COMPOSE_SOURCE_DELAY}, and re-bounded at execution by
///           `balance - liability - orphaned`, so every compose that CAN land in
///           the meantime has landed first.
///       The residual is a compose that cannot run for longer than that delay — a
///       source the owner removed and did not re-add. The queued stray rescue is
///       the public warning for it, the same posture as the source timelock.
///    3. Settlement and Permit3 are trusted (the standing allowance is to
///       Settlement alone, and only for tokens {enableToken} has wired).
///    4. ENABLED TOKENS MUST BE EXACT-TRANSFER AND NON-REBASING (audit 2026-09-30
///       X-TOKENS-1 / BRIDGE-A-6). Credits are the bridge-REPORTED amount (point 1),
///       and Settlement then pulls a filled order's full `owed` out of the POOLED
///       balance. A fee-on-transfer token (including one whose fee switch is merely
///       dormant, like USDT's `basisPointsRate`, or an upgradeable token that later
///       adds one) or a negatively rebasing token makes `credited > held`, and the
///       shortfall lands on whichever row of that token fills or settles LAST.
///       This cannot be measured here: the LayerZero tokens arrive in an earlier
///       transaction, the Across handler runs after the transfer with no snapshot
///       to compare against, and a `balance - liability` clamp would under-credit
///       honest deliveries whenever any fill is filled-but-not-yet-{sync}ed
///       (Settlement pulls without notifying this contract, so that figure reads
///       LOW by every unsynced fill). So it is an admission rule on {enableToken}:
///       the core is asset-general, this pooled escrow is not. A positive rebase
///       goes the other way — the yield is unattributed and reachable only through
///       the delayed stray rescue.
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

    /// @dev One escrow ROW. Keyed by `keccak256(orderHash, beneficiary, token)` —
    ///      see {commitKey} — so the row's identity is the whole commitment, not the
    ///      order hash alone. Amounts are CUMULATIVE and never reset: `credited`
    ///      arrived, `spentAccounted` was pulled by fills (see {sync}), `refunded`
    ///      went back to the beneficiary. What the row still holds is the
    ///      difference, and that is what `liability[token]` sums.
    struct Commit {
        address token; //         the credited ERC20 (part of the key; stored for {settle})
        address beneficiary; //   refund target (part of the key; stored for {settle})
        uint256 credited; //      cumulative arrivals
        uint256 spentAccounted; //cumulative `filled` already reflected in `liability`
        uint256 refunded; //      cumulative refunds paid by {settle}
        uint64 expiry; //         bridged fallback unlock, MAX over credits (see {_credit})
        uint64 deadline; //       the activated order's deadline; authoritative while approved
        bool approved; //         this row is the one funding the order right now
    }

    /// @notice escrow row key → record. See {commitKey}.
    mapping(bytes32 => Commit) public commits;

    /// @notice destination order hash → the ONE row currently funding it (0 = none).
    ///         An order is approved on-chain at most once at a time and its
    ///         `filled` counter is per hash, so exactly one row may back it; a
    ///         second row for the same hash — another beneficiary's or another
    ///         token's — can only ever refund to its own beneficiary.
    mapping(bytes32 => bytes32) public activeRow;

    /// @notice token → funds this contract still holds on behalf of live commits.
    ///         Balance above this is not owed to a row, but it is NOT all loose:
    ///         it also holds LayerZero deliveries whose compose has not run yet.
    ///         See {rescue} / {queueStrayRescue} for what each path may take.
    ///         Kept current against fills by {sync}, which {settle} calls and which
    ///         anyone may call directly — without it a filled-but-unsettled order
    ///         would leave the figure permanently overstated and the escape hatch
    ///         unusable.
    mapping(address => uint256) public liability;

    /// @notice Tokens wired for settlement (ERC20 → Permit3, Permit3 → Settlement).
    mapping(address => bool) public tokenEnabled;

    /// @notice token → amount ANNOUNCED as orphaned by an {Orphaned} event and not
    ///         yet rescued. The only balance {rescue} may release — see trust
    ///         assumption 2.
    ///
    /// @dev    There is deliberately no compose de-duplication map (audit
    ///         2026-09-30 BRIDGE-A-3). EndpointV2 overwrites
    ///         `composeQueue[from][to][guid][index]` with its RECEIVED marker BEFORE
    ///         calling the composer and `sendCompose` refuses an occupied slot, so a
    ///         replay is structurally impossible; the only thing a
    ///         `keccak256(guid, message)` dedupe could ever catch was two DISTINCT
    ///         compose indices under one GUID with byte-identical payloads — i.e. a
    ///         batching source legitimately delivering the same amount twice — and
    ///         it dropped the second one silently, leaving its tokens unattributed.
    ///         The endpoint is already trusted (it is the only permitted caller).
    mapping(address => uint256) public orphaned;

    /// @notice A queued {queueStrayRescue}: who receives it, the most it may move,
    ///         and the earliest time {executeStrayRescue} may run it.
    struct PendingStrayRescue {
        address to;
        uint64 eta;
        uint256 amount;
    }

    /// @notice token → the queued stray rescue for it (`eta == 0` = none).
    mapping(address => PendingStrayRescue) public pendingStrayRescue;

    /// @notice Trusted LayerZero compose senders — the Stargate pool or OFT on
    ///         THIS chain — mapped to the ERC20 they deliver.
    mapping(address => address) public composeSourceToken;

    /// @notice How long a newly registered compose source waits before it can
    ///         credit anything. See trust assumption 2.
    uint256 public constant COMPOSE_SOURCE_DELAY = 2 days;

    /// @notice A queued compose-source registration: the token it will deliver and
    ///         the earliest time {applyComposeSource} may make it live.
    struct PendingComposeSource {
        address token;
        uint64 eta;
    }

    mapping(address => PendingComposeSource) public pendingComposeSource;

    event Credited(bytes32 indexed orderHash, address indexed token, uint256 amount, address beneficiary);
    event Activated(bytes32 indexed orderHash, address indexed token, uint256 anchor, uint64 refundAfter);
    event Settled(bytes32 indexed orderHash, address indexed beneficiary, uint256 spent, uint256 refunded);
    /// @notice A compose delivery this contract will never accept — malformed,
    ///         wrong-chain, unknown token, or against a settled commitment. Emitted
    ///         INSTEAD of reverting, because the tokens landed in an earlier
    ///         transaction and a revert would leave them unreachable. A non-zero
    ///         `amount` is added to `orphaned[token]` and is recoverable via
    ///         {rescue}; a `header` orphan (amount unreadable, 0) only via the
    ///         delayed stray path. Distinct from a compose that simply has not run
    ///         yet, which needs no recovery at all — see the note on {rescue}.
    event Orphaned(bytes32 indexed guid, address indexed token, uint256 amount, bytes reason);
    /// @notice {sync} moved `delta` out of `liability` after observing fills.
    event Synced(bytes32 indexed orderHash, uint256 spent, uint256 delta);
    event Rescued(address indexed token, address indexed to, uint256 amount);
    event StrayRescueQueued(address indexed token, address indexed to, uint256 amount, uint64 eta);
    event StrayRescueCancelled(address indexed token);
    event TokenEnabled(address indexed token);
    event ComposeSourceSet(address indexed source, address indexed token);
    event ComposeSourceQueued(address indexed source, address indexed token, uint64 eta);
    event OwnerSet(address indexed owner);
    event OwnershipTransferStarted(address indexed pendingOwner);

    error NotOwner();
    error NotPendingOwner();
    error NotSpokePool();
    error NotEndpoint();
    error UntrustedComposeSource();
    error ComposeSourceNotReady();
    error BadCommitment();
    error WrongChain();
    error TokenNotEnabled();
    /// @dev Another row is funding this order hash right now; it refunds (or the
    ///      order expires) before a different row may take over.
    error RowActive();
    error Underfunded();
    error NotYetRefundable();
    error UnsupportedOrderShape();
    error NothingToRescue();
    error StrayRescueNotReady();
    /// @dev {lzCompose} was handed native value. The inbox owes no native
    ///      liabilities and has no native path, so value would be locked forever;
    ///      the revert leaves the compose in the endpoint's queue, re-executable
    ///      with zero value (audit 2026-09-30 BRIDGE-A-4).
    error NativeValueNotAccepted();
    error Reentrancy();

    uint256 private _lock = 1;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev Applied to every function that moves tokens out. Deliberately NOT
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
    ///
    ///         ⚠ ADMISSION RULE: exact-transfer, non-rebasing ERC20s only — see
    ///         trust assumption 4. A token whose transfer can deliver less than the
    ///         amount moved (fee-on-transfer, including a dormant fee switch) or
    ///         whose balances can shrink (negative rebase) breaks the pooled
    ///         funding invariant for every other row of that token.
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
    ///
    ///         `token != 0` QUEUES the registration: it goes live only through
    ///         {applyComposeSource}, {COMPOSE_SOURCE_DELAY} later. Re-mapping a live
    ///         source to a different token is an addition too and waits the same.
    ///         `token == 0` REMOVES the source immediately and cancels anything
    ///         queued for it — narrowing trust needs no delay.
    function setComposeSource(address source, address token) external onlyOwner {
        if (token == address(0)) {
            delete pendingComposeSource[source];
            composeSourceToken[source] = address(0);
            emit ComposeSourceSet(source, address(0));
            return;
        }
        uint64 eta = uint64(block.timestamp + COMPOSE_SOURCE_DELAY);
        pendingComposeSource[source] = PendingComposeSource(token, eta);
        emit ComposeSourceQueued(source, token, eta);
    }

    /// @notice Make a queued compose source live once its delay has passed.
    ///         Permissionless: the owner already decided, publicly, a full delay
    ///         ago; applying it is bookkeeping.
    function applyComposeSource(address source) external {
        PendingComposeSource memory p = pendingComposeSource[source];
        if (p.eta == 0 || block.timestamp < p.eta) revert ComposeSourceNotReady();
        delete pendingComposeSource[source];
        composeSourceToken[source] = p.token;
        emit ComposeSourceSet(source, p.token);
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
    ///      to strand. So does a compose carrying native VALUE: `payable` is the
    ///      composer interface's, but this contract has no native liabilities and
    ///      no native exit, so value would be locked forever. The revert is
    ///      retryable — the message stays queued and anyone can re-execute it with
    ///      zero value (audit 2026-09-30 BRIDGE-A-4).
    ///
    ///      Every orphan whose amount is known is added to `orphaned[token]`, the
    ///      ledger {rescue} is bounded by. A `header` orphan carries no readable
    ///      amount; its tokens are recoverable only through the delayed stray path.
    function lzCompose(address _from, bytes32 _guid, bytes calldata _message, address, bytes calldata)
        external
        payable
    {
        if (msg.sender != LZ_ENDPOINT) revert NotEndpoint();
        if (msg.value != 0) revert NativeValueNotAccepted();
        address token = composeSourceToken[_from];
        if (token == address(0)) revert UntrustedComposeSource();

        // No (guid, payload) dedupe — the endpoint makes a replay impossible, and a
        // dedupe only ever dropped a legitimate identical second compose under one
        // GUID. See {orphaned}.

        if (!OFTComposeMsgCodec.isWellFormed(_message)) {
            emit Orphaned(_guid, token, 0, "header");
            return;
        }
        uint256 amount = OFTComposeMsgCodec.amountLD(_message);
        (bool ok, CommitmentCodec.Commitment memory c) =
            CommitmentCodec.tryDecode(OFTComposeMsgCodec.composeMsg(_message));
        if (!ok) {
            _orphan(_guid, token, amount, "payload");
            return;
        }
        if (c.dstChainId != block.chainid) {
            _orphan(_guid, token, amount, "chain");
            return;
        }
        if (!tokenEnabled[token]) {
            _orphan(_guid, token, amount, "token");
            return;
        }
        // Every well-formed delivery has a row of its own now (the key is the whole
        // commitment), so nothing here can be refused as a mismatch any more.
        _credit(c, token, amount);
    }

    /// @dev Park an announced, never-acceptable delivery: emit it and make exactly
    ///      its amount releasable by {rescue}.
    function _orphan(bytes32 guid, address token, uint256 amount, bytes memory reason) private {
        orphaned[token] += amount;
        emit Orphaned(guid, token, amount, reason);
    }

    // ──────────────────── Escrow accounting ────────────────────

    /// @notice The escrow row a commitment lands in.
    /// @dev THE ROW IS THE WHOLE COMMITMENT, NOT THE ORDER HASH. Bridge deliveries
    ///      are unauthenticated on this chain — any depositor can author a
    ///      commitment naming any order hash — and the order hash commits to the
    ///      maker, legs and recipients but NOT to the refund target or the token.
    ///      Keyed by hash alone, whichever delivery landed FIRST owned the record:
    ///      F28 found the beneficiary hijack (a 1-wei front-credit became the refund
    ///      recipient of the victim's principal) and pinned the beneficiary; F29
    ///      found what the pin left — a 1-wei credit still OCCUPIED the hash, so the
    ///      victim's real delivery reverted (Across) or orphaned (LayerZero), and a
    ///      dust credit in another enabled token pinned the token the same way.
    ///      With `(orderHash, beneficiary, token)` in the key a stranger's credit
    ///      lands in a row of its own: it can neither block, redirect nor settle
    ///      the victim's. A credit that copies the victim's whole commitment is a
    ///      gift to the victim's row.
    function commitKey(bytes32 orderHash, address beneficiary, address token) public pure returns (bytes32) {
        return keccak256(abi.encode(orderHash, beneficiary, token));
    }

    /// @dev Additive. Several deliveries may back one row — a partially-filled
    ///      source order bridges more than once, and each delivery simply
    ///      accumulates until {activate} can be satisfied.
    ///
    ///      `expiry` is the MAXIMUM over credits, and that is safe ONLY because the
    ///      row is per-commitment: a stranger can raise the fallback unlock only on
    ///      a row that carries the victim's exact beneficiary and token — i.e. by
    ///      giving the victim money — and even then {settleExpired} refunds the row
    ///      the moment the ORDER's own deadline has passed, whatever the fallback
    ///      says. (F28 briefly took the minimum so a copycat could not park the
    ///      unlock in 2106; the minimum let the same copycat force an early refund
    ///      instead. The deadline path removes the need to choose.)
    ///
    ///      That "even then" needs {settleExpired} to reach EVERY row, not only the
    ///      `legsIn[0].token` one — a row credited in another token can never
    ///      activate, so before audit 2026-09-30 (BRIDGE-A-2 / X-DIFF-REST-1) its
    ///      only exit was the inflatable fallback. {settleExpired} now takes the
    ///      row's token, and opens at once for a row whose order can NEVER
    ///      activate (other token, unsupported or never-expiring shape).
    ///
    ///      A zero-amount credit is ignored outright: it adds nothing to the row,
    ///      so it must not be able to move the row's clock either (the free
    ///      variant of the copycat raise).
    function _credit(CommitmentCodec.Commitment memory c, address token, uint256 amount) internal {
        if (amount == 0) return;
        bytes32 key = commitKey(c.orderHash, c.beneficiary, token);
        Commit storage k = commits[key];
        if (k.token == address(0)) {
            k.token = token;
            k.beneficiary = c.beneficiary;
        }
        k.credited += amount;
        if (c.expiry > k.expiry) k.expiry = c.expiry;
        liability[token] += amount;
        emit Credited(c.orderHash, token, amount, c.beneficiary);
    }

    /// @notice Authorize a fully-funded destination order on-chain from the row
    ///         `(orderHash, beneficiary, legsIn[0].token)`. Permissionless and
    ///         preimage-gated: the caller supplies the ORDER, the inbox hashes it and
    ///         matches against what the bridge committed. A caller can therefore
    ///         only ever activate the exact order the source chain named, and only
    ///         out of a row that names the same token the order sells.
    ///
    ///         Idempotent for the active row — safe to call again once more funds
    ///         have landed, and a no-op once approved. A DIFFERENT row for the same
    ///         hash cannot activate while one is active: the settlement's `filled`
    ///         counter is per hash, so two rows could not both be charged for it.
    ///
    /// @dev    `approveOrder` runs before the funding check purely to reuse the
    ///         hash it returns; a failed check reverts the whole call, so the
    ///         approval never survives an invalid activation.
    function activate(Order calldata order, address beneficiary) external returns (bytes32 orderHash) {
        _checkShape(order);

        orderHash = SETTLEMENT.approveOrder(order); // reverts unless order.maker == this
        address token = PackedArrays.legInToken(order.legsIn, 0);
        bytes32 key = commitKey(orderHash, beneficiary, token);
        Commit storage k = commits[key];
        if (k.credited == 0) revert BadCommitment(); // nothing was ever bridged for this row
        if (!tokenEnabled[token]) revert TokenNotEnabled();
        bytes32 active = activeRow[orderHash];
        if (active != bytes32(0) && active != key) revert RowActive();

        // THE funding invariant. See the contract-level note: this, plus the
        // settlement's own `filled <= anchor` cap, is what makes cross-order
        // isolation hold without any pull-time bookkeeping. `refunded` is
        // subtracted because a row that was settled and re-credited must fund the
        // order out of what it holds NOW.
        uint256 anchor = _legInStart(order.legsIn, 0);
        if (k.credited - k.refunded < anchor) revert Underfunded();

        k.approved = true;
        activeRow[orderHash] = key;
        // The order's own deadline now governs the refund gate, replacing rather
        // than extending the bridged fallback expiry. Past the deadline the
        // settlement itself refuses to fill, so nothing is gained by holding the
        // beneficiary's funds any longer — and the fallback is typically the more
        // distant of the two.
        k.deadline = uint64(DutchAuction.expiry(order));
        emit Activated(orderHash, token, anchor, k.deadline);
    }

    /// @notice Wind-up: send the beneficiary everything the row holds that no fill
    ///         consumed, and clear the liability. Permissionless — the recipient is
    ///         part of the row's key, so the caller has no discretion.
    ///
    ///         Gated on {refundAfter}: the order's deadline once the row has ever
    ///         activated, the row's own fallback expiry otherwise. Past the deadline the
    ///         settlement itself refuses to fill, so there is no race with an
    ///         in-flight solver.
    ///
    ///         NOT terminal. A late delivery for an already-settled row credits it
    ///         again and is refundable again (or, if the order is still live,
    ///         re-activates it); nothing a stranger can do to a row closes it for the
    ///         beneficiary. The one-shot `settled` flag of earlier versions is what
    ///         let a dust credit plus one `settle` call retire a victim's hash.
    function settle(bytes32 orderHash, address beneficiary, address token)
        external
        nonReentrant
        returns (uint256 refunded)
    {
        bytes32 key = commitKey(orderHash, beneficiary, token);
        if (block.timestamp <= refundAfter(orderHash, beneficiary, token)) revert NotYetRefundable();
        return _settle(orderHash, key);
    }

    /// @notice {settle} for a row whose ORDER can no longer — or can never — be
    ///         filled out of it, whatever the row's bridged fallback expiry says. The
    ///         order is the pre-image of the hash and everything checked here is
    ///         signed, so this needs no trust in the commitment's `expiry` — which is
    ///         exactly the field a copycat credit can inflate.
    ///
    ///         Refunds the row `(hash(order), beneficiary, token)` once ANY of:
    ///           • the order's signed deadline has passed;
    ///           • `token` is not the order's `legsIn[0].token` — {activate} keys on
    ///             that token, so such a row can never fund the order;
    ///           • the order fails {_staticShapeOk} (wrong maker, unsupported shape,
    ///             never-expiring deadline, malformed legs) — {activate} can never
    ///             approve it, so no row under its hash is ever spendable.
    ///         In each case no fill can ever pull from the row, so refunding it to
    ///         the beneficiary its key names is safe at any time (audit 2026-09-30
    ///         BRIDGE-A-2 / X-DIFF-REST-1: before, only the `legsIn[0].token` row of
    ///         an EXPIRING order was reachable, and every other row waited out a
    ///         copycat-inflatable fallback — up to 2106).
    function settleExpired(Order calldata order, address beneficiary, address token)
        external
        nonReentrant
        returns (uint256)
    {
        // `legInToken` is read only once `_staticShapeOk` has validated the blob.
        if (
            _staticShapeOk(order) && DutchAuction.expiry(order) > block.timestamp
                && token == PackedArrays.legInToken(order.legsIn, 0)
        ) revert NotYetRefundable();
        bytes32 orderHash = OrderHash.hash(order);
        return _settle(orderHash, commitKey(orderHash, beneficiary, token));
    }

    function _settle(bytes32 orderHash, bytes32 key) private returns (uint256 refunded) {
        Commit storage k = commits[key];
        if (k.credited == 0) revert BadCommitment();

        // Bring `liability` current with whatever fills already took, then release
        // only what is left. Across sync + settle the whole of `credited` leaves
        // `liability` exactly once.
        uint256 spent = _sync(orderHash, key);
        refunded = k.credited - spent - k.refunded;

        k.refunded += refunded;
        liability[k.token] -= refunded;

        if (k.approved) {
            // Withdraw the standing approval so a late `approveOrder` record cannot
            // be re-used against a re-credited row, and free the hash for a later
            // activation (only reachable while the order is still live).
            k.approved = false;
            delete activeRow[orderHash];
            SETTLEMENT.revokeOrderApproval(orderHash);
        }
        if (refunded != 0) SafeTransferLib.safeTransfer(k.token, k.beneficiary, refunded);
        emit Settled(orderHash, k.beneficiary, spent, refunded);
    }

    /// @notice Refund an ANNOUNCED orphan — a LayerZero delivery whose compose ran
    ///         and emitted {Orphaned} with a known amount (`payload`, `chain`,
    ///         `token`). Immediate, because the amount it may move was published
    ///         by that event and is tracked in `orphaned[token]`.
    ///
    ///         Releases `min(amount, orphaned[token], balance - liability)`. NOT
    ///         `balance - liability`: that figure also contains every delivery
    ///         whose compose has not run yet — still queued with the executor,
    ///         through a source that is still in its {COMPOSE_SOURCE_DELAY}, or
    ///         through one just removed — and each of those credits its row when the
    ///         compose finally lands. Sweeping one made that credit unbacked and
    ///         paid it out of other rows (audit 2026-09-30 BRIDGE-A-1).
    ///
    ///         RECOVERY ORDER. A compose the executor never ran is not lost: the
    ///         endpoint keeps it in `composeQueue` and `endpoint.lzCompose` is
    ///         permissionless, so the fix for a slow delivery is to execute it, not
    ///         to rescue it. Balance that no event announced goes through
    ///         {queueStrayRescue}. Call {sync} on filled-but-unsettled commits first
    ///         — until then their spent portion still counts as owed.
    /// @param amount The most to release; `type(uint256).max` for "all that may".
    function rescue(address token, address to, uint256 amount)
        external
        onlyOwner
        nonReentrant
        returns (uint256 rescued)
    {
        rescued = _min(amount, _min(orphaned[token], _loose(token)));
        if (rescued == 0) revert NothingToRescue();
        orphaned[token] -= rescued;
        SafeTransferLib.safeTransfer(token, to, rescued);
        emit Rescued(token, to, rescued);
    }

    /// @notice Queue the recovery of UNANNOUNCED balance — a donation, an Across
    ///         deposit sent with no message (the SpokePool then never calls the
    ///         handler), a `header` orphan, positive rebase yield. Public for a full
    ///         {COMPOSE_SOURCE_DELAY} before {executeStrayRescue} can move anything,
    ///         the same timelock that guards compose-source additions: a delivery
    ///         whose compose is merely pending must get the chance to land first.
    ///         Re-queuing replaces (and restarts) the pending one.
    function queueStrayRescue(address token, address to, uint256 amount) external onlyOwner {
        uint64 eta = uint64(block.timestamp + COMPOSE_SOURCE_DELAY);
        pendingStrayRescue[token] = PendingStrayRescue({to: to, eta: eta, amount: amount});
        emit StrayRescueQueued(token, to, amount, eta);
    }

    function cancelStrayRescue(address token) external onlyOwner {
        delete pendingStrayRescue[token];
        emit StrayRescueCancelled(token);
    }

    /// @notice Run a queued stray rescue once its delay has passed. The bound is
    ///         evaluated NOW, not at queue time: at most the queued amount, and at
    ///         most `balance - liability - orphaned` — so a compose that landed
    ///         during the delay is liability by now and out of reach, and announced
    ///         orphans stay with {rescue}.
    function executeStrayRescue(address token) external onlyOwner nonReentrant returns (uint256 rescued) {
        PendingStrayRescue memory p = pendingStrayRescue[token];
        if (p.eta == 0 || block.timestamp < p.eta) revert StrayRescueNotReady();
        delete pendingStrayRescue[token];
        rescued = _min(p.amount, strayBalance(token));
        if (rescued == 0) revert NothingToRescue();
        SafeTransferLib.safeTransfer(token, p.to, rescued);
        emit Rescued(token, p.to, rescued);
    }

    /// @dev `balance - liability`, floored at zero.
    function _loose(address token) private view returns (uint256) {
        uint256 bal = SafeTransferLib.balanceOf(token, address(this));
        uint256 owed = liability[token];
        return bal > owed ? bal - owed : 0;
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @notice Reconcile `liability` with what fills have already pulled for the
    ///         row currently funding `orderHash`. Permissionless and idempotent.
    ///
    ///         Settlement moves an approved order's inputs through Permit3 without
    ///         calling this contract, so nothing here observes a fill as it happens.
    ///         Left unreconciled, `liability` keeps counting funds that are long
    ///         gone, which understates {rescuable} — and since there is usually
    ///         SOME filled-but-unsettled row, that would keep the escape hatch
    ///         pinned at zero exactly when it is needed. {settle} calls this, but
    ///         waiting for a deadline is too late for a recovery path.
    /// @return spent Cumulative amount this order has pulled, in `token` units.
    function sync(bytes32 orderHash) public returns (uint256 spent) {
        bytes32 key = activeRow[orderHash];
        if (key == bytes32(0)) return 0;
        return _sync(orderHash, key);
    }

    function _sync(bytes32 orderHash, bytes32 key) private returns (uint256 spent) {
        Commit storage k = commits[key];
        if (!k.approved) return k.spentAccounted;
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
    function refundAfter(bytes32 orderHash, address beneficiary, address token) public view returns (uint64) {
        Commit storage k = commits[commitKey(orderHash, beneficiary, token)];
        // A row that ever activated keeps the order's deadline as its gate for good:
        // past it the order can never fill again, so a late credit into a settled
        // row is refundable at once rather than waiting out its own fallback.
        return k.deadline != 0 ? k.deadline : k.expiry;
    }

    /// @notice What {rescue} would currently release: the announced orphans, capped
    ///         by `balance - liability`. 0 when nothing is releasable.
    function rescuable(address token) external view returns (uint256) {
        return _min(orphaned[token], _loose(token));
    }

    /// @notice Balance no commitment and no announced orphan accounts for —
    ///         `balance - liability - orphaned`, floored at zero. INCLUDES deliveries
    ///         whose compose has not run yet, which is why it is reachable only
    ///         through the delayed {queueStrayRescue} path.
    function strayBalance(address token) public view returns (uint256) {
        uint256 loose = _loose(token);
        uint256 o = orphaned[token];
        return loose > o ? loose - o : 0;
    }

    /// @notice Still-missing funding for a destination order, in `legsIn[0]` units.
    ///         Zero means {activate} will succeed on shape alone. The off-chain
    ///         book uses this to keep a bridged order pending rather than dropping
    ///         it while the bridge is in flight.
    function missingFunding(bytes32 orderHash, address beneficiary, address token, uint256 anchor)
        external
        view
        returns (uint256)
    {
        Commit storage k = commits[commitKey(orderHash, beneficiary, token)];
        uint256 held = k.credited - k.refunded;
        return held >= anchor ? 0 : anchor - held;
    }

    // ──────────────────── Order shape ────────────────────

    /// @dev The inbox only makes a deliberately narrow kind of order, because it
    ///      is a shared escrow rather than a wallet:
    ///
    ///        SELL + exactly one input leg — makes the settlement's `filled`
    ///          counter denominated in the credited token, which is what both the
    ///          funding invariant and {settle}'s accounting rely on.
    ///        a FIXED input leg (`legsIn[0].end == 0`) — see below; without it the
    ///          amount pulled and the amount counted come apart.
    ///        no fill module, no fillTotal — either would decouple the fill delta
    ///          from the leg anchor and break that denomination.
    ///        no items — an item executes under the maker's authority, and this
    ///          maker's authority is a pooled escrow. Nothing it could legitimately
    ///          want to do requires one.
    ///        at least one output, none addressed to address(0) or to this
    ///          contract — `address(0)` means "the maker", which would deliver the
    ///          user's proceeds back into the escrow where only {rescue} could
    ///          reach them.
    ///        a live, FINITE deadline — {settle}'s refund gate keys on it, and a
    ///          never-expiring order (`type(uint48).max`) would leave its rows no
    ///          deadline-based exit at all.
    ///        the inbox as maker — otherwise `approveOrder` refuses it anyway.
    ///
    ///      Leg blobs are bounds-checked with the {PackedArrays} validator rule
    ///      (audit 2026-09-30 X-ASM-1): the element count must be backed by bytes,
    ///      or an accessor would read the blob's unhashed ABI padding / the next
    ///      tail, and one `orderHash` could decode to caller-chosen token, anchor
    ///      and recipients in different calls.
    function _checkShape(Order calldata order) internal view {
        if (!_staticShapeOk(order) || DutchAuction.expiry(order) <= block.timestamp) {
            revert UnsupportedOrderShape();
        }
    }

    /// @dev Every TIME-INDEPENDENT part of the shape {activate} accepts. Returns
    ///      false instead of reverting so {settleExpired} can use it: an order that
    ///      fails it can never be approved here, hence no row under its hash is
    ///      ever spendable and refunding any of them is safe at once.
    function _staticShapeOk(Order calldata order) internal view returns (bool) {
        if (order.maker != address(this)) return false;
        if (order.side() != OrderSide.SELL) return false;
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
        if (order.useNonceInvalidator()) return false;
        if (_validatedCount(order.legsIn, PackedArrays.LEG_IN_STRIDE) != 1) return false;
        // The input leg must be FIXED (`end == 0`). A RISING leg (`end != 0`, the
        // relayer-fee auction) is priced by {Pricing.inputOwed} as
        // `delta * inTick(start, end, bump) / anchor`, which reaches `end` at full
        // decay — while `filled` only ever reaches the ANCHOR, `start`. The two come
        // apart, and both things that depend on them break:
        //   • the funding invariant ({activate} approves at `credited >= start`)
        //     stops bounding the pull, so ONE commitment funded at `start` can draw
        //     `end` out of the pool — i.e. out of OTHER commitments' balances;
        //   • `sync` reads `filled` as "the amount of `token` pulled from here", so
        //     it under-reports the spend and leaves `liability` overstated forever.
        // Commitments are attacker-authorable (anyone can originate a bridge message
        // naming their own order hash) and {activate} is permissionless, so this is
        // reachable, not merely a mis-authoring hazard. With a fixed leg the gas bump
        // never applies either (`inTick` returns `start` when `end == 0`), and soft
        // exclusivity only ever REDUCES the input charge — so this one check restores
        // `pulled <= anchor <= credited` completely.
        if (_legInEnd(order.legsIn, 0) != 0) return false;
        if (_legInStart(order.legsIn, 0) == 0) return false;
        uint256 nOut = _validatedCount(order.legsOut, PackedArrays.LEG_OUT_STRIDE);
        if (nOut == 0) return false; // also the "malformed" sentinel — see below
        // An empty-test only, which is what `countUnchecked` is for: no element of
        // `items` is ever read here.
        if (PackedArrays.countUnchecked(order.items) != 0) return false;
        if (order.fillModule != address(0) || order.fillTotal != 0) return false;
        if (DutchAuction.expiry(order) == type(uint48).max) return false;
        for (uint256 j; j < nOut; j++) {
            address to = _legOutRecipient(order.legsOut, j);
            if (to == address(0) || to == address(this)) return false;
        }
        return true;
    }

    /// @dev {PackedArrays.validateFixed} without the revert: the declared count
    ///      when the blob holds that many `stride`-byte elements, else 0 (which
    ///      every caller here treats as "unsupported" — an inbox order needs at
    ///      least one leg on each side).
    function _validatedCount(bytes calldata b, uint256 stride) private pure returns (uint256 n) {
        n = PackedArrays.countUnchecked(b);
        if (b.length < 1 + n * stride) return 0;
    }

    /// @dev `startAmount` of packed input leg `i` — the leg's other fields are unused
    ///      here, so this keeps the call sites from destructuring a 3-tuple each time.
    function _legInStart(bytes calldata legs, uint256 i) private pure returns (uint256 v) {
        (, v,) = PackedArrays.legIn(legs, i);
    }

    /// @dev `endAmount` of packed input leg `i` — 0 means the leg is FIXED. Read on
    ///      its own by {_checkShape}, which cares about nothing else on the leg.
    function _legInEnd(bytes calldata legs, uint256 i) private pure returns (uint256 v) {
        (,, v) = PackedArrays.legIn(legs, i);
    }

    /// @dev `recipient` of packed output leg `j`.
    function _legOutRecipient(bytes calldata legs, uint256 j) private pure returns (address r) {
        (,,, r) = PackedArrays.legOut(legs, j);
    }
}
