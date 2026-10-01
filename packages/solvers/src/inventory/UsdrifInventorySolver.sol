// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedArraysMem} from "@core/settlement/PackedArraysMem.sol";
import {PackedArrays} from "@core/settlement/PackedArrays.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {Settlement, Order, CallbackMode} from "@core/settlement/Settlement.sol";
import {DutchAuction} from "@core/settlement/DutchAuction.sol";

/// @notice Minimal MoC surfaces (duplicated from `packages/modules/redeem/usdrif`
///         so `core` stays this package's only cross-package dependency).
interface IMocRifCore {
    /// @dev Escrows `qTP_` USDRIF and queues a RedeemTP op; RIF is delivered to
    ///      `recipient_` (which MUST equal msg.sender) when the queue executes.
    ///      Payable: `msg.value` must be the queue exec fee.
    function redeemTP(address tp_, uint256 qTP_, uint256 qACmin_, address recipient_, address vendor_)
        external
        payable
        returns (uint256 operId);
}

interface IMocQueueFees {
    /// @dev Exec fee (wei) for an op of `operType_` — the exact `msg.value`
    ///      `redeemTP` expects: `execCost × block.basefee` (on Rootstock, BASEFEE
    ///      returns the block's minimumGasPrice per RSKIP-412; verified on-fork).
    ///      `OperType.redeemTP == 4`.
    function getExecFee(uint8 operType_) external view returns (uint256);

    /// @dev Id of the oldest op still queued. `MocQueue.execute` advances it
    ///      whenever it executes (or fails and refunds) anything, whichever entry
    ///      drove it — the permissionless `MocMultiCollateralGuard.execute()` or
    ///      `executeLiquidatedBucket()`. The solver brackets every measured window
    ///      with it (see {UsdrifInventorySolver.QueueMovedDuringMeasurement}).
    function firstOperId() external view returns (uint256);
}

