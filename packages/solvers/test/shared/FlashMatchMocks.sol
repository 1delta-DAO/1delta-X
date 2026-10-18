// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {ITakerForModule} from "@core/interfaces/ITakerForModule.sol";
import {MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";

// Fixtures for {MatchFlashSolver}: a Uniswap-v3-shaped pool with BOTH `swap` and
// `flash` (and the pool `lock` the real one holds across either), the four
// fixed-address flash providers, a lender whose borrow needs its deposit first (the
// cycle), and two hostile actors.

/// @dev Plain high-level transfer, so a token's revert bubbles verbatim (SafeTransferLib
///      maps every failure to `TransferFailed`).
interface ITransferable {
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IFlashCb {
    function uniswapV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata data) external;
}

interface ISwapCb {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

interface IBalancerRecipient {
    function receiveFlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory fees,
        bytes memory data
    ) external;
}

interface IAaveReceiver {
    function executeOperation(address asset, uint256 amount, uint256 premium, address initiator, bytes calldata params)
        external
        returns (bool);
}

interface IMorphoReceiver {
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external;
}

interface IEulerReceiver {
    function onFlashLoan(bytes calldata data) external;
}

/// @dev Uniswap-v3-SHAPED factory (CREATE2, parameter-less pool constructor reading
///      `parameters()` back) — pool = `CREATE2(factory, keccak(t0, t1, fee), keccak(code))`.
contract MockFlashV3Factory {
    struct Params {
        address factory;
        address token0;
        address token1;
        uint24 fee;
    }

    Params public parameters;

    function initCodeHash() external pure returns (bytes32) {
        return keccak256(type(MockFlashV3Pool).creationCode);
    }

    function createPool(address a, address b, uint24 fee) external returns (MockFlashV3Pool pool) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        parameters = Params(address(this), t0, t1, fee);
        pool = new MockFlashV3Pool{salt: keccak256(abi.encode(t0, t1, fee))}();
        delete parameters;
    }
}

