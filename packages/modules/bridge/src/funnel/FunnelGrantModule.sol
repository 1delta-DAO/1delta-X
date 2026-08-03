// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMakerModule} from "@core/interfaces/IMakerModule.sol";

/// @dev The one call this module is allowed to make. Implemented by
///      {PositionFunnel}, which gates it on `msg.sender == GRANT_MODULE`.
interface IFunnelGrantee {
    function grant(address spender, address token, uint160 amount, bool taker, bytes32 ref) external;
}

/// @title FunnelGrantModule
/// @notice A MAKE item that installs the Permit3 allowances the REST OF THE SAME
///         FILL needs, so a {PositionFunnel} can run a leverage order with no
///         standing approvals and no signature beyond the order itself.
///
///  Placed first in the order's items:
///
///      items[0]  MAKE  FunnelGrantModule   grants (module, token, amount)
///      items[1]  MAKE  <lender supply>     pulls against that allowance
///      items[2]  TAKE  <lender borrow>     spends the taker allowance
///
///  Items run after outputs are delivered and BEFORE inputs are paid to the
///  solver, so a grant here can also cover the `legsIn` pull.
///
///  Security
///  ────────
///  This contract is deliberately tiny, because {PositionFunnel} pins it as an
///  immutable and every funnel trusts it. It does exactly two things — check the
///  caller and forward — and the forwarding rule is the load-bearing one:
///
///      THE TARGET IS `onBehalfOf`, NEVER A FIELD OF `data`.
///
///  `Settlement._executeItems` passes `order.maker` as `onBehalfOf`, and no path
///  reaches items without verifying that maker's authorisation. So a grant item
///  inside an attacker's order operates on the ATTACKER's funnel; there is no
///  encoding of `data` that redirects it at somebody else's. Taking the funnel
///  address from `data` instead would make this trivially drainable, which is why
///  it is called out here rather than left implicit.
///
///  Note this module is generic, not funnel-specific: any maker may reference it.
///  A maker with no `grant` function simply reverts, which costs that maker's own
///  fill and nobody else's.
contract FunnelGrantModule is IMakerModule {
    /// @notice The only permitted caller. Load-bearing: without it, anyone could
    ///         invoke `makeOnBehalf(victimFunnel, …)` directly and mint themselves
    ///         an allowance over that funnel.
    address public immutable SETTLEMENT;

    /// @param spender Who receives the allowance — a lender module for a MAKE leg,
    ///                or Settlement for a TAKE leg or a `legsIn` pull.
    /// @param token   ERC20 for the token book. Ignored when `taker` is true.
    /// @param taker   True to grant on the TAKER book instead of the token book.
    /// @param ref     `keccak256(item.data)` of the TAKE item being authorised.
    ///                Ignored when `taker` is false.
    struct GrantSpec {
        address spender;
        address token;
        bool taker;
        bytes32 ref;
    }

    error OnlySettlement();
    error AmountOverflow();

    constructor(address settlement) {
        SETTLEMENT = settlement;
    }

    /// @inheritdoc IMakerModule
    /// @dev `amount` is the item's pro-rata slice, computed by Settlement. Giving
    ///      the grant item the SAME `Item.amount` as the item that consumes it
    ///      makes both slices identical under a partial fill, so the allowance is
    ///      consumed exactly and nothing is left over.
    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (msg.sender != SETTLEMENT) revert OnlySettlement();
        if (amount > type(uint160).max) revert AmountOverflow();
        GrantSpec memory g = abi.decode(data, (GrantSpec));
        IFunnelGrantee(onBehalfOf).grant(g.spender, g.token, uint160(amount), g.taker, g.ref);
    }
}
