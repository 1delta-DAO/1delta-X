// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

import {BridgeOutBase} from "./BridgeOutBase.sol";
import {ICctpTokenMessenger} from "../vendor/ICctp.sol";

/// @title CctpBridgeOutModule
/// @notice Source-side MAKE module that burns a fill's USDC proceeds through
///         Circle's CCTP for a 1:1 mint on the destination chain.
///
///  Why this path is worth having
///  ─────────────────────────────
///  Every other bridge in this package fronts liquidity and charges for it, so the
///  destination floor is always `amount` minus a maker-signed allowance for a fee
///  that cannot be known at signing time. CCTP v1 has no relayer, no LP and no
///  fee: the mint equals the burn exactly. The guaranteed-delivery floor is
///  therefore the amount itself — the tightest floor any path here can offer, and
///  the one where a destination order's `legsIn[0].start` can be authored with no
///  slack at all.
///
///  It is also the only path with no counterparty: nothing can be under-filled,
///  because nothing is fronting capital. The trade is latency (Circle's
///  attestation, typically minutes rather than seconds) and reach (USDC only, on
///  Circle-supported domains).
///
///  ⚠ FUNNEL PATH ONLY — NO COMMITMENT CAN BE CARRIED
///  ─────────────────────────────────────────────────
///  `depositForBurn` moves tokens and nothing else. There is no message field, so
///  this module CANNOT carry the {CommitmentCodec} payload that authorises a
///  destination order on the shared {BridgedOrderInbox}. Sending USDC to the inbox
///  over CCTP would deposit unattributed funds that no commitment ever claims.
///
///  So `dstRecipient` must be a {PositionFunnel} — a user-owned account whose
///  destination order is signed by that user and validated through the funnel's
///  EIP-1271, needing no on-chain commitment. `dstOrderHash` is not a field here
///  at all, rather than a field that must be zero: a parameter that may only ever
///  hold one value is a trap, and leaving it out makes the constraint unstateable
///  instead of merely documented.
///
///  Routing the inbox path over CCTP needs v2's hook variants
///  (`depositForBurnWithHook`), which is a different messenger ABI and a separate
///  module — not a flag on this one.
///
///  Trust model, partial fills and the `msg.sender == SETTLEMENT` gate are all
///  inherited unchanged from {BridgeOutBase}.
contract CctpBridgeOutModule is BridgeOutBase {
    ICctpTokenMessenger public immutable TOKEN_MESSENGER;

    /// @notice A burn was submitted to CCTP for minting on `dstDomain`.
    ///
    ///  ⚠ THIS EVENT IS THE ONLY LINK BETWEEN A BURN AND THE ORDER IT FUNDS, and
    ///  that is why it exists here and nowhere else in this package. The Across and
    ///  LayerZero paths carry a {CommitmentCodec} payload that names the
    ///  destination order on-chain, and the destination {BridgedOrderInbox} emits
    ///  `Credited` when it lands. CCTP carries no payload and has no destination
    ///  contract of ours, so without this event NOTHING on either chain records
    ///  which order a given burn is for.
    ///
    ///  `nonce` is Circle's message nonce — the key an indexer needs to pair this
    ///  burn with the attestation Circle later publishes, and hence to decide which
    ///  destination order becomes fillable. `recipient` is the funnel, which is what
    ///  an orderbook matches outstanding destination orders against.
    event CctpBurn(
        uint64 indexed nonce, uint32 indexed dstDomain, address indexed recipient, address token, uint256 amount
    );

    /// @dev `dstDomain` is Circle's domain id and `dstChainId` the EVM chain id.
    ///      They are unrelated numbering schemes, so both are carried: the domain
    ///      is what CCTP routes on, and the chain id is what
    ///      {BridgeOutBase._checkDestination} sanity-checks (non-zero, not this
    ///      chain). Dropping the chain id would lose that check entirely, since
    ///      domain 0 is Ethereum and therefore indistinguishable from "unset".
    /// @param inputToken       USDC on THIS chain — the burn token.
    /// @param dstChainId       Destination EVM chain id. Checked, not routed on.
    /// @param dstDomain        Circle domain id. THIS is what routes.
    /// @param dstRecipient     The user's {PositionFunnel} on the destination —
    ///                         see the funnel-only note above.
    ///
    /// ⚠ THERE IS NO `dstScalingFactor` HERE, AND THERE MUST NOT BE. Every other
    ///   path in this package names a destination amount separately from the
    ///   source amount, so the two can be denominated differently and a decimal
    ///   conversion belongs between them. CCTP does not: `depositForBurn` takes ONE
    ///   figure, burned here and minted there as the same number. Scaling it would
    ///   not convert anything — it would change how much is taken from the maker.
    ///
    ///   That the identity holds is Circle's guarantee, not an assumption of ours:
    ///   USDC is 6 decimals on every domain they support, which is why a single
    ///   figure is a coherent ABI in the first place. A route where it did not hold
    ///   would be broken inside CCTP, not fixable here.
    struct CctpSpec {
        address inputToken;
        uint256 dstChainId;
        uint32 dstDomain;
        address dstRecipient;
    }

    constructor(address permit3, address settlement, address tokenMessenger) BridgeOutBase(permit3, settlement) {
        TOKEN_MESSENGER = ICctpTokenMessenger(tokenMessenger);
    }

    /// @inheritdoc IMakerModule
    ///
    /// @dev No fee bound and no `_floorAfterBps`: CCTP mints exactly what it burns,
    ///      so there is nothing to allow for and the delivered amount IS `amount`.
    ///      No `_scaleToDest` either — see the note on {CctpSpec}.
    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override onlySettlement {
        CctpSpec memory s = abi.decode(data, (CctpSpec));
        _checkDestination(s.dstRecipient, s.dstChainId);

        _pull(onBehalfOf, s.inputToken, amount);
        SafeTransferLib.forceApprove(s.inputToken, address(TOKEN_MESSENGER), amount);
        uint64 nonce = TOKEN_MESSENGER.depositForBurn(
            amount, s.dstDomain, bytes32(uint256(uint160(s.dstRecipient))), s.inputToken
        );
        emit CctpBurn(nonce, s.dstDomain, s.dstRecipient, s.inputToken, amount);
        // Mirrors the Across module: drop the allowance and return anything the
        // messenger did not take, so this module ends every fill holding nothing.
        SafeTransferLib.forceApprove(s.inputToken, address(TOKEN_MESSENGER), 0);
        _sweep(s.inputToken, onBehalfOf);
    }
}
