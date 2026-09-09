// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {Chains, Lenders, Tokens} from "@coretest/data/LenderRegistry.sol";
import {Order, Item, ItemOp, LegOut} from "@core/settlement/Settlement.sol";
import {PositionFillModule} from "@lib/PositionFillModule.sol";
import {NativeUnwrapModule} from "@modules/transfer/src/NativeUnwrapModule.sol";

import {IAaveV3Pool} from "../../src/interfaces/IAaveV3.sol";
import {AaveModulesBase} from "../shared/AaveModulesBase.t.sol";

/// @dev FULL CLOSE OF A wstETH/WETH LOOP, position-sized end to end.
///
/// The maker holds a levered wstETH position financed with WETH debt and wants
/// out — all of it, in one signature, ending in native ETH:
///
///   1. withdraw ALL wstETH collateral      ← {PositionFillModule} sizes the fill
///   2. sell it for WETH                    ← the SOLVER's side; no swap module
///   3. repay ALL the WETH debt             ← the repay module caps at live debt
///   4. take the remainder as native ETH    ← {NativeUnwrapModule}
///
/// Step 2 is worth naming: there is no swap item because this is an intent
/// settlement. The maker's `legsIn` is wstETH and their `legsOut` is WETH, so
/// "swap all to WETH" IS the fill — whoever fills sources the WETH however they
/// like. The order never names a pool.
///
/// ⚠ THE THING THIS TEST EXISTS TO PIN. Every leg and item scales by
/// `delta / fillTotal`, and `delta` is the COLLATERAL. The DEBT does not scale
/// with it — it is whatever it is. So the WETH leg funding the repay must be
/// signed with enough headroom that it still covers the debt after being scaled
/// down by the same ratio the collateral came in at. `test_..._capTooLoose_...`
/// below pins what happens when it is not: the fill fails closed, it does not
/// half-close the position.
contract PositionSizedLoopCloseTest is AaveModulesBase {
    PositionFillModule internal fillModule;
    NativeUnwrapModule internal unwrapModule;

    address internal WSTETH;
    address internal aWSTETH;
    address internal wethDebtToken;

    // ── The signed shape ──────────────────────────────────────────────────────
    // A tight cap is what makes a position-sized close sound: it is the expected
    // collateral plus a margin for accrual between signing and inclusion, NOT a
    // loose upper bound. See the contract note.
    uint256 internal constant COLLATERAL = 10 ether; //      wstETH actually held
    uint256 internal constant CAP = 10.5 ether; //           signed ceiling (+5% accrual margin)
    uint256 internal constant DEBT = 6 ether; //             WETH borrowed
    uint256 internal constant REPAY_LEG = 7 ether; //        WETH → maker, funds the repay
    uint256 internal constant NATIVE_LEG = 4 ether; //       WETH → unwrap → native to maker
    uint256 internal constant REPAY_CEILING = 7 ether; //    item ceiling; module caps at live debt

    function setUp() public override {
        super.setUp();

        WSTETH = tokens[Chains.ETHEREUM_MAINNET][Tokens.WSTETH];
        aWSTETH = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][WSTETH].collateral;
        wethDebtToken = lendingTokens[Chains.ETHEREUM_MAINNET][Lenders.AAVE_V3][WETH].debt;

        fillModule = new PositionFillModule();
        unwrapModule = new NativeUnwrapModule(WETH, address(settlement));

        vm.label(WSTETH, "wstETH");
        vm.label(aWSTETH, "aWstETH");
        vm.label(address(fillModule), "positionFillModule");
        vm.label(address(unwrapModule), "nativeUnwrapModule");

        // The withdraw module pulls aTokens on its OWN allowance (not Permit3).
        vm.prank(maker);
        IERC20(aWSTETH).approve(address(withdrawModule), type(uint256).max);
    }

    // ──────────────────── Fixtures ────────────────────

    /// @dev Open the loop the honest way: supply wstETH, borrow WETH against it,
    /// and dump the borrowed WETH so the wallet starts clean — the close must be
    /// funded by the solver, not by leftovers.
    function _openLoop() internal {
        deal(WSTETH, maker, COLLATERAL);
        vm.startPrank(maker);
        IERC20(WSTETH).approve(AAVE_POOL, COLLATERAL);
        IAaveV3Pool(AAVE_POOL).supply(WSTETH, COLLATERAL, maker, 0);
        IAaveV3Pool(AAVE_POOL).borrow(WETH, DEBT, 2, 0, maker);
        IERC20(WETH).transfer(address(0xdead), DEBT);
        vm.stopPrank();
    }

    function _withdrawData() internal view returns (bytes memory) {
        return abi.encode(AAVE_POOL, WSTETH, aWSTETH);
    }

    function _repayData() internal view returns (bytes memory) {
        return abi.encode(AAVE_POOL, WETH, uint256(2), wethDebtToken);
    }

    function _approveAll(uint256 repayCeiling) internal {
        bytes memory wd = _withdrawData();
        vm.startPrank(maker);
        // Taker gate on the withdraw, capped at the maker's signed ceiling.
        IERC20(WSTETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), WSTETH, uint160(CAP), 0);
        permit3.approveTaker(address(settlement), address(withdrawModule), keccak256(wd), uint160(CAP), 0);
        // The repay module pulls WETH from the maker's wallet — which the solver's
        // output leg has just filled.
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(repayModule), WETH, uint160(repayCeiling), 0);
        vm.stopPrank();
    }

    /// @dev `legsOut` is split on purpose: the first leg lands in the maker's
    /// WALLET so the repay item has something to pull, the second lands on the
    /// unwrap module so its item can turn it into native ETH. One combined leg
    /// could not do both.
    function _closeOrder(uint256 nonce, uint256 repayLeg, uint256 repayCeiling)
        internal
        view
        returns (Order memory order)
    {
        // ⚠ REPAY BEFORE WITHDRAW, AND THE VENUE ENFORCES IT. Moving collateral out
        // while the debt is open fails Aave's health-factor check (error 35), so the
        // repay must run first. That is exactly why {PositionFillModule} FINDS the
        // position item rather than assuming index 0 — here it is item 1.
        Item[] memory items = new Item[](3);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(repayModule),
            amount: repayCeiling,
            recipient: address(0),
            data: _repayData()
        });
        items[1] = Item({ // ← this item sizes the fill: the wstETH position
            op: ItemOp.TAKE,
            module: address(withdrawModule),
            amount: CAP, //                      == fillTotal == legsIn[0].start
            recipient: address(0), //            Settlement, for the tokenIn payout
            data: _withdrawData()
        });
        items[2] = Item({
            op: ItemOp.MAKE,
            module: address(unwrapModule),
            amount: NATIVE_LEG,
            recipient: address(0),
            data: abi.encode(address(0)) //      address(0) = pay the maker
        });

        LegOut[] memory outs = new LegOut[](2);
        outs[0] = LegOut({token: WETH, start: repayLeg, end: 0, recipient: address(0)}); // → maker's wallet
        outs[1] = LegOut({token: WETH, start: NATIVE_LEG, end: 0, recipient: address(unwrapModule)});

        order = _order(maker, nonce, WSTETH, WETH, CAP, repayLeg, items);
        order.legsOut = PackedEncode.legsOut(outs);
        order.fillModule = address(fillModule);
        order.fillTotal = CAP;
    }

    // ──────────────────── The close ────────────────────

    function test_close_wstethWethLoop_positionSized_endsInNativeEth() public {
        _openLoop();
        _approveAll(REPAY_CEILING);
        deal(WETH, solver, REPAY_LEG + NATIVE_LEG);
        _approveSolverSide(REPAY_LEG + NATIVE_LEG, WETH);

        Order memory order = _closeOrder(1, REPAY_LEG, REPAY_CEILING);
        bytes memory sig = _sign(order);

        // ── Quote it the way a filler would: probe with the signed denominator,
        //    then submit the delta it returns (which is also the staleness bound).
        (uint256 delta,,) = lens.previewFill(order, order.fillTotal, solver, "");
        uint256 livePosition = IERC20(aWSTETH).balanceOf(maker);
        assertEq(delta, livePosition, "fill sized from the LIVE wstETH position");
        assertLt(delta, CAP, "and it is below the signed cap, so this is a partial fill");

        uint256 debtBefore = IERC20(wethDebtToken).balanceOf(maker);
        uint256 ethBefore = maker.balance;

        vm.prank(solver);
        uint256 g0 = gasleft();
        settlement.fill(order, sig, delta);
        uint256 closeGas = g0 - gasleft();

        // ── 1. the whole wstETH position is gone, and none of it came back as dust
        assertLe(IERC20(aWSTETH).balanceOf(maker), 1, "wstETH collateral fully exited");
        assertEq(IERC20(WSTETH).balanceOf(maker), 0, "no unconverted wstETH in the wallet");
        // ── 2. the solver bought exactly the live position
        assertEq(IERC20(WSTETH).balanceOf(solver), livePosition, "solver received the whole position");
        // ── 3. the WETH debt is closed
        assertEq(IERC20(wethDebtToken).balanceOf(maker), 0, "WETH debt fully repaid");
        assertGt(debtBefore, 0, "and there was debt to repay");
        // ── 4. the remainder arrived as NATIVE ETH, scaled by the same ratio
        uint256 expectedNative = (NATIVE_LEG * delta) / CAP;
        assertApproxEqAbs(maker.balance - ethBefore, expectedNative, 1, "remainder paid as native ETH");

        // Nothing stranded anywhere.
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement WETH drained");
        assertEq(IERC20(WSTETH).balanceOf(address(settlement)), 0, "settlement wstETH drained");
        assertEq(IERC20(aWSTETH).balanceOf(address(withdrawModule)), 0, "withdraw module drained");
        // At most 1 wei, not 0: output legs round in the maker's favour (ceil) while
        // items slice by cumulative floor, so {NativeUnwrapModule} documents a 1-wei
        // rounding residue as unrecoverable dust by design.
        assertLe(IERC20(WETH).balanceOf(address(unwrapModule)), 1, "unwrap module holds at most rounding dust");
        assertEq(address(unwrapModule).balance, 0, "unwrap module holds no native");

        console2.log("=== wstETH/WETH loop close, position-sized ===");
        console2.log("  collateral withdrawn (wei) :", livePosition);
        console2.log("  debt repaid          (wei) :", debtBefore);
        console2.log("  native ETH to maker  (wei) :", maker.balance - ethBefore);
        console2.log("  gas, whole close           :", closeGas);
        console2.log("  gas per item (3 items)     :", closeGas / 3);
    }

    /// @dev The gas cost of position-sizing, isolated: the SAME close, signed the
    /// old way (an absolute amount plus `BalanceMode.Full`), from the same starting
    /// state, after 90 days of real accrual.
    ///
    /// The result is not the one I expected. Position-sizing adds a `resolveFill`
    /// STATICCALL and a venue read, but it REMOVES a second `pool.withdraw`: `Full`
    /// has to make one withdraw for the signed amount and another to hand the
    /// remainder back, and an Aave withdraw costs far more than a balance read. So
    /// whenever there is anything to return — which is the entire reason the feature
    /// exists — the position-sized close is the CHEAPER of the two. The sign is
    /// logged rather than asserted, because it inverts when accrual is exactly zero.
    function test_gas_positionSized_vs_balanceModeFull() public {
        _openLoop();
        // Let the position actually ACCRUE. Without this the live balance equals the
        // amount an absolute order would have signed, and the comparison would show
        // a benefit that is not there — the whole point is the gap between what the
        // maker knew at signing and what they hold at inclusion.
        vm.warp(block.timestamp + 90 days);
        deal(WETH, solver, (REPAY_LEG + NATIVE_LEG) * 2);
        _approveSolverSide((REPAY_LEG + NATIVE_LEG) * 2, WETH);
        _approveAll(REPAY_CEILING);

        uint256 live = IERC20(aWSTETH).balanceOf(maker);
        uint256 snap = vm.snapshotState();

        // ── A: position-sized
        Order memory sized = _closeOrder(2, REPAY_LEG, REPAY_CEILING);
        bytes memory sizedSig = _sign(sized);
        vm.prank(solver);
        uint256 g0 = gasleft();
        settlement.fill(sized, sizedSig, live);
        uint256 sizedGas = g0 - gasleft();
        uint256 sizedNative = maker.balance;
        uint256 sizedLeftoverWsteth = IERC20(WSTETH).balanceOf(maker);
        assertEq(IERC20(wethDebtToken).balanceOf(maker), 0, "A: debt closed");

        // ── B: the same close signed as an absolute amount with `Full` mode, from
        //    the same state. `Full` still exits the position, but the maker is paid
        //    only for the signed amount and the excess returns as raw wstETH.
        vm.revertToState(snap);
        bytes memory fullData = abi.encode(AAVE_POOL, WSTETH, aWSTETH, uint8(1), COLLATERAL);
        vm.startPrank(maker);
        permit3.approveTaker(address(settlement), address(withdrawModule), keccak256(fullData), uint160(COLLATERAL), 0);
        vm.stopPrank();

        Item[] memory items = new Item[](3);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(repayModule),
            amount: REPAY_CEILING,
            recipient: address(0),
            data: _repayData()
        });
        items[1] = Item({
            op: ItemOp.TAKE,
            module: address(withdrawModule),
            amount: COLLATERAL,
            recipient: address(0),
            data: fullData
        });
        items[2] = Item({
            op: ItemOp.MAKE,
            module: address(unwrapModule),
            amount: NATIVE_LEG,
            recipient: address(0),
            data: abi.encode(address(0))
        });
        LegOut[] memory outs = new LegOut[](2);
        outs[0] = LegOut({token: WETH, start: REPAY_LEG, end: 0, recipient: address(0)});
        outs[1] = LegOut({token: WETH, start: NATIVE_LEG, end: 0, recipient: address(unwrapModule)});
        Order memory plain = _order(maker, 3, WSTETH, WETH, COLLATERAL, REPAY_LEG, items);
        plain.legsOut = PackedEncode.legsOut(outs);
        bytes memory plainSig = _sign(plain);

        vm.prank(solver);
        g0 = gasleft();
        settlement.fill(plain, plainSig, COLLATERAL);
        uint256 plainGas = g0 - gasleft();
        assertEq(IERC20(wethDebtToken).balanceOf(maker), 0, "B: debt closed");

        // The property, not just the gas: `Full` exits the position too, but pays the
        // accrued excess back as RAW wstETH. Position-sizing sells it.
        uint256 plainLeftoverWsteth = IERC20(WSTETH).balanceOf(maker);
        assertEq(sizedLeftoverWsteth, 0, "A: nothing came back unconverted");
        assertGt(plainLeftoverWsteth, 0, "B: the accrued excess came back as raw wstETH");

        _report(live, sizedGas, plainGas, sizedNative, sizedLeftoverWsteth, plainLeftoverWsteth);
    }

    /// @dev Its own frame purely for the stack — nine live locals plus the logging
    ///      overflows under legacy codegen.
    function _report(
        uint256 live,
        uint256 sizedGas,
        uint256 plainGas,
        uint256 sizedNative,
        uint256 sizedLeft,
        uint256 plainLeft
    )
        private
        view
    {
        console2.log("=== close gas: position-sized (A) vs BalanceMode.Full (B) ===");
        console2.log("  live position after 90d    :", live);
        console2.log("  A gas                      :", sizedGas);
        console2.log("  B gas                      :", plainGas);
        // ⚠ SIGN NOT ASSUMED — it goes both ways, and which way is the finding.
        // With accrual (this test) A is CHEAPER: `Full` pays for a SECOND
        // `pool.withdraw` to return the remainder, which costs far more than A's
        // `resolveFill` staticcall. With no accrual at all, `bal > amount` is false,
        // `Full` makes one withdraw, and A's staticcall makes it the dearer of the two.
        if (sizedGas > plainGas) {
            console2.log("  A costs MORE by            :", sizedGas - plainGas);
        } else {
            console2.log("  A costs LESS by            :", plainGas - sizedGas);
        }
        console2.log("  A native ETH to maker      :", sizedNative);
        console2.log("  B native ETH to maker      :", maker.balance);
        console2.log("  A unconverted wstETH left  :", sizedLeft);
        console2.log("  B unconverted wstETH left  :", plainLeft);
    }

    // ──────────────────── The failure mode worth pinning ────────────────────

    /// @dev A LOOSE cap is the one way this shape bites. Every leg scales by
    /// `delta / fillTotal`, so a cap far above the real position scales the WETH
    /// leg funding the repay down with the collateral — while the debt stays put.
    /// It must fail CLOSED rather than half-close the position, because the order
    /// is one-shot: a partial close would leave the maker levered with their exit
    /// order spent.
    function test_capTooLoose_underfundsTheRepay_andFailsClosed() public {
        _openLoop();
        _approveAll(REPAY_CEILING);
        deal(WETH, solver, REPAY_LEG + NATIVE_LEG);
        _approveSolverSide(REPAY_LEG + NATIVE_LEG, WETH);

        // Cap at 4x the real position ⇒ ratio ≈ 0.25 ⇒ the repay leg delivers
        // ~1.75 WETH against a 6 WETH debt.
        Order memory order = _closeOrder(4, REPAY_LEG, REPAY_CEILING);
        order.fillTotal = CAP * 4;
        order.legsIn = _legsIn1(WSTETH, CAP * 4);
        Item[] memory items = new Item[](3);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(repayModule),
            amount: REPAY_CEILING,
            recipient: address(0),
            data: _repayData()
        });
        items[1] = Item({
            op: ItemOp.TAKE,
            module: address(withdrawModule),
            amount: CAP * 4,
            recipient: address(0),
            data: _withdrawData()
        });
        items[2] = Item({
            op: ItemOp.MAKE,
            module: address(unwrapModule),
            amount: NATIVE_LEG,
            recipient: address(0),
            data: abi.encode(address(0))
        });
        order.items = PackedEncode.items(items);
        bytes memory sig = _sign(order);

        uint256 debtBefore = IERC20(wethDebtToken).balanceOf(maker);

        vm.prank(solver);
        vm.expectRevert(); // the repay pull exceeds what the scaled leg delivered
        settlement.fill(order, sig, CAP * 4);

        // Nothing moved: still levered, order unspent.
        assertEq(IERC20(wethDebtToken).balanceOf(maker), debtBefore, "debt untouched");
        assertGe(IERC20(aWSTETH).balanceOf(maker), COLLATERAL - 2, "collateral untouched");
    }
}
