// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Market, Offer, MidnightIdLib} from "../../src/interfaces/IMidnight.sol";
import {ISellCallback} from "../../src/interfaces/ICallbacks.sol";

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

/// @notice Faithful-enough Morpho Midnight stand-in for the settlement-module
///         unit suite. Reproduces the exact function signatures (hence selectors)
///         the modules build, keys positions by the SAME `MidnightIdLib.toId` the
///         modules compute (so the on-chain views agree), enforces the
///         `setIsAuthorized` gate on the value-out legs, and performs the same
///         token pulls/pushes as the real protocol so fund-flow can be asserted.
///
///         Economics are intentionally 1:1 (1 unit ⇔ 1 loan token): ticks,
///         ratifiers, maturity and zero-coupon discounting are Morpho's concern,
///         not the modules'. `seed*` helpers set up positions without a full
///         order-book open.
contract MidnightMock {
    bytes32 public constant CALLBACK_SUCCESS = keccak256("morpho.midnight.callbackSuccess");

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

    // last-call captures (fund-path / pinning assertions)
    string public lastFn;
    address public lastOnBehalf;
    address public lastReceiver;
    address public lastTaker;
    address public lastCaller;
    address public lastCallback;
    uint256 public lastUnits;
    uint256 public lastAssets;
    uint256 public lastCollateralIndex;
    bool public lastBuy;

    error Unauthorized();

    // ──────────────────── views ────────────────────

    function debt(bytes32 id, address user) external view returns (uint128) {
        return _debt[id][user];
    }

    function credit(bytes32 id, address user) external view returns (uint128) {
        return _credit[id][user];
    }

    function collateral(bytes32 id, address user, uint256 index) external view returns (uint128) {
        return _collateral[id][user][index];
    }

    /// @dev Modeled solvency check: Σ collateral_i · price_i · lltv_i ≥ debt.
    ///      Faithful enough to exercise the loop (a borrow that isn't collateralized
    ///      by fill time is `SellerIsLiquidatable`); real tick/discount pricing is
    ///      Morpho's concern. Positions the modules never health-check are
    ///      unaffected (the value-out legs don't call this).
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

    /// @dev Test-only: set the collateral price used by the modeled solvency check.
    function setPrice(address collateralToken, uint256 priceWad) external {
        _price[collateralToken] = priceWad;
    }

    // ──────────────────── authorization ────────────────────

    function setIsAuthorized(address authorized, bool newIsAuthorized, address onBehalf) external {
        // The real contract lets a caller manage its OWN authorizations; here the
        // maker pranks the call so `msg.sender == onBehalf`.
        require(msg.sender == onBehalf, "auth: not self");
        isAuthorized[onBehalf][authorized] = newIsAuthorized;
    }

    function _requireAuth(address onBehalf) internal view {
        if (msg.sender != onBehalf && !isAuthorized[onBehalf][msg.sender]) revert Unauthorized();
    }

    // ──────────────────── position lifecycle ────────────────────

    function supplyCollateral(Market memory market, uint256 collateralIndex, uint256 assets, address onBehalf)
        external
    {
        lastFn = "supplyCollateral";
        lastCaller = msg.sender;
        lastCollateralIndex = collateralIndex;
        lastAssets = assets;
        lastOnBehalf = onBehalf;
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
        lastFn = "withdrawCollateral";
        lastCaller = msg.sender;
        lastCollateralIndex = collateralIndex;
        lastAssets = assets;
        lastOnBehalf = onBehalf;
        lastReceiver = receiver;
        bytes32 id = MidnightIdLib.toId(market);
        _collateral[id][onBehalf][collateralIndex] -= uint128(assets);
        IERC20Min(market.collateralParams[collateralIndex].token).transfer(receiver, assets);
    }

    function repay(Market memory market, uint256 units, address onBehalf, address callback, bytes memory) external {
        lastFn = "repay";
        lastCaller = msg.sender;
        lastUnits = units;
        lastOnBehalf = onBehalf;
        lastCallback = callback; // modules force this to 0
        _debt[MidnightIdLib.toId(market)][onBehalf] -= uint128(units); // reverts on over-repay
        // callback == 0 ⇒ payer is msg.sender (the module)
        IERC20Min(market.loanToken).transferFrom(msg.sender, address(this), units);
    }

    function withdraw(Market memory market, uint256 units, address onBehalf, address receiver) external {
        _requireAuth(onBehalf);
        lastFn = "withdraw";
        lastCaller = msg.sender;
        lastUnits = units;
        lastOnBehalf = onBehalf;
        lastReceiver = receiver;
        _credit[MidnightIdLib.toId(market)][onBehalf] -= uint128(units);
        IERC20Min(market.loanToken).transfer(receiver, units);
    }

    function take(
        Offer memory offer,
        bytes memory,
        uint256 units,
        address taker,
        address receiverIfTakerIsSeller,
        address takerCallback,
        bytes memory
    ) external returns (uint256, uint256) {
        _requireAuth(taker);
        lastFn = "take";
        lastCaller = msg.sender;
        lastUnits = units;
        lastTaker = taker;
        lastReceiver = receiverIfTakerIsSeller;
        lastCallback = takerCallback; // modules force this to 0
        lastBuy = offer.buy;
        bytes32 id = MidnightIdLib.toId(offer.market);

        // ── Maker-attached callback path (borrow-and-loop) ──
        // The offer maker is the seller/borrower (buy == false) and attached an
        // onSell callback. Model the borrower side the taker-centric branches below
        // omit — and, faithful to Midnight, fire the callback AFTER moving the
        // proceeds but BEFORE the solvency check, so the callback can collateralize
        // the new debt in the same fill. `takerCallback` (the lender side) is out
        // of scope here (the modules force it to 0).
        if (!offer.buy && offer.callback != address(0)) {
            lastCallback = offer.callback;
            _sellCallbackFill(offer, id, units); // hoisted to stay under the stack limit
            return (units, units);
        }

        if (offer.buy) {
            // maker is buyer/lender, taker is seller/borrower: taker incurs debt,
            // receives the (zero-discount) proceeds at receiverIfTakerIsSeller.
            _debt[id][taker] += uint128(units);
            IERC20Min(offer.market.loanToken).transfer(receiverIfTakerIsSeller, units);
        } else {
            // taker is buyer/lender: pull payment from the payer (msg.sender when
            // takerCallback == 0), taker gains credit.
            _credit[id][taker] += uint128(units);
            IERC20Min(offer.market.loanToken).transferFrom(msg.sender, address(this), units);
        }
        return (units, units);
    }

    /// @dev Borrow side of a maker-callback fill (buy == false). Moves proceeds,
    ///      fires onSell, then enforces solvency — the real Midnight order.
    ///      `msg.sender` (the lender) is preserved (private call = JUMP).
    function _sellCallbackFill(Offer memory offer, bytes32 id, uint256 units) private {
        address borrower = offer.maker;
        address proceedsReceiver = offer.receiverIfMakerIsSeller;
        _debt[id][borrower] += uint128(units);
        // The lender (msg.sender) funds the borrow; 1:1 economics as elsewhere.
        IERC20Min(offer.market.loanToken).transferFrom(msg.sender, address(this), units);
        IERC20Min(offer.market.loanToken).transfer(proceedsReceiver, units);
        require(
            ISellCallback(offer.callback).onSell(
                id, offer.market, units, units, 0, borrower, proceedsReceiver, offer.callbackData
            ) == CALLBACK_SUCCESS,
            "bad onSell callback"
        );
        require(_isHealthy(offer.market, id, borrower), "SellerIsLiquidatable");
    }

    function flashLoan(address[] memory tokens, uint256[] memory assets, address callback, bytes memory data)
        external
    {
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