/// @dev Constant-price pool with v3's swap AND flash contracts: output first, then the
///      callback on `msg.sender` with the caller's data, then a balance check. `flash`
///      charges `ceil(amount · fee / 1e6)` like v3. Both hold the pool lock (`LOK`).
contract MockFlashV3Pool {
    address public immutable factory;
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;

    /// @dev token1 per token0 = num / den.
    uint256 public num = 1;
    uint256 public den = 1;
    bytes public overrideData;
    bool private unlocked = true;

    constructor() {
        (factory, token0, token1, fee) = MockFlashV3Factory(msg.sender).parameters();
    }

    modifier lock() {
        require(unlocked, "LOK");
        unlocked = false;
        _;
        unlocked = true;
    }

    function setPrice(uint256 n, uint256 d) external {
        (num, den) = (n, d);
    }

    function setOverrideData(bytes calldata d) external {
        overrideData = d;
    }

    function _cb(bytes calldata data) private view returns (bytes memory) {
        if (overrideData.length != 0) return overrideData;
        return data;
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        lock
        returns (int256 amount0, int256 amount1)
    {
        (address tin, address tout) = zeroForOne ? (token0, token1) : (token1, token0);
        (uint256 n, uint256 d) = zeroForOne ? (num, den) : (den, num); // out = in · n / d
        uint256 amtIn;
        uint256 amtOut;
        if (amountSpecified > 0) {
            amtIn = uint256(amountSpecified);
            amtOut = (amtIn * n) / d;
        } else {
            amtOut = uint256(-amountSpecified);
            amtIn = (amtOut * d + n - 1) / n;
        }
        require(ITransferable(tout).transfer(recipient, amtOut), "T");
        (amount0, amount1) = zeroForOne ? (int256(amtIn), -int256(amtOut)) : (-int256(amtOut), int256(amtIn));
        uint256 before = MockERC20(tin).balanceOf(address(this));
        ISwapCb(msg.sender).uniswapV3SwapCallback(amount0, amount1, _cb(data));
        require(MockERC20(tin).balanceOf(address(this)) >= before + amtIn, "IIA");
    }

    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external lock {
        uint256 fee0 = (amount0 * fee + 1e6 - 1) / 1e6;
        uint256 fee1 = (amount1 * fee + 1e6 - 1) / 1e6;
        uint256 b0 = MockERC20(token0).balanceOf(address(this));
        uint256 b1 = MockERC20(token1).balanceOf(address(this));
        if (amount0 > 0) require(ITransferable(token0).transfer(recipient, amount0), "T");
        if (amount1 > 0) require(ITransferable(token1).transfer(recipient, amount1), "T");
        IFlashCb(msg.sender).uniswapV3FlashCallback(fee0, fee1, _cb(data));
        require(MockERC20(token0).balanceOf(address(this)) >= b0 + fee0, "F0");
        require(MockERC20(token1).balanceOf(address(this)) >= b1 + fee1, "F1");
    }
}

/// @dev Balancer v2 vault shape: any recipient, no initiator, repaid by transfer.
contract MockBalancerVault {
    uint256 public feeBps;

    function setFeeBps(uint256 b) external {
        feeBps = b;
    }

    function flashLoan(address recipient, address[] memory tokens, uint256[] memory amounts, bytes memory data)
        external
    {
        uint256 n = tokens.length;
        uint256[] memory fees = new uint256[](n);
        uint256[] memory before = new uint256[](n);
        for (uint256 i; i < n; i++) {
            before[i] = MockERC20(tokens[i]).balanceOf(address(this));
            fees[i] = (amounts[i] * feeBps) / 10_000;
            SafeTransferLib.safeTransfer(tokens[i], recipient, amounts[i]);
        }
        IBalancerRecipient(recipient).receiveFlashLoan(tokens, amounts, fees, data);
        for (uint256 i; i < n; i++) {
            require(MockERC20(tokens[i]).balanceOf(address(this)) >= before[i] + fees[i], "BAL#602");
        }
    }
}

/// @dev Aave v3 `flashLoanSimple` shape: premium, initiator, pull repayment.
contract MockAavePool {
    uint256 public constant PREMIUM_BPS = 5;

    function flashLoanSimple(address receiver, address asset, uint256 amount, bytes calldata params, uint16) external {
        uint256 premium = (amount * PREMIUM_BPS) / 10_000;
        SafeTransferLib.safeTransfer(asset, receiver, amount);
        require(IAaveReceiver(receiver).executeOperation(asset, amount, premium, msg.sender, params), "op");
        SafeTransferLib.safeTransferFrom(asset, receiver, address(this), amount + premium);
    }
}

/// @dev Morpho Blue shape: calls back `msg.sender`, pulls the principal.
contract MockMorpho {
    function flashLoan(address token, uint256 assets, bytes calldata data) external {
        SafeTransferLib.safeTransfer(token, msg.sender, assets);
        IMorphoReceiver(msg.sender).onMorphoFlashLoan(assets, data);
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), assets);
    }
}

/// @dev EVK vault shape: calls back `msg.sender`, checks its balance is restored.
///      `skip` makes it return without calling back (a fake/broken provider).
contract MockEulerVault {
    address public immutable asset;
    bool public skip;

    constructor(address a) {
        asset = a;
    }

    function setSkip(bool s) external {
        skip = s;
    }

    function flashLoan(uint256 amount, bytes calldata data) external {
        if (skip) return;
        uint256 before = MockERC20(asset).balanceOf(address(this));
        SafeTransferLib.safeTransfer(asset, msg.sender, amount);
        IEulerReceiver(msg.sender).onFlashLoan(data);
        require(MockERC20(asset).balanceOf(address(this)) >= before, "E_FlashLoanNotRepaid");
    }
}

