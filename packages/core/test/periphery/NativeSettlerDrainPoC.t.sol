// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, LegIn, LegOut, OrderSide, Validator, CallbackMode} from "@core/settlement/Settlement.sol";
import {NativeSettler} from "@core/periphery/NativeSettler.sol";
import {MockSettlementBase, MockERC20} from "../shared/MockSettlementBase.t.sol";

/// @dev Minimal WETH: same ERC20 book as {MockERC20} plus a `deposit()` that
///      mints to the depositor. Enough for `NativeSettler.settleFromNative`.
contract MockWETH {
    string public name = "WETH";
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
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

/// @dev A harmless "DEX route" that does nothing on any call (empty or not).
///      Stands in for the attacker-chosen `dexTarget`: the exploit needs no real
///      swap — the drain comes entirely from the forced allowance + delivery pull.
contract Noop {
    fallback() external payable {}
    receive() external payable {}
}

/// @title NativeSettlerDrainPoC
/// @notice REGRESSION test for the `NativeSettler` residue drain.
///
///         The attack: the attacker is the maker of an order they sign themselves,
///         so they fully control `order` (incl. `legsOut[0].token`) and `dexTarget`.
///         `settleFromNative` approves Settlement over the attacker-chosen output
///         token held by NativeSettler, then Settlement's `_deliverOutputs` pulls
///         that token FROM NativeSettler (the filler) via the direct-`transferFrom`
///         fallback — straight to the attacker. Against the pre-fix contract this
///         moved the entire balance for a cost of 1 wei.
///
///         What blocks it is the BALANCE FLOOR, and this test is written to prove
///         specifically that. Scoping the approval to `legsOut[0].start` does NOT
///         help on its own — the attacker simply signs `start` equal to the balance
///         they want, making the scoped approval exactly large enough. So the test
///         deliberately names the FULL residue as the output amount: it passes only
///         because the floor check rejects spending into the entry balance.
contract NativeSettlerDrainPoC is MockSettlementBase {
    // `maker` (makerPk 0xA11CE, inherited) plays the ATTACKER: they sign their
    // own order and are its maker, so `msg.sender == order.maker` passes trivially.
    address attacker;

    MockWETH weth;
    MockERC20 victimToken; // the residue token stranded in NativeSettler
    NativeSettler settler;
    Noop route;

    uint256 constant RESIDUE = 1_000_000e18; // NativeSettler's accumulated tokenOut slippage

    function setUp() public override {
        super.setUp(); // deploys permit3 + settlement (no fork)

        attacker = maker;
        vm.label(attacker, "attacker");

        weth = new MockWETH();
        victimToken = new MockERC20("victimToken");
        settler = new NativeSettler(address(weth), address(settlement));
        route = new Noop();

        vm.label(address(weth), "WETH");
        vm.label(address(victimToken), "victimToken");
        vm.label(address(settler), "nativeSettler");
        vm.label(address(route), "route");

        // Seed NativeSettler with the victim residue (no sweep function exists on
        // the contract — this models accumulated positive-slippage tokenOut).
        victimToken.mint(address(settler), RESIDUE);
    }

    function test_attacker_cannot_drain_nativeSettler_residue() public {
        // ── Pre-conditions ──
        assertEq(victimToken.balanceOf(address(settler)), RESIDUE, "settler seeded with residue");
        assertEq(victimToken.balanceOf(attacker), 0, "attacker starts with no victimToken");

        // 1) Attacker one-time setup: let Settlement pull the 1 wei WETH input that
        //    NativeSettler hands them (standing Permit3 allowance, like any router).
        vm.startPrank(attacker);
        weth.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(weth), uint160(1), 0);
        vm.stopPrank();

        // 2) Attacker signs their OWN order:
        //    SELL, maker = attacker, in = 1 wei WETH (anchor), out = the FULL
        //    residue of the attacker-chosen `victimToken`, delivered to the attacker.
        Order memory order = _blank(0);
        order.side = OrderSide.SELL;
        order.maker = attacker;
        order.legsIn = new LegIn[](1);
        order.legsIn[0] = LegIn(address(weth), 1, 0); // fixed 1-wei input, anchor
        order.legsOut = new LegOut[](1);
        order.legsOut[0] = LegOut(address(victimToken), RESIDUE, 0, attacker); // full residue → attacker

        bytes memory sig = _sign(order);

        // 3) dexTarget is a harmless no-op; dexCallData does nothing. The exploit
        //    needs no real swap.
        bytes memory dexCallData = "";

        // 4) Attacker self-settles with 1 wei of native ETH. The route produces no
        //    victimToken, so the only way to satisfy the output leg is to spend the
        //    entry balance — which the floor check refuses.
        vm.deal(attacker, 1);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(NativeSettler.PreexistingBalanceConsumed.selector, address(victimToken))
        );
        settler.settleFromNative{value: 1}(order, sig, 1, address(route), dexCallData);

        // ── ASSERT nothing moved ──
        assertEq(victimToken.balanceOf(attacker), 0, "attacker received nothing");
        assertEq(victimToken.balanceOf(address(settler)), RESIDUE, "residue untouched");
    }
}
