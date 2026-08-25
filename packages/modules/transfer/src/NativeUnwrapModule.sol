// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMakerModule} from "@core/interfaces/IMakerModule.sol";

interface IWETHWithdraw {
    function withdraw(uint256 amount) external;
}

/// @title NativeUnwrapModule
/// @notice In-fill NATIVE-OUT: a singleton MAKE item that turns a WETH output
///         leg into raw native currency in the recipient's wallet, inside the
///         same fill — the CoW / 1inch-LOP (`UNWRAP_WETH`) shape, with no
///         per-maker deployment and no post-fill sweep.
///
///  Order shape (the two halves reference each other and slice by the same
///  fill fraction, so they stay matched across partial fills):
///
///    legsOut = [ WETH, amount, recipient = THIS MODULE ]
///    items   = [ MAKE this module, amount, data = abi.encode(payoutRecipient) ]
///
///  `_deliverOutputs` runs before `_executeItems`, so by the time the item
///  dispatches, this fill's WETH slice is already sitting here; the item
///  unwraps exactly its slice and pushes the native coin on.
///  `data`'s recipient is maker-signed; `address(0)` means the maker.
///
///  Trust model: `msg.sender == SETTLEMENT` makes the maker's order signature
///  the sole authority over `(amount, recipient)`. Uniquely among maker
///  modules, NO Permit3 allowance is needed — the module spends only the WETH
///  the fill itself just delivered to it, never pulls from the maker.
///
/// @dev    Posture — chosen deliberately, the opposite trade to
///         {WethUnwrapForwarder}: the native send happens INSIDE the fill with
///         full gas forwarded (smart-account recipients work), so a recipient
///         whose `receive()` reverts kills the whole fill. That is the
///         industry-standard stance (CoW settlement's ETH buy-token, 1inch
///         LOP's unwrap flag): EOA recipients cannot revert at all, and
///         fillers simulate immediately before executing, so a hostile
///         receiver costs a simulation, not a transaction. Makers whose
///         recipient cannot accept native should sign a plain WETH leg — or
///         use the forwarder, which quarantines the send after settlement.
///
///         The unwrap is the EXACT item slice, never a balance sweep — so in a
///         batch, two orders' WETH legs can both land here before either item
///         runs and each item still pays only its own maker. WETH donated to
///         this address is claimable by anyone via an item whose leg
///         under-delivers; donations are gifts, not custody.
///
///         Funding invariant across partial fills: items slice by cumulative
///         FLOOR ({SettlementBase._executeItem}); output legs round in the
///         maker's favor ({SettlementPricing} — BUY legs cumulative CEIL, SELL
///         legs per-fill ceil), so cumulative delivered ≥ cumulative unwrapped
///         at every point — the withdraw can never be underfunded, and the
///         maker's total receipt is EXACTLY the signed amount. The rounding
///         excess accrues here as unrecoverable wei dust: at most 1 wei total
///         on a BUY order (zero once fully filled), at most 1 wei per partial
///         fill on a SELL order. Dust is donation-equivalent — it can never
///         mispay a maker (each item unwraps only its own slice).
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
    /// @dev `amount` is this fill's pro-rata item slice — identical to the WETH
    ///      leg's delivered slice (same signed amount, same fill fraction, same
    ///      floor rounding). `data = abi.encode(address recipient)`;
    ///      `address(0)` ⇒ `onBehalfOf` (the maker).
    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != SETTLEMENT) revert OnlySettlement();
        address recipient = abi.decode(data, (address));
        if (recipient == address(0)) recipient = onBehalfOf;
        WETH.withdraw(amount);
        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert NativeSendFailed();
    }
}
