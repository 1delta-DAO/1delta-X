// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Permit3} from "../src/permit3/Permit3.sol";
import {IPermit3} from "../src/interfaces/IPermit3.sol";
import {IMakerModule} from "../src/interfaces/IMakerModule.sol";
import {ITakerModule} from "../src/interfaces/ITakerModule.sol";
import {
    LimitOrderSettlement,
    LimitOrder,
    Item,
    ItemOp
} from "../src/settlement/LimitOrderSettlement.sol";

import {LenderRegistry, Chains, Lenders, Tokens} from "./data/LenderRegistry.sol";

// ──────────────────── Minimal Aave V3 interfaces ────────────────────

interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        returns (uint256);
}

interface IAaveCreditDelegation {
    function approveDelegation(address delegatee, uint256 amount) external;
}

// ──────────────────── Modules (same as main test file) ────────────────────

contract AaveV3DepositModule is IMakerModule {
    IPermit3 public immutable permit3;

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        (address pool, address asset) = abi.decode(data, (address, address));
        permit3.transferFrom(onBehalfOf, address(this), asset, uint160(amount));
        IERC20(asset).approve(pool, amount);
        IAaveV3Pool(pool).supply(asset, amount, onBehalfOf, 0);
    }
}

contract AaveV3RepayModule is IMakerModule {
    IPermit3 public immutable permit3;
    uint256 private _locked = 1;

    error Reentrancy();

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function makeOnBehalf(address onBehalfOf, uint256 amount, bytes calldata data) external override {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        (address pool, address asset, uint256 rateMode) = abi.decode(data, (address, address, uint256));
        permit3.transferFrom(onBehalfOf, address(this), asset, uint160(amount));
        IERC20(asset).approve(pool, amount);
        IAaveV3Pool(pool).repay(asset, amount, rateMode, onBehalfOf);
        uint256 residual = IERC20(asset).balanceOf(address(this));
        if (residual > 0) IERC20(asset).transfer(onBehalfOf, residual);
        _locked = 1;
    }
}

contract AaveV3WithdrawModule is ITakerModule {
    IPermit3 public immutable permit3;

    error OnlyPermit3();

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();
        (address pool, address asset, address aToken) = abi.decode(data, (address, address, address));
        permit3.transferFrom(onBehalfOf, address(this), aToken, uint160(amount));
        IAaveV3Pool(pool).withdraw(asset, amount, receiver);
    }
}

contract AaveV3BorrowModule is ITakerModule {
    IPermit3 public immutable permit3;

    error OnlyPermit3();

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();
        (address pool, address asset, uint256 rateMode) = abi.decode(data, (address, address, uint256));
        IAaveV3Pool(pool).borrow(asset, amount, rateMode, 0, onBehalfOf);
        IERC20(asset).transfer(receiver, amount);
    }
}

// ──────────────────── Test: all fills via permit signatures ────────────────────

