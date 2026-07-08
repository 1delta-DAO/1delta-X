// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ──────────────────── Minimal Euler V2 (EVK + EVC) surface ────────────────────
//
// Euler V2 splits responsibilities across two contracts:
//
//   • An EVK *vault* (`IEulerVault`) is an ERC-4626 lending vault for a single
//     `asset()`. It exposes `deposit`/`withdraw`/`redeem` (the 4626 side) plus a
//     borrowing extension `borrow`/`repay`/`debtOf`. A vault used as a borrow
//     market is the account's "controller"; a vault used as collateral is in the
//     account's "collateral set".
//
//   • The *EVC* (`IEVC`, Ethereum Vault Connector) is the shared authentication
//     and batching layer. Every vault defers its account/vault solvency checks to
//     the EVC, so multiple sub-operations batched through `EVC.batch` see a
//     SINGLE deferred liquidity check at the end of the batch.
//
// On-behalf-of model
// ──────────────────
// `deposit` and `repay` move value *into* a position and are permissionless on
// behalf of any `receiver` — a vault called directly routes itself through the
// EVC (its `callThroughEVC` modifier), so no operator status is needed (the
// inverse of Aave: tokens flow to the protocol). `borrow` and `withdraw` move
// value *out* and must be authenticated as the owner account: the module routes
// them via `EVC.call(vault, onBehalfOfAccount = user, …)`, which requires the
// user to have once granted the module operator rights
// (`EVC.setAccountOperator(user, module, true)`) and enabled the controller /
// collateral. This is the Euler analogue of Aave `approveDelegation` / Morpho
// `setAuthorization` / Comet `allow`.

interface IEulerVault {
    /// @notice The underlying ERC20 this vault lends/borrows.
    function asset() external view returns (address);

    /// @notice The Ethereum Vault Connector this vault is bound to.
    function EVC() external view returns (address);

    // ──────────────── ERC-4626 value-in / value-out ────────────────

    /// @notice Pull `amount` of `asset` from the caller and mint shares to
    ///         `receiver`. `amount == type(uint256).max` deposits the caller's
    ///         whole balance.
    function deposit(uint256 amount, address receiver) external returns (uint256 shares);

    /// @notice Burn `owner`'s shares worth `amount` assets and send the assets to
    ///         `receiver`. Must be authenticated as `owner` (directly or via the
    ///         EVC operator context). `amount == type(uint256).max` withdraws all.
    function withdraw(uint256 amount, address receiver, address owner) external returns (uint256 shares);

    /// @notice Burn `shares` from `owner` and send the redeemed assets to
    ///         `receiver`. `shares == type(uint256).max` redeems the full balance.
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    // ──────────────── Borrowing extension ────────────────

    /// @notice Create `amount` of debt on the authenticated account and send the
    ///         borrowed `asset` to `receiver`. Requires the account to have this
    ///         vault enabled as its controller. Must be routed through the EVC so
    ///         the vault sees the borrower as the on-behalf-of account.
    function borrow(uint256 amount, address receiver) external returns (uint256);

    /// @notice Pull `amount` of `asset` from the caller and reduce `receiver`'s
    ///         debt. Caps at the outstanding debt; `amount == type(uint256).max`
    ///         repays the whole debt. Permissionless on behalf of `receiver`.
    function repay(uint256 amount, address receiver) external returns (uint256);

    // ──────────────── Reads ────────────────

    /// @notice The account's current debt in underlying assets (accrued).
    function debtOf(address account) external view returns (uint256);

    /// @notice Max assets `owner` can currently withdraw given liquidity & health.
    function maxWithdraw(address owner) external view returns (uint256);

    /// @notice Owner's share balance (the ERC-4626 receipt).
    function balanceOf(address owner) external view returns (uint256);

    function convertToAssets(uint256 shares) external view returns (uint256);
}

interface IEVC {
    /// @notice One sub-operation of a `batch`. `onBehalfOfAccount` is the account
    ///         the call is authenticated as (the vault reads it back via
    ///         `getCurrentOnBehalfOfAccount`); `address(0)` targets the EVC itself.
    struct BatchItem {
        address targetContract;
        address onBehalfOfAccount;
        uint256 value;
        bytes data;
    }

    /// @notice Execute a single call as `onBehalfOfAccount`. The caller must be the
    ///         account owner or an authorised operator. Used to route a lone
    ///         borrow / withdraw so the target vault authenticates the user.
    function call(address targetContract, address onBehalfOfAccount, uint256 value, bytes calldata data)
        external
        payable
        returns (bytes memory result);

    /// @notice Execute an ordered list of calls atomically with a SINGLE deferred
    ///         account/vault status check at the end — the primitive that lets a
    ///         multi-leg op pass through a transiently-invalid intermediate state.
    function batch(BatchItem[] calldata items) external payable;

    /// @notice Add `vault` to `account`'s controller set (required before borrow).
    function enableController(address account, address vault) external;

    /// @notice Add `vault` to `account`'s collateral set.
    function enableCollateral(address account, address vault) external;

    /// @notice Grant/revoke `operator` the right to act for `account`. The maker
    ///         calls this once so a borrow / withdraw / batch module may manage
    ///         their position; the Permit3 taker allowance bounds the per-fill size.
    function setAccountOperator(address account, address operator, bool authorized) external;

    function isAccountOperatorAuthorized(address account, address operator) external view returns (bool);
}
