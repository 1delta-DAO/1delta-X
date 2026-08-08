// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ──────────────────── Minimal DolomiteMargin surface ────────────────────
//
// DolomiteMargin is a single margin engine: every state change — supply,
// withdraw, borrow, repay, trade, liquidate — is expressed as an `ActionArgs`
// and submitted in a batch to `operate(accounts, actions)`. The engine applies
// all actions and runs ONE collateralisation check at the end, so a batch may
// pass through a transiently-undercollateralised intermediate state. This is the
// Dolomite analogue of Euler's `EVC.batch`.
//
// Amounts are described by an `AssetAmount`:
//   • `sign`         — true = increase the account's balance (supply/repay),
//                      false = decrease it (withdraw/borrow).
//   • `denomination` — Wei (underlying units) or Par (interest-index units).
//   • `ref`          — Delta (relative change) or Target (absolute end balance).
// A full close is `(sign:true, Par, Target, 0)` — "end at exactly zero".
//
// On-behalf-of model
// ──────────────────
// `operate` requires `msg.sender` to be the account owner or a *local operator*
// the owner authorised via `setOperators`. EVERY op (including deposit) goes
// through `operate`, so a module must be a local operator of the user — the
// Dolomite analogue of Aave `approveDelegation` / Morpho `setAuthorization`.
//
// The structs below are flattened from DolomiteMargin's library-namespaced types
// (`Account.Info`, `Types.AssetAmount`, `Actions.ActionArgs`). The ABI tuple
// layout — and therefore the `operate` selector and calldata — is identical.

struct AccountInfo {
    address owner;
    uint256 number;
}

enum AssetDenomination {
    Wei, // underlying token amount
    Par // principal/index amount
}

enum AssetReference {
    Delta, // relative change from the current value
    Target // absolute end value
}

struct AssetAmount {
    bool sign; // true if positive (increase balance)
    AssetDenomination denomination;
    AssetReference ref;
    uint256 value;
}

struct WeiBalance {
    bool sign; // true if positive (a supply/collateral balance); false = debt
    uint256 value;
}

enum ActionType {
    Deposit, // supply tokens (pull from `otherAddress`)
    Withdraw, // withdraw/borrow tokens (send to `otherAddress`)
    Transfer,
    Buy,
    Sell,
    Trade,
    Liquidate,
    Vaporize,
    Call
}

struct ActionArgs {
    ActionType actionType;
    uint256 accountId; // index into the `accounts` array
    AssetAmount amount;
    uint256 primaryMarketId;
    uint256 secondaryMarketId;
    address otherAddress; // funds source (Deposit) / destination (Withdraw)
    uint256 otherAccountId;
    bytes data;
}

struct OperatorArg {
    address operator;
    bool trusted;
}

interface IDolomiteMargin {
    /// @notice Apply `actions` to `accounts` atomically, with a single end-of-call
    ///         collateralisation check. `msg.sender` must own or be a local
    ///         operator of every referenced account.
    function operate(AccountInfo[] calldata accounts, ActionArgs[] calldata actions) external;

    /// @notice Authorise/deauthorise local operators for `msg.sender`'s accounts.
    function setOperators(OperatorArg[] calldata args) external;

    /// @notice The account's signed balance in `marketId` (underlying units).
    ///         `sign==false` ⇒ the magnitude is debt.
    function getAccountWei(AccountInfo calldata account, uint256 marketId) external view returns (WeiBalance memory);

    function getIsLocalOperator(address owner, address operator) external view returns (bool);

    function getMarketIdByTokenAddress(address token) external view returns (uint256);

    function getMarketTokenAddress(uint256 marketId) external view returns (address);
}
