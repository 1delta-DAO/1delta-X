// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, LegOut} from "@core/settlement/Settlement.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";
import {Chains, Tokens} from "@coretest/data/LenderRegistry.sol";

import {SiloPreFundModule} from "../../src/SiloPreFundModules.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";
import {ISilo} from "../../src/interfaces/ISilo.sol";

/// @dev Share-side views the assertions need (the silo IS its own Collateral
///      share token; `maxWithdraw` is solvency-clipped once debt exists, so
///      position size is asserted via `previewRedeem(balanceOf)`).
interface ISiloShares {
    function balanceOf(address owner) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256 assets);
}

/// @dev The ONE-SIDED pre-fund composites on Silo v2 (mainnet wstETH/WETH market):
/// "deposit whatever the conversion delivered" / "repay whatever the conversion
/// delivered", with ZERO receive-side approvals. The converted output leg is
/// delivered straight to the module (`recipient = module`), the core sizes
/// `forAmount` to exactly that delivery, and the maker's only grants are the
/// input-leg approval they had anyway plus a signable taker allowance. The
/// received asset — wstETH on the deposit, the WETH debt underlying on the
/// repay — is never approved to anything, anywhere.
contract SiloPreFundOneSidedTest is CoreSettlementBase {
    SiloPreFundModule preFund;
    // ── Silo v2 wstETH/WETH market, Ethereum mainnet (same pinned deployment
    //    as the Leverage suite). ──
    address internal constant SILO_WSTETH = 0x1a132e4e90D66E2f4FCDc99420F204D46F907aDB;
    address internal constant SILO_WETH = 0x02AE6A64a0DC17ffFDC5722Ad8270a7B32Be44db;

    address WSTETH;

    address liquidityProvider = address(0x11D0);

    uint256 constant WETH_IN = 2 ether;
    uint256 constant WSTETH_OUT = 1.6 ether;

    /// @dev Silo v2 deployed mid-2025, after the default 22M pin — same block as
    ///      the package's Leverage suite.
    function _forkBlock() internal view virtual override returns (uint256) {
        return 25_600_000;
    }

    function setUp() public virtual override {
        super.setUp();

        WSTETH = tokens[Chains.ETHEREUM_MAINNET][Tokens.WSTETH];

        preFund = new SiloPreFundModule(address(permit3), address(settlement));

        vm.label(SILO_WSTETH, "siloWstETH");
        vm.label(SILO_WETH, "siloWETH");
        vm.label(WSTETH, "wstETH");

        // Seed borrowable WETH liquidity — deposit is permissionless, and the
        // market's organic liquidity at the pinned block is too thin to lean on.
        deal(WETH, liquidityProvider, 25 ether);
        vm.startPrank(liquidityProvider);
        IERC20(WETH).approve(SILO_WETH, type(uint256).max);
        ISilo(SILO_WETH).deposit(25 ether, liquidityProvider);
        vm.stopPrank();
    }

    // ──────────────────── Helpers ────────────────────

    /// @dev `(1 << 255) | index` — fund from `legsOut[index]`.
    function _forLeg(uint256 index, address token) internal pure returns (uint256) {
        // bit 255 = leg reference; bit 253 = the PRE-FUND shape, which makes the core
        // require `legsOut[index].recipient == module` (F27/H-1).
        return (uint256(1) << 255) | (uint256(1) << 253) | (uint256(uint160(token)) << 16) | index;
    }

    /// @dev Same leg reference, with the op in descriptor bits [244,252).
    function _forLegOp(uint256 index, address token, SiloPreFundModule.Op op) internal pure returns (uint256) {
        return _forLeg(index, token) | (uint256(op) << 244);
    }

    /// @dev Address one output leg to `to` (the pre-fund shape).
    function _routeLegOut(Order memory o, address token, uint256 start, uint256 end, address to) internal pure {
        LegOut[] memory legsOut = new LegOut[](1);
        legsOut[0] = LegOut(token, start, end, to);
        o.legsOut = PackedEncode.legsOut(legsOut);
    }

    /// @dev Maker's Collateral position in underlying, via the pure share
    ///      conversion (maxWithdraw would be solvency-clipped by open debt).
    function _makerCollateralAssets() internal view returns (uint256) {
        return ISiloShares(SILO_WSTETH).previewRedeem(ISiloShares(SILO_WSTETH).balanceOf(maker));
    }

    // ── SWAP & DEPOSIT. The maker converts WETH (the one asset they hold and
    //    had approved anyway) into a wstETH Silo Collateral position. wstETH —
    //    the asset they RECEIVE — has its ERC20 approval to Permit3 revoked
    //    outright and no Permit3 book entry: the receive side is strictly empty. ──
    function test_preFundDeposit_swapAndDeposit_zeroReceiveSideApprovals() public {
        deal(WETH, maker, WETH_IN);
        _approveMakerToSettlement(WETH, WETH_IN); //  the input leg — the ONE approval
        deal(WSTETH, solver, WSTETH_OUT);
        _approveSolverSide(WSTETH_OUT, WSTETH);

        bytes memory data = abi.encode(_forLeg(0, WSTETH), SILO_WSTETH, WSTETH);
        vm.startPrank(maker);
        IERC20(WSTETH).approve(address(permit3), 0); //  receive side stripped bare
        vm.stopPrank();

        Item[] memory items = new Item[](1);
        // `amount` is the PACING total (the anchor) — this module moves nothing out.
        items[0] = Item(ItemOp.MAKE, address(preFund), 0, address(0), data);
        Order memory o = _order(maker, 401, WETH, WSTETH, WETH_IN, WSTETH_OUT, items);
        _routeLegOut(o, WSTETH, WSTETH_OUT, 0, address(preFund));
        bytes memory sig = _sign(o);

        // The preflight accepts the module-addressed leg.
        (bool ok, string memory why) = lens.validateOrder(o);
        assertTrue(ok, why);

        uint256 makerWst = IERC20(WSTETH).balanceOf(maker);

        vm.prank(solver);
        settlement.fill(o, sig, WETH_IN);

        assertApproxEqAbs(_makerCollateralAssets(), WSTETH_OUT, 2, "the delivered leg became Collateral");
        assertEq(IERC20(WSTETH).balanceOf(maker), makerWst, "the maker's wallet never saw the wstETH");
        assertEq(IERC20(WSTETH).balanceOf(address(preFund)), 0, "module drained");
        assertEq(IERC20(WETH).balanceOf(solver), WETH_IN, "solver received the input leg");
    }

    // ── SWAP & REPAY. The maker converts wstETH into retiring their WETH silo
    //    debt. The debt asset is the canonical never-approved token: the maker's
    //    WETH ERC20 approval to Permit3 is revoked to prove it. Over-delivery
    //    (1.2 delivered vs 1.0 owed) is swept to the maker — the surplus is
    //    theirs. ──
    function test_preFundRepay_capsAtDebt_andSweepsSurplusToMaker() public {
        // Seed the position: 5 wstETH Collateral, 1 WETH debt.
        uint256 debt = 1 ether;
        uint256 wethDelivered = 1.2 ether;
        deal(WSTETH, maker, 5 ether + 1 ether);
        vm.startPrank(maker);
        IERC20(WSTETH).approve(SILO_WSTETH, 5 ether);
        ISilo(SILO_WSTETH).deposit(5 ether, maker);
        ISilo(SILO_WETH).borrow(debt, maker, maker);
        vm.stopPrank();

        _approveMakerToSettlement(WSTETH, 1 ether); //  the input leg — already-held asset
        deal(WETH, solver, wethDelivered);
        _approveSolverSide(wethDelivered, WETH);

        bytes memory data = abi.encode(_forLegOp(0, WETH, SiloPreFundModule.Op.Repay), SILO_WETH, WETH);
        vm.startPrank(maker);
        IERC20(WETH).approve(address(permit3), 0); //  receive side stripped bare
        vm.stopPrank();

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.MAKE, address(preFund), 0, address(0), data);
        Order memory o = _order(maker, 402, WSTETH, WETH, 1 ether, wethDelivered, items);
        _routeLegOut(o, WETH, wethDelivered, 0, address(preFund));
        bytes memory sig = _sign(o);

        uint256 makerWeth = IERC20(WETH).balanceOf(maker);

        vm.prank(solver);
        settlement.fill(o, sig, 1 ether);

        assertEq(ISilo(SILO_WETH).maxRepay(maker), 0, "the debt is retired in full");
        assertApproxEqAbs(
            IERC20(WETH).balanceOf(maker), makerWeth + (wethDelivered - debt), 2, "the surplus was swept to the maker"
        );
        assertEq(IERC20(WETH).balanceOf(address(preFund)), 0, "module drained");
        assertEq(IERC20(WSTETH).balanceOf(solver), 1 ether, "solver received the input leg");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement drained");
    }

    // ── The auctioned version, in partial fills: a decaying wstETH leg filled
    //    mid-decay deposits exactly the clearing amount — the combination no
    //    ratio-in-data or wallet-routed MAKE can express. ──
    function test_preFundDeposit_decayedLeg_partialFills_depositExactlyTheClearing() public {
        deal(WETH, maker, WETH_IN);
        _approveMakerToSettlement(WETH, WETH_IN);
        deal(WSTETH, solver, WSTETH_OUT * 2);
        _approveSolverSide(WSTETH_OUT * 2, WSTETH);
        uint256 solverBefore = IERC20(WSTETH).balanceOf(solver);

        bytes memory data = abi.encode(_forLeg(0, WSTETH), SILO_WSTETH, WSTETH);
        vm.startPrank(maker);
        IERC20(WSTETH).approve(address(permit3), 0);
        vm.stopPrank();

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.MAKE, address(preFund), 0, address(0), data);
        Order memory o = _order(maker, 403, WETH, WSTETH, WETH_IN, WSTETH_OUT, items);
        _routeLegOut(o, WSTETH, WSTETH_OUT, 1.4 ether, address(preFund)); //  1.6 → 1.4
        o.timing = _packTiming(uint32(block.timestamp), 1000, 0) | _expiryBits(block.timestamp + 1 hours);
        bytes memory sig = _sign(o);

        vm.warp(block.timestamp + 500); //  halfway ⇒ the leg clears at 1.5
        vm.prank(solver);
        settlement.fill(o, sig, WETH_IN / 3);
        vm.prank(solver);
        settlement.fill(o, sig, WETH_IN - WETH_IN / 3);

        uint256 delivered = solverBefore - IERC20(WSTETH).balanceOf(solver);
        assertApproxEqAbs(delivered, 1.5 ether, 2, "the auction cleared mid-decay");
        assertApproxEqAbs(_makerCollateralAssets(), delivered, 2, "every delivered wei was deposited");
        assertEq(IERC20(WSTETH).balanceOf(address(preFund)), 0, "module drained across slices");
    }
}
