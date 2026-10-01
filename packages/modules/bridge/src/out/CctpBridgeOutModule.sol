// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

import {BridgeOutBase} from "./BridgeOutBase.sol";
import {ICctpTokenMessenger} from "../vendor/ICctp.sol";

/// @title CctpBridgeOutModule
/// @notice Source-side MAKE module that burns a fill's USDC proceeds through
///         Circle's CCTP **V2** for a mint on the destination chain.
///
///  V2, not V1 (audit 2026-09-30 BRIDGE-B-6)
///  ────────────────────────────────────────
///  Circle halts CCTP V1 on 2026-12-01 (burn limits fall from 2026-10-31), and V2
///  is not backward compatible, so this module targets the V2 TokenMessenger's
///  seven-argument `depositForBurn`. See {ICctpTokenMessenger} for the V2
///  differences that matter here — chiefly that V2 has a FEE.
///
///  Why this path is worth having
///  ─────────────────────────────
///  CCTP has no relayer and no LP: nothing fronts capital, so nothing can be
///  under-filled. V2 withholds a fee of at most `maxFee` from the mint, which the
///  maker bounds here as `maxFeeBps` of the slice, so the guaranteed-delivery floor
///  is `amount - maxFee` — `amount` itself for a Standard transfer signed with
///  `maxFeeBps == 0`. The trade is latency (Circle's attestation) and reach (USDC
///  only, on Circle-supported domains).
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
///  Routing the inbox path over CCTP would need V2's `depositForBurnWithHook` plus
///  a destination handler that runs the hook — a separate module, not a flag here.
///
///  Trust model, partial fills and the `msg.sender == SETTLEMENT` gate are all
///  inherited unchanged from {BridgeOutBase}.
contract CctpBridgeOutModule is BridgeOutBase {
    ICctpTokenMessenger public immutable TOKEN_MESSENGER;

    /// @notice A burn was submitted to CCTP for minting on `dstDomain`.
    ///
    ///  ⚠ THIS EVENT IS THE ONLY ON-CHAIN LINK BETWEEN A BURN AND THE ORDER IT
    ///  FUNDS. The Across and LayerZero paths carry a {CommitmentCodec} payload that
    ///  names the destination order, and the destination {BridgedOrderInbox} emits
    ///  `Credited` when it lands. CCTP carries no payload and has no destination
    ///  contract of ours, so without this event nothing records which order a burn
    ///  is for.
    ///
    ///  V2 assigns the message nonce off-chain, so an indexer pairs this event with
    ///  Circle's attestation by the SOURCE TRANSACTION HASH. `recipient` is the
    ///  funnel, which is what an orderbook matches outstanding destination orders
    ///  against, and `amount - maxFee` is the least that funnel will receive.
    event CctpBurn(
        uint32 indexed dstDomain,
        address indexed recipient,
        address token,
        uint256 amount,
        uint256 maxFee,
        uint32 minFinalityThreshold
    );

    /// @dev `dstDomain` is Circle's domain id and `dstChainId` the EVM chain id.
    ///      They are unrelated numbering schemes, so both are carried: the domain
    ///      is what CCTP routes on, and the chain id is what
    ///      {BridgeOutBase._checkDestination} sanity-checks (non-zero, not this
    ///      chain). Dropping the chain id would lose that check entirely, since
    ///      domain 0 is Ethereum and therefore indistinguishable from "unset".
    /// @param inputToken           USDC on THIS chain — the burn token.
    /// @param dstChainId           Destination EVM chain id. Checked, not routed on.
    /// @param dstDomain            Circle domain id. THIS is what routes.
    /// @param dstRecipient         The user's {PositionFunnel} on the destination —
    ///                             see the funnel-only note above.
    /// @param maxFeeBps            Maker-signed ceiling on the V2 transfer fee, as
    ///                             bps of the slice (rounded DOWN, so the floor
    ///                             `slice - maxFee` rounds up). Capped at
    ///                             {MAX_DEDUCTION_BPS}. `0` with a Standard
    ///                             threshold delivers the slice exactly.
    /// @param minFinalityThreshold `<= 1000` Fast (fee), `2000` Standard. Passed
    ///                             through; the maker's fee bound must cover the
    ///                             mode it picks or the attestation never mints.
    ///
    /// ⚠ THERE IS NO `dstScalingFactor` HERE, AND THERE MUST NOT BE. Every other
    ///   path in this package names a destination amount separately from the
    ///   source amount, so the two can be denominated differently and a decimal
    ///   conversion belongs between them. CCTP does not: `depositForBurn` takes ONE
    ///   figure, burned here and minted there as the same number (less the fee).
    ///   Scaling it would not convert anything — it would change how much is taken
    ///   from the maker. That the identity holds is Circle's guarantee: USDC is 6
    ///   decimals on every domain they support.
    struct CctpSpec {
        address inputToken;
        uint256 dstChainId;
        uint32 dstDomain;
        address dstRecipient;
        uint16 maxFeeBps;
        uint32 minFinalityThreshold;
    }

    constructor(address permit3, address settlement, address tokenMessenger) BridgeOutBase(permit3, settlement) {
        TOKEN_MESSENGER = ICctpTokenMessenger(tokenMessenger);
    }

    /// @inheritdoc IMakerModule
    ///
    /// @dev `maxFee = slice * maxFeeBps / BPS`, the same rounding as every other
    ///      proportional bound here ({_floorAfterBps}). No `_scaleToDest` — see the
    ///      note on {CctpSpec}. `destinationCaller` is zero so the solver that pays
    ///      for the mint can submit `receiveMessage` (see the package README).
    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override onlySettlement {
        CctpSpec memory s = abi.decode(data, (CctpSpec));
        _checkDestination(s.dstRecipient, s.dstChainId);
        uint256 maxFee = amount - _floorAfterBps(amount, s.maxFeeBps);

        // Snapshot before the pull — see {_sweep}: the sweep must return only what
        // THIS fill brought in, never a balance that was already resident.
        uint256 floor = _floorOf(s.inputToken);
        _pull(onBehalfOf, s.inputToken, amount);
        SafeTransferLib.forceApprove(s.inputToken, address(TOKEN_MESSENGER), amount);
        TOKEN_MESSENGER.depositForBurn(
            amount,
            s.dstDomain,
            bytes32(uint256(uint160(s.dstRecipient))),
            s.inputToken,
            bytes32(0),
            maxFee,
            s.minFinalityThreshold
        );
        emit CctpBurn(s.dstDomain, s.dstRecipient, s.inputToken, amount, maxFee, s.minFinalityThreshold);
        // Mirrors the Across module: drop the allowance and return anything the
        // messenger did not take, so this module ends every fill where it started.
        SafeTransferLib.forceApprove(s.inputToken, address(TOKEN_MESSENGER), 0);
        _sweep(s.inputToken, onBehalfOf, floor);
    }
}
