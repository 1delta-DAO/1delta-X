// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IOrderValidator} from "@core/interfaces/IOrderValidator.sol";
import {Order} from "@core/settlement/Settlement.sol";
import {InvariantReceiptGuard} from "@validators/InvariantReceiptGuard.sol";

interface IERC20BalanceOf {
    function balanceOf(address account) external view returns (uint256);
}

/// @title MinBalanceInvariant
/// @notice Aggregator-style min-return protection as a post-execution INVARIANT:
///         after the fill runs, assert that `account` holds at least `minBalance`
///         of `token`. Settlement moves NOMINAL amounts and never re-measures what
///         actually arrived (see the settlement README's "Fee-on-transfer &
///         rebasing tokens"), so a maker BUYING a fee-on-transfer / rebasing token
///         is otherwise silently underpaid — the transfer moves the signed amount
///         but the token's fee/rebase means less lands. Attaching this invariant
///         gives the maker a hard floor: if the fee eats past it, the whole fill
///         reverts (`InvariantFailed`).
///
///  Usage
///  ─────
///  Attach to `order.invariants` with
///      data = abi.encode(address token, address account, uint256 minBalance)
///  where `account` is usually `order.maker` (or a `LegOut.recipient`) and
///      minBalance = account's balance BEFORE the fill  +  the minimum net amount
///                   the maker will accept.
///
///  Because an invariant is a stateless `view` (a STATICCALL — it cannot read a
///  pre-fill snapshot), it checks an ABSOLUTE floor, not a delta. The maker fixes
///  the floor at signing time from its then-current balance; this is exactly the
///  Seaport/0x "minimum balance after" pattern. If the account transacts in
///  `token` between signing and filling, re-sign with a fresh floor.
///
///  ⚠ AN END STATE, NOT A DELIVERY (audit 2026-09-30 VAL-1). The floor is equally
///  met by tokens the maker obtained some other way (another order, another venue,
///  a transfer). As an add-on to a fungible output leg that is fine — the leg binds
///  the filler. As the order's ONLY receipt (`legsOut` empty: "pay X, end with ≥ Y")
///  it would let an open filler collect X for an inflow it did not provide, so that
///  shape must be filled by the order's named `exclusiveFiller`
///  ({InvariantReceiptGuard}; reverts {InvariantReceiptGuard.ReceiptNeedsNamedFiller}
///  otherwise).
///
///  Stateless, ownerless, and maker-opted: `token`/`account`/`minBalance` live in
///  the order's signed `Validator.data`, so a solver can neither weaken the floor
///  nor point it at a different token. Orders without it stay fillable by anyone.
///
/// @dev `data = abi.encode(address token, address account, uint256 minBalance)`.
contract MinBalanceInvariant is IOrderValidator {
    /// @inheritdoc IOrderValidator
    /// @dev Passes iff `token.balanceOf(account) >= minBalance`, after the
    ///      {InvariantReceiptGuard} named-filler rule. Uses only the maker-signed
    ///      `data` and the order; the filler-supplied `takerData` is ignored.
    function validate(Order calldata order, address filler, bytes calldata data, bytes calldata)
        external
        view
        override
        returns (bool)
    {
        InvariantReceiptGuard.enforce(order, filler);
        (address token, address account, uint256 minBalance) = abi.decode(data, (address, address, uint256));
        return IERC20BalanceOf(token).balanceOf(account) >= minBalance;
    }
}
