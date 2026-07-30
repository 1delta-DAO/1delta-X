// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";

import {Chains, Tokens} from "@coretest/data/LenderRegistry.sol";

import {IFluidVault} from "../../src/interfaces/IFluid.sol";
import {FluidTakerModule} from "../../src/FluidModules.sol";
import {FluidModulesBase} from "../shared/FluidModulesBase.t.sol";

/// @dev Leverage fork tests for the Fluid modules — deposit X collateral + borrow Y
/// in ONE order, on the mainnet wstETH-USDC T1 vault (vault id 14). The shared
/// harness's ETH-USDC vault has NATIVE collateral, which the ERC20-only deposit
/// maker module cannot fund — so this suite pins the wstETH market instead
/// (native supply is explicitly out of scope for the module set).
///
/// The maker deposits wstETH into an EXISTING position (a fresh open is the
/// composite `FluidOperateModule` Open path, full-fill only) and borrows USDC
/// against it. The solver funds the wstETH from inventory — the simplest fill that
/// proves the module round-trip — and receives the borrow proceeds:
///
///   tokenIn  = USDC     (maker gives — sourced from the borrow item)
///   tokenOut = wstETH   (solver gives → delivered to maker, pulled into the deposit)
///
/// Items:
///   [0] MAKE  FluidDepositModule            supply wstETH (permissionless value-in)
///   [1] TAKE  FluidTakerModule (op=Borrow)  borrow USDC   (JIT NFT custody)
///
/// Auth surface exercised:
///   • Permit3 token allowance  maker → depositModule (wstETH pull during MAKE)
///   • one-time `factory.setApprovalForAll(takerModule)` (granted in the base
///     harness) — Fluid's strict-ownerOf check forces the module to pull the
///     position NFT in just-in-time and hand it straight back
///   • Permit3 taker allowance  (settlement, keccak256(borrowData)) caps the TAKE
///
/// Fluid stores positions in tick-quantised form (no per-user share token), so
/// position deltas are asserted OPERATIONALLY: after the fill the maker closes the
/// position with the repay-all / withdraw-all sentinels and the `operate` return
/// values reveal the exact live collateral + debt (±Fluid's BigMath rounding).
contract FluidLeverageTest is FluidModulesBase {
    /// @dev Fluid wstETH-USDC vault (T1, vault id 14) on Ethereum mainnet. NOT the
    ///      original vault id 4 — that legacy market's USDC borrow limit at the
    ///      Liquidity layer is exhausted at the pinned block (any borrow reverts
    ///      with Fluid error 11004, `UserModule__BorrowLimitReached`); vault 14 has
    ///      ~2.9M USDC of borrow headroom (checked via the LiquidityResolver).
    address constant WSTETH_USDC_VAULT = 0x1982CC7b1570C2503282d0A0B41F69b3B28fdcc3;

    address WSTETH;

    function setUp() public override {
        super.setUp();

        WSTETH = tokens[Chains.ETHEREUM_MAINNET][Tokens.WSTETH];

        vm.label(WSTETH_USDC_VAULT, "FluidWstethUsdcVault");
        vm.label(WSTETH, "wstETH");

        // wstETH is not pre-approved in CoreSettlementBase — bare ERC20 approve to
        // Permit3 so the deposit module can pull it from the maker during MAKE.
        vm.prank(maker);
        IERC20(WSTETH).approve(address(permit3), type(uint256).max);
    }

    // ──────────────────── Helpers ────────────────────

    function _borrowData(uint256 nftId) internal pure returns (bytes memory) {
        return abi.encode(uint8(FluidTakerModule.Op.Borrow), WSTETH_USDC_VAULT, VAULT_FACTORY, nftId);
    }

    /// @dev Open a wstETH-collateral / zero-debt position owned by the maker
    ///      directly against the vault (funding pulled from the operate caller
    ///      via the vault's liquidityCallback ⇒ approve the VAULT).
    function _seedWstethPosition(uint256 col0) internal returns (uint256 nftId) {
        deal(WSTETH, maker, col0);
        vm.startPrank(maker);
        IERC20(WSTETH).approve(WSTETH_USDC_VAULT, col0);
        (nftId,,) = IFluidVault(WSTETH_USDC_VAULT).operate(0, int256(col0), 0, address(0));
        vm.stopPrank();
        require(nftId != 0, "seed position failed");
    }

    function _approveMakerLeverageSide(uint256 nftId, uint256 colAdd, uint256 debtAdd) internal {
        vm.startPrank(maker);
        // wstETH: deposit module pulls the collateral via Permit3 during MAKE.
        permit3.approveToken(address(depositModule), WSTETH, uint160(colAdd), 0);
        // Permit3 taker gate on the exact (op, vault, factory, nftId) borrow ref.
        permit3.approveTaker(address(settlement), keccak256(_borrowData(nftId)), uint160(debtAdd), 0);
        // USDC fallback allowance for the tokenIn shortfall path — never triggers
        // here since the borrow fully funds tokenIn, but keeps it safe.
        permit3.approveToken(address(settlement), USDC, uint160(debtAdd), 0);
        vm.stopPrank();
        // (factory.setApprovalForAll(takerModule) already granted in the base harness.)
    }

    function _buildLeverageOrder(uint256 nonce, uint256 nftId, uint256 colAdd, uint256 debtAdd)
        internal
        view
        returns (Order memory order)
    {
        Item[] memory items = new Item[](2);
        items[0] = Item(
            ItemOp.MAKE, address(depositModule), colAdd, address(0), abi.encode(WSTETH_USDC_VAULT, WSTETH, nftId)
        );
        items[1] = Item(ItemOp.TAKE, address(takerModule), debtAdd, address(0), _borrowData(nftId));
        order = _order(maker, nonce, USDC, WSTETH, debtAdd, colAdd, items);
    }

    /// @dev Fully close the position (repay-all + withdraw-all sentinels) as the
    ///      maker and return the live (collateral, debt) the vault reported —
    ///      the operational read-out of the position after the leverage fill.
    function _closeAndMeasure(uint256 nftId, uint256 usdcBudget) internal returns (uint256 col, uint256 debt) {
        deal(USDC, maker, usdcBudget);
        vm.startPrank(maker);
        IERC20(USDC).approve(WSTETH_USDC_VAULT, usdcBudget);
        (, int256 colOut, int256 debtOut) =
            IFluidVault(WSTETH_USDC_VAULT).operate(nftId, type(int256).min, type(int256).min, maker);
        vm.stopPrank();
        col = uint256(-colOut);
        debt = uint256(-debtOut);
    }

    // ──────────────────── Full leverage open ────────────────────

    function test_leverageOpen_deposit_borrow_fluid() public {
        uint256 col0 = 1 ether; //     seed collateral (existing position)
        uint256 colAdd = 1 ether; //   maker receives + deposits via the fill
        uint256 debtAdd = 1_000e6; //  maker borrows → solver receives

        uint256 nftId = _seedWstethPosition(col0);

        deal(WSTETH, solver, colAdd);
        _approveMakerLeverageSide(nftId, colAdd, debtAdd);
        _approveSolverSide(colAdd, WSTETH);

        Order memory order = _buildLeverageOrder(1, nftId, colAdd, debtAdd);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, debtAdd)[0];

        assertEq(paid, colAdd, "solver paid 1 wstETH of collateral");

        // Solver: spent wstETH inventory, received the borrow proceeds.
        assertEq(IERC20(WSTETH).balanceOf(solver), 0, "solver wstETH spent");
        assertEq(IERC20(USDC).balanceOf(solver), debtAdd, "solver received USDC");

        // JIT custody round-trip left the NFT with the maker; wallets stayed clean.
        assertEq(_ownerOf(nftId), maker, "position NFT returned to maker");
        assertEq(IERC20(WSTETH).balanceOf(maker), 0, "maker wstETH forwarded into deposit");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "maker USDC forwarded out via borrow");

        // Settlement & modules end empty.
        assertEq(IERC20(WSTETH).balanceOf(address(settlement)), 0, "settlement wstETH drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(WSTETH).balanceOf(address(depositModule)), 0, "deposit module wstETH drained");
        assertEq(IERC20(USDC).balanceOf(address(takerModule)), 0, "taker module USDC drained");

        // Position deltas via full close: collateral = seed + deposit, debt = borrow
        // (±0.1% for Fluid's BigMath tick rounding).
        (uint256 col, uint256 debt) = _closeAndMeasure(nftId, (debtAdd * 101) / 100);
        assertApproxEqRel(col, col0 + colAdd, 1e15, "position collateral = seed + deposited");
        assertApproxEqRel(debt, debtAdd, 1e15, "position debt = borrowed");
    }

    // ──────────────────── Partial fill (pro-rata items) ────────────────────

    /// @dev Both single-op items pro-rate (no FullFillGuard on deposit/borrow):
    ///      half a fill deposits half the collateral and borrows half the debt;
    ///      a second half-fill completes the totals.
    function test_partialFill_leverageOpen_fluid() public {
        uint256 col0 = 1 ether;
        uint256 colAdd = 1 ether;
        uint256 debtAdd = 1_000e6;
        uint256 half = debtAdd / 2;

        uint256 nftId = _seedWstethPosition(col0);

        deal(WSTETH, solver, colAdd);
        _approveMakerLeverageSide(nftId, colAdd, debtAdd);
        _approveSolverSide(colAdd, WSTETH);

        Order memory order = _buildLeverageOrder(2, nftId, colAdd, debtAdd);
        bytes memory sig = _sign(order);

        // ── First half ──
        vm.prank(solver);
        uint256 paid1 = settlement.fill(order, sig, half)[0];

        assertEq(paid1, colAdd / 2, "first fill: half the collateral");
        assertEq(IERC20(USDC).balanceOf(solver), half, "solver received half the borrow");
        assertEq(IERC20(WSTETH).balanceOf(solver), colAdd / 2, "solver kept half its inventory");
        assertEq(_ownerOf(nftId), maker, "NFT back with maker between fills");

        // ── Second half completes the order ──
        vm.prank(solver);
        uint256 paid2 = settlement.fill(order, sig, half)[0];

        assertEq(paid1 + paid2, colAdd, "fills sum to the full collateral");
        assertEq(IERC20(USDC).balanceOf(solver), debtAdd, "solver received the full borrow");
        assertEq(IERC20(WSTETH).balanceOf(solver), 0, "solver inventory fully spent");
        assertEq(_ownerOf(nftId), maker, "position NFT returned to maker");

        // Settlement & modules end empty.
        assertEq(IERC20(WSTETH).balanceOf(address(settlement)), 0, "settlement wstETH drained");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement USDC drained");
        assertEq(IERC20(WSTETH).balanceOf(address(depositModule)), 0, "deposit module wstETH drained");
        assertEq(IERC20(USDC).balanceOf(address(takerModule)), 0, "taker module USDC drained");

        // Position deltas via full close — totals match the two half-slices summed.
        (uint256 col, uint256 debt) = _closeAndMeasure(nftId, (debtAdd * 101) / 100);
        assertApproxEqRel(col, col0 + colAdd, 1e15, "position collateral = seed + deposited");
        assertApproxEqRel(debt, debtAdd, 1e15, "position debt = borrowed");
    }
}
