// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order} from "@core/settlement/Settlement.sol";
import {SettlementLens} from "@periphery/SettlementLens.sol";

import {MockSettlementBase} from "@coretest/shared/MockSettlementBase.t.sol";

/// @dev A maker-chosen token whose reads never return: every `balanceOf` /
///      `allowance` spins until the frame is out of gas. The cheapest way a
///      stranger can make one order's preflight cost everything it is handed.
contract GasBurnerToken {
    function balanceOf(address) external view returns (uint256) {
        _burn();
        return 0;
    }

    function allowance(address, address) external view returns (uint256) {
        _burn();
        return 0;
    }

    function _burn() private view {
        uint256 x;
        while (gasleft() > 0) x += block.timestamp;
    }
}

/// @title LensPoisonOrder
/// @notice One poison order must not take its batch down with it.
///
///  {SettlementLens.getOrderRelevantStates} used to forward ALL available gas to
///  each order's `try`. An order whose token burns gas ate 63/64 of the call's
///  budget, every later order in the batch ran out and came back `Invalid`, and an
///  orderbook evicting on `Invalid` dropped a whole chunk of honest orders for one
///  poisoned one. Each order now runs under {ORDER_STATE_GAS}; an exhausted budget
///  reads `Inconclusive` — "not evaluated" — never `Invalid`.
contract LensPoisonOrderTest is MockSettlementBase {
    uint256 constant IN_ = 1_000e18;
    uint256 constant OUT_ = 2e18;

    GasBurnerToken poison;

    function setUp() public virtual override {
        super.setUp();
        poison = new GasBurnerToken();
        tA.mint(maker, 10 * IN_);
        _makerApprove(address(settlement), address(tA), 10 * IN_);
    }

    function _batch(Order[] memory orders, uint256 gasLimit)
        internal
        view
        returns (SettlementLens.OrderStatus[] memory statuses, uint256[] memory fillable)
    {
        bytes[] memory sigs = new bytes[](orders.length);
        for (uint256 i; i < orders.length; i++) {
            sigs[i] = _sign(orders[i]);
        }
        (statuses, fillable,,) =
            lens.getOrderRelevantStates{gas: gasLimit}(orders, sigs, solver, new bytes[](orders.length));
    }

    /// Honest orders on BOTH sides of the poison one still come back Fillable, with
    /// their real fillable amount; the poison order is Inconclusive, not Invalid.
    function test_poisonOrder_doesNotEvictItsChunk() public view {
        Order[] memory orders = new Order[](4);
        orders[0] = _plainOrder(1, address(tA), address(tB), IN_, OUT_);
        orders[1] = _plainOrder(2, address(poison), address(tB), IN_, OUT_);
        orders[2] = _plainOrder(3, address(tA), address(tB), IN_, OUT_);
        orders[3] = _plainOrder(4, address(tA), address(tB), IN_, OUT_);

        // A realistic provider-style budget: plenty for four orders, nowhere near
        // enough for the poison order to be handed "everything".
        (SettlementLens.OrderStatus[] memory st, uint256[] memory fillable) = _batch(orders, 3_000_000);

        assertEq(uint8(st[0]), uint8(SettlementLens.OrderStatus.Fillable), "before the poison");
        assertEq(uint8(st[1]), uint8(SettlementLens.OrderStatus.Inconclusive), "poison: not evaluated");
        assertEq(uint8(st[2]), uint8(SettlementLens.OrderStatus.Fillable), "after the poison");
        assertEq(uint8(st[3]), uint8(SettlementLens.OrderStatus.Fillable), "after the poison");
        assertEq(fillable[2], IN_, "real fillable amount, not a degraded 0");
        assertEq(fillable[3], IN_, "real fillable amount, not a degraded 0");
    }

    /// When the CALL runs short, the orders it could not start read Inconclusive and
    /// the call still returns — an orderbook must not lose the verdicts it did get.
    function test_exhaustedCallBudget_marksRestInconclusive_noRevert() public view {
        Order[] memory orders = new Order[](4);
        orders[0] = _plainOrder(1, address(poison), address(tB), IN_, OUT_);
        orders[1] = _plainOrder(2, address(tA), address(tB), IN_, OUT_);
        orders[2] = _plainOrder(3, address(tA), address(tB), IN_, OUT_);
        orders[3] = _plainOrder(4, address(tA), address(tB), IN_, OUT_);

        // Enough to start the poison order, not enough for a full budget after it.
        (SettlementLens.OrderStatus[] memory st,) = _batch(orders, 800_000);

        assertEq(uint8(st[0]), uint8(SettlementLens.OrderStatus.Inconclusive), "poison");
        for (uint256 i = 1; i < st.length; i++) {
            assertEq(uint8(st[i]), uint8(SettlementLens.OrderStatus.Inconclusive), "not started: inconclusive, not invalid");
        }
    }

    /// `n` rows, the poison one at index `at`, every other row honest.
    function _poisonAt(uint256 n, uint256 at)
        internal
        view
        returns (Order[] memory orders, bytes[] memory sigs, bytes[] memory takerDatas)
    {
        orders = new Order[](n);
        sigs = new bytes[](n);
        takerDatas = new bytes[](n);
        for (uint256 i; i < n; i++) {
            orders[i] = _plainOrder(i + 1, i == at ? address(poison) : address(tA), address(tB), IN_, OUT_);
            sigs[i] = _sign(orders[i]);
        }
    }

    /// One call under `gasLimit` MUST return — every row `Fillable` or
    /// `Inconclusive`, the poison row `Inconclusive`, nothing `Invalid`.
    function _assertReturns(Order[] memory orders, bytes[] memory sigs, bytes[] memory tds, uint256 at, uint256 gasLimit)
        internal
        view
    {
        try lens.getOrderRelevantStates{gas: gasLimit}(orders, sigs, solver, tds) returns (
            SettlementLens.OrderStatus[] memory st, uint256[] memory, bool[] memory, bool[] memory
        ) {
            assertEq(uint8(st[at]), uint8(SettlementLens.OrderStatus.Inconclusive), "poison row");
            for (uint256 i; i < st.length; i++) {
                assertTrue(
                    st[i] == SettlementLens.OrderStatus.Fillable || st[i] == SettlementLens.OrderStatus.Inconclusive,
                    "an honest row read as a verdict it never got"
                );
            }
        } catch {
            revert(string.concat("batch reverted at gas ", vm.toString(gasLimit), ", n ", vm.toString(orders.length)));
        }
    }

    /// RE-AUDIT 2026-09-29. The per-order cap kept a poison row from starving the
    /// rows after it — but the reserve behind it was per row only, so once the poison
    /// row had burned its whole budget the call could not always afford to MARK the
    /// rest: the short-circuit `Inconclusive` writes plus the return encoding ran it
    /// out of gas, and the WHOLE call reverted. PoC: poison at row 0, a 560k call,
    /// n ≥ 35; at 575k, n = 60 and n = 100. A row is now started only while every
    /// row after it can still be marked ({SettlementLens.ORDER_STATE_ROW_GAS}).
    ///
    /// The PoC points first, then a sweep across the whole band in which the poison
    /// row starts and leaves the call tight — including a poison row in the MIDDLE,
    /// after honest rows have grown the call's memory (the return encoding's
    /// per-word price rises with it).
    function test_lens_poisonRow_largeBatch_returnsNotReverts() public view {
        (Order[] memory o35, bytes[] memory s35, bytes[] memory t35) = _poisonAt(35, 0);
        _assertReturns(o35, s35, t35, 0, 560_000);
        (Order[] memory o60, bytes[] memory s60, bytes[] memory t60) = _poisonAt(60, 0);
        _assertReturns(o60, s60, t60, 0, 575_000);
        (Order[] memory o, bytes[] memory s, bytes[] memory t) = _poisonAt(100, 0);
        _assertReturns(o, s, t, 0, 560_000);
        _assertReturns(o, s, t, 0, 575_000);

        // Poison at row 0, n = 100: from "cannot start it" through "starts it with
        // the least headroom allowed" to "evaluates honest rows after it".
        for (uint256 g = 540_000; g <= 1_700_000; g += 5_000) {
            _assertReturns(o, s, t, 0, g);
        }
        // Poison in the middle of n = 60, after 30 honest rows.
        (o, s, t) = _poisonAt(60, 30);
        for (uint256 g = 700_000; g <= 3_500_000; g += 20_000) {
            _assertReturns(o, s, t, 30, g);
        }
    }

    /// Control: a genuinely malformed order is still `Invalid` — the cap narrowed
    /// only the out-of-gas case.
    function test_malformedOrder_stillInvalid() public view {
        Order[] memory orders = new Order[](2);
        orders[0] = _plainOrder(1, address(tA), address(tB), IN_, OUT_);
        orders[1] = _plainOrder(2, address(tA), address(tB), IN_, OUT_);
        orders[1].legsIn = hex"ff"; // not a valid packed blob → reverts inside the try
        (SettlementLens.OrderStatus[] memory st,) = _batch(orders, 3_000_000);
        assertEq(uint8(st[0]), uint8(SettlementLens.OrderStatus.Fillable), "honest");
        assertEq(uint8(st[1]), uint8(SettlementLens.OrderStatus.Invalid), "malformed");
    }

    /// The single-order view stays uncapped: a caller can still evaluate an order the
    /// batch reported Inconclusive with the whole call's budget.
    function test_singleOrderView_isUncapped() public view {
        assertEq(lens.ORDER_STATE_GAS(), 500_000);
        Order memory o = _plainOrder(1, address(tA), address(tB), IN_, OUT_);
        (SettlementLens.OrderStatus s, uint256 f,,) = lens.getOrderRelevantState(o, _sign(o), solver, "");
        assertEq(uint8(s), uint8(SettlementLens.OrderStatus.Fillable));
        assertEq(f, IN_);
    }
}
