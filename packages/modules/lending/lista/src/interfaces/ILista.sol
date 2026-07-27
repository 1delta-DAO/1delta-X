// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ──────────────────── Minimal Lista (Moolah + LendingBroker) surface ────────────────────
//
// Lista's core is a **Moolah** — a Morpho Blue fork — so COLLATERAL lives in the
// Moolah singleton under the user's address, keyed by an identical `MarketParams`
// and gated by Morpho's `setAuthorization(module, true)`. The **debt side** of a
// brokered market is overlaid by a `LendingBroker` (one dynamic + N fixed
// positions); borrow/repay route through the broker, not through Moolah's own
// `borrow`. Collateral is shared across the broker's positions.
//
// Only the FIXED-term broker borrow is delegable — `broker.borrow(amount, termId,
// user, receiver)` runs on-behalf and is gated by the user's Moolah
// authorization. The FLEX (dynamic) borrow is a bare `broker.borrow(uint256)`,
// `msg.sender`-only, so it cannot be driven by a module (out of scope).

/// @notice Morpho-shaped market descriptor (identical layout to Morpho Blue).
struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

struct Position {
    uint256 supplyShares;
    uint128 borrowShares;
    uint128 collateral;
}

type Id is bytes32;

/// @notice The Moolah singleton — the collateral custodian. Morpho-shaped.
interface IMoolah {
    function supplyCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, bytes memory data)
        external;
    function withdrawCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, address receiver)
        external;
    /// @notice Morpho-native delegation: the maker calls `setAuthorization(module,
    ///         true)` so the withdraw-collateral / broker-borrow module may manage
    ///         their position. The broker's on-behalf borrow checks this same flag.
    function setAuthorization(address authorized, bool newIsAuthorized) external;
    function position(Id id, address user) external view returns (Position memory);
}

/// @notice The Lista fixed-term `LendingBroker` — the debt-side gateway.
interface IListaBroker {
    /// @notice On-behalf FIXED-term borrow. `user` is the debtor (gated by the
    ///         user's Moolah authorization of msg.sender); proceeds go to
    ///         `receiver`. Matches the on-chain `_listaBrokerBorrow` path.
    function borrow(uint256 amount, uint256 termId, address user, address receiver) external;

    /// @notice On-behalf FIXED repay of position `loanId`. `amount == 0` repays as
    ///         much of the debt as msg.sender's balance/allowance covers and
    ///         refunds the excess to msg.sender.
    function repay(uint256 amount, uint256 loanId, address onBehalf) external;

    /// @notice On-behalf FLEX (dynamic) repay. Selected when `loanId ==
    ///         LISTA_BROKER_DYNAMIC_LOAN` (type(uint128).max).
    function repay(uint256 amount, address onBehalf) external;
}

library MarketParamsLib {
    function id(MarketParams memory marketParams) internal pure returns (Id) {
        return Id.wrap(keccak256(abi.encode(marketParams)));
    }
}
