// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Permit3} from "../src/permit3/Permit3.sol";
import {IPermit3} from "../src/interfaces/IPermit3.sol";
import {IMakerModule} from "../src/interfaces/IMakerModule.sol";
import {
    LimitOrderSettlement,
    LimitOrder,
    Item,
    ItemOp
} from "../src/settlement/LimitOrderSettlement.sol";

import {LenderRegistry, Chains, Lenders, Tokens} from "./data/LenderRegistry.sol";

// ──────────────────── Minimal Aave V3 pool surface ────────────────────

interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
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

    function makeOnBehalf(address user, uint256 amount, bytes calldata data) external override {
        (address pool, address asset) = abi.decode(data, (address, address));

        permit3.transferFrom(user, address(this), asset, uint160(amount));
        IERC20(asset).approve(pool, amount);
        IAaveV3Pool(pool).supply(asset, amount, user, 0);
    }
}

// ──────────────────── Test ────────────────────

contract LimitOrderSettlementTest is Test, LenderRegistry {
    Permit3 permit3;
    LimitOrderSettlement settlement;
    AaveV3DepositModule depositModule;

    uint256 makerPk = 0xA11CE;
    address maker = vm.addr(makerPk);
    address solver = address(0xBEEF);

    address WETH;
    address USDC;
    address AAVE_POOL;
    address aWETH;

    function setUp() public {
        // Prefer ETH_RPC_URL (user-supplied, likely a private node);
        // fall back to the registry's default public RPC.
        string memory rpc;
        try vm.envString("ETH_RPC_URL") returns (string memory v) {
            rpc = v;
        } catch {
            rpc = _getChainRpc(Chains.ETHEREUM_MAINNET);
        }
        vm.createSelectFork(rpc);

        WETH = tokens[Chains.ETHEREUM_MAINNET][Tokens.WETH];
        USDC = tokens[Chains.ETHEREUM_MAINNET][Tokens.USDC];
        AAVE_POOL = lendingControllers[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3];
        aWETH = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][WETH].collateral;

        permit3 = new Permit3();
        settlement = new LimitOrderSettlement(address(permit3));
        depositModule = new AaveV3DepositModule(address(permit3));

        vm.label(maker, "maker");
        vm.label(solver, "solver");
        vm.label(address(permit3), "permit3");
        vm.label(address(settlement), "settlement");
        vm.label(address(depositModule), "aaveV3DepositModule");
        vm.label(WETH, "WETH");
        vm.label(USDC, "USDC");
        vm.label(AAVE_POOL, "aaveV3Pool");
        vm.label(aWETH, "aWETH");
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

    function _approveSolverSide(uint256 wethCap) internal {
        vm.startPrank(solver);
        // WETH: Settlement pulls tokenOut from solver
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), WETH, uint160(wethCap), 0);
        vm.stopPrank();
    }

    // EIP-712 hashing — must match LimitOrderSettlement exactly.

    bytes32 constant ITEM_TH = keccak256("Item(uint8 op,address module,uint256 amount,bytes data)");
    bytes32 constant ORDER_TH = keccak256(
        "LimitOrder(address maker,uint256 nonce,uint256 deadline,address tokenIn,address tokenOut,uint256 amountIn,uint32 decayStartTime,uint32 decayDuration,uint256 startAmountOut,uint256 endAmountOut,Item[] items)"
        "Item(uint8 op,address module,uint256 amount,bytes data)"
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
                    keccak256(items[i].data)
                )
            );
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
                _hashItems(o.items)
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
        _approveSolverSide(wethOut);

        // Build order: one MAKE item — deposit the received WETH into Aave v3.
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(depositModule),
            amount: wethOut,
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
            items: items
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
}