/// @title UsdrifInventorySolver
/// @notice Inventory-funded filler for direct USDRIF→USDT0 exit orders on
///         Rootstock, plus the async machinery that recycles the received
///         USDRIF back into USDT0 via MoC's native redemption.
///
///  The flash family fills from borrowed capital inside one atomic tx. That is
///  impossible here: MoC redemption is queued — the RIF only exists ~30–90s
///  after `redeemTP`, once someone drains the queue — so the
///  repayment capital cannot exist inside the fill transaction. Inventory is
///  structurally required, and the round trip is a three-step cycle:
///
///    1. fill (atomic):    maker signs a USDRIF→USDT0 order; an operator calls
///                         `executeFillAndRedeem`. Settlement pulls USDT0 from
///                         this contract via Permit3 and delivers USDRIF here,
///                         and the same tx escrows it into MoC. MoC's
///                         `recipient == msg.sender` rule — the reason a
///                         user-side redeem wrapper is not viable — is a no-op
///                         for a principal redeeming its own tokens to itself.
///    2. settle (async):   the queue executes and MoC delivers RIF to this
///                         contract (or, for a failed op, refunds the USDRIF).
///                         ⚠ ANYONE can trigger that: `MocQueue.execute` is
///                         restricted to the multi-collateral guard, but the
///                         guard's own `execute()` is permissionless
///                         (`external notPaused nonReentrant`, verified on
///                         mainnet). Deliveries can therefore land inside ANY
///                         external call this contract makes — see
///                         {QueueMovedDuringMeasurement} for why every measured
///                         window refuses that (audit 2026-09-30 RIF-1/RIF-2).
///    3. recycle (atomic): an operator `sell`s the RIF → USDT0 through an
///                         owner-whitelisted venue (Uniswap v3 router, an
///                         aggregator, …) along an owner-configured route
///                         (`sellRoutes`): the pair, a per-call spend budget and
///                         a minimum rate are the owner's; the operator only
///                         picks timing, size within budget and a tighter floor.
///                         Both floors are enforced here by balance delta —
///                         venue-agnostic slippage safety.
///
///  Trust model: unlike `BaseFlashSolver`, this contract HOLDS FUNDS between
///  fills (USDT0 inventory, in-flight USDRIF/RIF, an RBTC float for MoC exec
///  fees), so every state-changing entrypoint is owner- or operator-gated.
///  Fill-pricing judgment lives off-chain with the operator, and is ENFORCED
///  on-chain by the operator's own `maxSpent` bound on every fill (on top of the
///  owner's {fillMinRate} — the same split `sell` makes between `minOut` and the
///  route rate; audit 2026-09-30 PERIPH-1.v2); the maker's protection is the
///  settlement-enforced amountOut floor, exactly as with any other filler.
///
///  Supported order shapes: one output token paid out of inventory, one input
///  token received, NO items (a maker-signed item is the one maker-controlled
///  hook that runs inside the measured fill — audit 2026-09-30 RIF-2). Both
///  delivery modes fill: a plain order is pulled from inventory via Permit3, and
///  a delta-verify order (`timing` bit 104, the mode the app signs) is delivered
///  by this contract's own callback — such an order must name THIS contract as
///  its `exclusiveFiller` (audit 2026-09-30 RIF-4). Redemption ops are tracked off-chain via the
///  `RedemptionInitiated` event + MoC's FIFO signal (`opId < firstOperId()`);
///  a failed op refunds the escrowed USDRIF here, ready to re-initiate.
contract UsdrifInventorySolver {
    IPermit3 public immutable permit3;
    Settlement public immutable settlement;
    IMocRifCore public immutable mocCore;
    IMocQueueFees public immutable mocQueue;
    address public immutable usdrif;

    /// @dev `OperType.redeemTP` index in the MoC queue enum {none,mintTC,redeemTC,mintTP,redeemTP,...}.
    uint8 internal constant OPER_REDEEM_TP = 4;

    /// @dev Fixed-point unit of `SellRoute.minRateWad`.
    uint256 internal constant WAD = 1e18;

    /// @notice Settlement's allowance-less callback trampoline — the only caller
    ///         {onSettlementFill} accepts. Read once at construction.
    address public immutable EXECUTOR;

    /// @dev 1 = idle, 2 = a delta-verify fill this contract started is waiting for
    ///      its delivery callback. Single-use: the callback clears it.
    uint256 private _deliveryArmed = 1;

    address public owner;
    /// @notice Nominee from {transferOwnership}, pending {acceptOwnership}.
    address public pendingOwner;
    mapping(address => bool) public operators;
    /// @dev Owner-whitelisted conversion venues callable from `sell`. The
    ///      whitelist is what keeps `sell` operator-grade: without it an
    ///      operator could call ANY contract (e.g. Permit3) with crafted
    ///      calldata from this contract's identity. It is necessary but NOT
    ///      sufficient — a whitelisted router still executes whatever calldata
    ///      the operator builds (its own recipient, its own tokenOut), which is
    ///      why `sell` is additionally bound to {sellRoutes}.
    mapping(address => bool) public aggregators;

    /// @notice Tokens this contract holds or trades: fill inventory
    ///         (`setupTokenApproval` / constructor), USDRIF, and both sides of
    ///         every configured {sellRoutes} pair. Sticky once set.
    ///
    ///  Why it exists: `sell`'s checks are balance deltas on `tokenIn`/`tokenOut`
    ///  only. A venue that IS a held token (whitelisting USDT0 "as an
    ///  aggregator") would let `data = USDT0.transfer(operator, all)` move a
    ///  third token those deltas never look at. {setAggregator} therefore refuses
    ///  any known token, and {setSellRoute}/{setupTokenApproval} refuse a
    ///  current aggregator, so the two sets can never overlap in either order.
    mapping(address => bool) public isKnownToken;

    /// @notice Owner-configured conversion route for `sell`.
    /// @param minRateWad Minimum `amountOut / spent`, in RAW token units,
    ///        WAD-scaled: `sell` requires `amountOut * 1e18 >= spent * minRateWad`.
    ///        Decimals are NOT normalised — e.g. RIF (18) → USDT0 (6) at a floor
    ///        of $0.05/RIF is `0.05e6 * 1e18 / 1e18 = 5e4`; the reverse USDT0 →
    ///        RIF at 15 RIF/USDT0 is `15e18 * 1e18 / 1e6 = 1.5e31`.
    ///        **0 means the pair is not allowed** (fail closed).
    /// @param maxAmountIn Per-call ceiling on `tokenIn` spent through this
    ///        route. The venue's approval is capped at it, and the measured spend
    ///        is re-checked against it.
    struct SellRoute {
        uint128 minRateWad;
        uint128 maxAmountIn;
    }

    /// @notice `tokenIn => tokenOut => route`. Owner-set; empty = `sell` refuses
    ///         the pair.
    ///
    ///  Why it exists: `sell`'s arguments — `tokenIn`, `tokenOut`, `minOut` and
    ///  the opaque venue `data` — are all operator-chosen and nothing on-chain
    ///  ties them together. Without a route, `sell(SwapRouter02, USDT0, RIF, max,
    ///  0, exactInputSingle(USDT0→x, recipient = operator))` measures a RIF delta
    ///  of 0 ≥ minOut 0 and ships the whole inventory to the operator in one call,
    ///  bypassing {maxOutflowPerFill} and making the operator tier
    ///  owner-equivalent again. With a route, whatever leaves as `tokenIn` must
    ///  come back as the OWNER-chosen `tokenOut` at no worse than the OWNER-chosen
    ///  rate, bounded per call — the operator's worst case is "a sale at the
    ///  owner's floor price", not "a transfer to self". Keep the floor fresh: a
    ///  stale rate far below market is a sandwich budget.
    mapping(address => mapping(address => SellRoute)) public sellRoutes;

    /// @notice Per-token ceiling on how much inventory ONE `executeFill` call may
    ///         pay out. Owner-set; **0 means no outflow is permitted**, so a fresh
    ///         deployment fails closed until the owner configures a budget.
    ///
    ///  Why this exists: `executeFill` takes an ARBITRARY `(order, sig)` and makes
    ///  this contract the filler while it holds a `type(uint160).max` Permit3
    ///  allowance to Settlement on every inventory token. Without a bound, an
    ///  operator — explicitly a lower trust tier than owner, which is the whole
    ///  reason `sell` has a venue whitelist and owner-set routes — could sign their own order with
    ///  `legsOut[0]` set to the entire inventory and take 100% of it in one call,
    ///  paying a token amount in. That made the operator tier owner-equivalent,
    ///  contradicting the contract's stated design.
    ///
    ///  On its own this bounded NOTHING against a compromised key: it measured only
    ///  what left, so a self-signed order paying the cap for a junk input token
    ///  could be repeated — in one transaction, by a contract operator (re-audit
    ///  F30). What bounds the operator now is the combination: {fillMinRate} (what
    ///  leaves must come back as the owner's token at the owner's rate) and
    ///  {OutflowBudget} (cumulative per window, shared with `sell`). This per-call
    ///  cap remains as a size limit on any single fill. `sell` has its own, separate per-call
    ///  budget ({SellRoute.maxAmountIn}) — a recycle spends RIF/USDRIF, a fill pays
    ///  out USDT0, and one knob for both would couple unrelated sizes.
    mapping(address => uint256) public maxOutflowPerFill;

    /// @notice Owner-configured FILL route: `fillMinRate[spent][received]` is the
    ///         minimum `received / spent` a fill must realise, in RAW token units,
    ///         WAD-scaled — the same convention as {SellRoute.minRateWad}. E.g.
    ///         "at least 1 USDRIF per USDT0 paid" is `1e18 * 1e18 / 1e6 = 1e30`.
    ///         **0 means fills of that pair are refused** (fail closed).
    ///
    ///  Why it exists (re-audit F30): {maxOutflowPerFill} measured only what LEFT
    ///  the contract, never what came back. An operator could self-sign an order
    ///  paying out up to the cap in exchange for a worthless input token and
    ///  repeat it; with a contract operator, in one transaction. A fill now has to
    ///  bring the OWNER-chosen token back at no worse than the OWNER-chosen rate,
    ///  measured by balance delta — the operator's worst case becomes "a fill at
    ///  the owner's floor price", exactly as {sellRoutes} does for `sell`.
    mapping(address => mapping(address => uint256)) public fillMinRate;

    /// @notice Length of one {OutflowBudget} accounting window.
    uint256 public constant OUTFLOW_WINDOW = 1 hours;

    /// @notice A token's cumulative outflow budget and its use, in ONE slot.
    /// @param start Start of the window `used` belongs to (aligned to {OUTFLOW_WINDOW}).
    /// @param used  Spent so far in that window.
    /// @param limit Per-token ceiling on the CUMULATIVE amount fills and `sell` may
    ///        spend within one {OUTFLOW_WINDOW}. Owner-set via {setOutflowLimit};
    ///        **0 means nothing may leave** (fail closed).
    ///
    ///  Why it exists (re-audit F30): {maxOutflowPerFill} and
    ///  {SellRoute.maxAmountIn} are per CALL, with no memory between calls, and
    ///  {setOperator} accepts a contract — so a compromised operator could loop
    ///  either path inside one transaction and the per-call bounds would bound
    ///  nothing. This budget is shared by both paths and keyed by the token SPENT,
    ///  so however the calls are sliced, at most `limit` leaves per window (≤ 2×
    ///  across a window boundary — windows are aligned, not rolling), and the owner
    ///  has the rest of the window to revoke the key.
    ///
    ///  Packed with the usage rather than kept in its own mapping, so a charge is
    ///  ONE cold slot read instead of two (~2.1k gas on every fill and `sell`).
    ///  96 bits hold 7.9e28 raw units — 79 billion whole tokens at 18 decimals.
    struct OutflowBudget {
        uint64 start;
        uint96 used;
        uint96 limit;
    }

    mapping(address => OutflowBudget) public outflowBudget;

    error NotOwner();
    error NotOperator();
    error NativeTransferFailed();
    error TransferFailed();
    error NotPendingOwner();
    error AggregatorNotAllowed();
    /// @dev `setAggregator` refused a target that would turn `sell` into an
    ///      arbitrary-call primitive from this identity (self, Permit3,
    ///      Settlement, MoC, a known token, zero).
    error ForbiddenAggregator(address aggregator);
    /// @dev `setSellRoute` / `setupTokenApproval` refused a token that is a
    ///      whitelisted aggregator, or an identical pair.
    error ForbiddenToken(address token);
    /// @dev No owner-configured route for `tokenIn → tokenOut`.
    error RouteNotAllowed(address tokenIn, address tokenOut);
    /// @dev One `sell` spent more `tokenIn` than the route's per-call budget
    ///      (or than the allowance it granted).
    error SellCapExceeded(address tokenIn, uint256 attempted, uint256 cap);
    /// @dev Measured output is below the route's owner-set minimum rate.
    error RateTooLow(uint256 amountOut, uint256 spent, uint256 minRateWad);
    error InsufficientOutput(uint256 amountOut, uint256 minOut);
    /// @dev One `executeFill` moved more of `token` out of inventory than the
    ///      owner-set per-call budget allows.
    error OutflowCapExceeded(address token, uint256 attempted, uint256 cap);
    /// @dev The cumulative spend of `token` in the current window would exceed
    ///      its {OutflowBudget} limit.
    error OutflowWindowExceeded(address token, uint256 wouldUse, uint256 limit);
    /// @dev {setOutflowLimit} above the 96-bit field of {OutflowBudget}.
    error OutflowLimitTooLarge(uint256 limit);
    /// @dev The order does not pay out exactly one token and take in exactly one
    ///      other token — the only shape a fill route can price.
    error UnsupportedFillShape();
    /// @dev No owner-configured fill route for `spent → received`.
    error FillRouteNotAllowed(address spent, address received);
    /// @dev A fill realised less than the route's owner-set minimum rate.
    error FillRateTooLow(uint256 received, uint256 spent, uint256 minRateWad);
    /// @dev A fill paid out more than the operator's own `maxSpent` bound — the
    ///      price moved maker-ward between the operator's quote and inclusion
    ///      (priority bump, price module, descending curve).
    error SpentAboveOperatorBound(uint256 spent, uint256 maxSpent);
    /// @dev MoC's queue executed DURING a measured window (`sell`'s venue call or a
    ///      fill). Queue execution pays this contract synchronously — RIF for a
    ///      successful redemption, the escrowed USDRIF back for a failed one — and
    ///      is permissionless through `MocMultiCollateralGuard.execute()`. Any party
    ///      with code execution inside the window (a hook token on the venue path, a
    ///      maker item) could otherwise land this contract's OWN proceeds inside the
    ///      balance deltas and have them counted as consideration: a `sell` whose
    ///      spend nets to zero escapes the rate floor and the window budget, a fill
    ///      whose `got` is a refund escapes {fillMinRate}. Honest windows never run
    ///      the queue, so refusing costs no liveness (audit 2026-09-30 RIF-1/RIF-2).
    error QueueMovedDuringMeasurement();
    /// @dev {onSettlementFill} called by anyone but the EXECUTOR.
    error OnlyExecutor();
    /// @dev {onSettlementFill} outside a delta-verify fill this contract started.
    error NotArmed();

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OperatorSet(address indexed operator, bool allowed);
    event AggregatorSet(address indexed aggregator, bool allowed);
    event MaxOutflowSet(address indexed token, uint256 cap);
    event FillRouteSet(address indexed spent, address indexed received, uint256 minRateWad);
    event OutflowLimitSet(address indexed token, uint256 limit);
    event SellRouteSet(address indexed tokenIn, address indexed tokenOut, uint256 minRateWad, uint256 maxAmountIn);
    event RedemptionInitiated(uint256 indexed opId, uint256 qTP, uint256 qACmin, uint256 execFee);
    event Sold(
        address indexed aggregator,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyOperator() {
        if (!operators[msg.sender] && msg.sender != owner) revert NotOperator();
        _;
    }

    /// @param initialAggregator First whitelisted conversion venue (e.g. the
    ///                          Uniswap v3 SwapRouter02); more via `setAggregator`.
    ///                          Subject to the same refusals as `setAggregator`.
    ///                          No sell route exists yet — `sell` is closed until
    ///                          the owner calls `setSellRoute`.
    /// @param usdt0 The inventory token paid out on fills — approved to
    ///              Settlement (via Permit3) once here; further inventory
    ///              tokens can be added later with `setupTokenApproval`.
    constructor(
        address _permit3,
        address _settlement,
        address initialAggregator,
        address _mocCore,
        address _mocQueue,
        address _usdrif,
        address usdt0
    ) {
        permit3 = IPermit3(_permit3);
        settlement = Settlement(_settlement);
        mocCore = IMocRifCore(_mocCore);
        mocQueue = IMocQueueFees(_mocQueue);
        usdrif = _usdrif;
        EXECUTOR = address(Settlement(_settlement).EXECUTOR());
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
        isKnownToken[_usdrif] = true;
        _approveSettlementPull(usdt0);
        _setAggregator(initialAggregator, true);
    }

    /// @dev RBTC float for MoC exec fees (and any native refunds MoC sends back).
    receive() external payable {}

    // ──────────────────── Fill side (atomic) ────────────────────

    /// @notice Fill a maker order against this contract's inventory. A plain
    ///         order has Settlement pull the output tokens from this contract via
    ///         Permit3; a delta-verify order (`timing` bit 104) is delivered by this
    ///         contract's own callback ({onSettlementFill}) and must name it as
    ///         `exclusiveFiller`. Either way the maker's input tokens land here.
    /// @param maxSpent The OPERATOR's price bound: the most of the output token
    ///        this fill may move out of inventory (measured). Quote it from the
    ///        price you evaluated; `type(uint256).max` = no operator bound (the
    ///        owner's {fillMinRate} still applies). It exists because the strict
    ///        `fill` carries no price floor, and a maker who controls the order's
    ///        pricing (priority bump, price module, descending curve) can move the
    ///        price maker-ward between the quote and inclusion — down to the
    ///        owner's floor (audit 2026-09-30 PERIPH-1.v2).
    function executeFill(Order calldata order, bytes calldata sig, uint256 fillAmountIn, uint256 maxSpent)
        external
        onlyOperator
        returns (uint256[] memory paid)
    {
        paid = _fillCapped(order, sig, fillAmountIn, maxSpent);
    }

    /// @notice Fill a USDRIF→USDT0 order and, in the same transaction, escrow
    ///         the ENTIRE resulting USDRIF balance into a MoC redemption — the
    ///         solver's long-USDRIF window is zero; only the RIF leg (queue
    ///         execution → `sell`) carries market exposure.
    /// @param maxSpent See {executeFill}.
    /// @param qACmin Floor on the RIF the redemption may deliver (MoC-enforced;
    ///               the op errors and refunds the USDRIF if the price moves below it).
    function executeFillAndRedeem(
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmountIn,
        uint256 maxSpent,
        uint256 qACmin
    ) external onlyOperator returns (uint256[] memory paid, uint256 opId) {
        paid = _fillCapped(order, sig, fillAmountIn, maxSpent);
        opId = _initiateRedemption(IERC20(usdrif).balanceOf(address(this)), qACmin);
    }

    /// @dev Run the fill and enforce, on MEASURED balance deltas rather than on
    ///      what the order claims: the pair is an owner-configured fill route, the
    ///      received amount meets its minimum rate against the spent amount, the
    ///      spend is within the operator's `maxSpent`, within {maxOutflowPerFill}
    ///      for this call and within {OutflowBudget} for the window.
    ///
    ///      The one-token-each-way, item-free shape is what makes two balance reads
    ///      a complete measurement: Settlement pulls from its filler ONLY to deliver
    ///      `legsOut` (or this contract's own callback pays them, on a delta-verify
    ///      order), so with every output leg in `spent`, nothing else this contract
    ///      holds can move; and every input leg pays `received`, so the whole
    ///      consideration is one delta. Fee legs to third parties in the same token
    ///      count as spend.
    ///
    ///      ⚠ THE MEASUREMENT MUST BE EXCLUSIVE. A balance delta only measures the
    ///      fill if nothing else pays this contract during it. Two things could:
    ///      a maker-signed ITEM (an arbitrary module CALL inside `settlement.fill`)
    ///      — refused in {_fillPair} — and MoC's queue, which anyone can execute
    ///      and which pays this contract its own redemption proceeds or refunds —
    ///      refused by the `firstOperId` bracket below (audit 2026-09-30 RIF-2).
    function _fillCapped(Order calldata order, bytes calldata sig, uint256 fillAmountIn, uint256 maxSpent)
        private
        returns (uint256[] memory paid)
    {
        (address spent, address received) = _fillPair(order);
        uint256 rate = fillMinRate[spent][received];
        if (rate == 0) revert FillRouteNotAllowed(spent, received);

        uint256 spentBefore = IERC20(spent).balanceOf(address(this));
        uint256 receivedBefore = IERC20(received).balanceOf(address(this));
        paid = _settle(order, sig, fillAmountIn, spent);

        uint256 spentNow = IERC20(spent).balanceOf(address(this));
        uint256 movedOut = spentBefore > spentNow ? spentBefore - spentNow : 0;
        // Checked: a net DECREASE of the received token is not a fill of this pair.
        uint256 got = IERC20(received).balanceOf(address(this)) - receivedBefore;

        if (movedOut > maxSpent) revert SpentAboveOperatorBound(movedOut, maxSpent);
        uint256 cap = maxOutflowPerFill[spent];
        if (movedOut > cap) revert OutflowCapExceeded(spent, movedOut, cap);
        if (got * WAD < movedOut * rate) revert FillRateTooLow(got, movedOut, rate);
        _spendWindow(spent, movedOut);
    }

    /// @dev The settlement call itself, bracketed by the MoC queue head (see the ⚠
    ///      on {_fillCapped}). Its own frame for the stack limit.
    function _settle(Order calldata order, bytes calldata sig, uint256 fillAmountIn, address spent)
        private
        returns (uint256[] memory paid)
    {
        uint256 queueHead = mocQueue.firstOperId();
        if (DutchAuction.deltaVerifyOutputs(order)) {
            // Delivered by {onSettlementFill}: the core verifies each recipient's
            // balance delta, and only the named exclusive filler (this contract) may
            // run the callback — see the core's `_snapshotOutRecipients`.
            _deliveryArmed = 2;
            paid = settlement.fillWithCallback(
                order,
                sig,
                fillAmountIn,
                address(this),
                abi.encode(spent, _legRecipients(order)),
                CallbackMode.PreDeliveryTyped
            );
            // The callback is single-use and clears the flag itself; reset anyway so
            // a fill that somehow returned without it leaves nothing armed.
            _deliveryArmed = 1;
        } else {
            paid = settlement.fill(order, sig, fillAmountIn);
        }
        if (mocQueue.firstOperId() != queueHead) revert QueueMovedDuringMeasurement();
    }

    /// @notice Delivery callback for a delta-verify fill — pays each output leg its
    ///         PRICED amount, out of inventory, to the leg's recipient. Not public in
    ///         effect: only the EXECUTOR may call it, and only while {_fillCapped}
    ///         has armed it. Everything it moves is then measured by {_fillCapped}
    ///         exactly as a Permit3 pull would be (same `spent` token, same caps).
    function onSettlementFill(
        bytes32,
        uint256,
        uint256,
        uint256,
        uint256[] calldata,
        uint256[] calldata pricedOut,
        bytes calldata userData
    ) external {
        if (msg.sender != EXECUTOR) revert OnlyExecutor();
        if (_deliveryArmed != 2) revert NotArmed();
        _deliveryArmed = 1;
        (address token, address[] memory recipients) = abi.decode(userData, (address, address[]));
        for (uint256 j; j < pricedOut.length; ++j) {
            if (pricedOut[j] != 0) SafeTransferLib.safeTransfer(token, recipients[j], pricedOut[j]);
        }
    }

    /// @dev Each output leg's resolved recipient (`address(0)` = the maker), in leg
    ///      order — the destinations the core will measure. Called after
    ///      {_fillPair} validated the blob.
    function _legRecipients(Order calldata order) private pure returns (address[] memory r) {
        bytes memory legsOut = order.legsOut;
        uint256 n = PackedArraysMem.validateLegsOut(legsOut);
        r = new address[](n);
        for (uint256 j; j < n; ++j) {
            address to = PackedArraysMem.legOutRecipient(legsOut, j);
            r[j] = to == address(0) ? order.maker : to;
        }
    }

    /// @dev The single token every `legsOut` pays and the single token every
    ///      `legsIn` pays, which must differ — and NO items: a maker-signed item is
    ///      an arbitrary module call inside the measured fill (audit 2026-09-30 RIF-2).
    function _fillPair(Order calldata order) private pure returns (address spent, address received) {
        if (PackedArrays.countUnchecked(order.items) != 0) revert UnsupportedFillShape();
        bytes memory legsOut = order.legsOut;
        bytes memory legsIn = order.legsIn;
        uint256 nOut = PackedArraysMem.validateLegsOut(legsOut);
        uint256 nIn = PackedArraysMem.validateLegsIn(legsIn);
        if (nOut == 0 || nIn == 0) revert UnsupportedFillShape();
        spent = PackedArraysMem.legOutToken(legsOut, 0);
        for (uint256 j = 1; j < nOut; ++j) {
            if (PackedArraysMem.legOutToken(legsOut, j) != spent) revert UnsupportedFillShape();
        }
        received = PackedArraysMem.legInToken(legsIn, 0);
        for (uint256 i = 1; i < nIn; ++i) {
            if (PackedArraysMem.legInToken(legsIn, i) != received) revert UnsupportedFillShape();
        }
        if (spent == received) revert UnsupportedFillShape();
    }

    /// @dev Charge `amount` of `token` to the current {OUTFLOW_WINDOW}.
    function _spendWindow(address token, uint256 amount) private {
        if (amount == 0) return;
        uint64 start = uint64(block.timestamp - (block.timestamp % OUTFLOW_WINDOW));
        OutflowBudget memory b = outflowBudget[token];
        uint256 wouldUse = (b.start == start ? uint256(b.used) : 0) + amount;
        if (wouldUse > b.limit) revert OutflowWindowExceeded(token, wouldUse, b.limit);
        // `wouldUse <= limit < 2^96`, so the narrowing is exact.
        outflowBudget[token] = OutflowBudget(start, uint96(wouldUse), b.limit);
    }

    // ──────────────────── Conversion handlers (async recycle) ────────────────────

    /// @notice Queue a MoC USDRIF→RIF redemption to this contract. The exec fee
    ///         (`execCost × block.basefee`) is computed in-tx and funded from this
    ///         contract's RBTC balance (top up via `msg.value` or `receive`).
    /// @param qTP USDRIF amount to redeem; `type(uint256).max` = full balance.
    function initiateRedemption(uint256 qTP, uint256 qACmin) external payable onlyOperator returns (uint256 opId) {
        if (qTP == type(uint256).max) qTP = IERC20(usdrif).balanceOf(address(this));
        opId = _initiateRedemption(qTP, qACmin);
    }

    /// @notice Swap held tokens through a whitelisted venue along an
    ///         owner-configured route (`sellRoutes[tokenIn][tokenOut]`) — the
    ///         RIF→USDT0 recycle leg, a direct USDRIF→USDT0 dump, or any
    ///         aggregator route the owner has priced. The venue's calldata is
    ///         opaque to this contract, so every check is enforced HERE by
    ///         balances:
    ///           - the venue can pull at most `min(amountIn, route.maxAmountIn)`
    ///             of `tokenIn` (allowance granted just-in-time, revoked after);
    ///           - the measured `spent` must stay within that allowance;
    ///           - the measured `tokenOut` gain must satisfy the route's
    ///             `minRateWad` against `spent` AND the operator's `minOut`.
    ///         A lying or buggy venue cannot under-deliver, and calldata that
    ///         routes the proceeds anywhere but here (or into a token other than
    ///         `tokenOut`) fails the rate check. Chunk large RIF sales to respect
    ///         venue depth and the per-call budget.
    /// @param amountIn Allowance granted to the venue; `type(uint256).max` =
    ///                 `min(balance, route.maxAmountIn)`. An explicit amount above
    ///                 the budget reverts. The amount embedded in `data` governs
    ///                 the actual swap.
    /// @param minOut Operator's own absolute floor on the `tokenOut` gain —
    ///               applied on top of (never instead of) the route's rate.
    /// @param data Pre-built venue calldata routing tokenIn→tokenOut with this
    ///             contract as recipient. `msg.value` is forwarded for venues
    ///             that need native alongside.
    function sell(
        address aggregator,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        bytes calldata data
    ) external payable onlyOperator returns (uint256 amountOut) {
        if (!aggregators[aggregator]) revert AggregatorNotAllowed();
        SellRoute memory route = sellRoutes[tokenIn][tokenOut];
        if (route.minRateWad == 0) revert RouteNotAllowed(tokenIn, tokenOut);

        uint256 inBefore = IERC20(tokenIn).balanceOf(address(this));
        if (amountIn == type(uint256).max) {
            amountIn = inBefore < route.maxAmountIn ? inBefore : route.maxAmountIn;
        } else if (amountIn > route.maxAmountIn) {
            revert SellCapExceeded(tokenIn, amountIn, route.maxAmountIn);
        }
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

        _callVenue(aggregator, tokenIn, amountIn, data);

        // Checked subtractions: a net DECREASE of tokenOut or a net INCREASE of
        // tokenIn is not a sale and reverts (panic) rather than passing as 0.
        uint256 spent = inBefore - IERC20(tokenIn).balanceOf(address(this));
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        // Allowance already bounds the venue; re-checked because `spent` is a
        // balance delta and the budget is the invariant, not the approval.
        if (spent > amountIn) revert SellCapExceeded(tokenIn, spent, amountIn);
        if (amountOut * WAD < spent * route.minRateWad) revert RateTooLow(amountOut, spent, route.minRateWad);
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
        // The SAME window budget fills draw on — see {OutflowBudget}.
        _spendWindow(tokenIn, spent);
        emit Sold(aggregator, tokenIn, tokenOut, spent, amountOut);
    }

    /// @dev `sell`'s venue call: just-in-time allowance, the call, allowance cleared.
    ///      Its own frame for the stack limit under the legacy profile.
    ///
    ///      EXCLUSIVE WINDOW (audit 2026-09-30 RIF-1): `sell`'s deltas assume the venue
    ///      is the only thing that moves `tokenIn`/`tokenOut` during this call. MoC's
    ///      queue pays this contract its own RIF (or refunds USDRIF) whenever anyone
    ///      executes it — permissionlessly, via the guard — so a hook on the venue path
    ///      could land those proceeds inside the window: on the tokenIn side they net
    ///      the measured spend to zero (no rate floor, no window charge), on the
    ///      tokenOut side they pass as sale proceeds. The call is bracketed with the
    ///      queue head and refused if it moved.
    function _callVenue(address aggregator, address tokenIn, uint256 amountIn, bytes calldata data) private {
        uint256 queueHead = mocQueue.firstOperId();
        SafeTransferLib.forceApprove(tokenIn, aggregator, amountIn);
        (bool ok, bytes memory ret) = aggregator.call{value: msg.value}(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        SafeTransferLib.forceApprove(tokenIn, aggregator, 0);
        if (mocQueue.firstOperId() != queueHead) revert QueueMovedDuringMeasurement();
    }

    function _initiateRedemption(uint256 qTP, uint256 qACmin) internal returns (uint256 opId) {
        uint256 fee = mocQueue.getExecFee(OPER_REDEEM_TP);
        SafeTransferLib.forceApprove(usdrif, address(mocCore), qTP);
        // recipient == address(this) (MoC requires recipient == msg.sender);
        // vendor 0 = no vendor markup.
        opId = mocCore.redeemTP{value: fee}(usdrif, qTP, qACmin, address(this), address(0));
        emit RedemptionInitiated(opId, qTP, qACmin, fee);
    }

    // ──────────────────── Custody / admin (owner) ────────────────────

    /// @notice Grant Settlement pull-rights (via Permit3) on `token`, enabling it
    ///         as fill inventory.
    ///         Refuses a whitelisted aggregator (see {isKnownToken}).
    function setupTokenApproval(address token) external onlyOwner {
        _approveSettlementPull(token);
    }

    /// @notice Whitelist (or revoke) a conversion venue callable from `sell`.
    ///         Whitelisting refuses zero, this contract, Permit3, Settlement, the
    ///         MoC core/queue and every {isKnownToken}: each would let operator
    ///         calldata act from this contract's identity outside the balance
    ///         deltas `sell` measures (e.g. Permit3 `approveToken`, a held
    ///         token's `transfer`). Revocation is always allowed.
    function setAggregator(address aggregator, bool allowed) external onlyOwner {
        _setAggregator(aggregator, allowed);
    }

    /// @notice Configure (or, with `minRateWad == 0`, close) the `sell` route
    ///         `tokenIn → tokenOut`. See {SellRoute} for units — the rate is in
    ///         raw token units, WAD-scaled, with NO decimal normalisation.
    ///         Both tokens become {isKnownToken}; neither may be an aggregator,
    ///         and a pair must be two distinct non-zero tokens.
    function setSellRoute(address tokenIn, address tokenOut, uint128 minRateWad, uint128 maxAmountIn)
        external
        onlyOwner
    {
        if (tokenIn == tokenOut) revert ForbiddenToken(tokenIn);
        _registerToken(tokenIn);
        _registerToken(tokenOut);
        sellRoutes[tokenIn][tokenOut] = SellRoute({minRateWad: minRateWad, maxAmountIn: maxAmountIn});
        emit SellRouteSet(tokenIn, tokenOut, minRateWad, maxAmountIn);
    }

    /// @notice Set the per-call inventory outflow budget for `token`. Owner-only —
    ///         operators cannot raise their own ceiling.
    function setMaxOutflowPerFill(address token, uint256 cap) external onlyOwner {
        maxOutflowPerFill[token] = cap;
        emit MaxOutflowSet(token, cap);
    }

    /// @notice Configure (or, with `minRateWad == 0`, close) the fill route
    ///         `spent → received`. See {fillMinRate} for units.
    function setFillRoute(address spent, address received, uint256 minRateWad) external onlyOwner {
        if (spent == received) revert ForbiddenToken(spent);
        _registerToken(spent);
        _registerToken(received);
        fillMinRate[spent][received] = minRateWad;
        emit FillRouteSet(spent, received, minRateWad);
    }

    /// @notice Set the per-window cumulative outflow budget for `token`, shared by
    ///         fills and `sell`. Owner-only. See {OutflowBudget}.
    function setOutflowLimit(address token, uint256 limit) external onlyOwner {
        // Refused, not capped: a ceiling the owner did not ask for is drift.
        if (limit > type(uint96).max) revert OutflowLimitTooLarge(limit);
        // Only the ceiling changes; what the current window already spent stays
        // spent, so lowering the limit mid-window cannot be dodged by a reset.
        outflowBudget[token].limit = uint96(limit);
        emit OutflowLimitSet(token, limit);
    }

    /// @notice The per-window outflow ceiling for `token` — see {OutflowBudget}.
    function outflowLimit(address token) external view returns (uint256) {
        return outflowBudget[token].limit;
    }

    function setOperator(address operator, bool allowed) external onlyOwner {
        operators[operator] = allowed;
        emit OperatorSet(operator, allowed);
    }

    /// @notice Step one of a two-step ownership handover. Nothing changes until
    ///         the nominee calls {acceptOwnership}, so a mistyped address cannot
    ///         strand custody. `address(0)` cancels a pending nomination.
    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    /// @notice Withdraw inventory / proceeds. `token == address(0)` withdraws RBTC.
    function withdraw(address token, uint256 amount, address to) external onlyOwner {
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            SafeTransferLib.safeTransfer(token, to, amount);
        }
    }

    /// @notice Escape hatch for conversion paths this contract doesn't hardcode
    ///         (multi-hop routes, OTC settlement, rescues). Owner-only.
    function execute(address target, bytes calldata data) external payable onlyOwner returns (bytes memory result) {
        bool ok;
        (ok, result) = target.call{value: msg.value}(data);
        if (!ok) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
    }

    function _setAggregator(address aggregator, bool allowed) internal {
        if (
            allowed
                && (aggregator == address(0)
                    || aggregator == address(this)
                    || aggregator == address(permit3)
                    || aggregator == address(settlement)
                    || aggregator == address(mocCore)
                    || aggregator == address(mocQueue)
                    || isKnownToken[aggregator])
        ) revert ForbiddenAggregator(aggregator);
        aggregators[aggregator] = allowed;
        emit AggregatorSet(aggregator, allowed);
    }

    function _registerToken(address token) internal {
        if (token == address(0) || aggregators[token]) revert ForbiddenToken(token);
        isKnownToken[token] = true;
    }

    function _approveSettlementPull(address token) internal {
        _registerToken(token);
        SafeTransferLib.forceApprove(token, address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), token, type(uint160).max, 0);
    }
}
