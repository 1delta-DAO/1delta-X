// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {DustHandler} from "@core/dust/DustHandler.sol";

import {ICEther} from "../../src/interfaces/ICompoundV2.sol";
import {CompoundV2NativeRepayModule, CompoundV2NativeWithdrawModule} from "../../src/CompoundV2NativeModules.sol";
import {CompoundV2ModulesBase} from "../shared/CompoundV2ModulesBase.t.sol";

/// @dev Native cEther flows driven END-TO-END THROUGH THE SETTLEMENT (not the
/// modules in isolation — that's `CompoundV2Native.t.sol`). These prove the design
/// claim from the native-handling discussion: when a collateral is redeemed to
/// native ETH (or a native debt is repaid), the native lives ONLY inside the module
/// for the redeem→wrap (or unwrap→repay) window — the Settlement and Permit3 stay
/// ERC20 end to end.
///
/// The boundary is asserted as a DELTA around the fill (`_assertNoNativeGain`): the
/// Settlement/Permit3/module native balance must be UNCHANGED by the fill. An
/// absolute `== 0` is wrong here — the deterministic forge deploy addresses carry
/// pre-existing mainnet-fork dust (the Settlement's `0x2e234…` holds 1 wei, Permit3
/// ~0.000577 ETH), so only the delta isolates what the flow itself moves.
///
///   cETH collateral + USDC debt, driven by `settlement.fill`:
///     • sell a slice of native collateral for USDC          (isolated native redeem)
///     • full close: repay USDC debt, redeem ALL collateral  (repay → withdraw-Full)
///     • repay a native ETH debt funded by the solver        (native as the "sink")
contract CompoundV2NativeSettlementTest is CompoundV2ModulesBase {
    ICEther constant CETH = ICEther(0x4Ddc2D193948926D02f9B1fE9e1daa0718270ED5);

    CompoundV2NativeRepayModule nRepay;
    CompoundV2NativeWithdrawModule nWithdraw;

    function setUp() public override {
        super.setUp();
        nRepay = new CompoundV2NativeRepayModule(address(permit3), address(settlement), WETH);
        nWithdraw = new CompoundV2NativeWithdrawModule(address(permit3), WETH);
        vm.label(address(nRepay), "compoundV2NativeRepayModule");
        vm.label(address(nWithdraw), "compoundV2NativeWithdrawModule");
        vm.label(address(CETH), "cETH");

        // Enter the cETH market so supplied cETH counts as collateral (the close test
        // borrows USDC against it). Harmless for the other tests.
        vm.prank(maker);
        address[] memory m = new address[](1);
        m[0] = address(CETH);
        COMPTROLLER.enterMarkets(m);
    }

    // ──────────────────── data blobs ────────────────────

    function _withdrawEthData() internal pure returns (bytes memory) {
        return abi.encode(address(CETH)); // Exact mode (no trailing BalanceMode)
    }

    /// @param itemTotal the item's full maker-signed amount. `Full` mode is
    ///        full-fill only — it liquidates the entire live balance, so it cannot
    ///        be pro-rated (see {FullFillGuard}).
    function _withdrawEthFullData(uint256 itemTotal) internal pure returns (bytes memory) {
        return abi.encode(address(CETH), uint8(DustHandler.BalanceMode.Full), itemTotal);
    }

    function _repayUsdcData() internal view returns (bytes memory) {
        return abi.encode(address(CUSDC), USDC);
    }

    // ──────────────────── seeding ────────────────────

    /// @dev Maker supplies `ethAmt` ETH into cETH as collateral (self-mint).
    function _seedEthCollateral(uint256 ethAmt) internal {
        vm.deal(maker, ethAmt);
        vm.prank(maker);
        CETH.mint{value: ethAmt}();
    }

    /// @dev Maker supplies `ethAmt` ETH collateral and borrows `usdcDebt` USDC
    ///      directly (self-borrow — no on-behalf borrow exists), dumping the
    ///      proceeds so the wallet starts clean.
    function _openUsdcDebtOnEth(uint256 ethAmt, uint256 usdcDebt) internal {
        _seedEthCollateral(ethAmt);
        vm.startPrank(maker);
        (bool ok, bytes memory ret) = address(CUSDC).call(abi.encodeWithSignature("borrow(uint256)", usdcDebt));
        require(ok && (ret.length < 32 || abi.decode(ret, (uint256)) == 0), "seed usdc borrow");
        IERC20(USDC).transfer(address(0xdead), usdcDebt); // dump borrowed USDC
        vm.stopPrank();
    }

    // ──────────────────── boundary assertion ────────────────────

    /// @dev The core claim: the fill adds NO native to the shared ERC20-only
    ///      infra. Deltas, not absolutes — the deploy addresses carry fork dust.
    function _assertNoNativeGain(uint256 settlementEthBefore, uint256 permit3EthBefore) internal view {
        assertEq(address(settlement).balance, settlementEthBefore, "settlement gained no native ETH");
        assertEq(address(permit3).balance, permit3EthBefore, "permit3 gained no native ETH");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  1) Isolated native redeem: sell a slice of cETH collateral for USDC.
    //     TAKE (redeem cETH → WETH → solver) ; solver delivers USDC → maker.
    // ═══════════════════════════════════════════════════════════════════════
    function test_settle_sellNativeCollateral_forUsdc() public {
        _seedEthCollateral(3 ether);
        uint256 cEthBefore = IERC20(address(CETH)).balanceOf(maker);
        assertGt(cEthBefore, 0, "maker has cETH");

        uint256 wethIn = 1 ether; //   collateral slice redeemed (the maker's tokenIn)
        uint256 usdcOut = 1_500e6; //  solver delivers this to the maker (signed price)

        deal(USDC, solver, usdcOut); // solver funds tokenOut (standing allowance from base)

        // Maker authorizes the native redeem: pull cETH (token allowance) + cap the
        // forwarded slice (taker allowance, ref = keccak256(data)).
        vm.startPrank(maker);
        IERC20(address(CETH)).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(nWithdraw), address(CETH), type(uint160).max, 0);
        permit3.approveTaker(address(settlement), keccak256(_withdrawEthData()), uint160(wethIn), 0);
        vm.stopPrank();

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE, address(nWithdraw), wethIn, address(0), _withdrawEthData());
        Order memory order = _order(maker, 1, WETH, USDC, wethIn, usdcOut, items);
        bytes memory sig = _sign(order);

        uint256 solverWethBefore = IERC20(WETH).balanceOf(solver);
        uint256 sEthBefore = address(settlement).balance;
        uint256 pEthBefore = address(permit3).balance;
        uint256 modEthBefore = address(nWithdraw).balance;

        vm.prank(solver);
        uint256 delivered = settlement.fill(order, sig, wethIn)[0];
        assertEq(delivered, usdcOut, "maker's USDC output delivered");

        // Maker: got USDC, keeps a reduced cETH position, NEVER touched raw ETH.
        assertEq(IERC20(USDC).balanceOf(maker), usdcOut, "maker received USDC");
        assertLt(IERC20(address(CETH)).balanceOf(maker), cEthBefore, "cETH partially redeemed");
        assertGt(IERC20(address(CETH)).balanceOf(maker), 0, "residual cETH kept");
        assertEq(maker.balance, 0, "maker got no raw ETH");

        // Solver: paid the collateral slice as WETH (native never seen), USDC spent.
        assertEq(IERC20(WETH).balanceOf(solver) - solverWethBefore, wethIn, "solver got WETH for the slice");
        assertEq(IERC20(USDC).balanceOf(solver), 0, "solver USDC spent");

        // Boundary: native re-entered as WETH at the module; nothing native stuck.
        _assertNoNativeGain(sEthBefore, pEthBefore);
        assertEq(address(nWithdraw).balance, modEthBefore, "withdraw module retained no native");
        assertEq(IERC20(WETH).balanceOf(address(nWithdraw)), 0, "withdraw module WETH drained");
        assertEq(IERC20(address(CETH)).balanceOf(address(nWithdraw)), 0, "withdraw module cETH drained");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  2) Full close: cETH collateral + USDC debt.
    //     [0] MAKE repay USDC debt   (frees the collateral — must run first)
    //     [1] TAKE redeem ALL cETH   (Full: forward the slice to the solver,
    //                                 sweep the leftover collateral to the maker)
    //     The withdrawn collateral is native; it re-enters as WETH at the module.
    // ═══════════════════════════════════════════════════════════════════════
    function test_close_repayUsdcDebt_redeemAllNativeCollateral() public {
        uint256 ethColl = 5 ether;
        uint256 usdcDebt = 2_000e6;
        _openUsdcDebtOnEth(ethColl, usdcDebt);
        assertGt(CUSDC.borrowBalanceStored(maker), 0, "pre: maker has USDC debt");

        uint256 wethToSolver = 1.1 ether; //  collateral slice paid to the solver (signed price)
        uint256 usdcRepay = 2_010e6; //       solver delivers; buffers the debt + accrual

        deal(USDC, solver, usdcRepay); //     solver funds the repay leg

        vm.startPrank(maker);
        // Repay leg: Settlement delivers USDC to the maker, the repay module pulls it.
        permit3.approveToken(address(repayModule), USDC, uint160(usdcRepay), 0);
        // Redeem leg: pull the maker's cETH + cap the forwarded slice.
        IERC20(address(CETH)).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(nWithdraw), address(CETH), type(uint160).max, 0);
        permit3.approveTaker(
            address(settlement), keccak256(_withdrawEthFullData(wethToSolver)), uint160(wethToSolver), 0
        );
        vm.stopPrank();

        // Order-of-items matters: repay (MAKE) BEFORE redeem-Full (TAKE), else the
        // debt still locks the collateral and the full redeem reverts on shortfall.
        Item[] memory items = new Item[](2);
        items[0] = Item(ItemOp.MAKE, address(repayModule), usdcRepay, address(0), _repayUsdcData());
        items[1] = Item(ItemOp.TAKE, address(nWithdraw), wethToSolver, address(0), _withdrawEthFullData(wethToSolver));
        Order memory order = _order(maker, 1, WETH, USDC, wethToSolver, usdcRepay, items);
        bytes memory sig = _sign(order);

        uint256 makerWethBefore = IERC20(WETH).balanceOf(maker);
        uint256 sEthBefore = address(settlement).balance;
        uint256 pEthBefore = address(permit3).balance;
        uint256 modEthBefore = address(nWithdraw).balance;

        vm.prank(solver);
        settlement.fill(order, sig, wethToSolver);

        // Position closed: debt cleared, collateral fully redeemed.
        assertApproxEqAbs(CUSDC.borrowBalanceStored(maker), 0, 1, "USDC debt closed");
        assertEq(IERC20(address(CETH)).balanceOf(maker), 0, "cETH fully redeemed");

        // The leftover collateral was swept back to the maker AS WETH (never raw ETH).
        assertGt(IERC20(WETH).balanceOf(maker) - makerWethBefore, 3 ether, "leftover collateral to maker as WETH");
        assertEq(maker.balance, 0, "maker got no raw ETH");

        // Solver: paid the slice as WETH, spent the repay USDC.
        assertEq(IERC20(WETH).balanceOf(solver), wethToSolver, "solver got the WETH slice");
        assertEq(IERC20(USDC).balanceOf(solver), 0, "solver USDC spent");

        _assertNoNativeGain(sEthBefore, pEthBefore);
        assertEq(address(nWithdraw).balance, modEthBefore, "withdraw module retained no native");
        assertEq(IERC20(WETH).balanceOf(address(nWithdraw)), 0, "withdraw module WETH drained");
        assertEq(IERC20(address(CETH)).balanceOf(address(nWithdraw)), 0, "withdraw module cETH drained");
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), 0, "repay module USDC drained");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  3) Native debt as the SINK: repay a cETH (native ETH) borrow through the
    //     settlement. Solver delivers WETH → maker; the native repay module pulls
    //     it, unwraps, and `repayBorrowBehalf{value}`. Native lives only inside the
    //     module (the "repay native == unstake, run in reverse" case).
    // ═══════════════════════════════════════════════════════════════════════
    function test_settle_repayNativeEthDebt_fundedBySolver() public {
        // Seed: USDC collateral, then borrow 1 ETH (auto-enters the cETH market),
        // dump the borrowed ETH so the wallet starts clean.
        _seedUsdcCollateral(4_000e6);
        vm.startPrank(maker);
        require(CETH.borrow(1 ether) == 0, "seed eth borrow");
        (bool dumped,) = address(0xdead).call{value: 1 ether}("");
        require(dumped, "dump");
        vm.stopPrank();

        uint256 debt = CETH.borrowBalanceCurrent(maker);
        assertGt(debt, 0, "pre: maker has an ETH debt");
        uint256 wethRepay = debt + 0.05 ether; //  solver delivers; buffers accrual
        uint256 usdcToSolver = 2_000e6; //          maker pays the solver (signed price)

        deal(USDC, maker, usdcToSolver); //         maker's tokenIn leg
        deal(WETH, solver, wethRepay); //           solver funds the repay

        vm.startPrank(maker);
        // tokenIn (USDC) → solver: Settlement pulls it from the maker.
        permit3.approveToken(address(settlement), USDC, uint160(usdcToSolver), 0);
        // Repay leg: Settlement delivers WETH to the maker, the native repay pulls it.
        permit3.approveToken(address(nRepay), WETH, uint160(wethRepay), 0);
        vm.stopPrank();
        _approveSolverSide(wethRepay, WETH);

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.MAKE, address(nRepay), wethRepay, address(0), abi.encode(address(CETH)));
        Order memory order = _order(maker, 1, USDC, WETH, usdcToSolver, wethRepay, items);
        bytes memory sig = _sign(order);

        uint256 sEthBefore = address(settlement).balance;
        uint256 pEthBefore = address(permit3).balance;
        uint256 modEthBefore = address(nRepay).balance;

        vm.prank(solver);
        settlement.fill(order, sig, usdcToSolver);

        // Native ETH debt cleared (repaid via unwrap INSIDE the module).
        assertApproxEqAbs(CETH.borrowBalanceStored(maker), 0, 1, "ETH debt closed");
        // Pull-exact: only the live debt was pulled; the buffer stays with the maker.
        assertApproxEqAbs(IERC20(WETH).balanceOf(maker), wethRepay - debt, 1e12, "repay buffer kept by maker");
        // Solver received the maker's USDC.
        assertEq(IERC20(USDC).balanceOf(solver), usdcToSolver, "solver got USDC");

        _assertNoNativeGain(sEthBefore, pEthBefore);
        assertEq(address(nRepay).balance, modEthBefore, "repay module retained no native");
        assertEq(IERC20(WETH).balanceOf(address(nRepay)), 0, "repay module WETH drained");
    }
}
