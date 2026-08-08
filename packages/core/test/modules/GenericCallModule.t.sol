// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "../shared/PackedEncode.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {Order, Item, ItemOp, Validator, OrderSide} from "@core/settlement/Settlement.sol";
import {GenericCallModule} from "@core/modules/GenericCallModule.sol";

import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

/// @dev Minimal ERC20 for the arbitrary-call funding token — freely mintable, so
///      the call side-effect is fully controlled without touching fork state.
contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev The "solver callback" target: a stand-in for whatever custom logic a
///      solver wants composed into a fill. `pull` draws the module-approved
///      funding token in and records receipt, proving the maker-signed call
///      executed mid-fill with real funds behind it.
contract CallTarget {
    mapping(address => uint256) public received;

    function pull(address token, uint256 amount) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        received[token] += amount;
    }
}

/// @dev Coverage for the module-based solver-callback path (Option B): a maker
/// signs an `Item{MAKE, GenericCallModule}` and an arbitrary contract call runs
/// inline during the fill, funded by a Permit3 pull from the maker and gated by
/// the module's own allowance — with NO change to the settlement core. Proves:
///   • the composed call fires mid-fill alongside a normal swap, funded correctly;
///   • a direct call to the module (bypassing the maker signature) reverts;
///   • the call is hard-capped by the maker's per-module Permit3 allowance.
contract GenericCallModuleTest is CoreSettlementBase {
    GenericCallModule module;
    CallTarget target;
    MockToken act; // arbitrary "action" token the composed call spends

    uint256 constant USDC_IN = 1_500e6;
    uint256 constant WETH_OUT = 1 ether;
    uint256 constant ACT_AMT = 100e18;

    function setUp() public override {
        super.setUp();
        module = new GenericCallModule(address(permit3), address(settlement));
        target = new CallTarget();
        act = new MockToken();
        vm.label(address(module), "genericCallModule");
        vm.label(address(target), "callTarget");
        vm.label(address(act), "actToken");

        // Maker funds + approvals for the composed call's token.
        act.mint(maker, 1_000e18);
        vm.startPrank(maker);
        act.approve(address(permit3), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Build the MAKE item that runs the arbitrary maker-signed call.
    function _callItem(address token, uint256 amount, bytes memory callData) internal view returns (Item memory) {
        GenericCallModule.CallSpec memory spec =
            GenericCallModule.CallSpec({token: token, target: address(target), callData: callData});
        return
            Item({
                op: ItemOp.MAKE, module: address(module), amount: amount, recipient: address(0), data: abi.encode(spec)
            });
    }

    function _orderWithItem(uint256 nonce, Item memory it) internal view returns (Order memory) {
        Item[] memory items = new Item[](1);
        items[0] = it;
        return Order({
            maker: maker,
            nonce: nonce,
            deadline: block.timestamp + 1 hours,
            legsIn: _legsIn1(USDC, USDC_IN),
            legsOut: _legsOut1(WETH, WETH_OUT),
            timing: 0,
            exclusiveFiller: address(0),
            minFillAnchor: 0,
            exclusivityOverrideBps: 0,
            curve: PackedEncode.noCurve(),
            gasBumpBps: 0,
            gasPriceRef: 0,
            items: PackedEncode.items(items),
            validators: PackedEncode.noValidators(),
            invariants: PackedEncode.noValidators(),
            fillModule: address(0),
            fillTotal: 0
        });
    }

    // ══════════════════════ Happy path ══════════════════════
    //
    // A plain USDC→WETH swap that ALSO composes an arbitrary call: the maker's
    // signed item spends 100 ACT into `CallTarget.pull` mid-fill. This is the
    // "inject a solver callback" capability, delivered purely through the
    // existing Item mechanism.

    function test_composedCall_runsMidFill_funded() public {
        deal(USDC, maker, USDC_IN);
        deal(WETH, solver, WETH_OUT);
        _approveMakerToSettlement(USDC, USDC_IN);
        _approveSolverSide(WETH_OUT, WETH);

        // Maker caps this module at exactly the call's spend.
        vm.prank(maker);
        permit3.approveToken(address(module), address(act), uint160(ACT_AMT), uint48(block.timestamp + 1 hours));

        bytes memory callData = abi.encodeWithSelector(CallTarget.pull.selector, address(act), ACT_AMT);
        Order memory order = _orderWithItem(0, _callItem(address(act), ACT_AMT, callData));
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, USDC_IN);

        // Swap settled normally.
        assertEq(IERC20(WETH).balanceOf(maker), WETH_OUT, "maker received WETH");
        assertEq(IERC20(USDC).balanceOf(solver), USDC_IN, "solver received USDC");
        // Composed call executed with the maker's funds.
        assertEq(target.received(address(act)), ACT_AMT, "call target received the ACT");
        assertEq(act.balanceOf(maker), 1_000e18 - ACT_AMT, "maker ACT spent");
        assertEq(act.balanceOf(address(module)), 0, "module ends empty");
    }

    // ══════════════════════ Direct-call gate ══════════════════════
    //
    // The whole safety of an arbitrary-call module rests on the maker's
    // signature authorising `data`. Bypassing Settlement (a direct call with
    // attacker-chosen data) must revert.

    function test_directCall_revertsOnlySettlement() public {
        bytes memory callData = abi.encodeWithSelector(CallTarget.pull.selector, address(act), ACT_AMT);
        GenericCallModule.CallSpec memory spec =
            GenericCallModule.CallSpec({token: address(act), target: address(target), callData: callData});

        vm.prank(address(0xBAD));
        vm.expectRevert(GenericCallModule.OnlySettlement.selector);
        module.makeOnBehalf(maker, ACT_AMT, abi.encode(spec));
    }

    // ══════════════════════ Allowance cap bounds the call ══════════════════════
    //
    // Even a maker-signed call can only spend up to the module's Permit3
    // allowance × the item slice. A call that tries to pull more than the module
    // was funded reverts (the module only approved `amount`), aborting the fill.

    function test_composedCall_cappedByAllowance() public {
        deal(USDC, maker, USDC_IN);
        deal(WETH, solver, WETH_OUT);
        _approveMakerToSettlement(USDC, USDC_IN);
        _approveSolverSide(WETH_OUT, WETH);

        vm.prank(maker);
        permit3.approveToken(address(module), address(act), uint160(ACT_AMT), uint48(block.timestamp + 1 hours));

        // Item slice funds/approves 100 ACT, but the call demands 200 → target's
        // transferFrom exceeds the module's approval and reverts → CallFailed.
        bytes memory callData = abi.encodeWithSelector(CallTarget.pull.selector, address(act), ACT_AMT * 2);
        Order memory order = _orderWithItem(0, _callItem(address(act), ACT_AMT, callData));
        bytes memory sig = _sign(order);

        vm.prank(solver);
        // CallFailed wraps the target's revert data as an arg, so match on the
        // selector only.
        vm.expectPartialRevert(GenericCallModule.CallFailed.selector);
        settlement.fill(order, sig, USDC_IN);
    }
}
