// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {LegIn} from "@core/settlement/Structs.sol";
import {Order, Item, ItemOp, ItemPolicy, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {MatchRaceGuard} from "@solvers/base/MatchRaceGuard.sol";
import {MatchFlashSolver, FlashKind, FlashMatch, PoolSwap, V3Venue} from "@solvers/match/MatchFlashSolver.sol";

import {MatchFlashSolverTest} from "./MatchFlashSolver.t.sol";
import {MockFlashV3Pool, MockLeverLender, ITransferable, ISwapCb} from "./shared/FlashMatchMocks.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Review 2026-10-18 — "amount mismatches" in the flash wrapper around matchSettle.
// Every test pins ONE amount the solver borrows / pushes / repays / sweeps against
// the figure the core resolves at open. Run:
//   FOUNDRY_PROFILE=solvers forge test --match-path 'packages/solvers/test/Review20261018Flash_*' --match-test test_R
// ─────────────────────────────────────────────────────────────────────────────

/// @dev A v3-shaped venue whose pools hit their price limit half way: an exact-input
///      swap consumes only HALF of `amountSpecified` (what a real pool does when its
///      liquidity runs out before the limit), reporting the smaller input delta.
contract PartialV3Factory {
    struct Params {
        address factory;
        address token0;
        address token1;
        uint24 fee;
    }

    Params public parameters;

    function initCodeHash() external pure returns (bytes32) {
        return keccak256(type(PartialV3Pool).creationCode);
    }

    function createPool(address a, address b, uint24 fee) external returns (PartialV3Pool pool) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        parameters = Params(address(this), t0, t1, fee);
        pool = new PartialV3Pool{salt: keccak256(abi.encode(t0, t1, fee))}();
        delete parameters;
    }
}

