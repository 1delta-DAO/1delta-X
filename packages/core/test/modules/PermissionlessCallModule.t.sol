// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "../shared/PackedEncode.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {PermissionlessCallModule} from "@core/modules/PermissionlessCallModule.sol";

import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

/// @dev Stand-in for the permissionless pokes this module exists to compose into a
///      fill — an interest accrual, a harvest, an oracle update. Anyone may call it;
///      it records who and how often.
contract Accruer {
    uint256 public accruals;
    address public lastCaller;

    function accrue() external {
        accruals++;
        lastCaller = msg.sender;
    }

    function alwaysReverts() external pure {
        revert("nope");
    }
}

/// @dev {PermissionlessCallModule} — the reduced escape hatch. It runs ONE
///      maker-signed, permissionless call inline during a fill, from an identity
///      that holds no authority of any kind.
///
///      This replaced `GenericCallModule`, which additionally pulled a funding token
///      from the maker via Permit3 and therefore required makers to grant it a
///      standing Permit3 allowance. The 2026-08 audit showed that combination was a
///      drain: the arbitrary call runs from the MODULE's identity, and
///      `msg.sender == SETTLEMENT` does not bound `spec` (anyone can sign an order
///      naming themselves as maker), so an attacker's own order could make the module
///      call `permit3.transferFrom(victim, attacker, …)` against any allowance
///      another user had granted it. Removing the funding leg removes the reason
///      anyone would ever grant it one — see {test_moduleHoldsNoPermit3Reference}.
contract PermissionlessCallModuleTest is CoreSettlementBase {
    PermissionlessCallModule module;
    Accruer target;

    uint256 constant USDC_IN = 1_500e6;
    uint256 constant WETH_OUT = 1 ether;

    function setUp() public override {
        super.setUp();
        module = new PermissionlessCallModule(address(settlement));
        target = new Accruer();
        vm.label(address(module), "permissionlessCallModule");
        vm.label(address(target), "accruer");
    }

    function _callItem(uint256 amount, bytes memory callData) internal view returns (Item memory) {
        PermissionlessCallModule.CallSpec memory spec =
            PermissionlessCallModule.CallSpec({target: address(target), callData: callData});
        return Item({
            op: ItemOp.MAKE,
            module: address(module),
            amount: amount,
            recipient: address(0),
            data: abi.encode(spec)
        });
    }

    function _orderWithItem(uint256 nonce, Item memory it) internal view returns (Order memory) {
        Item[] memory items = new Item[](1);
        items[0] = it;
        return _order(maker, nonce, USDC, WETH, USDC_IN, WETH_OUT, items);
    }

    // ══════════════════════ Happy path ══════════════════════

    /// @dev A plain USDC→WETH swap that ALSO fires a maker-signed permissionless
    ///      poke mid-fill. The call runs from the MODULE, not from Settlement and
    ///      not from the maker — which is exactly why it may only ever be something
    ///      an anonymous caller could do anyway.
    function test_composedCall_runsMidFill() public {
        deal(USDC, maker, USDC_IN);
        deal(WETH, solver, WETH_OUT);
        _approveMakerToSettlement(USDC, USDC_IN);
        _approveSolverSide(WETH_OUT, WETH);

        Order memory order = _orderWithItem(0, _callItem(1, abi.encodeCall(Accruer.accrue, ())));
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, USDC_IN);

        assertEq(IERC20(WETH).balanceOf(maker), WETH_OUT, "maker received WETH");
        assertEq(IERC20(USDC).balanceOf(solver), USDC_IN, "solver received USDC");
        assertEq(target.accruals(), 1, "the composed call fired");
        assertEq(target.lastCaller(), address(module), "and it fired from the module's own identity");
    }

    /// @dev No funding leg means no allowance of any kind is needed to use it. The
    ///      maker approves Settlement for the SWAP input and nothing else.
    function test_noAllowanceToTheModuleIsRequired() public {
        deal(USDC, maker, USDC_IN);
        deal(WETH, solver, WETH_OUT);
        _approveMakerToSettlement(USDC, USDC_IN);
        _approveSolverSide(WETH_OUT, WETH);

        (uint160 allowed,) = permit3.tokenAllowance(maker, address(module), USDC);
        assertEq(allowed, 0, "no Permit3 allowance to the module");

        Order memory order = _orderWithItem(0, _callItem(1, abi.encodeCall(Accruer.accrue, ())));
        // Signed OUTSIDE the prank on purpose: `_sign` calls `DOMAIN_SEPARATOR()`,
        // which would otherwise consume the single-call prank and leave the fill
        // running as the test contract.
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, USDC_IN);
        assertEq(target.accruals(), 1, "it works anyway");
    }

    // ══════════════════════ Gates ══════════════════════

    /// @dev The direct-call gate. It does NOT make `spec` trustworthy (anyone can go
    ///      through Settlement as the maker of their own order); it only keeps the
    ///      module a Settlement-dispatched item rather than a public trampoline.
    function test_directCall_revertsOnlySettlement() public {
        PermissionlessCallModule.CallSpec memory spec =
            PermissionlessCallModule.CallSpec({target: address(target), callData: abi.encodeCall(Accruer.accrue, ())});

        vm.prank(address(0xBAD));
        vm.expectRevert(PermissionlessCallModule.OnlySettlement.selector);
        module.makeOnBehalf(maker, 1, abi.encode(spec));
    }

    /// @dev A failing call aborts the whole fill — the maker signed it as part of
    ///      the order, so it is not optional.
    function test_failingCall_revertsTheFill() public {
        deal(USDC, maker, USDC_IN);
        deal(WETH, solver, WETH_OUT);
        _approveMakerToSettlement(USDC, USDC_IN);
        _approveSolverSide(WETH_OUT, WETH);

        Order memory order = _orderWithItem(0, _callItem(1, abi.encodeCall(Accruer.alwaysReverts, ())));
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectPartialRevert(PermissionlessCallModule.CallFailed.selector);
        settlement.fill(order, sig, USDC_IN);
    }

    /// @dev `Base._runItem` skips a slice that floors to zero, so a partial fill too
    ///      small to accrue a whole unit of the item does not fire the call. That is
    ///      how a maker makes the poke proportional rather than per-fill.
    function test_zeroSlice_skipsTheCall() public {
        deal(USDC, maker, USDC_IN);
        deal(WETH, solver, WETH_OUT);
        _approveMakerToSettlement(USDC, USDC_IN);
        _approveSolverSide(WETH_OUT, WETH);

        // amount 1 over a 1_500e6 anchor ⇒ any fill below the full anchor floors to 0.
        Order memory order = _orderWithItem(0, _callItem(1, abi.encodeCall(Accruer.accrue, ())));
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, USDC_IN / 2);
        assertEq(target.accruals(), 0, "dust slice skipped the call");

        vm.prank(solver);
        settlement.fill(order, sig, USDC_IN / 2);
        assertEq(target.accruals(), 1, "and fires once the slice reaches 1");
    }

    // ══════════════════════ The regression guard ══════════════════════

    /// @dev SECURITY REGRESSION — the module must reference NO allowance book.
    ///
    ///      This is the whole safety argument, and it is structural rather than
    ///      behavioural, so it is asserted structurally: the deployed bytecode must
    ///      not contain the Permit3 address. The predecessor stored it as an
    ///      immutable (inlined into the runtime code) in order to pull funding, and
    ///      that pull is what made makers grant this shared, arbitrary-call contract
    ///      a standing allowance — which any attacker's self-signed order could then
    ///      spend, because the call runs from the module's own identity.
    ///
    ///      If someone re-adds a funding leg, this fails. Read the contract note
    ///      before deciding to make it pass again.
    function test_moduleHoldsNoPermit3Reference() public view {
        bytes memory code = address(module).code;
        bytes20 permit3Addr = bytes20(address(permit3));
        bool found;
        for (uint256 i; i + 20 <= code.length; i++) {
            bytes20 window;
            assembly {
                window := mload(add(add(code, 0x20), i))
            }
            if (window == permit3Addr) {
                found = true;
                break;
            }
        }
        assertFalse(found, "module must hold no reference to Permit3 - see the contract note");
    }
}
