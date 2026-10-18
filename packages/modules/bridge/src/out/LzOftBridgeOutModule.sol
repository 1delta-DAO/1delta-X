// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ISettlementModule} from "@core/interfaces/ISettlementModule.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";

import {BridgeOutBase} from "./BridgeOutBase.sol";
import {IOFT} from "../vendor/ILayerZero.sol";

/// @dev WETH9-shaped wrapped native (WETH, WRBTC, WBNB …). Only `withdraw` is used.
interface IWrappedNativeLike {
    function withdraw(uint256 amount) external;
}

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
///     credit ledger held here: whoever intends to pay tops up via {topUpFor} —
///     or the fill itself does, from a wrapped-native output leg (FEE FROM THE
///     FILL'S LEGS below) — and the maker names the payer as `feePayer` in the
///     signed spec.
///     `feePayer` is also the LayerZero refund address, so the executor's change
///     goes straight back to them without passing through this contract.
///
///     Setting `feePayer` to the maker is the self-contained default (the user
///     covers their own message fee, in native, on the chain they are already
///     transacting on). Setting it to a solver works too, and lets the fee be
///     priced into the auction spread instead — but ONLY against a
///     {feeAllowance} that payer granted that maker ({approveFeeSponsorship}).
///
///     ⚠ WHY THE CONSENT IS ON-CHAIN (re-audit F30). `feePayer`, `oft` and
///     `maxNativeFee` are all MAKER-signed, and the fee is quoted by and paid to
///     `oft`. With no binding between payer and maker, anyone could sign their own
///     order naming a victim as `feePayer` and their own contract as `oft`, have it
///     quote the victim's whole credit, and fill it themselves — every top-up in
///     the ledger was one self-signed order away. Charging someone else's credit
///     now needs that someone's standing, amount-bounded allowance to this maker,
///     so a sponsor's worst case is the allowance it chose to extend.
///
///     ⚠ WHAT THE SPONSORSHIP CAN AND CANNOT BIND (audit 2026-09-30 X-DIFF-REST-3).
///     A sponsorship is consent per (payer, maker), consumed per MESSAGE:
///       • a sponsored send must be the WHOLE item (`totalAmount`, {FullFillGuard}),
///         so a filler cannot split one order into N slices and charge the
///         sponsor N messaging fees;
///       • each send is capped by the sponsor's `maxFeePerSend`, and the
///         allowance moves by {increaseFeeSponsorship} / {decreaseFeeSponsorship}
///         as well as the absolute {approveFeeSponsorship}, so a re-approval need
///         not race the maker;
///       • it BINDS THE FILLER on-chain. A sponsored send must ride the `SETTLE`
///         item op ({ISettlementModule.settle}), the one seam on which the core
///         passes the filler, and the filler must be the sponsor itself or an
///         agent the sponsor named ({setSponsorFiller}). The `MAKE` seam
///         ({IMakerModule.makeOnBehalf}) carries no filler identity, so a
///         sponsored spec dispatched as `MAKE` now reverts
///         {SponsoredSendNeedsSettle} instead of letting any filler of the order
///         make the sponsor pay (audit 2026-09-30 X-DIFF-REST-3 part (a); this
///         used to be an off-chain rule only). A self-paid send (`feePayer ==
///         maker`) works on both seams. The SDK's `assertLzSponsorshipSafe`
///         (hard lifelong `exclusiveFiller` = sponsor) remains a LIVENESS check:
///         a non-sponsor filler now simply reverts.
///       • it is PULL-funded only. The pre-funded forms ride `MAKE`, which cannot
///         carry the filler; `settle` refuses a pre-fund blob ({PreFundNeedsMake}).
///         The fee-from-legs form below is the zero-float alternative to a
///         sponsorship: the filler still prices the fee, but delivers it as an
///         output leg instead of parking a float here.
///
///     FEE FROM THE FILL'S LEGS (review 2026-10-18 M-4). The two forms above both
///     make the messaging fee a native FLOAT someone must park here before the
///     fill: a prior {topUpFor} by the maker, or a sponsor's float that the
///     auction never prices. The PRE-FUNDED fee credit removes the float: the
///     order carries a wrapped-native output leg addressed to this module and a
///     separate MAKE item with op {OP_FEE_CREDIT}
///
///         legsOut[k] = (WRAPPED_NATIVE, feeBudget, recipient = this module)
///         items[0]   = MAKE this, data = abi.encode(forLegPreFund(k, WRAPPED_NATIVE) | OP_FEE_CREDIT << 244)
///         items[1]   = MAKE this, data = abi.encode(forLegPreFund(j, inputToken), LzSpec{feePayer: maker, …})
///
///     Item 0 unwraps exactly the core-sized delivery of leg `k` into
///     `nativeCredit[maker]`; item 1 then pays the quoted fee from that credit as
///     an ordinary self-paid send. So the fee is just another output the filler
///     delivers and prices into its quote — no float, no prior transaction, no
///     sponsor, zero filler capital. It takes TWO items because the core binds
///     and consumes ONE leg per item (word 0's descriptor, {Base._forSlice}): a
///     second leg reference inside one item's data would be sized by nothing but
///     a balance floor against an `oft`-quoted (maker-chosen) fee — the Teller
///     shape {PreFundGuard} exists to forbid. Schedule item 0 first (items run in
///     order on `fill`; on `matchSettle` an out-of-order schedule only finds less
///     credit and reverts {InsufficientNativeCredit}). Any part of the budget the
///     quote does not use stays the maker's credit — spent first by their next
///     send, or reclaimed with {withdrawNative}. Disabled (reverts
///     {NoWrappedNative}) on a deployment built with `wrappedNative == 0`.
///
///     ⚠ TOKEN BINDING (audit 2026-09-30 BRIDGE-B-2). `inputToken` MUST be
///     `IOFT(oft).token()`, and this is now checked on-chain. A native OFT burns
///     from its CALLER with no allowance, whatever the module pulled, so a spec
///     naming a junk `inputToken` and a real native OFT burned this module's
///     RESIDENT OFT balance (strays, mis-sends) to the attacker's destination.
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
contract LzOftBridgeOutModule is BridgeOutBase, ISettlementModule {
    /// @notice The chain's wrapped native token, unwrapped by the {OP_FEE_CREDIT}
    ///         op. `address(0)` disables that op; nothing else reads it.
    IWrappedNativeLike public immutable WRAPPED_NATIVE;

    /// @dev Pre-fund ops, descriptor bits [244,252) — the {PreFundModuleBase._preFundOp}
    ///      convention. Inside the signed descriptor, so the op is maker-signed.
    uint256 public constant OP_SEND = 0;
    uint256 public constant OP_FEE_CREDIT = 1;

    /// @notice Native balance available to pay LayerZero messaging fees, per payer.
    ///         Deliberately a ledger rather than a pooled float: a pooled balance
    ///         would let any order drain whatever anyone else deposited.
    mapping(address => uint256) public nativeCredit;

    /// @notice `feeAllowance[payer][maker]` — how much of `payer`'s {nativeCredit}
    ///         orders signed by `maker` may spend on messaging fees. Only consulted
    ///         when `feePayer != maker`; a maker always pays from their own credit.
    mapping(address payer => mapping(address maker => uint256)) public feeAllowance;

    /// @notice `maxFeePerSend[payer][maker]` — the most ONE sponsored message may
    ///         charge `payer`, whatever the maker's own `maxNativeFee` says.
    mapping(address payer => mapping(address maker => uint256)) public maxFeePerSend;

    /// @notice `sponsorFiller[payer][filler]` — `filler` may fill orders that spend
    ///         `payer`'s sponsorship (besides `payer` itself). Lets a sponsor fill
    ///         through its own executor contract. Never name a PERMISSIONLESS
    ///         contract (a public solver anyone can drive): its address is then
    ///         every caller's.
    mapping(address payer => mapping(address filler => bool)) public sponsorFiller;

    event ToppedUp(address indexed payer, uint256 amount, uint256 balance);
    event WithdrawnNative(address indexed payer, uint256 amount, uint256 balance);
    event FeeSponsorshipSet(address indexed payer, address indexed maker, uint256 amount, uint256 maxPerSend);
    event SponsorFillerSet(address indexed payer, address indexed filler, bool allowed);

    error FeeAboveCap();
    error InsufficientNativeCredit();
    error NativeTransferFailed();
    /// @dev `feePayer` is not the maker and has not sponsored this maker for at
    ///      least the quoted fee, or the fee exceeds the sponsor's per-send cap.
    error FeeNotSponsored();
    /// @dev `IOFT(oft).token() != inputToken` — see the TOKEN BINDING note.
    error OftTokenMismatch();
    /// @dev A sponsored spec (`feePayer != maker`) was dispatched on the `MAKE` seam,
    ///      which carries no filler identity — sign it as a `SETTLE` item.
    error SponsoredSendNeedsSettle();
    /// @dev A sponsored send filled by someone other than the sponsor or one of
    ///      its named agents ({setSponsorFiller}).
    error FillerNotSponsor(address filler);
    /// @dev A pre-funded blob dispatched on the `SETTLE` seam. The core sizes a
    ///      pre-funded slice from its delivery ledger only for `ItemOp.MAKE`; on
    ///      `SETTLE` the slice would be the maker-signed `item.amount` against a
    ///      delivery nothing bound to this module.
    error PreFundNeedsMake();
    /// @dev A pre-fund descriptor naming an op this module does not implement.
    error BadOp();
    /// @dev {OP_FEE_CREDIT} on a deployment without a wrapped native token.
    error NoWrappedNative();
    /// @dev Native sent to this module by anyone but {WRAPPED_NATIVE}'s `withdraw`.
    ///      Credit is only ever added through {topUpFor} or {OP_FEE_CREDIT}, so a
    ///      bare transfer would strand value no ledger row owns.
    error OnlyWrappedNative();

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
    ///                          ⚠ Must NOT carry an lzCompose native VALUE: the
    ///                          inbox owes no native and reverts a value-bearing
    ///                          compose (it stays retryable with zero value).
    /// @param totalAmount       The item's FULL maker-signed amount. Mandatory (and
    ///                          the slice must equal it) when `feePayer` is not
    ///                          the maker; optional otherwise, where zero allows
    ///                          partial slices. On the PRE-FUNDED form (always
    ///                          self-paid) the delivered slice must be AT LEAST it
    ///                          ({BridgeOutBase._fullFillGate}).
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
        uint256 totalAmount;
    }

    /// @param wrappedNative the chain's WETH9-shaped wrapped native, or `address(0)`
    ///                      to deploy without the {OP_FEE_CREDIT} op.
    constructor(address permit3, address settlement, address wrappedNative) BridgeOutBase(permit3, settlement) {
        WRAPPED_NATIVE = IWrappedNativeLike(wrappedNative);
    }

    /// @dev Accepts only {WRAPPED_NATIVE}'s `withdraw` payout (WETH9 pays with a
    ///      2,300-gas `transfer`; this body fits it). See {OnlyWrappedNative}.
    receive() external payable {
        if (msg.sender != address(WRAPPED_NATIVE)) revert OnlyWrappedNative();
    }

    // ──────────────────── Native fee ledger ────────────────────

    /// @notice Fund `account`'s messaging-fee credit. Permissionless: a solver may
    ///         top up a maker, or a maker themselves.
    function topUpFor(address account) external payable {
        nativeCredit[account] += msg.value;
        emit ToppedUp(account, msg.value, nativeCredit[account]);
    }

    /// @notice Let orders signed by `maker` spend up to `amount` of the caller's
    ///         credit on messaging fees, at most `maxPerSend` per message. Keyed by
    ///         `msg.sender`, so only ever your own credit; set to 0 to revoke. An
    ///         absolute value — prefer {increaseFeeSponsorship} /
    ///         {decreaseFeeSponsorship} to adjust a live one, so a maker cannot
    ///         spend the old allowance and then the new one.
    function approveFeeSponsorship(address maker, uint256 amount, uint256 maxPerSend) external {
        feeAllowance[msg.sender][maker] = amount;
        maxFeePerSend[msg.sender][maker] = maxPerSend;
        emit FeeSponsorshipSet(msg.sender, maker, amount, maxPerSend);
    }

    /// @notice Raise the caller's sponsorship of `maker` by `amount`.
    function increaseFeeSponsorship(address maker, uint256 amount) external {
        uint256 a = feeAllowance[msg.sender][maker] + amount;
        feeAllowance[msg.sender][maker] = a;
        emit FeeSponsorshipSet(msg.sender, maker, a, maxFeePerSend[msg.sender][maker]);
    }

    /// @notice Lower the caller's sponsorship of `maker` by `amount`, flooring at 0.
    function decreaseFeeSponsorship(address maker, uint256 amount) external {
        uint256 a = feeAllowance[msg.sender][maker];
        a = a > amount ? a - amount : 0;
        feeAllowance[msg.sender][maker] = a;
        emit FeeSponsorshipSet(msg.sender, maker, a, maxFeePerSend[msg.sender][maker]);
    }

    /// @notice Allow (or stop allowing) `filler` to fill orders that spend the
    ///         caller's sponsorship — for a sponsor that fills through its own
    ///         executor contract. Keyed by `msg.sender`.
    function setSponsorFiller(address filler, bool allowed) external {
        sponsorFiller[msg.sender][filler] = allowed;
        emit SponsorFillerSet(msg.sender, filler, allowed);
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
    /// @dev Self-paid sends only: a sponsored spec reverts {SponsoredSendNeedsSettle}.
    ///
    ///      PULL: `data = abi.encode(LzSpec)`; the bridged tokens come from the maker
    ///      under its Permit3 allowance to this module.
    ///      PRE-FUNDED (word 0 a pre-fund leg reference, `amount` = the core's
    ///      delivery-ledger figure for that leg, which is addressed to this module):
    ///        op {OP_SEND}       `data = abi.encode(forLegPreFund(j, inputToken), LzSpec)`
    ///                           — bridge the delivered leg, no maker grant;
    ///        op {OP_FEE_CREDIT} `data = abi.encode(forLegPreFund(k, WRAPPED_NATIVE) | 1 << 244)`
    ///                           — unwrap the delivered leg into `nativeCredit[maker]`.
    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override onlySettlement {
        if (!_isPreFund(data)) {
            _send(onBehalfOf, amount, abi.decode(data, (LzSpec)), data, address(0), false);
            return;
        }
        // The descriptor half of {PreFundModuleBase._gatePreFundMake}; the caller
        // half is `onlySettlement`. Restated although `_isPreFund` just answered it,
        // so the pin sits on this entrypoint where the shapes checker reads it.
        PreFundGuard.requireLegRef(data);
        uint256 op = _preFundOp(data);
        if (op == OP_SEND) {
            (, LzSpec memory s) = abi.decode(data, (uint256, LzSpec));
            _send(onBehalfOf, amount, s, data, address(0), true);
        } else if (op == OP_FEE_CREDIT) {
            _creditFee(onBehalfOf, amount, data);
        } else {
            revert BadOp();
        }
    }

    /// @inheritdoc ISettlementModule
    /// @dev The `SETTLE` twin of {makeOnBehalf}'s PULL form, identical except that
    ///      the core passes the `filler`, which a sponsored send must be bound to.
    ///      `filler` is used ONLY for that check — nothing is ever pulled from it
    ///      (the SETTLE rule, {ISettlementModule}); the bridged tokens come from the
    ///      MAKER under its own Permit3 allowance to this module, exactly as on the
    ///      MAKE seam. A pre-funded blob is refused ({PreFundNeedsMake}).
    function settle(address maker, address filler, uint256 amount, bytes calldata data)
        external
        override
        onlySettlement
    {
        if (_isPreFund(data)) revert PreFundNeedsMake();
        _send(maker, amount, abi.decode(data, (LzSpec)), data, filler, false);
    }

    /// @dev Descriptor bits [244,252): which pre-fund op. Only reached once
    ///      {_isPreFund} has answered `true`, so `data` is at least one word.
    function _preFundOp(bytes calldata data) private pure returns (uint256 op) {
        /// @solidity memory-safe-assembly
        assembly {
            op := and(shr(244, calldataload(data.offset)), 0xff)
        }
    }

    /// @dev {OP_FEE_CREDIT}: turn this item's core-sized wrapped-native delivery into
    ///      the maker's messaging-fee credit. {PreFundGuard.requireDelivered} binds
    ///      the descriptor's signed token to {WRAPPED_NATIVE} and proves `amount` of it
    ///      landed here on top of the pre-delivery balance (underflow = fail closed),
    ///      so neither residue nor another order's parked delivery can be credited.
    ///      The credit is keyed by `onBehalfOf` — the core-verified maker who paid for
    ///      the delivery — never by anything in `data`.
    function _creditFee(address onBehalfOf, uint256 amount, bytes calldata data) private {
        IWrappedNativeLike w = WRAPPED_NATIVE;
        if (address(w) == address(0)) revert NoWrappedNative();
        PreFundGuard.requireDelivered(data, address(w), amount);
        w.withdraw(amount);
        uint256 credit = nativeCredit[onBehalfOf] + amount;
        nativeCredit[onBehalfOf] = credit;
        emit ToppedUp(onBehalfOf, amount, credit);
    }

    /// @param s       the decoded spec (PULL: `data` itself; PRE-FUNDED: word 1 on).
    /// @param data    the raw item data — read only by the PRE-FUNDED floor, for the
    ///                descriptor's signed funding token.
    /// @param filler  the fill's filler on the SETTLE seam; `address(0)` on the MAKE
    ///                seam, where it is unknown.
    /// @param preFund the funding form ({BridgeOutBase._fundIn}).
    function _send(
        address onBehalfOf,
        uint256 amount,
        LzSpec memory s,
        bytes calldata data,
        address filler,
        bool preFund
    ) private {
        _checkDestination(s.dstRecipient, s.dstChainId);
        // The endpoint id is a SEPARATE namespace from the chain id, and nothing
        // on-chain can prove the two agree — that pairing is an off-chain preflight.
        // Zero is the one value that is unambiguously an unpopulated field.
        if (s.dstEid == 0) revert BadDestination();
        // See the TOKEN BINDING note: the venue must move exactly the token funded.
        if (IOFT(s.oft).token() != s.inputToken) revert OftTokenMismatch();
        // A sponsored send is one message for the whole item — see the contract note.
        _fullFillGate(amount, s.totalAmount, s.feePayer != onBehalfOf, preFund);

        // PULL snapshots then pulls; PRE-FUNDED proves the delivery landed here. Either
        // way `floor` is the pre-fill balance the closing sweep returns down to.
        uint256 floor = _fundIn(onBehalfOf, s.inputToken, amount, data, preFund);

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
        // Someone else's credit only with their consent to THIS maker, and only up
        // to the amount they extended — see the contract note.
        if (s.feePayer != onBehalfOf) {
            // The filler binding (X-DIFF-REST-3 a): only the sponsor, or an agent it
            // named, may make it pay. The MAKE seam cannot tell, so it refuses.
            if (filler == address(0)) revert SponsoredSendNeedsSettle();
            if (filler != s.feePayer && !sponsorFiller[s.feePayer][filler]) revert FillerNotSponsor(filler);
            uint256 allowed = feeAllowance[s.feePayer][onBehalfOf];
            if (fee > allowed || fee > maxFeePerSend[s.feePayer][onBehalfOf]) revert FeeNotSponsored();
            unchecked {
                feeAllowance[s.feePayer][onBehalfOf] = allowed - fee;
            }
        }
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
        _sweep(s.inputToken, onBehalfOf, floor);
    }
}
