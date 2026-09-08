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

/// @notice Lista's NATIVE collateral provider (the WBNB/WETH markets where
///         `Moolah.providers(id, wrappedNative)` is set). NOT a plain
///         forwarder: its `supplyCollateral` is a 3-arg PAYABLE (the amount is
///         `msg.value`, wrapped by the provider — the Morpho-shaped 4-arg ERC20
///         selector reverts), and its `withdrawCollateral` keeps Morpho's 4-arg
///         shape but UNWRAPS and pays `receiver` native. Modules bridge
///         wrapped↔native at this boundary ({ListaNativeModules}); the maker
///         side stays ERC20 throughout.
interface IListaNativeProvider {
    /// @notice Supply `msg.value` (wrapped by the provider) as collateral for
    ///         `onBehalf`. Permissionless on behalf.
    function supplyCollateral(MarketParams memory marketParams, address onBehalf, bytes memory data) external payable;

    /// @notice Withdraw `assets` collateral for `onBehalf` (gated by
    ///         `Moolah.isAuthorized`), unwrap, send NATIVE to `receiver`.
    function withdrawCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, address receiver)
        external;
}

/// @notice Lista's SmartLP collateral provider (`SmartProvider`) — the ONE
///         provider shape that is NOT Morpho-shaped. The market's collateral
///         token is a receipt over a two-coin StableSwap LP that only Moolah can
///         hold (`mint`/`burn` minter-only, `transfer` `onlyMoolah`), so deposits
///         take the POOL COINS and withdrawals pay them back out — the receipt
///         itself is never approvable or transferable by a user or module.
///
///         Authorization (verified against the deployed provider):
///         - `supplyCollateral` has NO auth check — anyone may fund anyone;
///           only ERC20 approvals of the coins to the provider are needed.
///         - every withdraw requires `msg.sender == onBehalf ||
///           Moolah.isAuthorized(onBehalf, msg.sender)` — the SAME Moolah grant
///           the broker borrow and plain collateral withdraw ride.
interface IListaSmartProvider {
    /// @notice Zap `amount0`/`amount1` of the pool's coins (order from
    ///         `dex.coins(i)`, NEVER the symbol) into LP and credit the minted
    ///         receipt to `onBehalf`'s Moolah position. The position is credited
    ///         with the LP ACTUALLY minted (a balance delta) — `minLpAmount` is
    ///         the only floor. When a coin is the chain's native (the 0xEeee…
    ///         sentinel), that coin's amount must equal `msg.value`.
    ///         Selector 0x2f1a11e1.
    function supplyCollateral(
        MarketParams memory marketParams,
        address onBehalf,
        uint256 amount0,
        uint256 amount1,
        uint256 minLpAmount
    ) external payable;

    /// @notice Burn `collateralAmount` LP units from `onBehalf`'s position and
    ///         pay out ONE pool coin `i` to `receiver` (≥ `minCoinOut`).
    ///         Selector 0x5c16d49f.
    function withdrawCollateralOneCoin(
        MarketParams memory marketParams,
        uint256 collateralAmount,
        uint256 i,
        uint256 minCoinOut,
        address onBehalf,
        address receiver
    ) external;
}

/// @notice The Lista fixed-term `LendingBroker` — the debt-side gateway.
interface IListaBroker {
    /// @notice On-behalf FIXED-term borrow. `user` is the debtor (gated by the
    ///         user's Moolah authorization of msg.sender); proceeds go to
    ///         `receiver`. Matches the on-chain `_listaBrokerBorrow` path.
    function borrow(uint256 amount, uint256 termId, address user, address receiver) external;

    /// @notice On-behalf FIXED repay of position `loanId`. The broker
    ///         `transferFrom`s the LITERAL `amount` from msg.sender, consumes up
    ///         to the live debt (interest-first, early-repay penalty included)
    ///         and refunds the excess to msg.sender. `amount == 0` reverts
    ///         `ZeroAmount()` — there is no repay-from-balance convention.
    function repay(uint256 amount, uint256 loanId, address onBehalf) external;

    /// @notice On-behalf FLEX (dynamic) repay. Selected when `loanId ==
    ///         LISTA_BROKER_DYNAMIC_LOAN` (type(uint128).max). Same
    ///         literal-pull / refund-excess / zero-reverts semantics.
    function repay(uint256 amount, address onBehalf) external;

    /// @notice On-behalf FULL close: retires the dynamic position AND every
    ///         fixed position (early-repay penalties included), repaid by
    ///         SHARES so no dust remains — immune to the refinance-bot race.
    ///         Pulls EXACTLY the live total debt from msg.sender via
    ///         `transferFrom` (allowance and balance must cover accrual between
    ///         quote and execution — approve a ceiling) and refunds nothing.
    ///         Selector 0x7c27383b, verified present on both deployed
    ///         implementation generations (pre-upgrade 0xf71b…709f and current).
    function repayAll(address onBehalf) external;
}

library MarketParamsLib {
    function id(MarketParams memory marketParams) internal pure returns (Id) {
        return Id.wrap(keccak256(abi.encode(marketParams)));
    }
}
