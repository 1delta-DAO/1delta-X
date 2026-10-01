// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Market, Offer, MidnightIdLib} from "../../src/interfaces/IMidnight.sol";
import {IBuyCallback, ISellCallback} from "../../src/interfaces/ICallbacks.sol";

/// @dev Minimal mintable ERC20 for the mock-based Midnight harness (no fork).
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

interface IERC20Min {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

interface IMidnightFlashLoanReceiver {
    function onFlashLoan(address caller, address[] calldata tokens, uint256[] calldata assets, bytes calldata data)
        external
        returns (bytes32);
}

/// @dev Midnight's offer ratifier hook (`morpho-org/midnight` `IRatifier`).
interface IRatifier {
    function isRatified(Offer memory offer, bytes memory ratifierData, address taker) external view returns (bytes32);
}

/// @dev A ratifier that approves every offer — stands in for the maker's
///      signature ratifier, whose crypto is Morpho's concern, not the modules'.
contract MockRatifier is IRatifier {
    function isRatified(Offer memory, bytes memory, address) external pure returns (bytes32) {
        return keccak256("morpho.midnight.callbackSuccess");
    }
}

/// @notice Morpho Midnight stand-in for the settlement-module unit suite.
///
///  FIDELITY (2026-09-30, audit L-ML-8). This mock used to diverge from the
///  deployed venue (`morpho-org/midnight` `src/Midnight.sol`, Base singleton
///  0xAded…A18A) on four load-bearing semantics, and the suite was green BECAUSE
///  of it. It now reproduces each of them:
///
///   1. AUTH ON EVERY POSITION WRITE. `supplyCollateral` and `repay` are gated on
///      `onBehalf == msg.sender || isAuthorized[onBehalf][msg.sender]` exactly like
///      `withdraw` / `withdrawCollateral` / `take` (upstream L497, L519 — "prevent
///      activated collateral poisoning"). A module that supplies or repays for a
///      maker needs the maker's `setIsAuthorized` grant.
///   2. RE-DELEGATION. `setIsAuthorized` accepts an already-authorized caller, not
///      only `onBehalf` itself (upstream L725-727) — a grant is FULL control.
///   3. LAZY POSITION UPDATE. `credit()` returns the RAW stored credit; `withdraw`
///      / `updatePosition` first apply the pending slash + continuous fee
///      ({setPendingCreditCut} models both), so withdrawing a stale `credit()`
///      underflows (upstream L473-485, L793-839).
///   4. TAKE ECONOMICS + CHECKS. The per-market settlement fee ({setSettlementFee})
///      is taken out of the SELLER's proceeds on a buy offer and added to the
///      BUYER's cost on a sell offer; `maxUnits` / `maxAssets` consumption
///      (exactly one non-zero), `SelfTake`, `UnusedReceiverMustBeZero`, and the
///      ratifier gate (`isAuthorized[maker][ratifier]` + `isRatified`) are all
///      enforced; the payer is resolved as upstream (`buyerCallback`, else the
///      maker on a buy offer, else `msg.sender`) and the seller's solvency is
///      checked after the sell callback.
///
///  Prices stay at par (1 unit ⇔ 1 loan token at tick 0, before fees): ticks,
///  maturity discounting and liquidation are Morpho's concern, not the modules'.
///  `seed*` helpers set up positions without a full order-book open.
contract MidnightMock {
    bytes32 public constant CALLBACK_SUCCESS = keccak256("morpho.midnight.callbackSuccess");
    uint256 internal constant WAD = 1e18;

    // id → user → value
    mapping(bytes32 => mapping(address => uint128)) internal _debt;
    mapping(bytes32 => mapping(address => uint128)) internal _credit;
    // id → user → collateralIndex → value
    mapping(bytes32 => mapping(address => mapping(uint256 => uint128))) internal _collateral;
    // onBehalf → authorized → allowed
    mapping(address => mapping(address => bool)) public isAuthorized;
    // collateral token → price in loan-token wei per collateral wei, 1e18-scaled
    // (0 ⇒ par, i.e. 1:1 in raw units). Only used by the modeled solvency check.
    mapping(address => uint256) internal _price;
    // maker → group → consumed units/assets
    mapping(address => mapping(bytes32 => uint256)) public consumed;
    // id → settlement fee, WAD per unit (price at tick 0 is WAD)
    mapping(bytes32 => uint256) public settlementFee;
    // id → user → credit the next position update slashes/accrues away
    mapping(bytes32 => mapping(address => uint128)) public pendingCreditCut;

    error Unauthorized();
    error TakerUnauthorized();
    error InvalidOfferCaps();
    error SelfTake();
    error UnusedReceiverMustBeZero();
    error RatifierUnauthorized();
    error RatifierFailed();
    error ConsumedAssets();
    error ConsumedUnits();

    // ──────────────────── views ────────────────────

    function debt(bytes32 id, address user) external view returns (uint128) {
        return _debt[id][user];
    }

    /// @dev RAW stored credit — NOT up to date (upstream NatSpec: "use
    ///      updatePositionView").
    function credit(bytes32 id, address user) external view returns (uint128) {
        return _credit[id][user];
    }

    function collateral(bytes32 id, address user, uint256 index) external view returns (uint128) {
        return _collateral[id][user][index];
    }

    /// @dev Modeled solvency check: Σ collateral_i · price_i · lltv_i ≥ debt.
    function isHealthy(Market memory market, bytes32 id, address user) external view returns (bool) {
        return _isHealthy(market, id, user);
    }

    function _isHealthy(Market memory market, bytes32 id, address user) internal view returns (bool) {
        uint256 weightedByLltv;
        uint256 n = market.collateralParams.length;
        for (uint256 i; i < n; i++) {
            uint256 c = _collateral[id][user][i];
            if (c == 0) continue;
            uint256 price = _price[market.collateralParams[i].token];
            if (price == 0) price = 1e18; // par
            uint256 valueInLoan = (c * price) / 1e18;
            weightedByLltv += (valueInLoan * market.collateralParams[i].lltv) / 1e18;
        }
        return weightedByLltv >= _debt[id][user];
    }

    // ──────────────────── test-only knobs ────────────────────

    /// @dev Set the collateral price used by the modeled solvency check.
    function setPrice(address collateralToken, uint256 priceWad) external {
        _price[collateralToken] = priceWad;
    }

    /// @dev Model a `feeSetter` settlement-fee change (`setMarketSettlementFee`).
    function setSettlementFee(Market memory market, uint256 feeWad) external {
        settlementFee[MidnightIdLib.toId(market)] = feeWad;
    }

    /// @dev Model a loss-factor slash and/or accrued continuous fee: the next
    ///      position update lowers `user`'s credit by `cut`.
    function setPendingCreditCut(Market memory market, address user, uint128 cut) external {
        pendingCreditCut[MidnightIdLib.toId(market)][user] = cut;
    }

    // ──────────────────── authorization ────────────────────

    function setIsAuthorized(address authorized, bool newIsAuthorized, address onBehalf) external {
        _requireAuth(onBehalf);
        isAuthorized[onBehalf][authorized] = newIsAuthorized;
    }

    function _requireAuth(address onBehalf) internal view {
        if (msg.sender != onBehalf && !isAuthorized[onBehalf][msg.sender]) revert Unauthorized();
    }

    // ──────────────────── position update ────────────────────

    function updatePositionView(Market memory, bytes32 id, address user)
        public
        view
        returns (uint128 newCredit, uint128 newPendingFee, uint128 accruedFee)
    {
        uint128 c = _credit[id][user];
        uint128 cut = pendingCreditCut[id][user];
        if (cut > c) cut = c;
        return (c - cut, 0, cut);
    }

    function updatePosition(Market memory market, address user) external returns (uint128, uint128, uint128) {
        return _updatePosition(market, MidnightIdLib.toId(market), user);
    }

    function _updatePosition(Market memory market, bytes32 id, address user)
        internal
        returns (uint128 newCredit, uint128 newPendingFee, uint128 accruedFee)
    {
        (newCredit, newPendingFee, accruedFee) = updatePositionView(market, id, user);
        _credit[id][user] = newCredit;
        pendingCreditCut[id][user] = 0;
    }

    // ──────────────────── position lifecycle ────────────────────

    function supplyCollateral(Market memory market, uint256 collateralIndex, uint256 assets, address onBehalf)
        external
    {
        _requireAuth(onBehalf); // upstream L519
        address token = market.collateralParams[collateralIndex].token;
        IERC20Min(token).transferFrom(msg.sender, address(this), assets);
        _collateral[MidnightIdLib.toId(market)][onBehalf][collateralIndex] += uint128(assets);
    }

    function withdrawCollateral(
        Market memory market,
        uint256 collateralIndex,
        uint256 assets,
        address onBehalf,
        address receiver
    ) external {
        _requireAuth(onBehalf);
        bytes32 id = MidnightIdLib.toId(market);
        _collateral[id][onBehalf][collateralIndex] -= uint128(assets);
        require(_isHealthy(market, id, onBehalf), "UnhealthyBorrower");
        IERC20Min(market.collateralParams[collateralIndex].token).transfer(receiver, assets);
    }

    function repay(Market memory market, uint256 units, address onBehalf, address callback, bytes memory) external {
        _requireAuth(onBehalf); // upstream L497
        require(callback == address(0), "mock: repay callback unsupported"); // modules force 0
        _debt[MidnightIdLib.toId(market)][onBehalf] -= uint128(units); // reverts on over-repay
        // callback == 0 ⇒ payer is msg.sender (the module); 1 unit == 1 token.
        IERC20Min(market.loanToken).transferFrom(msg.sender, address(this), units);
    }

    function withdraw(Market memory market, uint256 units, address onBehalf, address receiver) external {
        _requireAuth(onBehalf);
        bytes32 id = MidnightIdLib.toId(market);
        _updatePosition(market, id, onBehalf); // slash + fee FIRST, like upstream
        _credit[id][onBehalf] -= uint128(units);
        IERC20Min(market.loanToken).transfer(receiver, units);
    }

    /// @dev One fill's resolved parties and amounts — a struct only to stay under
    ///      the legacy stack limit.
    struct Fill {
        bytes32 id;
        uint256 units;
        address buyer;
        address seller;
        address payer;
        address receiver;
        address buyerCallback;
        address sellerCallback;
        bytes buyerData;
        bytes sellerData;
        uint256 buyerAssets;
        uint256 sellerAssets;
    }

    function take(
        Offer memory offer,
        bytes memory ratifierData,
        uint256 units,
        address taker,
        address receiverIfTakerIsSeller,
        address takerCallback,
        bytes memory takerCallbackData
    ) external returns (uint256, uint256) {
        if (taker != msg.sender && !isAuthorized[taker][msg.sender]) revert TakerUnauthorized();
        _checkOffer(offer, ratifierData, taker, receiverIfTakerIsSeller);

        Fill memory f;
        f.id = MidnightIdLib.toId(offer.market);
        f.units = units;
        (f.buyerAssets, f.sellerAssets) = _prices(offer.buy, f.id, units);
        _consume(offer, units, f.buyerAssets, f.sellerAssets);
        (f.buyer, f.seller) = offer.buy ? (offer.maker, taker) : (taker, offer.maker);
        _movePositions(f.id, f.buyer, f.seller, units);

        f.buyerCallback = offer.buy ? offer.callback : takerCallback;
        f.sellerCallback = offer.buy ? takerCallback : offer.callback;
        f.buyerData = offer.buy ? offer.callbackData : takerCallbackData;
        f.sellerData = offer.buy ? takerCallbackData : offer.callbackData;
        f.payer = f.buyerCallback != address(0) ? f.buyerCallback : (offer.buy ? f.buyer : msg.sender);
        f.receiver = offer.buy ? receiverIfTakerIsSeller : offer.receiverIfMakerIsSeller;

        _settle(offer.market, f);
        return (f.buyerAssets, f.sellerAssets);
    }

    function _checkOffer(Offer memory offer, bytes memory ratifierData, address taker, address receiverIfTakerIsSeller)
        private
        view
    {
        if ((offer.maxAssets == 0) == (offer.maxUnits == 0)) revert InvalidOfferCaps();
        if (offer.maker == taker) revert SelfTake();
        if (offer.buy ? offer.receiverIfMakerIsSeller != address(0) : receiverIfTakerIsSeller != address(0)) {
            revert UnusedReceiverMustBeZero();
        }
        if (!isAuthorized[offer.maker][offer.ratifier]) revert RatifierUnauthorized();
        if (IRatifier(offer.ratifier).isRatified(offer, ratifierData, taker) != CALLBACK_SUCCESS) {
            revert RatifierFailed();
        }
    }

    /// @dev Upstream order: buy callback → pull fee + proceeds from the payer →
    ///      sell callback → seller solvency.
    function _settle(Market memory market, Fill memory f) private {
        if (f.buyerCallback != address(0)) {
            require(
                IBuyCallback(f.buyerCallback).onBuy(f.id, market, f.buyerAssets, f.units, 0, f.buyer, f.buyerData)
                    == CALLBACK_SUCCESS,
                "WrongBuyCallbackReturnValue"
            );
        }
        IERC20Min(market.loanToken).transferFrom(f.payer, address(this), f.buyerAssets - f.sellerAssets);
        IERC20Min(market.loanToken).transferFrom(f.payer, f.receiver, f.sellerAssets);
        if (f.sellerCallback != address(0)) {
            require(
                ISellCallback(f.sellerCallback)
                    .onSell(f.id, market, f.sellerAssets, f.units, 0, f.seller, f.receiver, f.sellerData)
                == CALLBACK_SUCCESS,
                "WrongSellCallbackReturnValue"
            );
        }
        require(_isHealthy(market, f.id, f.seller), "SellerIsLiquidatable");
    }

    /// @dev Par price (tick 0 ⇒ WAD). Buy offer: the seller (taker) gets
    ///      `price − fee`, rounded down. Sell offer: the buyer (taker) pays
    ///      `price + fee`, rounded up. The difference is the venue's fee.
    function _prices(bool buy, bytes32 id, uint256 units) private view returns (uint256 buyerAssets, uint256 sellerAssets) {
        uint256 fee = settlementFee[id];
        if (buy) {
            sellerAssets = (units * (WAD - fee)) / WAD;
            buyerAssets = units; // (sellerPrice + fee) == WAD
        } else {
            sellerAssets = units;
            buyerAssets = (units * (WAD + fee) + WAD - 1) / WAD;
        }
    }

    function _consume(Offer memory offer, uint256 units, uint256 buyerAssets, uint256 sellerAssets) private {
        uint256 newConsumed;
        if (offer.maxAssets > 0) {
            newConsumed = consumed[offer.maker][offer.group] + (offer.buy ? buyerAssets : sellerAssets);
            if (newConsumed > offer.maxAssets) revert ConsumedAssets();
        } else {
            newConsumed = consumed[offer.maker][offer.group] + units;
            if (newConsumed > offer.maxUnits) revert ConsumedUnits();
        }
        consumed[offer.maker][offer.group] = newConsumed;
    }

    /// @dev Upstream netting: the buyer's units retire their debt first, the rest
    ///      is new credit; the seller's units consume their credit first, the rest
    ///      is new debt.
    function _movePositions(bytes32 id, address buyer, address seller, uint256 units) private {
        uint256 buyerDebt = _debt[id][buyer];
        uint256 buyerCreditIncrease = units > buyerDebt ? units - buyerDebt : 0;
        _debt[id][buyer] -= uint128(units - buyerCreditIncrease);
        _credit[id][buyer] += uint128(buyerCreditIncrease);

        uint256 sellerCredit = _credit[id][seller];
        uint256 sellerCreditDecrease = units < sellerCredit ? units : sellerCredit;
        _credit[id][seller] -= uint128(sellerCreditDecrease);
        _debt[id][seller] += uint128(units - sellerCreditDecrease);
    }

    function flashLoan(address[] memory tokens, uint256[] memory assets, address callback, bytes memory data) external {
        for (uint256 i; i < tokens.length; i++) {
            IERC20Min(tokens[i]).transfer(callback, assets[i]);
        }
        require(
            IMidnightFlashLoanReceiver(callback).onFlashLoan(msg.sender, tokens, assets, data) == CALLBACK_SUCCESS,
            "bad-callback"
        );
        for (uint256 i; i < tokens.length; i++) {
            IERC20Min(tokens[i]).transferFrom(callback, address(this), assets[i]);
        }
    }

    // ──────────────────── test-only seeding ────────────────────

    /// @dev Set up a collateral position (funds pulled from msg.sender).
    function seedCollateral(Market memory market, address user, uint256 index, uint256 amount) external {
        IERC20Min(market.collateralParams[index].token).transferFrom(msg.sender, address(this), amount);
        _collateral[MidnightIdLib.toId(market)][user][index] += uint128(amount);
    }

    /// @dev Set up a debt position (no token flow — debt is simply owed).
    function seedDebt(Market memory market, address user, uint256 units) external {
        _debt[MidnightIdLib.toId(market)][user] += uint128(units);
    }

    /// @dev Set up a credit (lend) position; the redeemable loan token is pulled
    ///      from msg.sender so the mock can pay it out on `withdraw`.
    function seedCredit(Market memory market, address user, uint256 units) external {
        IERC20Min(market.loanToken).transferFrom(msg.sender, address(this), units);
        _credit[MidnightIdLib.toId(market)][user] += uint128(units);
    }
}
