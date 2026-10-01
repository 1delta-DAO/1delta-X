// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ──────────────────── Morpho Midnight structs ────────────────────
//
// Field order is load-bearing: it fixes the ABI encoding that Midnight's
// function selectors and — crucially — its market `id` derivation
// (`MidnightIdLib.toId`, an `abi.encode(market)` hash) are built on. These MUST
// mirror `morpho-org/midnight` `src/interfaces/IMidnight.sol` exactly.

struct CollateralParams {
    address token;
    uint256 lltv;
    uint256 liquidationCursor;
    address oracle;
}

struct Market {
    uint256 chainId;
    address midnight;
    address loanToken;
    CollateralParams[] collateralParams;
    uint256 maturity;
    uint256 rcfThreshold;
    address enterGate;
    address liquidatorGate;
}

struct Offer {
    Market market;
    bool buy;
    address maker;
    uint256 start;
    uint256 expiry;
    uint256 tick;
    bytes32 group;
    address callback;
    bytes callbackData;
    address receiverIfMakerIsSeller;
    address ratifier;
    bool reduceOnly;
    uint128 maxUnits;
    uint128 maxAssets;
    uint256 continuousFeeCap;
}

/// @notice Minimal Morpho Midnight surface used by the settlement modules.
///
///  Midnight is a fixed-rate, fixed-maturity, ORDER-BOOK lending primitive —
///  NOT a Morpho Blue fork. There is no pool `supply`/`borrow`: lending and
///  borrowing both happen through `take`, which consumes an off-chain-signed
///  maker `Offer` (lend = buy zero-coupon credit units, borrow = sell debt
///  units). Position lifecycle is handled by `supplyCollateral` /
///  `withdrawCollateral` / `repay` / `withdraw` (credit redemption).
interface IMidnight {
    // ── Position lifecycle ──

    /// @dev Inflow: pulls `assets` of `market.collateralParams[collateralIndex].token`
    ///      from `msg.sender` and credits it as collateral to `onBehalf`. Requires
    ///      `msg.sender == onBehalf` or `isAuthorized[onBehalf][msg.sender]`
    ///      (collateral-poisoning guard) — NOT permissionless.
    function supplyCollateral(Market memory market, uint256 collateralIndex, uint256 assets, address onBehalf) external;

    /// @dev Outflow: sends `assets` of the indexed collateral from `onBehalf`'s
    ///      position to `receiver`. Requires `msg.sender == onBehalf` or
    ///      `isAuthorized[onBehalf][msg.sender]`, and a health check.
    function withdrawCollateral(
        Market memory market,
        uint256 collateralIndex,
        uint256 assets,
        address onBehalf,
        address receiver
    ) external;

    /// @dev Inflow: reduces `onBehalf`'s debt by `units`. With `callback == 0`
    ///      the loan token is pulled from `msg.sender`; over-repay reverts. Pulls
    ///      exactly `units` loan tokens (1 unit == 1 token at repayment). Requires
    ///      `msg.sender == onBehalf` or `isAuthorized[onBehalf][msg.sender]`.
    function repay(Market memory market, uint256 units, address onBehalf, address callback, bytes calldata data)
        external;

    /// @dev Outflow: redeems `units` of `onBehalf`'s credit for the loan token,
    ///      sent to `receiver`. Requires `msg.sender == onBehalf` or authorization.
    function withdraw(Market memory market, uint256 units, address onBehalf, address receiver) external;

    /// @dev Order-book fill (the lend/borrow primitive). `offer.buy == true` ⇒
    ///      `taker` is the seller/borrower and Midnight sends `sellerAssets` to
    ///      `receiverIfTakerIsSeller`; `offer.buy == false` ⇒ `taker` is the
    ///      buyer/lender and Midnight pulls `buyerAssets` from the payer (which is
    ///      `msg.sender` when `takerCallback == 0`). Acting for a `taker !=
    ///      msg.sender` requires `isAuthorized[taker][msg.sender]`.
    /// @return buyerAssets loan-token amount on the buy side
    /// @return sellerAssets loan-token amount on the sell side
    function take(
        Offer memory offer,
        bytes memory ratifierData,
        uint256 units,
        address taker,
        address receiverIfTakerIsSeller,
        address takerCallback,
        bytes memory takerCallbackData
    ) external returns (uint256 buyerAssets, uint256 sellerAssets);

