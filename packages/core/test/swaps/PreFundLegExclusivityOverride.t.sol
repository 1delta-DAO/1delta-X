// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MockSettlementBase, MockERC20} from "../shared/MockSettlementBase.t.sol";
import {PackedEncode} from "../shared/PackedEncode.sol";
import {Order} from "@core/settlement/Settlement.sol";

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

    /// THE BUG. Identical economics, pre-fund spelling of the recipient, and the
    /// non-exclusive filler pays the EXCLUSIVE price.
    function test_moduleAddressedLeg_losesTheOverride() public {
        uint256 paid = _fillAsOutsider(_exclusiveOrder(2, module));
        assertEq(paid, AMOUNT_OUT, "override was silently skipped on the pre-fund leg");

        // And the maker is short by exactly the improvement they signed for.
        assertEq(
            (AMOUNT_OUT * (10_000 + OVERRIDE_BPS)) / 10_000 - paid,
            (AMOUNT_OUT * OVERRIDE_BPS) / 10_000,
            "shortfall == the whole signed override"
        );
    }
}