contract LimitOrderSettlementPermitTest is Test, LenderRegistry {
    Permit3 permit3;
    LimitOrderSettlement settlement;
    AaveV3DepositModule depositModule;
    AaveV3RepayModule repayModule;
    AaveV3WithdrawModule withdrawModule;
    AaveV3BorrowModule borrowModule;

    uint256 makerPk = 0xA11CE;
    address maker = vm.addr(makerPk);
    address solver = address(0xBEEF);

    address WETH;
    address USDC;
    address AAVE_POOL;
    address aWETH;

    function setUp() public {
        _forkEthMainnet();

        WETH = tokens[Chains.ETHEREUM_MAINNET][Tokens.WETH];
        USDC = tokens[Chains.ETHEREUM_MAINNET][Tokens.USDC];
        AAVE_POOL = lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3];
        aWETH = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][WETH].collateral;

        permit3 = new Permit3();
        settlement = new LimitOrderSettlement(address(permit3));
        depositModule = new AaveV3DepositModule(address(permit3));
        repayModule = new AaveV3RepayModule(address(permit3));
        withdrawModule = new AaveV3WithdrawModule(address(permit3));
        borrowModule = new AaveV3BorrowModule(address(permit3));

        vm.label(maker, "maker");
        vm.label(solver, "solver");
        vm.label(address(permit3), "permit3");
        vm.label(address(settlement), "settlement");
        vm.label(WETH, "WETH");
        vm.label(USDC, "USDC");
        vm.label(AAVE_POOL, "aaveV3Pool");
        vm.label(aWETH, "aWETH");

        // ── Maker: bare ERC20 approves to Permit3. Nothing else. ──
        vm.startPrank(maker);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        IERC20(aWETH).approve(address(permit3), type(uint256).max);
        vm.stopPrank();

        // ── Solver: standing Permit3 allowance (solvers are contracts with one-time setup). ──
        vm.startPrank(solver);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), WETH, type(uint160).max, 0);
        permit3.approveToken(address(settlement), USDC, type(uint160).max, 0);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════════
    //  1. Swap + deposit (MAKE only)
    // ══════════════════════════════════════════════════════════════

    function test_permit_swap_and_deposit() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;

        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);

        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(depositModule),
            amount: wethOut,
            recipient: address(0),
            data: abi.encode(AAVE_POOL, WETH)
        });

        LimitOrder memory order = LimitOrder({
            maker: maker,
            nonce: 0,
            deadline: block.timestamp + 1 hours,
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: usdcIn,
            decayStartTime: 0,
            decayDuration: 0,
            startAmountOut: wethOut,
            endAmountOut: wethOut,
            items: items
        });

        IPermit3.PermitBatch memory batch = _buildBatch(
            _tokenPermits(
                address(settlement), USDC, usdcIn,
                address(depositModule), WETH, wethOut
            ),
            _noTakerPermits(),
            0, order.deadline
        );

        bytes memory sig = _signPermitWitness(batch, _hashOrder(order));

        vm.prank(solver);
        settlement.fillWithPermit(order, batch, sig, usdcIn);

        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver received USDC");
        assertApproxEqAbs(IERC20(aWETH).balanceOf(maker), wethOut, 2, "maker got aWETH");
    }

    // ══════════════════════════════════════════════════════════════
    //  2. Withdraw + swap (TAKE only)
    // ══════════════════════════════════════════════════════════════

    function test_permit_withdraw_and_swap() public {
        uint256 wethIn = 1 ether;
        uint256 usdcOut = 2_000e6;

        _seedAWethPosition(wethIn + 1e15);
        deal(USDC, solver, usdcOut);

        bytes memory takerData = abi.encode(AAVE_POOL, WETH, aWETH);

        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.TAKE,
            module: address(withdrawModule),
            amount: wethIn,
            recipient: address(0),
            data: takerData
        });

        LimitOrder memory order = _order(maker, 1, WETH, USDC, wethIn, usdcOut, items);

        IPermit3.PermitBatch memory batch = _buildBatch(
            _tokenPermitsWithTaker(
                address(settlement), WETH, wethIn,
                address(withdrawModule), aWETH, wethIn
            ),
            _takerPermits1(address(withdrawModule), keccak256(takerData), wethIn),
            0, order.deadline
        );

        bytes memory sig = _signPermitWitness(batch, _hashOrder(order));

        vm.prank(solver);
        settlement.fillWithPermit(order, batch, sig, wethIn);

        assertEq(IERC20(WETH).balanceOf(solver), wethIn, "solver received WETH");
        assertEq(IERC20(USDC).balanceOf(maker), usdcOut, "maker received USDC");
    }

    // ══════════════════════════════════════════════════════════════
    //  3. Deposit collateral + borrow (MAKE + TAKE)
    // ══════════════════════════════════════════════════════════════

    function test_permit_deposit_and_borrow() public {
        uint256 collateralIn = 1 ether;
        uint256 borrowOut = 1_500e6;

        address usdcDebtToken = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][USDC].debt;

        deal(WETH, solver, collateralIn);

        // Credit delegation: Aave-native, separate from Permit3.
        vm.prank(maker);
        IAaveCreditDelegation(usdcDebtToken).approveDelegation(address(borrowModule), type(uint256).max);

        bytes memory borrowData = abi.encode(AAVE_POOL, USDC, uint256(2));

        Item[] memory items = new Item[](2);
        items[0] = Item(ItemOp.MAKE, address(depositModule), collateralIn, address(0), abi.encode(AAVE_POOL, WETH));
        items[1] = Item(ItemOp.TAKE, address(borrowModule), borrowOut, address(0), borrowData);

        LimitOrder memory order = _order(maker, 2, USDC, WETH, borrowOut, collateralIn, items);

        IPermit3.TokenPermit[] memory tp = new IPermit3.TokenPermit[](2);
        tp[0] = IPermit3.TokenPermit(address(settlement), USDC, uint160(borrowOut), uint48(order.deadline));
        tp[1] = IPermit3.TokenPermit(address(depositModule), WETH, uint160(collateralIn), uint48(order.deadline));

        IPermit3.PermitBatch memory batch = _buildBatch(
            tp,
            _takerPermits1(address(borrowModule), keccak256(borrowData), borrowOut),
            1, order.deadline
        );

        bytes memory sig = _signPermitWitness(batch, _hashOrder(order));

        vm.prank(solver);
        settlement.fillWithPermit(order, batch, sig, borrowOut);

        assertApproxEqAbs(IERC20(aWETH).balanceOf(maker), collateralIn, 2, "maker aWETH up");
        assertApproxEqAbs(IERC20(usdcDebtToken).balanceOf(maker), borrowOut, 2, "maker debt up");
        assertEq(IERC20(USDC).balanceOf(solver), borrowOut, "solver received borrow proceeds");
    }

    // ══════════════════════════════════════════════════════════════
    //  4. Repay with dust refund
    // ══════════════════════════════════════════════════════════════

    function test_permit_repay_with_dust() public {
        uint256 debt = 3_000e6;
        uint256 buffer = 50e6;
        uint256 buffered = debt + buffer;

        _openUsdcDebt(debt);
        deal(USDC, solver, buffered);

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.MAKE, address(repayModule), buffered, address(0), abi.encode(AAVE_POOL, USDC, uint256(2)));

        LimitOrder memory order = _order(maker, 3, WETH, USDC, 1 ether, buffered, items);

        IPermit3.PermitBatch memory batch = _buildBatch(
            _tokenPermits(address(settlement), WETH, 1 ether, address(repayModule), USDC, buffered),
            _noTakerPermits(),
            2, order.deadline
        );

        bytes memory sig = _signPermitWitness(batch, _hashOrder(order));

        vm.prank(solver);
        settlement.fillWithPermit(order, batch, sig, 1 ether);

        assertEq(
            IERC20(lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][USDC].debt).balanceOf(maker),
            0,
            "debt zeroed"
        );
        assertGt(IERC20(USDC).balanceOf(maker), 0, "dust refunded");
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), 0, "module drained");
    }

    // ══════════════════════════════════════════════════════════════
    //  5. Migration Aave v3 → Spark (4-item order, one signature)
    // ══════════════════════════════════════════════════════════════

    function test_permit_migrate_aaveV3_to_spark() public {
        _setupMigration();
        (LimitOrder memory order, IPermit3.PermitBatch memory batch) = _buildMigrationOrderAndBatch();
        bytes memory sig = _signPermitWitness(batch, _hashOrder(order));

        vm.prank(solver);
        settlement.fillWithPermit(order, batch, sig, 3_000e6);

        _assertMigration();
    }

    function _setupMigration() internal {
        address sparkUsdcDebt = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SPARK][USDC].debt;
        _openAaveV3Position(10 ether, 3_000e6);
        deal(USDC, solver, 3_050e6);
        vm.prank(maker);
        IAaveCreditDelegation(sparkUsdcDebt).approveDelegation(address(borrowModule), type(uint256).max);
    }

    function _buildMigrationOrderAndBatch()
        internal
        view
        returns (LimitOrder memory order, IPermit3.PermitBatch memory batch)
    {
        address SPARK_POOL = lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.SPARK];
        bytes memory aaveWithdrawData = abi.encode(AAVE_POOL, WETH, aWETH);
        bytes memory sparkBorrowData = abi.encode(SPARK_POOL, USDC, uint256(2));
        uint48 exp = uint48(block.timestamp + 1 hours);

        Item[] memory items = new Item[](4);
        items[0] = Item(ItemOp.MAKE, address(repayModule), 3_050e6, address(0), abi.encode(AAVE_POOL, USDC, uint256(2)));
        items[1] = Item(ItemOp.TAKE, address(withdrawModule), 9 ether, maker, aaveWithdrawData);
        items[2] = Item(ItemOp.MAKE, address(depositModule), 9 ether, address(0), abi.encode(SPARK_POOL, WETH));
        items[3] = Item(ItemOp.TAKE, address(borrowModule), 3_000e6, address(0), sparkBorrowData);

        order = _order(maker, 7, USDC, USDC, 3_000e6, 3_050e6, items);

        IPermit3.TokenPermit[] memory tp = new IPermit3.TokenPermit[](4);
        tp[0] = IPermit3.TokenPermit(address(repayModule), USDC, uint160(3_050e6), exp);
        tp[1] = IPermit3.TokenPermit(address(withdrawModule), aWETH, uint160(9 ether), exp);
        tp[2] = IPermit3.TokenPermit(address(depositModule), WETH, uint160(9 ether), exp);
        tp[3] = IPermit3.TokenPermit(address(settlement), USDC, uint160(3_050e6), exp);

        IPermit3.TakerPermit[] memory tkp = new IPermit3.TakerPermit[](2);
        tkp[0] = IPermit3.TakerPermit(address(withdrawModule), keccak256(aaveWithdrawData), uint160(9 ether), exp);
        tkp[1] = IPermit3.TakerPermit(address(borrowModule), keccak256(sparkBorrowData), uint160(3_000e6), exp);

        batch = _buildBatch(tp, tkp, 3, order.deadline);
    }

    function _assertMigration() internal view {
        address aaveUsdcDebt = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][USDC].debt;
        address spWETH = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SPARK][WETH].collateral;
        address sparkUsdcDebt = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SPARK][USDC].debt;

        assertEq(IERC20(aaveUsdcDebt).balanceOf(maker), 0, "Aave debt closed");
        assertApproxEqAbs(IERC20(spWETH).balanceOf(maker), 9 ether, 2, "Spark collateral opened");
        assertApproxEqAbs(IERC20(sparkUsdcDebt).balanceOf(maker), 3_000e6, 2, "Spark debt opened");
    }

    // ══════════════════════════════════════════════════════════════
    //  Helpers
    // ══════════════════════════════════════════════════════════════

    // ── Fork ──

    function _forkEthMainnet() internal {
        try vm.envString("ETH_RPC_URL") returns (string memory v) {
            if (bytes(v).length > 0) {
                try this.__fork(v) { return; } catch {}
            }
        } catch {}
        string[13] memory rpcs = [
            "https://eth.drpc.org",
            "https://ethereum-rpc.publicnode.com",
            "https://rpc.flashbots.net",
            "https://api.zan.top/eth-mainnet",
            "https://1rpc.io/eth",
            "https://rpc.mevblocker.io",
            "https://eth.meowrpc.com",
            "https://eth.api.onfinality.io/public",
            "https://eth-mainnet.public.blastapi.io",
            "https://gateway.tenderly.co/public/mainnet",
            "https://ethereum-public.nodies.app",
            "https://rpc.eth.gateway.fm",
            "https://0xrpc.io/eth"
        ];
        for (uint256 i; i < rpcs.length; i++) {
            try this.__fork(rpcs[i]) { return; } catch {}
        }
        revert("no working mainnet RPC");
    }

    function __fork(string calldata rpc) external {
        vm.createSelectFork(rpc);
    }

    // ── Position seeding ──

    function _seedAWethPosition(uint256 amount) internal {
        deal(WETH, maker, amount);
        vm.startPrank(maker);
        IERC20(WETH).approve(AAVE_POOL, amount);
        IAaveV3Pool(AAVE_POOL).supply(WETH, amount, maker, 0);
        vm.stopPrank();
    }

    function _openUsdcDebt(uint256 debt) internal {
        deal(WETH, maker, 11 ether);
        vm.startPrank(maker);
        IERC20(WETH).approve(AAVE_POOL, 10 ether);
        IAaveV3Pool(AAVE_POOL).supply(WETH, 10 ether, maker, 0);
        IAaveV3Pool(AAVE_POOL).borrow(USDC, debt, 2, 0, maker);
        IERC20(USDC).transfer(address(0xdead), debt);
        vm.stopPrank();
    }

    function _openAaveV3Position(uint256 collateral, uint256 debt) internal {
        deal(WETH, maker, collateral + 1 ether);
        vm.startPrank(maker);
        IERC20(WETH).approve(AAVE_POOL, collateral);
        IAaveV3Pool(AAVE_POOL).supply(WETH, collateral, maker, 0);
        IAaveV3Pool(AAVE_POOL).borrow(USDC, debt, 2, 0, maker);
        IERC20(USDC).transfer(address(0xdead), debt);
        vm.stopPrank();
    }

    // ── Order builder ──

    function _order(
        address _maker,
        uint256 nonce,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        Item[] memory items
    ) internal view returns (LimitOrder memory) {
        return LimitOrder({
            maker: _maker,
            nonce: nonce,
            deadline: block.timestamp + 1 hours,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            decayStartTime: 0,
            decayDuration: 0,
            startAmountOut: amountOut,
            endAmountOut: amountOut,
            items: items
        });
    }

    // ── Permit batch builders ──

    function _buildBatch(
        IPermit3.TokenPermit[] memory tp,
        IPermit3.TakerPermit[] memory tkp,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (IPermit3.PermitBatch memory) {
        return IPermit3.PermitBatch({tokens: tp, takers: tkp, nonce: nonce, deadline: deadline});
    }

    function _noTakerPermits() internal pure returns (IPermit3.TakerPermit[] memory) {
        return new IPermit3.TakerPermit[](0);
    }

    function _tokenPermits(
        address spender1, address token1, uint256 amt1,
        address spender2, address token2, uint256 amt2
    ) internal view returns (IPermit3.TokenPermit[] memory tp) {
        tp = new IPermit3.TokenPermit[](2);
        uint48 exp = uint48(block.timestamp + 1 hours);
        tp[0] = IPermit3.TokenPermit(spender1, token1, uint160(amt1), exp);
        tp[1] = IPermit3.TokenPermit(spender2, token2, uint160(amt2), exp);
    }

    function _tokenPermitsWithTaker(
        address spender1, address token1, uint256 amt1,
        address spender2, address token2, uint256 amt2
    ) internal view returns (IPermit3.TokenPermit[] memory) {
        return _tokenPermits(spender1, token1, amt1, spender2, token2, amt2);
    }

    function _takerPermits1(address module, bytes32 ref, uint256 amt)
        internal
        view
        returns (IPermit3.TakerPermit[] memory tkp)
    {
        tkp = new IPermit3.TakerPermit[](1);
        tkp[0] = IPermit3.TakerPermit(module, ref, uint160(amt), uint48(block.timestamp + 1 hours));
    }

    // ── EIP-712 hashing + signing ──

    bytes32 constant ITEM_TH =
        keccak256("Item(uint8 op,address module,uint256 amount,address recipient,bytes data)");
    bytes32 constant ORDER_TH = keccak256(
        "LimitOrder(address maker,uint256 nonce,uint256 deadline,address tokenIn,address tokenOut,uint256 amountIn,uint32 decayStartTime,uint32 decayDuration,uint256 startAmountOut,uint256 endAmountOut,Item[] items)"
        "Item(uint8 op,address module,uint256 amount,address recipient,bytes data)"
    );
    bytes32 constant TOKEN_PERMIT_TH =
        keccak256("TokenPermit(address spender,address token,uint160 amount,uint48 expiration)");
    bytes32 constant TAKER_PERMIT_TH =
        keccak256("TakerPermit(address module,bytes32 ref,uint160 amount,uint48 expiration)");

    string constant PERMIT_BATCH_WITNESS_FULL =
        "PermitBatchWitness(TokenPermit[] tokens,TakerPermit[] takers,uint256 nonce,uint256 deadline,"
        "LimitOrder witness)"
        "Item(uint8 op,address module,uint256 amount,address recipient,bytes data)"
        "LimitOrder(address maker,uint256 nonce,uint256 deadline,address tokenIn,address tokenOut,uint256 amountIn,uint32 decayStartTime,uint32 decayDuration,uint256 startAmountOut,uint256 endAmountOut,Item[] items)"
        "TakerPermit(address module,bytes32 ref,uint160 amount,uint48 expiration)"
        "TokenPermit(address spender,address token,uint160 amount,uint48 expiration)";

    function _hashOrder(LimitOrder memory o) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_TH,
                o.maker, o.nonce, o.deadline, o.tokenIn, o.tokenOut, o.amountIn,
                o.decayStartTime, o.decayDuration, o.startAmountOut, o.endAmountOut,
                _hashItems(o.items)
            )
        );
    }

    function _hashItems(Item[] memory items) internal pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](items.length);
        for (uint256 i; i < items.length; i++) {
            h[i] = keccak256(
                abi.encode(ITEM_TH, uint8(items[i].op), items[i].module, items[i].amount, items[i].recipient, keccak256(items[i].data))
            );
        }
        return keccak256(abi.encodePacked(h));
    }

    function _hashTokenPermits(IPermit3.TokenPermit[] memory p) internal pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](p.length);
        for (uint256 i; i < p.length; i++) {
            h[i] = keccak256(abi.encode(TOKEN_PERMIT_TH, p[i].spender, p[i].token, p[i].amount, p[i].expiration));
        }
        return keccak256(abi.encodePacked(h));
    }

    function _hashTakerPermits(IPermit3.TakerPermit[] memory p) internal pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](p.length);
        for (uint256 i; i < p.length; i++) {
            h[i] = keccak256(abi.encode(TAKER_PERMIT_TH, p[i].module, p[i].ref, p[i].amount, p[i].expiration));
        }
        return keccak256(abi.encodePacked(h));
    }

    function _signPermitWitness(IPermit3.PermitBatch memory batch, bytes32 witness)
        internal
        view
        returns (bytes memory)
    {
        bytes32 typeHash = keccak256(bytes(PERMIT_BATCH_WITNESS_FULL));
        bytes32 hashStruct = keccak256(
            abi.encode(typeHash, _hashTokenPermits(batch.tokens), _hashTakerPermits(batch.takers), batch.nonce, batch.deadline, witness)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", permit3.DOMAIN_SEPARATOR(), hashStruct));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, digest);
        return abi.encodePacked(r, s, v);
    }
}
