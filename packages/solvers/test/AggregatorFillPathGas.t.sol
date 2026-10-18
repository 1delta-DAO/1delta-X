// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order} from "@core/settlement/Settlement.sol";
import {RoutePlan} from "../src/aggregator/AggregatorFillSolver.sol";

import {AggregatorZeroCapitalItemsTest, MockPreFundSupply} from "./AggregatorZeroCapitalItems.t.sol";
import {noGuard} from "./shared/AggDeploy.sol";

/// @notice Task 31 §4.6 — the measurement behind "is a third single-order callback mode
///         (pay inputs → callback → deliver → items) worth Settlement bytecode?".
///
///         The same item-free PULL order through `executeFill` (`fillWithCallback`,
///         `PostInputs`) and through `executeItemFill` (a one-order `matchSettle`)
///         isolates the netted path's fixed overhead — the most such a mode could save
///         per fill. The swap→supply order (pre-funded MAKE, only fillable on the netted
///         path) adds the item. Each figure is one call's execution gas from a fresh
///         test, so every bench pays the same cold accesses. `forge test --match-contract
///         AggregatorFillPathGas -vv` prints them.
contract AggregatorFillPathGasTest is AggregatorZeroCapitalItemsTest {
    function test_gas_path_itemFree_executeFill() public {
        Order memory o = _order(1);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _plan(address(aggSolver), AMOUNT_OUT);
        uint256 g0 = gasleft();
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
        emit log_named_uint("item-free pull, executeFill (PostInputs)  ", g0 - gasleft());
    }

    function test_gas_path_itemFree_executeItemFill() public {
        Order memory o = _order(1);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _plan(address(aggSolver), AMOUNT_OUT);
        uint256 g0 = gasleft();
        aggSolver.executeItemFill(o, sig, AMOUNT_IN, p, "", 0, _np(), noGuard());
        emit log_named_uint("item-free pull, executeItemFill (netted)  ", g0 - gasleft());
    }

    function test_gas_path_preFundSupply_executeItemFill() public {
        MockPreFundSupply m = new MockPreFundSupply(address(settlement), address(0x9001));
        Order memory o = _supplyOrder(3, m);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _plan(address(aggSolver), AMOUNT_OUT);
        uint256 g0 = gasleft();
        aggSolver.executeItemFill(o, sig, AMOUNT_IN, p, "", LATE0, _np(), noGuard());
        emit log_named_uint("swap->supply, executeItemFill (netted)    ", g0 - gasleft());
    }
}
