// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ──────────────────── Minimal Silo v2 surface ────────────────────
//
// A Silo v2 market is a `SiloConfig` fronting TWO silos (`silo0` / `silo1`),
// one ERC-4626 vault per asset. To run a WETH-collateral / USDC-debt position
// you `deposit` into the WETH silo and `borrow` from the USDC silo — each silo
// is its own address, so a single-op module just needs the silo it acts on.
//
// The silo IS its own Collateral share token (the ERC-4626 share). Protected
// deposits use a separate share token; here we drive the common Collateral leg
// (the 2-arg `deposit` / 3-arg `withdraw` overloads default to Collateral).
//
// On-behalf model
// ───────────────
//   • borrow(assets, receiver, borrower) — value-out to `receiver` while the
//     debt lands on `borrower`. When `borrower != msg.sender` Silo consumes the
//     borrower's *receive allowance* on the debt share token, granted once via
//     `IShareToken.setReceiveApproval(module, cap)` — the Silo analogue of Aave
//     credit delegation. The module never needs the debt-share address.
//   • withdraw(assets, receiver, owner) — ERC-4626 owner allowance: when
//     `owner != msg.sender` the silo burns `owner`'s Collateral shares against
//     `allowance[owner][module]` (a standing `silo.approve(module, max)`), and
//     sends the underlying to `receiver`.
//   • deposit / repay are permissionless value-in (the module funds them).
interface ISilo {
    function asset() external view returns (address);

    /// @notice Deposit as Collateral (borrowable) — the 2-arg overload.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    /// @notice Deposit with an explicit collateral type (0 = Protected, 1 = Collateral).
    function deposit(uint256 assets, address receiver, uint8 collateralType) external returns (uint256 shares);

    /// @notice Withdraw underlying Collateral to `receiver`, burning `owner`'s shares.
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);

    /// @notice Redeem `shares` of Collateral to `receiver` from `owner`.
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    /// @notice Borrow `assets` to `receiver`, incurring debt on `borrower`.
    function borrow(uint256 assets, address receiver, address borrower) external returns (uint256 shares);

    /// @notice Repay `assets` of `borrower`'s debt (permissionless).
    function repay(uint256 assets, address borrower) external returns (uint256 shares);

    /// @notice Live debt of `borrower` in underlying units (upper bound for repay).
    function maxRepay(address borrower) external view returns (uint256 assets);

    /// @notice Max underlying `owner` can withdraw right now (liquidity-bounded).
    function maxWithdraw(address owner) external view returns (uint256 assets);
}

/// @notice The Silo debt share token's reverse-approval primitive. The borrower
///         calls `setReceiveApproval(module, cap)` so `module` may create up to
///         `cap` of debt on their behalf (`receiveAllowances[module][borrower]`).
///         Surfaced here only for reference / optional on-chain grant helpers —
///         the SDK emits it as a separate `PermissionType.Lender` step.
interface ISiloShareToken {
    function setReceiveApproval(address owner, uint256 amount) external;
    function receiveAllowance(address owner, address recipient) external view returns (uint256);
}
