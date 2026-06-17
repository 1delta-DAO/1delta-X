// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {DolomiteModulesBase} from "../shared/DolomiteModulesBase.t.sol";
import {DolomiteTakeBase, DolomiteOperateModule} from "../../src/DolomiteModules.sol";

/// @dev The taker modules MUST reject any caller other than Permit3 — otherwise a
/// direct `takeOnBehalf(victim, amount, attacker, data)` would bypass the Permit3
/// allowance gate and drain the victim via their Dolomite operator grant.
contract DolomiteTakerModuleAuthTest is DolomiteModulesBase {
    address attacker = address(0xBAD);

    function test_withdraw_rejects_non_permit3() public {
        vm.prank(attacker);
        vm.expectRevert(DolomiteTakeBase.OnlyPermit3.selector);
        withdrawModule.takeOnBehalf(maker, 1 ether, attacker, _depositData());
    }

    function test_borrow_rejects_non_permit3() public {
        vm.prank(attacker);
        vm.expectRevert(DolomiteTakeBase.OnlyPermit3.selector);
        borrowModule.takeOnBehalf(maker, 1_000e6, attacker, _borrowData());
    }

    function test_operate_rejects_non_permit3() public {
        DolomiteOperateModule.BatchData memory p = DolomiteOperateModule.BatchData({
            mode: uint256(DolomiteOperateModule.BatchMode.Close),
            dolomite: address(DOLOMITE),
            collMarketId: COLL_MARKET,
            collToken: COLL,
            borrowMarketId: DEBT_MARKET,
            borrowToken: DEBT,
            accountNumber: ACCOUNT,
            sideAmount: 1_000e6
        });
        vm.prank(attacker);
        vm.expectRevert(DolomiteOperateModule.OnlyPermit3.selector);
        operateModule.takeOnBehalf(maker, 1 ether, attacker, abi.encode(p));
    }
}
