// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Settlement, Order, CallbackMode} from "../settlement/Settlement.sol";
import {SafeTransferLib} from "../utils/SafeTransferLib.sol";
import {PackedArrays} from "../settlement/PackedArrays.sol";

interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @title NativeSettler
/// @notice Periphery that lets a maker pay NATIVE currency into a WETH-denominated
///         order, self-settled in one transaction — WITHOUT any change to the
///         ERC20-only core (Settlement/Permit3 never touch native).
///
///         Flow (single-asset SELL, `tokenIn == WETH`): the maker calls this with
///         `msg.value` of native. We wrap it and hand the WETH to the maker so the
///         core's Permit3 pull (which always charges `order.maker`) can collect it
///         as the order's input. We then act as the FILLER of a PostInputs
///         `fillWithCallback`: the core pays us that WETH, the callback swaps it
///         into `tokenOut` on the frontend-supplied route, and Settlement delivers
///         `tokenOut` to the maker.
///
///         Native is thus handled entirely at the edge. Note the maker must
///         (a) sign the order and (b) have a standing Permit3 allowance on WETH to
///         Settlement (a one-time setup, like approving any router). Because the
///         input arrives as `msg.value`, the maker MUST be the caller — this entry
///         is not relayable for the input side (you cannot sign away native ETH).
///
///  Security: this contract MUST end every call holding ZERO balance and ZERO
///  standing approvals. That is load-bearing, not hygiene.
///
///  `order` is fully caller-controlled (anyone can sign an order naming themselves
///  as maker), so `order.legsOut[0].token` is an ATTACKER-CHOSEN address, and this
///  contract is the FILLER of the fill it starts. Settlement's `_deliverOutputs`
///  pulls output legs *from the filler*, falling back to a direct ERC20
///  `transferFrom` when the Permit3 leg fails. So any balance left here between
///  calls, plus any standing allowance granted to Settlement, is a free drain: the
///  attacker signs an order whose output leg names that token and amount with
///  themselves as recipient, and Settlement hands it over.
///
///  Four properties close it, and all four are required:
///    1. approvals are scoped to the maximum this fill can consume, never
///       `type(uint256).max`;
///    2. both approvals are reset to 0 before returning, so nothing stands;
///    3. every residual balance is swept to the maker, so a completed call never
///       leaves a balance behind for a later attacker-crafted order to name;
///    4. a BALANCE FLOOR — each touched token must end at or above what this
///       contract held on entry, else the call reverts.
///
///  (4) is the one that actually stops the attack, and (1)–(3) alone do NOT.
///  Scoping the approval to `legsOut[0].start` is useless on its own, because the
///  attacker simply signs `start` equal to the balance they want: the approval is
///  then "exactly enough" to hand over everything. Sweeping only helps balances
///  this contract creates, not ones donated by direct transfer. Only the floor
///  makes a pre-existing balance unreachable, so an attacker can reach nothing but
///  the funds they themselves supplied in the same transaction. This mirrors
///  Settlement's own `BatchNotWhole` guard and its "never spend a donated balance"
///  invariant.
///
/// @dev    The WETH round-trips (wrap → maker → pulled back to us) purely to satisfy
///         the core's "charge order.maker" invariant; a native-aware core could
///         skip it. Positive route slippage is swept to the MAKER (property 3) —
///         it is the maker's money, and leaving it here would be exploitable.
///         A balance donated by direct transfer stays put and is NOT recoverable
///         (there is no admin) — the same posture Settlement takes toward
///         donations, and the safe direction to err in.
contract NativeSettler {
    IWETH public immutable weth;
    Settlement public immutable settlement;

    error NotMaker();
    error TokenInNotWeth();
    /// @dev This entry settles exactly one output leg (it scopes a single approval
    ///      to `legsOut[0]`), so a multi-leg order would under-approve and fail
    ///      mid-delivery. Rejected up front instead.
    error SingleOutputLegRequired();
    /// @dev The fill ended with LESS of `token` than this contract held on entry —
    ///      it drew down a pre-existing balance instead of the proceeds the route
    ///      produced. This is the guard that defeats the self-signed-order drain
    ///      (see the contract-level security note); on the honest path the entry
    ///      balance is zero and the floor is trivially met.
    error PreexistingBalanceConsumed(address token);

    constructor(address _weth, address _settlement) {
        weth = IWETH(_weth);
        settlement = Settlement(_settlement);
    }

    /// @param order        maker == msg.sender; single-asset SELL with legsIn[0].token == WETH.
    /// @param sig           the maker's EIP-712 order signature.
    /// @param fillAmount    anchor units (legsIn[0]) to fill.
    /// @param dexTarget     the frontend's route target (invoked in the fill callback).
    /// @param dexCallData   route calldata; must pull our WETH and return `tokenOut` to us.
    function settleFromNative(
        Order calldata order,
        bytes calldata sig,
        uint256 fillAmount,
        address dexTarget,
        bytes calldata dexCallData
    ) external payable returns (uint256[] memory outs) {
        if (msg.sender != order.maker) revert NotMaker();
        if (PackedArrays.validateFixed(order.legsIn, PackedArrays.LEG_IN_STRIDE) != 1) revert TokenInNotWeth();
        if (PackedArrays.legInToken(order.legsIn, 0) != address(weth)) revert TokenInNotWeth();
        if (PackedArrays.validateFixed(order.legsOut, PackedArrays.LEG_OUT_STRIDE) != 1) {
            revert SingleOutputLegRequired();
        }

        (address tokenOut, uint256 outStart,,) = PackedArrays.legOut(order.legsOut, 0);

        // 0) Floor every touched token at what we hold right now, BEFORE anything
        //    moves, so the fill can only ever spend what it itself produces. Taken
        //    before the wrap, which nets to zero (deposit then transfer out).
        uint256 outFloor = SafeTransferLib.balanceOf(tokenOut, address(this));
        uint256 wethFloor = SafeTransferLib.balanceOf(address(weth), address(this));

        // 1) Wrap native → WETH and give it to the maker so the core can charge it.
        weth.deposit{value: msg.value}();
        weth.transfer(order.maker, msg.value);

        // 2) Scope both approvals to the exact maximum this fill can consume — never
        //    unbounded (see the contract-level security note). The route can spend at
        //    most the WETH the core pays us, which is `msg.value`. Settlement can pull
        //    at most `legsOut[0].start`: a SELL output decays DOWN from `start` and a
        //    BUY output is fixed at it, so `start` is the ceiling on either side.
        SafeTransferLib.forceApprove(address(weth), dexTarget, msg.value);
        SafeTransferLib.forceApprove(tokenOut, address(settlement), outStart);

        // 3) Self-settle as the filler.
        outs = settlement.fillWithCallback(order, sig, fillAmount, dexTarget, dexCallData, CallbackMode.PostInputs);

        // 4) Leave nothing standing, enforce the floor, and return what this call
        //    produced. A residual approval or a residual balance would be drainable
        //    by the next caller's self-signed order.
        SafeTransferLib.forceApprove(address(weth), dexTarget, 0);
        SafeTransferLib.forceApprove(tokenOut, address(settlement), 0);
        _settleResidual(tokenOut, outFloor, order.maker);
        // Skipped when tokenOut IS weth: the call above already settled that balance
        // against the same floor, and re-running it would compare against a stale one.
        if (tokenOut != address(weth)) _settleResidual(address(weth), wethFloor, order.maker);
    }

    /// @dev Enforce `token`'s balance floor and hand everything above it to `to`.
    ///      Reverts if the fill spent into the entry balance. Zero-guarded so a
    ///      strict token is never handed a no-op transfer.
    function _settleResidual(address token, uint256 floor, address to) private {
        uint256 bal = SafeTransferLib.balanceOf(token, address(this));
        if (bal < floor) revert PreexistingBalanceConsumed(token);
        unchecked {
            uint256 excess = bal - floor; // bal >= floor
            if (excess != 0) SafeTransferLib.safeTransfer(token, to, excess);
        }
    }
}
