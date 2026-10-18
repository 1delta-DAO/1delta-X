// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";

import {CommitmentCodec} from "../CommitmentCodec.sol";

/// @title BridgeOutBase
/// @notice Shared scaffolding for the SOURCE side of a cross-chain order: a MAKE
///         module that pulls the maker's proceeds and hands them to a bridge,
///         carrying a {CommitmentCodec} commitment that names the destination
///         order.
///
///  Placement in the fill — two funding forms
///  ──────────────────────────────────────────
///  A fill runs `deliverOutputs → items → payInputs`, so by the time an item
///  executes the solver has already delivered the order's outputs. A cross-chain
///  order is therefore an ordinary order plus one item, and the item is funded in
///  one of two ways, chosen by word 0 of its `data`:
///
///    PULL (`data = abi.encode(spec)`) — `legsOut[j]` delivers the bridgeable token
///      to the MAKER, and this module draws it back through the maker's Permit3
///      token allowance to THIS module, then bridges it. The original shape; it
///      costs the maker a receive-side approval for a token they may never have
///      held (review 2026-10-18 M-5).
///
///    PRE-FUNDED (`data = abi.encode(forLegPreFund(j, token), spec)`) — `legsOut[j]`
///      is addressed to THIS MODULE, and the item bridges exactly what the core's
///      delivery ledger says was delivered there. `item.amount` is unread (the
///      core sizes the slice from `ctx.outs[j]`, {Base._forSlice}), the maker
///      grants nothing, and the tokens never transit the wallet. Admission is the
///      {PreFundModuleBase._gatePreFundMake} pair — `msg.sender == SETTLEMENT`
///      (the `onlySettlement` modifier) and {PreFundGuard.requireLegRef} — and the
///      body opens with {PreFundGuard.floorOf} on the asset it is about to move:
///      the core binds the leg's recipient and token to the DESCRIPTOR, the floor
///      binds the descriptor to the spec's `inputToken` and proves the delivery
///      landed here. Anything the bridge leaves unconsumed above that floor goes
///      back to the maker ({_sweep}); another order's in-flight delivery parked
///      on this singleton between a netted plan's DELIVER and ITEM steps sits
///      below the floor and is never spent.
///      ⚠ MAKE SEAM ONLY. The core sizes a pre-funded slice from the ledger only
///      for `ItemOp.MAKE`; on `SETTLE` the same blob would be sized from the
///      maker-signed `item.amount` against a delivery nothing bound, so
///      {LzOftBridgeOutModule.settle} refuses it ({PreFundNeedsMake}).
///
///  The two data spaces are disjoint at word 0: every pull spec opens with an
///  address (Across, CCTP) or an ABI offset (LayerZero's dynamic `LzSpec`), so
///  `>> 253 == 0`, while a pre-fund descriptor has `>> 253 == 5`
///  (`tools/check-module-shapes.py` rule 4 / `WORD0_EXEMPT`).
///
///  Trust model — identical to {GenericCallModule}'s, and for the same reasons:
///    1. `msg.sender == SETTLEMENT`. Settlement only dispatches items whose
///       `(module, amount, data)` sit inside the maker's signed order hash, so
///       this gate is what makes the maker's signature the authority over the
///       bridge parameters. Without it, anyone could call `makeOnBehalf(victim,
///       …)` and bridge a victim's funds to a destination of their choosing.
///    2. PULL: the maker's Permit3 allowance to THIS module caps what a fill can
///       move. PRE-FUNDED: the core-sized delivery does, under the balance floor.
///       The module holds no settlement allowances and is nobody's Permit3
///       spender, so it can never reach beyond either bound.
///
///  Partial fills
///  ─────────────
///  Settlement scales `amount` pro-rata, so a partially-filled source order
///  bridges in slices that all name the same destination order hash; the inbox
///  accumulates them. A proportional deduction (relay fee, slippage) rounds DOWN
///  per slice, so for THAT term the slices sum to at least the whole-order floor.
///
///  That is the whole of the guarantee, and it holds only for slices that are
///  actually DELIVERED (audit 2026-09-30 PRICE-2.v2 / X-ARITH-2):
///    • a decimal DOWN-scale (`dstScalingFactor < 0`) floors per slice, so N
///      slices can sum up to N-1 destination units below the whole-order floor;
///    • an Across slice whose relay-fee share cannot pay a relayer is never
///      relayed at all — it refunds to the maker on the origin chain after
///      `fillDeadline` and never reaches the destination.
///  Either leaves an inbox commitment below its `legsIn[0].start` anchor
///  (`Underfunded`), and the filler chooses the slices. So the Across module
///  REQUIRES a full fill (`totalAmount`, {FullFillGuard}) for every
///  inbox-committed deposit, and the LayerZero module does so for every
///  sponsored send (fees are per message). Bridge fees are per-message on every
///  path, so a maker-signed `totalAmount` is the right call elsewhere too.
///  On the PRE-FUNDED form the slice is the leg's delivery rather than a pro-rated
///  `item.amount`, so `totalAmount` is read as a floor there — see {_fullFillGate}.
abstract contract BridgeOutBase is IMakerModule {
    IPermit3 public immutable PERMIT3;
    address public immutable SETTLEMENT;

    /// @dev Sanity ceiling on any maker-signed proportional deduction. Not a
    ///      security boundary (the maker signs the value) — it catches a
    ///      mis-encoded spec that would otherwise gift the transfer away, and
    ///      keeps the floor subtraction trivially underflow-free.
    uint256 internal constant MAX_DEDUCTION_BPS = 2_000; // 20%
    uint256 internal constant BPS = 10_000;

    error OnlySettlement();
    error DeductionTooHigh();
    error ZeroAmount();
    error ChainIdTooLarge();
    error BadDestination();
    /// @dev A maker-signed decimal `scalingFactor` outside ±18. No real token pair
    ///      spans a wider ratio, so this is a mis-encoded spec, not an exotic route.
    error ScalingFactorOutOfRange();

    constructor(address permit3, address settlement) {
        PERMIT3 = IPermit3(permit3);
        SETTLEMENT = settlement;
    }

    modifier onlySettlement() {
        if (msg.sender != SETTLEMENT) revert OnlySettlement();
        _;
    }

    /// @dev Reject destination shapes that are wrong on every chain, for every
    ///      configuration. Deliberately NOT a registry: whether a given chain is
    ///      actually supported — the funnel factory deployed there, the endpoint id
    ///      matching the chain id — is a question only an off-chain preflight can
    ///      answer, and putting it on-chain would mean an owner who can censor
    ///      orders on a module that is otherwise ownerless and immutable.
    ///
    ///      What is left here is the set of encodings that can never be intentional:
    ///
    ///        recipient zero — Across and LayerZero would both deliver into the zero
    ///          address. Unrecoverable, and the only guard here that prevents a
    ///          total loss rather than an inconvenience.
    ///        chain id zero — a spec whose destination field was never populated.
    ///        chain id == this chain — bridging to yourself. Whatever the intent, it
    ///          is not this; catching it costs one comparison.
    function _checkDestination(address dstRecipient, uint256 dstChainId) internal view {
        if (dstRecipient == address(0)) revert BadDestination();
        if (dstChainId == 0 || dstChainId == block.chainid) revert BadDestination();
    }

    /// @dev Pull the funding token from the maker. Gated by the maker's Permit3
    ///      token allowance to this module.
    function _pull(address onBehalfOf, address token, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        PERMIT3.transferFrom(onBehalfOf, address(this), token, uint160(amount));
    }

    /// @dev Which funding form `data` is in: `true` = PRE-FUNDED (word 0 is a pre-fund
    ///      leg-reference descriptor, `>> 253 == 5`), `false` = PULL. The same
    ///      predicate as {Base._isPreFundDesc} — so the module's funding form and the
    ///      core's sizing rule are driven off one signed word and cannot disagree —
    ///      with the length test folded in, so a blob shorter than a word answers
    ///      PULL (the branch that cannot spend this module's balance) instead of
    ///      being classified from whatever calldata follows it.
    function _isPreFund(bytes calldata data) internal pure returns (bool r) {
        /// @solidity memory-safe-assembly
        assembly {
            r := and(gt(data.length, 31), eq(shr(253, calldataload(data.offset)), 5))
        }
    }

    /// @dev Bring this item's `amount` of `token` under the module's control and
    ///      return the floor the closing {_sweep} must not dip below.
    ///
    ///      PRE-FUNDED: nothing moves. {PreFundGuard.floorOf} asserts that the
    ///      descriptor's signed funding token IS `token` (the asset about to be
    ///      bridged) and that at least `amount` of it sits here on top of the
    ///      pre-delivery balance; the floor it returns is that pre-delivery balance.
    ///      Underflows — fails closed — on a leg addressed elsewhere or priced in
    ///      another token. The caller must already have pinned the dispatcher and
    ///      the descriptor ({PreFundGuard.requireLegRef}).
    ///      PULL: snapshot first, then draw `amount` from the maker's wallet.
    function _fundIn(address onBehalfOf, address token, uint256 amount, bytes calldata data, bool preFund)
        internal
        returns (uint256 floor)
    {
        if (preFund) {
            if (amount == 0) revert ZeroAmount();
            return PreFundGuard.floorOf(data, token, amount);
        }
        // Snapshot before the pull — see {_sweep}: the sweep must return only what
        // THIS fill brought in, never a balance that was already resident.
        floor = _floorOf(token);
        _pull(onBehalfOf, token, amount);
    }

    /// @dev Full-fill gate driven by a maker-signed `totalAmount` in the spec.
    ///      `required` forces it (an absent total then fails closed); otherwise a
    ///      zero total means "partial slices allowed".
    ///
    ///      PRE-FUNDED reads `totalAmount` as a FLOOR (`amount >= totalAmount`), not an
    ///      equality. There `amount` is the leg's actual delivery, which a decaying
    ///      output leg prices anywhere in `[end, start]`; an equality would make
    ///      every auction-priced full fill revert. What the gate protects — that ONE
    ///      message carries at least the whole-order figure the destination anchor
    ///      and the per-message fee were authored against — is exactly `>=`. A
    ///      partial fill that already meets it is harmless (the bridge carries the
    ///      whole floor); the remainder then cannot meet it and never fills.
    function _fullFillGate(uint256 amount, uint256 totalAmount, bool required, bool preFund) internal pure {
        if (!required && totalAmount == 0) return;
        if (preFund) {
            if (amount < totalAmount || totalAmount == 0) {
                revert FullFillGuard.PartialFillUnsupported(amount, totalAmount);
            }
        } else {
            FullFillGuard.requireFullFill(amount, totalAmount);
        }
    }

    /// @dev The guaranteed-delivery floor the destination order must be authored
    ///      against: `amount` less a maker-signed proportional allowance for the
    ///      bridge's fee or slippage. The deduction rounds DOWN, so the floor
    ///      rounds up — which is the direction that keeps summed partial bridges
    ///      at or above the whole-order floor for THIS term (see the contract
    ///      note for the terms it does not cover).
    function _floorAfterBps(uint256 amount, uint256 bps) internal pure returns (uint256) {
        if (bps > MAX_DEDUCTION_BPS) revert DeductionTooHigh();
        return amount - (amount * bps) / BPS;
    }

    /// @dev Convert a SOURCE-decimal amount into DESTINATION decimals.
    ///
    ///      `scalingFactor` is `destinationDecimals - sourceDecimals`, signed, and
    ///      maker-signed. Zero — the overwhelmingly common case, and the only case
    ///      that existed before this — costs one comparison and returns unchanged.
    ///
    ///  ⚠ WHY THIS IS NOT OPTIONAL ONCE A ROUTE NEEDS IT
    ///  ────────────────────────────────────────────────
    ///  The destination floor a bridge enforces (`outputAmount` on Across, the
    ///  minted amount on CCTP) is denominated in the DESTINATION token's decimals,
    ///  while `amount` arrives here in the source token's. Where the two differ —
    ///  USDT is 6 decimals on Ethereum and 18 on BNB Chain, WBTC 8 in most places
    ///  and 18 in some — passing the source figure through unconverted does not
    ///  revert. It silently demands, or accepts, a floor wrong by a factor of
    ///  10^12. That is the whole reason this exists: the failure is not loud.
    ///
    ///      dest has MORE decimals (factor > 0) → MULTIPLY
    ///      dest has FEWER decimals (factor < 0) → DIVIDE, rounding DOWN
    ///
    ///  Rounding down is the safe direction and the deliberate one: the result is
    ///  a floor the bridge must MEET, so rounding up would demand more value than
    ///  the source amount is worth and leave the deposit unfillable. Rounding down
    ///  costs the maker at most one destination-decimal unit PER SLICE — dust by
    ///  construction, since the case only arises when the destination is the
    ///  coarser denomination, but enough to leave a whole-order anchor unmet when
    ///  a filler splits the order; hence the full-fill rule in the contract note.
    ///
    ///  The multiplying branch is CHECKED (no `unchecked`): a maker-signed factor
    ///  and a large amount can overflow, and this figure decides how much value a
    ///  fill moves. Reverting beats wrapping.
    function _scaleToDest(uint256 amount, int8 scalingFactor) internal pure returns (uint256) {
        if (scalingFactor == 0) return amount;
        // 10^18 is already the widest ratio any real token pair presents (18 vs 0).
        // Beyond it the multiply is certain to overflow for any meaningful amount,
        // so a larger factor is a mis-encoded spec rather than an exotic pair.
        if (scalingFactor > 18 || scalingFactor < -18) revert ScalingFactorOutOfRange();
        if (scalingFactor > 0) return amount * (10 ** uint256(uint8(scalingFactor)));
        return amount / (10 ** uint256(uint8(-scalingFactor)));
    }

    /// @dev Return anything the bridge did not consume to the maker — never to a
    ///      caller-chosen address — so the module ends every fill empty.
    /// @dev ⚠ `floor` IS NOT OPTIONAL. `token` comes from the maker-signed spec on a
    ///      shared singleton, so a whole-balance sweep hands any stray/donated
    ///      balance to whoever authors the next one-wei order. "The module ends every
    ///      fill EMPTY" is the wrong invariant — the right one is "ends where it
    ///      started", and that needs the floor.
    function _sweep(address token, address to, uint256 floor) internal {
        uint256 bal = SafeTransferLib.balanceOf(token, address(this));
        if (bal > floor) SafeTransferLib.safeTransfer(token, to, bal - floor);
    }

    /// @dev The pre-fill balance the matching {_sweep} must not dip below.
    function _floorOf(address token) internal view returns (uint256) {
        return SafeTransferLib.balanceOf(token, address(this));
    }

    /// @dev The 64-byte payload the destination {BridgedOrderInbox} reads — or
    ///      NOTHING, when `dstOrderHash` is zero.
    ///
    ///      The empty case is the {PositionFunnel} path. A funnel needs no
    ///      commitment: it is a user-owned account, so the destination order is
    ///      normally signed by that user and validated through the funnel's
    ///      EIP-1271, rather than authorised on-chain from a bridged hash. The
    ///      destination side then reduces to a plain transfer — an Across deposit
    ///      with no `message`, a LayerZero send with no `composeMsg`, and hence no
    ///      `lzCompose` and none of the orphan risk that path carries. It is also
    ///      cheaper: bridges charge by payload size.
    ///
    ///      The chain-id bound is checked rather than silently truncated: the
    ///      commitment packs it into 64 bits, and a wrapped value would name a
    ///      DIFFERENT chain than the one the bridge is actually sending to,
    ///      defeating the inbox's replay guard.
    function _commitment(bytes32 dstOrderHash, address beneficiary, uint256 dstChainId, uint32 expiry)
        internal
        pure
        returns (bytes memory)
    {
        if (dstOrderHash == bytes32(0)) return "";
        if (dstChainId > type(uint64).max) revert ChainIdTooLarge();
        return CommitmentCodec.encode(
            CommitmentCodec.Commitment({
                orderHash: dstOrderHash, beneficiary: beneficiary, dstChainId: uint64(dstChainId), expiry: expiry
            })
        );
    }
}
