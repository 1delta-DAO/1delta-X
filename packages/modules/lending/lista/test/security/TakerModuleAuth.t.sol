// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ListaTakerModule} from "../../src/ListaModules.sol";
import {ListaBrokerModule} from "../../src/ListaBrokerModule.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";
import {MarketParams} from "../../src/interfaces/ILista.sol";

/// @dev Both value-out entrypoints MUST reject any caller other than Permit3 —
/// otherwise a direct `takeOnBehalf` would bypass the Permit3 allowance gate and
/// drain the victim via their Moolah authorization / broker credit.
///
/// Since the broker surface was merged into one contract, this also pins the
/// OP-DISJOINTNESS that lets that contract host both seams: {ListaBrokerModule}
/// answers only op 1 on `takeOnBehalf` and only op 0 on `makeOnBehalf`, and
/// {ListaTakerModule} no longer answers op 0 at all (the borrow slot it vacated).
/// Without those, a grant signed for one dispatch could be spent on the other.
/// Runs without a fork.
contract ListaTakerModuleAuthTest is Test {
    ListaTakerModule taker;
    ListaBrokerModule broker;

    address permit3 = address(0xBEEF);
    address settlement = address(0x5E77);
    address maker = address(0xA11CE);
    address attacker = address(0xBAD);

    function setUp() public {
        taker = new ListaTakerModule(permit3);
        broker = new ListaBrokerModule(permit3, settlement);
    }

    function _borrowData() internal pure returns (bytes memory) {
        return abi.encode(uint8(ListaBrokerModule.Op.Borrow), address(0xB40E7), uint256(1_700000000));
    }

    function _repayData() internal pure returns (bytes memory) {
        return abi.encode(uint8(ListaBrokerModule.Op.Repay), address(0xB40E7), address(0x1041), uint256(1));
    }

    function _withdrawData() internal pure returns (bytes memory) {
        MarketParams memory mp =
            MarketParams(address(0x1041), address(0xC011), address(0x02AC), address(0x121A), 860000000000000000);
        return abi.encode(uint8(ListaTakerModule.Op.WithdrawCollateral), address(0x3011A), mp);
    }

    // ──────────────── the dispatch pins ────────────────

    function test_borrow_rejects_non_permit3() public {
        vm.prank(attacker);
        vm.expectRevert(PreFundModuleBase.OnlyPermit3.selector);
        broker.takeOnBehalf(maker, 1e18, attacker, _borrowData());
    }

    function test_withdraw_rejects_non_permit3() public {
        vm.prank(attacker);
        vm.expectRevert(ListaTakerModule.OnlyPermit3.selector);
        taker.takeOnBehalf(maker, 1e18, attacker, _withdrawData());
    }

    function test_repay_rejects_non_settlement() public {
        vm.prank(attacker);
        vm.expectRevert(PreFundGuard.OnlySettlement.selector);
        broker.makeOnBehalf(maker, 1e18, _repayData());
    }

    // ──────────────── the op walls between the two seams ────────────────

    /// A repay blob carries the maker's Permit3 TOKEN allowance, a borrow blob
    /// their TAKER allowance. Feeding either to the other entrypoint must die on
    /// the op, before any venue call — that is what makes hosting both seams on
    /// one contract safe without the {PreFundGuard.requirePlainTake}-style split
    /// the take/takeFor pair needs.
    function test_brokerModule_rejects_repayBlob_onTakeSeam() public {
        vm.prank(permit3);
        vm.expectRevert(
            abi.encodeWithSelector(ListaBrokerModule.BadOp.selector, uint256(uint8(ListaBrokerModule.Op.Repay)))
        );
        broker.takeOnBehalf(maker, 1e18, attacker, _repayData());
    }

    function test_brokerModule_rejects_borrowBlob_onMakeSeam() public {
        vm.prank(settlement);
        vm.expectRevert(
            abi.encodeWithSelector(ListaBrokerModule.BadOp.selector, uint256(uint8(ListaBrokerModule.Op.Borrow)))
        );
        broker.makeOnBehalf(maker, 1e18, _borrowData());
    }

    /// The vacated slot. `ListaTakerModule` kept op 0 RESERVED rather than
    /// renumbering, so a borrow blob pointed at the old module fails closed
    /// instead of decoding as a withdraw.
    function test_takerModule_rejects_theVacatedBorrowOp() public {
        vm.prank(permit3);
        vm.expectRevert(abi.encodeWithSelector(ListaTakerModule.BadOp.selector, uint8(0)));
        taker.takeOnBehalf(maker, 1e18, attacker, abi.encode(uint8(0), address(0xB40E7), uint256(1)));
    }
}
