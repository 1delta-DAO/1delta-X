// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ──────────────────── Minimal Gearbox V3 surface ────────────────────
//
// Gearbox V3 has TWO distinct lending surfaces:
//
//   1. The passive **PoolV3** — a plain ERC-4626 vault (LPs supply the
//      borrowable asset). Clean MAKE/TAKE, exactly like Silo/Exactly's vault leg.
//
//   2. The **credit-account** (leverage) side — each user's position is a
//      separate account contract, operated by an array of sub-calls through the
//      `CreditFacadeV3`. On-behalf operation runs via the **bot** model:
//      `setBotPermissions(bot, permissions)` lets `bot` drive the account through
//      `botMulticall`. This is the Gearbox analogue of Dolomite `setOperators` —
//      a real delegation path (the SDK's Matrix C "no delegation" reflects the
//      SDK direct route, not the on-chain surface).

/// @notice PoolV3 ERC-4626 vault (the passive supply side).
interface IGearboxPoolV3 {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function maxWithdraw(address owner) external view returns (uint256);
}

/// @notice One sub-call inside a (bot)multicall — `target` is normally the
///         CreditFacade itself (self-calls the facade interprets).
struct MultiCall {
    address target;
    bytes callData;
}

interface IGearboxCreditFacadeV3 {
    /// @notice Drive `creditAccount` through `calls`. Callable by a bot the account
    ///         owner authorised via `setBotPermissions`.
    function botMulticall(address creditAccount, MultiCall[] calldata calls) external;
}

/// @notice The self-call surface interpreted inside a (bot)multicall.
interface IGearboxCreditFacadeV3Multicall {
    function addCollateral(address token, uint256 amount) external;
    function increaseDebt(uint256 amount) external;
    function decreaseDebt(uint256 amount) external;
    function withdrawCollateral(address token, uint256 amount, address to) external;
}
