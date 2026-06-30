// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {Order, Item, ItemOp, Validator} from "@core/settlement/UniversalSettlement.sol";
import {LimitOrderLeverageSolver} from "@core/solver/LimitOrderLeverageSolver.sol";

import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";
import {Chains, Lenders} from "@coretest/data/LenderRegistry.sol";

import {IAaveV3Pool, IAaveCreditDelegation} from "../../src/interfaces/IAaveV3.sol";
import {
    AaveV3DepositModule,
    AaveV3RepayModule,
    AaveV3WithdrawModule,
    AaveV3BorrowModule
} from "../../src/AaveV3Modules.sol";

/// @dev Aave integration harness. Extends the module-free CoreSettlementBase and
/// layers the Aave adapter fixtures (deposit / withdraw / borrow / repay) plus a
/// leverage solver on top, along with the position-seeding, approval and
/// order-building helpers the module action tests compose. The dependency points
/// the right way: this module package depends on the core package, never the
/// other way around.
abstract contract AaveModulesBase is CoreSettlementBase {
    AaveV3DepositModule depositModule;
    AaveV3WithdrawModule withdrawModule;
    AaveV3BorrowModule borrowModule;
    AaveV3RepayModule repayModule;
    LimitOrderLeverageSolver leverageSolver;

    address AAVE_POOL;
    address aWETH;
    address usdcDebtToken;

    function setUp() public virtual override {
        super.setUp();

        AAVE_POOL = lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3];
        aWETH = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][WETH].collateral;
        usdcDebtToken = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][USDC].debt;

        depositModule = new AaveV3DepositModule(address(permit3), address(settlement));
        withdrawModule = new AaveV3WithdrawModule(address(permit3));
        borrowModule = new AaveV3BorrowModule(address(permit3));
        repayModule = new AaveV3RepayModule(address(permit3), address(settlement));
        // Balancer v2 Vault + UniswapV3 SwapRouter — mainnet canonical addresses.
        leverageSolver = new LimitOrderLeverageSolver(
            address(permit3),
            address(settlement),
            0xBA12222222228d8Ba445958a75a0704d566BF2C8,
            0xE592427A0AEce92De3Edee1F18E0157C05861564
        );

        vm.label(address(depositModule), "aaveV3DepositModule");
        vm.label(address(withdrawModule), "aaveV3WithdrawModule");
        vm.label(address(borrowModule), "aaveV3BorrowModule");
        vm.label(address(repayModule), "aaveV3RepayModule");
        vm.label(address(leverageSolver), "leverageSolver");
        vm.label(AAVE_POOL, "aaveV3Pool");
        vm.label(aWETH, "aWETH");

        // Maker bare-approves aWETH to Permit3 (the withdraw module pulls it).
        vm.prank(maker);
        IERC20(aWETH).approve(address(permit3), type(uint256).max);
    }

    // ──────────────────── Position seeding ────────────────────

    function _seedAWethPosition(uint256 amount) internal {
        deal(WETH, maker, amount);
        vm.startPrank(maker);
        IERC20(WETH).approve(AAVE_POOL, amount);
        IAaveV3Pool(AAVE_POOL).supply(WETH, amount, maker, 0);
        vm.stopPrank();
    }

    /// @dev Maker supplies 10 WETH collateral + borrows `debt` USDC against it,
    ///      then dumps the borrowed USDC so the wallet starts clean.
    function _openUsdcDebt(uint256 debt) internal {
        deal(WETH, maker, 11 ether);
        vm.startPrank(maker);
        IERC20(WETH).approve(AAVE_POOL, 10 ether);
        IAaveV3Pool(AAVE_POOL).supply(WETH, 10 ether, maker, 0);
        IAaveV3Pool(AAVE_POOL).borrow(USDC, debt, 2, 0, maker);
        IERC20(USDC).transfer(address(0xdead), debt);
        vm.stopPrank();
    }

    /// @dev Maker supplies `collateral` WETH (+1 WETH kept in wallet) and borrows
    ///      `debt` USDC, dumping the proceeds so the wallet starts clean.
    function _openAaveV3Position(uint256 collateral, uint256 debt) internal {
        deal(WETH, maker, collateral + 1 ether);
        vm.startPrank(maker);
        IERC20(WETH).approve(AAVE_POOL, collateral);
        IAaveV3Pool(AAVE_POOL).supply(WETH, collateral, maker, 0);
        IAaveV3Pool(AAVE_POOL).borrow(USDC, debt, 2, 0, maker);
        IERC20(USDC).transfer(address(0xdead), debt);
        vm.stopPrank();
    }

    // ──────────────────── Approval helpers ────────────────────

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
        permit3.approveTaker(address(settlement), ref, uint160(wethIn), 0);
        vm.stopPrank();
    }

    function _approveMakerDepositBorrowSide(uint256 collateralIn, uint256 borrowOut) internal {
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
        permit3.approveTaker(address(settlement), borrowRef, uint160(borrowOut), 0);

        // USDC fallback allowance for _payTokenInToSolver — never triggers here
        // since the borrow fully funds tokenIn, but keeps the shortfall path safe.
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDC, uint160(borrowOut), 0);
        vm.stopPrank();
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
        permit3.approveTaker(address(settlement), keccak256(aaveWithdrawData), uint160(exactWeth), 0);

        // [2] Spark deposit leg: depositModule pulls WETH from maker via Permit3.
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(depositModule), WETH, uint160(exactWeth), 0);

        // [3] Spark borrow leg: protocol-native credit delegation + Permit3 taker cap.
        IAaveCreditDelegation(sparkUsdcDebt).approveDelegation(address(borrowModule), type(uint256).max);
        bytes memory sparkBorrowData = abi.encode(SPARK_POOL, USDC, uint256(2));
        permit3.approveTaker(address(settlement), keccak256(sparkBorrowData), uint160(debt), 0);

        vm.stopPrank();
    }

    // ──────────────────── Module order builders ────────────────────

    function _buildWithdrawOrder(uint256 wethIn, uint256 usdcOut, bytes memory takerData)
        internal
        view
        returns (Order memory order)
    {
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.TAKE,
            module: address(withdrawModule),
            amount: wethIn,
            recipient: address(0),
            data: takerData
        });
        order = _order(maker, 1, WETH, USDC, wethIn, usdcOut, items);
    }

    function _buildDepositBorrowOrder(uint256 collateralIn, uint256 borrowOut)
        internal
        view
        returns (Order memory order)
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
        order = _order(maker, 2, USDC, WETH, borrowOut, collateralIn, items);
    }

    function _buildRepayOrder(uint256 bufferedAmount, uint256 wethForSolver)
        internal
        view
        returns (Order memory order)
    {
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(repayModule),
            amount: bufferedAmount,
            recipient: address(0),
            data: abi.encode(AAVE_POOL, USDC, uint256(2), usdcDebtToken)
        });
        order = _order(maker, 3, WETH, USDC, wethForSolver, bufferedAmount, items);
    }

    function _buildMigrationOrder(
        uint256 bufferedRepay,
        uint256 exactWeth,
        uint256 debt,
        address SPARK_POOL
    ) internal view returns (Order memory order) {
        Item[] memory items = new Item[](4);

        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(repayModule),
            amount: bufferedRepay,
            recipient: address(0),
            data: abi.encode(AAVE_POOL, USDC, uint256(2), usdcDebtToken)
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

        order = Order({
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
            exclusiveFiller: address(0),
            exclusivityEndTime: 0,
            minFillAmountIn: 0,
            items: items,
            validators: new Validator[](0),
            invariants: new Validator[](0)
        });
    }
}
