// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order, Item, ItemOp, ItemPolicy, CurvePoint} from "@core/settlement/Structs.sol";
import {OrderGates} from "@core/settlement/OrderGates.sol";
import {OrderState} from "@core/settlement/OrderState.sol";
import {IFillModule} from "@core/interfaces/IFillModule.sol";
import {IProceedsAsset} from "@core/interfaces/IProceedsAsset.sol";
import {SettlementLens} from "@periphery/SettlementLens.sol";

import {MockSettlementBase} from "@coretest/shared/MockSettlementBase.t.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

/// @dev A fill module that accepts exactly the filler's proposal — so the
///      settler's `max`-resolution and request ceiling are what bound it.
contract EchoFillModule20260930 is IFillModule {
    function resolveFill(Order calldata, uint256, uint256 fillAmount, bytes calldata)
        external
        pure
        returns (uint256)
    {
        return fillAmount;
    }
}

/// @dev Ignores the proposal and asks for the whole remainder (the FullFillModule
///      shape) — a delta above a smaller request.
contract GreedyFillModule20260930 is IFillModule {
    function resolveFill(Order calldata order, uint256 prevFilled, uint256, bytes calldata)
        external
        pure
        returns (uint256)
    {
        return order.fillTotal - prevFilled;
    }
}

/// @dev A TAKE module that only answers {IProceedsAsset}.
contract ProceedsOnlyModule20260930 is IProceedsAsset {
    address public immutable ASSET;

    constructor(address a) {
        ASSET = a;
    }

    function proceedsAsset(bytes calldata) external view returns (address) {
        return ASSET;
    }
}

