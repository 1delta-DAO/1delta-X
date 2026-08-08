// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";
import {Chains, Tokens} from "@coretest/data/LenderRegistry.sol";

import {SiloDepositModule, SiloTakerModule} from "../../src/SiloModules.sol";
import {ISilo, ISiloShareToken} from "../../src/interfaces/ISilo.sol";

/// @dev ERC-4626 share-side views the assertions need beyond the module's
///      minimal ISilo (the silo IS its own Collateral share token; `maxWithdraw`
///      is solvency-bounded once debt exists, so position size is asserted via
///      `previewRedeem(balanceOf)` instead).
interface ISiloShares {
    function balanceOf(address owner) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
}

/// @dev Leverage open on Silo v2 (Ethereum mainnet wstETH/WETH market): the
///      maker signs ONE order whose items deposit wstETH Collateral (MAKE) and
///      borrow WETH against it (TAKE). A solver funded with nothing but the
///      collateral token fills it and walks away with the borrow proceeds.
///
///        tokenIn  = WETH   (maker gives — sourced entirely from the borrow item)
///        tokenOut = wstETH (solver gives → forwarded into the deposit item)
///
///      Items:
///        [0] MAKE  SiloDepositModule  wstETH silo `deposit` (standard Collateral —
///                                     protected deposits are out of scope)
///        [1] TAKE  SiloTakerModule    WETH silo `borrow` — op 0
///
///      Auth (per README): deposit is permissionless value-in (Permit3 token
///      allowance only); borrow needs the maker's receive-approval on the WETH
///      debt share token + the Permit3 taker allowance keyed by the signed data.
contract SiloLeverageTest is CoreSettlementBase {
    // ── Silo v2 wstETH/WETH market, Ethereum mainnet (silo-contracts-v2
    //    `_siloDeployments.json` → Silo_wstETH_WETH; internals read from the
    //    SiloConfig on-chain at the pinned block). ──
    address internal constant SILO_CONFIG = 0xE7A7ca8BC2D2ccD5c6F536f4956Af568e5215F70;
    /// @dev silo0 — the wstETH ERC-4626 vault (collateral side). The silo is its
    ///      own Collateral share token.
    address internal constant SILO_WSTETH = 0x1a132e4e90D66E2f4FCDc99420F204D46F907aDB;
    /// @dev silo1 — the WETH ERC-4626 vault (debt side).
    address internal constant SILO_WETH = 0x02AE6A64a0DC17ffFDC5722Ad8270a7B32Be44db;
    /// @dev silo1's ShareDebtToken — carries the `setReceiveApproval` grant.
    address internal constant WETH_DEBT_SHARE = 0xDa76d43195010681BA0C846C94cdcc73376DCFB8;

    address WSTETH;

    SiloDepositModule depositModule;
    SiloTakerModule takerModule;

    address liquidityProvider = address(0x11D0);

    /// @dev Silo v2 deployed on mainnet mid-2025, after the default 22M pin.
    ///      Same block as the modules-liquity-v2 leverage suite.
    function _forkBlock() internal view virtual override returns (uint256) {
        return 25_600_000;
    }

    function setUp() public virtual override {
        super.setUp();

        WSTETH = tokens[Chains.ETHEREUM_MAINNET][Tokens.WSTETH];

        depositModule = new SiloDepositModule(address(permit3), address(settlement));
        takerModule = new SiloTakerModule(address(permit3));

        vm.label(address(depositModule), "siloDepositModule");
        vm.label(address(takerModule), "siloTakerModule");
        vm.label(SILO_WSTETH, "siloWstETH");
        vm.label(SILO_WETH, "siloWETH");
        vm.label(WETH_DEBT_SHARE, "wethDebtShare");
        vm.label(WSTETH, "wstETH");

        // Seed borrowable WETH liquidity — deposit is permissionless, and the
        // market's organic liquidity at the pinned block is too thin to lean on.
        deal(WETH, liquidityProvider, 25 ether);
        vm.startPrank(liquidityProvider);
        IERC20(WETH).approve(SILO_WETH, type(uint256).max);
        ISilo(SILO_WETH).deposit(25 ether, liquidityProvider);
        vm.stopPrank();

        // Maker bare-approves wstETH to Permit3 (the deposit module pulls it).
        vm.prank(maker);
        IERC20(WSTETH).approve(address(permit3), type(uint256).max);
    }

    // ──────────────────── Helpers ────────────────────

    function _borrowData() internal view returns (bytes memory) {
        return abi.encode(uint8(0), SILO_WETH, WETH);
    }

    function _depositData() internal view returns (bytes memory) {
        return abi.encode(SILO_WSTETH, WSTETH);
    }

    function _buildLeverageOrder(uint256 collateralIn, uint256 borrowOut) internal view returns (Order memory) {
        Item[] memory items = new Item[](2);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(depositModule),
            amount: collateralIn,
            recipient: address(0),
            data: _depositData()
        });
        items[1] = Item({
            op: ItemOp.TAKE, module: address(takerModule), amount: borrowOut, recipient: address(0), data: _borrowData()
        });
        return _order(maker, 1, WETH, WSTETH, borrowOut, collateralIn, items);
    }

    function _approveMakerLeverageSide(uint256 collateralIn, uint256 borrowOut) internal {
        vm.startPrank(maker);
        // wstETH: the deposit module pulls the collateral via Permit3 during MAKE.
        permit3.approveToken(address(depositModule), WSTETH, uint160(collateralIn), 0);
        // Silo-native borrow grant: the maker lets the taker module put up to
        // `borrowOut` of WETH debt on them (debt-share receive allowance — the
        // credit-delegation analogue). The Permit3 taker gate caps the fill.
        ISiloShareToken(WETH_DEBT_SHARE).setReceiveApproval(address(takerModule), borrowOut);
        // Permit3 taker gate on the exact borrow position + amount.
        permit3.approveTaker(address(settlement), keccak256(_borrowData()), uint160(borrowOut), 0);
        // WETH fallback allowance for the tokenIn shortfall path — never triggers
        // here (the borrow fully funds tokenIn) but keeps the flow safe.
        permit3.approveToken(address(settlement), WETH, uint160(borrowOut), 0);
        vm.stopPrank();
    }

    /// @dev Maker's Collateral position in underlying, via the pure share
    ///      conversion (maxWithdraw would be solvency-clipped by the open debt).
    function _makerCollateralAssets() internal view returns (uint256) {
        return ISiloShares(SILO_WSTETH).previewRedeem(ISiloShares(SILO_WSTETH).balanceOf(maker));
    }

    // ──────────────────── Full leverage open ────────────────────

    function test_leverage_deposit_borrow_silo() public {
        uint256 collateralIn = 5 ether; //   solver funds → maker's silo position
        uint256 borrowOut = 2 ether; //      maker borrows → solver receives

        deal(WSTETH, solver, collateralIn);
        _approveMakerLeverageSide(collateralIn, borrowOut);
        _approveSolverSide(collateralIn, WSTETH);

        Order memory order = _buildLeverageOrder(collateralIn, borrowOut);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, borrowOut)[0];

        assertEq(paid, collateralIn, "solver paid exactly the collateral leg");

        // Maker: fresh Collateral position + WETH debt, all inside the silo.
        assertApproxEqAbs(_makerCollateralAssets(), collateralIn, 2, "maker collateral position up");
        assertApproxEqAbs(ISilo(SILO_WETH).maxRepay(maker), borrowOut, 2, "maker WETH debt up");

        // Solver: spent wstETH, received the borrow proceeds.
        assertEq(IERC20(WSTETH).balanceOf(solver), 0, "solver wstETH spent");
        assertEq(IERC20(WETH).balanceOf(solver), borrowOut, "solver received WETH");

        // Maker wallet untouched — both legs settled inside the position.
        assertEq(IERC20(WSTETH).balanceOf(maker), 0, "maker wstETH forwarded into deposit");
        assertEq(IERC20(WETH).balanceOf(maker), 0, "maker WETH forwarded out via borrow");

        // Settlement & modules end empty.
        assertEq(IERC20(WSTETH).balanceOf(address(settlement)), 0, "settlement wstETH drained");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(WSTETH).balanceOf(address(depositModule)), 0, "deposit module wstETH drained");
        assertEq(IERC20(WETH).balanceOf(address(takerModule)), 0, "taker module WETH drained");
    }

    // ──────────────────── Partial fill (pro-rata) ────────────────────

    function test_leverage_partialFill_silo() public {
        uint256 collateralIn = 5 ether;
        uint256 borrowOut = 2 ether;

        deal(WSTETH, solver, collateralIn);
        _approveMakerLeverageSide(collateralIn, borrowOut);
        _approveSolverSide(collateralIn, WSTETH);

        Order memory order = _buildLeverageOrder(collateralIn, borrowOut);
        bytes memory sig = _sign(order);

        // Fill HALF the order — items scale pro-rata: half the collateral in,
        // half the borrow out.
        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, borrowOut / 2)[0];

        assertEq(paid, collateralIn / 2, "solver paid half the collateral");

        assertApproxEqAbs(_makerCollateralAssets(), collateralIn / 2, 2, "maker collateral = half");
        assertApproxEqAbs(ISilo(SILO_WETH).maxRepay(maker), borrowOut / 2, 2, "maker debt = half");

        assertEq(IERC20(WSTETH).balanceOf(solver), collateralIn / 2, "solver kept the unfilled half");
        assertEq(IERC20(WETH).balanceOf(solver), borrowOut / 2, "solver received half the borrow");

        assertEq(IERC20(WSTETH).balanceOf(address(settlement)), 0, "settlement wstETH drained");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
    }
}
