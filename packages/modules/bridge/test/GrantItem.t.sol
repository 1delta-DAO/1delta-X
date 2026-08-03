// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order, Item, ItemOp, LegOut} from "@core/settlement/Settlement.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";

import {PositionFunnel} from "../src/funnel/PositionFunnel.sol";
import {PositionFunnelFactory} from "../src/funnel/PositionFunnelFactory.sol";
import {FunnelGrantModule} from "../src/funnel/FunnelGrantModule.sol";
import {MockLendingPool, MockSupplyModule, MockBorrowModule} from "./shared/LendingMocks.t.sol";
import {BridgeTestBase} from "./shared/BridgeTestBase.t.sol";

/// @title GrantItemTest
/// @notice Just-in-time allowances: a leverage order that runs against a funnel
///         with NO standing approvals, authorised entirely by the order itself.
///
///         The security claim under test is that {PositionFunnel.grant} cannot be
///         reached except through Settlement executing an order the funnel's owner
///         signed, and that even then it only ever touches the funnel that signed
///         it. The attack section below is the point of this file.
contract GrantItemTest is BridgeTestBase {
    PositionFunnelFactory factory;
    FunnelGrantModule grantModule;
    PositionFunnel funnel;
    PositionFunnel attackerFunnel;

    MockLendingPool pool;
    MockSupplyModule supplyModule;
    MockBorrowModule borrowModule;

    bytes32 constant USER_SALT = bytes32(uint256(1));

    /// @dev A real leverage trade, so the solver's payoff is coherent: the funnel
    ///      brings its own bridged collateral, the solver adds the rest and is
    ///      repaid out of the borrow.
    uint256 constant FUNNEL_COLL = 100e18; // already at the funnel
    uint256 constant SOLVER_COLL = 200e18; // delivered by the solver via legsOut
    uint256 constant COLL = FUNNEL_COLL + SOLVER_COLL; // supplied as collateral
    uint256 constant BORROW = 600e18; // borrowed, and paid to the solver

    function setUp() public virtual override {
        super.setUp();
        grantModule = new FunnelGrantModule(address(settlement));
        factory =
            new PositionFunnelFactory(address(permit3), address(settlement), address(lens), address(grantModule));

        funnel = PositionFunnel(payable(factory.deploy(maker, USER_SALT)));
        attackerFunnel = PositionFunnel(payable(factory.deploy(solver, USER_SALT)));
        vm.label(address(funnel), "funnel");
        vm.label(address(attackerFunnel), "attackerFunnel");

        pool = new MockLendingPool(address(tA), address(tB));
        supplyModule = new MockSupplyModule(address(permit3), address(settlement), pool);
        borrowModule = new MockBorrowModule(address(permit3), pool);

        // The lender's own borrow delegation stays a one-time position-level grant;
        // only the Permit3 allowances move into the order.
        PositionFunnel.Call[] memory calls = new PositionFunnel.Call[](1);
        calls[0] = PositionFunnel.Call({
            target: address(pool),
            value: 0,
            data: abi.encodeCall(MockLendingPool.approveDelegate, (address(borrowModule)))
        });
        vm.prank(maker);
        funnel.execute(calls);

        // The funnel's own collateral, as if bridged in.
        tA.mint(address(funnel), FUNNEL_COLL);

        // The solver funds its side of the trade.
        tA.mint(solver, SOLVER_COLL);
        _solverApprove(address(settlement), address(tA), type(uint160).max);
    }

    // ──────────────────── Builders ────────────────────

    function _grantSpec(address spender, address token, bool taker, bytes32 ref)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(FunnelGrantModule.GrantSpec({spender: spender, token: token, taker: taker, ref: ref}));
    }

    /// @dev Leverage with the allowances carried by the order. The grant items are
    ///      given the SAME `amount` as the items that consume them, so under a
    ///      partial fill both slices scale identically and the allowance is spent
    ///      exactly.
    function _leverageOrder(uint256 nonce, address funnelAddr) internal view returns (Order memory o) {
        o = _blank(nonce);
        o.maker = funnelAddr;
        o.legsIn = _legsIn1(address(tB), BORROW);
        o.legsOut = new LegOut[](1);
        // recipient 0 == the maker: the solver's collateral lands at the funnel,
        // where item[2] picks it up together with the bridged share.
        o.legsOut[0] = LegOut(address(tA), SOLVER_COLL, 0, address(0));

        bytes memory takeData = "";
        o.items = new Item[](4);
        // [0] let the supply module pull the collateral
        o.items[0] = Item({
            op: ItemOp.MAKE,
            module: address(grantModule),
            amount: COLL,
            recipient: address(0),
            data: _grantSpec(address(supplyModule), address(tA), false, bytes32(0))
        });
        // [1] let Settlement spend the taker allowance the borrow needs
        o.items[1] = Item({
            op: ItemOp.MAKE,
            module: address(grantModule),
            amount: BORROW,
            recipient: address(0),
            data: _grantSpec(address(settlement), address(0), true, keccak256(takeData))
        });
        o.items[2] =
            Item({op: ItemOp.MAKE, module: address(supplyModule), amount: COLL, recipient: address(0), data: ""});
        o.items[3] =
            Item({op: ItemOp.TAKE, module: address(borrowModule), amount: BORROW, recipient: address(0), data: takeData});
    }

    function _fill(Order memory o, uint256 amount) internal {
        bytes memory sig = _signWith(o, makerPk);
        vm.prank(solver);
        settlement.fill(o, sig, amount);
    }

    // ──────────────────── Happy path ────────────────────

    /// @dev No `enableToken`, no `executeSigned` for allowances, no standing
    ///      approvals of any kind — the order is the whole authorisation.
    function test_leverage_withNoStandingApprovals() public {
        (uint160 before1,,) = permit3.tokenAllowance(address(funnel), address(supplyModule), address(tA));
        assertEq(before1, 0, "no allowance before the fill");

        Order memory o = _leverageOrder(1, address(funnel));
        _fill(o, BORROW);

        assertEq(pool.collateralOf(address(funnel)), COLL, "collateral supplied");
        assertEq(pool.debtOf(address(funnel)), BORROW, "debt opened");
        // The solver's side of the trade: it gave SOLVER_COLL and was repaid out
        // of the borrow proceeds, never out of the funnel's balance.
        assertEq(tA.balanceOf(solver), 0, "solver's collateral went in");
        assertEq(tB.balanceOf(solver), BORROW, "solver paid from the borrow");
    }

    /// @dev The grant is sized to the item, so it lands at exactly zero.
    function test_allowanceIsExactlyConsumed_nothingDangles() public {
        Order memory o = _leverageOrder(1, address(funnel));
        _fill(o, BORROW);

        (uint160 tokenLeft,,) = permit3.tokenAllowance(address(funnel), address(supplyModule), address(tA));
        assertEq(tokenLeft, 0, "token allowance fully spent");
        (uint160 takerLeft,,) = permit3.takerAllowance(address(funnel), address(settlement), keccak256(""));
        assertEq(takerLeft, 0, "taker allowance fully spent");
    }

    /// @dev Even a leftover cannot outlive the block it was created in.
    function test_grantExpiresWithTheBlock() public {
        Order memory o = _leverageOrder(1, address(funnel));
        _fill(o, BORROW);

        (, uint48 exp,) = permit3.tokenAllowance(address(funnel), address(supplyModule), address(tA));
        assertEq(exp, uint48(block.timestamp), "same-block expiry");
        assertTrue(exp < uint48(block.timestamp + 1), "dead next block");
    }

    /// @dev Partial fills scale the grant and the pull together.
    function test_partialFill_grantScalesWithTheItem() public {
        Order memory o = _leverageOrder(1, address(funnel));
        _fill(o, BORROW / 2);

        assertEq(pool.collateralOf(address(funnel)), COLL / 2, "half supplied");
        assertEq(tB.balanceOf(solver), BORROW / 2, "solver paid pro-rata");
        (uint160 left,,) = permit3.tokenAllowance(address(funnel), address(supplyModule), address(tA));
        assertEq(left, 0, "half granted, half spent, nothing left");
    }

    // ──────────────────── What the solver relies on ────────────────────

    /// @dev The solver's guarantee is ATOMICITY, not prediction. Its collateral is
    ///      delivered before the items run, so if anything downstream fails — here
    ///      the lender refusing the borrow — the whole fill unwinds and the solver
    ///      keeps everything. It can never end up having paid `legsOut` without
    ///      receiving `legsIn`.
    function test_solverIsMadeWholeWhenTheFillFails() public {
        // Revoke the borrow delegation the position depends on.
        PositionFunnel.Call[] memory calls = new PositionFunnel.Call[](1);
        calls[0] = PositionFunnel.Call({
            target: address(pool),
            value: 0,
            data: abi.encodeWithSignature("revokeDelegate(address)", address(borrowModule))
        });
        vm.prank(maker);
        funnel.execute(calls);

        Order memory o = _leverageOrder(1, address(funnel));
        bytes memory sig = _signWith(o, makerPk);

        vm.prank(solver);
        vm.expectRevert(MockLendingPool.NotDelegated.selector);
        settlement.fill(o, sig, BORROW);

        assertEq(tA.balanceOf(solver), SOLVER_COLL, "solver still holds its collateral");
        assertEq(tB.balanceOf(solver), 0, "and was never paid");
        assertEq(pool.collateralOf(address(funnel)), 0, "no position opened");
        assertEq(tA.balanceOf(address(funnel)), FUNNEL_COLL, "funnel untouched");
    }

    /// @dev And the grants unwind with it — a failed fill leaves no allowance
    ///      behind for anyone to pick up afterwards.
    function test_failedFillLeavesNoAllowance() public {
        PositionFunnel.Call[] memory calls = new PositionFunnel.Call[](1);
        calls[0] = PositionFunnel.Call({
            target: address(pool),
            value: 0,
            data: abi.encodeWithSignature("revokeDelegate(address)", address(borrowModule))
        });
        vm.prank(maker);
        funnel.execute(calls);

        Order memory o = _leverageOrder(1, address(funnel));
        bytes memory sig = _signWith(o, makerPk);
        vm.prank(solver);
        vm.expectRevert(MockLendingPool.NotDelegated.selector);
        settlement.fill(o, sig, BORROW);

        (uint160 left,,) = permit3.tokenAllowance(address(funnel), address(supplyModule), address(tA));
        assertEq(left, 0, "grant reverted with the fill");
    }

    // ──────────────────── Attacks ────────────────────

    /// @dev Direct call. The gate is an immutable address, not a role.
    function test_attack_grantCannotBeCalledDirectly() public {
        vm.prank(solver);
        vm.expectRevert(PositionFunnel.NotGrantModule.selector);
        funnel.grant(solver, address(tA), type(uint160).max, false, bytes32(0));
    }

    /// @dev Not even by the owner — the only caller is the module.
    function test_attack_ownerCannotCallGrantDirectly() public {
        vm.prank(maker);
        vm.expectRevert(PositionFunnel.NotGrantModule.selector);
        funnel.grant(maker, address(tA), type(uint160).max, false, bytes32(0));
    }

    /// @dev Going through the module directly skips Settlement, and therefore skips
    ///      the maker-signature check that makes the whole thing safe.
    function test_attack_moduleCannotBeCalledDirectly() public {
        vm.prank(solver);
        vm.expectRevert(FunnelGrantModule.OnlySettlement.selector);
        grantModule.makeOnBehalf(
            address(funnel), type(uint160).max, _grantSpec(solver, address(tA), false, bytes32(0))
        );
    }

    /// @dev THE attack this design has to survive. The attacker signs their OWN
    ///      order — perfectly valid, their own funnel is the maker — and puts a
    ///      grant item in it naming themselves as spender and the victim's token.
    ///      The module targets `onBehalfOf`, which Settlement sets from the
    ///      verified `order.maker`, so the grant lands on the ATTACKER's funnel.
    ///      The victim's is untouched and no allowance over their funds exists.
    function test_attack_ownOrderCannotGrantOnAnotherFunnel() public {
        Order memory evil = _blank(99);
        evil.maker = address(attackerFunnel); // the attacker's own funnel
        evil.legsIn = _legsIn1(address(tA), 1);
        evil.legsOut = new LegOut[](0);
        evil.items = new Item[](1);
        evil.items[0] = Item({
            op: ItemOp.MAKE,
            module: address(grantModule),
            amount: COLL,
            recipient: address(0),
            data: _grantSpec(solver, address(tA), false, bytes32(0)) // spender = attacker
        });

        // Fund and wire the attacker's own funnel so the fill can complete.
        tA.mint(address(attackerFunnel), 1);
        address[] memory toks = new address[](1);
        toks[0] = address(tA);
        attackerFunnel.enableTokens(toks);

        bytes memory sig = _signWith(evil, solverPk); // attacker signs their own order
        vm.prank(solver);
        settlement.fill(evil, sig, 1);

        // The grant landed on the attacker's funnel, over the attacker's own funds.
        (uint160 onAttacker,,) = permit3.tokenAllowance(address(attackerFunnel), solver, address(tA));
        assertEq(onAttacker, COLL, "attacker granted over their own funnel");

        // The victim's funnel has no allowance to anyone, and still holds everything.
        (uint160 onVictim,,) = permit3.tokenAllowance(address(funnel), solver, address(tA));
        assertEq(onVictim, 0, "victim funnel untouched");
        assertEq(tA.balanceOf(address(funnel)), FUNNEL_COLL, "victim funds intact");
    }

    /// @dev A forged order naming the victim as maker cannot be signed, so it never
    ///      reaches items at all.
    function test_attack_forgedOrderOnVictimFunnelDoesNotVerify() public {
        Order memory evil = _leverageOrder(2, address(funnel));
        bytes memory sig = _signWith(evil, solverPk); // NOT the funnel's owner

        vm.prank(solver);
        vm.expectRevert();
        settlement.fill(evil, sig, BORROW);

        (uint160 left,,) = permit3.tokenAllowance(address(funnel), address(supplyModule), address(tA));
        assertEq(left, 0, "no allowance was created");
    }

    /// @dev The circuit breaker, in case the module ever needs to be abandoned.
    function test_ownerCanDisableGrants() public {
        vm.prank(maker);
        funnel.setGrantsDisabled(true);

        Order memory o = _leverageOrder(1, address(funnel));
        bytes memory sig = _signWith(o, makerPk);
        vm.prank(solver);
        vm.expectRevert();
        settlement.fill(o, sig, BORROW);
    }

    function test_onlyOwnerCanDisableGrants() public {
        vm.prank(solver);
        vm.expectRevert(PositionFunnel.NotOwner.selector);
        funnel.setGrantsDisabled(true);
    }

    /// @dev The implementation holds nothing, but `owner()` is forgeable when it is
    ///      called directly, so `grant` refuses to run outside a clone regardless.
    function test_attack_implementationCannotGrant() public {
        PositionFunnel impl = PositionFunnel(payable(factory.IMPLEMENTATION()));
        vm.prank(address(grantModule));
        vm.expectRevert(PositionFunnel.NotProxy.selector);
        impl.grant(solver, address(tA), 1, false, bytes32(0));
    }
}