/// @title Audit 2026-09-30 — cross-component lens remediation
/// @notice CORE-FILL-1, CORE-FILL-4 / CORE-FILLER-2, CORE-MATCH-4 and PERIPH-1.v3
///         mirrored into {SettlementLens}: each test pins the lens to what the
///         settler does with the same order.
contract Audit20260930CrossLensTest is MockSettlementBase {
    uint256 constant IN_ = 1_000e18;
    uint256 constant OUT_ = 2e18;
    address constant EX = address(0xE0);

    // ═══════════ CORE-FILL-1: a zero placeholder leg carries no premium ═══════════

    function test_audit_CORE_FILL_1_lensFlagsZeroPlaceholderBuyInput() public {
        tB.mint(solver, OUT_);
        _solverApprove(address(settlement), address(tB), OUT_);
        Order memory o = _buyOrder(1, address(0), address(tB), 0, 0, OUT_);
        o.exclusiveFiller = EX;
        _setExclusivityEnd(o, block.timestamp + 1 hours);
        o.params = 500; // soft override

        (bool ok, string memory why) = lens.validateOrder(o);
        assertFalse(ok, "lens agrees the window is hard");
        assertEq(why, "override has no carrier leg (outsiders are refused in-window)");

        // The settler's verdict on the same order.
        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert(OrderGates.NotExclusiveFiller.selector);
        settlement.fill(o, sig, OUT_);
    }

    // ═══════════ CORE-FILL-4 / CORE-FILLER-2: module deltas in the preview ═══════════

    function _moduleOrder(uint256 nonce, address module) internal returns (Order memory o) {
        tA.mint(maker, IN_);
        _makerApprove(address(settlement), address(tA), type(uint160).max);
        tB.mint(solver, OUT_);
        _solverApprove(address(settlement), address(tB), type(uint160).max);
        o = _plainOrder(nonce, address(tA), address(tB), IN_, OUT_);
        o.fillModule = module;
        o.fillTotal = 10;
    }

    function test_audit_CORE_FILL_4_previewResolvesMaxBeforeTheModule() public {
        Order memory o = _moduleOrder(2, address(new EchoFillModule20260930()));
        // Before: the module was handed `max` as the proposal and the preview
        // panicked on `prevFilled + max`; the settler resolves it to the remainder.
        (uint256 d,, uint256[] memory paid) = lens.previewFill(o, type(uint256).max, solver, "");
        assertEq(d, 10, "max resolves to the remainder");
        bytes memory sig = _sign(o);
        vm.prank(solver);
        uint256[] memory outs = settlement.fill(o, sig, type(uint256).max);
        assertEq(paid[0], outs[0], "preview == fill");
        assertEq(settlement.filled(lens.hashOrder(o)), 10);
    }

    function test_audit_CORE_FILLER_2_previewRefusesModuleDeltaAboveRequest() public {
        Order memory o = _moduleOrder(3, address(new GreedyFillModule20260930()));
        // Before: previewed a 10-unit fill for a 1-unit request.
        vm.expectRevert(SettlementLens.OverFill.selector);
        lens.previewFill(o, 1, solver, "");
        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert(OrderState.OverFill.selector);
        settlement.fill(o, sig, 1);
        // The documented idiom: max (or the remainder) fills the whole order.
        (uint256 d,,) = lens.previewFill(o, type(uint256).max, solver, "");
        assertEq(d, 10);
    }

    // ═══════════ CORE-MATCH-4: item recipients that land on the settler side ═══════════

    function _takeOrder(uint256 nonce, address module, address recipient) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), IN_, OUT_);
        Item[] memory its = new Item[](1);
        its[0] = Item({op: ItemOp.TAKE, module: module, amount: IN_, recipient: recipient, data: hex"01"});
        o.items = PackedEncode.items(its);
    }

    function test_audit_CORE_MATCH_4_itemToExecutorFlagged() public {
        address m = address(new ProceedsOnlyModule20260930(address(tA)));
        Order memory ctl = _takeOrder(4, m, address(0));
        // An input-funding TAKE must sign CANONICAL (B8, 2026-10-06) to be a clean control.
        ctl.timing = ItemPolicy.pack(ctl.timing, ItemPolicy.CANONICAL);
        (bool ok,) = lens.validateOrder(ctl);
        assertTrue(ok, "control: proceeds in an input-leg token to the settler");

        Order memory o = _takeOrder(5, m, address(settlement.EXECUTOR()));
        string memory why;
        (ok, why) = lens.validateOrder(o);
        assertFalse(ok);
        assertEq(why, "item recipient is settlement executor (takeable)");
    }

    function test_audit_CORE_MATCH_4_explicitSettlementRecipientGetsProceedsCheck() public {
        // Proceeds in tC, which no input leg names: stranded on the settler.
        address m = address(new ProceedsOnlyModule20260930(address(tC)));
        (bool ok, string memory why) = lens.validateOrder(_takeOrder(6, m, address(0)));
        assertFalse(ok);
        assertEq(why, "item delivers a token no input leg can consume");
        // Before: an explicit `recipient == SETTLEMENT` skipped the check.
        (ok, why) = lens.validateOrder(_takeOrder(7, m, address(settlement)));
        assertFalse(ok, "explicit settlement recipient is checked like 0");
        assertEq(why, "item delivers a token no input leg can consume");
    }

    // ═══════════ PERIPH-1.v3: the lens names orders that need a price floor ═══════════

    function test_audit_PERIPH_1_v3_bumpFloorAdvised() public view {
        Order memory o = _plainOrder(8, address(tA), address(tB), IN_, OUT_);
        (bool adv, string memory mover) = lens.bumpFloorAdvised(o);
        assertFalse(adv, "a fixed order has no maker-ward mover");

        o.pricingModule = address(0xBEEF);
        (adv, mover) = lens.bumpFloorAdvised(o);
        assertTrue(adv);
        assertEq(mover, "price module");

        o.pricingModule = address(0);
        o.timing |= uint256(1) << 103;
        (adv, mover) = lens.bumpFloorAdvised(o);
        assertEq(mover, "priority auction");

        o = _plainOrder(9, address(tA), address(tB), IN_, OUT_);
        o.params = uint256(50) << 16; // gasBumpBps
        (adv, mover) = lens.bumpFloorAdvised(o);
        assertEq(mover, "gas bump");

        o = _plainOrder(10, address(tA), address(tB), IN_, OUT_);
        CurvePoint[] memory c = new CurvePoint[](2);
        c[0] = CurvePoint({timeDelta: 0, bumpBps: 6_000});
        c[1] = CurvePoint({timeDelta: 100, bumpBps: 2_000});
        o.curve = PackedEncode.curve(c);
        (adv, mover) = lens.bumpFloorAdvised(o);
        assertEq(mover, "descending curve segment");
        c[1].bumpBps = 9_000;
        o.curve = PackedEncode.curve(c);
        (adv,) = lens.bumpFloorAdvised(o);
        assertFalse(adv, "a rising curve only moves filler-ward");
    }
}
