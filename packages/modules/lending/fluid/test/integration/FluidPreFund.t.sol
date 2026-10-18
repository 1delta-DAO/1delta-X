// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, LegOut, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {Chains, Tokens} from "@coretest/data/LenderRegistry.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";

import {IFluidVault} from "../../src/interfaces/IFluid.sol";
import {FluidPreFundModule} from "../../src/FluidPreFundModules.sol";
import {FluidModulesBase} from "../shared/FluidModulesBase.t.sol";

/// @title FluidPreFundForkTest
/// @notice {FluidPreFundModule} on the LIVE mainnet wstETH-USDC T1 vault (id 14, the
///         vault the pre-fund TAKE_FOR suite uses — vault 4's borrow limit is
///         exhausted at the pinned block).
///
///         Part 1 drives the module directly (pranked Settlement, delivery `deal`t to
///         the module), pinning what Fluid itself does with each op: the deposit, the
///         exact repay (and Fluid's revert on a literal over-payback), and the
///         RepayAll live-debt clamp with the delivery as the ceiling.
///
///         Part 2 runs the two ACYCLIC position shapes the module exists for through
///         the REAL Settlement's `matchSettle`, netted against a counter-order, with
///         ZERO filler capital and ZERO receive-side grants:
///           • open:  borrow TAKE early → deliver collateral → Deposit late;
///           • close: withdraw TAKE early → deliver USDC → RepayAll late — the Fluid
///             full close that used to exist only as the fused (cyclic) Close.
contract FluidPreFundForkTest is FluidModulesBase {
    address constant WSTETH_USDC_VAULT = 0x1982CC7b1570C2503282d0A0B41F69b3B28fdcc3;

    FluidPreFundModule preFund;
    address WSTETH;

    uint256 carolPk = 0xCA201;
    address carol = vm.addr(carolPk);

    uint256 constant COL0 = 2 ether;
    uint256 constant DEBT0 = 1_000e6;
    uint256 constant RESIDUE = 7e6; // stray USDC already on the singleton

    uint256 posId;

    function setUp() public override {
        super.setUp();
        WSTETH = tokens[Chains.ETHEREUM_MAINNET][Tokens.WSTETH];
        preFund = new FluidPreFundModule(address(permit3), address(settlement));
        vm.label(WSTETH_USDC_VAULT, "FluidWstethUsdcVault");
        vm.label(WSTETH, "wstETH");
        vm.label(address(preFund), "fluidPreFund");
        vm.label(carol, "carol");
        deal(USDC, address(preFund), RESIDUE);
        deal(WSTETH, address(preFund), 1e15); // residue in the collateral token too
    }

    // ──────────────────── helpers ────────────────────

    /// @dev Pre-fund leg reference (bits 255+253), op in [244,252), token in [16,176).
    function _desc(uint256 op, address token, uint256 j) internal pure returns (uint256) {
        return (uint256(5) << 253) | (op << 244) | (uint256(uint160(token)) << 16) | j;
    }

    function _data(uint256 op, address token, uint256 nftId) internal view returns (bytes memory) {
        return abi.encode(_desc(op, token, 0), WSTETH_USDC_VAULT, token, nftId);
    }

    /// @dev A position owned by `owner_` with `col` wstETH and `debt` USDC, opened
    ///      directly on the vault.
    function _seed(address owner_, uint256 col, uint256 debt) internal returns (uint256 nftId) {
        deal(WSTETH, owner_, col);
        vm.startPrank(owner_);
        IERC20(WSTETH).approve(WSTETH_USDC_VAULT, col);
        (nftId,,) = IFluidVault(WSTETH_USDC_VAULT).operate(0, int256(col), int256(debt), owner_);
        vm.stopPrank();
        require(nftId != 0, "seed failed");
        if (debt != 0) deal(USDC, owner_, 0); // the borrow is not the maker's wallet balance under test
    }

    /// @dev Deliver `amt` of `token` to the module (as a fill would) and run the item.
    function _make(uint256 op, address token, uint256 nftId, uint256 amt) internal {
        deal(token, address(preFund), IERC20(token).balanceOf(address(preFund)) + amt);
        bytes memory data = _data(op, token, nftId);
        vm.prank(address(settlement));
        preFund.makeOnBehalf(maker, amt, data);
    }

    /// @dev Behavioural "debt == 0" probe (Fluid has no position getter): a position
    ///      carrying ANY debt cannot have its collateral withdrawn to zero, so the
    ///      withdraw-all succeeds iff the debt is exactly zero. Rolled back.
    function _debtIsZero(uint256 nftId) internal returns (bool zero) {
        uint256 snap = vm.snapshotState();
        vm.prank(_ownerOf(nftId));
        try IFluidVault(WSTETH_USDC_VAULT).operate(nftId, type(int256).min, 0, address(0xdead)) {
            zero = true;
        } catch {}
        vm.revertToState(snap);
    }

    /// @dev Fluid rounds through its exchange prices, so a position reads a few wei
    ///      off a nominal amount (measured: 7 USDC units, 32 wstETH wei).
    uint256 constant TOL_USDC = 20;
    uint256 constant TOL_WSTETH = 1e6;

    /// @dev Fluid's error envelopes and the codes these tests pin (verified against
    ///      `fluid-contracts-public` `protocols/vault/errorTypes.sol` and
    ///      `liquidity/errorTypes.sol`).
    bytes4 constant FLUID_VAULT_ERROR = bytes4(keccak256("FluidVaultError(uint256)"));
    bytes4 constant FLUID_LIQUIDITY_ERROR = bytes4(keccak256("FluidLiquidityError(uint256)"));
    uint256 constant VAULT_POSITION_ABOVE_CF = 31006;
    uint256 constant VAULT_EXCESS_DEBT_PAYBACK = 31015;
    uint256 constant LIQ_OPERATE_AMOUNT_INSUFFICIENT = 11007;

    /// @dev Collateral + debt of a position, measured by a rolled-back full close
    ///      funded generously. A debt-free position must not pass the repay-all
    ///      sentinel (Fluid reverts an empty payback), hence `hasDebt`.
    function _measure(uint256 nftId) internal returns (uint256 col, uint256 debt) {
        return _measure(nftId, true);
    }

    function _measure(uint256 nftId, bool hasDebt) internal returns (uint256 col, uint256 debt) {
        uint256 snap = vm.snapshotState();
        address owner_ = _ownerOf(nftId);
        deal(USDC, owner_, 1_000_000e6);
        vm.startPrank(owner_);
        IERC20(USDC).approve(WSTETH_USDC_VAULT, type(uint256).max);
        (, int256 c, int256 d) = IFluidVault(WSTETH_USDC_VAULT).operate(nftId, type(int256).min, hasDebt ? type(int256).min : int256(0), owner_);
        vm.stopPrank();
        vm.revertToState(snap);
        col = uint256(-c);
        debt = uint256(-d);
    }

    // ──────────────────── part 1: the venue semantics, op by op ────────────────────

    /// Deposit supplies the WHOLE delivery into the maker's position; the module ends
    /// at its residue, the vault grant is cleared, and the maker granted nothing.
    function test_fork_deposit_suppliesExactlyTheDelivery() public {
        posId = _seed(maker, COL0, 0);
        uint256 residue = IERC20(WSTETH).balanceOf(address(preFund));
        _make(0, WSTETH, posId, 1 ether);
        (uint256 col,) = _measure(posId, false);
        assertApproxEqAbs(col, COL0 + 1 ether, TOL_WSTETH, "position gained the delivery");
        assertEq(IERC20(WSTETH).balanceOf(address(preFund)), residue, "singleton back to its residue");
        assertEq(IERC20(WSTETH).allowance(address(preFund), WSTETH_USDC_VAULT), 0, "vault grant cleared");
        assertEq(_ownerOf(posId), maker, "no custody taken");
    }

    /// Exact repay retires exactly the delivery.
    function test_fork_repayExact_retiresTheDelivery() public {
        posId = _seed(maker, COL0, DEBT0);
        _make(1, USDC, posId, 400e6);
        (, uint256 debt) = _measure(posId);
        assertApproxEqAbs(debt, DEBT0 - 400e6, TOL_USDC, "debt down by the delivery");
        assertEq(IERC20(USDC).balanceOf(address(preFund)), RESIDUE, "singleton back to its residue");
    }

    /// Fluid reverts a LITERAL payback above the live debt (`Vault__ExcessDebtPayback`)
    /// — which is why the exact op is for bounded deleverage and RepayAll exists.
    function test_fork_repayExact_aboveLiveDebt_reverts() public {
        posId = _seed(maker, COL0, DEBT0);
        deal(USDC, address(preFund), RESIDUE + 1_100e6);
        bytes memory data = _data(1, USDC, posId);
        vm.prank(address(settlement));
        vm.expectRevert(abi.encodeWithSelector(FLUID_VAULT_ERROR, VAULT_EXCESS_DEBT_PAYBACK));
        preFund.makeOnBehalf(maker, 1_100e6, data);
    }

    /// RepayAll: the delivery is a CEILING. After 30 days of accrual the vault takes
    /// exactly the live debt, the remainder is swept to the maker, the debt is zero.
    function test_fork_repayAll_clampsAtLiveDebt_sweepsRemainderToMaker() public {
        posId = _seed(maker, COL0, DEBT0);
        vm.warp(block.timestamp + 30 days);
        (, uint256 live) = _measure(posId);
        assertGt(live, DEBT0, "interest accrued");

        _make(2, USDC, posId, 1_100e6);

        assertTrue(_debtIsZero(posId), "debt fully retired");
        assertApproxEqAbs(IERC20(USDC).balanceOf(maker), 1_100e6 - live, TOL_USDC, "remainder swept to the maker");
        assertEq(IERC20(USDC).balanceOf(address(preFund)), RESIDUE, "residue untouched");
        assertEq(IERC20(USDC).allowance(address(preFund), WSTETH_USDC_VAULT), 0, "vault grant cleared");
        assertEq(_ownerOf(posId), maker, "no custody taken");
    }

    /// RepayAll with a delivery BELOW the live debt fails closed: the scoped approval
    /// is the ceiling, so the vault cannot reach the residue (on the netted path: a
    /// sibling order's parked delivery) sitting on the module.
    function test_fork_repayAll_debtAboveDelivery_failsClosed_residueUnreachable() public {
        posId = _seed(maker, COL0, DEBT0);
        deal(USDC, address(preFund), 5_000e6 + 500e6); // a big parked balance + the delivery
        bytes memory data = _data(2, USDC, posId);
        vm.prank(address(settlement));
        vm.expectRevert();
        preFund.makeOnBehalf(maker, 500e6, data);
        assertEq(IERC20(USDC).balanceOf(address(preFund)), 5_500e6, "nothing drawn");
    }

    /// RepayAll is ONE-SHOT: once the debt is zero Fluid's repay-all resolves to its
    /// 1-wei rounding payback, which the Liquidity layer rejects
    /// (`UserModule__OperateAmountInsufficient`) — so a RepayAll order is signed
    /// full-fill.
    function test_fork_repayAll_onZeroDebt_reverts() public {
        posId = _seed(maker, COL0, DEBT0);
        _make(2, USDC, posId, 1_010e6);
        assertTrue(_debtIsZero(posId), "closed");
        deal(USDC, address(preFund), IERC20(USDC).balanceOf(address(preFund)) + 10e6);
        bytes memory data = _data(2, USDC, posId);
        vm.prank(address(settlement));
        vm.expectRevert(abi.encodeWithSelector(FLUID_LIQUIDITY_ERROR, LIQ_OPERATE_AMOUNT_INSUFFICIENT));
        preFund.makeOnBehalf(maker, 10e6, data);
    }

    /// A stranger's position is refused: payback is permissionless on Fluid, so the
    /// binding is what keeps the maker's delivery off someone else's debt.
    function test_fork_strangersPosition_refused() public {
        address stranger = address(0x5742);
        uint256 id = _seed(stranger, COL0, DEBT0);
        deal(USDC, address(preFund), RESIDUE + 100e6);
        bytes memory data = _data(2, USDC, id);
        vm.prank(address(settlement));
        vm.expectRevert(abi.encodeWithSelector(FluidPreFundModule.NotPositionOwner.selector, id, stranger));
        preFund.makeOnBehalf(maker, 100e6, data);
    }

    /// The token must be the vault side the op spends: depositing USDC into a
    /// wstETH-collateral vault names the reason instead of reverting in the callback.
    function test_fork_wrongVaultToken_refused() public {
        posId = _seed(maker, COL0, 0);
        deal(USDC, address(preFund), RESIDUE + 100e6);
        bytes memory data = _data(0, USDC, posId);
        vm.prank(address(settlement));
        vm.expectRevert(abi.encodeWithSelector(FluidPreFundModule.WrongVaultToken.selector, USDC, WSTETH));
        preFund.makeOnBehalf(maker, 100e6, data);
    }

    /// A delivery that did NOT land on the module (a maker-addressed leg) underflows
    /// the floor before Fluid is touched — the residue can never fund it.
    function test_fork_unfundedModule_failsClosedOnTheFloor() public {
        posId = _seed(maker, COL0, DEBT0);
        bytes memory data = _data(2, USDC, posId);
        vm.prank(address(settlement));
        vm.expectRevert(); // arithmetic underflow in PreFundGuard.floorOf
        preFund.makeOnBehalf(maker, 100e6, data);
    }

    // ──────────────────── part 2: acyclic shapes through the real matchSettle ────────────────────

    function _signWith(Order memory o, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), _hashOrder(o)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _step(uint256 kind, uint256 a) internal pure returns (uint256) {
        return MatchStep.pack(kind, a, 0);
    }

    /// @dev Maker order: `tokIn` (amtIn) is PRODUCED by a TAKE item (borrow / withdraw
    ///      through {FluidTakerModule}), `tokOut` (amtOut) is delivered TO the
    ///      pre-fund module and consumed by its MAKE item (op `op`).
    function _positionOrder(uint8 takeOp, uint256 makeOp, address tokIn, uint256 amtIn, address tokOut, uint256 amtOut)
        internal
        returns (Order memory o)
    {
        bytes memory takeData = abi.encode(takeOp, WSTETH_USDC_VAULT, VAULT_FACTORY, posId);
        Item[] memory items = new Item[](2);
        items[0] = Item(ItemOp.TAKE, address(takerModule), amtIn, address(0), takeData);
        items[1] = Item(ItemOp.MAKE, address(preFund), 0, address(0), _data(makeOp, tokOut, posId));
        o = _order(maker, 1, tokIn, tokOut, amtIn, amtOut, items);
        LegOut[] memory legsOut = new LegOut[](1);
        legsOut[0] = LegOut(tokOut, amtOut, 0, address(preFund)); // ← delivered to the module
        o.legsOut = PackedEncode.legsOut(legsOut);
        // The ONLY grant: the taker allowance that bounds what leaves the position.
        vm.prank(maker);
        permit3.approveTaker(address(settlement), address(takerModule), keccak256(takeData), uint160(amtIn), 0);
    }

    /// @dev Carol, the counter-order: sells `tokIn` for `tokOut`, plain wallet order.
    function _carol(address tokIn, uint256 amtIn, address tokOut, uint256 amtOut) internal returns (Order memory o) {
        deal(tokIn, carol, amtIn);
        vm.startPrank(carol);
        IERC20(tokIn).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), tokIn, uint160(amtIn), 0);
        vm.stopPrank();
        o = _order(carol, 1, tokIn, tokOut, amtIn, amtOut, new Item[](0));
    }

    /// @dev ITEM take (early) → PULL maker (nets to nothing) → PULL carol → DELIVER
    ///      maker (to the module) → ITEM make (late) → DELIVER carol (from the take).
    function _runAcyclic(Order memory m, Order memory c, uint256 fillM, uint256 fillC) internal {
        Order[] memory orders = new Order[](2);
        orders[0] = m;
        orders[1] = c;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _signWith(m, makerPk);
        sigs[1] = _signWith(c, carolPk);
        uint256[] memory fills = new uint256[](2);
        fills[0] = fillM;
        fills[1] = fillC;
        uint256[] memory s = new uint256[](6);
        s[0] = MatchStep.pack(MatchStep.ITEM, 0, 0);
        s[1] = _step(MatchStep.PULL, 0);
        s[2] = _step(MatchStep.PULL, 1);
        s[3] = _step(MatchStep.DELIVER, 0);
        s[4] = MatchStep.pack(MatchStep.ITEM, 0, 1);
        s[5] = _step(MatchStep.DELIVER, 1);
        MatchPlan memory p = MatchPlan({
            orders: orders,
            sigs: sigs,
            fillAmounts: fills,
            takerDatas: new bytes[](0),
            schedule: s,
            callTargets: new address[](0),
            callDatas: new bytes[](0),
            profitRecipient: address(0)
        });
        vm.prank(solver);
        settlement.matchSettle(p);
    }

    /// Acyclic OPEN: borrow 500 USDC against the position's existing collateral
    /// (headroom), deliver 0.2 wstETH to the module, Deposit late. The maker's wallet
    /// and the solver hold nothing before or after.
    function test_fork_matchSettle_acyclicOpen_borrowEarly_depositLate_zeroCapital() public {
        posId = _seed(maker, COL0, 0);
        uint256 borrowAmt = 500e6;
        uint256 colAdd = 0.2 ether;
        Order memory m = _positionOrder(0, 0, USDC, borrowAmt, WSTETH, colAdd);
        Order memory c = _carol(WSTETH, colAdd, USDC, borrowAmt);
        uint256 wResidue = IERC20(WSTETH).balanceOf(address(preFund));

        _runAcyclic(m, c, borrowAmt, colAdd);

        (uint256 col, uint256 debt) = _measure(posId);
        assertApproxEqAbs(col, COL0 + colAdd, TOL_WSTETH, "delivered collateral supplied");
        assertApproxEqAbs(debt, borrowAmt, TOL_USDC, "borrow drawn");
        assertEq(IERC20(USDC).balanceOf(carol), borrowAmt, "carol paid from the borrow");
        assertEq(IERC20(WSTETH).balanceOf(maker) + IERC20(USDC).balanceOf(maker), 0, "maker wallet untouched");
        assertEq(IERC20(WSTETH).balanceOf(solver) + IERC20(USDC).balanceOf(solver), 0, "zero solver capital");
        assertEq(IERC20(WSTETH).balanceOf(address(preFund)), wResidue, "singleton back to its residue");
        assertEq(_ownerOf(posId), maker, "position NFT back with the maker");
    }

    /// Acyclic FULL CLOSE (review 2026-10-18 M-3): withdraw 0.6 wstETH early (the
    /// position's headroom carries the debt for one step), deliver 1,100 USDC to the
    /// module, RepayAll late. After 30 days of accrual the vault takes exactly the
    /// live debt; the remainder is swept to the maker; the debt is zero. No flash, no
    /// fused item, no receive-side grant, zero solver capital.
    function test_fork_matchSettle_acyclicFullClose_withdrawEarly_repayAllLate_zeroCapital() public {
        posId = _seed(maker, COL0, DEBT0);
        vm.warp(block.timestamp + 30 days);
        (, uint256 live) = _measure(posId);
        uint256 colOut = 0.6 ether;
        uint256 usdcIn = 1_100e6;
        Order memory m = _positionOrder(1, 2, WSTETH, colOut, USDC, usdcIn);
        Order memory c = _carol(USDC, usdcIn, WSTETH, colOut);

        _runAcyclic(m, c, colOut, usdcIn);

        assertTrue(_debtIsZero(posId), "debt fully retired");
        assertApproxEqAbs(IERC20(USDC).balanceOf(maker), usdcIn - live, TOL_USDC, "repay remainder swept to the maker");
        assertEq(IERC20(WSTETH).balanceOf(carol), colOut, "carol paid from the withdrawal");
        assertEq(IERC20(WSTETH).balanceOf(solver) + IERC20(USDC).balanceOf(solver), 0, "zero solver capital");
        assertEq(IERC20(USDC).balanceOf(address(preFund)), RESIDUE, "singleton back to its residue");
        (uint160 a,) = permit3.tokenAllowance(maker, address(preFund), USDC);
        assertEq(a, 0, "no receive-side Permit3 allowance existed");
        assertEq(_ownerOf(posId), maker, "position NFT back with the maker");
    }

    /// The same close with the withdraw sized PAST the position's headroom is the
    /// true cycle: the TAKE cannot run before the repay, so the plan reverts in
    /// Fluid's end-of-operate health check (`Vault__PositionAboveCF`). That remainder
    /// belongs to the flash family (or the fused `FluidOperateModule` Close).
    function test_fork_matchSettle_closeAtTheLtvEdge_isACycle_reverts() public {
        posId = _seed(maker, COL0, DEBT0);
        uint256 colOut = 1.6 ether; // leaves ~0.4 wstETH against 1,000 USDC of debt
        Order memory m = _positionOrder(1, 2, WSTETH, colOut, USDC, 1_100e6);
        Order memory c = _carol(USDC, 1_100e6, WSTETH, colOut);
        vm.expectRevert(abi.encodeWithSelector(FLUID_VAULT_ERROR, VAULT_POSITION_ABOVE_CF));
        this.runAcyclicExternal(m, c, colOut, 1_100e6);
    }

    function runAcyclicExternal(Order memory m, Order memory c, uint256 fillM, uint256 fillC) external {
        _runAcyclic(m, c, fillM, fillC);
    }

    /// A LITERAL descriptor (an absolute amount, no delivery behind it) is refused at
    /// the door — the module only ever spends a core-sized, delivered leg.
    function test_fork_literalDescriptor_refused() public {
        posId = _seed(maker, COL0, DEBT0);
        bytes memory data = abi.encode(uint256(100e6), WSTETH_USDC_VAULT, USDC, posId);
        vm.prank(address(settlement));
        vm.expectRevert(PreFundGuard.PreFundDescriptorRequired.selector);
        preFund.makeOnBehalf(maker, 100e6, data);
    }
}
