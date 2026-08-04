// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";

import {IAaveCreditDelegation} from "../../src/interfaces/IAaveV3.sol";
import {AaveV3FusedLeverageModule} from "../../src/AaveV3FusedModules.sol";
import {AaveModulesBase} from "../shared/AaveModulesBase.t.sol";

/// @dev The FUSED leverage item: supply + borrow in ONE `takeOnBehalf`, against the
/// two-item MAKE(deposit) + TAKE(borrow) pair that expresses the same position
/// today.
///
/// Aave checks health inside `borrow`, so the supply must come first. As two items
/// that is a scheduling obligation the solver has to honour; fused, it is internal
/// to the module and no schedule can split it. This file pins that the fused item
/// produces an IDENTICAL position, prices the difference, and covers the pro-rata
/// derivation that lets one gated `amount` drive both legs.
contract FusedLeverageTest is AaveModulesBase {
    AaveV3FusedLeverageModule fused;

    uint256 constant COLLATERAL = 1 ether; //  supplied
    uint256 constant BORROW = 1_500e6; //      drawn against it

    function setUp() public override {
        super.setUp();
        fused = new AaveV3FusedLeverageModule(address(permit3));
        vm.label(address(fused), "aaveV3FusedLeverageModule");
    }

    /// @dev `data` for the fused item. Carries the maker's intended TOTALS; the
    ///      module re-derives the collateral for whatever slice it is handed.
    function _fusedData(uint256 collateralTotal, uint256 borrowTotal) internal view returns (bytes memory) {
        return abi.encode(AAVE_POOL, USDC, uint256(2), WETH, collateralTotal, borrowTotal);
    }

    /// @dev One fused item replaces the MAKE+TAKE pair. `amount` is the BORROW leg
    ///      — the gated one, so the taker allowance caps it.
    function _fusedOrder(uint256 nonce, uint256 collateralTotal, uint256 borrowTotal)
        internal
        view
        returns (Order memory)
    {
        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE, address(fused), borrowTotal, address(0), _fusedData(collateralTotal, borrowTotal));
        return _order(maker, nonce, USDC, WETH, borrowTotal, collateralTotal, items);
    }

    /// @dev The maker authorises ONE module for both legs: a token allowance for the
    ///      collateral pull, a taker allowance for the borrow, plus Aave's own credit
    ///      delegation. (The two-item shape needs the same grants spread over two
    ///      modules.)
    function _authFused(uint256 collateralTotal, uint256 borrowTotal) internal {
        vm.startPrank(maker);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(fused), WETH, uint160(collateralTotal), 0);
        permit3.approveTaker(
            address(settlement),
            keccak256(_fusedData(collateralTotal, borrowTotal)),
            uint160(borrowTotal),
            uint48(block.timestamp + 1 hours)
        );
        IAaveCreditDelegation(usdcDebtToken).approveDelegation(address(fused), type(uint256).max);
        vm.stopPrank();
    }

    // ── The fused item opens the same position as the pair, in one dispatch.
    //
    //    Both runs start from an IDENTICAL fork state via a snapshot/revert. That
    //    matters more than it looks: run back-to-back, whichever goes second finds
    //    Aave's reserve state, the maker's aToken balance and the debt token all
    //    WARM and non-zero, which is worth ~280k on its own and would swamp the
    //    thing being measured. ──
    function test_fused_opensSamePosition_andCostsLess() public {
        deal(WETH, solver, COLLATERAL);
        _approveMakerDepositBorrowSide(COLLATERAL, BORROW);
        _approveSolverSide(COLLATERAL, WETH);
        _authFused(COLLATERAL, BORROW);

        Order memory pair = _buildDepositBorrowOrder(COLLATERAL, BORROW);
        bytes memory pairSig = _sign(pair);
        Order memory fusedOrder = _fusedOrder(77, COLLATERAL, BORROW);
        bytes memory fusedSig = _sign(fusedOrder);

        uint256 aBefore = IERC20(aWETH).balanceOf(maker);
        uint256 dBefore = IERC20(usdcDebtToken).balanceOf(maker);
        uint256 snap = vm.snapshotState();

        // ---- A: today's two-item pair ----
        vm.prank(solver);
        uint256 g0 = gasleft();
        settlement.fill(pair, pairSig, BORROW);
        uint256 pairGas = g0 - gasleft();
        uint256 aPair = IERC20(aWETH).balanceOf(maker) - aBefore;
        uint256 dPair = IERC20(usdcDebtToken).balanceOf(maker) - dBefore;

        // ---- B: the fused item, from the SAME starting state ----
        vm.revertToState(snap);
        vm.prank(solver);
        g0 = gasleft();
        settlement.fill(fusedOrder, fusedSig, BORROW);
        uint256 fusedGas = g0 - gasleft();
        uint256 aFused = IERC20(aWETH).balanceOf(maker) - aBefore;
        uint256 dFused = IERC20(usdcDebtToken).balanceOf(maker) - dBefore;

        // Same position, both legs — the fusion changes dispatch, not economics.
        assertApproxEqAbs(aFused, aPair, 2, "same collateral supplied");
        assertApproxEqAbs(dFused, dPair, 2, "same debt drawn");
        assertApproxEqAbs(aFused, COLLATERAL, 2, "collateral is the signed total");
        assertApproxEqAbs(dFused, BORROW, 2, "debt is the signed total");

        // Nothing left anywhere.
        assertEq(IERC20(WETH).balanceOf(address(fused)), 0, "fused module drained");
        assertEq(IERC20(USDC).balanceOf(address(fused)), 0, "fused module drained");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement drained");

        emit log_named_uint("two-item pair (gas)", pairGas);
        emit log_named_uint("fused item    (gas)", fusedGas);
        emit log_named_int("saved         (gas)", int256(pairGas) - int256(fusedGas));
        assertLt(fusedGas, pairGas, "fusing must not cost more than the pair it replaces");
    }

    // ── The pro-rata derivation: one gated `amount` drives both legs. Half the
    //    borrow must supply half the collateral. ──
    function test_fused_partialFill_derivesCollateralProRata() public {
        deal(WETH, solver, COLLATERAL);
        _approveSolverSide(COLLATERAL, WETH);
        _authFused(COLLATERAL, BORROW);

        Order memory o = _fusedOrder(88, COLLATERAL, BORROW);
        bytes memory sig = _sign(o);

        uint256 aBefore = IERC20(aWETH).balanceOf(maker);
        uint256 dBefore = IERC20(usdcDebtToken).balanceOf(maker);

        vm.prank(solver);
        settlement.fill(o, sig, BORROW / 2); // half the debt…

        assertApproxEqAbs(
            IERC20(aWETH).balanceOf(maker) - aBefore, COLLATERAL / 2, 2, "supplies half the collateral"
        );
        assertApproxEqAbs(IERC20(usdcDebtToken).balanceOf(maker) - dBefore, BORROW / 2, 2, "half the debt");

        // The remaining half completes the position exactly — the ceil rounding is
        // per-fill and toward MORE collateral, never less.
        vm.prank(solver);
        settlement.fill(o, sig, BORROW / 2);

        assertGe(IERC20(aWETH).balanceOf(maker) - aBefore, COLLATERAL, "never under-collateralised by rounding");
        assertApproxEqAbs(IERC20(aWETH).balanceOf(maker) - aBefore, COLLATERAL, 3, "and not materially over");
    }

    // ── The taker allowance caps the borrow leg, and the token allowance caps the
    //    collateral leg — both legs stay bounded by something the maker signed. ──
    function test_fused_borrowBeyondTakerAllowance_reverts() public {
        deal(WETH, solver, COLLATERAL);
        _approveSolverSide(COLLATERAL, WETH);
        _authFused(COLLATERAL, BORROW);

        // An order asking for more debt than the maker's taker allowance covers.
        Order memory o = _fusedOrder(99, COLLATERAL * 2, BORROW * 2);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert(); // Permit3 InsufficientAllowance — the ref/amount gate
        settlement.fill(o, sig, BORROW * 2);
    }

    // ── A zero `borrowTotal` would divide by zero in the ratio; rejected. ──
    function test_fused_zeroBorrowTotal_reverts() public {
        deal(WETH, solver, COLLATERAL);
        _approveSolverSide(COLLATERAL, WETH);

        bytes memory data = abi.encode(AAVE_POOL, USDC, uint256(2), WETH, COLLATERAL, uint256(0));
        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE, address(fused), BORROW, address(0), data);
        Order memory o = _order(maker, 111, USDC, WETH, BORROW, COLLATERAL, items);

        vm.startPrank(maker);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(fused), WETH, uint160(COLLATERAL), 0);
        permit3.approveTaker(
            address(settlement), keccak256(data), uint160(BORROW), uint48(block.timestamp + 1 hours)
        );
        IAaveCreditDelegation(usdcDebtToken).approveDelegation(address(fused), type(uint256).max);
        vm.stopPrank();

        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert(AaveV3FusedLeverageModule.InvalidRatio.selector);
        settlement.fill(o, sig, BORROW);
    }
}
