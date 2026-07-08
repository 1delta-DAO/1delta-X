// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ──────────────────── Minimal Fluid (Vault protocol) surface ────────────────────
//
// Fluid splits responsibilities across the contracts that shape these modules:
//
//   • A *vault* (`IFluidVault`) is a single collateral / single debt lending
//     market. EVERY position mutation — supply, withdraw, borrow, payback —
//     flows through ONE function, `operate(nftId, newCol, newDebt, to)`, which
//     applies both legs and runs a SINGLE health check at the end. Sign
//     convention: `newCol > 0` deposit / `< 0` withdraw; `newDebt > 0` borrow /
//     `< 0` payback. `type(int256).min` is the "max" sentinel — withdraw the
//     entire collateral / pay back the entire debt. Withdrawn collateral and
//     borrowed debt are both sent to `to` (`address(0)` ⇒ `msg.sender`).
//
//   • The *Liquidity* layer holds all funds. When `operate` needs supply/payback
//     tokens it does NOT pull them via a plain allowance — the vault implements
//     `liquidityCallback`, and INSIDE the vault that callback runs
//     `transferFrom(operateCaller → LIQUIDITY)`. The contract executing that
//     `transferFrom` is the VAULT, so the funding `msg.sender` of `operate` must
//     have approved the **vault** as the ERC20 spender (NOT the Liquidity layer).
//     The vault recovers the pull source from `operate`'s `msg.sender`
//     automatically — the module just has to be that caller and have approved it.
//
//   • The *VaultFactory* (`IFluidVaultFactory`) is a standard ERC721: every
//     position is an NFT, and `operate` authorises value-OUT legs with a STRICT
//     owner check — `VAULT_FACTORY.ownerOf(nftId) != msg.sender` reverts. It does
//     NOT consult `getApproved` / `isApprovedForAll`, so an ERC721 approval alone
//     cannot authorise a borrow/withdraw. The only way a module can do value-out
//     without permanent custody is just-in-time: `transferFrom(user → module)`,
//     `operate(...)`, `transferFrom(module → user)`, all in one call. That round
//     trip needs a one-time `setApprovalForAll(module, true)` from the user — the
//     Fluid analogue of Aave `approveDelegation` / Euler `setAccountOperator`,
//     but necessarily broader (it covers every position the user holds on that
//     factory; the Permit3 amount-gate + pinned `nftId` are what bound each op).
//     `setApprovalForAll` survives transfers, so one grant keeps working.

interface IFluidVault {
    /// @notice The single entrypoint for all position mutations.
    /// @param nftId  position NFT id (0 ⇒ mint a fresh position to `msg.sender`).
    /// @param newCol  collateral delta: `> 0` supply, `< 0` withdraw,
    ///                `type(int256).min` withdraw the entire collateral.
    /// @param newDebt debt delta: `> 0` borrow, `< 0` payback,
    ///                `type(int256).min` pay back the entire debt.
    /// @param to     recipient of withdrawn collateral / borrowed debt
    ///               (`address(0)` ⇒ `msg.sender`).
    /// @return nftId_   the operated position id (the freshly minted id if 0 was passed)
    /// @return newCol_  the collateral amount actually applied (negative ⇒ withdrawn)
    /// @return newDebt_ the debt amount actually applied (negative ⇒ paid back)
    function operate(uint256 nftId, int256 newCol, int256 newDebt, address to)
        external
        payable
        returns (uint256 nftId_, int256 newCol_, int256 newDebt_);
}

/// @notice The ERC721 surface of Fluid's VaultFactory needed for just-in-time
///         custody of a value-out position. Standard ERC721 semantics:
///         `setApprovalForAll` survives transfers, so a single user grant keeps
///         working across fills.
interface IFluidVaultFactory {
    function ownerOf(uint256 tokenId) external view returns (address owner);
    function transferFrom(address from, address to, uint256 tokenId) external;
    function isApprovedForAll(address owner, address operator) external view returns (bool);
}
