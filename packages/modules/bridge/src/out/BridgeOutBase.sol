// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

import {CommitmentCodec} from "../CommitmentCodec.sol";

/// @title BridgeOutBase
/// @notice Shared scaffolding for the SOURCE side of a cross-chain order: a MAKE
///         module that pulls the maker's proceeds and hands them to a bridge,
///         carrying a {CommitmentCodec} commitment that names the destination
///         order.
///
///  Placement in the fill
///  ─────────────────────
///  A fill runs `deliverOutputs → items → payInputs`, so by the time an item
///  executes the solver has already delivered the order's outputs to the maker.
///  A cross-chain order is therefore an ordinary order plus one item: `legsOut[0]`
///  delivers the bridgeable token to the maker, and this module immediately pulls
///  it back through Permit3 and bridges it. No settlement changes, no new
///  callback, no special fill entrypoint.
///
///  Trust model — identical to {GenericCallModule}'s, and for the same reasons:
///    1. `msg.sender == SETTLEMENT`. Settlement only dispatches items whose
///       `(module, amount, data)` sit inside the maker's signed order hash, so
///       this gate is what makes the maker's signature the authority over the
///       bridge parameters. Without it, anyone could call `makeOnBehalf(victim,
///       …)` and bridge a victim's funds to a destination of their choosing.
///    2. The maker's Permit3 allowance to THIS module caps what a fill can move.
///       The module holds no settlement allowances and is nobody's Permit3
///       spender, so it can never reach beyond that per-module cap.
///
///  Partial fills
///  ─────────────
///  Settlement scales `amount` pro-rata, so a partially-filled source order
///  bridges in slices that all name the same destination order hash; the inbox
///  accumulates them. Derived floors (relay fee, slippage) are computed from the
///  slice, and because each rounds its deduction DOWN the slices always sum to at
///  least the whole-order floor — a partially-bridged order can still reach its
///  destination anchor. Bridge fees are per-message, though, so pinning the
///  source order to `FullFillModule` is usually the right call.
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

    /// @dev The guaranteed-delivery floor the destination order must be authored
    ///      against: `amount` less a maker-signed proportional allowance for the
    ///      bridge's fee or slippage. The deduction rounds DOWN, so the floor
    ///      rounds up — which is the direction that keeps summed partial bridges
    ///      at or above the whole-order floor.
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
    ///  costs the maker at most one destination-decimal unit — dust by
    ///  construction, since the case only arises when the destination is the
    ///  coarser denomination.
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
    function _sweep(address token, address to) internal {
        uint256 left = SafeTransferLib.balanceOf(token, address(this));
        if (left != 0) SafeTransferLib.safeTransfer(token, to, left);
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
