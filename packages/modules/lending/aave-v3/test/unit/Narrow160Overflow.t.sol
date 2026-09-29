// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MockSettlementBase, MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {Narrow160} from "@lib/Narrow160.sol";

import {AaveV3CreditModule} from "../../src/AaveV3CreditModule.sol";

/// @dev A venue that behaves like Aave for the two calls the leverage op makes:
///      `supply` PULLS exactly what it is told (so an over-wide approve would be
///      consumed, which is the drain), `borrow` mints the borrow asset to the caller.
contract PullingPool {
    function supply(address asset, uint256 amount, address, uint16) external {
        MockERC20(asset).transferFrom(msg.sender, address(this), amount);
    }

    function borrow(address asset, uint256 amount, uint256, uint16, address) external {
        MockERC20(asset).mint(msg.sender, amount);
    }
}

/// @title Narrow160OverflowTest
/// @notice Pins the {Narrow160} guard at `AaveV3CreditModule._ratioSupplyLeg`:
///
///       permit3.transferFrom(onBehalfOf, address(this), collateralAsset,
///                            Narrow160.to160(collateral));
///
///  `collateral = ceil(amount · collateralTotal / borrowTotal)`, where
///  `collateralTotal` and `borrowTotal` are decoded from the item's maker-signed
///  `data` — which the core never width-checks (it only checks the item SLICE,
///  `amount`). With `amount == borrowTotal` (a full fill) the collateral is exactly
///  `collateralTotal`, so the order author chooses it freely. A bare `uint160(...)`
///  there would pull `collateral mod 2^160` (0 wei at 2^160) while `_supply`
///  force-approves the full, un-narrowed figure to an order-named `pool` (F26/2d).
///
///  Entry path is the realistic one, not a direct module call:
///    Settlement.fill → Permit3.take (taker book, ref = keccak256(data))
///      → AaveV3CreditModule.takeOnBehalf (Op.Leverage, plain TAKE)
///      → _ratioSupplyLeg → Narrow160.to160.
///  Real Permit3 + Settlement over mock tokens (MockSettlementBase), so this runs
///  under the RPC-free `modules-aave-v3` unit profile.
contract Narrow160OverflowTest is MockSettlementBase {
    AaveV3CreditModule mod;
    PullingPool pool;

    // tA = borrow asset (maker PAYS it to the solver, funded by the borrow)
    // tB = what the maker receives from the solver
    // tC = collateral asset, pulled from the maker's wallet by the module
    uint256 constant BORROW = 1_000e6;
    uint256 constant OUT = 1e18;
    uint256 constant OP_LEVERAGE = uint256(AaveV3CreditModule.Op.Leverage);

    function setUp() public override {
        super.setUp();
        mod = new AaveV3CreditModule(address(permit3), address(settlement));
        pool = new PullingPool();
        vm.label(address(mod), "aaveV3CreditModule");
        vm.label(address(pool), "pool");
    }

    // ──────────────────── builders ────────────────────

    /// @dev Op.Leverage plain-TAKE layout:
    ///      (op, pool, borrowAsset, rateMode, collateralAsset, collateralTotal, borrowTotal)
    function _data(uint256 collateralTotal) internal view returns (bytes memory) {
        return abi.encode(OP_LEVERAGE, address(pool), address(tA), uint256(2), address(tC), collateralTotal, BORROW);
    }

    /// @dev One fused item; `amount` is the BORROW leg (the taker-gated one). The
    ///      order's legs are small and core-width-safe — only `data` carries the
    ///      oversized figure.
    function _order(uint256 nonce, bytes memory data) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), BORROW, OUT);
        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.TAKE, module: address(mod), amount: BORROW, recipient: address(0), data: data});
        o.items = PackedEncode.items(items);
    }

    /// @dev Every grant the fill needs, maxed out, so the ONLY thing that can stop
    ///      the collateral pull is the width check under test.
    function _grant(bytes memory data, uint256 makerCollateral) internal {
        tC.mint(maker, makerCollateral);
        _makerApprove(address(mod), address(tC), type(uint160).max);
        vm.prank(maker);
        permit3.approveTaker(address(settlement), address(mod), keccak256(data), uint160(BORROW), 0);

        tB.mint(solver, OUT);
        _solverApprove(address(settlement), address(tB), type(uint160).max);
    }

    struct Snap {
        uint256 makerC;
        uint256 modC;
        uint256 poolC;
        uint256 modA;
        uint256 settlementA;
        uint256 solverA;
        uint256 makerB;
        uint256 solverB;
        uint256 modPoolAllowanceC;
        uint160 tokenAllowance;
        uint160 takerAllowance;
    }

    function _snap(bytes memory data) internal view returns (Snap memory s) {
        s.makerC = tC.balanceOf(maker);
        s.modC = tC.balanceOf(address(mod));
        s.poolC = tC.balanceOf(address(pool));
        s.modA = tA.balanceOf(address(mod));
        s.settlementA = tA.balanceOf(address(settlement));
        s.solverA = tA.balanceOf(solver);
        s.makerB = tB.balanceOf(maker);
        s.solverB = tB.balanceOf(solver);
        s.modPoolAllowanceC = tC.allowance(address(mod), address(pool));
        (s.tokenAllowance,) = permit3.tokenAllowance(maker, address(mod), address(tC));
        (s.takerAllowance,) = permit3.takerAllowance(maker, address(settlement), address(mod), keccak256(data));
    }

    function _assertUnchanged(Snap memory a, Snap memory b) internal pure {
        assertEq(b.makerC, a.makerC, "maker collateral moved");
        assertEq(b.modC, a.modC, "module collateral moved");
        assertEq(b.poolC, a.poolC, "venue collateral moved");
        assertEq(b.modA, a.modA, "module borrow asset moved");
        assertEq(b.settlementA, a.settlementA, "settlement borrow asset moved");
        assertEq(b.solverA, a.solverA, "solver borrow asset moved");
        assertEq(b.makerB, a.makerB, "maker output moved");
        assertEq(b.solverB, a.solverB, "solver output moved");
        assertEq(b.modPoolAllowanceC, a.modPoolAllowanceC, "module left an allowance to the venue");
        assertEq(b.tokenAllowance, a.tokenAllowance, "Permit3 token allowance consumed");
        assertEq(b.takerAllowance, a.takerAllowance, "Permit3 taker allowance consumed");
    }

    // ──────────────────── tests ────────────────────

    /// @dev collateralTotal = 2^160 at a full fill ⇒ collateral = 2^160 exactly.
    ///      A clipping cast would pull 0 and approve 2^160; the guard reverts with
    ///      the bare selector (Permit3 and Settlement bubble module reverts
    ///      unwrapped), and the whole fill unwinds.
    function test_narrow160_leverageRatioCollateral_reverts() public {
        uint256 over = uint256(type(uint160).max) + 1;
        bytes memory data = _data(over);
        Order memory o = _order(1, data);
        bytes memory sig = _sign(o); // sign BEFORE any prank

        _grant(data, 1_000e18); // the maker holds far less than 2^160 — irrelevant: the width check is first
        Snap memory before = _snap(data);

        vm.prank(solver);
        vm.expectRevert(Narrow160.AmountOverflow.selector);
        settlement.fill(o, sig, BORROW);

        _assertUnchanged(before, _snap(data));
    }

    /// @dev Same order at a PARTIAL fill: the derivation is `ceil(slice · total /
    ///      borrowTotal)`, so a larger signed total that only exceeds 2^160 after
    ///      pro-rating still trips the guard (half fill, total = 2^161 + 2 ⇒ 2^160 + 1).
    function test_narrow160_leverageRatioCollateralPartialFill_reverts() public {
        uint256 total = (uint256(type(uint160).max) + 1) * 2 + 2;
        bytes memory data = _data(total);
        Order memory o = _order(2, data);
        bytes memory sig = _sign(o);

        _grant(data, 1_000e18);
        Snap memory before = _snap(data);

        vm.prank(solver);
        vm.expectRevert(Narrow160.AmountOverflow.selector);
        settlement.fill(o, sig, BORROW / 2);

        _assertUnchanged(before, _snap(data));
    }

    /// @dev Boundary: collateral = type(uint160).max exactly gets PAST the narrowing
    ///      and the whole fill succeeds — the full amount is pulled, supplied, the
    ///      venue approval is cleared, and the borrow funds the solver.
    function test_narrow160_leverageRatioCollateral_atMaxPassesNarrowing() public {
        uint256 atMax = type(uint160).max;
        bytes memory data = _data(atMax);
        Order memory o = _order(3, data);
        bytes memory sig = _sign(o);

        _grant(data, atMax);

        vm.prank(solver);
        settlement.fill(o, sig, BORROW);

        assertEq(tC.balanceOf(maker), 0, "maker's full uint160.max collateral pulled");
        assertEq(tC.balanceOf(address(pool)), atMax, "venue received exactly the narrowed amount");
        assertEq(tC.balanceOf(address(mod)), 0, "module holds no collateral");
        assertEq(tC.allowance(address(mod), address(pool)), 0, "venue approval cleared");
        assertEq(tA.balanceOf(solver), BORROW, "borrow funded the solver");
        assertEq(tB.balanceOf(maker), OUT, "maker received the output leg");
    }

    /// @dev Boundary, un-funded variant: at exactly uint160.max with the maker
    ///      holding far less, the fill still reverts — but NOT with AmountOverflow.
    ///      The narrowing passed; the failure is downstream (the token pull).
    function test_narrow160_leverageRatioCollateralUnfunded_atMaxFailsPastNarrowing() public {
        bytes memory data = _data(type(uint160).max);
        Order memory o = _order(4, data);
        bytes memory sig = _sign(o);

        _grant(data, 1_000e18);
        Snap memory before = _snap(data);

        vm.prank(solver);
        try settlement.fill(o, sig, BORROW) {
            fail();
        } catch (bytes memory err) {
            bytes4 sel;
            if (err.length >= 4) sel = bytes4(err);
            assertTrue(sel != Narrow160.AmountOverflow.selector, "reverted at the narrowing, not past it");
        }

        _assertUnchanged(before, _snap(data));
    }
}
