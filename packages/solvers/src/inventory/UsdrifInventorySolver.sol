// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedArraysMem} from "@core/settlement/PackedArraysMem.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {Settlement, Order} from "@core/settlement/Settlement.sol";

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
}

/// @title UsdrifInventorySolver
/// @notice Inventory-funded filler for direct USDRIF→USDT0 exit orders on
///         Rootstock, plus the async machinery that recycles the received
///         USDRIF back into USDT0 via MoC's native redemption.
///
///  The flash family fills from borrowed capital inside one atomic tx. That is
///  impossible here: MoC redemption is queued — the RIF only exists ~30–90s
///  after `redeemTP`, once the guard-gated executor drains the queue — so the
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
///    2. settle (async):   MoC's executor delivers RIF to this contract.
///    3. recycle (atomic): an operator `sell`s the RIF → USDT0 through an
///                         owner-whitelisted venue (Uniswap v3 router, an
///                         aggregator, …) with the output floor enforced here
///                         by balance delta — venue-agnostic slippage safety.
///
///  Trust model: unlike `BaseFlashSolver`, this contract HOLDS FUNDS between
///  fills (USDT0 inventory, in-flight USDRIF/RIF, an RBTC float for MoC exec
///  fees), so every state-changing entrypoint is owner- or operator-gated.
///  Fill-pricing judgment lives off-chain with the operator; the maker's
///  protection is the settlement-enforced amountOut floor, exactly as with any
///  other filler. Redemption ops are tracked off-chain via the
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

    address public owner;
    mapping(address => bool) public operators;
    /// @dev Owner-whitelisted conversion venues callable from `sell`. The
    ///      whitelist is what keeps `sell` operator-grade: without it an
    ///      operator could call ANY contract (e.g. Permit3) with crafted
    ///      calldata from this contract's identity.
    mapping(address => bool) public aggregators;

    /// @notice Per-token ceiling on how much inventory ONE `executeFill` call may
    ///         pay out. Owner-set; **0 means no outflow is permitted**, so a fresh
    ///         deployment fails closed until the owner configures a budget.
    ///
    ///  Why this exists: `executeFill` takes an ARBITRARY `(order, sig)` and makes
    ///  this contract the filler while it holds a `type(uint160).max` Permit3
    ///  allowance to Settlement on every inventory token. Without a bound, an
    ///  operator — explicitly a lower trust tier than owner, which is the whole
    ///  reason `sell` has an aggregator whitelist — could sign their own order with
    ///  `legsOut[0]` set to the entire inventory and take 100% of it in one call,
    ///  paying a token amount in. That made the operator tier owner-equivalent,
    ///  contradicting the contract's stated design.
    ///
    ///  This does not make a compromised operator key harmless — they can still
    ///  loop calls across blocks. It bounds the loss per call and gives the owner a
    ///  revocation window, which is the difference between "instant total loss" and
    ///  "a drain the owner can interrupt". Eliminating it entirely needs an
    ///  order-shape allowlist, not a cap.
    mapping(address => uint256) public maxOutflowPerFill;

    error NotOwner();
    error NotOperator();
    error NativeTransferFailed();
    error TransferFailed();
    error AggregatorNotAllowed();
    error InsufficientOutput(uint256 amountOut, uint256 minOut);
    /// @dev One `executeFill` moved more of `token` out of inventory than the
    ///      owner-set per-call budget allows.
    error OutflowCapExceeded(address token, uint256 attempted, uint256 cap);

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OperatorSet(address indexed operator, bool allowed);
    event AggregatorSet(address indexed aggregator, bool allowed);
    event MaxOutflowSet(address indexed token, uint256 cap);
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
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
        aggregators[initialAggregator] = true;
        emit AggregatorSet(initialAggregator, true);
        _approveSettlementPull(usdt0);
    }

    /// @dev RBTC float for MoC exec fees (and any native refunds MoC sends back).
    receive() external payable {}

    // ──────────────────── Fill side (atomic) ────────────────────

    /// @notice Fill a maker order against this contract's inventory. Settlement
    ///         pulls the output tokens from this contract via Permit3 and
    ///         delivers the maker's input tokens here.
    function executeFill(Order calldata order, bytes calldata sig, uint256 fillAmountIn)
        external
        onlyOperator
        returns (uint256[] memory paid)
    {
        paid = _fillCapped(order, sig, fillAmountIn);
    }

    /// @notice Fill a USDRIF→USDT0 order and, in the same transaction, escrow
    ///         the ENTIRE resulting USDRIF balance into a MoC redemption — the
    ///         solver's long-USDRIF window is zero; only the RIF leg (queue
    ///         execution → `sell`) carries market exposure.
    /// @param qACmin Floor on the RIF the redemption may deliver (MoC-enforced;
    ///               the op errors and refunds the USDRIF if the price moves below it).
    function executeFillAndRedeem(Order calldata order, bytes calldata sig, uint256 fillAmountIn, uint256 qACmin)
        external
        onlyOperator
        returns (uint256[] memory paid, uint256 opId)
    {
        paid = _fillCapped(order, sig, fillAmountIn);
        opId = _initiateRedemption(IERC20(usdrif).balanceOf(address(this)), qACmin);
    }

    /// @dev Run the fill and enforce {maxOutflowPerFill} on every token this order
    ///      pays out. Measured as a balance delta rather than read off the order,
    ///      so a hostile order cannot understate what it moves.
    function _fillCapped(Order calldata order, bytes calldata sig, uint256 fillAmountIn)
        private
        returns (uint256[] memory paid)
    {
        uint256 n = PackedArraysMem.validateLegsOut(order.legsOut);
        uint256[] memory before = new uint256[](n);
        for (uint256 j; j < n; ++j) {
            before[j] = IERC20(PackedArraysMem.legOutToken(order.legsOut, j)).balanceOf(address(this));
        }

        paid = settlement.fill(order, sig, fillAmountIn);

        for (uint256 j; j < n; ++j) {
            address token = PackedArraysMem.legOutToken(order.legsOut, j);
            uint256 nowBal = IERC20(token).balanceOf(address(this));
            if (nowBal < before[j]) {
                uint256 movedOut = before[j] - nowBal;
                uint256 cap = maxOutflowPerFill[token];
                if (movedOut > cap) revert OutflowCapExceeded(token, movedOut, cap);
            }
        }
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

    /// @notice Swap held tokens through a whitelisted venue — the RIF→USDT0
    ///         recycle leg, a direct USDRIF→USDT0 dump, or any aggregator route.
    ///         The venue's calldata is opaque to this contract, so the checks the
    ///         Uni-v3-only version delegated to the router are enforced HERE by
    ///         balances: the venue can pull at most `amountIn` of `tokenIn`
    ///         (allowance revoked after the call), and the call reverts unless
    ///         the measured `tokenOut` gain covers `minOut` — a lying or buggy
    ///         venue cannot under-deliver. Chunk large RIF sales to respect
    ///         venue depth.
    /// @param amountIn Allowance granted to the venue; `type(uint256).max` =
    ///                 full balance. The amount embedded in `data` governs the
    ///                 actual swap.
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
        if (amountIn == type(uint256).max) amountIn = IERC20(tokenIn).balanceOf(address(this));

        uint256 inBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 outBefore = IERC20(tokenOut).balanceOf(address(this));

        SafeTransferLib.forceApprove(tokenIn, aggregator, amountIn);
        (bool ok, bytes memory ret) = aggregator.call{value: msg.value}(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        SafeTransferLib.forceApprove(tokenIn, aggregator, 0);

        amountOut = IERC20(tokenOut).balanceOf(address(this)) - outBefore;
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
        emit Sold(aggregator, tokenIn, tokenOut, inBefore - IERC20(tokenIn).balanceOf(address(this)), amountOut);
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
    function setupTokenApproval(address token) external onlyOwner {
        _approveSettlementPull(token);
    }

    /// @notice Whitelist (or revoke) a conversion venue callable from `sell`.
    function setAggregator(address aggregator, bool allowed) external onlyOwner {
        aggregators[aggregator] = allowed;
        emit AggregatorSet(aggregator, allowed);
    }

    /// @notice Set the per-call inventory outflow budget for `token`. Owner-only —
    ///         operators cannot raise their own ceiling.
    function setMaxOutflowPerFill(address token, uint256 cap) external onlyOwner {
        maxOutflowPerFill[token] = cap;
        emit MaxOutflowSet(token, cap);
    }

    function setOperator(address operator, bool allowed) external onlyOwner {
        operators[operator] = allowed;
        emit OperatorSet(operator, allowed);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
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

    function _approveSettlementPull(address token) internal {
        SafeTransferLib.forceApprove(token, address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), token, type(uint160).max, 0);
    }
}
