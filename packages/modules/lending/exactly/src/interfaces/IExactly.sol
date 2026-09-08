// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ──────────────────── Minimal Exactly Market surface ────────────────────
//
// Exactly is a fixed-rate / fixed-maturity ERC-4626 pool lender. One `Market`
// per asset (cross-margin via the `Auditor`); each Market is an ERC-4626 share
// vault PLUS floating + fixed (`…AtMaturity`) borrow/lend books. `maturity == 0`
// selects the floating pool; a non-zero unix timestamp selects a fixed pool.
//
// On-behalf model
// ───────────────
//   • borrow(assets, receiver, borrower) / withdraw(assets, receiver, owner) —
//     value-out to `receiver` while the debt/withdrawal lands on the third-party
//     principal. When the principal != msg.sender the Market spends the
//     principal's ERC-4626 **share allowance** granted to the caller — the maker
//     signs one `market.approve(module, max)` and it covers both legs. There is
//     no separate `approveDelegation` surface.
//   • deposit / repay are permissionless value-in (the module funds them).
//   • Collateral only counts once the maker has `Auditor.enterMarket(market)`
//     (a maker-side permission, not a module call — `enterMarket` uses msg.sender).
//
// Fixed legs are preview-bounded: `borrowAtMaturity`'s `maxAssets` and
// `…withdrawAtMaturity`'s `minAssetsRequired` are maker-signed slippage guards
// carried in the order `data`.
interface IExactlyMarket {
    function asset() external view returns (address);

    // ── floating ──
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function borrow(uint256 assets, address receiver, address borrower) external returns (uint256 borrowShares);
    function repay(uint256 assets, address borrower) external returns (uint256 actualRepay, uint256 borrowShares);
    function refund(uint256 borrowShares, address borrower) external returns (uint256 assets, uint256 actualShares);

    // ── fixed (`…AtMaturity`) ──
    function depositAtMaturity(uint256 maturity, uint256 assets, uint256 minAssetsRequired, address receiver)
        external
        returns (uint256 positionAssets);
    function withdrawAtMaturity(
        uint256 maturity,
        uint256 positionAssets,
        uint256 minAssetsRequired,
        address receiver,
        address owner
    ) external returns (uint256 assetsDiscounted);
    function borrowAtMaturity(uint256 maturity, uint256 assets, uint256 maxAssets, address receiver, address borrower)
        external
        returns (uint256 assetsOwed);
    // ⚠ ONE return word, matching the deployed Market.sol (`actualRepayAssets`).
    // This was declared as a two-word tuple until 2026-09-03 — a latent mismatch
    // that never surfaced because {ExactlyRepayModule} ignores the return (solc
    // skips return-data decoding for unused typed returns). Any caller that USES
    // the return would have reverted on decode against the live market; the
    // pre-funded repay module found it (its sweep needs `actualRepay`).
    function repayAtMaturity(uint256 maturity, uint256 positionAssets, uint256 maxAssets, address borrower)
        external
        returns (uint256 actualRepayAssets);

    // ── views ──
    function previewDebt(address borrower) external view returns (uint256 debt);
    function maxWithdraw(address owner) external view returns (uint256);

    // ── EIP-2612 (solmate ERC20 base) ──
    // The deployed Markets expose the full solmate permit triple, verified
    // on-fork against Optimism MarketUSDC/MarketWETH (each proxy computes its
    // own DOMAIN_SEPARATOR — they differ per market, so no cross-market permit
    // replay). This is what makes the share allowance a SIGNATURE instead of an
    // on-chain `approve`; see the permit tail in {ExactlyTakerModule}.
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;
    function nonces(address owner) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @notice The cross-margin risk hub. `enterMarket` is a maker-side permission
///         (uses msg.sender), surfaced here for reference only.
interface IExactlyAuditor {
    function enterMarket(address market) external;
    function exitMarket(address market) external;
}
