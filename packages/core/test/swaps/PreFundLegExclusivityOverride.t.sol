// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MockSettlementBase, MockERC20} from "../shared/MockSettlementBase.t.sol";
import {PackedEncode} from "../shared/PackedEncode.sol";
import {Order} from "@core/settlement/Settlement.sol";
import {OrderGates} from "@core/settlement/OrderGates.sol";

/// @notice PoC — soft exclusivity is priced away on a PRE-FUND output leg.
///
///         `Pricing.outputAt` lifts the non-exclusive filler's price by
///         `overrideBps` only when `legRecipient == address(0) || == o.maker`.
///         `Base._forSlice`, however, blesses `legRecipient == module` as the
///         MAKER'S OWN funding leg ("same signer, same sizing, same net-zero
///         property") — it is the recipient a pre-fund descriptor REQUIRES.
///
///         So the two files answer "is this leg the maker's?" differently for the
///         same leg, and choosing the pre-fund spelling of an otherwise identical
///         order silently drops the maker's signed price improvement. On the
///         shipped leverage shape the module-addressed leg is the SOLE output and
///         the input leg is fixed (never overridden), so `overrideBps` becomes a
///         complete no-op and the exclusivity window is given away for free.
contract PreFundLegExclusivityOverrideTest is MockSettlementBase {
    address alice = address(0xA11CE01); // the exclusive filler
    address module = address(0x0D0DE); // stands in for a pre-fund module

    uint256 constant AMOUNT_IN = 1000e6;
    uint256 constant AMOUNT_OUT = 1000e18;
    uint256 constant OVERRIDE_BPS = 100; // 1%

    function _exclusiveOrder(uint256 nonce, address outRecipient) internal view returns (Order memory o) {
        o = _blank(nonce);
        o.legsIn = PackedEncode.oneLegIn(address(tA), AMOUNT_IN, 0); // FIXED → never overridden
        o.legsOut = PackedEncode.oneLegOut(address(tB), AMOUNT_OUT, 0, outRecipient);
        o.exclusiveFiller = alice;
        _setExclusivityEnd(o, block.timestamp + 60); // window is open
        o.params = OVERRIDE_BPS; // params bits [0:16) — soft exclusivity
    }

    function _fillAsOutsider(Order memory o) internal returns (uint256 paidByFiller) {
        bytes memory sig = _sign(o);

        tA.mint(maker, AMOUNT_IN);
        tB.mint(solver, AMOUNT_OUT * 2);
        _makerApprove(address(settlement), address(tA), type(uint160).max);
        _solverApprove(address(settlement), address(tB), type(uint160).max);

        uint256 before = tB.balanceOf(solver);
        vm.prank(solver); // solver != alice → a NON-exclusive, in-window filler
        settlement.fill(o, sig, AMOUNT_IN);
        paidByFiller = before - tB.balanceOf(solver);
    }

    function test_makerAddressedLeg_collectsTheOverride() public {
        uint256 paid = _fillAsOutsider(_exclusiveOrder(1, address(0)));
        assertEq(paid, (AMOUNT_OUT * (10_000 + OVERRIDE_BPS)) / 10_000, "maker leg should be lifted 1%");
    }

    /// THE BUG, closed (re-audit 2026-09-29). Identical economics, pre-fund spelling
    /// of the recipient: no leg can carry the premium (fixed input, sole output
    /// addressed away from the maker), so the outsider used to fill at the EXCLUSIVE
    /// price. `OrderGates.exclusivityOverride` now treats a soft window with no
    /// carrier as hard — the outsider is refused, and nothing moves.
    function test_moduleAddressedLeg_losesTheOverride() public {
        Order memory o = _exclusiveOrder(2, module);
        bytes memory sig = _sign(o);
        tA.mint(maker, AMOUNT_IN);
        tB.mint(solver, AMOUNT_OUT * 2);
        _makerApprove(address(settlement), address(tA), type(uint160).max);
        _solverApprove(address(settlement), address(tB), type(uint160).max);

        vm.prank(solver); // non-exclusive, in-window
        vm.expectRevert(OrderGates.NotExclusiveFiller.selector);
        settlement.fill(o, sig, AMOUNT_IN);
        assertEq(tB.balanceOf(solver), AMOUNT_OUT * 2, "outsider paid nothing");
        assertEq(tA.balanceOf(maker), AMOUNT_IN, "maker kept its input");
    }

    /// The same carrier rule, general shape (swap-and-send): a sole output to a
    /// THIRD PARTY, fixed input. Also refused in-window; the exclusive filler fills.
    function test_thirdPartyAddressedLeg_softWindowIsHard() public {
        Order memory o = _exclusiveOrder(3, address(0xB0B));
        bytes memory sig = _sign(o);
        tA.mint(maker, AMOUNT_IN);
        tB.mint(solver, AMOUNT_OUT);
        tB.mint(alice, AMOUNT_OUT);
        _makerApprove(address(settlement), address(tA), type(uint160).max);
        _solverApprove(address(settlement), address(tB), type(uint160).max);

        vm.prank(solver);
        vm.expectRevert(OrderGates.NotExclusiveFiller.selector);
        settlement.fill(o, sig, AMOUNT_IN);

        vm.startPrank(alice);
        MockERC20(address(tB)).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(tB), type(uint160).max, 0);
        settlement.fill(o, sig, AMOUNT_IN);
        vm.stopPrank();
        assertEq(tB.balanceOf(address(0xB0B)), AMOUNT_OUT, "exclusive filler delivers to the recipient");
    }

    /// An AUCTIONED input carries the premium, so the soft window stays soft even
    /// when the only output is addressed to a third party.
    function test_auctionedInput_keepsTheWindowSoft() public {
        Order memory o = _exclusiveOrder(4, address(0xB0B));
        o.legsIn = PackedEncode.oneLegIn(address(tA), AMOUNT_IN, AMOUNT_IN * 2); // rising input
        uint256 paid = _fillAsOutsider(o);
        assertEq(paid, AMOUNT_OUT, "output unchanged");
        assertLt(tA.balanceOf(solver), AMOUNT_IN * 2, "outsider charged less input: premium carried");
    }
}
