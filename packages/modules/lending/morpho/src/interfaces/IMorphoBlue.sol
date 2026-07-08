// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ──────────────────── Minimal Morpho Blue singleton surface ────────────────────
//
// Morpho Blue is a single contract hosting every isolated market. A market is
// fully described by its `MarketParams`; its id is `keccak256(abi.encode(params))`.
// Unlike Aave there is no per-market pool address and no tokenised receipt
// (aToken / debtToken) — supply, collateral and borrow positions are tracked
// inside the singleton, keyed by `(id, account)`. Borrow and collateral-withdraw
// on someone else's behalf are gated by Morpho's own `setAuthorization`.

/// @notice The full description of an isolated Morpho market. Encoded into the
///         order item's `data`, so it is bound into the maker's EIP-712 hash.
struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

/// @notice A single account's state in one market.
struct Position {
    uint256 supplyShares;
    uint128 borrowShares;
    uint128 collateral;
}

/// @dev Market ids are bytes32. Aliased for readability against Morpho's ABI.
type Id is bytes32;

interface IMorphoBlue {
    function supply(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf, bytes memory data)
        external
        returns (uint256 assetsSupplied, uint256 sharesSupplied);

    function withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn);

    function borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalf,
        address receiver
    ) external returns (uint256 assetsBorrowed, uint256 sharesBorrowed);

    function repay(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalf, bytes memory data)
        external
        returns (uint256 assetsRepaid, uint256 sharesRepaid);

    function supplyCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, bytes memory data)
        external;

    function withdrawCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, address receiver)
        external;

    /// @notice Morpho-native delegation. The maker calls
    ///         `setAuthorization(module, true)` so a borrow / withdraw-collateral
    ///         module may manage their position. Coarse by design — the Permit3
    ///         taker allowance is what bounds the per-fill amount.
    function setAuthorization(address authorized, bool newIsAuthorized) external;

    function position(Id id, address user) external view returns (Position memory);

    function market(Id id)
        external
        view
        returns (
            uint128 totalSupplyAssets,
            uint128 totalSupplyShares,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares,
            uint128 lastUpdate,
            uint128 fee
        );

    function accrueInterest(MarketParams memory marketParams) external;
}

/// @notice Callback invoked by `Morpho.repay` when called with non-empty `data`.
///         Morpho computes the exact `assets` for the requested shares, fires
///         this callback, then pulls `assets` from the caller via transferFrom.
///         Lets the repayer fund the exact amount instead of pre-pulling a
///         buffer. See Morpho Blue `IMorphoRepayCallback`.
interface IMorphoRepayCallback {
    function onMorphoRepay(uint256 assets, bytes calldata data) external;
}

// ──────────────────── Market id helper ────────────────────

library MarketParamsLib {
    /// @dev Mirrors Morpho's own id derivation: the keccak of the tightly-packed
    ///      5 words of `MarketParams`. `abi.encode` of an all-word struct is the
    ///      same 160-byte layout, so this matches the on-chain id.
    function id(MarketParams memory marketParams) internal pure returns (Id) {
        return Id.wrap(keccak256(abi.encode(marketParams)));
    }
}
