// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";

interface IWrappedNative {
    function withdraw(uint256 amount) external;
    function deposit() external payable;
}

/// @title NativeUnwrapModule
/// @notice In-fill NATIVE-OUT: a singleton MAKE item that turns a WETH output
///         leg into raw native currency in the recipient's wallet, inside the
///         same fill — the CoW / 1inch-LOP (`UNWRAP_WETH`) shape, with no
///         per-maker deployment and no post-fill sweep.
///
///  Order shape — a PRE-FUNDED leg reference, the same descriptor every
///  push-funded lending MAKE uses ({PreFundGuard}):
///
///    legsOut = [ WETH, amount, recipient = THIS MODULE ]            // leg j
///    items   = [ MAKE this module, amount = 0,
///                data = abi.encode(forLegPreFund(j, WETH), payoutRecipient) ]
///
///  `_deliverOutputs` runs before `_executeItems` and records what it PAID for
///  leg j in the fill's delivery ledger; the settler then sizes this item from
///  that ledger ({Base._forSlice}: `amount == ctx.outs[j]`, spent once), so the
///  item unwraps EXACTLY what this fill delivered — whatever the leg priced to.
///  `data`'s payout recipient is maker-signed; `address(0)` means the maker.
///
///  Trust model: `msg.sender == SETTLEMENT` makes the maker's order signature
///  the sole authority over `(leg, recipient)`. Uniquely among maker modules,
///  NO Permit3 allowance is needed — the module spends only the WETH the fill
///  itself just delivered to it, never pulls from the maker.
///
/// @dev    ⚠ WHY THE DESCRIPTOR, NOT A SIGNED CONSTANT. The first version sized
///         the unwrap from the pro-rated `item.amount` — "same signed amount,
///         same fill fraction" as the leg. That holds only for a FIXED leg
///         (`end == 0`, no curve, no bump, no price module, no override). On any
///         auction-priced leg the delivery is `Pricing.outputAt` — a function
///         of time and bid — while the item was a constant: signing `start`
///         reverted in WETH9 once the tick moved, signing `end` left the whole
///         auction improvement stranded on this SHARED singleton, where a
///         zero-leg self-order naming the residue as its `amount` withdrew it
///         to a stranger (2026-09-12 audit, finding 2, fork-PoC'd). The
///         module-addressed leg also escaped the soft-exclusivity lift, handing
///         the maker's signed premium to any in-window outsider. The leg
///         reference closes all three at once: the amount IS the delivery, the
///         core refuses `overrideBps != 0` on this shape, and {floorOf} proves
///         the WETH landed HERE before a wei of it moves — so an item can never
///         spend another order's delivery or a donation. It also puts this
///         module on the pre-fund side of {Batch._assertMatchShape}, where a
///         self-funding MAKE belongs.
///
///         Posture — BATCH-SAFE native send (2026-10-15, v2). The send runs
///         INSIDE the fill with a capped but generous gas budget ({SEND_GAS},
///         set per chain at deploy, sized for smart-account `receive()`s), and
///         if the recipient cannot take native coin the module pays the same
///         amount in WETH instead ({PaidWrapped}). Why both halves:
///           • `matchSettle` is all-or-nothing and (after task 31) pays several
///             makers through this singleton in ONE plan, and `batchFill` shares
///             one transaction's gas across orders (63/64 rule). An uncapped
///             send that reverts or burns gas would let ONE recipient kill or
///             starve every other order in the transaction. The cap bounds the
///             burn per recipient; the fallback turns a revert into a payout.
///           • The cap is NOT a 2,300-gas stipend (failure class C10: CoW's
///             `transfer` needs driver-side access lists, UniswapX M-02 shut out
///             smart wallets). A recipient whose `receive()` needs more than
///             {SEND_GAS} still gets paid — in WETH — never refused.
///         The caller cannot FORCE the fallback by picking a gas limit: a send
///         starved below {SEND_GAS} leaves this frame only ~1/64 of its gas
///         (EIP-150), too little for the re-wrap, and {makeOnBehalf} refuses up
///         front anyway unless the full budget can reach the recipient
///         ({InsufficientSendGas}). So a WETH payout means the recipient itself
///         could not take native coin within the budget. The v1 module
///         (deployed for the 2026-10 beta Settlement) forwarded all gas and
///         reverted on failure — the 1inch-LOP unwrap stance; CoW pays its ETH
///         buy token with a 2,300-gas `transfer`.
contract NativeUnwrapModule is IMakerModule {
    IWrappedNative public immutable WETH;
    address public immutable SETTLEMENT;
    /// @notice Gas the native send gives the recipient. Per chain, set at deploy.
    uint256 public immutable SEND_GAS;

    /// @dev Gas the CALL itself may charge the caller before the callee starts:
    ///      value transfer (9,000) + new account (25,000) + a cold account read
    ///      (2,600) on Ethereum's schedule, rounded up. Rootstock prices CALL by its
    ///      own rules; the headroom is generous, and a live fill confirms it there.
    uint256 private constant CALL_OVERHEAD = 40_000;

    /// @dev The recipient could not take native coin within {SEND_GAS} (its
    ///      `receive()` reverted, is missing, or needs more gas); it was paid the
    ///      same amount in WETH instead.
    event PaidWrapped(address indexed recipient, uint256 amount);

    error OnlySettlement();
    error SendGasTooLow();
    /// @dev Not enough gas left to give the recipient the full {SEND_GAS}: refusing
    ///      here is what stops a caller from forcing the WETH fallback by
    ///      under-funding the transaction.
    error InsufficientSendGas();

    constructor(address weth, address settlement, uint256 sendGas) {
        if (sendGas < 2300) revert SendGasTooLow();
        WETH = IWrappedNative(weth);
        SETTLEMENT = settlement;
        SEND_GAS = sendGas;
    }

    /// @dev WETH9's `withdraw` pays via `transfer` (2300 stipend) — this must
    ///      stay an empty body.
    receive() external payable {}

    /// @inheritdoc IMakerModule
    /// @dev `amount` is what THIS fill delivered for the referenced WETH leg —
    ///      sized by the settler from its delivery ledger, never by the item's
    ///      signed constant. `data = abi.encode(uint256 forDesc, address recipient)`
    ///      where `forDesc` is the pre-fund leg reference naming WETH;
    ///      `recipient == address(0)` ⇒ `onBehalfOf` (the maker).
    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != SETTLEMENT) revert OnlySettlement();
        // The settler sizes `amount` from the ledger ONLY for this descriptor
        // shape; a plain-address blob would fall back to the signed constant
        // that the header explains away. Same predicate as `Base._isPreFundDesc`.
        PreFundGuard.requireLegRef(data);
        // Proof of delivery: the descriptor names WETH and at least `amount` of it
        // is here on top of whatever was here before. Underflows (fails closed) on
        // a leg not addressed to this module or priced in another token.
        PreFundGuard.requireDelivered(data, address(WETH), amount);
        (, address recipient) = abi.decode(data, (uint256, address));
        if (recipient == address(0)) recipient = onBehalfOf;
        WETH.withdraw(amount);
        // EIP-150 passes at most 63/64 of what is left after the CALL's own
        // charges; demand enough that the recipient gets all of {SEND_GAS}.
        if (gasleft() < SEND_GAS + SEND_GAS / 63 + CALL_OVERHEAD) revert InsufficientSendGas();
        (bool ok,) = recipient.call{value: amount, gas: SEND_GAS}("");
        if (!ok) {
            // Re-wrap exactly `amount` (never a stray native balance) and pay it as
            // WETH: a plain token transfer, which no recipient can refuse.
            WETH.deposit{value: amount}();
            SafeTransferLib.safeTransfer(address(WETH), recipient, amount);
            emit PaidWrapped(recipient, amount);
        }
    }
}
