// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "../shared/PackedEncode.sol";
import {MockSettlementBase, MockERC20} from "../shared/MockSettlementBase.t.sol";

import {IOrderValidator} from "@core/interfaces/IOrderValidator.sol";
import {Order, Validator} from "@core/settlement/Settlement.sol";
import {OrderGates} from "@core/settlement/OrderGates.sol";

/// @dev A THIRD-PARTY end-state invariant — not one of the shipped validators, so it
///      carries no {InvariantReceiptGuard} of its own: "the maker holds at least
///      `min` of `token` when the fill ends". Stateless, so it cannot tell THIS
///      fill's delivery from any other inflow.
contract AuditMakerHoldsInvariant is IOrderValidator {
    function validate(Order calldata order, address, bytes calldata data, bytes calldata)
        external
        view
        returns (bool)
    {
        (address token, uint256 min) = abi.decode(data, (address, uint256));
        return MockERC20(token).balanceOf(order.maker) >= min;
    }
}

/// @title Audit20260930InvariantReceiptTest
/// @notice VAL-1 (2026-09-30 audit), the generic core half: an order whose ONLY
///         receipt is a post-execution invariant (no output leg) is fillable only by
///         its named `exclusiveFiller`, for the order's whole life — whatever the
///         invariant contract is. Before the fix, any filler could collect the
///         maker's payment once the maker obtained the asset elsewhere.
contract Audit20260930InvariantReceiptTest is MockSettlementBase {
    uint256 constant PAY = 1_000e18;
    uint256 constant WANT = 5e18;

    AuditMakerHoldsInvariant inv;
    address namedFiller = makeAddr("namedFiller");

    function setUp() public override {
        super.setUp();
        inv = new AuditMakerHoldsInvariant();
    }

    /// @dev "Pay PAY tA; receipt = I hold >= WANT tB afterwards" — no output leg.
    function _purchase(uint256 nonce, address exclusive) internal view returns (Order memory o) {
        o = _blank(nonce);
        o.legsIn = _legsIn1(address(tA), PAY);
        Validator[] memory vs = new Validator[](1);
        vs[0] = Validator({target: address(inv), data: abi.encode(address(tB), WANT)});
        o.invariants = PackedEncode.validators(vs);
        o.exclusiveFiller = exclusive;
    }

    function _fundMaker(uint256 amt) internal {
        tA.mint(maker, amt);
        _makerApprove(address(settlement), address(tA), amt);
    }

    /// @dev The PoC shape: the maker bought the asset elsewhere (or a second bid of
    ///      theirs was filled); an open order is now a free payout to any bot.
    function test_audit_VAL_1_core_thirdPartyInvariant_openOrder_noFreePayout() public {
        _fundMaker(PAY);
        tB.mint(maker, WANT); // the end state is already true — no delivery needed
        Order memory o = _purchase(1, address(0));
        bytes memory sig = _sign(o);

        vm.prank(solver);
        vm.expectRevert(OrderGates.NotExclusiveFiller.selector);
        settlement.fill(o, sig, PAY);

        assertEq(tA.balanceOf(maker), PAY, "maker's payment untouched");
        assertEq(tA.balanceOf(solver), 0, "the bot collected nothing");
    }

    /// @dev The rule is LIFELONG: an exclusivity window that has lapsed (here it is
    ///      0, i.e. never open) does not admit anyone else; the named filler fills.
    function test_audit_VAL_1_core_namedFiller_only_forWholeLife() public {
        _fundMaker(PAY);
        Order memory o = _purchase(2, namedFiller);
        bytes memory sig = _sign(o);
        tB.mint(maker, WANT);

        vm.prank(solver);
        vm.expectRevert(OrderGates.NotExclusiveFiller.selector);
        settlement.fill(o, sig, PAY);

        vm.prank(namedFiller);
        settlement.fill(o, sig, PAY);
        assertEq(tA.balanceOf(namedFiller), PAY, "the named filler is paid");
    }

    /// @dev `FILLER_SET` can never be a caller, so such an order fails closed.
    function test_audit_VAL_1_core_fillerSetSentinel_failsClosed() public {
        _fundMaker(PAY);
        tB.mint(maker, WANT);
        Order memory o = _purchase(3, OrderGates.FILLER_SET);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert(OrderGates.NotExclusiveFiller.selector);
        settlement.fill(o, sig, PAY);
    }

    /// @dev The batch path threads the same filler and gets the same refusal.
    function test_audit_VAL_1_core_batchFill_refusesOpenFiller() public {
        _fundMaker(PAY);
        tB.mint(maker, WANT);
        Order[] memory os = new Order[](1);
        os[0] = _purchase(4, address(0));
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(os[0]);
        vm.prank(solver);
        (, bool[] memory ok) = settlement.batchFill(os, sigs, _u1(PAY), false, _u1(0), new bytes[](1));
        assertFalse(ok[0], "skipped");
        assertEq(tA.balanceOf(solver), 0, "nothing paid");
    }

    /// @dev An order WITH an output leg is untouched: the leg is the receipt and the
    ///      invariant only an extra floor (the FoT MinBalance use) — any filler.
    function test_audit_VAL_1_core_outputLegOrder_openFillerUnaffected() public {
        _fundMaker(PAY);
        Order memory o = _purchase(5, address(0));
        o.legsOut = _legsOut1(address(tB), WANT);
        bytes memory sig = _sign(o);
        tB.mint(solver, WANT);
        _solverApprove(address(settlement), address(tB), WANT);

        vm.prank(solver);
        settlement.fill(o, sig, PAY);
        assertEq(tB.balanceOf(maker), WANT, "delivered");
        assertEq(tA.balanceOf(solver), PAY, "paid");
    }
}
