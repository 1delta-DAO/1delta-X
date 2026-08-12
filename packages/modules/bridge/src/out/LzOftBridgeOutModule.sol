// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";

import {BridgeOutBase} from "./BridgeOutBase.sol";
import {IOFT} from "../vendor/ILayerZero.sol";

/// @title LzOftBridgeOutModule
/// @notice Source-side MAKE module for BOTH LayerZero paths — Stargate V2 pools
///         and plain OFTs such as USDT0 — because `IStargate` is `IOFT`-shaped and
///         this module only uses the shared surface. Which one a given order uses
///         is a matter of the `oft` address in its signed spec, nothing more.
///
///         Stargate sends go in taxi mode (`oftCmd` empty): immediate rather than
///         batched. Bus mode would need `sendToken` and separate verification that
///         compose is delivered in that mode.
///
///  What differs from Across
///  ────────────────────────
///  1. NATIVE FEE. LayerZero charges the messaging fee in native currency, and a
///     module invoked from an item has no way to receive value — `makeOnBehalf` is
///     not payable and carries no filler-supplied data. So the fee is drawn from a
///     pre-funded credit ledger held here: whoever intends to pay tops up via
///     {topUpFor}, and the maker names them as `feePayer` in the signed spec.
///     `feePayer` is also the LayerZero refund address, so the executor's change
///     goes straight back to them without passing through this contract.
///
///     Setting `feePayer` to the maker is the self-contained default (the user
///     covers their own message fee, in native, on the chain they are already
///     transacting on). Setting it to a solver works too, and lets the fee be
///     priced into the auction spread instead — that is an off-chain agreement,
///     so it needs no code here either way.
///
///  2. SPLIT ARRIVAL. Tokens land on the destination in the `lzReceive`
///     transaction and the commitment in a LATER `lzCompose` one. That is why
///     {BridgedOrderInbox.lzCompose} never reverts on business-logic failure —
///     see the note there. Nothing about it changes this module.
///
///  3. DELIVERY FLOOR. Stargate takes a pool fee, and an OFT truncates to shared
///     decimals. Both are absorbed by the maker-signed `maxSlippageBps`, which
///     becomes `minAmountLD` — enforced by the bridge, and therefore the
///     guaranteed floor the destination order's input leg is authored against.
///     For a token whose local and shared decimals match (USDT0 at 6) zero is
///     correct; for an 18-decimal OFT it must at least cover the dust.
contract LzOftBridgeOutModule is BridgeOutBase {
    /// @notice Native balance available to pay LayerZero messaging fees, per payer.
    ///         Deliberately a ledger rather than a pooled float: a pooled balance
    ///         would let any order drain whatever anyone else deposited.
    mapping(address => uint256) public nativeCredit;

    event ToppedUp(address indexed payer, uint256 amount, uint256 balance);
    event WithdrawnNative(address indexed payer, uint256 amount, uint256 balance);

    error FeeAboveCap();
    error InsufficientNativeCredit();
    error NativeTransferFailed();

    /// @param oft               Stargate pool or OFT/adapter on THIS chain.
    /// @param inputToken        ERC20 pulled from the maker. Must be `IOFT.token()`.
    /// @param dstEid            LayerZero endpoint id of the destination — NOT a
    ///                          chain id. `dstChainId` below is the real chain id
    ///                          and goes into the commitment.
    /// @param dstChainId        Destination chain id, for the commitment's replay guard.
    /// @param dstRecipient      Destination {BridgedOrderInbox} or the user's
    ///                          {PositionFunnel}. With a funnel, set `dstOrderHash`
    ///                          to zero: `composeMsg` is then empty, so no
    ///                          `lzCompose` is scheduled and the split-arrival
    ///                          orphan risk in point 2 below does not apply.
    /// @param maxSlippageBps    Maker-signed ceiling on pool fee + dust. Determines
    ///                          `minAmountLD`, which MUST equal the destination
    ///                          order's `legsIn[0].start` for a full fill.
    /// @param maxNativeFee      Ceiling on the quoted messaging fee. A quote above
    ///                          it reverts the fill rather than draining the payer.
    /// @param feePayer          Whose {nativeCredit} pays, and the LayerZero refund
    ///                          address for the executor's change.
    /// @param extraOptions      Executor options. MUST budget lzCompose gas as well
    ///                          as lzReceive, or the commitment never lands and the
    ///                          delivery becomes an orphan at the inbox. Signed by
    ///                          the maker rather than built here so the gas budget
    ///                          is explicit and auditable at signing time.
    struct LzSpec {
        address oft;
        address inputToken;
        uint32 dstEid;
        uint256 dstChainId;
        address dstRecipient;
        uint16 maxSlippageBps;
        uint128 maxNativeFee;
        address feePayer;
        bytes extraOptions;
        bytes32 dstOrderHash;
        address beneficiary;
        uint32 commitmentExpiry;
    }

    constructor(address permit3, address settlement) BridgeOutBase(permit3, settlement) {}

    // ──────────────────── Native fee ledger ────────────────────

    /// @notice Fund `account`'s messaging-fee credit. Permissionless: a solver may
    ///         top up a maker, or a maker themselves.
    function topUpFor(address account) external payable {
        nativeCredit[account] += msg.value;
        emit ToppedUp(account, msg.value, nativeCredit[account]);
    }

    /// @notice Reclaim unspent credit. Keyed by `msg.sender`, so only ever your own.
    function withdrawNative(uint256 amount) external {
        uint256 bal = nativeCredit[msg.sender];
        if (amount > bal) revert InsufficientNativeCredit();
        unchecked {
            nativeCredit[msg.sender] = bal - amount;
        }
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
        emit WithdrawnNative(msg.sender, amount, nativeCredit[msg.sender]);
    }

    // ──────────────────── Fill path ────────────────────

    /// @inheritdoc IMakerModule
    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override onlySettlement {
        LzSpec memory s = abi.decode(data, (LzSpec));
        _checkDestination(s.dstRecipient, s.dstChainId);
        // The endpoint id is a SEPARATE namespace from the chain id, and nothing
        // on-chain can prove the two agree — that pairing is an off-chain preflight.
        // Zero is the one value that is unambiguously an unpopulated field.
        if (s.dstEid == 0) revert BadDestination();

        _pull(onBehalfOf, s.inputToken, amount);

        IOFT.SendParam memory sp = IOFT.SendParam({
            dstEid: s.dstEid,
            to: bytes32(uint256(uint160(s.dstRecipient))),
            amountLD: amount,
            minAmountLD: _floorAfterBps(amount, s.maxSlippageBps),
            extraOptions: s.extraOptions,
            composeMsg: _commitment(s.dstOrderHash, s.beneficiary, s.dstChainId, s.commitmentExpiry),
            oftCmd: "" // taxi / immediate for Stargate; ignored by a plain OFT
        });

        // Quote against the exact SendParam that will be sent — a quote taken over
        // anything else prices a different message.
        uint256 fee = IOFT(s.oft).quoteSend(sp, false).nativeFee;
        if (fee > s.maxNativeFee) revert FeeAboveCap();
        uint256 credit = nativeCredit[s.feePayer];
        if (fee > credit) revert InsufficientNativeCredit();
        unchecked {
            nativeCredit[s.feePayer] = credit - fee;
        }

        // A native OFT burns from this module's own balance and needs no approval;
        // an adapter or a Stargate pool pulls the underlying and does. Inferred
        // from the addresses rather than from the optional `approvalRequired()`
        // view, so a deployment that omits that view still works.
        bool pulls = s.oft != s.inputToken;
        if (pulls) SafeTransferLib.forceApprove(s.inputToken, s.oft, amount);

        IOFT(s.oft).send{value: fee}(sp, IOFT.MessagingFee({nativeFee: fee, lzTokenFee: 0}), s.feePayer);

        if (pulls) SafeTransferLib.forceApprove(s.inputToken, s.oft, 0);
        _sweep(s.inputToken, onBehalfOf);
    }
}
