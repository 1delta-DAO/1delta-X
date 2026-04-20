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
    ItemOp,
    Validator
} from "../src/settlement/LimitOrderSettlement.sol";
import {LimitOrderLeverageSolver} from "../src/solver/LimitOrderLeverageSolver.sol";
import {ChainlinkPriceLte, ChainlinkPriceGte} from "../src/validators/ChainlinkPriceValidators.sol";

import {LenderRegistry, Chains, Lenders, Tokens} from "./data/LenderRegistry.sol";

// ──────────────────── Minimal Aave V3 pool surface ────────────────────

interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function borrow(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        uint16 referralCode,
        address onBehalfOf
    ) external;
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        returns (uint256);
}

interface IAaveCreditDelegation {
    function approveDelegation(address delegatee, uint256 amount) external;
}

// ──────────────────── Aave v3 deposit maker module ────────────────────
//
// Single-op module: pulls `asset` from the user via Permit3, then supplies
// on the user's behalf. `data = abi.encode(pool, asset)`.
//
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

// ──────────────────── Aave v3 repay maker module ────────────────────
//
// Handles interest-accrual over-repay cleanly:
//
//   1. Pulls `amount` (a user-signed buffered value) from the user via Permit3.
//   2. Calls `pool.repay(asset, amount, rateMode, user)`. Aave v3 caps
//      internally at `min(amount, currentDebt)` and only pulls
//      `paybackAmount` from this contract via its own transferFrom.
//   3. Any residual left in this contract is swept back to `user` —
//      never to an attacker-controlled address, because the refund
//      destination is the `user` function argument, not a field of
//      `data`. That closes the "anyone can call this and redirect dust"
//      attack vector without requiring a `msg.sender == permit3` gate.
//
// `nonReentrant` guards against weird-token transfer hooks.
// `data = abi.encode(pool, asset, rateMode)`.
//
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

        // Sweep residual (over-repay dust) back to the user. `balanceOf` avoids
        // depending on the pool's return value and handles protocols that round
        // differently from their own accounting.
        uint256 residual = IERC20(asset).balanceOf(address(this));
        if (residual > 0) IERC20(asset).transfer(onBehalfOf, residual);

        _locked = 1;
    }
}

// ──────────────────── Aave v3 withdraw taker module ────────────────────
//
// Single-op taker module. Permit3 decrements the taker allowance on
// `keccak256(data)`, then invokes `takeOnBehalf` here. The module pulls
// the user's aToken via the Permit3 token allowance (the user infinite-
// approves the aToken to this module), then calls `pool.withdraw` which
// burns the module's aTokens and sends the underlying to `receiver`.
//
// `data = abi.encode(pool, asset, aToken)`.
//
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

// ──────────────────── Aave v3 borrow taker module ────────────────────
//
// Single-op taker module. Issues a variable-rate borrow on behalf of the
// user and forwards proceeds to `receiver`. The user must have called
// `approveDelegation(module, cap)` on the relevant Aave variableDebtToken
// so Aave itself permits the module to incur debt on their account.
//
// `data = abi.encode(pool, asset, rateMode)`  (rateMode: 2 = variable)
//
contract AaveV3BorrowModule is ITakerModule {
    IPermit3 public immutable permit3;

    error OnlyPermit3();

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        if (msg.sender != address(permit3)) revert OnlyPermit3();

        (address pool, address asset, uint256 rateMode) = abi.decode(data, (address, address, uint256));

        // Borrow lands `amount` of `asset` at `msg.sender` (this module).
        IAaveV3Pool(pool).borrow(asset, amount, rateMode, 0, onBehalfOf);
        // Forward to Permit3's requested receiver (Settlement in our flow).
        IERC20(asset).transfer(receiver, amount);
    }
}

// ──────────────────── Test ────────────────────

