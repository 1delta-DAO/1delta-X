// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

import {BridgeOutBase} from "./BridgeOutBase.sol";
import {IAcrossSpokePool} from "../vendor/IAcross.sol";

/// @title AcrossBridgeOutModule
/// @notice Source-side MAKE module that deposits a fill's proceeds into Across,
///         addressed to the destination {BridgedOrderInbox} and carrying the
///         commitment that names the destination order.
///
///  Across is the simplest of the three supported paths:
///    • no native messaging fee — the relayer is paid out of the token amount, so
///      this module never needs an ETH balance;
///    • tokens and message arrive together in the relayer's fill transaction, so
///      the destination can never end up holding unattributed funds;
///    • `outputAmount` is exact and enforced, which makes it a perfect
///      guaranteed-delivery floor for the destination order's input leg.
///
///  Pricing
///  ───────
///  Across relay fees are quoted off-chain, and an item receives no filler-
///  supplied data (`makeOnBehalf` takes only the maker-signed `data`), so the
///  live quote cannot reach this module. The maker instead signs a BOUND —
///  `maxRelayFeeBps` — and the module derives `outputAmount` from it. The failure
///  mode is benign in both directions: too generous and the maker overpays a
///  little; too tight and no relayer takes the deposit, which then refunds to the
///  maker on this chain after `fillDeadline`.
contract AcrossBridgeOutModule is BridgeOutBase {
    IAcrossSpokePool public immutable SPOKE_POOL;

    /// @param inputToken        Token pulled from the maker on THIS chain.
    /// @param outputToken       Token the relayer delivers on the destination.
    /// @param dstChainId        Destination chain.
    /// @param dstRecipient      The Across recipient: either the shared
    ///                          {BridgedOrderInbox} (commitment-authorised) or the
    ///                          user's {PositionFunnel} (owner-signed). Set
    ///                          `dstOrderHash` to zero for the latter and the
    ///                          deposit carries no message at all.
    /// @param exclusiveRelayer  Optional exclusive relayer; `address(0)` = open.
    /// @param maxRelayFeeBps    Maker-signed ceiling on the relay fee. Determines
    ///                          `outputAmount`, which MUST equal the destination
    ///                          order's `legsIn[0].start` for a full fill.
    /// @param dstScalingFactor  `destinationDecimals - sourceDecimals` for this
    ///                          token pair; `0` when they match, which is the
    ///                          common case. Across enforces `outputAmount` in the
    ///                          DESTINATION token's decimals, so a pair that
    ///                          differs (USDT 6/18, WBTC 8/18) is silently wrong
    ///                          by a power of ten without it — see
    ///                          {BridgeOutBase._scaleToDest}.
    /// @param fillDeadlineOffset Seconds from now the relayer has to fill. After
    ///                          it lapses the deposit refunds to the maker here.
    /// @param exclusivityOffset Seconds of exclusivity; ignored when there is no
    ///                          exclusive relayer.
    /// @param dstOrderHash      The destination order this deposit funds.
    /// @param beneficiary       Destination-chain refund target if that order
    ///                          never fills.
    /// @param commitmentExpiry  Unix time after which the inbox may refund even if
    ///                          no order ever activated.
    struct AcrossSpec {
        address inputToken;
        address outputToken;
        uint256 dstChainId;
        address dstRecipient;
        address exclusiveRelayer;
        uint16 maxRelayFeeBps;
        int8 dstScalingFactor;
        uint32 fillDeadlineOffset;
        uint32 exclusivityOffset;
        bytes32 dstOrderHash;
        address beneficiary;
        uint32 commitmentExpiry;
    }

    constructor(address permit3, address settlement, address spokePool) BridgeOutBase(permit3, settlement) {
        SPOKE_POOL = IAcrossSpokePool(spokePool);
    }

    /// @inheritdoc IMakerModule
    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override onlySettlement {
        AcrossSpec memory s = abi.decode(data, (AcrossSpec));
        _checkDestination(s.dstRecipient, s.dstChainId);

        _pull(onBehalfOf, s.inputToken, amount);
        SafeTransferLib.forceApprove(s.inputToken, address(SPOKE_POOL), amount);
        _deposit(s, onBehalfOf, amount);
        SafeTransferLib.forceApprove(s.inputToken, address(SPOKE_POOL), 0);
        _sweep(s.inputToken, onBehalfOf);
    }

    /// @dev The deposit itself, in its own frame: `depositV3` takes twelve
    ///      arguments and the legacy codegen runs out of stack if they are pushed
    ///      alongside the caller's locals.
    ///
    ///      `depositor` is the MAKER, not this module — it is the refund recipient
    ///      if the deposit expires unfilled, and a module-addressed refund would
    ///      need its own claim path to get back to the user.
    ///
    ///      ORDER OF OPERATIONS: the relay-fee bound is applied in SOURCE units and
    ///      the result is then converted to destination decimals. Doing it the
    ///      other way would round twice and, on a shrinking conversion, let the
    ///      rounding eat into the fee allowance rather than the delivered amount.
    function _deposit(AcrossSpec memory s, address depositor, uint256 amount) private {
        uint32 nowTs = uint32(block.timestamp);
        SPOKE_POOL.depositV3(
            depositor,
            s.dstRecipient,
            s.inputToken,
            s.outputToken,
            amount,
            _scaleToDest(_floorAfterBps(amount, s.maxRelayFeeBps), s.dstScalingFactor),
            s.dstChainId,
            s.exclusiveRelayer,
            nowTs, // quoteTimestamp: now, so the LP fee prices at execution
            nowTs + s.fillDeadlineOffset,
            s.exclusiveRelayer == address(0) ? 0 : nowTs + s.exclusivityOffset,
            _commitment(s.dstOrderHash, s.beneficiary, s.dstChainId, s.commitmentExpiry)
        );
    }
}
