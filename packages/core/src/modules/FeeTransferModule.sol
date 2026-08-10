// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMakerModule} from "../interfaces/IMakerModule.sol";
import {IPermit3} from "../interfaces/IPermit3.sol";

/// @title FeeTransferModule
/// @notice Originator-fee item: a MAKE module that pulls an ABSOLUTE fee amount
///         from the maker and forwards it to a named recipient. The
///         MAKER-funded fee channel for orders where a fee OUTPUT leg
///         (a `LegOut.recipient`) doesn't fit — outputless shapes (pure deposits,
///         zero-capital exits, repays) where nothing is delivered by the
///         solver, so a fee must come from the maker's wallet directly.
///
///         The analogue of 1inch LOP's `FeeTaker` extension, expressed in this
///         protocol's native seam: fees are just items. Properties:
///
///           • ABSOLUTE amount — "your exit margin is 4.20 USDC", priced
///             off-chain at signing; no dependence on delivered size.
///           • Any token, any order shape, maker-funded.
///           • Pro-rata for free: like any item, `amount` slices by the fill
///             fraction, so partial fills accrue the fee proportionally.
///
///         The relayer-fee counterpart is the rising `tokenIn` leg — this
///         module pays a KNOWN recipient a KNOWN amount; the rising leg pays
///         WHOEVER fills an auction-discovered amount. An outputless
///         integrator order typically carries both.
///
///  Trust model: `msg.sender == SETTLEMENT` makes
///  the maker's order signature the sole authority over `(token, recipient,
///  amount)`, and the maker's Permit3 allowance to THIS module caps what it can
///  ever pull. The transfer is maker → recipient directly; the module never
///  holds funds.
contract FeeTransferModule is IMakerModule {
    IPermit3 public immutable PERMIT3;
    address public immutable SETTLEMENT;

    error OnlySettlement();
    error ZeroRecipient();

    constructor(address permit3, address settlement) {
        PERMIT3 = IPermit3(permit3);
        SETTLEMENT = settlement;
    }

    /// @inheritdoc IMakerModule
    /// @dev `data = abi.encode(token, recipient)`; `amount` is the fee slice for
    ///      this fill (pro-rata of the signed item amount).
    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != SETTLEMENT) revert OnlySettlement();
        (address token, address recipient) = abi.decode(data, (address, address));
        if (recipient == address(0)) revert ZeroRecipient();
        PERMIT3.transferFrom(onBehalfOf, recipient, token, uint160(amount));
    }
}