contract PartialV3Pool {
    address public immutable factory;
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    uint256 public num = 1;
    uint256 public den = 1;

    constructor() {
        (factory, token0, token1, fee) = PartialV3Factory(msg.sender).parameters();
    }

    function setPrice(uint256 n, uint256 d) external {
        (num, den) = (n, d);
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        require(amountSpecified > 0, "exact-in only");
        (address tin, address tout) = zeroForOne ? (token0, token1) : (token1, token0);
        (uint256 n, uint256 d) = zeroForOne ? (num, den) : (den, num);
        uint256 amtIn = uint256(amountSpecified) / 2; // liquidity exhausted half way
        uint256 amtOut = (amtIn * n) / d;
        require(ITransferable(tout).transfer(recipient, amtOut), "T");
        (amount0, amount1) = zeroForOne ? (int256(amtIn), -int256(amtOut)) : (-int256(amtOut), int256(amtIn));
        uint256 before = MockERC20(tin).balanceOf(address(this));
        ISwapCb(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        require(MockERC20(tin).balanceOf(address(this)) >= before + amtIn, "IIA");
    }
}

contract Review20261018Flash_Amounts is MatchFlashSolverTest {
    function _priceBperA(MockFlashV3Pool p, address a, uint256 bPerA) internal {
        if (p.token0() == a) p.setPrice(bPerA, 1);
        else p.setPrice(1, bPerA);
    }

    // ═══════════ Q1: flash principal vs the output the core resolves at open ═══════════

    /// The off-chain figure is 1 wei UNDER the core's `outs[0][0]`: DELIVER cannot pay it
    /// out of the pushed principal — the core's transfer reverts; nothing settles.
    function test_R1_flashBelowCorePrice_deliverReverts() public {
        Order memory o = _openOrder(1);
        FlashMatch memory j = _openJob(FlashKind.UNI_V3_FLASH);
        j.flash.amount = C_OUT - 1;
        _expectRun(_guard(o), j, _openPlan(o), SafeTransferLib.TransferFailed.selector);
        assertEq(lender.debt(maker), 0, "nothing settled");
        assertEq(settlement.filled(_hashOrder(o)), 0);
    }

    /// Same under-flash when the pool already holds a stranded wei of the output token
    /// (e.g. a self-burn leg on the single-order path): DELIVER now succeeds out of the
    /// stranded balance, and the end-state floor catches it — `BatchNotWhole`. Still a
    /// revert, never a settlement funded by someone else's stranded balance.
    function test_R1_flashBelowCorePrice_strandedPoolBalance_BatchNotWhole() public {
        Order memory o = _openOrder(1);
        coll.mint(address(settlement), 1);
        FlashMatch memory j = _openJob(FlashKind.UNI_V3_FLASH);
        j.flash.amount = C_OUT - 1;
        _expectRun(_guard(o), j, _openPlan(o), abi.encodeWithSignature("BatchNotWhole(address)", address(coll)));
        assertEq(coll.balanceOf(address(settlement)), 1, "stranded wei untouched");
    }

    /// Dutch decay between simulation and inclusion: the filler previews the output at
    /// t0 (0.80) and flashes that; the tx lands at the end of the window where the core
    /// resolves 0.75. The unused 0.05 of principal round-trips through the pool and is
    /// swept back — but the pool's flash fee was charged on the FULL 0.80, so the
    /// over-flash costs 0.3% × 0.05 = 0.00015 C of the spread. Benign (profit stays
    /// above the preview-time figure because the output fell), quantified.
    function test_R2_dutchDecay_overFlash_surplusReturns_feeOnUnusedPrincipal() public {
        uint256 HI = 0.80e18;
        bytes memory data = abi.encode(_preFund(0, address(coll)), uint256(0));
        Item[] memory its = new Item[](1);
        its[0] = Item({op: ItemOp.TAKE_FOR, module: address(lender), amount: D_IN, recipient: address(0), data: data});
        Order memory o = _blank(1);
        o.legsIn = PackedEncode.oneLegIn(address(debtT), D_IN, 0);
        o.legsOut = PackedEncode.oneLegOut(address(coll), HI, C_OUT, address(lender)); // 0.80 → 0.75 over 10 min
        o.items = PackedEncode.items(its);
        o.timing = ItemPolicy.pack(o.timing, ItemPolicy.ORDERED);
        _setDecayStart(o, block.timestamp);
        _setDecayDuration(o, 600);
        _approveTaker(data, D_IN);
        _seedOpen();

        vm.warp(block.timestamp + 600); // inclusion at the end of the window
        FlashMatch memory j = _openJob(FlashKind.UNI_V3_FLASH);
        j.flash.amount = HI; // the t0 preview
        MatchPlan memory p = _plan(o, D_IN, _fundCall(new PoolSwap[](0), address(coll)), _schedule(1), address(fs));
        _run(_guard(o), j, p);

        assertEq(lender.collateral(maker), SEED_C + C_OUT, "core delivered the decayed 0.75, not the flashed 0.80");
        uint256 feeHi = _flashFee(HI, 3000);
        assertEq(coll.balanceOf(treasury), D_IN / POOL_PRICE - C_OUT - feeHi, "unused 0.05 came back; its fee did not");
        assertEq(feeHi - _flashFee(C_OUT, 3000), 0.00015e18, "cost of the over-flash: 0.3% of the unused 0.05");
        _assertClean();
    }

    /// Partial fill: the core CEILs the output slice (Pricing.sol:83) and FLOORs the
    /// input slice (:168); the TAKE_FOR item slice is the same floor (Base._prorate), so
    /// credit == owed and the plan needs no PULL. A floor-rounded flash is 1 wei short
    /// and reverts; the ceil figure fills.
    function test_R6_partialFill_coreCeilsOutput_flashMustCeilToo() public {
        Order memory o = _openOrder(1);
        uint256 fill = 1000e18 + 1; // anchor 1500e18: out = ceil(0.75e18 · fill / 1500e18) = 0.5e18 + 1
        uint256 outCeil = 0.5e18 + 1;
        uint256 owedIn = 1000e18 + 1; // floor(1500e18 · fill / 1500e18), exact here
        FlashMatch memory j = _openJob(FlashKind.UNI_V3_FLASH);
        MatchPlan memory p = _plan(o, fill, _fundCall(new PoolSwap[](0), address(coll)), _schedule(1), address(fs));

        j.flash.amount = outCeil - 1;
        _expectRun(_guard(o), j, p, SafeTransferLib.TransferFailed.selector);

        j.flash.amount = outCeil;
        _run(_guard(o), j, p);
        assertEq(lender.collateral(maker), SEED_C + outCeil, "ceil slice delivered");
        assertEq(lender.debt(maker), owedIn, "item slice == inputOwed: no PULL needed");
        assertEq(debtT.balanceOf(maker), 0, "credit == owed, no refund");
        assertEq(coll.balanceOf(treasury), owedIn / POOL_PRICE - outCeil - _flashFee(outCeil, 3000));
        _assertClean();
    }

    // ═══════════ Q2: repayment source / a token on both sides ═══════════

    /// The flash token is BOTH the order's output and its input (borrow C against a C
    /// deposit). Pool ledger: pushed 0.75 - delivered 0.75 + item credit 0.80 (== owed,
    /// stays in the pool) → sweep 0.80 to the solver → repay 0.75 + fee. No double count
    /// in either direction; the maker is refunded nothing because credit == owed.
    function test_R3_flashTokenOnBothSides_inputAndOutput_ledgerExact() public {
        MockLeverLender same =
            new MockLeverLender(address(permit3), address(settlement), address(coll), address(coll), 1, 1);
        coll.mint(address(same), 10e18);
        same.book(address(coll));
        same.seed(maker, SEED_C, 0);
        uint256 IN = 0.8e18;
        bytes memory data = abi.encode(_preFund(0, address(coll)), uint256(0));
        Item[] memory its = new Item[](1);
        its[0] = Item({op: ItemOp.TAKE_FOR, module: address(same), amount: IN, recipient: address(0), data: data});
        Order memory o = _blank(1);
        o.legsIn = PackedEncode.oneLegIn(address(coll), IN, 0);
        o.legsOut = PackedEncode.oneLegOut(address(coll), C_OUT, 0, address(same));
        o.items = PackedEncode.items(its);
        o.timing = ItemPolicy.pack(o.timing, ItemPolicy.ORDERED);
        vm.prank(maker);
        permit3.approveTaker(
            address(settlement), address(same), keccak256(data), uint160(IN), uint48(block.timestamp + 1 hours)
        );

        FlashMatch memory j = _job(FlashKind.UNI_V3_FLASH, address(coll), C_OUT, address(debtT), 3000, new PoolSwap[](0));
        MatchPlan memory p = _plan(o, IN, _fundCall(new PoolSwap[](0), address(coll)), _schedule(1), address(fs));
        (address[] memory toks, uint256[] memory profit) = _run(_guard(o), j, p);

        uint256 fee = _flashFee(C_OUT, 3000);
        assertEq(same.collateral(maker), SEED_C + C_OUT);
        assertEq(same.debt(maker), IN);
        assertEq(coll.balanceOf(treasury), IN - C_OUT - fee, "profit = owed - delivered - fee");
        assertEq(coll.balanceOf(maker), 0, "credit == owed: no refund");
        assertEq(coll.balanceOf(address(settlement)), 0, "pool flat");
        assertEq(toks.length, 2);
        assertEq(profit[0], IN - C_OUT - fee);
        _assertClean();
    }

    /// The SDK plan ({buildFlashMatchPlan}) carries NO PULL step: an item that credits
    /// the input leg 1 wei short of `owed` (venue rounding on a real withdraw/borrow)
    /// reverts `LegUnfunded` — the whole plan, every time. Appending PULL(0,0) after
    /// the items draws exactly the shortfall from the maker's wallet instead.
    function test_R7_itemUnderProducesOwed_noPullReverts_pullStepDrawsShortfall() public {
        bytes memory data = abi.encode(_preFund(0, address(coll)), uint256(0));
        Item[] memory its = new Item[](1);
        its[0] =
            Item({op: ItemOp.TAKE_FOR, module: address(lender), amount: D_IN - 1, recipient: address(0), data: data});
        Order memory o = _order(1, address(debtT), D_IN, address(coll), C_OUT, its);
        _approveTaker(data, D_IN);
        _seedOpen();
        MatchPlan memory p = _openPlan(o);
        _expectRun(
            _guard(o), _openJob(FlashKind.UNI_V3_FLASH), p, abi.encodeWithSignature("LegUnfunded(uint256,uint256)", 0, 0)
        );

        debtT.mint(maker, 1);
        _makerApprove(address(settlement), address(debtT), 1);
        uint256[] memory s = new uint256[](4);
        s[0] = MatchStep.pack(MatchStep.CALL, 0, 0);
        s[1] = MatchStep.pack(MatchStep.DELIVER, 0, 0);
        s[2] = MatchStep.pack(MatchStep.ITEM, 0, 0);
        s[3] = MatchStep.pack(MatchStep.PULL, 0, 0);
        p.schedule = s;
        _run(_guard(o), _openJob(FlashKind.UNI_V3_FLASH), p);
        assertEq(debtT.balanceOf(maker), 0, "the 1-wei shortfall was pulled");
        assertEq(lender.debt(maker), D_IN - 1);
        assertEq(coll.balanceOf(treasury), D_IN / POOL_PRICE - C_OUT - _flashFee(C_OUT, 3000));
        _assertClean();
    }

    /// F-4: the SDK plan now ends in PULL(0, j) per input leg. When the items credit the
    /// leg in full that PULL draws `owed − credit = 0` — no transfer, no Permit3 call, so
    /// a maker with NO wallet approval still fills, and the outcome equals the PULL-less plan.
    function test_R7b_trailingPull_isANoOpWhenItemsCreditInFull() public {
        Order memory o = _openOrder(1);
        MatchPlan memory p = _openPlan(o);
        uint256[] memory s = new uint256[](4);
        (s[0], s[1], s[2]) = (p.schedule[0], p.schedule[1], p.schedule[2]);
        s[3] = MatchStep.pack(MatchStep.PULL, 0, 0);
        p.schedule = s;
        _run(_guard(o), _openJob(FlashKind.UNI_V3_FLASH), p);
        _assertOpened();
        assertEq(coll.balanceOf(treasury), D_IN / POOL_PRICE - C_OUT - _flashFee(C_OUT, 3000));
        _assertClean();
    }

    // ═══════════ Q3: floors — which token, and can the maker's inflow satisfy them ═══════════

    /// S3 class (2026-10-05 §1): the maker pays a second input leg IN THE FLASH TOKEN
    /// (0.05 C from the wallet). The route alone is short of the repayment (1500 D at
    /// 2100 → 0.7143 C < 0.75225 owed); the maker's 0.05 C covers it.
    ///   • `swaps[].minOut` is measured on the pool's reported output delta, so with the
    ///     filler's floor (`repayAmount`) it reverts `SwapBelowMin` regardless of the
    ///     maker's inflow — the route floor is NOT lifted by the inflow (unlike the
    ///     pre-fix AggregatorFillSolver).
    ///   • With minOut = 0 the fill goes through and `minProfit` sees the NET sweep —
    ///     route + maker inflow - repayment — which is the operator's real P&L in C.
    function test_R8_makerInflowInFlashToken_doesNotLiftRouteFloor_butIsRealProfit() public {
        uint256 CIN = 0.05e18;
        bytes memory data = abi.encode(_preFund(0, address(coll)), uint256(0));
        Item[] memory its = new Item[](1);
        its[0] = Item({op: ItemOp.TAKE_FOR, module: address(lender), amount: D_IN, recipient: address(0), data: data});
        LegIn[] memory li = new LegIn[](2);
        li[0] = LegIn(address(debtT), D_IN, 0);
        li[1] = LegIn(address(coll), CIN, 0);
        Order memory o = _blank(1);
        o.legsIn = PackedEncode.legsIn(li);
        o.legsOut = PackedEncode.oneLegOut(address(coll), C_OUT, 0, address(lender));
        o.items = PackedEncode.items(its);
        o.timing = ItemPolicy.pack(o.timing, ItemPolicy.ORDERED);
        _approveTaker(data, D_IN);
        _seedOpen();
        coll.mint(maker, CIN);
        _makerApprove(address(settlement), address(coll), CIN);
        _price(swapPool, 2100); // route alone: 1500/2100 = 0.714285… C < 0.75225 owed

        uint256[] memory s = new uint256[](4);
        s[0] = MatchStep.pack(MatchStep.CALL, 0, 0);
        s[1] = MatchStep.pack(MatchStep.DELIVER, 0, 0);
        s[2] = MatchStep.pack(MatchStep.ITEM, 0, 0);
        s[3] = MatchStep.pack(MatchStep.PULL, 0, 1);
        MatchPlan memory p = _plan(o, D_IN, _fundCall(new PoolSwap[](0), address(coll)), s, address(fs));

        uint256 fee = _flashFee(C_OUT, 3000);
        uint256 routeOut = D_IN / 2100;
        // (a) the filler's floor on the swap: route output alone, maker inflow does not count
        FlashMatch memory j = _openJob(FlashKind.UNI_V3_FLASH);
        j.swaps[0].minOut = C_OUT + fee;
        _expectRun(
            _guard(o), j, p, abi.encodeWithSelector(MatchFlashSolver.SwapBelowMin.selector, routeOut, C_OUT + fee)
        );
        // (b) no route floor: the maker's 0.05 C funds the repayment and is real profit
        j.swaps[0].minOut = 0;
        j.minProfit = new MatchRaceGuard.SweptFloor[](1);
        j.minProfit[0] = MatchRaceGuard.SweptFloor({token: address(coll), min: routeOut + CIN - C_OUT - fee});
        (, uint256[] memory profit) = _run(_guard(o), j, p);
        assertEq(profit[0], routeOut + CIN - C_OUT - fee, "net sweep = route + maker inflow - repayment");
        assertLt(routeOut, C_OUT + fee, "the route alone could not repay");
        assertEq(coll.balanceOf(maker), 0);
        _assertClean();
    }

    /// `minProfit` is a floor on the SWEPT BALANCE, not on the fill's P&L: a wei parked
    /// on the solver by anyone before the call satisfies `expected + 1` (which reverts
    /// without it — `test_minProfit_floor_reverts`). Benign: the recipient still
    /// receives ≥ floor; the parked wei is the donor's loss.
    function test_R4_minProfitFloor_isTheSweptBalance_notTheFillPnL() public {
        Order memory o = _openOrder(1);
        FlashMatch memory j = _openJob(FlashKind.UNI_V3_FLASH);
        uint256 expected = D_IN / POOL_PRICE - C_OUT - _flashFee(C_OUT, 3000);
        j.minProfit = new MatchRaceGuard.SweptFloor[](1);
        j.minProfit[0] = MatchRaceGuard.SweptFloor({token: address(coll), min: expected + 1});
        coll.mint(address(fs), 1);
        (, uint256[] memory profit) = _run(_guard(o), j, _openPlan(o));
        assertEq(profit[0], expected + 1, "floor met by the parked wei; the fill earned `expected`");
        assertEq(coll.balanceOf(treasury), expected + 1);
    }

    // ═══════════ Q4: residue ═══════════

    /// A MID-PLAN multi-hop swap ({onMatchStep}) through a thin pool: the second hop
    /// consumes only half its input (price limit hit). Before the F-3 fix `_hop` did not
    /// check consumed == amountIn and the intermediate token — in no sweep set (not a
    /// leg, not a `job.swaps` path token, not `extraSweep`) — stayed on the solver: 750
    /// MID parked after a call that reported 0 profit. Now every hop is exact-input or
    /// the whole call reverts {MatchFlashSolver.PartialSwap}.
    MatchFlashSolver internal fs2;
    MockERC20 internal mid;

    /// Venue 0 = the normal factory (D/MID 1:1), venue 1 = the thin factory (MID/C at
    /// 1000 MID per C, consumes half); a Balancer source holding D.
    function _thinSetup() internal {
        PartialV3Factory pf = new PartialV3Factory();
        V3Venue[] memory v = new V3Venue[](2);
        v[0] = V3Venue({factory: address(factory), initCodeHash: factory.initCodeHash()});
        v[1] = V3Venue({factory: address(pf), initCodeHash: pf.initCodeHash()});
        fs2 = new MatchFlashSolver(address(settlement), _ops(operator), v, _providers());
        mid = tC;
        MockFlashV3Pool dm = factory.createPool(address(debtT), address(mid), 500);
        _priceBperA(dm, address(debtT), 1);
        mid.mint(address(dm), 1_000_000e18);
        PartialV3Pool mc = pf.createPool(address(mid), address(coll), 500);
        if (mc.token0() == address(mid)) mc.setPrice(1, 1000);
        else mc.setPrice(1000, 1);
        coll.mint(address(mc), 1_000e18);
        debtT.mint(address(balancer), 10_000e18);
    }

    function _thinPath() internal view returns (bytes memory) {
        return abi.encodePacked(address(debtT), uint24(500), uint8(0), address(mid), uint24(500), uint8(1), address(coll));
    }

    function test_R5_midPlanHop_partialConsumption_reverts() public {
        _thinSetup();
        Order memory o = _openOrder(1);
        MatchPlan memory p =
            _plan(o, D_IN, _fundCall(_swaps1(_thinPath(), 0, C_OUT), address(coll)), _schedule(1), address(fs2));
        FlashMatch memory j = _job(FlashKind.BALANCER_V2, address(debtT), D_IN, address(0), 0, new PoolSwap[](0));
        vm.prank(operator);
        (bool ok, bytes memory ret) = address(fs2).call(abi.encodeCall(fs2.executeMatch, (_guard(o), j, p)));
        assertFalse(ok, "a partially consumed hop reverts the whole call");
        assertTrue(_contains(ret, abi.encodeWithSelector(MatchFlashSolver.PartialSwap.selector, 750e18, 1500e18)));
        assertEq(mid.balanceOf(address(fs2)), 0, "nothing parked on the solver");
    }

    /// `needle` appears in `hay` (the PartialSwap is wrapped by the core's CALL step).
    function _contains(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        if (needle.length > hay.length) return false;
        for (uint256 i; i + needle.length <= hay.length; ++i) {
            bool m = true;
            for (uint256 k; k < needle.length; ++k) {
                if (hay[i + k] != needle[k]) {
                    m = false;
                    break;
                }
            }
            if (m) return true;
        }
        return false;
    }
}
