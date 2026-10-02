// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {IPositionSource} from "@core/interfaces/IPositionSource.sol";
import {PositionFillModule} from "@lib/PositionFillModule.sol";

import {MidnightModulesBase} from "../shared/MidnightModulesBase.t.sol";

/// @title Audit 2026-09-30 L-LIB-8 — MidnightTakerModule reports the live position
/// @notice Both ops had `Full` withdraws but no {IPositionSource} reader, so a
///         position-sized exit reverted `NoPositionItem`. The credit side reports
///         the UPDATED credit (the stale `credit()` would over-size — L-ML-3).
contract PositionSourceMidnightTest is MidnightModulesBase {
    function _pos(bytes memory data) internal view returns (bool ok, address asset, uint256 amount) {
        bytes memory ret;
        (ok, ret) = address(takerModule).staticcall(abi.encodeCall(IPositionSource.positionOf, (maker, data)));
        if (ok && ret.length == 64) (asset, amount) = abi.decode(ret, (address, uint256));
    }

    function test_audit_L_LIB_8_midnightCollateralPosition() public {
        _seedCollateral(maker, 7e18);
        (bool ok, address asset, uint256 amount) = _pos(_withdrawCollateralData(0, 0));
        assertTrue(ok, "taker module answers positionOf");
        assertEq(asset, address(COLL));
        assertEq(amount, 7e18);

        PositionFillModule pfm = new PositionFillModule();
        Item[] memory items = new Item[](1);
        items[0] = _item(ItemOp.TAKE, address(takerModule), 10e18, _withdrawCollateralData(0, 0));
        Order memory o = _order(maker, 1, address(COLL), address(LOAN), 10e18, 1e18, items);
        o.fillModule = address(pfm);
        o.fillTotal = 10e18;
        assertEq(pfm.resolveFill(o, 0, type(uint256).max, ""), 7e18, "fill sized from the position");
    }

    function test_audit_L_LIB_8_midnightCreditPositionIsTheUpdatedCredit() public {
        _seedCredit(maker, 5e18);
        midnight.setPendingCreditCut(_market(), maker, 1e18); // a pending slash
        (bool ok, address asset, uint256 amount) = _pos(_withdrawCreditData(0, 0));
        assertTrue(ok);
        assertEq(asset, address(LOAN));
        assertEq(amount, 4e18, "slash applied: the figure a Full withdraw redeems");
        assertEq(_creditOf(maker), 5e18, "the stored credit() is stale");
    }
}
