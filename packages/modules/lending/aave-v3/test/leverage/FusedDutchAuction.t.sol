// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, OrderSide, LegIn, LegOut, Validator, CurvePoint} from "@core/settlement/Settlement.sol";

import {IAaveCreditDelegation} from "../../src/interfaces/IAaveV3.sol";
import {AaveV3FusedLeverageModule} from "../../src/AaveV3FusedModules.sol";
import {AaveModulesBase} from "../shared/AaveModulesBase.t.sol";

/// @dev A DUTCH-AUCTIONED leverage fill on the fused module.
///
/// The obstacle: `_executeItem` slices `item.amount` by the fill fraction and never
/// sees the auction tick — items are auction-blind by design. So on a SELL leverage
/// order (collateral decaying) the fused module's fixed collateral/borrow ratio
/// cannot track the price, and the maker either strands the auction surplus in
/// their wallet or under-funds the deposit.
///
/// The resolution is to put the auction on the DEBT side instead — sign it as a BUY:
///
///   legsOut = [1 WETH]            FIXED   (BUY ⇒ outputs fixed) → deposit is exact
///   legsIn  = [1500 → 1600 USDC]  RISING  (BUY ⇒ inputs rise)   → the auction
///   item    = fused TAKE, amount = 1600 USDC — the CEILING
///
/// The maker's collateral and debt are then both fixed and known at signing, and the
/// auction decides how much of the borrowed USDC the SOLVER keeps. Whatever it does
/// not earn is returned to the maker as cash back by `_payInputsToSolver`, which
/// already refunds proceeds above `inputOwed`. Nothing new is needed.
///
/// Note the sizing rule this implies — the dual of the documented MAKE rule
/// ("size a MAKE item at the auction FLOOR"): **size a TAKE item at the auction
/// CEILING.** Sized at the floor, a late fill owes more than the borrow produced and
/// `_payInputsToSolver` pulls the shortfall out of the maker's wallet.
contract FusedDutchAuctionTest is AaveModulesBase {
    AaveV3FusedLeverageModule fused;

    uint256 constant COLLATERAL = 1 ether; //   fixed: what the maker ends up holding
    uint256 constant DEBT_FLOOR = 1_500e6; //   t=0   — best for the maker
    uint256 constant DEBT_CEIL = 1_600e6; //    t=end — best for the solver
    uint32 constant DECAY = 600; //             10-minute auction

    function setUp() public override {
        super.setUp();
        fused = new AaveV3FusedLeverageModule(address(permit3));
        vm.label(address(fused), "aaveV3FusedLeverageModule");
    }

    function _data() internal view returns (bytes memory) {
        // The ratio is exact because BOTH totals are fixed quantities on a BUY.
        return abi.encode(AAVE_POOL, USDC, uint256(2), WETH, COLLATERAL, DEBT_CEIL);
    }

    /// @dev BUY: fixed collateral out, rising debt in, one fused item at the ceiling.
    function _auctionedLeverage() internal view returns (Order memory o) {
        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE, address(fused), DEBT_CEIL, address(0), _data());

        LegIn[] memory legsIn = new LegIn[](1);
        legsIn[0] = LegIn(USDC, DEBT_FLOOR, DEBT_CEIL); // end != 0 ⇒ rises with the tick

        LegOut[] memory legsOut = new LegOut[](1);
        legsOut[0] = LegOut(WETH, COLLATERAL, 0, address(0)); // end == 0 ⇒ fixed

        o = Order({
            params: 0,
            pricingModule: address(0),
            maker: maker,
            nonce: 1,
            deadline: block.timestamp + 1 hours,
            legsIn: PackedEncode.legsIn(legsIn),
            legsOut: PackedEncode.legsOut(legsOut),
            timing: _packTiming(uint32(block.timestamp), DECAY, 0),
            exclusiveFiller: address(0),
            minFillAnchor: 0,
            curve: _noCurve(),
            items: PackedEncode.items(items),
            validators: PackedEncode.noValidators(),
            invariants: PackedEncode.noValidators(),
            fillModule: address(0),
            fillTotal: 0
        });
        o.timing |= uint256(1) << 101; // BUY (side lives in timing bit 101, not its own field)
    }

    function _auth() internal {
        vm.startPrank(maker);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(fused), WETH, uint160(COLLATERAL), 0);
        permit3.approveTaker(
            address(settlement), keccak256(_data()), uint160(DEBT_CEIL), uint48(block.timestamp + 1 hours)
        );
        IAaveCreditDelegation(usdcDebtToken).approveDelegation(address(fused), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Fill the SAME order `elapsed` seconds into the auction, from an identical
    ///      starting state, and report what each side ended up with.
    function _fillAt(Order memory o, bytes memory sig, uint256 elapsed)
        internal
        returns (uint256 collateralGained, uint256 debtTaken, uint256 makerCashBack, uint256 solverGot)
    {
        uint256 aBefore = IERC20(aWETH).balanceOf(maker);
        uint256 dBefore = IERC20(usdcDebtToken).balanceOf(maker);

        vm.warp(block.timestamp + elapsed);
        vm.prank(solver);
        settlement.fill(o, sig, COLLATERAL); // BUY ⇒ the anchor is the collateral leg

        collateralGained = IERC20(aWETH).balanceOf(maker) - aBefore;
        debtTaken = IERC20(usdcDebtToken).balanceOf(maker) - dBefore;
        makerCashBack = IERC20(USDC).balanceOf(maker);
        solverGot = IERC20(USDC).balanceOf(solver);
    }

    // ── The auction runs on the debt side; the position itself is invariant. ──
    function test_auctionedLeverage_positionFixed_solverShareDecays() public {
        _auth();
        Order memory o = _auctionedLeverage();
        bytes memory sig = _sign(o);

        uint256 snap = vm.snapshotState();
        uint256[3] memory elapsed = [uint256(0), DECAY / 2, DECAY];
        uint256[3] memory coll;
        uint256[3] memory debt;
        uint256[3] memory cash;
        uint256[3] memory paid;

        for (uint256 i; i < 3; i++) {
            vm.revertToState(snap);
            deal(WETH, solver, COLLATERAL);
            _approveSolverSide(COLLATERAL, WETH);
            (coll[i], debt[i], cash[i], paid[i]) = _fillAt(o, sig, elapsed[i]);
        }

        emit log_named_uint("t=0     solver receives (USDC)", paid[0]);
        emit log_named_uint("t=mid   solver receives (USDC)", paid[1]);
        emit log_named_uint("t=end   solver receives (USDC)", paid[2]);
        emit log_named_uint("t=0     maker cash back (USDC)", cash[0]);
        emit log_named_uint("t=mid   maker cash back (USDC)", cash[1]);
        emit log_named_uint("t=end   maker cash back (USDC)", cash[2]);

        // 1. THE POSITION IS INVARIANT TO THE TICK. This is the whole point of the
        //    BUY framing: the fused ratio is exact at every clearing price, because
        //    both of its totals are fixed legs.
        for (uint256 i; i < 3; i++) {
            assertApproxEqAbs(coll[i], COLLATERAL, 2, "collateral fixed at every tick");
            assertApproxEqAbs(debt[i], DEBT_CEIL, 2, "debt fixed at every tick");
        }

        // 2. THE AUCTION IS REAL. The solver earns strictly more the longer it waits.
        assertEq(paid[0], DEBT_FLOOR, "t=0: solver earns the floor");
        assertEq(paid[2], DEBT_CEIL, "t=end: solver earns the ceiling");
        assertGt(paid[1], paid[0], "mid > start");
        assertGt(paid[2], paid[1], "end > mid");
        assertApproxEqAbs(paid[1], (DEBT_FLOOR + DEBT_CEIL) / 2, 1, "midpoint prices at the midpoint");

        // 3. THE MAKER'S EDGE IS CASH BACK, NOT LESS DEBT — the surplus the solver
        //    did not earn is returned by `_payInputsToSolver`, machinery that already
        //    existed for over-provisioned TAKE proceeds.
        for (uint256 i; i < 3; i++) {
            assertEq(cash[i] + paid[i], DEBT_CEIL, "every borrowed dollar is accounted for");
        }
        assertEq(cash[0], DEBT_CEIL - DEBT_FLOOR, "t=0: maker keeps the full 100 USDC");
        assertEq(cash[2], 0, "t=end: the solver has earned all of it");

        // 4. Nothing stranded.
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement drained");
        assertEq(IERC20(USDC).balanceOf(address(fused)), 0, "module drained");
        assertEq(IERC20(WETH).balanceOf(address(fused)), 0, "module drained");
    }

    // ── The sizing rule, demonstrated: a TAKE item sized at the auction FLOOR
    //    under-produces on a late fill, and the shortfall is pulled from the maker's
    //    own wallet rather than from the borrow. Size TAKE items at the CEILING. ──
    function test_takeItemSizedAtFloor_pullsShortfallFromMaker() public {
        bytes memory floorData = abi.encode(AAVE_POOL, USDC, uint256(2), WETH, COLLATERAL, DEBT_FLOOR);
        Order memory o = _auctionedLeverage();
        // Resize the single TAKE item to the auction FLOOR (`o.items` is a packed blob
        // now, so rebuild it rather than index into it). ← floor, not ceiling
        Item[] memory floorItems = new Item[](1);
        floorItems[0] = Item(ItemOp.TAKE, address(fused), DEBT_FLOOR, address(0), floorData);
        o.items = PackedEncode.items(floorItems);
        o.nonce = 2;

        vm.startPrank(maker);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(fused), WETH, uint160(COLLATERAL), 0);
        permit3.approveTaker(
            address(settlement), keccak256(floorData), uint160(DEBT_FLOOR), uint48(block.timestamp + 1 hours)
        );
        IAaveCreditDelegation(usdcDebtToken).approveDelegation(address(fused), type(uint256).max);
        vm.stopPrank();

        deal(WETH, solver, COLLATERAL);
        _approveSolverSide(COLLATERAL, WETH);
        bytes memory sig = _sign(o);

        // A LATE fill owes the ceiling but the item only borrowed the floor. With no
        // USDC in the maker's wallet and no standing allowance to cover the gap, the
        // shortfall pull fails — the order is simply unfillable late.
        vm.warp(block.timestamp + DECAY);
        vm.prank(solver);
        vm.expectRevert();
        settlement.fill(o, sig, COLLATERAL);

        // Give the maker the shortfall and a Settlement allowance: it now fills, but
        // the maker has paid 100 USDC out of pocket on top of the debt they took on.
        deal(USDC, maker, DEBT_CEIL - DEBT_FLOOR);
        vm.prank(maker);
        permit3.approveToken(address(settlement), USDC, uint160(DEBT_CEIL), 0);

        vm.prank(solver);
        settlement.fill(o, sig, COLLATERAL);

        assertEq(IERC20(USDC).balanceOf(solver), DEBT_CEIL, "solver still earns the full ceiling");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "funded partly from the makers own pocket");
        assertApproxEqAbs(IERC20(usdcDebtToken).balanceOf(maker), DEBT_FLOOR, 2, "maker only borrowed the floor");
    }
}