/// @dev A lender whose borrow is health-checked against the deposit — so a leverage
///      open at the edge (and a close) is a CYCLE: the borrow needs the deposit, the
///      deposit needs the delivery, the delivery needs the borrow's proceeds. One
///      contract plays every module role:
///        • TAKE_FOR, PRE-FUNDED (the fused composite): `data = abi.encode(desc, mode)`
///            mode 0 = OPEN:  deposit the delivered COLL (`forAmount`), borrow `amount` DEBT
///            mode 1 = CLOSE: repay with the delivered DEBT (`forAmount`), withdraw `amount` COLL
///        • MAKE (pre-funded deposit of the delivered COLL) and TAKE (borrow DEBT) — the
///          two-item edge open.
///      Health: `debt · den · 1e4 ≤ collateral · num · LTV_BPS` (DEBT per COLL = num/den).
contract MockLeverLender is ITakerForModule, ITakerModule, IMakerModule {
    address public immutable PERMIT3;
    address public immutable SETTLEMENT;
    address public immutable COLL;
    address public immutable DEBT;
    uint256 public immutable PRICE_NUM;
    uint256 public immutable PRICE_DEN;
    uint256 public constant LTV_BPS = 8000;

    mapping(address => uint256) public collateral;
    mapping(address => uint256) public debt;
    /// @dev What the lender accounts as held, per token — anything above is a delivery.
    mapping(address => uint256) public booked;

    constructor(address permit3, address settlement, address coll, address debt_, uint256 num, uint256 den) {
        (PERMIT3, SETTLEMENT, COLL, DEBT, PRICE_NUM, PRICE_DEN) = (permit3, settlement, coll, debt_, num, den);
    }

    /// @dev Test setup: account the current balance of `token` as liquidity.
    function book(address token) external {
        booked[token] = MockERC20(token).balanceOf(address(this));
    }

    /// @dev Test setup: an existing position (its collateral already booked).
    function seed(address user, uint256 coll, uint256 d) external {
        collateral[user] += coll;
        debt[user] += d;
    }

    function healthy(address user) public view returns (bool) {
        return debt[user] * PRICE_DEN * 10_000 <= collateral[user] * PRICE_NUM * LTV_BPS;
    }

    function takeForOnBehalf(
        address spender,
        address user,
        uint256 amount,
        uint256 forAmount,
        address receiver,
        bytes calldata data
    ) external override {
        require(msg.sender == PERMIT3 && spender == SETTLEMENT, "auth");
        (, uint256 mode) = abi.decode(data, (uint256, uint256));
        if (mode == 0) {
            _in(COLL, forAmount);
            collateral[user] += forAmount;
            debt[user] += amount;
            _out(DEBT, receiver, amount);
        } else {
            _in(DEBT, forAmount);
            uint256 d = debt[user];
            debt[user] = forAmount >= d ? 0 : d - forAmount;
            collateral[user] -= amount;
            _out(COLL, receiver, amount);
        }
        require(healthy(user), "unhealthy");
    }

    function makeOnBehalf(address user, uint256 amount, bytes calldata) external override {
        require(msg.sender == SETTLEMENT, "auth");
        _in(COLL, amount);
        collateral[user] += amount;
    }

    function takeOnBehalf(address user, uint256 amount, address receiver, bytes calldata) external override {
        require(msg.sender == PERMIT3, "auth");
        debt[user] += amount;
        require(healthy(user), "unhealthy");
        _out(DEBT, receiver, amount);
    }

    function _in(address token, uint256 amt) private {
        require(MockERC20(token).balanceOf(address(this)) >= booked[token] + amt, "unfunded");
        booked[token] += amt;
    }

    function _out(address token, address to, uint256 amt) private {
        booked[token] -= amt;
        SafeTransferLib.safeTransfer(token, to, amt);
    }
}

/// @dev A mintable ERC20 with a one-shot transfer hook: the next `transfer` calls
///      `target` with `payload` and bubbles its revert.
contract HookToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public target;
    bytes public payload;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function arm(address t, bytes calldata p) external {
        (target, payload) = (t, p);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        _hook();
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function _hook() private {
        address t = target;
        if (t == address(0)) return;
        target = address(0);
        (bool ok, bytes memory ret) = t.call(payload);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}

/// @dev A "pool" no allowlisted venue derives (a rogue factory's pool, or any
///      contract): forwards a raw call, so the solver sees it as `msg.sender`.
contract RoguePool {
    function poke(address target, bytes calldata data) external {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}
