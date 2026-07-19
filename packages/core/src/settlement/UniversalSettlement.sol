// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPermit3} from "../interfaces/IPermit3.sol";
import {IMakerModule} from "../interfaces/IMakerModule.sol";
import {IFillModule} from "../interfaces/IFillModule.sol";
import {ISettlementModule} from "../interfaces/ISettlementModule.sol";
import {IOrderValidator} from "../interfaces/IOrderValidator.sol";
import {SignatureVerification} from "../permit3/SignatureVerification.sol";
import {SafeTransferLib} from "../utils/SafeTransferLib.sol";
import {Permit3TransferLib} from "../utils/Permit3TransferLib.sol";

// Re-exported so downstream files can keep importing the order types from here.
import {Order, Item, ItemOp, Validator, OrderSide, CurvePoint} from "./SettlementStructs.sol";
import {OrderHash} from "./OrderHash.sol";
import {DutchAuction} from "./DutchAuction.sol";
import {NonceManager} from "./NonceManager.sol";
import {SolverCallbackExecutor} from "./SolverCallbackExecutor.sol";

/// @title UniversalSettlement
/// @notice Signed limit-order settler with partial fills, optional dutch
///         decay, and pro-rata module-dispatched lending legs. All token
///         and taker authority flows through Permit3 — there is no module
///         whitelist, no admin role. A module's authority comes entirely
///         from the maker's signature + their per-module Permit3 allowances.
///
///  Structure: order types live in {SettlementStructs}, EIP-712 hashing in
///  {OrderHash}, auction pricing in {DutchAuction}, and cancellation in
///  {NonceManager} (inherited). This contract owns the fill flow, the
///  validator/invariant gates, and settlement accounting.
contract UniversalSettlement is NonceManager {
    using OrderHash for Order;
    using DutchAuction for Order;

    // ──────────────────── Storage ────────────────────

    IPermit3 public immutable PERMIT3;

    /// @dev EIP-712 domain, cached at deploy but recomputed if `block.chainid`
    ///      changes (chain fork) so an order signature can never be replayed
    ///      against the wrong domain after a split. Mirrors Permit3's EIP712
    ///      base; exposed via the `DOMAIN_SEPARATOR()` view below.
    bytes32 private immutable _CACHED_DOMAIN_SEPARATOR;
    uint256 private immutable _CACHED_CHAIN_ID;
    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _HASHED_NAME = keccak256("UniversalSettlement");
    bytes32 private constant _HASHED_VERSION = keccak256("1");

    /// @notice Allowance-less trampoline for `fillWithCallback` (see the contract
    ///         for the security rationale). Deployed here so it is dedicated to
    ///         this Settlement and can never be an approved Permit3 spender.
    SolverCallbackExecutor public immutable EXECUTOR;

    /// @notice orderHash → cumulative filled amount, in the order's ANCHOR units
    ///         (`tokenIn[0]` for SELL, `tokenOut[0]` for BUY).
    mapping(bytes32 => uint256) public filled;

    /// @notice maker → orderHash → on-chain order authorization. The signature-less
    ///         alternative to signing: a maker that cannot produce a verifiable
    ///         signature at all — a classic multisig with no EIP-1271
    ///         `isValidSignature`, for which neither the ECDSA nor the 1271 branch
    ///         of the verifier can ever succeed — instead records intent on-chain via
    ///         {approveOrder}. Fillers then pass an EMPTY `sig` and the fill
    ///         authorizes against this mapping. Funding still flows through the
    ///         maker's standing Permit3 allowances, and the fill is still gated by
    ///         the shared nonce/deadline/validator machinery — this only replaces the
    ///         signature check, nothing else.
    mapping(address => mapping(bytes32 => bool)) public orderApproved;

    uint256 private _locked = 1;

    // ──────────────────── Events ────────────────────

    /// @notice A fill occurred. Intentionally data-less: every amount is
    ///         recoverable from the ERC20 `Transfer` / protocol events in the same
    ///         tx (`tokenOut` legs are solver→maker transfers; the anchor
    ///         `fillAmountIn` is the `tokenIn[0]`/`tokenOut[0]` leg), and on-chain
    ///         callers get the per-leg outputs from the function return value. The
    ///         event exists only to bind those transfers to an `orderHash` (which
    ///         Transfer events don't carry) and to make fills filterable by
    ///         maker/solver — so it emits just those three topics, no log data.
    event OrderFilled(bytes32 indexed orderHash, address indexed maker, address indexed solver);

    /// @notice A maker authorized an order on-chain via {approveOrder} — the
    ///         signature-less order path — or withdrew it via {revokeOrderApproval}.
    event OrderApproved(address indexed maker, bytes32 indexed orderHash);
    event OrderApprovalRevoked(address indexed maker, bytes32 indexed orderHash);

    // ──────────────────── Errors ────────────────────

    error OrderExpired();
    error NonceCancelled();
    error ZeroFill();
    error OverFill();
    error Reentrancy();
    error ValidationFailed(uint256 index);
    error InvariantFailed(uint256 index);
    error NotExclusiveFiller();
    error FillTooSmall();
    error OnlySelf();
    error BatchFillIncomplete(uint256 index);
    /// @dev `batchFill`'s `takerDatas` array is not aligned 1:1 with `orders`.
    error LengthMismatch();
    error ReverseModeRequiresNoItems();
    /// @dev `batchSettle` was given an order carrying MAKE/TAKE/SETTLE items — the
    ///      netted flow is item-free (same rationale as `PostInputs`).
    error BatchSettleNoItems();
    /// @dev A netted `batchSettle` left Settlement holding LESS of `token` than it
    ///      did before the batch — the solver under-covered the residual, so the
    ///      batch would have drawn down a pre-existing/donated balance. Reverts.
    error BatchNotWhole(address token);
    /// @dev A `batchSettleItems` order's item-funded input leg (not in the solver's
    ///      pull-set) produced FEWER proceeds than the leg owes — the item did not
    ///      fund the obligation and there is no self-funded pull to make it up.
    error BatchItemsInputUnfunded();
    /// @dev `batchSettleItems`' `sequence` is not a permutation of `[0, n)` — it has
    ///      the wrong length, an out-of-range index, or a duplicate.
    error BatchItemsBadSequence();
    /// @dev A `batchSettleItems` order carries a SETTLE item. SETTLE routes the
    ///      maker's asset to the filler, not a pool counterparty — out of scope for
    ///      the netted item flow (a shared-pool SETTLE needs its own design).
    error BatchItemsSettleUnsupported();
    /// @dev A `batchSettleItems` order repeats an input token across two `tokenIn`
    ///      legs. The pooled input settlement attributes proceeds per token via a
    ///      balance delta; two same-token legs would mis-account. Use distinct
    ///      tokens (leverage/repay/migrate orders already do).
    error BatchItemsDuplicateInput();
    /// @dev An empty `sig` was supplied for a fill, but the maker has no matching
    ///      on-chain {approveOrder} record for this order.
    error OrderNotApproved();
    /// @dev {approveOrder} called with an order whose `maker` is not the caller.
    error NotOrderMaker();

    /// @notice Where the solver callback runs relative to settlement, chosen by
    ///         the filler in `fillWithCallback`.
    enum CallbackMode {
        PreDelivery, // callback → deliver outputs → items → pay inputs (works for any order)
        PostInputs // pay inputs → callback → deliver outputs (item-free only; JIT-from-proceeds)
    }

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(address permit3) {
        PERMIT3 = IPermit3(permit3);
        EXECUTOR = new SolverCallbackExecutor();
        _CACHED_CHAIN_ID = block.chainid;
        _CACHED_DOMAIN_SEPARATOR = _buildDomainSeparator();
    }

    /// @notice EIP-712 domain separator for the current chain. Returns the cached
    ///         value unless `block.chainid` has changed since deployment (fork),
    ///         in which case it is rebuilt so signatures stay domain-bound.
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return block.chainid == _CACHED_CHAIN_ID ? _CACHED_DOMAIN_SEPARATOR : _buildDomainSeparator();
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(abi.encode(_DOMAIN_TYPEHASH, _HASHED_NAME, _HASHED_VERSION, block.chainid, address(this)));
    }

    // ──────────────────── Fill ────────────────────

    /// @notice Fill (up to) `fillAmount` of an order — in `tokenIn[0]` units for a
    ///         SELL, `tokenOut[0]` units for a BUY. Partial fills allowed.
    ///         Lending items are executed pro-rata for this fill's slice.
    /// @dev    Thin wrapper over the {takerData} overload with an empty blob, so
    ///         existing 3-arg call sites (solvers, SDK) keep working unchanged.
    function fill(Order calldata order, bytes calldata sig, uint256 fillAmount)
        external
        nonReentrant
        returns (uint256[] memory fillAmountsOut)
    {
        bytes32 orderHash = order.hash();
        _verifySignature(orderHash, sig, order.maker);
        return _fillCore(order, orderHash, fillAmount, msg.sender, address(0), "", CallbackMode.PreDelivery, "");
    }

    /// @notice Fill overload that carries a filler-supplied `takerData` blob into
    ///         the order's validators and invariants.
    /// @param  takerData  Adversarial, UNSIGNED, shared-per-fill data (see
    ///         {IOrderValidator}). It reaches every validator and invariant of this
    ///         fill but can only be *consumed by a validator* — a read-only gate —
    ///         so it can never alter the maker's signed outcome (amounts, tokens,
    ///         recipients). A validator that reads it MUST independently verify it
    ///         (e.g. recover a maker-trusted attester over a digest bound to
    ///         `msg.sender`). Lets a maker gate a fill on a proof only the filler
    ///         can produce (off-chain attestation, oracle update, ZK proof).
    function fill(Order calldata order, bytes calldata sig, uint256 fillAmount, bytes calldata takerData)
        external
        nonReentrant
        returns (uint256[] memory fillAmountsOut)
    {
        bytes32 orderHash = order.hash();
        _verifySignature(orderHash, sig, order.maker);
        return _fillCore(order, orderHash, fillAmount, msg.sender, address(0), "", CallbackMode.PreDelivery, takerData);
    }

    /// @notice Fill with a solver-supplied callback that runs just before output
    ///         delivery — the taker-interaction analogue. Lets a zero-inventory
    ///         solver source `tokenOut` just-in-time (flash / swap / route)
    ///         without a bespoke solver contract: the callback runs while the
    ///         fill's reentrancy guard is held, then Settlement pulls the outputs
    ///         the solver just acquired.
    ///
    ///  Safety: the `(callbackTarget, callbackData)` call is made by
    ///  {SolverCallbackExecutor} — an allowance-less trampoline — NOT by
    ///  Settlement, so it cannot abuse Settlement's Permit3 spender status to
    ///  move a maker's funds (e.g. `callbackTarget = PERMIT3` gains nothing). The
    ///  callback is filler-supplied and NOT part of the maker's signed order, so
    ///  it can only act with its own authority; the maker's funds stay gated by
    ///  their signature + Permit3 allowances exactly as in a plain `fill`.
    ///  Reentrancy into any fill is blocked by `nonReentrant`.
    ///
    ///  `mode` (filler-chosen) picks where the callback runs:
    ///    • PreDelivery — callback → deliver outputs → items → pay inputs. Works
    ///      for any order; the solver must source `tokenOut` from something that
    ///      does NOT depend on this fill's proceeds (flash / credit / inventory).
    ///    • PostInputs  — pay inputs → callback → deliver outputs. Item-free
    ///      orders only. The solver is paid its `tokenIn` FIRST, converts it in
    ///      the callback, then delivers `tokenOut` — a genuinely zero-inventory,
    ///      zero-flash plain-swap fill (the Fusion `takerInteraction` ordering).
    ///
    ///  The `mode` flag only permutes solver-side transfer order; it cannot change
    ///  the maker's signed outcome. In both modes the tx can only succeed if the
    ///  maker pays exactly the signed input and receives the signed output (a
    ///  mandatory, reverting delivery) and every invariant passes — so it is safe
    ///  for the filler, not the maker, to choose it.
    function fillWithCallback(
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmount,
        address callbackTarget,
        bytes calldata callbackData,
        CallbackMode mode
    ) external nonReentrant returns (uint256[] memory fillAmountsOut) {
        bytes32 orderHash = order.hash();
        _verifySignature(orderHash, sig, order.maker);
        return _fillCore(order, orderHash, fillAmount, msg.sender, callbackTarget, callbackData, mode, "");
    }

    /// @notice {fillWithCallback} overload carrying a filler-supplied `takerData`
    ///         blob into the order's validators and invariants. See {fill}'s
    ///         takerData overload for the adversarial/validator-verified rule.
    function fillWithCallback(
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmount,
        address callbackTarget,
        bytes calldata callbackData,
        CallbackMode mode,
        bytes calldata takerData
    ) external nonReentrant returns (uint256[] memory fillAmountsOut) {
        bytes32 orderHash = order.hash();
        _verifySignature(orderHash, sig, order.maker);
        return _fillCore(order, orderHash, fillAmount, msg.sender, callbackTarget, callbackData, mode, takerData);
    }

    /// @notice Single-signature fill: the maker's `sig` is over a Permit3
    ///         `PermitBatch` bound to this order's hash as a witness, so
    ///         one signature simultaneously authorises the order *and*
    ///         every Permit3 token + taker allowance the fill needs.
    ///         No standing approvals required.
    function fillWithPermit(
        Order calldata order,
        IPermit3.PermitBatch calldata batch,
        bytes calldata sig,
        uint256 fillAmount
    ) external nonReentrant returns (uint256[] memory fillAmountsOut) {
        bytes32 orderHash = order.hash();
        // Permit3 verifies the sig against (PermitBatchWitness + orderHash) and
        // applies all allowances. The order itself doesn't need a separate sig
        // — the witness binding makes the permit endorse this exact order.
        PERMIT3.permitBatchWithWitness(order.maker, batch, orderHash, OrderHash.WITNESS_TYPESTRING, sig);
        return _fillCore(order, orderHash, fillAmount, msg.sender, address(0), "", CallbackMode.PreDelivery, "");
    }

    /// @notice {fillWithPermit} overload carrying a filler-supplied `takerData`
    ///         blob into the order's validators and invariants. See {fill}'s
    ///         takerData overload for the adversarial/validator-verified rule.
    function fillWithPermit(
        Order calldata order,
        IPermit3.PermitBatch calldata batch,
        bytes calldata sig,
        uint256 fillAmount,
        bytes calldata takerData
    ) external nonReentrant returns (uint256[] memory fillAmountsOut) {
        bytes32 orderHash = order.hash();
        PERMIT3.permitBatchWithWitness(order.maker, batch, orderHash, OrderHash.WITNESS_TYPESTRING, sig);
        return _fillCore(order, orderHash, fillAmount, msg.sender, address(0), "", CallbackMode.PreDelivery, takerData);
    }

    /// @notice Fill a batch of orders in one transaction. Each order is attempted
    ///         independently; an order that reverts (expired, cancelled,
    ///         under-funded, over-fill, …) is SKIPPED and its `success[i]` is
    ///         false — unless `revertIfIncomplete`, in which case the first
    ///         failure reverts the whole batch. Mirrors 0x's `batchFill*` with
    ///         the `revertIfIncomplete` flag.
    /// @dev    Each fill runs via a `this.fillSelf` self-call so a revert unwinds
    ///         only that order, not the batch. The real filler (`msg.sender`) is
    ///         threaded through, so a skipped order costs the caller nothing and a
    ///         filled one settles against the caller exactly as a direct `fill`.
    function batchFill(
        Order[] calldata orders,
        bytes[] calldata sigs,
        uint256[] calldata fillAmounts,
        bool revertIfIncomplete
    ) external nonReentrant returns (uint256[][] memory fillAmountsOut, bool[] memory success) {
        uint256 n = orders.length;
        fillAmountsOut = new uint256[][](n);
        success = new bool[](n);
        address filler = msg.sender;
        for (uint256 i; i < n;) {
            // Empty takerData — the no-taker-blob path.
            try this.fillSelf(orders[i], sigs[i], fillAmounts[i], filler, "") returns (uint256[] memory outs) {
                fillAmountsOut[i] = outs;
                success[i] = true;
            } catch {
                if (revertIfIncomplete) revert BatchFillIncomplete(i);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice {batchFill} overload carrying a per-order filler-supplied `takerData`
    ///         blob, aligned 1:1 with `orders` (`takerDatas[i]` threads into order
    ///         `i`'s validators + invariants). See {fill}'s takerData overload for
    ///         the adversarial/validator-verified rule.
    /// @dev    Reverts {LengthMismatch} if `takerDatas.length != orders.length`.
    ///         The loop is inlined (not shared with the 4-arg overload) to stay
    ///         under the EVM stack limit without via-IR.
    function batchFill(
        Order[] calldata orders,
        bytes[] calldata sigs,
        uint256[] calldata fillAmounts,
        bool revertIfIncomplete,
        bytes[] calldata takerDatas
    ) external nonReentrant returns (uint256[][] memory fillAmountsOut, bool[] memory success) {
        uint256 n = orders.length;
        if (takerDatas.length != n) revert LengthMismatch();
        fillAmountsOut = new uint256[][](n);
        success = new bool[](n);
        address filler = msg.sender;
        for (uint256 i; i < n;) {
            try this.fillSelf(orders[i], sigs[i], fillAmounts[i], filler, takerDatas[i]) returns (uint256[] memory outs)
            {
                fillAmountsOut[i] = outs;
                success[i] = true;
            } catch {
                if (revertIfIncomplete) revert BatchFillIncomplete(i);
            }
            unchecked {
                ++i;
            }
        }
    }

    // ──────────────────── Batch settle (coincidence of wants) ────────────────────

    /// @notice Settle N orders as ONE netted batch — the coincidence-of-wants
    ///         (CoW) path. Every order's inputs are pooled into Settlement FIRST,
    ///         each maker's net SURPLUS is handed to the solver, a single solver
    ///         interaction converts that surplus into the net deficit, then every
    ///         output is delivered from the pool. Two mirror orders (`sell
    ///         WETH→USDC` and `sell USDC→WETH`) clear against each other with NO AMM
    ///         touched and, thanks to the surplus pre-send, ZERO solver capital even
    ///         when the batch is IMBALANCED (the solver swaps the surplus it is
    ///         handed into the deficit it must return — never fronting inventory).
    ///
    ///         This is a DEDICATED method: the single-order hot path is untouched,
    ///         so ordinary fills pay nothing for it. Unlike {batchFill} (which runs
    ///         each order independently and forces the solver to front the transient
    ///         peak), the pooled flow needs no solver inventory.
    ///
    ///         Flow (see `docs/batch-settle.md`):
    ///           1. per order: verify + open (`filled` written here) + pull inputs
    ///              → Settlement; then compute (not yet deliver) every output amount;
    ///           2. per token: PRE-SEND the batch's net surplus (pooled − owed, when
    ///              positive) to the solver — bounded to THIS batch's inputs, never a
    ///              donated balance;
    ///           3. one `interactionTarget` call via the allowance-less EXECUTOR —
    ///              the solver deposits the net-deficit token into Settlement (funded
    ///              by swapping the surplus it was just handed);
    ///           4. per order: deliver outputs (Settlement → maker/recipient) +
    ///              run invariants;
    ///           5. per touched token: require the balance did not drop below its
    ///              pre-batch snapshot (`BatchNotWhole` else) and sweep any residual.
    ///
    /// @dev    Item-free orders only ({BatchSettleNoItems}). Each maker is charged
    ///         and paid its OWN signed auction curve — identical to a single fill;
    ///         only the counterparty (the pool, not one solver) differs. This
    ///         overload passes an empty `takerData` to validators/invariants/fill
    ///         module; use the {batchSettle} `takerDatas` overload to thread a
    ///         per-order blob. `nonReentrant` spans the whole batch, so neither the
    ///         pre-send nor the interaction can re-enter, and every `filled` write
    ///         precedes both.
    /// @param  interactionTarget Optional (`address(0)` to skip) solver contract
    ///         called once between pre-send and deliver; returns the residual.
    /// @return outs `outs[i][j]` = order `i`'s delivered amount on output leg `j`.
    function batchSettle(
        Order[] calldata orders,
        bytes[] calldata sigs,
        uint256[] calldata fillAmounts,
        address interactionTarget,
        bytes calldata interactionData
    ) external nonReentrant returns (uint256[][] memory outs) {
        if (sigs.length != orders.length || fillAmounts.length != orders.length) revert LengthMismatch();
        return _batchSettle(orders, sigs, fillAmounts, new bytes[](0), interactionTarget, interactionData);
    }

    /// @notice {batchSettle} carrying a per-order filler-supplied `takerData` blob,
    ///         aligned 1:1 with `orders` — `takerDatas[i]` threads into order `i`'s
    ///         validators, invariants, and (for a fill-module order) `resolveFill`.
    ///         Same adversarial/validator-verified rule as {fill}'s takerData
    ///         overload: the blob is unsigned, so a validator must independently
    ///         verify anything it reads from it.
    /// @dev    Reverts {LengthMismatch} unless every array is `orders.length` long.
    function batchSettle(
        Order[] calldata orders,
        bytes[] calldata sigs,
        uint256[] calldata fillAmounts,
        bytes[] calldata takerDatas,
        address interactionTarget,
        bytes calldata interactionData
    ) external nonReentrant returns (uint256[][] memory outs) {
        uint256 n = orders.length;
        if (sigs.length != n || fillAmounts.length != n || takerDatas.length != n) revert LengthMismatch();
        return _batchSettle(orders, sigs, fillAmounts, takerDatas, interactionTarget, interactionData);
    }

    /// @dev Batch working set, bundled so `_batchSettle` holds ONE memory pointer
    ///      across the phases instead of four named locals (keeps the netted flow
    ///      under the EVM stack limit without via-IR).
    struct BatchState {
        address[] tokens; //     the touched-token universe (deduped)
        uint256[] beforeBal; //  per-token pre-batch balance snapshot
        FillCtx[] ctxs; //       per-order fill context (filled bookkeeping)
        uint256[][] outs; //     per-order per-leg output amounts (compute → deliver)
    }

    /// @dev Shared netted-settle implementation. `takerDatas` is either empty (the
    ///      no-blob overload) or `orders.length` long; `_td` picks per index. Runs
    ///      under the caller's `nonReentrant` lock (both public entry points hold
    ///      it). Phases are separate frames — the netted flow holds far more live
    ///      memory than the single-order path and is not stack-golfed for via-IR.
    function _batchSettle(
        Order[] calldata orders,
        bytes[] calldata sigs,
        uint256[] calldata fillAmounts,
        bytes[] memory takerDatas,
        address interactionTarget,
        bytes calldata interactionData
    ) internal returns (uint256[][] memory) {
        BatchState memory st;
        // Derive the touched-token universe on-chain (never trust the solver — the
        // pre-send bound and the whole-ness check both hinge on it) and snapshot.
        st.tokens = _collectTokens(orders);
        st.beforeBal = _snapshotBalances(st.tokens);

        // Phase 1: open every order (writes `filled`) + pool its inputs; then
        // compute — but do NOT yet deliver — every output amount, so the net
        // surplus per token is known before the interaction.
        st.ctxs = _batchOpenAll(orders, sigs, fillAmounts, takerDatas);
        st.outs = _batchComputeAllOutputs(orders, st.ctxs);

        // Phase 2: pre-send each token's net surplus to the solver (bounded to this
        // batch's own pooled inputs — donated balances stay put).
        _presendSurplus(st.tokens, st.beforeBal, orders, st.outs);

        // Phase 3: single residual interaction. Allowance-less EXECUTOR — the solver
        // returns the net-deficit token (funded by the surplus it was just handed)
        // but can never move the pool.
        if (interactionTarget != address(0)) EXECUTOR.execute(interactionTarget, interactionData);

        // Phase 4: deliver every order's outputs from the pool + run invariants.
        _batchDeliverAll(orders, st.ctxs, st.outs, takerDatas);

        // Phase 5: enforce the batch left Settlement whole and sweep any residual.
        _sweepSurplus(st.tokens, st.beforeBal);
        return st.outs;
    }

    /// @dev `takerDatas[i]` or an empty blob when the no-taker overload is used.
    function _td(bytes[] memory takerDatas, uint256 i) private pure returns (bytes memory) {
        return takerDatas.length == 0 ? bytes("") : takerDatas[i];
    }

    /// @dev Phase 1: open + pool inputs for every order. Own frame (stack).
    function _batchOpenAll(
        Order[] calldata orders,
        bytes[] calldata sigs,
        uint256[] calldata fillAmounts,
        bytes[] memory takerDatas
    ) internal returns (FillCtx[] memory ctxs) {
        uint256 n = orders.length;
        ctxs = new FillCtx[](n);
        address solver = msg.sender;
        for (uint256 i; i < n;) {
            ctxs[i] = _batchOpenAndPull(orders[i], sigs[i], fillAmounts[i], solver, _td(takerDatas, i));
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Phase 1 (compute half): every order's per-leg output amounts, with NO
    ///      transfer, so the pre-send can net surplus vs. owed before delivering.
    ///      `view` — same math the delivery half replays exactly (same `ctx`, same
    ///      block), so compute and deliver never diverge.
    function _batchComputeAllOutputs(Order[] calldata orders, FillCtx[] memory ctxs)
        internal
        view
        returns (uint256[][] memory amounts)
    {
        uint256 n = orders.length;
        amounts = new uint256[][](n);
        for (uint256 i; i < n;) {
            amounts[i] = _batchComputeOutputs(orders[i], ctxs[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Phase 2: hand each token's net surplus (`pooled − owed`, when positive)
    ///      to the solver so it can convert it into the deficit in the interaction —
    ///      the zero-capital unlock for imbalanced batches. `pooled` is measured as
    ///      the balance delta since the pre-batch snapshot, so the pre-send is
    ///      bounded to THIS batch's inputs and can never leak a donated balance.
    function _presendSurplus(
        address[] memory tokens,
        uint256[] memory beforeBal,
        Order[] calldata orders,
        uint256[][] memory amounts
    ) internal {
        address solver = msg.sender;
        for (uint256 k; k < tokens.length;) {
            address token = tokens[k];
            uint256 owed = _owedForToken(orders, amounts, token);
            uint256 pooled = SafeTransferLib.balanceOf(token, address(this)) - beforeBal[k]; // this batch only
            if (pooled > owed) {
                unchecked {
                    SafeTransferLib.safeTransfer(token, solver, pooled - owed);
                }
            }
            unchecked {
                ++k;
            }
        }
    }

    /// @dev Sum of every order's output amount denominated in `token` — the pool's
    ///      total obligation in that token, across makers and fee legs alike.
    function _owedForToken(Order[] calldata orders, uint256[][] memory amounts, address token)
        internal
        pure
        returns (uint256 owed)
    {
        for (uint256 i; i < orders.length;) {
            address[] calldata tOut = orders[i].tokenOut;
            for (uint256 j; j < tOut.length;) {
                if (tOut[j] == token) owed += amounts[i][j];
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Phase 4: deliver the pre-computed amounts from the pool + invariants +
    ///      event for every order. Own frame.
    function _batchDeliverAll(
        Order[] calldata orders,
        FillCtx[] memory ctxs,
        uint256[][] memory amounts,
        bytes[] memory takerDatas
    ) internal {
        uint256 n = orders.length;
        address solver = msg.sender;
        for (uint256 i; i < n;) {
            _batchDeliverStored(orders[i], amounts[i]);
            _runInvariants(orders[i], solver, _td(takerDatas, i));
            emit OrderFilled(ctxs[i].orderHash, orders[i].maker, solver);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Snapshot Settlement's balance of each token in a MEMORY list (the batch
    ///      token universe). Sibling of `_snapshotInputs`, which takes calldata legs.
    function _snapshotBalances(address[] memory tokens) internal view returns (uint256[] memory bals) {
        bals = new uint256[](tokens.length);
        for (uint256 k; k < tokens.length;) {
            bals[k] = SafeTransferLib.balanceOf(tokens[k], address(this));
            unchecked {
                ++k;
            }
        }
    }

    /// @dev Phase 5: require the batch left Settlement no worse off on any touched
    ///      token ({BatchNotWhole} else) and sweep any residual — the solver's
    ///      compensation, ~0 after a clean pre-send + interaction — to the caller.
    ///      Never touches `beforeBal` (pre-existing / donated balances stay put).
    function _sweepSurplus(address[] memory tokens, uint256[] memory beforeBal) internal {
        address solver = msg.sender;
        for (uint256 k; k < tokens.length;) {
            uint256 nowBal = SafeTransferLib.balanceOf(tokens[k], address(this));
            if (nowBal < beforeBal[k]) revert BatchNotWhole(tokens[k]);
            unchecked {
                uint256 surplus = nowBal - beforeBal[k]; // nowBal >= beforeBal[k]
                if (surplus != 0) SafeTransferLib.safeTransfer(tokens[k], solver, surplus);
                ++k;
            }
        }
    }

    /// @dev Phase-1 body for one order: the full `_fillCore` gate set (item-free
    ///      guard, deadline, signature/approval, exclusivity, nonce, validators),
    ///      then `_openFill` (writes `filled`) and pool this order's inputs into
    ///      Settlement. `takerData` threads into the validators and the fill module.
    ///      Split out so the batch loop stays under the stack limit.
    function _batchOpenAndPull(
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmount,
        address solver,
        bytes memory takerData
    ) internal returns (FillCtx memory ctx) {
        if (order.items.length != 0) revert BatchSettleNoItems();
        if (fillAmount == 0) revert ZeroFill();
        if (block.timestamp > order.deadline) revert OrderExpired();
        bytes32 orderHash = order.hash();
        _verifySignature(orderHash, sig, order.maker);
        uint256 overrideBps = _exclusivity(order, solver);
        if (_isNonceCancelled(order.maker, order.nonce)) revert NonceCancelled();
        _runValidators(order, solver, takerData);
        ctx = _openFill(order, orderHash, fillAmount, overrideBps, solver, takerData);
        _batchPullInputs(order, ctx);
    }

    /// @dev Pool this fill's input legs `maker → Settlement`. The owed-per-leg math
    ///      is IDENTICAL to `_payInputsToSolver` (fixed + auctioned legs, soft
    ///      exclusivity) minus the TAKE-proceeds branch — batch orders are
    ///      item-free, so proceeds are zero by construction. The maker is charged
    ///      exactly what a single fill would charge; only the destination differs.
    function _batchPullInputs(Order calldata order, FillCtx memory ctx) internal {
        address maker = order.maker;
        uint256 anchor = ctx.anchor;
        bool buy = order.side == OrderSide.BUY;
        uint256 fillAmount = ctx.newFilled - ctx.prevFilled;
        uint256 bump = type(uint256).max;
        for (uint256 i; i < order.tokenIn.length;) {
            uint256 owed;
            if (buy || order.startAmountIn[i] != order.endAmountIn[i]) {
                if (order.startAmountIn[i] != order.endAmountIn[i] && bump == type(uint256).max) {
                    bump = order.bumpBps();
                }
                owed = (fillAmount * order.amountInAt(i, bump)) / anchor;
                if (ctx.overrideBps != 0) owed = (owed * (10_000 - ctx.overrideBps)) / 10_000;
            } else {
                uint256 amt = order.startAmountIn[i];
                owed = ctx.fullFill ? amt : (amt * ctx.newFilled) / anchor - (amt * ctx.prevFilled) / anchor;
            }
            if (owed != 0) {
                Permit3TransferLib.transferFromWithFallback(PERMIT3, order.tokenIn[i], maker, address(this), owed);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Compute this fill's per-leg output amounts WITHOUT transferring — the
    ///      pre-send needs the totals before delivery. The per-leg math — BUY
    ///      fixed-output slices, SELL auction-priced, soft exclusivity on maker legs
    ///      only — is IDENTICAL to `_deliverOutputs`; the returned amount is final
    ///      (post-override), so `_batchDeliverStored` just moves it.
    function _batchComputeOutputs(Order calldata order, FillCtx memory ctx) internal view returns (uint256[] memory outs) {
        uint256 n = order.tokenOut.length;
        outs = new uint256[](n);
        bool buy = order.side == OrderSide.BUY;
        uint256 anchor = ctx.anchor;
        uint256 bump = type(uint256).max;
        for (uint256 j; j < n;) {
            uint256 amt;
            if (buy) {
                uint256 fixedOut = order.startAmountOut[j];
                amt = ctx.fullFill
                    ? fixedOut
                    : _ceilDiv(fixedOut * ctx.newFilled, anchor) - _ceilDiv(fixedOut * ctx.prevFilled, anchor);
            } else {
                if (order.startAmountOut[j] != order.endAmountOut[j] && bump == type(uint256).max) {
                    bump = order.bumpBps();
                }
                amt = _ceilDiv((ctx.newFilled - ctx.prevFilled) * order.amountOutAt(j, bump), anchor);
                // Soft-exclusivity override applies only to the maker's own SELL legs
                // (mirrors `_deliverOutputs`); a fee leg to a third party is untouched.
                if (amt != 0 && ctx.overrideBps != 0) {
                    address to = order.recipientOut[j];
                    if (to == address(0) || to == order.maker) {
                        amt = _ceilDiv(amt * (10_000 + ctx.overrideBps), 10_000);
                    }
                }
            }
            outs[j] = amt;
            unchecked {
                ++j;
            }
        }
    }

    /// @dev Deliver the pre-computed output amounts `Settlement → recipient` via
    ///      plain `transfer` (the pool, not the solver, is the source). A short pool
    ///      reverts here (atomic). `recipientOut[j] == 0` ⇒ the maker.
    function _batchDeliverStored(Order calldata order, uint256[] memory amts) internal {
        for (uint256 j; j < amts.length;) {
            uint256 amt = amts[j];
            if (amt != 0) {
                address to = order.recipientOut[j];
                bool makerLeg = to == address(0) || to == order.maker;
                SafeTransferLib.safeTransfer(order.tokenOut[j], makerLeg ? order.maker : to, amt);
            }
            unchecked {
                ++j;
            }
        }
    }

    /// @dev The de-duplicated union of every order's `tokenIn`/`tokenOut`. Derived
    ///      on-chain (not solver-supplied) so the `BatchNotWhole` guard covers every
    ///      token the batch could move. O(legs²) — batches are small, and this runs
    ///      only on the deliberate CoW path, never the single-order hot path.
    function _collectTokens(Order[] calldata orders) internal pure returns (address[] memory tokens) {
        uint256 maxLen;
        for (uint256 i; i < orders.length;) {
            maxLen += orders[i].tokenIn.length + orders[i].tokenOut.length;
            unchecked {
                ++i;
            }
        }
        address[] memory buf = new address[](maxLen);
        uint256 count;
        for (uint256 i; i < orders.length;) {
            count = _appendUnique(buf, count, orders[i].tokenIn);
            count = _appendUnique(buf, count, orders[i].tokenOut);
            unchecked {
                ++i;
            }
        }
        tokens = new address[](count);
        for (uint256 k; k < count;) {
            tokens[k] = buf[k];
            unchecked {
                ++k;
            }
        }
    }

    /// @dev Append each of `toks` to `buf[0..count)` if not already present; return
    ///      the new count. Linear scan — the token universe of one batch is tiny.
    function _appendUnique(address[] memory buf, uint256 count, address[] calldata toks)
        private
        pure
        returns (uint256)
    {
        for (uint256 i; i < toks.length;) {
            address t = toks[i];
            bool seen;
            for (uint256 k; k < count;) {
                if (buf[k] == t) {
                    seen = true;
                    break;
                }
                unchecked {
                    ++k;
                }
            }
            if (!seen) {
                buf[count] = t;
                unchecked {
                    ++count;
                }
            }
            unchecked {
                ++i;
            }
        }
        return count;
    }

    // ─────────────── Item-aware netted settle (leverage ⋈ spot) ───────────────

    /// @notice The item-aware generalization of {batchSettle}: settle N orders as
    ///         one netted batch WHERE ORDERS MAY CARRY MAKE/TAKE ITEMS. This lets a
    ///         spot order's pooled liquidity fund a leverage order's conversion with
    ///         NO solver inventory, NO callback, and — in the match case — NO flash:
    ///         the spot order's input is delivered as the leverage order's collateral
    ///         and deposited BEFORE the borrow, bootstrapping it; the borrow proceeds
    ///         then pay the spot order out of the pool.
    ///
    ///         Because deliveries interleave with item execution (an order's output
    ///         is delivered, then its MAKE deposits it, then its TAKE borrows the
    ///         funding token into the pool), there is no "pull all → deliver all"
    ///         order. The solver supplies two hints the contract executes verbatim:
    ///
    ///           • `pullMask[i]` — bit `j` set ⇒ pull order `i`'s input leg `j` into
    ///             the pool up front (its SELF-FUNDED seeds: spot sells, equity
    ///             margin). Legs left unset are ITEM-FUNDED — satisfied by that
    ///             order's own TAKE proceeds during execution.
    ///           • `sequence` — a permutation of `[0, n)`: the order in which to run
    ///             each order's deliver-outputs + items + settle-inputs.
    ///
    ///         Neither hint can make an UNSAFE settlement succeed (see below); a bad
    ///         hint only reverts. Scheduling is thus the solver's job (liveness); the
    ///         contract owns correctness (safety):
    ///           - every output leg is a transfer that fully succeeds or reverts (no
    ///             maker under-delivered);
    ///           - each maker is charged its OWN signed slice, unchanged by netting;
    ///           - items run under the maker's signature + the maker's own Permit3
    ///             allowances (`_executeItems` is byte-identical to the single-order
    ///             path), `filled` written before any of it;
    ///           - the same pool whole-ness guard as {batchSettle}: every touched
    ///             token must end ≥ its pre-batch balance (`BatchNotWhole` else), so
    ///             a donated balance is never consumed and the solver can never
    ///             extract past the batch's genuine surplus.
    ///
    /// @dev    Flow: (1) open every order (writes `filled`) + pull `pullMask` legs →
    ///         pool; (2) one optional `interactionTarget` call (the solver seeds any
    ///         residual it must front, e.g. a dual-conversion equity leg); (3) run
    ///         orders in `sequence` — deliver outputs from pool, `_executeItems`
    ///         (TAKE proceeds → pool), settle inputs to pool (item-funded legs keep
    ///         `owed` in the pool from proceeds and return the surplus to the maker;
    ///         `BatchItemsInputUnfunded` if a non-pulled leg under-produces); (4)
    ///         whole-check + sweep. `nonReentrant`; SETTLE items are out of scope
    ///         (they route to the filler — a shared-pool version needs its own
    ///         design). Item tokens must lie within the orders' leg-token universe
    ///         (true for leverage/repay/migrate). v1 passes empty `takerData`.
    /// @dev The `batchSettleItems` call bundle — one calldata struct so the external
    ///      ABI decode stays under the stack limit without via-IR (seven dynamic
    ///      params would overflow it). Arrays are aligned 1:1 with `orders`.
    struct ItemsBatch {
        Order[] orders;
        bytes[] sigs;
        uint256[] fillAmounts;
        uint256[] pullMask; //          bit j of [i] ⇒ pull order i's input leg j up front
        uint256[] sequence; //          execution order (a permutation of [0, n))
        address interactionTarget; //   optional (0 = skip) solver seed call
        bytes interactionData;
    }

    /// @return outs `outs[i][j]` = order `i`'s delivered amount on output leg `j`.
    function batchSettleItems(ItemsBatch calldata b) external nonReentrant returns (uint256[][] memory) {
        uint256 n = b.orders.length;
        if (b.sigs.length != n || b.fillAmounts.length != n || b.pullMask.length != n || n > 256) {
            revert LengthMismatch();
        }
        return _batchSettleItems(b);
    }

    function _batchSettleItems(ItemsBatch calldata b) internal returns (uint256[][] memory) {
        BatchState memory st;
        st.tokens = _collectTokens(b.orders);
        st.beforeBal = _snapshotBalances(st.tokens);

        // Phase 1: open every order (writes `filled`) + pull the self-funded seeds.
        _openAndPullAll(b.orders, b.sigs, b.fillAmounts, b.pullMask, st);

        // Phase 2: optional solver interaction — seed any residual the solver must
        // front (e.g. a dual-conversion equity leg). Allowance-less EXECUTOR.
        if (b.interactionTarget != address(0)) EXECUTOR.execute(b.interactionTarget, b.interactionData);

        // Phase 3: run each order against the pool in the solver-given sequence.
        _execSequence(b.orders, st, b.pullMask, b.sequence);

        // Phase 4: enforce the batch left Settlement whole and sweep any residual.
        _sweepSurplus(st.tokens, st.beforeBal);
        return st.outs;
    }

    /// @dev Phase 1: open + pull-seed every order. Item-bearing orders allowed.
    function _openAndPullAll(
        Order[] calldata orders,
        bytes[] calldata sigs,
        uint256[] calldata fillAmounts,
        uint256[] calldata pullMask,
        BatchState memory st
    ) internal {
        uint256 n = orders.length;
        st.ctxs = new FillCtx[](n);
        st.outs = new uint256[][](n);
        address solver = msg.sender;
        for (uint256 i; i < n;) {
            st.ctxs[i] = _openItemOrder(orders[i], sigs[i], fillAmounts[i], solver);
            _pullMaskedInputs(orders[i], st.ctxs[i], pullMask[i]);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev The `_fillCore` gate set (deadline/sig/exclusivity/nonce/validators) +
    ///      `_openFill` (writes `filled`), WITHOUT pulling inputs or forbidding
    ///      items — the item-aware sibling of `_batchOpenAndPull`.
    function _openItemOrder(Order calldata order, bytes calldata sig, uint256 fillAmount, address solver)
        internal
        returns (FillCtx memory ctx)
    {
        if (fillAmount == 0) revert ZeroFill();
        if (block.timestamp > order.deadline) revert OrderExpired();
        _assertItemBatchShape(order);
        bytes32 orderHash = order.hash();
        _verifySignature(orderHash, sig, order.maker);
        uint256 overrideBps = _exclusivity(order, solver);
        if (_isNonceCancelled(order.maker, order.nonce)) revert NonceCancelled();
        _runValidators(order, solver, "");
        ctx = _openFill(order, orderHash, fillAmount, overrideBps, solver, "");
    }

    /// @dev Enforce the two shape constraints the netted item flow relies on (both
    ///      documented, now also checked): no SETTLE item (it routes to the filler,
    ///      not the pool — `BatchItemsSettleUnsupported`) and no repeated input token
    ///      (the pooled proceeds attribution keys on the token — a duplicate leg
    ///      would mis-account; `BatchItemsDuplicateInput`). Runs once per order at
    ///      open. O(items + tokenIn²), tiny — the deliberate CoW path.
    function _assertItemBatchShape(Order calldata order) internal pure {
        Item[] calldata items = order.items;
        for (uint256 i; i < items.length;) {
            if (items[i].op == ItemOp.SETTLE) revert BatchItemsSettleUnsupported();
            unchecked {
                ++i;
            }
        }
        address[] calldata tokenIn = order.tokenIn;
        for (uint256 i; i < tokenIn.length;) {
            for (uint256 j = i + 1; j < tokenIn.length;) {
                if (tokenIn[i] == tokenIn[j]) revert BatchItemsDuplicateInput();
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Pull ONLY the input legs whose `mask` bit is set (the self-funded
    ///      seeds), maker → pool. `owed` uses the shared `_inputOwed` slice math.
    function _pullMaskedInputs(Order calldata order, FillCtx memory ctx, uint256 mask) internal {
        for (uint256 i; i < order.tokenIn.length;) {
            if ((mask >> i) & 1 == 1) {
                uint256 owed = _inputOwed(order, ctx, i);
                if (owed != 0) {
                    Permit3TransferLib.transferFromWithFallback(PERMIT3, order.tokenIn[i], order.maker, address(this), owed);
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Phase 3: run each order once, in the solver-given `sequence` (validated
    ///      to be a permutation of `[0, n)` — wrong length, out-of-range, or a
    ///      duplicate reverts `BatchItemsBadSequence`).
    function _execSequence(
        Order[] calldata orders,
        BatchState memory st,
        uint256[] calldata pullMask,
        uint256[] calldata sequence
    ) internal {
        uint256 n = orders.length;
        if (sequence.length != n) revert BatchItemsBadSequence();
        address solver = msg.sender;
        uint256 seen;
        for (uint256 k; k < n;) {
            uint256 idx = sequence[k];
            if (idx >= n || (seen >> idx) & 1 == 1) revert BatchItemsBadSequence();
            seen |= (uint256(1) << idx);
            st.outs[idx] = _execOrderNetted(orders[idx], st.ctxs[idx], pullMask[idx], solver);
            unchecked {
                ++k;
            }
        }
    }

    /// @dev One order's netted forward flow: deliver outputs from the pool → run
    ///      items (TAKE proceeds → pool) → settle inputs into the pool → invariants.
    ///      The pool is the counterparty throughout; the solver never touches it.
    function _execOrderNetted(Order calldata order, FillCtx memory ctx, uint256 mask, address solver)
        internal
        returns (uint256[] memory amounts)
    {
        amounts = _batchComputeOutputs(order, ctx);
        _batchDeliverStored(order, amounts); // pool → maker/recipient (reverts if pool short)
        // Snapshot AFTER delivery, BEFORE items, so proceeds measure THIS order's
        // TAKE production only (other pooled funds cancel in the delta).
        uint256[] memory tokenInBefore = _snapshotInputs(order.tokenIn);
        _executeItems(order, ctx);
        _settleInputsToPool(order, ctx, mask, tokenInBefore);
        _runInvariants(order, solver, "");
        emit OrderFilled(ctx.orderHash, order.maker, solver);
    }

    /// @dev Settle one order's input legs INTO the pool (not to a solver):
    ///      • self-funded leg (mask bit set) — `owed` was already pulled in Phase 1;
    ///        return any stray proceeds for the token to the maker (never strand).
    ///      • item-funded leg (mask bit unset) — its TAKE proceeds (the balance
    ///        delta since `tokenInBefore`) must cover `owed`; `owed` STAYS in the
    ///        pool (it funds other orders' deliveries) and the surplus returns to the
    ///        maker. `BatchItemsInputUnfunded` if proceeds < owed.
    function _settleInputsToPool(
        Order calldata order,
        FillCtx memory ctx,
        uint256 mask,
        uint256[] memory tokenInBefore
    ) internal {
        address maker = order.maker;
        for (uint256 i; i < order.tokenIn.length;) {
            address token = order.tokenIn[i];
            uint256 proceeds = SafeTransferLib.balanceOf(token, address(this)) - tokenInBefore[i];
            if ((mask >> i) & 1 == 1) {
                if (proceeds != 0) SafeTransferLib.safeTransfer(token, maker, proceeds);
            } else {
                uint256 owed = _inputOwed(order, ctx, i);
                if (proceeds < owed) revert BatchItemsInputUnfunded();
                unchecked {
                    uint256 surplus = proceeds - owed; // owed stays pooled
                    if (surplus != 0) SafeTransferLib.safeTransfer(token, maker, surplus);
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev The `owed` amount for input leg `i` — the SAME slice math as
    ///      `_payInputsToSolver`/`_batchPullInputs` (fixed + auctioned legs, soft
    ///      exclusivity), factored for the item-aware helpers. Recomputes the shared
    ///      auction bump per call (view; this is the deliberate CoW path, not the
    ///      hot single-order path).
    function _inputOwed(Order calldata order, FillCtx memory ctx, uint256 i) internal view returns (uint256 owed) {
        if (order.side == OrderSide.BUY || order.startAmountIn[i] != order.endAmountIn[i]) {
            uint256 bump = order.startAmountIn[i] != order.endAmountIn[i] ? order.bumpBps() : 0;
            owed = (ctx.newFilled - ctx.prevFilled) * order.amountInAt(i, bump) / ctx.anchor;
            if (ctx.overrideBps != 0) owed = owed * (10_000 - ctx.overrideBps) / 10_000;
        } else {
            uint256 amt = order.startAmountIn[i];
            owed = ctx.fullFill ? amt : (amt * ctx.newFilled) / ctx.anchor - (amt * ctx.prevFilled) / ctx.anchor;
        }
    }

    /// @notice Self-call fill target for {batchFill}. Verifies the maker signature
    ///         and runs the fill for an explicit `filler`, carrying this order's
    ///         `takerData`. `onlySelf` — external callers must use `fill`.
    function fillSelf(
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmount,
        address filler,
        bytes calldata takerData
    ) external returns (uint256[] memory) {
        if (msg.sender != address(this)) revert OnlySelf();
        bytes32 orderHash = order.hash();
        _verifySignature(orderHash, sig, order.maker);
        return _fillCore(order, orderHash, fillAmount, filler, address(0), "", CallbackMode.PreDelivery, takerData);
    }

    // ──────────────────── On-chain order authorization ────────────────────

    /// @notice Signature-less order authorization. Instead of signing the order
    ///         off-chain, the maker (`msg.sender`) records approval on-chain here;
    ///         fillers then fill with an EMPTY `sig`. This is the path for makers
    ///         that cannot produce a verifiable signature at all — a classic
    ///         multisig with no EIP-1271 `isValidSignature`, for which neither the
    ///         ECDSA nor the 1271 branch of {SignatureVerification} can succeed.
    ///         (Signers that CAN produce a signature — EOA, EIP-1271 wallet, Safe,
    ///         EIP-7702 account — should just sign; they need no on-chain write.)
    ///
    ///         The mapping is keyed by `msg.sender` and checked at fill time against
    ///         `order.maker`, so a caller can only ever authorize an order that names
    ///         itself as maker — no one can approve on another maker's behalf. The
    ///         `order.maker == msg.sender` guard makes that explicit and fails fast.
    ///
    ///         Nothing else about the fill changes: the maker must still hold the
    ///         standing Permit3 allowances the fill consumes, and every fill remains
    ///         gated by the order's deadline, nonce (see {NonceManager}), validators,
    ///         and invariants. Approval is the exact analogue of a signature — it
    ///         authorizes the order for partial fills up to its size, not a single use.
    /// @return orderHash The EIP-712 order hash now authorized (handy for indexing).
    function approveOrder(Order calldata order) external returns (bytes32 orderHash) {
        if (order.maker != msg.sender) revert NotOrderMaker();
        orderHash = order.hash();
        orderApproved[msg.sender][orderHash] = true;
        emit OrderApproved(msg.sender, orderHash);
    }

    /// @notice Withdraw a prior {approveOrder}. Keyed by `msg.sender`, so a maker can
    ///         only clear its own approval. Cancelling the order's nonce
    ///         ({cancelOrders}/{rollbackNonces}) also blocks the fill — the nonce gate
    ///         runs on every fill regardless — but leaves this flag set; use this to
    ///         un-approve without burning the nonce, or to reclaim the storage.
    function revokeOrderApproval(bytes32 orderHash) external {
        orderApproved[msg.sender][orderHash] = false;
        emit OrderApprovalRevoked(msg.sender, orderHash);
    }

    /// @dev Per-fill context, bundled so the settlement helpers take one memory
    ///      pointer and each settle flow runs in its own stack frame (keeps the
    ///      fill under the EVM stack limit).
    struct FillCtx {
        bytes32 orderHash;
        uint256 anchor; //       fill denominator (fixed-side leg 0)
        uint256 prevFilled; //   cumulative filled before this fill
        uint256 newFilled; //    cumulative filled after this fill
        uint256 overrideBps; //  soft-exclusivity improvement (0 = none)
        address filler; //       who is paid / delivers
        bool fullFill; //        prevFilled == 0 && newFilled == anchor: the whole
        //                       order in one shot ⇒ every pro-rata slice is the
        //                       leg's full amount, skipping the mul/div.
    }

    function _fillCore(
        Order calldata order,
        bytes32 orderHash,
        uint256 fillAmount,
        address filler,
        address callbackTarget,
        bytes memory callbackData,
        CallbackMode mode,
        bytes memory takerData
    ) internal returns (uint256[] memory) {
        if (fillAmount == 0) revert ZeroFill();
        // Note: the anti-dust floor is checked in _openFill against the resolved
        // `delta` (the actual progress), not the requested `fillAmount` — for a
        // fill-module order the two can differ, and minFillAnchor must gate the
        // real advance. For an identity order delta == fillAmount, so behavior is
        // unchanged.
        if (block.timestamp > order.deadline) revert OrderExpired();

        uint256 overrideBps = _exclusivity(order, filler);
        if (_isNonceCancelled(order.maker, order.nonce)) revert NonceCancelled();
        _runValidators(order, filler, takerData);

        // `takerData` doubles as the filler's fill proposal for a fill-module
        // order (see {IFillModule}); a plain fungible order ignores it here.
        FillCtx memory ctx = _openFill(order, orderHash, fillAmount, overrideBps, filler, takerData);

        // The SAME takerData feeds the post-execution invariants (via the settle
        // helper), so a validator and an invariant see an identical filler blob.
        return mode == CallbackMode.PostInputs
            ? _settlePostInputs(order, ctx, callbackTarget, callbackData, takerData)
            : _settleForward(order, ctx, callbackTarget, callbackData, takerData);
    }

    /// @dev Exclusivity gate. Inside the window only the nominated filler fills
    ///      for free; a non-exclusive filler is blocked (hard exclusivity) or
    ///      allowed against an `exclusivityOverrideBps` price improvement it must
    ///      pay the maker (soft exclusivity). Returns the override, 0 otherwise.
    function _exclusivity(Order calldata order, address filler) internal view returns (uint256 overrideBps) {
        if (
            order.exclusiveFiller != address(0) && block.timestamp < order.exclusivityEndTime
                && filler != order.exclusiveFiller
        ) {
            if (order.exclusivityOverrideBps == 0) revert NotExclusiveFiller();
            overrideBps = order.exclusivityOverrideBps;
        }
    }

    /// @dev Reserve this fill's slice: resolve the denominator + this fill's
    ///      delta, check over-fill, bump the cumulative counter, and package the
    ///      context. The denominator (`ctx.anchor`) is the fixed-side leg 0
    ///      (`tokenIn[0]` for SELL, `tokenOut[0]` for BUY) for a plain fungible
    ///      order, or the maker-signed `fillTotal` when set. The delta is the
    ///      requested `fillAmount` for the identity case, or a fill module's
    ///      accepted amount when `order.fillModule` is set — see {IFillModule}.
    ///
    ///      Security: the module may only choose the DELTA; the over-fill cap
    ///      (`newFilled <= total`) and the uniform per-leg scaling stay here, so
    ///      a buggy/hostile module can only mis-size the fraction (which scales
    ///      both sides of the order proportionally), never over-extract.
    function _openFill(
        Order calldata order,
        bytes32 orderHash,
        uint256 fillAmount,
        uint256 overrideBps,
        address filler,
        bytes memory takerData
    ) internal returns (FillCtx memory ctx) {
        // Denominator: maker-signed `fillTotal` when set, else the leg anchor.
        // The `!= 0` branch reads a single calldata word — no leg access, so a
        // pure non-fungible order (empty legs) still has a valid denominator.
        uint256 total = order.fillTotal != 0 ? order.fillTotal : _anchorTotal(order);
        uint256 prevFilled = filled[orderHash];
        // Delta: identity (zero overhead — a calldata compare, no call) or a
        // fill-module resolve. The module validates the filler's proposal
        // (`takerData`) against this order and returns the accepted delta.
        uint256 delta;
        if (order.fillModule == address(0)) {
            delta = fillAmount; // identity — already checked != 0 in _fillCore
        } else {
            delta = IFillModule(order.fillModule).resolveFill(order, prevFilled, fillAmount, takerData);
            if (delta == 0) revert ZeroFill(); // a module can return 0; identity can't
        }
        // Anti-dust floor on the ACTUAL progress (delta), identity + module alike.
        if (delta < order.minFillAnchor) revert FillTooSmall();
        uint256 newFilled = prevFilled + delta;
        if (newFilled > total) revert OverFill();
        filled[orderHash] = newFilled;
        ctx = FillCtx(orderHash, total, prevFilled, newFilled, overrideBps, filler, prevFilled == 0 && newFilled == total);
    }

    /// @dev Forward flow: optional callback → deliver outputs → items → pay
    ///      inputs → invariants. The callback runs BEFORE any funds move, routed
    ///      through the allowance-less EXECUTOR (cannot leverage Settlement's
    ///      Permit3 spender status) and under `nonReentrant`.
    function _settleForward(
        Order calldata order,
        FillCtx memory ctx,
        address callbackTarget,
        bytes memory callbackData,
        bytes memory takerData
    ) internal returns (uint256[] memory outs) {
        if (callbackTarget != address(0)) EXECUTOR.execute(callbackTarget, callbackData);

        outs = _deliverOutputs(order, ctx);

        // Snapshot each tokenIn before items so the payout uses ONLY this fill's
        // TAKE proceeds — never a pre-existing/donated Settlement balance. Skipped
        // for item-free orders: with no TAKE legs there are no proceeds, so the
        // snapshot + the balanceOf re-read in `_payInputsToSolver` would just burn
        // two STATICCALLs per input leg on every plain swap.
        bool hasItems = order.items.length != 0;
        uint256[] memory tokenInBefore = hasItems ? _snapshotInputs(order.tokenIn) : new uint256[](0);
        _executeItems(order, ctx);
        _payInputsToSolver(order, ctx, tokenInBefore, hasItems);
        _runInvariants(order, ctx.filler, takerData);
        emit OrderFilled(ctx.orderHash, order.maker, ctx.filler);
    }

    /// @dev Reverse (PostInputs) flow: pay the solver its tokenIn FIRST, let the
    ///      callback convert it, THEN deliver tokenOut — a zero-inventory /
    ///      zero-flash swap (the Fusion takerInteraction order). Item-free only:
    ///      item flows have deposit→borrow dependencies that assume the forward
    ///      order. Delivery + invariants stay mandatory and reverting, so the
    ///      maker is made whole or the whole tx unwinds.
    function _settlePostInputs(
        Order calldata order,
        FillCtx memory ctx,
        address callbackTarget,
        bytes memory callbackData,
        bytes memory takerData
    ) internal returns (uint256[] memory outs) {
        if (order.items.length != 0) revert ReverseModeRequiresNoItems();
        // No items ⇒ no TAKE proceeds ⇒ proceeds are 0 by construction, so
        // `_payInputsToSolver` (hasItems=false) pulls exactly `owed` from the
        // maker → solver with no balance snapshot needed.
        _payInputsToSolver(order, ctx, new uint256[](0), false);
        if (callbackTarget != address(0)) EXECUTOR.execute(callbackTarget, callbackData);
        outs = _deliverOutputs(order, ctx);
        _runInvariants(order, ctx.filler, takerData);
        emit OrderFilled(ctx.orderHash, order.maker, ctx.filler);
    }

    /// @dev The fill denominator in anchor units: the FIXED side's leg 0 —
    ///      `startAmountIn[0]` (SELL) or `startAmountOut[0]` (BUY).
    function _anchorTotal(Order calldata order) internal pure returns (uint256) {
        return order.side == OrderSide.BUY ? order.startAmountOut[0] : order.startAmountIn[0];
    }

    /// @dev ceil(a / b), b > 0.
    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /// @dev Deliver every output leg for this fill, solver → the leg's recipient
    ///      (`recipientOut[j]`, `address(0)` = the maker — so a fee leg is just an
    ///      output addressed to the originator).
    ///      • SELL: outputs are auction-priced — each leg is `ceil(fillAmount ·
    ///        currentAmountOut / anchor)` at the current tick, so the maker is
    ///        never underpaid.
    ///      • BUY: outputs are FIXED — each leg is the cumulative ceil slice of
    ///        `startAmountOut[j]`, summing to exactly `startAmountOut[j]` at full
    ///        fill (and to `fillAmount` for j==0). Each leg pulls the solver's
    ///        `tokenOut` via Permit3, falling back to a direct ERC20 transferFrom
    ///        when the solver approved Settlement directly (see
    ///        `_transferFromWithFallback`).
    function _deliverOutputs(Order calldata order, FillCtx memory ctx) internal returns (uint256[] memory outs) {
        uint256 n = order.tokenOut.length;
        outs = new uint256[](n);
        bool buy = order.side == OrderSide.BUY;
        uint256 anchor = ctx.anchor;
        // SELL outputs are auction-priced; the decay bump is shared by all legs, so
        // compute it at most once — sentinel uint256.max = "not yet computed" (a real
        // bump is always ≤ 10000). Lazy so an all-fixed order never calls bumpBps.
        uint256 bump = type(uint256).max;
        for (uint256 j; j < n;) {
            uint256 amt;
            if (buy) {
                // Fixed output — the exact-output guarantee; never overridden.
                uint256 fixedOut = order.startAmountOut[j];
                amt = ctx.fullFill
                    ? fixedOut
                    : _ceilDiv(fixedOut * ctx.newFilled, anchor) - _ceilDiv(fixedOut * ctx.prevFilled, anchor);
            } else {
                if (order.startAmountOut[j] != order.endAmountOut[j] && bump == type(uint256).max) {
                    bump = order.bumpBps();
                }
                amt = _ceilDiv((ctx.newFilled - ctx.prevFilled) * order.amountOutAt(j, bump), anchor);
            }
            if (amt != 0) {
                address to = order.recipientOut[j];
                bool makerLeg = to == address(0) || to == order.maker;
                // Soft-exclusivity override: a non-exclusive in-window filler must
                // deliver MORE output. The improvement is the MAKER's compensation
                // for a bypassed exclusive filler, so it applies ONLY to the
                // maker's own SELL output legs — never a fee leg addressed to a
                // third party (which would leak the comp to the fee recipient and
                // break an "absolute" fee), and never BUY (fixed exact-output).
                // Mirrors the input side, where the override adjusts only the
                // maker's charge (fee/relayer legs are auctioned, not overridden
                // upward).
                if (!buy && ctx.overrideBps != 0 && makerLeg) {
                    amt = _ceilDiv(amt * (10_000 + ctx.overrideBps), 10_000);
                }
                outs[j] = amt;
                Permit3TransferLib.transferFromWithFallback(
                    PERMIT3, order.tokenOut[j], ctx.filler, makerLeg ? order.maker : to, amt
                );
            }
            unchecked {
                ++j;
            }
        }
    }

    /// @dev Snapshot Settlement's balance of every input token before items run.
    function _snapshotInputs(address[] calldata tokens) internal view returns (uint256[] memory bals) {
        uint256 n = tokens.length;
        bals = new uint256[](n);
        for (uint256 i; i < n;) {
            bals[i] = SafeTransferLib.balanceOf(tokens[i], address(this));
            unchecked {
                ++i;
            }
        }
    }

    /// @dev For each item, execute the slice attributable to this fill:
    ///      slice = item.amount * newFilled / anchor
    ///            - item.amount * prevFilled / anchor
    ///      Sums to exactly item.amount once the order is fully filled.
    function _executeItems(Order calldata order, FillCtx memory ctx) internal {
        for (uint256 i; i < order.items.length; i++) {
            Item calldata item = order.items[i];
            uint256 slice = ctx.fullFill
                ? item.amount
                : (item.amount * ctx.newFilled) / ctx.anchor - (item.amount * ctx.prevFilled) / ctx.anchor;
            if (slice == 0) continue;

            if (item.op == ItemOp.MAKE) {
                // Maker module pulls the funding token from order.maker via Permit3 internally.
                IMakerModule(item.module).makeOnBehalf(order.maker, slice, item.data);
            } else if (item.op == ItemOp.TAKE) {
                // Taker: Permit3 enforces the gate and dispatches. `recipient = 0` is the
                // classic flow (proceeds to Settlement for tokenIn payout); signing a
                // non-zero recipient (e.g. the maker) chains output into a subsequent item.
                address to = item.recipient == address(0) ? address(this) : item.recipient;
                PERMIT3.take(item.module, order.maker, uint160(slice), to, item.data);
            } else {
                // SETTLE: generic solver↔maker exchange — the FILLER-AWARE fallback
                // for exchanges the typed legs can't express (see {ISettlementModule}).
                // The module acts under the maker's signature + its own maker approval;
                // passing `ctx.filler` lets the maker's asset route to whoever fills. The
                // maker's receipt is guaranteed by the mandatory tokenOut delivery (run
                // before items) and/or an invariant, not by the module.
                ISettlementModule(item.module).settle(order.maker, ctx.filler, slice, item.data);
            }
        }
    }

    /// @dev Pay every input leg to the solver for this fill.
    ///      • Fixed leg (`start == end`, the common SELL input): `owed_i` is the
    ///        cumulative floor slice of `startAmountIn[i]`, summing to exactly
    ///        `startAmountIn[i]` at full fill (and to `fillAmount` for i==0) —
    ///        the exact-input guarantee.
    ///      • Auctioned leg (`start != end`): `owed_i = floor(fillAmount ·
    ///        currentAmountIn / anchor)` at the current tick — rising
    ///        `start → end`, gas bump included; the maker is never overcharged
    ///        and the total never exceeds `endAmountIn[i]`. Every BUY conversion
    ///        input is such a leg; on SELL it is the relayer-fee auction for
    ///        orders with no conversion output to price a filler's compensation
    ///        into (e.g. a pure gasless deposit).
    ///
    ///      Soft exclusivity applies to every auctioned input leg: a
    ///      non-exclusive in-window filler charges `overrideBps` less — the
    ///      auction leg moves toward the maker.
    ///
    ///      Each leg uses ONLY the TAKE proceeds produced by THIS fill (the
    ///      balance delta since `tokenInBefore[i]`) — so a pre-existing/donated
    ///      Settlement balance can never be redirected to the solver. Any
    ///      shortfall is pulled from the maker via Permit3 (falling back to a
    ///      direct ERC20 transferFrom if the maker approved Settlement directly);
    ///      any surplus proceeds are returned to the maker, not stranded.
    function _payInputsToSolver(
        Order calldata order,
        FillCtx memory ctx,
        uint256[] memory tokenInBefore,
        bool hasItems
    ) internal {
        address maker = order.maker;
        address filler = ctx.filler;
        uint256 anchor = ctx.anchor;
        bool buy = order.side == OrderSide.BUY;
        uint256 fillAmount = ctx.newFilled - ctx.prevFilled;
        // BUY inputs are auction-priced; shared bump computed once (sentinel = max).
        uint256 bump = type(uint256).max;
        for (uint256 i; i < order.tokenIn.length; i++) {
            uint256 owed;
            // Auctioned input: any leg with `start != end` (all BUY conversion
            // inputs; on SELL, the rising relayer-fee leg). `buy` short-circuits
            // so a fixed BUY leg still takes the auction path's amountInAt
            // (which returns the fixed amount) — preserving BUY's per-fill
            // floor rounding exactly as before.
            if (buy || order.startAmountIn[i] != order.endAmountIn[i]) {
                if (order.startAmountIn[i] != order.endAmountIn[i] && bump == type(uint256).max) {
                    bump = order.bumpBps();
                }
                owed = (fillAmount * order.amountInAt(i, bump)) / anchor;
                // Soft-exclusivity override: a non-exclusive in-window filler must
                // charge LESS input (the auction leg moves toward the maker).
                if (ctx.overrideBps != 0) owed = (owed * (10_000 - ctx.overrideBps)) / 10_000;
            } else {
                // Fixed input — the exact-input guarantee; never overridden.
                uint256 amt = order.startAmountIn[i];
                owed = ctx.fullFill ? amt : (amt * ctx.newFilled) / anchor - (amt * ctx.prevFilled) / anchor;
            }
            address tokenIn = order.tokenIn[i];
            // Item-free orders have no TAKE proceeds ⇒ proceeds are 0 without a
            // balanceOf (the snapshot was skipped upstream). Item orders measure
            // this fill's proceeds as the balance delta since the snapshot.
            uint256 proceeds = hasItems ? SafeTransferLib.balanceOf(tokenIn, address(this)) - tokenInBefore[i] : 0;
            if (owed == 0) {
                // Nothing owed on this leg (dust slice, or a zero-amount leg),
                // but any TAKE proceeds for this token must still be returned to
                // the maker — never stranded in Settlement (there is no sweep).
                // Zero-guarded against no-op transfers on strict tokens.
                if (proceeds != 0) SafeTransferLib.safeTransfer(tokenIn, maker, proceeds);
                continue;
            }
            if (proceeds >= owed) {
                SafeTransferLib.safeTransfer(tokenIn, filler, owed);
                unchecked {
                    uint256 surplus = proceeds - owed; // proceeds >= owed
                    if (surplus > 0) SafeTransferLib.safeTransfer(tokenIn, maker, surplus);
                }
            } else {
                if (proceeds > 0) SafeTransferLib.safeTransfer(tokenIn, filler, proceeds);
                unchecked {
                    Permit3TransferLib.transferFromWithFallback(PERMIT3, tokenIn, maker, filler, owed - proceeds); // owed > proceeds
                }
            }
        }
    }

    // ──────────────────── Validators / invariants ────────────────────

    /// @dev Pre-execution staticcall validators. `filler` is the address executing
    ///      this fill (threaded from msg.sender, or from batchFill's caller), so a
    ///      maker-signed validator can express filler-conditional policy. The shared
    ///      `takerData` (filler-supplied, unsigned, adversarial — see
    ///      {IOrderValidator}) is passed to every validator.
    function _runValidators(Order calldata order, address filler, bytes memory takerData) internal view {
        uint256 len = order.validators.length;
        for (uint256 i; i < len;) {
            Validator calldata v = order.validators[i];
            if (!_gatePasses(v.target, order, filler, v.data, takerData)) revert ValidationFailed(i);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Staticcall `target.validate(order, filler, data, takerData)` and return
    ///      whether it passed (call ok AND ≥32 bytes returned AND the bool word ==
    ///      1). The single-word return is read into scratch space, avoiding the
    ///      `bytes memory` return allocation the abstract call would make. `data` is
    ///      the maker-signed per-validator config; `takerData` is the shared
    ///      filler-supplied blob (a validator must independently verify it).
    function _gatePasses(
        address target,
        Order calldata order,
        address filler,
        bytes calldata data,
        bytes memory takerData
    ) private view returns (bool pass) {
        bytes memory cd = abi.encodeCall(IOrderValidator.validate, (order, filler, data, takerData));
        /// @solidity memory-safe-assembly
        assembly {
            let ok := staticcall(gas(), target, add(cd, 0x20), mload(cd), 0x00, 0x20)
            pass := and(and(ok, gt(returndatasize(), 31)), eq(mload(0x00), 1))
        }
    }

    /// @dev Post-execution staticcall invariants. Same shape as validators
    ///      (including the threaded `filler` and the shared `takerData`) but run
    ///      AFTER items execute, so they can assert on the order's side effects
    ///      (e.g. "maker's Aave health factor ≥ 2.0").
    function _runInvariants(Order calldata order, address filler, bytes memory takerData) internal view {
        uint256 len = order.invariants.length;
        for (uint256 i; i < len;) {
            Validator calldata v = order.invariants[i];
            if (!_gatePasses(v.target, order, filler, v.data, takerData)) revert InvariantFailed(i);
            unchecked {
                ++i;
            }
        }
    }

    function _verifySignature(bytes32 orderHash, bytes calldata sig, address expected) internal view {
        // Signature-less path: an EMPTY `sig` authorizes against the maker's on-chain
        // {approveOrder} record instead of a signature. No valid signature has zero
        // length (the shared verifier rejects it), so the sentinel can never collide
        // with a real one. This lets a maker that cannot sign — e.g. a multisig
        // without EIP-1271 — still place orders. Every other fill gate is unchanged.
        if (sig.length == 0) {
            if (!orderApproved[expected][orderHash]) revert OrderNotApproved();
            return;
        }
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), orderHash));
        // Shared verifier: EOA (ecrecover), EIP-1271 contract wallets, and
        // EIP-7702 accounts (raw-key or delegated-1271) are all accepted.
        SignatureVerification.verify(sig, digest, expected);
    }
}
