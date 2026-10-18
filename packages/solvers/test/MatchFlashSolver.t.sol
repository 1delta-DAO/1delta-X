// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {MockSettlementBase, MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";

import {Order, Item, ItemOp, ItemPolicy, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";
import {MatchRaceGuard} from "@solvers/base/MatchRaceGuard.sol";
import {
    MatchFlashSolver,
    FlashKind,
    FlashSource,
    FlashMatch,
    FlashProviders,
    PoolSwap,
    RaceCheck,
    V3Venue
} from "@solvers/match/MatchFlashSolver.sol";

import {
    MockFlashV3Factory,
    MockFlashV3Pool,
    MockBalancerVault,
    MockAavePool,
    MockMorpho,
    MockEulerVault,
    MockLeverLender,
    HookToken,
    RoguePool
} from "./shared/FlashMatchMocks.sol";

/// @title MatchFlashSolverTest
/// @notice The cycle class (review 2026-10-18 S-4) filled with ZERO filler capital: a
///         flash around `matchSettle`, repaid from the plan's own proceeds. Real
///         Settlement + Permit3; a lender whose borrow is health-checked against the
///         deposit, so every shape below is a genuine cycle ({test_cycle_isUnfillableWithoutFlash}).
///
///  Shapes: leverage open as one ORDERED pre-funded TAKE_FOR (fused deposit+borrow),
///  the two-item edge open (pre-funded MAKE then TAKE), the fused close (repay+withdraw
///  TAKE_FOR), each via v3 `flash()`, the v3 flash swap, and the four fixed-address /
///  per-call providers. Then the callback gates, the repayment floor, the sweep, and
///  the no-allowance-left invariant.
contract MatchFlashSolverTest is MockSettlementBase {
    MockERC20 coll; // the collateral the maker receives (flash asset on an open)
    MockERC20 debtT; // the debt the maker sells (flash asset on a close)

    MockFlashV3Factory factory;
    MockFlashV3Pool swapPool; //  COLL/DEBT 0.05% — the repayment swap
    MockFlashV3Pool flashPool; // COLL/DEBT 0.3%  — the flash source
    MockLeverLender lender;
    MockBalancerVault balancer;
    MockAavePool aave;
    MockMorpho morpho;
    MockEulerVault eVault;
    MatchFlashSolver fs;

    address operator = address(0x0B0B);
    address treasury = address(0x7EA5);

    uint256 constant POOL_PRICE = 1950; // DEBT per COLL on both pools (lender oracle: 2000)
    uint256 constant D_IN = 1500e18; //   open: the maker sells this much new debt
    uint256 constant C_OUT = 0.75e18; //  open: … for this much new collateral
    uint256 constant SEED_C = 0.5e18; //  open: existing collateral (max borrow 800 < 1500)

    uint256 constant CLOSE_COLL = 1e18; //  close: the whole position's collateral
    uint256 constant CLOSE_DEBT = 1500e18; // close: … and its whole debt
    uint256 constant CLOSE_PAY = 0.8e18; // close: collateral paid to the filler (0.2 back)

    function setUp() public override {
        super.setUp();
        coll = tB;
        debtT = tA;
        vm.label(address(coll), "COLL");
        vm.label(address(debtT), "DEBT");

        factory = new MockFlashV3Factory();
        swapPool = factory.createPool(address(coll), address(debtT), 500);
        flashPool = factory.createPool(address(coll), address(debtT), 3000);
        _price(swapPool, POOL_PRICE);
        _price(flashPool, POOL_PRICE);
        _fundPool(swapPool);
        _fundPool(flashPool);

        lender = new MockLeverLender(address(permit3), address(settlement), address(coll), address(debtT), 2000, 1);
        debtT.mint(address(lender), 10_000_000e18);
        lender.book(address(debtT));

        balancer = new MockBalancerVault();
        aave = new MockAavePool();
        morpho = new MockMorpho();
        eVault = new MockEulerVault(address(coll));
        coll.mint(address(balancer), 100e18);
        coll.mint(address(aave), 100e18);
        coll.mint(address(morpho), 100e18);
        coll.mint(address(eVault), 100e18);

        fs = _deploy(_ops(operator), _venues(address(factory)));
    }

    // ═══════════════════════════ helpers ═══════════════════════════

    function _ops(address a) internal pure returns (address[] memory o) {
        o = new address[](1);
        o[0] = a;
    }

    function _venues(address f) internal view returns (V3Venue[] memory v) {
        v = new V3Venue[](1);
        v[0] = V3Venue({factory: f, initCodeHash: factory.initCodeHash()});
    }

    function _providers() internal view returns (FlashProviders memory) {
        return FlashProviders({balancerVault: address(balancer), aavePool: address(aave), morpho: address(morpho)});
    }

    function _deploy(address[] memory ops, V3Venue[] memory venues) internal returns (MatchFlashSolver) {
        return new MatchFlashSolver(address(settlement), ops, venues, _providers());
    }

    function _price(MockFlashV3Pool p, uint256 debtPerColl) internal {
        if (p.token0() == address(coll)) p.setPrice(debtPerColl, 1);
        else p.setPrice(1, debtPerColl);
    }

    function _fundPool(MockFlashV3Pool p) internal {
        coll.mint(address(p), 1_000e18);
        debtT.mint(address(p), 10_000_000e18);
    }

    /// @dev `forLegPreFund(j, token)`: bit 255 | bit 253 | token at [16, 176) | leg j.
    function _preFund(uint256 j, address token) internal pure returns (uint256) {
        return (uint256(5) << 253) | (uint256(uint160(token)) << 16) | j;
    }

    function _order(uint256 nonce, address tIn, uint256 amtIn, address tOut, uint256 amtOut, Item[] memory items)
        internal
        view
        returns (Order memory o)
    {
        o = _blank(nonce);
        o.legsIn = PackedEncode.oneLegIn(tIn, amtIn, 0);
        // Delivered straight to the lender: the PRE-FUNDED shape (no maker approval of a
        // token the maker never held).
        o.legsOut = PackedEncode.oneLegOut(tOut, amtOut, 0, address(lender));
        o.items = PackedEncode.items(items);
        o.timing = ItemPolicy.pack(o.timing, ItemPolicy.ORDERED);
    }

    function _approveTaker(bytes memory data, uint256 cap) internal {
        vm.prank(maker);
        permit3.approveTaker(
            address(settlement), address(lender), keccak256(data), uint160(cap), uint48(block.timestamp + 1 hours)
        );
    }

    function _seedOpen() internal {
        coll.mint(address(lender), SEED_C);
        lender.book(address(coll));
        lender.seed(maker, SEED_C, 0);
    }

    /// @dev Leverage open, FUSED: one ORDERED pre-funded TAKE_FOR — deposit the delivered
    ///      COLL, borrow D_IN DEBT into the pool.
    function _openOrder(uint256 nonce) internal returns (Order memory o) {
        bytes memory data = abi.encode(_preFund(0, address(coll)), uint256(0));
        Item[] memory its = new Item[](1);
        its[0] = Item({op: ItemOp.TAKE_FOR, module: address(lender), amount: D_IN, recipient: address(0), data: data});
        o = _order(nonce, address(debtT), D_IN, address(coll), C_OUT, its);
        _approveTaker(data, D_IN);
        _seedOpen();
    }

    /// @dev Leverage close, FUSED: one ORDERED pre-funded TAKE_FOR — repay with the
    ///      delivered DEBT, withdraw all COLL into the pool (0.2 of it refunded).
    function _closeOrder(uint256 nonce) internal returns (Order memory o) {
        coll.mint(address(lender), CLOSE_COLL);
        lender.book(address(coll));
        lender.seed(maker, CLOSE_COLL, CLOSE_DEBT);
        bytes memory data = abi.encode(_preFund(0, address(debtT)), uint256(1));
        Item[] memory its = new Item[](1);
        its[0] =
            Item({op: ItemOp.TAKE_FOR, module: address(lender), amount: CLOSE_COLL, recipient: address(0), data: data});
        o = _order(nonce, address(coll), CLOSE_PAY, address(debtT), CLOSE_DEBT, its);
        _approveTaker(data, CLOSE_COLL);
    }

    function _schedule(uint256 nItems) internal pure returns (uint256[] memory s) {
        s = new uint256[](2 + nItems);
        s[0] = MatchStep.pack(MatchStep.CALL, 0, 0); // inject the flash principal
        s[1] = MatchStep.pack(MatchStep.DELIVER, 0, 0);
        for (uint256 k; k < nItems; k++) {
            s[2 + k] = MatchStep.pack(MatchStep.ITEM, 0, k);
        }
    }

    function _fundCall(PoolSwap[] memory swaps, address token) internal pure returns (bytes memory) {
        address[] memory t = new address[](1);
        t[0] = token;
        uint256[] memory a = new uint256[](1);
        a[0] = type(uint256).max;
        return abi.encodeCall(MatchFlashSolver.onMatchStep, (swaps, t, a));
    }

    function _plan(Order memory o, uint256 fill, bytes memory callData, uint256[] memory schedule, address target)
        internal
        view
        returns (MatchPlan memory p)
    {
        Order[] memory orders = new Order[](1);
        orders[0] = o;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(o);
        uint256[] memory fills = new uint256[](1);
        fills[0] = fill;
        address[] memory targets = new address[](1);
        targets[0] = target;
        bytes[] memory datas = new bytes[](1);
        datas[0] = callData;
        p = MatchPlan({
            orders: orders,
            sigs: sigs,
            fillAmounts: fills,
            takerDatas: new bytes[](0),
            schedule: schedule,
            callTargets: targets,
            callDatas: datas,
            profitRecipient: address(0)
        });
    }

    function _openPlan(Order memory o) internal view returns (MatchPlan memory) {
        return _plan(o, D_IN, _fundCall(new PoolSwap[](0), address(coll)), _schedule(1), address(fs));
    }

    function _hop(address a, uint24 fee, uint8 venue, address b) internal pure returns (bytes memory) {
        return abi.encodePacked(a, fee, venue, b);
    }

    function _swaps1(bytes memory path, uint256 amountIn, uint256 minOut) internal pure returns (PoolSwap[] memory s) {
        s = new PoolSwap[](1);
        s[0] = PoolSwap({path: path, amountIn: amountIn, minOut: minOut});
    }

    function _job(FlashKind kind, address token, uint256 amount, address pair, uint24 fee, PoolSwap[] memory swaps)
        internal
        view
        returns (FlashMatch memory j)
    {
        j.flash = FlashSource({
            kind: kind,
            token: token,
            amount: amount,
            pairToken: pair,
            fee: fee,
            venue: 0,
            vault: address(0),
            maxRepay: 0
        });
        j.swaps = swaps;
        j.recipient = treasury;
        j.extraSweep = new address[](0);
        j.minProfit = new MatchRaceGuard.SweptFloor[](0);
    }

    /// @dev Flash COLL from `kind`, swap the borrowed DEBT → COLL on the 0.05% pool.
    function _openJob(FlashKind kind) internal view returns (FlashMatch memory) {
        return _job(
            kind, address(coll), C_OUT, address(debtT), 3000, _swaps1(_hop(address(debtT), 500, 0, address(coll)), 0, 0)
        );
    }

    function _guard(Order memory o) internal pure returns (RaceCheck memory g) {
        g.orderHashes = new bytes32[](1);
        g.orderHashes[0] = _hashOrder(o);
        g.expectedFilled = new uint256[](1);
        g.nonceMakers = new address[](0);
        g.nonces = new uint256[](0);
    }

    function _noGuard() internal pure returns (RaceCheck memory g) {
        g.orderHashes = new bytes32[](0);
        g.expectedFilled = new uint256[](0);
        g.nonceMakers = new address[](0);
        g.nonces = new uint256[](0);
    }

    function _run(RaceCheck memory g, FlashMatch memory j, MatchPlan memory p)
        internal
        returns (address[] memory, uint256[] memory)
    {
        vm.prank(operator);
        return fs.executeMatch(g, j, p);
    }

    function _expectRun(RaceCheck memory g, FlashMatch memory j, MatchPlan memory p, bytes memory err) internal {
        vm.prank(operator);
        vm.expectRevert(err);
        fs.executeMatch(g, j, p);
    }

    function _expectRun(RaceCheck memory g, FlashMatch memory j, MatchPlan memory p, bytes4 err) internal {
        _expectRun(g, j, p, abi.encodePacked(err));
    }

    function _expectAnyRevert(RaceCheck memory g, FlashMatch memory j, MatchPlan memory p) internal {
        vm.prank(operator);
        vm.expectRevert();
        fs.executeMatch(g, j, p);
    }

    function _expectRunPartial(RaceCheck memory g, FlashMatch memory j, MatchPlan memory p, bytes4 err) internal {
        vm.prank(operator);
        vm.expectPartialRevert(err);
        fs.executeMatch(g, j, p);
    }

    function _flashFee(uint256 amount, uint256 fee) internal pure returns (uint256) {
        return (amount * fee + 1e6 - 1) / 1e6;
    }

    /// @dev Zero balance and zero allowance to every party, on every token.
    function _assertClean() internal view {
        address[2] memory toks = [address(coll), address(debtT)];
        address[9] memory spenders = [
            address(settlement),
            address(permit3),
            address(settlement.EXECUTOR()),
            address(swapPool),
            address(flashPool),
            address(balancer),
            address(aave),
            address(morpho),
            address(eVault)
        ];
        for (uint256 t; t < toks.length; t++) {
            assertEq(MockERC20(toks[t]).balanceOf(address(fs)), 0, "solver holds nothing");
            assertEq(MockERC20(toks[t]).balanceOf(address(settlement)), 0, "pool flat");
            for (uint256 s; s < spenders.length; s++) {
                assertEq(MockERC20(toks[t]).allowance(address(fs), spenders[s]), 0, "no allowance survives");
            }
        }
    }

    function _assertOpened() internal view {
        assertEq(lender.collateral(maker), SEED_C + C_OUT, "the delivered collateral was deposited");
        assertEq(lender.debt(maker), D_IN, "the debt was opened");
        assertEq(coll.balanceOf(maker), 0, "maker wallet: no COLL");
        assertEq(debtT.balanceOf(maker), 0, "maker wallet: no DEBT");
    }

    // ═══════════════════════════ the cycle class ═══════════════════════════

    /// The control: the same plan with nothing fronting the delivery cannot settle, and
    /// the borrow cannot be hoisted ahead of the deposit. It IS a cycle.
    function test_cycle_isUnfillableWithoutFlash() public {
        Order memory o = _openOrder(1);
        uint256[] memory s = new uint256[](2);
        s[0] = MatchStep.pack(MatchStep.DELIVER, 0, 0);
        s[1] = MatchStep.pack(MatchStep.ITEM, 0, 0);
        MatchPlan memory p = _plan(o, D_IN, "", s, address(fs));
        p.callTargets = new address[](0);
        p.callDatas = new bytes[](0);
        vm.prank(solver);
        vm.expectRevert(); // the pool holds no COLL to deliver
        settlement.matchSettle(p);
        // and a plain borrow-first is refused by the lender's health check
        vm.prank(address(permit3));
        vm.expectRevert(bytes("unhealthy"));
        lender.takeOnBehalf(maker, D_IN, address(this), "");
    }

    /// Leverage open (ORDERED pre-funded TAKE_FOR), flashed from a v3 pool's `flash()`,
    /// repaid by swapping the borrowed DEBT on a second pool.
    function test_leverageOpen_takeFor_v3Flash_zeroCapital() public {
        Order memory o = _openOrder(1);
        uint256 poolBefore = coll.balanceOf(address(flashPool));
        uint256 fee = _flashFee(C_OUT, 3000);

        (address[] memory toks, uint256[] memory profit) =
            _run(_guard(o), _openJob(FlashKind.UNI_V3_FLASH), _openPlan(o));

        _assertOpened();
        assertEq(coll.balanceOf(address(flashPool)), poolBefore + fee, "flash repaid with its fee");
        uint256 expected = D_IN / POOL_PRICE - C_OUT - fee;
        assertEq(coll.balanceOf(treasury), expected, "the spread, in the flash asset");
        assertEq(debtT.balanceOf(treasury), 0, "all DEBT went to the repayment swap");
        assertEq(toks.length, 2, "sweep set: COLL, DEBT");
        assertEq(toks[0], address(coll));
        assertEq(profit[0], expected);
        assertEq(settlement.filled(_hashOrder(o)), D_IN, "order filled");
        _assertClean();
    }

    /// The same open through a v3 FLASH SWAP: one pool fronts the COLL and is paid in
    /// DEBT inside its own swap callback — no second pool, no flash fee.
    function test_leverageOpen_takeFor_v3FlashSwap_zeroCapital() public {
        Order memory o = _openOrder(1);
        FlashMatch memory j = _job(FlashKind.UNI_V3_SWAP, address(coll), C_OUT, address(debtT), 500, new PoolSwap[](0));
        _run(_guard(o), j, _openPlan(o));

        _assertOpened();
        uint256 owed = C_OUT * POOL_PRICE; // exact at this price
        assertEq(debtT.balanceOf(treasury), D_IN - owed, "the spread, in the repayment token");
        assertEq(coll.balanceOf(treasury), 0);
        _assertClean();
    }

    /// The edge open as TWO items — a pre-funded MAKE (deposit) then a TAKE (borrow) —
    /// with no headroom for the borrow until the deposit lands.
    function test_leverageOpen_edge_makeThenTake_zeroCapital() public {
        bytes memory makeData = abi.encode(_preFund(0, address(coll)));
        bytes memory takeData = abi.encode(uint256(0xB0));
        Item[] memory its = new Item[](2);
        its[0] = Item({op: ItemOp.MAKE, module: address(lender), amount: 0, recipient: address(0), data: makeData});
        its[1] = Item({op: ItemOp.TAKE, module: address(lender), amount: D_IN, recipient: address(0), data: takeData});
        Order memory o = _order(1, address(debtT), D_IN, address(coll), C_OUT, its);
        _approveTaker(takeData, D_IN);
        _seedOpen();

        MatchPlan memory p = _plan(o, D_IN, _fundCall(new PoolSwap[](0), address(coll)), _schedule(2), address(fs));
        _run(_guard(o), _openJob(FlashKind.UNI_V3_FLASH), p);

        _assertOpened();
        assertEq(coll.balanceOf(treasury), D_IN / POOL_PRICE - C_OUT - _flashFee(C_OUT, 3000));
        _assertClean();
    }

    /// Fused composite CLOSE: flash the DEBT, deliver it to the lender, the item repays
    /// and withdraws everything, the filler's COLL share repays the flash.
    function test_fusedClose_v3Flash_zeroCapital() public {
        Order memory o = _closeOrder(1);
        MatchPlan memory p =
            _plan(o, CLOSE_PAY, _fundCall(new PoolSwap[](0), address(debtT)), _schedule(1), address(fs));
        FlashMatch memory j = _job(
            FlashKind.UNI_V3_FLASH,
            address(debtT),
            CLOSE_DEBT,
            address(coll),
            3000,
            _swaps1(_hop(address(coll), 500, 0, address(debtT)), 0, 0)
        );
        _run(_guard(o), j, p);

        assertEq(lender.debt(maker), 0, "debt repaid");
        assertEq(lender.collateral(maker), 0, "collateral withdrawn");
        assertEq(coll.balanceOf(maker), CLOSE_COLL - CLOSE_PAY, "the maker keeps the rest of its collateral");
        uint256 expected = CLOSE_PAY * POOL_PRICE - CLOSE_DEBT - _flashFee(CLOSE_DEBT, 3000);
        assertEq(debtT.balanceOf(treasury), expected, "the spread, in DEBT");
        _assertClean();
    }

    /// A swap INSIDE the plan: flash DEBT, convert it to the delivered COLL in the CALL
    /// step ({onMatchStep} swaps then funds), repay the DEBT from the borrow.
    function test_midPlanSwap_inCallStep() public {
        Order memory o = _openOrder(1);
        uint256 flashD = 1470e18;
        bytes memory callData = _fundCall(_swaps1(_hop(address(debtT), 500, 0, address(coll)), 0, C_OUT), address(coll));
        MatchPlan memory p = _plan(o, D_IN, callData, _schedule(1), address(fs));
        FlashMatch memory j =
            _job(FlashKind.UNI_V3_FLASH, address(debtT), flashD, address(coll), 3000, new PoolSwap[](0));
        _run(_guard(o), j, p);

        _assertOpened();
        assertEq(debtT.balanceOf(treasury), D_IN - flashD - _flashFee(flashD, 3000), "DEBT spread");
        assertEq(coll.balanceOf(treasury), flashD / POOL_PRICE - C_OUT, "the COLL over-funding came back");
        _assertClean();
    }

    // ═══════════════════════════ providers ═══════════════════════════

    function _assertProviderOpen(FlashKind kind, uint256 fee) internal {
        Order memory o = _openOrder(1);
        FlashMatch memory j = _openJob(kind);
        if (kind == FlashKind.EULER) j.flash.vault = address(eVault);
        _run(_guard(o), j, _openPlan(o));
        _assertOpened();
        assertEq(coll.balanceOf(treasury), D_IN / POOL_PRICE - C_OUT - fee);
        _assertClean();
    }

    function test_provider_balancer() public {
        _assertProviderOpen(FlashKind.BALANCER_V2, 0);
    }

    function test_provider_balancer_withFee() public {
        balancer.setFeeBps(10);
        _assertProviderOpen(FlashKind.BALANCER_V2, (C_OUT * 10) / 10_000);
    }

    function test_provider_aave_approvalPulledAndCleared() public {
        _assertProviderOpen(FlashKind.AAVE_V3, (C_OUT * aave.PREMIUM_BPS()) / 10_000);
    }

    function test_provider_morpho_approvalPulledAndCleared() public {
        _assertProviderOpen(FlashKind.MORPHO, 0);
    }

    function test_provider_euler() public {
        _assertProviderOpen(FlashKind.EULER, 0);
    }

    function test_provider_disabled() public {
        MatchFlashSolver bare = new MatchFlashSolver(
            address(settlement),
            _ops(operator),
            _venues(address(factory)),
            FlashProviders(address(0), address(0), address(0))
        );
        Order memory o = _openOrder(1);
        MatchPlan memory p = _plan(o, D_IN, _fundCall(new PoolSwap[](0), address(coll)), _schedule(1), address(bare));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(MatchFlashSolver.ProviderDisabled.selector, FlashKind.MORPHO));
        bare.executeMatch(_guard(o), _openJob(FlashKind.MORPHO), p);
    }

    // ═══════════════════════════ repayment ═══════════════════════════

    /// The swap no longer covers flash + fee: the whole transaction reverts.
    function test_repayShortfall_reverts() public {
        Order memory o = _openOrder(1);
        _price(swapPool, 2100); // 1500 DEBT → 0.714 COLL < 0.75225 owed
        _expectRunPartial(
            _guard(o), _openJob(FlashKind.UNI_V3_FLASH), _openPlan(o), MatchFlashSolver.FlashNotRepaid.selector
        );
        assertEq(lender.debt(maker), 0, "nothing settled");
    }

    function test_flashSwap_maxRepay_reverts() public {
        Order memory o = _openOrder(1);
        FlashMatch memory j = _job(FlashKind.UNI_V3_SWAP, address(coll), C_OUT, address(debtT), 500, new PoolSwap[](0));
        j.flash.maxRepay = C_OUT * POOL_PRICE - 1;
        _expectRun(
            _guard(o),
            j,
            _openPlan(o),
            abi.encodeWithSelector(MatchFlashSolver.RepayAboveMax.selector, C_OUT * POOL_PRICE, C_OUT * POOL_PRICE - 1)
        );
    }

    function test_minProfit_floor_reverts() public {
        Order memory o = _openOrder(1);
        FlashMatch memory j = _openJob(FlashKind.UNI_V3_FLASH);
        uint256 expected = D_IN / POOL_PRICE - C_OUT - _flashFee(C_OUT, 3000);
        j.minProfit = new MatchRaceGuard.SweptFloor[](1);
        j.minProfit[0] = MatchRaceGuard.SweptFloor({token: address(coll), min: expected + 1});
        _expectRun(
            _guard(o),
            j,
            _openPlan(o),
            abi.encodeWithSelector(MatchRaceGuard.SweptShort.selector, address(coll), expected + 1, expected)
        );
    }

    function test_swapMinOut_reverts() public {
        Order memory o = _openOrder(1);
        FlashMatch memory j = _openJob(FlashKind.UNI_V3_FLASH);
        j.swaps[0].minOut = 1e18;
        _expectRunPartial(_guard(o), j, _openPlan(o), MatchFlashSolver.SwapBelowMin.selector);
    }

    /// A pool is locked through its own flash: flash and repay-swap on the SAME pool
    /// reverts — the reason UNI_V3_SWAP exists.
    function test_flashAndSwapOnSamePool_reverts_LOK() public {
        Order memory o = _openOrder(1);
        FlashMatch memory j = _openJob(FlashKind.UNI_V3_FLASH);
        j.flash.fee = 500; // the swap pool
        _expectRun(_guard(o), j, _openPlan(o), bytes("LOK"));
    }

    // ═══════════════════════════ callback authentication ═══════════════════════════

    /// Every callback, called cold, pays nobody.
    function test_unsolicitedCallbacks_revert() public {
        bytes memory junk = abi.encode(uint256(1));
        vm.expectRevert(MatchFlashSolver.NotArmed.selector);
        fs.uniswapV3FlashCallback(0, 0, junk);
        vm.expectRevert(MatchFlashSolver.NotArmed.selector);
        fs.uniswapV3SwapCallback(1, -1, junk);
        vm.expectRevert(MatchFlashSolver.NotArmed.selector);
        fs.receiveFlashLoan(new address[](0), new uint256[](0), new uint256[](0), junk);
        vm.expectRevert(MatchFlashSolver.NotArmed.selector);
        fs.executeOperation(address(coll), 1, 0, address(fs), junk);
        vm.expectRevert(MatchFlashSolver.NotArmed.selector);
        fs.onMorphoFlashLoan(1, junk);
        vm.expectRevert(MatchFlashSolver.NotArmed.selector);
        fs.onFlashLoan(junk);

        address[] memory t = new address[](1);
        t[0] = address(coll);
        uint256[] memory a = new uint256[](1);
        a[0] = type(uint256).max;
        vm.expectRevert(MatchFlashSolver.OnlyExecutor.selector);
        fs.onMatchStep(new PoolSwap[](0), t, a);
        vm.prank(address(settlement.EXECUTOR()));
        vm.expectRevert(MatchFlashSolver.NotArmed.selector);
        fs.onMatchStep(new PoolSwap[](0), t, a);
    }

    /// The EXECUTOR is a public trampoline: anyone's `matchSettle` CALL step can make it
    /// call {onMatchStep}. Outside this contract's own settlement that pays nothing.
    function test_onMatchStep_fromForeignPlan_reverts() public {
        coll.mint(address(fs), 1e18); // bait
        uint256[] memory s = new uint256[](1);
        s[0] = MatchStep.pack(MatchStep.CALL, 0, 0);
        address[] memory targets = new address[](1);
        targets[0] = address(fs);
        bytes[] memory datas = new bytes[](1);
        datas[0] = _fundCall(new PoolSwap[](0), address(coll));
        MatchPlan memory p = MatchPlan({
            orders: new Order[](0),
            sigs: new bytes[](0),
            fillAmounts: new uint256[](0),
            takerDatas: new bytes[](0),
            schedule: s,
            callTargets: targets,
            callDatas: datas,
            profitRecipient: address(0xBAD)
        });
        vm.prank(address(0xBAD));
        vm.expectRevert();
        settlement.matchSettle(p);
        assertEq(coll.balanceOf(address(fs)), 1e18, "bait untouched");
    }

    /// A callback from a non-allowlisted pool WHILE an honest flash is in flight — even
    /// echoing the exact committed payload — is refused: gate 2 (the armed provider).
    function test_roguePool_flashCallbackDuringFlash_reverts() public {
        HookToken hook = new HookToken();
        MockFlashV3Pool hp = factory.createPool(address(hook), address(debtT), 3000);
        hook.mint(address(hp), 100e18);
        RoguePool rogue = new RoguePool();

        Order memory o = _openOrder(1);
        MatchPlan memory p = _openPlan(o);
        FlashMatch memory j = _job(FlashKind.UNI_V3_FLASH, address(hook), 1e18, address(debtT), 3000, new PoolSwap[](0));
        bytes memory payload = abi.encode(j, abi.encodeCall(settlement.matchSettle, (p)));
        // The pool's transfer of the principal fires the hook: the rogue pool calls back.
        hook.arm(
            address(rogue),
            abi.encodeCall(
                RoguePool.poke, (address(fs), abi.encodeCall(MatchFlashSolver.uniswapV3FlashCallback, (0, 0, payload)))
            )
        );
        _expectRun(_guard(o), j, p, abi.encodeWithSelector(MatchFlashSolver.UnexpectedCaller.selector, address(rogue)));
    }

    /// A swap callback from a non-allowlisted pool while a repayment swap is in flight:
    /// the hop's data names a pool the caller is not.
    function test_roguePool_swapCallbackDuringSwap_reverts() public {
        HookToken hook = new HookToken();
        MockFlashV3Pool hp = factory.createPool(address(hook), address(debtT), 500);
        hook.mint(address(hp), 100e18);
        RoguePool rogue = new RoguePool();

        Order memory o = _openOrder(1);
        FlashMatch memory j = _openJob(FlashKind.UNI_V3_FLASH);
        j.swaps = _swaps1(_hop(address(debtT), 500, 0, address(hook)), 1e18, 0);
        j.extraSweep = new address[](0);
        bytes memory hopData = abi.encode(address(debtT), address(hook), uint24(500), uint8(0), uint256(1e18));
        hook.arm(
            address(rogue),
            abi.encodeCall(
                RoguePool.poke,
                (address(fs), abi.encodeCall(MatchFlashSolver.uniswapV3SwapCallback, (1e18, -1, hopData)))
            )
        );
        _expectRun(_guard(o), j, _openPlan(o), MatchFlashSolver.NotPool.selector);
    }

    /// Gate 3: a provider (Balancer-style: any recipient, any data) calling back with a
    /// payload other than the committed one.
    function test_payloadMismatch_reverts() public {
        Order memory o = _openOrder(1);
        flashPool.setOverrideData(abi.encode(uint256(0xdead)));
        _expectRun(
            _guard(o), _openJob(FlashKind.UNI_V3_FLASH), _openPlan(o), MatchFlashSolver.UnexpectedPayload.selector
        );
    }

    /// A provider that returns without calling back: nothing settled, refused.
    function test_callbackMissing_reverts() public {
        Order memory o = _openOrder(1);
        eVault.setSkip(true);
        FlashMatch memory j = _openJob(FlashKind.EULER);
        j.flash.vault = address(eVault);
        _expectRun(_guard(o), j, _openPlan(o), MatchFlashSolver.FlashCallbackMissing.selector);
    }

    /// Pools are derived, never named: the venue index is bounds-checked and the
    /// derivation pins the factory's own pools.
    function test_venue_derivationAndBounds() public {
        assertEq(fs.poolFor(0, address(coll), address(debtT), 3000), address(flashPool));
        assertEq(fs.poolFor(0, address(debtT), address(coll), 500), address(swapPool));
        MockFlashV3Factory rogueFactory = new MockFlashV3Factory();
        MockFlashV3Pool roguePool = rogueFactory.createPool(address(coll), address(debtT), 3000);
        assertTrue(
            fs.poolFor(0, address(coll), address(debtT), 3000) != address(roguePool), "rogue factory unreachable"
        );

        Order memory o = _openOrder(1);
        FlashMatch memory j = _openJob(FlashKind.UNI_V3_FLASH);
        j.flash.venue = 1;
        _expectRun(_guard(o), j, _openPlan(o), abi.encodeWithSelector(MatchFlashSolver.UnknownVenue.selector, 1));

        // A fee tier with no pool: the derived address has no code.
        j.flash.venue = 0;
        j.flash.fee = 10_000;
        _expectAnyRevert(_guard(o), j, _openPlan(o));
    }

    // ═══════════════════════════ residue, gating, plan checks ═══════════════════════════

    /// Anything here before the call — a donation, in a leg token or an unrelated one —
    /// leaves with the sweep; the contract ends empty.
    function test_residueSweep_donationsAndExtraToken() public {
        Order memory o = _openOrder(1);
        coll.mint(address(fs), 1e18);
        tC.mint(address(fs), 5e18);
        FlashMatch memory j = _openJob(FlashKind.UNI_V3_FLASH);
        j.extraSweep = new address[](1);
        j.extraSweep[0] = address(tC);
        (address[] memory toks, uint256[] memory profit) = _run(_guard(o), j, _openPlan(o));

        uint256 spread = D_IN / POOL_PRICE - C_OUT - _flashFee(C_OUT, 3000);
        assertEq(coll.balanceOf(treasury), spread + 1e18, "donation swept with the spread");
        assertEq(tC.balanceOf(treasury), 5e18, "extra token swept");
        assertEq(tC.balanceOf(address(fs)), 0);
        assertEq(toks.length, 3);
        assertEq(profit[2], 5e18);
        _assertClean();
    }

    function test_recipientDefaultsToOperator() public {
        Order memory o = _openOrder(1);
        FlashMatch memory j = _openJob(FlashKind.UNI_V3_FLASH);
        j.recipient = address(0);
        _run(_guard(o), j, _openPlan(o));
        assertEq(coll.balanceOf(operator), D_IN / POOL_PRICE - C_OUT - _flashFee(C_OUT, 3000));
    }

    function test_onlyOperator() public {
        Order memory o = _openOrder(1);
        MatchPlan memory p = _openPlan(o);
        FlashMatch memory j = _openJob(FlashKind.UNI_V3_FLASH);
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(MatchFlashSolver.NotOperator.selector, address(0xBAD)));
        fs.executeMatch(_guard(o), j, p);
    }

    function test_constructor_rejectsBadSets() public {
        FlashProviders memory pr = _providers();
        V3Venue[] memory v = _venues(address(factory));
        address st = address(settlement);
        vm.expectRevert(MatchFlashSolver.BadOperatorSet.selector);
        new MatchFlashSolver(st, new address[](0), v, pr);
        vm.expectRevert(MatchFlashSolver.BadOperatorSet.selector);
        new MatchFlashSolver(st, _ops(address(0)), v, pr);
        address[] memory five = new address[](5);
        for (uint256 i; i < 5; i++) {
            five[i] = address(uint160(0x1000 + i));
        }
        vm.expectRevert(MatchFlashSolver.BadOperatorSet.selector);
        new MatchFlashSolver(st, five, v, pr);
        V3Venue[] memory bad = new V3Venue[](1);
        bad[0] = V3Venue({factory: address(factory), initCodeHash: bytes32(0)});
        vm.expectRevert(MatchFlashSolver.BadVenue.selector);
        new MatchFlashSolver(st, _ops(operator), bad, pr);
    }

    function test_raceGuard_orderTaken() public {
        Order memory o = _openOrder(1);
        RaceCheck memory g = _guard(o);
        g.expectedFilled[0] = 1;
        _expectRun(
            g,
            _openJob(FlashKind.UNI_V3_FLASH),
            _openPlan(o),
            abi.encodeWithSelector(MatchRaceGuard.OrderTaken.selector, 0, 1, 0)
        );
    }

    function test_settleItem_refused() public {
        Item[] memory its = new Item[](1);
        its[0] = Item({op: ItemOp.SETTLE, module: address(lender), amount: 1, recipient: address(0), data: ""});
        Order memory o = _order(1, address(debtT), D_IN, address(coll), C_OUT, its);
        _expectRun(
            _noGuard(),
            _openJob(FlashKind.UNI_V3_FLASH),
            _openPlan(o),
            abi.encodeWithSelector(MatchFlashSolver.SettleUnsupported.selector, 0, 0)
        );
    }

    function test_strandedRecipients_refused() public {
        Order memory o = _openOrder(1);
        MatchPlan memory p = _openPlan(o);
        p.profitRecipient = address(settlement);
        _expectRun(_guard(o), _openJob(FlashKind.UNI_V3_FLASH), p, MatchFlashSolver.ProfitStranded.selector);

        p.profitRecipient = address(settlement.EXECUTOR());
        _expectRun(_guard(o), _openJob(FlashKind.UNI_V3_FLASH), p, MatchFlashSolver.ProfitStranded.selector);

        FlashMatch memory j = _openJob(FlashKind.UNI_V3_FLASH);
        j.recipient = address(fs);
        _expectRun(_guard(o), j, _openPlan(o), MatchFlashSolver.BadRecipient.selector);
    }

    function test_badFlashRequests_refused() public {
        Order memory o = _openOrder(1);
        FlashMatch memory j = _openJob(FlashKind.UNI_V3_FLASH);
        j.flash.pairToken = address(coll);
        _expectRun(_guard(o), j, _openPlan(o), MatchFlashSolver.BadFlashRequest.selector);

        j = _openJob(FlashKind.UNI_V3_FLASH);
        j.flash.amount = 0;
        _expectRun(_guard(o), j, _openPlan(o), MatchFlashSolver.BadFlashRequest.selector);

        j = _openJob(FlashKind.EULER); // no vault
        _expectRun(_guard(o), j, _openPlan(o), MatchFlashSolver.BadFlashRequest.selector);
    }
}
