// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {MockSettlementBase, MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {Proportional} from "@core/settlement/Proportional.sol";
import {ProportionalSweepModule} from "../src/ProportionalSweepModule.sol";

/// @dev The INLINE `uint160` guard in {ProportionalSweepModule.settle}, driven
///      end-to-end through a real {Settlement.fill}.
///
///  Why this site needs its own test: the core's `uint160` width check
///  (`Base._runItem`) deliberately EXEMPTS `ItemOp.SETTLE` — a SETTLE module's
///  interface is `uint256` and a wide slice is meaningful there. So the sweep cap
///  arrives un-narrowed, and the resolved `pull = min(balance * bps, cap)` is the
///  first place anything checks it against Permit3's `uint160` book. Without the
///  guard, `uint160(pull)` would wrap `2^160` to ZERO and a maker's "sweep 100%"
///  item would silently move nothing (or `2^160 + k` would move `k`).
///
///  The two tests pin the exact boundary: `2^160` reverts with the module's
///  `AmountOverflow` and moves nothing; `type(uint160).max` passes the guard and
///  is pulled in full.
contract ProportionalSweepNarrow160Test is MockSettlementBase {
    ProportionalSweepModule sweep;
    MockERC20 swept; // the swept token — freely mintable past 2^160

    uint256 constant IN = 1_000e18; // tA the maker sells on the typed leg
    uint256 constant OUT = 900e18; // tB the solver delivers
    uint256 constant FINITE_SWEEP_ALLOWANCE = 1e30; // a non-infinite book entry, so "unchanged" is observable

    function setUp() public override {
        super.setUp();
        sweep = new ProportionalSweepModule(address(settlement), address(permit3));
        swept = new MockERC20("swept");
        vm.label(address(sweep), "proportionalSweep");

        tA.mint(maker, IN);
        tB.mint(solver, OUT);
        _makerApprove(address(settlement), address(tA), IN);
        _solverApprove(address(settlement), address(tB), OUT);
    }

    /// @dev Plain tA→tB order carrying one SETTLE sweep item: 100% of the maker's
    ///      `swept` balance to the filler, capped at `cap` (the signed item amount).
    function _sweepOrder(uint256 nonce, uint256 cap) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), IN, OUT);
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.SETTLE,
            module: address(sweep),
            amount: cap,
            recipient: address(0),
            data: abi.encode(address(swept), Proportional.encode(10_000))
        });
        o.items = PackedEncode.items(items);
    }

    function _sweepAllowance() internal view returns (uint160 amt) {
        (amt,) = permit3.tokenAllowance(maker, address(sweep), address(swept));
    }

    /// `pull = 2^160` (balance and signed cap both exactly one past the book
    /// width): the fill reverts with the module's own `AmountOverflow` — the core
    /// did not stop it, because SETTLE slices are exempt — and nothing moves.
    function test_narrow160_proportionalSweepPull_reverts() public {
        uint256 overflow = uint256(type(uint160).max) + 1;
        swept.mint(maker, overflow);
        _makerApprove(address(sweep), address(swept), FINITE_SWEEP_ALLOWANCE);

        Order memory o = _sweepOrder(1, overflow);
        bytes memory sig = _sign(o);

        uint256 makerSwept = swept.balanceOf(maker);
        uint256 solverSwept = swept.balanceOf(solver);
        uint256 makerA = tA.balanceOf(maker);
        uint256 solverB = tB.balanceOf(solver);
        uint160 sweepAllowance = _sweepAllowance();
        (uint160 settleAllowance,) = permit3.tokenAllowance(maker, address(settlement), address(tA));

        vm.prank(solver);
        vm.expectRevert(ProportionalSweepModule.AmountOverflow.selector);
        settlement.fill(o, sig, IN);

        assertEq(swept.balanceOf(maker), makerSwept, "maker's swept balance untouched");
        assertEq(swept.balanceOf(solver), solverSwept, "filler received nothing");
        assertEq(swept.balanceOf(address(sweep)), 0, "module holds nothing");
        assertEq(tA.balanceOf(maker), makerA, "maker's typed input leg not pulled");
        assertEq(tB.balanceOf(solver), solverB, "solver's output leg not pulled");
        assertEq(_sweepAllowance(), sweepAllowance, "maker->sweep Permit3 allowance unchanged");
        (uint160 settleAfter,) = permit3.tokenAllowance(maker, address(settlement), address(tA));
        assertEq(settleAfter, settleAllowance, "maker->settlement Permit3 allowance unchanged");
    }

    /// Boundary: `pull = type(uint160).max` is the widest amount Permit3 can
    /// book, so the guard lets it through and the whole amount is swept — the
    /// guard is `>`, not `>=`, and it narrows without clipping.
    function test_narrow160_proportionalSweepPull_atMaxPassesNarrowing() public {
        uint256 atMax = uint256(type(uint160).max);
        swept.mint(maker, atMax + 5); // balance ABOVE the cap: the cap is what binds
        _makerApprove(address(sweep), address(swept), type(uint160).max); // infinite

        Order memory o = _sweepOrder(2, atMax);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        settlement.fill(o, sig, IN);

        assertEq(swept.balanceOf(solver), atMax, "filler received exactly type(uint160).max");
        assertEq(swept.balanceOf(maker), 5, "maker keeps the excess above the cap");
        assertEq(tB.balanceOf(maker), OUT, "maker's output leg delivered");
    }
}