    /// @dev Multi-token flash loan: transfers each `assets[i]` of `tokens[i]` to
    ///      `callback`, invokes `callback.onFlashLoan(msg.sender, tokens, assets,
    ///      data)` (which must return `CALLBACK_SUCCESS`), then pulls each amount
    ///      back via `transferFrom(callback, ...)`.
    function flashLoan(address[] calldata tokens, uint256[] calldata assets, address callback, bytes calldata data)
        external;

    /// @dev Grants/revokes `authorized` the right to manage `onBehalf`'s position.
    ///      Callable by `onBehalf` OR any address it already authorized — a grant
    ///      is FULL control, re-delegation included.
    function setIsAuthorized(address authorized, bool newIsAuthorized, address onBehalf) external;

    /// @dev PERMISSIONLESS. Applies `user`'s pending loss-factor slash and accrued
    ///      continuous fee to their stored credit (what `withdraw` / `take` do
    ///      first) and returns the UPDATED `(credit, pendingFee, accruedFee)`.
    ///      Selector 0x545e513a, present on the Base singleton.
    function updatePosition(Market memory market, address user) external returns (uint128, uint128, uint128);

    /// @dev View twin of {updatePosition} (selector 0xd4de4974); `id` must be
    ///      `MidnightIdLib.toId(market)`.
    function updatePositionView(Market memory market, bytes32 id, address user)
        external
        view
        returns (uint128, uint128, uint128);

    // ── Position views (keyed by the market `id`) ──

    /// @dev Live debt of `user` in market `id`, in debt units.
    function debt(bytes32 id, address user) external view returns (uint128);

    /// @dev STORED credit (lend balance) of `user` in market `id`, in credit units.
    ///      ⚠ NOT up to date: the pending slash and continuous fee are applied
    ///      lazily, so `withdraw(credit())` can underflow. Size a full exit from
    ///      {updatePosition} instead.
    function credit(bytes32 id, address user) external view returns (uint128);

    /// @dev `user`'s collateral amount at `index` in market `id`.
    function collateral(bytes32 id, address user, uint256 index) external view returns (uint128);

    /// @dev Whether `borrower`'s position in `market` (`id`) is solvent.
    function isHealthy(Market memory market, bytes32 id, address borrower) external view returns (bool);
}

/// @notice The success sentinel a Midnight flash-loan receiver must return from
///         `onFlashLoan`. Equals `keccak256("morpho.midnight.callbackSuccess")`.
interface IMidnightFlashConstants {
    // solhint-disable-next-line func-name-mixedcase
    function CALLBACK_SUCCESS() external view returns (bytes32);
}

/// @notice Callback invoked by `Midnight.flashLoan` on the borrower.
interface IMidnightFlashLoanReceiver {
    function onFlashLoan(address caller, address[] calldata tokens, uint256[] calldata assets, bytes calldata data)
        external
        returns (bytes32);
}

/// @title MidnightIdLib
/// @notice Reproduces Midnight's `IdLib.toId` — the SSTORE2-pointer CREATE2
///         derivation used to key its position views (`debt`/`credit`/
///         `collateral`). A market's `id` is `keccak256(0xff ‖ market.midnight ‖
///         salt(0) ‖ keccak256(SSTORE2_PREFIX ‖ abi.encode(market)))`, i.e. the
///         CREATE2 address at which Midnight stores the market blob as runtime
///         code — returned here as the full `bytes32` the mappings are keyed by.
library MidnightIdLib {
    /// @dev SSTORE2 creation-code prefix (`morpho-org/midnight` `ConstantsLib`/
    ///      `IdLib`): deploys the appended blob as runtime bytecode.
    bytes internal constant SSTORE2_PREFIX = hex"600b380380600b5f395ff3";

    function toId(Market memory market) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                uint8(0xff),
                market.midnight,
                uint256(0),
                keccak256(abi.encodePacked(SSTORE2_PREFIX, abi.encode(market)))
            )
        );
    }
}