contract LimitOrderSettlementTest is Test, LenderRegistry {
    Permit3 permit3;
    LimitOrderSettlement settlement;
    AaveV3DepositModule depositModule;
    AaveV3WithdrawModule withdrawModule;
    AaveV3BorrowModule borrowModule;
    AaveV3RepayModule repayModule;
    LimitOrderLeverageSolver leverageSolver;

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
        withdrawModule = new AaveV3WithdrawModule(address(permit3));
        borrowModule = new AaveV3BorrowModule(address(permit3));
        repayModule = new AaveV3RepayModule(address(permit3));
        // Balancer v2 Vault + UniswapV3 SwapRouter — mainnet canonical addresses.
        leverageSolver = new LimitOrderLeverageSolver(
            address(permit3),
            address(settlement),
            0xBA12222222228d8Ba445958a75a0704d566BF2C8,
            0xE592427A0AEce92De3Edee1F18E0157C05861564
        );

        vm.label(maker, "maker");
        vm.label(solver, "solver");
        vm.label(address(permit3), "permit3");
        vm.label(address(settlement), "settlement");
        vm.label(address(depositModule), "aaveV3DepositModule");
        vm.label(address(withdrawModule), "aaveV3WithdrawModule");
        vm.label(address(borrowModule), "aaveV3BorrowModule");
        vm.label(address(repayModule), "aaveV3RepayModule");
        vm.label(address(leverageSolver), "leverageSolver");
        vm.label(WETH, "WETH");
        vm.label(USDC, "USDC");
        vm.label(AAVE_POOL, "aaveV3Pool");
        vm.label(aWETH, "aWETH");
    }

    // ──────────────────── Fork helper ────────────────────

    /// @dev Tries `ETH_RPC_URL` first (if set), then walks a baked-in list of
    ///      public mainnet RPCs until one succeeds. Reverts if all fail.
    function _forkEthMainnet() internal {
        // 1. user-supplied override
        try vm.envString("ETH_RPC_URL") returns (string memory v) {
            if (bytes(v).length > 0) {
                try this.__fork(v) {
                    return;
                } catch {}
            }
        } catch {}

        // 2. baked-in list — ordered by observed latency on the user's bench
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

        for (uint256 i = 0; i < rpcs.length; i++) {
            try this.__fork(rpcs[i]) {
                return;
            } catch {}
        }
        revert("LimitOrderSettlementTest: no working mainnet RPC (set ETH_RPC_URL to bypass)");
    }

    /// @dev External self-call so a reverting `createSelectFork` can be caught
    ///      by try/catch (cheatcode reverts propagate through external boundaries).
    function __fork(string calldata rpc) external {
        // Pin to a block with headroom under Aave market caps for deterministic tests.
        // drpc.org, flashbots, and the public nodes all serve this block.
        vm.createSelectFork(rpc, 22_000_000);
    }

    // ──────────────────── Helpers ────────────────────

    function _approveMakerSide(uint256 usdcCap, uint256 wethCap) internal {
        vm.startPrank(maker);
        // USDC: Settlement pulls tokenIn from maker on shortfall
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDC, uint160(usdcCap), 0);
        // WETH: the deposit module pulls WETH from maker during makeOnBehalf
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(depositModule), WETH, uint160(wethCap), 0);
        vm.stopPrank();
    }


    // EIP-712 hashing — must match LimitOrderSettlement exactly.

    bytes32 constant ITEM_TH =
        keccak256("Item(uint8 op,address module,uint256 amount,address recipient,bytes data)");
    bytes32 constant VALIDATOR_TH = keccak256("Validator(address target,bytes data)");
    bytes32 constant ORDER_TH = keccak256(
        "LimitOrder(address maker,uint256 nonce,uint256 deadline,address tokenIn,address tokenOut,uint256 amountIn,uint32 decayStartTime,uint32 decayDuration,uint256 startAmountOut,uint256 endAmountOut,Item[] items,Validator[] validators)"
        "Item(uint8 op,address module,uint256 amount,address recipient,bytes data)"
        "Validator(address target,bytes data)"
    );

    function _hashItems(Item[] memory items) internal pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](items.length);
        for (uint256 i; i < items.length; i++) {
            h[i] = keccak256(
                abi.encode(
                    ITEM_TH,
                    uint8(items[i].op),
                    items[i].module,
                    items[i].amount,
                    items[i].recipient,
                    keccak256(items[i].data)
                )
            );
        }
        return keccak256(abi.encodePacked(h));
    }

    function _hashValidators(Validator[] memory validators) internal pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](validators.length);
        for (uint256 i; i < validators.length; i++) {
            h[i] = keccak256(abi.encode(VALIDATOR_TH, validators[i].target, keccak256(validators[i].data)));
        }
        return keccak256(abi.encodePacked(h));
    }

    function _hashOrder(LimitOrder memory o) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_TH,
                o.maker,
                o.nonce,
                o.deadline,
                o.tokenIn,
                o.tokenOut,
                o.amountIn,
                o.decayStartTime,
                o.decayDuration,
                o.startAmountOut,
                o.endAmountOut,
                _hashItems(o.items),
                _hashValidators(o.validators)
            )
        );
    }

    function _sign(LimitOrder memory o) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), _hashOrder(o)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    // ──────────────────── The test ────────────────────
    //
    // Maker sells USDC for WETH at a fixed rate; the received WETH is
    // supplied to Aave v3 on the maker's behalf as a single MAKE item.
    //
    //   tokenIn  = USDC   (maker gives, solver receives)
    //   tokenOut = WETH   (solver gives, maker receives — then deposited)
    //
    function test_swap_and_deposit_aaveV3() public {
        uint256 usdcIn = 2_000e6; //    maker pays 2000 USDC
        uint256 wethOut = 1 ether; //    receives 1 WETH (fixed price for this test)

        // Fund actors.
        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);

        // Approvals on both sides.
        _approveMakerSide(usdcIn, wethOut);
        _approveSolverSide(wethOut, WETH);

        // Build order: one MAKE item — deposit the received WETH into Aave v3.
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
            decayDuration: 0, //        fixed-price (start == end)
            startAmountOut: wethOut,
            endAmountOut: wethOut,
            items: items,
            validators: new Validator[](0)
        });

        bytes memory sig = _sign(order);

        // Pre-state
        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);
        uint256 makerWethBefore = IERC20(WETH).balanceOf(maker);
        uint256 makerAWethBefore = IERC20(aWETH).balanceOf(maker);
        uint256 solverUsdcBefore = IERC20(USDC).balanceOf(solver);
        uint256 solverWethBefore = IERC20(WETH).balanceOf(solver);

        // Solver fills the full order in one shot.
        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, usdcIn);

        // Post-state assertions.
        assertEq(paid, wethOut, "solver paid exactly wethOut");

        assertEq(IERC20(USDC).balanceOf(maker), makerUsdcBefore - usdcIn, "maker USDC spent");
        assertEq(IERC20(WETH).balanceOf(maker), makerWethBefore, "maker WETH unchanged (deposited)");
        assertApproxEqAbs(
            IERC20(aWETH).balanceOf(maker),
            makerAWethBefore + wethOut,
            2, // allow 1-wei index rounding on Aave's side
            "maker received aWETH"
        );

        assertEq(IERC20(USDC).balanceOf(solver), solverUsdcBefore + usdcIn, "solver received USDC");
        assertEq(IERC20(WETH).balanceOf(solver), solverWethBefore - wethOut, "solver WETH spent");

        // Settlement should have no residual token balance.
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
    }

    // ──────────────────── Withdraw + swap ────────────────────
    //
    // Maker already has an aWETH position. They want to unwind WETH and
    // sell it for USDC. Sequence:
    //
    //   tokenIn  = WETH   (maker gives — sourced from the withdraw item)
    //   tokenOut = USDC   (solver gives, maker receives)
    //
    // One TAKE item: AaveV3WithdrawModule, routed via `permit3.take` so
    // the taker allowance gate enforces the exact (user, module, ref)
    // amount. aWETH proceeds flow: user aWETH → module (via token
    // allowance) → pool.withdraw burns + sends WETH → settlement.
    //
    function test_withdraw_and_swap_aaveV3() public {
        uint256 wethIn = 1 ether;
        uint256 usdcOut = 2_000e6;

        _seedAWethPosition(wethIn + 1e15); // +0.001 WETH cushion for scaled rounding
        deal(USDC, solver, usdcOut);

        bytes memory takerData = abi.encode(AAVE_POOL, WETH, aWETH);
        bytes32 ref = keccak256(takerData);

        _approveMakerWithdrawSide(wethIn, ref, takerData);
        _approveSolverSide(usdcOut, USDC);

        LimitOrder memory order = _buildWithdrawOrder(wethIn, usdcOut, takerData);
        bytes memory sig = _sign(order);

        uint256 makerAWethBefore = IERC20(aWETH).balanceOf(maker);
        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, wethIn);

        assertEq(paid, usdcOut, "solver paid exactly usdcOut");
        assertEq(IERC20(USDC).balanceOf(maker) - makerUsdcBefore, usdcOut, "maker received USDC");
        assertApproxEqAbs(makerAWethBefore - IERC20(aWETH).balanceOf(maker), wethIn, 2, "maker aWETH burned");
        assertEq(IERC20(WETH).balanceOf(solver), wethIn, "solver received WETH");

        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(aWETH).balanceOf(address(withdrawModule)), 0, "module aWETH drained");

        (uint160 remaining,,) = permit3.takerAllowance(maker, address(withdrawModule), ref);
        assertEq(remaining, 0, "taker allowance spent");
    }

    function _seedAWethPosition(uint256 amount) internal {
        deal(WETH, maker, amount);
        vm.startPrank(maker);
        IERC20(WETH).approve(AAVE_POOL, amount);
        IAaveV3Pool(AAVE_POOL).supply(WETH, amount, maker, 0);
        vm.stopPrank();
    }

    function _approveMakerWithdrawSide(uint256 wethIn, bytes32 ref, bytes memory /* takerData */) internal {
        vm.startPrank(maker);
        // Fallback for _payTokenInToSolver — never triggers in this flow.
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), WETH, uint160(wethIn), 0);
        // Withdraw module pulls aWETH via Permit3 — user infinite-approves aToken,
        // caps the per-module allowance at the order size.
        IERC20(aWETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(withdrawModule), aWETH, uint160(wethIn), 0);
        // Taker-allowance gate on the exact position.
        permit3.approveTaker(address(withdrawModule), ref, uint160(wethIn), 0);
        vm.stopPrank();
    }

    function _approveSolverSide(uint256 cap, address token) internal {
        vm.startPrank(solver);
        IERC20(token).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), token, uint160(cap), 0);
        vm.stopPrank();
    }

    function _buildWithdrawOrder(uint256 wethIn, uint256 usdcOut, bytes memory takerData)
        internal
        view
        returns (LimitOrder memory order)
    {
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.TAKE,
            module: address(withdrawModule),
            amount: wethIn,
            recipient: address(0),
            data: takerData
        });
        order = LimitOrder({
            maker: maker,
            nonce: 1,
            deadline: block.timestamp + 1 hours,
            tokenIn: WETH,
            tokenOut: USDC,
            amountIn: wethIn,
            decayStartTime: 0,
            decayDuration: 0,
            startAmountOut: usdcOut,
            endAmountOut: usdcOut,
            items: items,
            validators: new Validator[](0)
        });
    }

    // ──────────────────── Taker module security ────────────────────
    //
    // The msg.sender == permit3 check is load-bearing: without it, a
    // direct takeOnBehalf call would bypass the Permit3 taker-allowance
    // gate and drain the victim via their token allowance.
    //
    function test_takeOnBehalf_rejectsDirectCall() public {
        // Seed position so a successful drain would actually move tokens.
        deal(WETH, maker, 1 ether);
        vm.startPrank(maker);
        IERC20(WETH).approve(AAVE_POOL, 1 ether);
        IAaveV3Pool(AAVE_POOL).supply(WETH, 1 ether, maker, 0);
        IERC20(aWETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(withdrawModule), aWETH, type(uint160).max, 0);
        // (No taker approval — simulating a user who hasn't granted this specific op.)
        vm.stopPrank();

        bytes memory data = abi.encode(AAVE_POOL, WETH, aWETH);

        // Attacker tries to invoke the module directly, pointing `receiver` at themselves.
        address attacker = address(0xDEAD);
        vm.prank(attacker);
        vm.expectRevert(AaveV3WithdrawModule.OnlyPermit3.selector);
        withdrawModule.takeOnBehalf(maker, 1 ether, attacker, data);
    }

    // ──────────────────── Deposit X + borrow Y in one order ────────────────────
    //
    // Maker deposits 1 WETH as collateral and borrows 1500 USDC against
    // it. The solver funds the 1 WETH collateral and receives the 1500
    // USDC borrow proceeds in exchange. (No swap of the borrowed asset
    // back into collateral — this is deposit+borrow, not a levered
    // position.)
    //
    //   tokenIn  = USDC   (maker gives — sourced from the borrow item)
    //   tokenOut = WETH   (solver gives → forwarded into the deposit item)
    //
    // Items:
    //   [0] MAKE  AaveV3DepositModule   supply 1 WETH
    //   [1] TAKE  AaveV3BorrowModule    borrow 1500 USDC (variable rate)
    //
    // Maker side authorisations:
    //   • WETH   → Permit3 (ERC20.approve)
    //   • WETH   → depositModule via permit3.approveToken (module pulls during MAKE)
    //   • USDC variable debt token → borrowModule via approveDelegation
    //     (Aave-native credit delegation — the blast-radius caveat)
    //   • Permit3 takerAllowance on keccak256(borrowData) for 1500 USDC
    //
    function test_depositX_borrowY_aaveV3() public {
        uint256 collateralIn = 1 ether; //    maker receives + deposits
        uint256 borrowOut = 1_500e6; //        maker borrows → solver receives

        address usdcDebtToken = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][USDC].debt;

        deal(WETH, solver, collateralIn);

        _approveMakerDepositBorrowSide(collateralIn, borrowOut, usdcDebtToken);
        _approveSolverSide(collateralIn, WETH);

        LimitOrder memory order = _buildDepositBorrowOrder(collateralIn, borrowOut);
        bytes memory sig = _sign(order);

        uint256 makerAWethBefore = IERC20(aWETH).balanceOf(maker);
        uint256 makerDebtBefore = IERC20(usdcDebtToken).balanceOf(maker);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, borrowOut);

        assertEq(paid, collateralIn, "solver paid 1 WETH of collateral");

        // Maker: has a fresh ~1 aWETH collateral position and ~1500 USDC of debt.
        assertApproxEqAbs(IERC20(aWETH).balanceOf(maker) - makerAWethBefore, collateralIn, 2, "maker aWETH up");
        assertApproxEqAbs(IERC20(usdcDebtToken).balanceOf(maker) - makerDebtBefore, borrowOut, 2, "maker debt up");

        // Solver: spent WETH, received USDC.
        assertEq(IERC20(WETH).balanceOf(solver), 0, "solver WETH spent");
        assertEq(IERC20(USDC).balanceOf(solver), borrowOut, "solver received USDC");

        // Wallet balances unchanged — neither leg's asset sat in the maker's EOA.
        assertEq(IERC20(WETH).balanceOf(maker), 0, "maker WETH forwarded into deposit");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "maker USDC forwarded out via borrow");

        // Settlement & modules end empty.
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(WETH).balanceOf(address(depositModule)), 0, "deposit module WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(borrowModule)), 0, "borrow module USDC drained");
    }

    function _approveMakerDepositBorrowSide(uint256 collateralIn, uint256 borrowOut, address usdcDebtToken) internal {
        bytes memory borrowData = abi.encode(AAVE_POOL, USDC, uint256(2));
        bytes32 borrowRef = keccak256(borrowData);

        vm.startPrank(maker);
        // WETH: deposit module pulls the collateral via Permit3 during MAKE.
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(depositModule), WETH, uint160(collateralIn), 0);

        // Credit delegation: Aave-native authorisation for the borrow module to
        // incur USDC debt on the maker's behalf. Infinite here — the Permit3
        // taker allowance is what actually caps this fill.
        IAaveCreditDelegation(usdcDebtToken).approveDelegation(address(borrowModule), type(uint256).max);

        // Permit3 taker gate on the exact borrow position + amount.
        permit3.approveTaker(address(borrowModule), borrowRef, uint160(borrowOut), 0);

        // USDC fallback allowance for _payTokenInToSolver — never triggers here
        // since the borrow fully funds tokenIn, but keeps the shortfall path safe.
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDC, uint160(borrowOut), 0);
        vm.stopPrank();
    }

    function _buildDepositBorrowOrder(uint256 collateralIn, uint256 borrowOut)
        internal
        view
        returns (LimitOrder memory order)
    {
        Item[] memory items = new Item[](2);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(depositModule),
            amount: collateralIn,
            recipient: address(0),
            data: abi.encode(AAVE_POOL, WETH)
        });
        items[1] = Item({
            op: ItemOp.TAKE,
            module: address(borrowModule),
            amount: borrowOut,
            recipient: address(0),
            data: abi.encode(AAVE_POOL, USDC, uint256(2))
        });
        order = LimitOrder({
            maker: maker,
            nonce: 2,
            deadline: block.timestamp + 1 hours,
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: borrowOut,
            decayStartTime: 0,
            decayDuration: 0,
            startAmountOut: collateralIn,
            endAmountOut: collateralIn,
            items: items,
            validators: new Validator[](0)
        });
    }

    // ──────────────────── Leverage via flash loan + DEX (no inventory) ────────────────────
    //
    // Same maker intent as test_depositX_borrowY_aaveV3, but the solver
    // owns zero WETH and zero USDC. The LimitOrderLeverageSolver:
    //
    //   1. Flash-loans `collateralIn` WETH from Balancer v2.
    //   2. Settlement pulls that WETH via Permit3 → maker → deposit
    //      module supplies it as collateral.
    //   3. Borrow module mints maker's USDC debt; proceeds land at the
    //      solver.
    //   4. Solver swaps the USDC back to WETH on Uniswap v3.
    //   5. Solver repays the flash loan. Residual WETH is profit.
    //
    // The maker's order is *identical* in shape to the deposit+borrow
    // test — nothing on-chain distinguishes leverage from plain
    // deposit+borrow. The difference lives entirely in how the solver
    // sources the tokenOut inventory.
    //
    function test_leverage_via_flashLoan_aaveV3() public {
        uint256 collateralIn = 1 ether; //     deposit leg (flash-loaned by solver)
        uint256 borrowOut = 5_000e6; //         borrow leg — sized so the 5000 USDC swap
        //                                      covers 1 WETH repayment at any ETH price
        //                                      ≲ $5000 (with some slippage margin).

        // Seed maker with a healthy initial collateral position so the +1 WETH
        // deposit + 2200 USDC borrow doesn't breach LTV.
        _seedAWethPosition(10 ether);

        // Register maker-side authorisations.
        address usdcDebtToken = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][USDC].debt;
        _approveMakerDepositBorrowSide(collateralIn, borrowOut, usdcDebtToken);

        // Solver-side: register ERC20 + Permit3 allowance for WETH.
        //   (The solver's WETH originates from the flash loan inside executeFill,
        //    so it's present exactly during the Settlement pull.)
        leverageSolver.setupTokenApproval(WETH);

        // Build the order — same schema as deposit+borrow.
        LimitOrder memory order = _buildDepositBorrowOrder(collateralIn, borrowOut);
        // Bump nonce so it doesn't collide with the earlier test's nonce 2.
        order.nonce = 99;
        bytes memory sig = _sign(order);

        uint256 makerAWethBefore = IERC20(aWETH).balanceOf(maker);
        uint256 makerDebtBefore = IERC20(usdcDebtToken).balanceOf(maker);

        // Anyone can call — no operator gate.
        leverageSolver.executeFill(
            WETH,
            collateralIn,
            order,
            sig,
            borrowOut,
            500, //                         Uniswap V3 0.05% pool (USDC/WETH)
            0 //                            minSwapOut — permissive for this reference test
        );

        // Maker: +1 aWETH collateral, +2200 USDC debt.
        assertApproxEqAbs(IERC20(aWETH).balanceOf(maker) - makerAWethBefore, collateralIn, 2, "maker aWETH up");
        assertApproxEqAbs(IERC20(usdcDebtToken).balanceOf(maker) - makerDebtBefore, borrowOut, 2, "maker debt up");

        // Solver holds no USDC post-swap; any WETH is profit (non-negative).
        assertEq(IERC20(USDC).balanceOf(address(leverageSolver)), 0, "solver USDC fully swapped");
        assertGe(IERC20(WETH).balanceOf(address(leverageSolver)), 0, "solver WETH non-negative");

        // Nothing stuck anywhere else.
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(WETH).balanceOf(address(depositModule)), 0, "deposit module WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(borrowModule)), 0, "borrow module USDC drained");
    }

    // ──────────────────── Repay with over-repay dust refund ────────────────────
    //
    // Maker has an open Aave USDC debt. They sign a repay amount that
    // intentionally over-shoots (`currentDebt + buffer`) so that no
    // matter what interest accrues between signing and fill, the repay
    // lands fully. The module sweeps the unused portion back to the
    // maker.
    //
    //   tokenIn  = WETH  (maker gives — pays solver)
    //   tokenOut = USDC  (solver gives — funds the repay leg)
    //
    // Items:
    //   [0] MAKE  AaveV3RepayModule   repay up to `bufferedAmount` USDC
    //
    // Trust model for the refund: `makeOnBehalf`'s `user` argument is
    // the *only* place the refund can go — no attacker-controlled
    // redirection is possible, because `refundTo` is not a field of
    // `data`. Even if a griefer calls the module directly with a
    // victim as `user`, the residual flows back to the victim.
    //
    function test_repay_with_dust_refund_aaveV3() public {
        uint256 debtAmount = 3_000e6;
        uint256 buffer = 50e6; //              over-repay buffer for accrual
        uint256 bufferedAmount = debtAmount + buffer;
        uint256 wethForSolver = 1 ether;

        address usdcDebtToken = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][USDC].debt;

        _openUsdcDebt(debtAmount);

        // Fund solver side.
        deal(USDC, solver, bufferedAmount);

        _approveMakerRepaySide(bufferedAmount, wethForSolver);
        _approveSolverSide(bufferedAmount, USDC);

        // Record pre-state.
        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);
        uint256 makerWethBefore = IERC20(WETH).balanceOf(maker);
        uint256 makerDebtBefore = IERC20(usdcDebtToken).balanceOf(maker);
        assertGt(makerDebtBefore, 0, "pre: maker should have debt");

        LimitOrder memory order = _buildRepayOrder(bufferedAmount, wethForSolver);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, wethForSolver);

        assertEq(paid, bufferedAmount, "solver paid buffered USDC");

        // Debt fully closed.
        assertEq(IERC20(usdcDebtToken).balanceOf(maker), 0, "debt zeroed");

        // Dust refunded to maker. Maker originally held `makerUsdcBefore` USDC;
        // the solver's buffered payment passed through the repay module and
        // what wasn't consumed by Aave came back.
        uint256 actualRepaid = makerDebtBefore; //                 ≈ debtAmount + tiny accrual
        uint256 expectedDust = bufferedAmount - actualRepaid;
        uint256 makerUsdcDelta = IERC20(USDC).balanceOf(maker) - makerUsdcBefore;
        assertApproxEqAbs(makerUsdcDelta, expectedDust, 1e6, "dust refunded to maker");
        assertGt(makerUsdcDelta, 0, "some dust exists given the buffer");

        // Solver spent USDC, gained WETH.
        assertEq(IERC20(USDC).balanceOf(solver), 0, "solver USDC spent");
        assertEq(IERC20(WETH).balanceOf(solver), wethForSolver, "solver received WETH");
        assertEq(IERC20(WETH).balanceOf(maker), makerWethBefore - wethForSolver, "maker WETH spent");

        // Module holds nothing — residual was swept, dust returned to maker.
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), 0, "repay module USDC drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
    }

    /// @dev Maker supplies collateral + borrows `debt` USDC against it.
    function _openUsdcDebt(uint256 debt) internal {
        deal(WETH, maker, 11 ether);
        vm.startPrank(maker);
        // Collateral
        IERC20(WETH).approve(AAVE_POOL, 10 ether);
        IAaveV3Pool(AAVE_POOL).supply(WETH, 10 ether, maker, 0);
        // Borrow
        IAaveV3Pool(AAVE_POOL).borrow(USDC, debt, 2, 0, maker);
        // Dump the borrowed USDC so the post-fill USDC delta cleanly equals the
        // dust refund without being confounded by the initial borrow proceeds.
        IERC20(USDC).transfer(address(0xdead), debt);
        vm.stopPrank();
        // Maker now has: 1 WETH wallet, ~debt USDC variable debt, 0 USDC wallet.
    }

    function _approveMakerRepaySide(uint256 bufferedAmount, uint256 wethForSolver) internal {
        vm.startPrank(maker);
        // tokenIn leg: maker pays WETH to solver via Permit3
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), WETH, uint160(wethForSolver), 0);
        // repay leg: repay module pulls USDC from maker
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(repayModule), USDC, uint160(bufferedAmount), 0);
        vm.stopPrank();
    }

    function _buildRepayOrder(uint256 bufferedAmount, uint256 wethForSolver)
        internal
        view
        returns (LimitOrder memory order)
    {
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(repayModule),
            amount: bufferedAmount,
            recipient: address(0),
            data: abi.encode(AAVE_POOL, USDC, uint256(2))
        });
        order = LimitOrder({
            maker: maker,
            nonce: 3,
            deadline: block.timestamp + 1 hours,
            tokenIn: WETH,
            tokenOut: USDC,
            amountIn: wethForSolver,
            decayStartTime: 0,
            decayDuration: 0,
            startAmountOut: bufferedAmount,
            endAmountOut: bufferedAmount,
            items: items,
            validators: new Validator[](0)
        });
    }

    // ──────────────────── Migrate Aave v3 → Spark (4-item order, exact amounts) ────────────────────
    //
    // Maker has an open Aave v3 position (10 WETH collateral, 3000 USDC debt).
    // They sign ONE 4-item order that closes the Aave position and opens an
    // equivalent Spark position. Spark is an Aave v3 fork on mainnet — same ABI,
    // so we reuse the existing Aave modules pointed at the Spark pool via `data`.
    //
    // Items (strictly ordered):
    //   [0] MAKE  AaveV3RepayModule         repay (debt + buffer), dust → maker
    //   [1] TAKE  AaveV3WithdrawModule      withdraw `exactWeth` WETH, recipient = maker
    //   [2] MAKE  AaveV3DepositModule→Spark deposit `exactWeth` WETH onto Spark
    //   [3] TAKE  AaveV3BorrowModule→Spark  borrow 3000 USDC on Spark, recipient = Settlement
    //
    //   tokenIn  = USDC   (Settlement → solver: `debt` — paid entirely from Spark borrow proceeds)
    //   tokenOut = USDC   (solver → maker:    `bufferedRepay` — funds the over-repay)
    //
    // Net for maker: Aave position zeroed; Spark mirror position opened; wallet gains `repayBuffer`
    // worth of USDC (the solver's margin — in a real order this is priced via dutch decay, here
    // it's a static gap for clarity).
    // Net for solver: pays `bufferedRepay`, receives `debt`. The gap is what pays for solving.
    //
    function test_migrate_aaveV3_to_spark() public {
        uint256 collateral = 10 ether; //    WETH collateral on Aave (also re-supplied on Spark)
        uint256 exactWeth = 9 ether; //      conservative floor for withdrawal (leaves dust on Aave)
        uint256 debt = 3_000e6; //           USDC debt on Aave (no accrual in test → exact)
        uint256 repayBuffer = 50e6;
        uint256 bufferedRepay = debt + repayBuffer;

        address SPARK_POOL = lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.SPARK];
        address spWETH = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SPARK][WETH].collateral;
        address sparkUsdcDebt = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.SPARK][USDC].debt;
        address aaveUsdcDebt = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][USDC].debt;

        vm.label(SPARK_POOL, "sparkPool");
        vm.label(spWETH, "spWETH");
        vm.label(sparkUsdcDebt, "sparkUsdcDebt");

        _openAaveV3UsdcDebt(collateral, debt);

        // Fund solver.
        deal(USDC, solver, bufferedRepay);

        _approveMakerMigrationSide(
            bufferedRepay, exactWeth, debt, SPARK_POOL, sparkUsdcDebt
        );
        _approveSolverSide(bufferedRepay, USDC);

        LimitOrder memory order = _buildMigrationOrder(
            bufferedRepay, exactWeth, debt, SPARK_POOL
        );
        bytes memory sig = _sign(order);

        uint256 makerAaveAWethBefore = IERC20(aWETH).balanceOf(maker);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, debt);

        assertEq(paid, bufferedRepay, "solver paid bufferedRepay tokenOut");

        // Maker ended with: Aave debt 0, Aave collateral ≈ 1 WETH (10 supplied - 9 withdrawn),
        // Spark collateral ≈ 9 WETH, Spark debt = 3000 USDC.
        assertEq(IERC20(aaveUsdcDebt).balanceOf(maker), 0, "Aave USDC debt closed");
        assertApproxEqAbs(
            IERC20(aWETH).balanceOf(maker), makerAaveAWethBefore - exactWeth, 2, "Aave collateral reduced by exactWeth"
        );
        assertApproxEqAbs(IERC20(spWETH).balanceOf(maker), exactWeth, 2, "Spark collateral opened");
        assertApproxEqAbs(IERC20(sparkUsdcDebt).balanceOf(maker), debt, 2, "Spark USDC debt opened");

        // Maker wallet: +repayBuffer USDC (solver's margin) — in a production flow this would be
        // near-zero under dutch decay, but the static spread keeps the test deterministic.
        assertApproxEqAbs(IERC20(USDC).balanceOf(maker), repayBuffer, 2, "maker wallet USDC = repay buffer");
        assertEq(IERC20(WETH).balanceOf(maker), 1 ether, "maker wallet WETH untouched by migration");

        // Solver paid bufferedRepay, received debt = bufferedRepay - repayBuffer.
        assertEq(IERC20(USDC).balanceOf(solver), debt, "solver USDC = debt (spread paid for solving)");

        // Nothing stuck at Settlement or modules.
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), 0, "repay module drained");
        assertEq(IERC20(WETH).balanceOf(address(depositModule)), 0, "deposit module drained");
        assertEq(IERC20(WETH).balanceOf(address(withdrawModule)), 0, "withdraw module drained");
        assertEq(IERC20(USDC).balanceOf(address(borrowModule)), 0, "borrow module drained");
    }

    function _openAaveV3UsdcDebt(uint256 collateral, uint256 debt) internal {
        deal(WETH, maker, collateral + 1 ether); // +1 extra WETH to keep in wallet
        vm.startPrank(maker);
        IERC20(WETH).approve(AAVE_POOL, collateral);
        IAaveV3Pool(AAVE_POOL).supply(WETH, collateral, maker, 0);
        IAaveV3Pool(AAVE_POOL).borrow(USDC, debt, 2, 0, maker);
        // Dump borrowed USDC so wallet starts clean.
        IERC20(USDC).transfer(address(0xdead), debt);
        vm.stopPrank();
    }

    function _approveMakerMigrationSide(
        uint256 bufferedRepay,
        uint256 exactWeth,
        uint256 debt,
        address SPARK_POOL,
        address sparkUsdcDebt
    ) internal {
        vm.startPrank(maker);

        // [0] Repay leg: maker → repayModule pulls USDC via Permit3.
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(repayModule), USDC, uint160(bufferedRepay), 0);
        // Settlement also pulls USDC for the tokenIn shortfall payout (buffered - borrow).
        permit3.approveToken(address(settlement), USDC, uint160(bufferedRepay), 0);

        // [1] Aave withdraw leg: withdrawModule pulls aWETH via Permit3.
        IERC20(aWETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(withdrawModule), aWETH, uint160(exactWeth), 0);
        bytes memory aaveWithdrawData = abi.encode(AAVE_POOL, WETH, aWETH);
        permit3.approveTaker(address(withdrawModule), keccak256(aaveWithdrawData), uint160(exactWeth), 0);

        // [2] Spark deposit leg: depositModule pulls WETH from maker via Permit3.
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(depositModule), WETH, uint160(exactWeth), 0);

        // [3] Spark borrow leg: protocol-native credit delegation + Permit3 taker cap.
        IAaveCreditDelegation(sparkUsdcDebt).approveDelegation(address(borrowModule), type(uint256).max);
        bytes memory sparkBorrowData = abi.encode(SPARK_POOL, USDC, uint256(2));
        permit3.approveTaker(address(borrowModule), keccak256(sparkBorrowData), uint160(debt), 0);

        vm.stopPrank();
    }

    function _buildMigrationOrder(
        uint256 bufferedRepay,
        uint256 exactWeth,
        uint256 debt,
        address SPARK_POOL
    ) internal view returns (LimitOrder memory order) {
        Item[] memory items = new Item[](4);

        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(repayModule),
            amount: bufferedRepay,
            recipient: address(0),
            data: abi.encode(AAVE_POOL, USDC, uint256(2))
        });
        items[1] = Item({
            op: ItemOp.TAKE,
            module: address(withdrawModule),
            amount: exactWeth,
            recipient: maker, //          chain WETH into the deposit item
            data: abi.encode(AAVE_POOL, WETH, aWETH)
        });
        items[2] = Item({
            op: ItemOp.MAKE,
            module: address(depositModule),
            amount: exactWeth,
            recipient: address(0),
            data: abi.encode(SPARK_POOL, WETH)
        });
        items[3] = Item({
            op: ItemOp.TAKE,
            module: address(borrowModule),
            amount: debt,
            recipient: address(0), //      default = Settlement for tokenIn payout
            data: abi.encode(SPARK_POOL, USDC, uint256(2))
        });

        order = LimitOrder({
            maker: maker,
            nonce: 7,
            deadline: block.timestamp + 1 hours,
            tokenIn: USDC,
            tokenOut: USDC,
            amountIn: debt, //             Settlement pays solver entirely from the borrow proceeds
            decayStartTime: 0,
            decayDuration: 0,
            startAmountOut: bufferedRepay,
            endAmountOut: bufferedRepay,
            items: items,
            validators: new Validator[](0)
        });
    }

    // ──────────────────── Single-signature fill ────────────────────
    //
    // The maker's wallet has done ZERO setup with Permit3 except the
    // bare `IERC20.approve(permit3, ∞)` per token (a one-time prerequisite
    // for any Permit3 user). They sign exactly ONE EIP-712 message that
    // bundles:
    //   • a PermitBatch (token allowances Settlement + the deposit module need)
    //   • a witness binding the permits to this specific LimitOrder
    //
    // Solver calls `fillWithPermit(order, batch, sig, fillAmountIn)`:
    //   1. Settlement asks Permit3 to verify the sig against
    //      EIP-712(PermitBatchWitness, witness=orderHash) and apply the
    //      allowances.
    //   2. Settlement runs the normal fill core. The freshly-applied
    //      allowances satisfy every Permit3.transferFrom inside the fill.
    //   3. Permit's nonce is consumed. The same signature can never be
    //      replayed (different witness → different digest; same witness +
    //      different batch → invalid sig; same exact bundle → nonce reused).
    //
    function test_fillWithPermit_singleSignature() public {
        uint256 usdcIn = 2_000e6;
        uint256 wethOut = 1 ether;

        deal(USDC, maker, usdcIn);
        deal(WETH, solver, wethOut);

        // ── Maker side: ONLY bare ERC20 approve to Permit3. No permit3.approveX calls. ──
        vm.startPrank(maker);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        vm.stopPrank();

        // Solver still needs its own one-time approval (separate user).
        _approveSolverSide(wethOut, WETH);

        // Build order.
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
            nonce: 42,
            deadline: block.timestamp + 1 hours,
            tokenIn: USDC,
            tokenOut: WETH,
            amountIn: usdcIn,
            decayStartTime: 0,
            decayDuration: 0,
            startAmountOut: wethOut,
            endAmountOut: wethOut,
            items: items,
            validators: new Validator[](0)
        });

        // Build the permit batch the fill needs:
        //   - settlement may pull USDC for tokenIn shortfall (cap = full amountIn for safety)
        //   - depositModule pulls WETH for the supply
        IPermit3.TokenPermit[] memory tokenPermits = new IPermit3.TokenPermit[](2);
        tokenPermits[0] = IPermit3.TokenPermit({
            spender: address(settlement),
            token: USDC,
            amount: uint160(usdcIn),
            expiration: uint48(order.deadline)
        });
        tokenPermits[1] = IPermit3.TokenPermit({
            spender: address(depositModule),
            token: WETH,
            amount: uint160(wethOut),
            expiration: uint48(order.deadline)
        });
        IPermit3.TakerPermit[] memory takerPermits = new IPermit3.TakerPermit[](0);

        IPermit3.PermitBatch memory batch = IPermit3.PermitBatch({
            tokens: tokenPermits,
            takers: takerPermits,
            nonce: 1,
            deadline: order.deadline
        });

        // Sign the witness-bound permit.
        bytes memory sig = _signPermitBatchWitness(batch, _hashOrder(order));

        // Fill — single solver call, single maker signature.
        vm.prank(solver);
        uint256 paid = settlement.fillWithPermit(order, batch, sig, usdcIn);

        assertEq(paid, wethOut, "solver paid 1 WETH");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "maker USDC pulled");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver received USDC");
        assertApproxEqAbs(IERC20(aWETH).balanceOf(maker), wethOut, 2, "maker received aWETH");

        // Permit nonce now used; signature non-replayable.
        assertTrue(permit3.isPermitNonceUsed(maker, 1), "permit nonce used");

        // Order nonce path is independent and untouched (no order sig was used).
        assertFalse(settlement.isNonceCancelled(maker, order.nonce), "order nonce untouched");
    }

    // ──────────────────── Permit-witness signing helpers ────────────────────

    bytes32 constant TOKEN_PERMIT_TH =
        keccak256("TokenPermit(address spender,address token,uint160 amount,uint48 expiration)");
    bytes32 constant TAKER_PERMIT_TH =
        keccak256("TakerPermit(address module,bytes32 ref,uint160 amount,uint48 expiration)");

    /// @dev Must mirror Permit3's `_PERMIT_BATCH_WITNESS_STUB` + Settlement's
    ///      `_LIMIT_ORDER_WITNESS_TYPESTRING` exactly.
    string constant PERMIT_BATCH_WITNESS_FULL_TYPESTRING =
        "PermitBatchWitness(TokenPermit[] tokens,TakerPermit[] takers,uint256 nonce,uint256 deadline,"
        "LimitOrder witness)"
        "Item(uint8 op,address module,uint256 amount,address recipient,bytes data)"
        "LimitOrder(address maker,uint256 nonce,uint256 deadline,address tokenIn,address tokenOut,uint256 amountIn,uint32 decayStartTime,uint32 decayDuration,uint256 startAmountOut,uint256 endAmountOut,Item[] items,Validator[] validators)"
        "TakerPermit(address module,bytes32 ref,uint160 amount,uint48 expiration)"
        "TokenPermit(address spender,address token,uint160 amount,uint48 expiration)"
        "Validator(address target,bytes data)";

    function _hashTokenPermits(IPermit3.TokenPermit[] memory permits) internal pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](permits.length);
        for (uint256 i; i < permits.length; i++) {
            h[i] = keccak256(
                abi.encode(
                    TOKEN_PERMIT_TH, permits[i].spender, permits[i].token, permits[i].amount, permits[i].expiration
                )
            );
        }
        return keccak256(abi.encodePacked(h));
    }

    function _hashTakerPermits(IPermit3.TakerPermit[] memory permits) internal pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](permits.length);
        for (uint256 i; i < permits.length; i++) {
            h[i] = keccak256(
                abi.encode(
                    TAKER_PERMIT_TH, permits[i].module, permits[i].ref, permits[i].amount, permits[i].expiration
                )
            );
        }
        return keccak256(abi.encodePacked(h));
    }

    function _signPermitBatchWitness(IPermit3.PermitBatch memory batch, bytes32 witness)
        internal
        view
        returns (bytes memory)
    {
        bytes32 typeHash = keccak256(bytes(PERMIT_BATCH_WITNESS_FULL_TYPESTRING));
        bytes32 hashStruct = keccak256(
            abi.encode(
                typeHash,
                _hashTokenPermits(batch.tokens),
                _hashTakerPermits(batch.takers),
                batch.nonce,
                batch.deadline,
                witness
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", permit3.DOMAIN_SEPARATOR(), hashStruct));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    // ──────────────────── Validators: stop-loss gating ────────────────────
    //
    // Maker holds an aWETH position. They sign an order to unwind it into
    // USDC, gated by a Chainlink ETH/USD price validator.
    //
    // Two scenarios:
    //   • threshold FAR BELOW current price → validator returns false → fill reverts
    //   • threshold FAR ABOVE current price → validator returns true  → fill succeeds
    //
    // Both use the `ChainlinkPriceLte` validator — typical stop-loss pattern
    // ("fill when price drops to X or lower"). Signing a threshold the market
    // hasn't reached protects the maker from accidental early execution.

    address constant ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    int256 constant FAR_BELOW_MARKET = int256(500 * 1e8); //     $500 — ETH is far above
    int256 constant FAR_ABOVE_MARKET = int256(1_000_000 * 1e8); // $1M — never

    function test_validator_rejectsWhenConditionNotMet() public {
        ChainlinkPriceLte priceLte = new ChainlinkPriceLte();

        uint256 wethIn = 1 ether;
        uint256 usdcOut = 2_000e6;

        _seedAWethPosition(wethIn + 1e15);
        deal(USDC, solver, usdcOut);

        bytes memory takerData = abi.encode(AAVE_POOL, WETH, aWETH);
        bytes32 ref = keccak256(takerData);

        _approveMakerWithdrawSide(wethIn, ref, takerData);
        _approveSolverSide(usdcOut, USDC);

        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.TAKE, module: address(withdrawModule), amount: wethIn, recipient: address(0), data: takerData});

        Validator[] memory validators = new Validator[](1);
        validators[0] = Validator({
            target: address(priceLte),
            data: abi.encode(ETH_USD_FEED, FAR_BELOW_MARKET)
        });

        LimitOrder memory order = _orderWithValidators(101, WETH, USDC, wethIn, usdcOut, items, validators);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(LimitOrderSettlement.ValidationFailed.selector, uint256(0)));
        settlement.fill(order, sig, wethIn);
    }

    function test_validator_passesWhenConditionMet() public {
        ChainlinkPriceLte priceLte = new ChainlinkPriceLte();

        uint256 wethIn = 1 ether;
        uint256 usdcOut = 2_000e6;

        _seedAWethPosition(wethIn + 1e15);
        deal(USDC, solver, usdcOut);

        bytes memory takerData = abi.encode(AAVE_POOL, WETH, aWETH);
        bytes32 ref = keccak256(takerData);

        _approveMakerWithdrawSide(wethIn, ref, takerData);
        _approveSolverSide(usdcOut, USDC);

        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.TAKE, module: address(withdrawModule), amount: wethIn, recipient: address(0), data: takerData});

        Validator[] memory validators = new Validator[](1);
        validators[0] = Validator({
            target: address(priceLte),
            data: abi.encode(ETH_USD_FEED, FAR_ABOVE_MARKET)
        });

        LimitOrder memory order = _orderWithValidators(102, WETH, USDC, wethIn, usdcOut, items, validators);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, wethIn);

        assertEq(paid, usdcOut, "filled when gate opened");
        assertEq(IERC20(USDC).balanceOf(maker), usdcOut, "maker received USDC");
    }

    function _orderWithValidators(
        uint256 nonce,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        Item[] memory items,
        Validator[] memory validators
    ) internal view returns (LimitOrder memory) {
        return LimitOrder({
            maker: maker,
            nonce: nonce,
            deadline: block.timestamp + 1 hours,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            decayStartTime: 0,
            decayDuration: 0,
            startAmountOut: amountOut,
            endAmountOut: amountOut,
            items: items,
            validators: validators
        });
    }
}
