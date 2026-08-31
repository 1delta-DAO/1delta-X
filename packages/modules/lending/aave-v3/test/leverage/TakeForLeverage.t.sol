// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, LegOut} from "@core/settlement/Settlement.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {IAaveCreditDelegation} from "../../src/interfaces/IAaveV3.sol";
import {AaveV3TakeForLeverageModule} from "../../src/AaveV3FusedModules.sol";
import {AaveModulesBase} from "../shared/AaveModulesBase.t.sol";

/// @dev The `TAKE_FOR` item on a real lender: supply + borrow in ONE dispatch,
/// with the collateral amount handed in by the SETTLER rather than re-derived
/// inside the module.
///
/// The two-item `[MAKE deposit, TAKE borrow]` pair and the ratio-based fused item
/// both express this position already. What this file pins is the thing neither of
/// them can: the collateral is `legsOut[0]` — the leg the solver delivered to the
/// maker moments earlier in the same fill — so there is exactly ONE signed copy of
/// that number, and over any fill the maker's WETH balance nets to zero.
contract TakeForLeverageTest is AaveModulesBase {
    AaveV3TakeForLeverageModule takeForModule;

    uint256 constant COLLATERAL = 1 ether; //  supplied — and the order's output leg
    uint256 constant BORROW = 1_500e6; //      drawn against it

    function setUp() public override {
        super.setUp();
        takeForModule = new AaveV3TakeForLeverageModule(address(permit3));
        vm.label(address(takeForModule), "aaveV3TakeForLeverageModule");
    }

    /// @dev `(1 << 255) | index` — fund from `legsOut[index]`.
    function _forLeg(uint256 index) internal pure returns (uint256) {
        return (uint256(1) << 255) | index;
    }

    /// @dev `(3 << 254) | floorBps << 160 | token` — fund with
    ///      `min(balanceOf(token, maker), cap)`, subject to a floor of `floorBps` of
    ///      the cap.
    ///
    ///      ⚠ THE FLOOR IS EXPLICIT ON PURPOSE. An UNSET floor (0) means the FULL CAP
    ///      to the settler — "fund the whole cap or do not fill" — because a
    ///      descriptor field nobody filled in must not select the lenient mode. A
    ///      genuine sweep like the one below deliberately funds LESS than its ceiling,
    ///      so it has to say so.
    function _forBalance(address token, uint256 floorBps) internal pure returns (uint256) {
        return (uint256(3) << 254) | (floorBps << 160) | uint160(token);
    }

    /// @dev No totals, no ratio: the collateral amount is not in here at all.
    ///      `forCap` is only read for the balance form; 0 here.
    function _takeForData() internal view returns (bytes memory) {
        return abi.encode(_forLeg(0), uint256(0), AAVE_POOL, USDC, uint256(2), WETH);
    }

    /// @dev A sweep: the maker's wallet is expected to sit UNDER the cap, so the floor
    ///      is signed low (1 bps) rather than left unset.
    function _takeForBalanceData(uint256 cap) internal view returns (bytes memory) {
        return abi.encode(_forBalance(WETH, 1), cap, AAVE_POOL, USDC, uint256(2), WETH);
    }

    /// @dev `legsOut[0]` is the WETH collateral — the leg the item funds from.
    function _takeForOrder(uint256 nonce, uint256 collateralTotal, uint256 borrowTotal)
        internal
        view
        returns (Order memory)
    {
        Item[] memory items = new Item[](1);
        items[0] =
            Item(ItemOp.TAKE_FOR, address(takeForModule), borrowTotal, address(0), _takeForData());
        return _order(maker, nonce, USDC, WETH, borrowTotal, collateralTotal, items);
    }

    /// @dev One module, both books: the taker allowance caps the borrow, the token
    ///      allowance caps the supply, plus Aave's own credit delegation.
    function _authTakeFor(uint256 collateralTotal, uint256 borrowTotal) internal {
        vm.startPrank(maker);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        // +2 wei of ceil margin: a SELL output leg is priced per fill with a CEIL, so
        // N slices can deliver marginally more than the leg total — and the funding
        // leg, being the same number, pulls exactly that. See {Base._forSlice}.
        permit3.approveToken(address(takeForModule), WETH, uint160(collateralTotal + 2), 0);
        permit3.approveTaker(
            address(settlement),
            address(takeForModule),
            keccak256(_takeForData()),
            uint160(borrowTotal),
            uint48(block.timestamp + 1 hours)
        );
        IAaveCreditDelegation(usdcDebtToken).approveDelegation(address(takeForModule), type(uint256).max);
        vm.stopPrank();
    }

    // ── Same position as the two-item pair, in one dispatch. Both runs start from
    //    an IDENTICAL fork state — run back-to-back, whichever goes second finds
    //    Aave's reserve, the aToken and the debt token warm, worth ~280k. ──
    function test_takeFor_opensSamePosition_andCostsLess() public {
        deal(WETH, solver, COLLATERAL);
        _approveMakerDepositBorrowSide(COLLATERAL, BORROW);
        _approveSolverSide(COLLATERAL, WETH);
        _authTakeFor(COLLATERAL, BORROW);

        Order memory pair = _buildDepositBorrowOrder(COLLATERAL, BORROW);
        bytes memory pairSig = _sign(pair);
        Order memory takeForOrder = _takeForOrder(77, COLLATERAL, BORROW);
        bytes memory takeForSig = _sign(takeForOrder);

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

        // ---- B: the TAKE_FOR item, from the SAME starting state ----
        vm.revertToState(snap);
        vm.prank(solver);
        g0 = gasleft();
        settlement.fill(takeForOrder, takeForSig, BORROW);
        uint256 takeForGas = g0 - gasleft();
        uint256 aNew = IERC20(aWETH).balanceOf(maker) - aBefore;
        uint256 dNew = IERC20(usdcDebtToken).balanceOf(maker) - dBefore;

        assertApproxEqAbs(aNew, aPair, 2, "same collateral supplied");
        assertApproxEqAbs(dNew, dPair, 2, "same debt drawn");
        assertApproxEqAbs(aNew, COLLATERAL, 2, "collateral is the signed OUTPUT LEG");
        assertApproxEqAbs(dNew, BORROW, 2, "debt is the signed item amount");

        assertEq(IERC20(WETH).balanceOf(address(takeForModule)), 0, "module drained");
        assertEq(IERC20(USDC).balanceOf(address(takeForModule)), 0, "module drained");
        assertEq(IERC20(WETH).balanceOf(address(settlement)), 0, "settlement drained");

        emit log_named_uint("two-item pair (gas)", pairGas);
        emit log_named_uint("TAKE_FOR item (gas)", takeForGas);
        emit log_named_int("saved         (gas)", int256(pairGas) - int256(takeForGas));
        assertLt(takeForGas, pairGas, "the composite item must not cost more than the pair");
    }

    // ── The property the descriptor buys: across partial fills the maker's WETH
    //    balance never moves. Every unit the solver delivers on the output leg is
    //    exactly the amount supplied back into Aave, because both come from the
    //    same {Pricing.outputAt} call — not from a second signed total the module
    //    re-derives and has to round. ──
    function test_takeFor_partialFills_makerNetsZeroInTheFundingToken() public {
        deal(WETH, solver, COLLATERAL * 2);
        _approveSolverSide(COLLATERAL * 2, WETH);
        _authTakeFor(COLLATERAL, BORROW);

        Order memory o = _takeForOrder(88, COLLATERAL, BORROW);
        bytes memory sig = _sign(o);

        uint256 wBefore = IERC20(WETH).balanceOf(maker);
        uint256 aBefore = IERC20(aWETH).balanceOf(maker);
        uint256 dBefore = IERC20(usdcDebtToken).balanceOf(maker);

        vm.prank(solver);
        settlement.fill(o, sig, BORROW / 3);
        assertEq(IERC20(WETH).balanceOf(maker), wBefore, "net zero after fill 1");

        vm.prank(solver);
        settlement.fill(o, sig, BORROW - BORROW / 3);
        assertEq(IERC20(WETH).balanceOf(maker), wBefore, "net zero after fill 2");

        assertApproxEqAbs(IERC20(aWETH).balanceOf(maker) - aBefore, COLLATERAL, 2, "the whole leg was supplied");
        assertApproxEqAbs(IERC20(usdcDebtToken).balanceOf(maker) - dBefore, BORROW, 2, "and the whole debt drawn");
    }

    // ── THE NO-CONVERSION SHAPE. A plain deposit + borrow: the maker funds the
    //    collateral from their OWN wallet, the borrow goes STRAIGHT to their wallet,
    //    and nothing converts. There is no output leg to reference, so the funding
    //    descriptor is the balance form — "deposit what I hold, up to this cap" —
    //    which is exactly the amount a maker cannot know at signing time.
    //
    //    The relayer is paid by a RISING INPUT LEG in the borrowed asset
    //    (docs/relayer-fees.md), and it self-funds: items run before
    //    `_payInputsToSolver`, so the borrow lands in the maker's wallet first and
    //    the fee is pulled out of it. The relayer fronts NOTHING — no inventory, no
    //    flash — for a fully-formed levered position opened in one signature. ──
    function test_noConversion_depositBalance_andBorrow_withRisingFee() public {
        uint256 held = 1 ether; //    the maker's whole WETH wallet becomes collateral
        uint256 cap = 2 ether; //     the mandatory signed ceiling
        uint256 feeFloor = 10e6; //   10 USDC — the relayer-fee auction start
        uint256 feeCeil = 30e6; //    auction end (worst for the maker)
        uint32 duration = 1000;

        deal(WETH, maker, held);
        // The maker starts with NO USDC: the fee can only come from the borrow.
        deal(USDC, maker, 0);

        bytes memory data = _takeForBalanceData(cap);
        vm.startPrank(maker);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(takeForModule), WETH, uint160(cap), 0); // funding leg
        permit3.approveToken(address(settlement), USDC, uint160(feeCeil), 0); // the fee pull
        permit3.approveTaker(
            address(settlement),
            address(takeForModule),
            keccak256(data),
            uint160(BORROW),
            uint48(block.timestamp + 1 hours)
        );
        IAaveCreditDelegation(usdcDebtToken).approveDelegation(address(takeForModule), type(uint256).max);
        vm.stopPrank();

        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.TAKE_FOR,
            module: address(takeForModule),
            amount: BORROW,
            recipient: maker, //  straight to the wallet — never touches Settlement
            data: data
        });
        Order memory o = Order({
            params: 0,
            pricingModule: address(0),
            maker: maker,
            nonce: 99,
            legsIn: _legsIn1Rising(USDC, feeFloor, feeCeil), // the relayer's pay
            legsOut: PackedEncode.legsOut(new LegOut[](0)), // EMPTY — nothing converts
            timing: _packTiming(uint32(block.timestamp), duration, 0) | _expiryBits(block.timestamp + 1 hours),
            exclusiveFiller: address(0),
            minFillAnchor: 0,
            curve: _noCurve(),
            items: PackedEncode.items(items),
            validators: PackedEncode.noValidators(),
            invariants: PackedEncode.noValidators(),
            fillModule: address(0),
            fillTotal: 0
        });
        bytes memory sig = _sign(o);

        uint256 aBefore = IERC20(aWETH).balanceOf(maker);
        uint256 dBefore = IERC20(usdcDebtToken).balanceOf(maker);
        uint256 solverUsdcBefore = IERC20(USDC).balanceOf(solver);

        vm.warp(block.timestamp + duration / 2); //  bump = 5000
        uint256 fee = feeFloor + (feeCeil - feeFloor) / 2; // 20 USDC

        // The anchor of an outputless SELL is the fee leg's `start`.
        vm.prank(solver);
        settlement.fill(o, sig, feeFloor);

        assertApproxEqAbs(IERC20(aWETH).balanceOf(maker) - aBefore, held, 2, "the whole wallet became collateral");
        assertEq(IERC20(WETH).balanceOf(maker), 0, "wallet swept");
        assertApproxEqAbs(IERC20(usdcDebtToken).balanceOf(maker) - dBefore, BORROW, 2, "debt drawn");
        assertEq(IERC20(USDC).balanceOf(maker), BORROW - fee, "maker keeps the borrow minus the fee");
        assertEq(IERC20(USDC).balanceOf(solver) - solverUsdcBefore, fee, "relayer earned the auction-tick fee");
        assertEq(IERC20(USDC).balanceOf(address(settlement)), 0, "settlement never held the borrow");
        assertEq(IERC20(WETH).balanceOf(address(takeForModule)), 0, "module drained");
    }
}
