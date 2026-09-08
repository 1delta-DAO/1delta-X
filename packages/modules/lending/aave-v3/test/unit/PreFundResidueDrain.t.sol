// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MockSettlementBase, MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {Order, Item, ItemOp, LegIn, LegOut} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";

import {AaveV3PreFundModule} from "../../src/AaveV3PreFundModules.sol";

/// @dev A "venue" decoded from maker-authored order `data`. It does what any
///      attacker-chosen venue can do with a scoped approval: pull it.
contract EvilPool {
    address immutable tok;
    address immutable thief;

    constructor(address _tok, address _thief) {
        tok = _tok;
        thief = _thief;
    }

    function supply(address, uint256 amount, address, uint16) external {
        MockERC20(tok).transferFrom(msg.sender, thief, amount);
    }
}

/// @dev An honest venue: pulls exactly the amount it was instructed to supply.
contract GoodPool {
    function supply(address tok, uint256 amount, address, uint16) external {
        MockERC20(tok).transferFrom(msg.sender, address(this), amount);
    }
}

/// @dev A debt token reporting zero debt — what any real debt token returns for an
///      address with no position on that market.
contract NoDebt {
    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
}

/// @notice PoC — a PRE-FUND module's `requireDelivered` floor accepts the module's
///         OWN pre-existing balance as proof that this fill's leg was delivered, so
///         any residue on a shared pre-fund singleton is drainable by anyone at zero
///         cost, THROUGH the pinned Settlement.
///
///         `PreFundSpenderAuth.t.sol` proves the drain is refused on the DIRECT
///         entrypoint (`OnlySettlement`). It is not refused when routed through a
///         Settlement fill, because anyone may author an order naming themselves as
///         maker, and `msg.sender == settlement` then holds by construction.
///
///         The delivered leg's TOKEN is never bound to the asset the module spends:
///         the attacker delivers a worthless token they mint themselves and the
///         module spends the residue token named in `data`.
contract PreFundResidueDrainTest is MockSettlementBase {
    AaveV3PreFundModule mod;
    MockERC20 junk; // the attacker's own token — delivered as the funding leg
    MockERC20 usdc; // the residue sitting on the shared singleton

    address thief = address(0xBADBAD);

    function setUp() public override {
        super.setUp();
        mod = new AaveV3PreFundModule(address(permit3), address(settlement));
        junk = new MockERC20("junk");
        usdc = new MockERC20("usdc");
    }

    /// @dev `(5 << 253)` = leg reference + PRE-FUND shape, leg index 0, op Supply (0).
    ///      With the fix, bits [16:176) carry the funding TOKEN the module will spend.
    function _desc() internal pure returns (uint256) {
        return (uint256(5) << 253);
    }

    function _descFor(address token) internal pure returns (uint256) {
        return (uint256(5) << 253) | (uint256(uint160(token)) << 16);
    }

    /// @dev Variant (b): NO attacker-chosen venue at all. `Op.Repay` names a debt
    ///      token reporting zero debt, so `toRepay == 0`, the pool is never touched,
    ///      and `sweepSurplus(asset, onBehalfOf, floor)` ships the residue straight to
    ///      the attacker — `floor` being `bal - forAmount`, i.e. 0 when `forAmount` is
    ///      sized at the whole residue.
    function test_preFundResidue_drainedWithNoAttackerVenue() public {
        uint256 residue = 100_000e6;
        usdc.mint(address(mod), residue);

        address noDebt = address(new NoDebt());

        Order memory o = _blank(2);
        o.legsIn = PackedEncode.oneLegIn(address(junk), 1, 0);
        o.legsOut = PackedEncode.oneLegOut(address(junk), residue, 0, address(mod));

        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(mod),
            amount: 0,
            recipient: address(0),
            // Op.Repay rides in descriptor bits [244,252). Pool is never reached.
            data: abi.encode((uint256(5) << 253) | (uint256(1) << 244), address(0xDEAD), address(usdc), uint256(2), noDebt)
        });
        o.items = PackedEncode.items(items);

        bytes memory sig = _sign(o);

        junk.mint(solver, residue);
        junk.mint(maker, 1);
        _solverApprove(address(settlement), address(junk), type(uint160).max);
        _makerApprove(address(settlement), address(junk), type(uint160).max);

        vm.prank(solver);
        vm.expectRevert(Base.ForLegNotMakers.selector);
        settlement.fill(o, sig, 1);

        assertEq(usdc.balanceOf(maker), 0, "attacker received the residue");
        assertEq(usdc.balanceOf(address(mod)), residue, "singleton was drained");
    }

    function test_preFundResidue_isDrainableThroughSettlement() public {
        uint256 residue = 100_000e6;
        usdc.mint(address(mod), residue); // any residue: dust, a donation, a rebase

        address evil = address(new EvilPool(address(usdc), thief));

        // The attacker authors an order naming THEMSELVES as maker. The funding
        // leg is denominated in a token they mint for free and is addressed at the
        // module, exactly as the pre-fund shape requires.
        Order memory o = _blank(1);
        o.legsIn = PackedEncode.oneLegIn(address(junk), 1, 0);
        o.legsOut = PackedEncode.oneLegOut(address(junk), residue, 0, address(mod));

        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(mod),
            amount: 0, // unread on the pre-fund seam — the descriptor is the amount
            recipient: address(0),
            data: abi.encode(_desc(), evil, address(usdc))
        });
        o.items = PackedEncode.items(items);

        bytes memory sig = _sign(o);

        // Zero capital: the attacker mints the funding token themselves.
        junk.mint(solver, residue);
        junk.mint(maker, 1);
        _solverApprove(address(settlement), address(junk), type(uint160).max);
        _makerApprove(address(settlement), address(junk), type(uint160).max);

        assertEq(usdc.balanceOf(address(mod)), residue, "precondition: module holds residue");

        vm.prank(solver);
        vm.expectRevert(Base.ForLegNotMakers.selector);
        settlement.fill(o, sig, 1);

        assertEq(usdc.balanceOf(thief), 0, "attacker drained the singleton");
        assertEq(usdc.balanceOf(address(mod)), residue, "singleton was drained");
    }

    /// NOT A BLANKET FREEZE. An honest pre-fund order — funding leg denominated in
    /// the very asset the module spends, and the descriptor naming it — still fills,
    /// and leaves the pre-existing residue untouched.
    function test_honestPreFundOrder_stillFills_andLeavesResidueAlone() public {
        uint256 residue = 100_000e6;
        uint256 fund = 7_000e6;
        usdc.mint(address(mod), residue);
        address pool = address(new GoodPool());

        Order memory o = _blank(3);
        o.legsIn = PackedEncode.oneLegIn(address(junk), 1, 0);
        o.legsOut = PackedEncode.oneLegOut(address(usdc), fund, 0, address(mod));

        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(mod),
            amount: 0,
            recipient: address(0),
            data: abi.encode(_descFor(address(usdc)), pool, address(usdc))
        });
        o.items = PackedEncode.items(items);

        bytes memory sig = _sign(o);

        usdc.mint(solver, fund);
        junk.mint(maker, 1);
        _solverApprove(address(settlement), address(usdc), type(uint160).max);
        _makerApprove(address(settlement), address(junk), type(uint160).max);

        vm.prank(solver);
        settlement.fill(o, sig, 1);

        assertEq(usdc.balanceOf(pool), fund, "the funded amount reached the venue");
        assertEq(usdc.balanceOf(address(mod)), residue, "residue untouched, module ends where it started");
    }
}
