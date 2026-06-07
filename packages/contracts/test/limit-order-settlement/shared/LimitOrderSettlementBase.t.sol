// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Permit3} from "../../../src/permit3/Permit3.sol";
import {IPermit3} from "../../../src/interfaces/IPermit3.sol";
import {
    LimitOrderSettlement,
    LimitOrder,
    Item,
    ItemOp,
    Validator
} from "../../../src/settlement/LimitOrderSettlement.sol";
import {LimitOrderLeverageSolver} from "../../../src/solver/LimitOrderLeverageSolver.sol";

import {LenderRegistry, Chains, Lenders, Tokens} from "../../data/LenderRegistry.sol";

import {
    IAaveV3Pool,
    IAaveCreditDelegation,
    AaveV3DepositModule,
    AaveV3RepayModule,
    AaveV3WithdrawModule,
    AaveV3BorrowModule
} from "./Modules.sol";

/// @dev Shared harness for every LimitOrderSettlement action test.
///
/// Holds the deployed system (Permit3 + Settlement + the Aave maker/taker
/// modules + the leverage solver), the maker/solver actors, the EIP-712
/// hashing/signing machinery for both the order signature and the
/// single-signature permit-batch-witness flow, and the position-seeding /
/// approval / order-building helpers the action files compose.
///
/// Action tests inherit this and contain only their `test_*` functions.
abstract contract LimitOrderSettlementBase is Test, LenderRegistry {
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

        // ── Maker: bare ERC20 approves to Permit3. The single-signature permit
        //    tests rely on these and grant their per-spender allowances in-band;
        //    the direct-fill tests layer their own capped `approveToken` calls on
        //    top (idempotent / overwriting), so this is safe for both flows. ──
        vm.startPrank(maker);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        IERC20(aWETH).approve(address(permit3), type(uint256).max);
        vm.stopPrank();

        // ── Solver: standing Permit3 allowance (solvers are contracts with a
        //    one-time setup). The permit tests rely on this standing allowance;
        //    the direct-fill tests overwrite the per-token cap via
        //    `_approveSolverSide`. ──
        vm.startPrank(solver);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), WETH, type(uint160).max, 0);
        permit3.approveToken(address(settlement), USDC, type(uint160).max, 0);
        vm.stopPrank();
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
        revert("LimitOrderSettlementBase: no working mainnet RPC (set ETH_RPC_URL to bypass)");
    }

    /// @dev External self-call so a reverting `createSelectFork` can be caught
    ///      by try/catch (cheatcode reverts propagate through external boundaries).
    function __fork(string calldata rpc) external {
        // Pin to a block with headroom under Aave market caps for deterministic tests.
        // drpc.org, flashbots, and the public nodes all serve this block.
        vm.createSelectFork(rpc, 22_000_000);
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
    ///      then dumps the borrowed USDC so the wallet starts clean (the post-fill
    ///      USDC delta then isn't confounded by the initial borrow proceeds).
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

    // ──────────────────── Direct-fill approval helpers ────────────────────

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

    function _approveSolverSide(uint256 cap, address token) internal {
        vm.startPrank(solver);
        IERC20(token).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), token, uint160(cap), 0);
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

    // ──────────────────── Order builders ────────────────────

    /// @dev Generic fixed-price single-/multi-item order with no extra gating.
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
            exclusiveFiller: address(0),
            exclusivityEndTime: 0,
            minFillAmountIn: 0,
            items: items,
            validators: new Validator[](0),
            invariants: new Validator[](0)
        });
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
        order = _order(maker, 1, WETH, USDC, wethIn, usdcOut, items);
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
        order = _order(maker, 2, USDC, WETH, borrowOut, collateralIn, items);
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
        order = _order(maker, 3, WETH, USDC, wethForSolver, bufferedAmount, items);
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
            exclusiveFiller: address(0),
            exclusivityEndTime: 0,
            minFillAmountIn: 0,
            items: items,
            validators: new Validator[](0),
            invariants: new Validator[](0)
        });
    }

    function _orderWithExclusivity(
        uint256 nonce, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut,
        Item[] memory items, address exclusiveFiller, uint32 exclusivityEndTime
    ) internal view returns (LimitOrder memory) {
        return LimitOrder({
            maker: maker, nonce: nonce, deadline: block.timestamp + 1 hours,
            tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn,
            decayStartTime: 0, decayDuration: 0,
            startAmountOut: amountOut, endAmountOut: amountOut,
            exclusiveFiller: exclusiveFiller,
            exclusivityEndTime: exclusivityEndTime,
            minFillAmountIn: 0,
            items: items,
            validators: new Validator[](0),
            invariants: new Validator[](0)
        });
    }

    function _orderWithMinFill(
        uint256 nonce, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut,
        Item[] memory items, uint256 minFillAmountIn
    ) internal view returns (LimitOrder memory) {
        return LimitOrder({
            maker: maker, nonce: nonce, deadline: block.timestamp + 1 hours,
            tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn,
            decayStartTime: 0, decayDuration: 0,
            startAmountOut: amountOut, endAmountOut: amountOut,
            exclusiveFiller: address(0), exclusivityEndTime: 0,
            minFillAmountIn: minFillAmountIn,
            items: items,
            validators: new Validator[](0),
            invariants: new Validator[](0)
        });
    }

    function _orderWithInvariants(
        uint256 nonce, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut,
        Item[] memory items, Validator[] memory invariants
    ) internal view returns (LimitOrder memory) {
        return LimitOrder({
            maker: maker, nonce: nonce, deadline: block.timestamp + 1 hours,
            tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn,
            decayStartTime: 0, decayDuration: 0,
            startAmountOut: amountOut, endAmountOut: amountOut,
            exclusiveFiller: address(0), exclusivityEndTime: 0, minFillAmountIn: 0,
            items: items,
            validators: new Validator[](0),
            invariants: invariants
        });
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
            exclusiveFiller: address(0),
            exclusivityEndTime: 0,
            minFillAmountIn: 0,
            items: items,
            validators: validators,
            invariants: new Validator[](0)
        });
    }

    // ──────────────────── Permit-batch builders ────────────────────

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

    // ──────────────────── EIP-712 hashing + signing ────────────────────
    //
    // Type hashes must match LimitOrderSettlement / Permit3 exactly.

    bytes32 constant ITEM_TH =
        keccak256("Item(uint8 op,address module,uint256 amount,address recipient,bytes data)");
    bytes32 constant VALIDATOR_TH = keccak256("Validator(address target,bytes data)");
    bytes32 constant ORDER_TH = keccak256(
        "LimitOrder(address maker,uint256 nonce,uint256 deadline,address tokenIn,address tokenOut,uint256 amountIn,uint32 decayStartTime,uint32 decayDuration,uint256 startAmountOut,uint256 endAmountOut,address exclusiveFiller,uint32 exclusivityEndTime,uint256 minFillAmountIn,Item[] items,Validator[] validators,Validator[] invariants)"
        "Item(uint8 op,address module,uint256 amount,address recipient,bytes data)"
        "Validator(address target,bytes data)"
    );
    bytes32 constant TOKEN_PERMIT_TH =
        keccak256("TokenPermit(address spender,address token,uint160 amount,uint48 expiration)");
    bytes32 constant TAKER_PERMIT_TH =
        keccak256("TakerPermit(address module,bytes32 ref,uint160 amount,uint48 expiration)");

    /// @dev Must mirror Permit3's `_PERMIT_BATCH_WITNESS_STUB` + Settlement's
    ///      `_LIMIT_ORDER_WITNESS_TYPESTRING` exactly.
    string constant PERMIT_BATCH_WITNESS_FULL =
        "PermitBatchWitness(TokenPermit[] tokens,TakerPermit[] takers,uint256 nonce,uint256 deadline,"
        "LimitOrder witness)"
        "Item(uint8 op,address module,uint256 amount,address recipient,bytes data)"
        "LimitOrder(address maker,uint256 nonce,uint256 deadline,address tokenIn,address tokenOut,uint256 amountIn,uint32 decayStartTime,uint32 decayDuration,uint256 startAmountOut,uint256 endAmountOut,address exclusiveFiller,uint32 exclusivityEndTime,uint256 minFillAmountIn,Item[] items,Validator[] validators,Validator[] invariants)"
        "TakerPermit(address module,bytes32 ref,uint160 amount,uint48 expiration)"
        "TokenPermit(address spender,address token,uint160 amount,uint48 expiration)"
        "Validator(address target,bytes data)";

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
        bytes memory head = abi.encode(
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
            o.endAmountOut
        );
        bytes memory tail = abi.encode(
            o.exclusiveFiller,
            o.exclusivityEndTime,
            o.minFillAmountIn,
            _hashItems(o.items),
            _hashValidators(o.validators),
            _hashValidators(o.invariants)
        );
        return keccak256(bytes.concat(head, tail));
    }

    /// @dev Signs the order with the maker's key against Settlement's domain.
    function _sign(LimitOrder memory o) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), _hashOrder(o)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, digest);
        return abi.encodePacked(r, s, v);
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

    /// @dev Signs the witness-bound permit batch against Permit3's domain.
    function _signPermitWitness(IPermit3.PermitBatch memory batch, bytes32 witness)
        internal
        view
        returns (bytes memory)
    {
        bytes32 typeHash = keccak256(bytes(PERMIT_BATCH_WITNESS_FULL));
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
}
