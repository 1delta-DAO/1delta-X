// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";

interface IWETHWithdraw {
    function withdraw(uint256 amount) external;
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
///         Posture — chosen deliberately, the opposite trade to
///         {WethUnwrapForwarder}: the native send happens INSIDE the fill with
///         full gas forwarded (smart-account recipients work), so a recipient
///         whose `receive()` reverts kills the whole fill. That is the
///         industry-standard stance (CoW settlement's ETH buy-token, 1inch
///         LOP's unwrap flag): EOA recipients cannot revert at all, and
///         fillers simulate immediately before executing, so a hostile
///         receiver costs a simulation, not a transaction. Makers whose
///         recipient cannot accept native should sign a plain WETH leg — or
///         use the forwarder, which quarantines the send after settlement.
contract NativeUnwrapModule is IMakerModule {
    IWETHWithdraw public immutable WETH;
    address public immutable SETTLEMENT;

    error OnlySettlement();
    error NativeSendFailed();

    constructor(address weth, address settlement) {
        WETH = IWETHWithdraw(weth);
        SETTLEMENT = settlement;
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
        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert NativeSendFailed();
    }
}
