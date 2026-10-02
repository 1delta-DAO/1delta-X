// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {IPositionSource} from "@core/interfaces/IPositionSource.sol";
import {PositionFillModule} from "@lib/PositionFillModule.sol";

import {DolomiteModulesBase} from "../shared/DolomiteModulesBase.t.sol";
import {DolomiteOperatorModule} from "../../src/DolomiteOperatorModule.sol";
import {AccountInfo, WeiBalance} from "../../src/interfaces/IDolomite.sol";

interface IDolomiteWeiView {
    function getAccountWei(AccountInfo calldata account, uint256 marketId) external view returns (WeiBalance memory);
}

/// @title Audit 2026-09-30 L-LIB-8 — DolomiteOperatorModule reports the live position
/// @notice The `Withdraw` op had a `BalanceMode.Full` branch but no {IPositionSource}
///         reader, so a position-sized exit reverted `NoPositionItem`. Raw
///         staticcalls so the test compiles — and fails — against the pre-fix module.
contract PositionSourceDolomiteTest is DolomiteModulesBase {
    function test_audit_L_LIB_8_dolomitePositionOfAndPositionSizedFill() public {
        _seedDolomiteCollateral(2 ether);
        (bool ok, bytes memory ret) =
            address(operatorModule).staticcall(abi.encodeCall(IPositionSource.positionOf, (maker, _withdrawData())));
        assertTrue(ok && ret.length == 64, "operator module answers positionOf");
        (address asset, uint256 amount) = abi.decode(ret, (address, uint256));
        WeiBalance memory w = IDolomiteWeiView(address(DOLOMITE)).getAccountWei(AccountInfo(maker, ACCOUNT), COLL_MARKET);
        assertEq(asset, COLL);
        assertEq(amount, w.value, "the live positive Wei balance");
        assertApproxEqAbs(amount, 2 ether, 2);

        // A non-withdraw op has no position to size.
        (ok,) = address(operatorModule).staticcall(abi.encodeCall(IPositionSource.positionOf, (maker, _borrowData())));
        assertFalse(ok, "borrow op refused");

        PositionFillModule pfm = new PositionFillModule();
        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE, address(operatorModule), 3 ether, address(0), _withdrawData());
        Order memory o = _order(maker, 9, COLL, DEBT, 3 ether, 1_000e6, items);
        o.fillModule = address(pfm);
        o.fillTotal = 3 ether;
        assertEq(pfm.resolveFill(o, 0, type(uint256).max, ""), amount, "fill sized from the position");
    }
}
