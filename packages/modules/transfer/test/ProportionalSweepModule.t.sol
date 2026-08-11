// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {ProportionalSweepModule} from "../src/ProportionalSweepModule.sol";
import {Proportional} from "@core/settlement/Proportional.sol";

// ── Mocks ─────────────────────────────────────────────────────────────────────

contract MockERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function move(address from, address to, uint256 amount) external {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev Records what the module asked Permit3 to do. Deliberately does NOT model
///      allowances — the point of these tests is WHICH transfer is requested, and
///      above all whose tokens it names as the source.
contract MockPermit3 {
    address public lastUser;
    address public lastTo;
    address public lastToken;
    uint256 public lastAmount;
    uint256 public callCount;

    function transferFrom(address user, address to, address token, uint160 amount) external {
        lastUser = user;
        lastTo = to;
        lastToken = token;
        lastAmount = amount;
        callCount++;
        MockERC20(token).move(user, to, amount);
    }
}

contract ProportionalSweepModuleTest is Test {
    ProportionalSweepModule module;
    MockPermit3 permit3;
    MockERC20 usdt;

    address settlement = address(0x5E77);
    address maker = address(0xAA4E12);
    address filler = address(0xF111E4AB);
    address attacker = address(0xBAD);

    function setUp() public {
        permit3 = new MockPermit3();
        module = new ProportionalSweepModule(settlement, address(permit3));
        usdt = new MockERC20();
    }

    function _data(uint256 bps) internal view returns (bytes memory) {
        return abi.encode(address(usdt), Proportional.encode(bps));
    }

    // ──────────────────── The sweep ────────────────────

    function test_sweep_pullsWholeBalanceToFiller() public {
        usdt.mint(maker, 5_000e6);

        vm.prank(settlement);
        module.settle(maker, filler, 10_000e6 /* cap */, _data(10_000));

        assertEq(usdt.balanceOf(maker), 0, "maker swept");
        assertEq(usdt.balanceOf(filler), 5_000e6, "filler received the sweep");
        assertEq(permit3.lastUser(), maker, "pulled FROM the maker");
        assertEq(permit3.lastTo(), filler, "delivered TO the filler");
    }

    /// The signed item `amount` is the cap — the same role `end` plays on a
    /// proportional leg. This is the check that stops a balance that grew after
    /// signing from being sold at the price of a much smaller one.
    function test_sweep_clampsToSignedCap() public {
        usdt.mint(maker, 9_000e6);

        vm.prank(settlement);
        module.settle(maker, filler, 2_000e6 /* cap */, _data(10_000));

        assertEq(usdt.balanceOf(filler), 2_000e6, "clamped to the cap");
        assertEq(usdt.balanceOf(maker), 7_000e6, "maker keeps the excess");
    }

    function test_sweep_fractionalBps() public {
        usdt.mint(maker, 1_000e6);

        vm.prank(settlement);
        module.settle(maker, filler, 1_000e6, _data(2_500)); // 25%

        assertEq(usdt.balanceOf(filler), 250e6, "swept a quarter");
    }

    /// A maker holding none of this token is a no-op, not a revert: it leaves them
    /// strictly better off, and reverting would make an otherwise-fillable
    /// multi-token order unfillable the moment one balance hit zero.
    function test_sweep_zeroBalance_isNoOp() public {
        vm.prank(settlement);
        module.settle(maker, filler, 1_000e6, _data(10_000));

        assertEq(permit3.callCount(), 0, "no transfer attempted");
    }

    // ──────────────────── Authority ────────────────────

    /// The gate that makes the maker's order signature the sole authority over
    /// `(module, amount, data)`.
    function test_onlySettlementMayInvoke() public {
        usdt.mint(maker, 1_000e6);

        vm.prank(attacker);
        vm.expectRevert(ProportionalSweepModule.OnlySettlement.selector);
        module.settle(maker, attacker, 1_000e6, _data(10_000));
    }

    /// THE test. This is the shape that sank `GenericCallModule`: a shared module
    /// holding standing Permit3 allowances, driven by attacker-authored order data.
    /// It is safe here only because the PAYER comes from Settlement (`order.maker`,
    /// signature-bound) and never from `data` — so an attacker signing their own
    /// order can only ever sweep themselves.
    function test_attackerOrderCannotNameAVictimAsPayer() public {
        address victim = address(0xC71AC0);
        usdt.mint(victim, 100_000e6);
        usdt.mint(attacker, 1e6);

        // The attacker signs an order naming THEMSELVES as maker (the only thing
        // they can do — the order hash is maker-bound) and fills it themselves.
        // Settlement therefore passes `maker = attacker`.
        vm.prank(settlement);
        module.settle(attacker, attacker, type(uint128).max, _data(10_000));

        assertEq(usdt.balanceOf(victim), 100_000e6, "victim untouched");
        assertEq(permit3.lastUser(), attacker, "payer is the attacker, never a spec-supplied address");
        assertEq(usdt.balanceOf(attacker), 1e6, "attacker only moved their own tokens, to themselves");
    }

    // ──────────────────── Encoding guards ────────────────────

    /// Raw bps is an ordinary small integer, so without this it would resolve as a
    /// nonsense absolute amount rather than failing.
    function test_rawBpsInsteadOfMarker_reverts() public {
        usdt.mint(maker, 1_000e6);

        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(ProportionalSweepModule.NotAProportionalMarker.selector, uint256(10_000)));
        module.settle(maker, filler, 1_000e6, abi.encode(address(usdt), uint256(10_000)));
    }

    /// The cap is mandatory, enforced by the shared library — so a sweep item and a
    /// sweep leg cannot disagree about it.
    function test_zeroCap_reverts() public {
        usdt.mint(maker, 1_000e6);

        vm.prank(settlement);
        vm.expectRevert(Proportional.ProportionalNeedsCap.selector);
        module.settle(maker, filler, 0, _data(10_000));
    }

    function testFuzz_sweep_neverExceedsCapOrBalance(uint256 balance, uint256 cap, uint16 bps) public {
        balance = bound(balance, 0, type(uint128).max);
        cap = bound(cap, 1, type(uint128).max);
        uint256 b = bound(uint256(bps), 1, 10_000);
        usdt.mint(maker, balance);

        vm.prank(settlement);
        module.settle(maker, filler, cap, _data(b));

        uint256 swept = usdt.balanceOf(filler);
        assertLe(swept, cap, "never above the signed cap");
        assertLe(swept, balance, "never above the balance");
        assertEq(swept, (balance * b) / 10_000 > cap ? cap : (balance * b) / 10_000, "exact");
    }
}
