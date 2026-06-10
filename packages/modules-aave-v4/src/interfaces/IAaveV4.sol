// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ──────────────────── Minimal Aave V4 surface ────────────────────
//
// Aave V4 uses a Hub/Spoke architecture with *position managers* as
// intermediaries. Direct spoke calls require governance whitelisting, so all
// user actions route through a position manager the user has approved on the
// spoke via `setUserPositionManager`:
//
//   - GiverPositionManager — supply / repay. The *caller* funds the tokens, so
//     the module must hold the underlying and ERC20-approve it to the giver PM.
//   - TakerPositionManager — withdraw / borrow. These have no `receiver`
//     parameter: proceeds land at the caller (the module) and are forwarded on.
//     The owner must additionally grant a per-(spoke, reserveId) allowance to
//     the caller via `approveWithdraw` / `approveBorrow`.
//
// `reserveId` identifies the (hub, asset) reserve on the spoke; `spoke` and the
// position-manager address are passed per call so the same module drives any
// V4 spoke deployment.

interface IGiverPositionManager {
    function supplyOnBehalfOf(address spoke, uint256 reserveId, uint256 amount, address onBehalfOf)
        external
        returns (uint256 shares, uint256 assets);

    function repayOnBehalfOf(address spoke, uint256 reserveId, uint256 amount, address onBehalfOf)
        external
        returns (uint256 shares, uint256 assets);
}

interface ITakerPositionManager {
    function withdrawOnBehalfOf(address spoke, uint256 reserveId, uint256 amount, address onBehalfOf)
        external
        returns (uint256 shares, uint256 assets);

    function borrowOnBehalfOf(address spoke, uint256 reserveId, uint256 amount, address onBehalfOf)
        external
        returns (uint256 shares, uint256 assets);

    // ── Owner-side allowance grants (the V4-native gate for TAKE ops) ──
    function approveWithdraw(address spoke, uint256 reserveId, address spender, uint256 amount) external;
    function approveBorrow(address spoke, uint256 reserveId, address spender, uint256 amount) external;
}

interface ISpokeV4 {
    function setUserPositionManager(address positionManager, bool approve) external;
    // Enable/disable a reserve as collateral for the caller's position. Unlike v3,
    // a freshly supplied v4 reserve is NOT auto-enabled as collateral, so a borrow
    // against it requires this to have been called first.
    function setUsingAsCollateral(uint256 reserveId, bool usingAsCollateral, address onBehalfOf) external;
    function getUserSuppliedAssets(uint256 reserveId, address user) external view returns (uint256);
    function getUserTotalDebt(uint256 reserveId, address user) external view returns (uint256);
}
