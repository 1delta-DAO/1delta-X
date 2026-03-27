// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ILendingModule} from "../interfaces/ILendingModule.sol";

/// @notice Morpho Blue MarketParams
struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

/// @notice Morpho Blue position data
struct MorphoPosition {
    uint256 supplyShares;
    uint128 borrowShares;
    uint128 collateral;
}

/// @notice Morpho Blue market state
struct MorphoMarket {
    uint128 totalSupplyAssets;
    uint128 totalSupplyShares;
    uint128 totalBorrowAssets;
    uint128 totalBorrowShares;
    uint128 lastUpdate;
    uint128 fee;
}

/// @notice Minimal Morpho Blue interface
interface IMorpho {
    function supply(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalfOf, bytes memory)
        external
        returns (uint256, uint256);
    function supplyCollateral(MarketParams memory marketParams, uint256 assets, address onBehalfOf, bytes memory)
        external;
    function withdraw(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalfOf,
        address receiver
    ) external returns (uint256, uint256);
    function withdrawCollateral(
        MarketParams memory marketParams,
        uint256 assets,
        address onBehalfOf,
        address receiver
    ) external;
    function borrow(
        MarketParams memory marketParams,
        uint256 assets,
        uint256 shares,
        address onBehalfOf,
        address receiver
    ) external returns (uint256, uint256);
    function repay(MarketParams memory marketParams, uint256 assets, uint256 shares, address onBehalfOf, bytes memory)
        external
        returns (uint256, uint256);
    function position(bytes32 id, address user) external view returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);
    function market(bytes32 id) external view returns (uint128, uint128, uint128, uint128, uint128, uint128);
    function idToMarketParams(bytes32 id)
        external
        view
        returns (address loanToken, address collateralToken, address oracle, address irm, uint256 lltv);
}

/// @title MorphoLendingModule
/// @notice ILendingModule adapter for Morpho Blue.
/// @dev `data` encoding:
///      abi.encode(address morpho, MarketParams memory market, bool isCollateral)
///        - morpho: the Morpho Blue singleton address (supports forks)
///        - market: full MarketParams (loanToken, collateralToken, oracle, irm, lltv)
///        - isCollateral: true for collateral ops, false for loan-token (supply/withdraw lending)
contract MorphoLendingModule is ILendingModule {
    function deposit(address asset, uint256 amount, address onBehalfOf, bytes calldata data) external override {
        (address morpho, MarketParams memory market, bool isCollateral) =
            abi.decode(data, (address, MarketParams, bool));

        IERC20(asset).approve(morpho, amount);

        if (isCollateral) {
            IMorpho(morpho).supplyCollateral(market, amount, onBehalfOf, "");
        } else {
            IMorpho(morpho).supply(market, amount, 0, onBehalfOf, "");
        }
    }

    function withdraw(address asset, uint256 amount, address onBehalfOf, address to, bytes calldata data)
        external
        override
    {
        (address morpho, MarketParams memory market, bool isCollateral) =
            abi.decode(data, (address, MarketParams, bool));

        if (isCollateral) {
            IMorpho(morpho).withdrawCollateral(market, amount, onBehalfOf, to);
        } else {
            IMorpho(morpho).withdraw(market, amount, 0, onBehalfOf, to);
        }
    }

    function borrow(address asset, uint256 amount, address onBehalfOf, address to, bytes calldata data)
        external
        override
    {
        (address morpho, MarketParams memory market,) = abi.decode(data, (address, MarketParams, bool));

        IMorpho(morpho).borrow(market, amount, 0, onBehalfOf, to);
    }

    function repay(address asset, uint256 amount, address onBehalfOf, bytes calldata data) external override {
        (address morpho, MarketParams memory market,) = abi.decode(data, (address, MarketParams, bool));

        IERC20(asset).approve(morpho, amount);
        IMorpho(morpho).repay(market, amount, 0, onBehalfOf, "");
    }

    // ── Balance views ──

    /// @notice Returns collateral balance in the Morpho market
    function getCollateralBalance(address, address user, bytes calldata data)
        external
        view
        override
        returns (uint256)
    {
        (address morpho, MarketParams memory market,) = abi.decode(data, (address, MarketParams, bool));
        bytes32 id = _marketId(market);
        (,, uint128 collateral) = IMorpho(morpho).position(id, user);
        return collateral;
    }

    /// @notice Returns debt in underlying assets (borrow shares → assets conversion)
    function getDebtBalance(address, address user, bytes calldata data)
        external
        view
        override
        returns (uint256)
    {
        (address morpho, MarketParams memory market,) = abi.decode(data, (address, MarketParams, bool));
        bytes32 id = _marketId(market);
        (, uint128 borrowShares,) = IMorpho(morpho).position(id, user);
        if (borrowShares == 0) return 0;
        // fetch market totals for shares→assets conversion
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = IMorpho(morpho).market(id);
        // mulDivUp(shares, totalAssets + 1, totalShares + 1e6) — Morpho's virtual offset
        return _mulDivUp(borrowShares, uint256(totalBorrowAssets) + 1, uint256(totalBorrowShares) + 1e6);
    }

    /// @notice Returns supply shares → assets for the loan-token side
    function getLendingBalance(address, address user, bytes calldata data)
        external
        view
        override
        returns (uint256)
    {
        (address morpho, MarketParams memory market,) = abi.decode(data, (address, MarketParams, bool));
        bytes32 id = _marketId(market);
        (uint256 supplyShares,,) = IMorpho(morpho).position(id, user);
        if (supplyShares == 0) return 0;
        (uint128 totalSupplyAssets, uint128 totalSupplyShares,,,,) = IMorpho(morpho).market(id);
        // mulDivDown(shares, totalAssets + 1, totalShares + 1e6)
        return (supplyShares * (uint256(totalSupplyAssets) + 1)) / (uint256(totalSupplyShares) + 1e6);
    }

    // ── Internal helpers ──

    function _marketId(MarketParams memory market) internal pure returns (bytes32) {
        return keccak256(abi.encode(market));
    }

    function _mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y + d - 1) / d;
    }
}
