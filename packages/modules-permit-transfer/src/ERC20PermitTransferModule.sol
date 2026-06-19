// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {PermitHelper} from "@core/utils/PermitHelper.sol";

// ──────────────────── ERC-20 gasless transfer via permit ────────────────────
//
// A TakerModule that executes a plain ERC-20 transfer on a user's behalf,
// funded by a Permit3 taker allowance. The solver pays gas and earns a fee
// encoded as the spread between the gross amount pulled and the net amount
// delivered to the recipient.
//
// Typical use-case: user holds USDC but has no native gas. They sign an EIP-2612
// permit (approving Permit3) and a limit order; a solver calls `fillWithPermit`
// to broadcast in one tx without the user ever touching the chain.
//
// Flow
// ────
//   1. (Optional) Replay EIP-2612 permit so Permit3 can pull the token at the
//      ERC-20 level without a prior on-chain `approve`.
//   2. Pull `amount` (gross) from user via `permit3.transferFrom`.
//   3. Send `transferAmount` to `recipient` (the intended receiver of the transfer).
//   4. Send `amount - transferAmount` (solver fee) to `receiver` (Settlement).
//      Settlement's `_payTokenInToSolver` forwards it to the solver.
//
// Matching LimitOrder shape
// ─────────────────────────
//   tokenIn  = token,  amountIn  = fee                  ← solver earns
//   tokenOut = token,  amountOut = 0                    ← solver provides nothing
//   items    = [{ TAKE, this, fee + transferAmount, 0, data }]
//
//   The dutch-auction fields let the fee decay over time to attract competitive
//   solvers; `minFillAmountIn = amountIn` prevents partial fills on transfers.
//
// data = abi.encode(token, recipient, transferAmount[, deadline, v, r, s])
//
//   token          — ERC-20 to move
//   recipient      — net-of-fee destination
//   transferAmount — tokens reaching `recipient`; must be ≤ `amount`
//   deadline/v/r/s — optional 128-byte EIP-2612 permit block (absent → standing ERC-20 allowance required)
//
contract ERC20PermitTransferModule is ITakerModule {
    IPermit3 public immutable permit3;

    error OnlyPermit3();
    error TransferAmountExceedsGross(uint256 transferAmount, uint256 gross);

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    /// @param onBehalfOf    User whose Permit3 taker allowance is spent.
    /// @param amount        Gross tokens pulled from the user (transferAmount + fee).
    /// @param receiver      Settlement address — the fee portion lands here.
    /// @param data          abi.encode(token, recipient, transferAmount[, deadline, v, r, s])
    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data)
        external
        override
    {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        (address token, address recipient, uint256 transferAmount) =
            abi.decode(data, (address, address, uint256));

        if (transferAmount > amount) revert TransferAmountExceedsGross(transferAmount, amount);

        // Optional EIP-2612 permit replay. Permits Permit3 to pull `amount` of
        // `token` from `onBehalfOf` at the ERC-20 level.
        // base = abi.encode(address, address, uint256) = 96 bytes.
        PermitHelper.replayIfPresent(data, 96, token, onBehalfOf, address(permit3), amount);

        // Pull gross from user via Permit3's token allowance gate.
        permit3.transferFrom(onBehalfOf, address(this), token, uint160(amount));

        // Deliver the transfer amount to the intended recipient.
        SafeTransferLib.safeTransfer(token, recipient, transferAmount);

        // Fee (spread) flows to Settlement → solver via _payTokenInToSolver.
        uint256 fee = amount - transferAmount;
        if (fee > 0) SafeTransferLib.safeTransfer(token, receiver, fee);
    }
}
