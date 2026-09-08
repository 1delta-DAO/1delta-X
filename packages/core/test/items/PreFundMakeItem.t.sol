// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "../shared/PackedEncode.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IMakerModule} from "@core/interfaces/IMakerModule.sol";
import {Order, Item, ItemOp, LegIn, LegOut, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";

import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";
import {SettlementLens} from "@periphery/SettlementLens.sol";

/// @dev A PRE-FUNDED maker module: it is PRE-FUNDED by the fill's own delivery
///      (`legsOut[j].recipient == this`) and supplies the instructed amount from its
///      own balance. It pulls nothing, so the maker needs no token allowance and no
///      ERC20 approval on the funding asset — and it needs no taker allowance
///      either, because nothing leaves the position.
///
///      The two guards a real one carries, in miniature: the caller pin (here
///      `msg.sender == settlement`, asserted by the EVM rather than compared out of
///      a forwarded word) and the balance floor, whose underflow is what catches a
///      leg delivered in the wrong token — the axis the core still does not bind.
contract MockPreFundMake is IMakerModule {
    address public immutable settlement;

    uint256[] public funded;
    uint256 public totalFunded;
    /// @dev Records `amount` as handed over, so a test can tell "the core sized it"
    ///      apart from "the module chose it".
    uint256 public lastAmount;

    error NotSettlement();
    error PreFundDescriptorRequired();

    constructor(address _settlement) {
        settlement = _settlement;
    }

    function makeOnBehalf(address, uint256 amount, bytes calldata data) external override {
        if (msg.sender != settlement) revert NotSettlement();
        // The module's half of the shape agreement: this entrypoint accepts ONLY the
        // pre-fund leg-reference form, so an ordinary pull-MAKE blob can never reach a
        // body that funds from balance.
        if (uint256(bytes32(data[0:32])) >> 253 != 5) revert PreFundDescriptorRequired();
        (, address fundingToken) = abi.decode(data, (uint256, address));
        // THE FLOOR. Underflows unless this fill's delivery landed HERE, in THIS
        // token. Sound only because `amount` is the core's, not the caller's.
        uint256 floor = IERC20(fundingToken).balanceOf(address(this)) - amount;
        floor; // spent down to, never below — nothing else to spend here
        funded.push(amount);
        totalFunded += amount;
        lastAmount = amount;
    }
}

/// @dev An ORDINARY pull-shaped maker module, to pin that the push branch cannot
///      capture a blob that was never meant for it. Its `data` opens with an address,
///      so `>> 253 == 0` and the descriptor test misses it.
contract MockPullMake is IMakerModule {
    address public immutable settlement;
    uint256 public totalFunded;

    constructor(address _settlement) {
        settlement = _settlement;
    }

    function makeOnBehalf(address, uint256 amount, bytes calldata) external override {
        require(msg.sender == settlement, "only settlement");
        totalFunded += amount;
    }
}

/// @title PreFundMakeItem
/// @notice A PRE-FUNDED `MAKE`: "supply/retire whatever this fill delivered to
///         you", expressed on the seam it belongs to.
///
///  The family this replaces rode the `TAKE_FOR` seam with a take side that moved
///  nothing — a vestigial `amount`, a taker allowance for a book that bounds what
///  LEAVES a position, and a Permit3 hop whose only job was to forward a `spender`
///  word so the module could re-derive a fact `msg.sender` already carries here.
///
///  What is asserted below is that the same core-sized funding — the delivery
///  ledger, the recipient pin, the auction tracking, the partial-fill exactness —
///  survives the move, and that the grants do not.
contract PreFundMakeItemTest is CoreSettlementBase {
    MockPreFundMake preFundMake;
    MockPullMake pullMake;

    uint256 constant USDC_IN = 1_500e6; //  the maker's input leg == the SELL anchor
    uint256 constant WETH_OUT = 1 ether; // delivered to the module, then supplied

    function setUp() public override {
        super.setUp();
        preFundMake = new MockPreFundMake(address(settlement));
        pullMake = new MockPullMake(address(settlement));
        vm.label(address(preFundMake), "mockPreFundMake");

        deal(USDC, maker, USDC_IN * 10);
        _approveMakerToSettlement(USDC, USDC_IN * 10);
    }

    // ──────────────────── helpers ────────────────────

    /// @dev `(5 << 253) | index` — bit 255 (leg reference) + bit 253 (PRE-FUND shape).
    ///      Bits [16:176) carry the funding TOKEN the module spends, which the core
    ///      now binds against `legsOut[index].token`.
    function _preFundLeg(uint256 index) internal view returns (uint256) {
        return (uint256(5) << 253) | (uint256(uint160(WETH)) << 16) | index;
    }

    /// @dev `(1 << 255) | index` — a leg reference WITHOUT the pre-fund bit.
    function _pullLeg(uint256 index) internal pure returns (uint256) {
        return (uint256(1) << 255) | index;
    }

    function _data(uint256 forDesc) internal view returns (bytes memory) {
        return abi.encode(forDesc, WETH);
    }

    function _fundSolver(uint256 amount) internal {
        deal(WETH, solver, amount);
        _approveSolverSide(amount, WETH);
    }

    /// @dev SELL: maker pays USDC from their wallet and receives WETH — delivered to
    ///      the MODULE, which supplies it. `itemAmount` defaults to 0 in the tests
    ///      that care, because a pre-funded MAKE never reads it.
    function _order(uint256 nonce, address module, bytes memory data, address legRecipient, uint256 itemAmount)
        internal
        view
        returns (Order memory o)
    {
        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.MAKE, module: module, amount: itemAmount, recipient: address(0), data: data});
        return _orderWithItems(nonce, items, legRecipient, 0);
    }

    function _orderWithItems(uint256 nonce, Item[] memory items, address legRecipient, uint256 outEnd)
        internal
        view
        returns (Order memory o)
    {
        LegIn[] memory legsIn = new LegIn[](1);
        legsIn[0] = LegIn(USDC, USDC_IN, 0);
        LegOut[] memory legsOut = new LegOut[](1);
        legsOut[0] = LegOut(WETH, WETH_OUT, outEnd, legRecipient);

        o = Order({
            params: 0,
            pricingModule: address(0),
            maker: maker,
            nonce: nonce,
            legsIn: PackedEncode.legsIn(legsIn),
            legsOut: PackedEncode.legsOut(legsOut),
            timing: _expiryBits(block.timestamp + 1 hours),
            exclusiveFiller: address(0),
            minFillAnchor: 0,
            curve: PackedEncode.noCurve(),
            items: PackedEncode.items(items),
            validators: PackedEncode.noValidators(),
            invariants: PackedEncode.noValidators(),
            fillModule: address(0),
            fillTotal: 0
        });
        if (outEnd != 0) o.timing |= _packTiming(uint32(block.timestamp), 1000, 0);
    }

    // ──────────────── the headline: one signature, one approval ────────────────

    /// The whole point, in one fill. The maker signs the order and holds exactly ONE
    /// on-chain approval — the pay asset to Permit3, the floor every Permit2-style
    /// system has. No taker allowance is granted (the assertion below reads the book
    /// and finds it empty), no Permit3 token allowance on the RECEIVED asset exists,
    /// and `item.amount` is zero because the core sizes the funding leg.
    function test_preFundMake_oneApproval_noTakerGrant_fundsTheDeliveredLeg() public {
        _fundSolver(WETH_OUT);
        // Strip the receive side entirely: the maker has never held WETH and never
        // approves it anywhere.
        vm.prank(maker);
        IERC20(WETH).approve(address(permit3), 0);

        bytes memory data = _data(_preFundLeg(0));
        Order memory o = _order(1, address(preFundMake), data, address(preFundMake), 0);

        uint256 makerWeth = IERC20(WETH).balanceOf(maker);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        settlement.fill(o, sig, USDC_IN);

        assertEq(preFundMake.totalFunded(), WETH_OUT, "the delivered leg funded the position in full");
        assertEq(IERC20(WETH).balanceOf(address(preFundMake)), WETH_OUT, "delivery landed at the module directly");
        assertEq(IERC20(WETH).balanceOf(maker), makerWeth, "the maker's wallet never held the received asset");

        (uint160 takerAmt,) = permit3.takerAllowance(maker, address(settlement), address(preFundMake), keccak256(data));
        assertEq(takerAmt, 0, "no taker allowance was granted, and none was needed");
    }

    /// `item.amount` is not merely ignorable — it is UNREAD. A signed amount that
    /// contradicts the leg changes nothing, which is what makes the F27/C-2
    /// two-denominator strand unexpressible on this seam: there is only one number.
    function test_preFundMake_itemAmountIsUnread() public {
        _fundSolver(WETH_OUT);
        bytes memory data = _data(_preFundLeg(0));
        Order memory o = _order(2, address(preFundMake), data, address(preFundMake), 12345);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        settlement.fill(o, sig, USDC_IN);
        assertEq(preFundMake.lastAmount(), WETH_OUT, "the CORE sized the funding, not the signed amount");
    }

    /// Partial fills: each slice funds exactly what that slice delivered, and the
    /// sum over the fills is the whole leg — no drift, no double-count.
    function test_preFundMake_partialFills_fundExactlyTheDelivery() public {
        _fundSolver(WETH_OUT * 2);
        bytes memory data = _data(_preFundLeg(0));
        Order memory o = _order(3, address(preFundMake), data, address(preFundMake), 0);
        bytes memory sig = _sign(o);

        vm.prank(solver);
        settlement.fill(o, sig, USDC_IN / 3);
        uint256 first = preFundMake.totalFunded();
        assertEq(IERC20(WETH).balanceOf(address(preFundMake)), first, "slice 1 funded exactly its delivery");

        vm.prank(solver);
        settlement.fill(o, sig, USDC_IN - USDC_IN / 3);
        // `outputAt` ceils per fill, so two slices sum to the leg total or one unit
        // above it — the ordinary rounding posture of an output leg, always toward
        // the maker. What is EXACT is the property this seam exists for:
        assertEq(
            preFundMake.totalFunded(),
            IERC20(WETH).balanceOf(address(preFundMake)),
            "funded exactly what was delivered, over both slices"
        );
        assertGe(preFundMake.totalFunded(), WETH_OUT, "never under the signed leg");
        assertLe(preFundMake.totalFunded(), WETH_OUT + 1, "and at most one unit of ceil drift above it");
    }

    /// A decaying leg carries its auction price straight into the funding side — the
    /// property a static signed amount cannot have.
    function test_preFundMake_decayedLeg_tracksTheAuction() public {
        _fundSolver(WETH_OUT);
        Item[] memory items = new Item[](1);
        items[0] =
            Item({op: ItemOp.MAKE, module: address(preFundMake), amount: 0, recipient: address(0), data: _data(_preFundLeg(0))});
        Order memory o = _orderWithItems(4, items, address(preFundMake), WETH_OUT / 2);
        vm.warp(block.timestamp + 500); // half way down the decay

        bytes memory sig = _sign(o);
        vm.prank(solver);
        settlement.fill(o, sig, USDC_IN);

        uint256 delivered = IERC20(WETH).balanceOf(address(preFundMake));
        assertLt(delivered, WETH_OUT, "the auction moved the leg");
        assertGt(delivered, WETH_OUT / 2, "but not past its end");
        assertEq(preFundMake.totalFunded(), delivered, "funded EXACTLY the decayed delivery");
    }

    // ──────────────── the bindings ────────────────

    /// The pre-fund bit is what makes the core demand `legsOut[j].recipient == module`.
    /// Point it at a maker-addressed leg and the fill unwinds: the delivery would
    /// land in the wallet while the module was told to spend from its own balance.
    function test_preFundMake_requiresModuleAddressedLeg() public {
        _fundSolver(WETH_OUT);
        Order memory o = _order(5, address(preFundMake), _data(_preFundLeg(0)), address(0), 0);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert(Base.ForLegNotMakers.selector);
        settlement.fill(o, sig, USDC_IN);
    }

    /// Out-of-range index: `outs.length` IS the validated `legsOut` count, so the
    /// bound is the delivery ledger's own length.
    function test_preFundMake_legIndexOutOfRange_reverts() public {
        _fundSolver(WETH_OUT);
        Order memory o = _order(6, address(preFundMake), _data(_preFundLeg(7)), address(preFundMake), 0);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert(Base.ForLegMissing.selector);
        settlement.fill(o, sig, USDC_IN);
    }

    /// ONE DELIVERY FUNDS ONE ITEM. Two items naming the same leg used to each be
    /// handed the full delivery, because the funding amount was a re-pricing with no
    /// bookkeeping (F27/H-1 mechanism 3). The ledger is spent, so the second claim
    /// has nothing to take.
    function test_legReuse_twoItemsOneLeg_reverts() public {
        _fundSolver(WETH_OUT);
        bytes memory data = _data(_preFundLeg(0));
        Item[] memory items = new Item[](2);
        items[0] = Item({op: ItemOp.MAKE, module: address(preFundMake), amount: 0, recipient: address(0), data: data});
        items[1] = items[0];
        Order memory o = _orderWithItems(7, items, address(preFundMake), 0);

        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert(Base.ForLegReused.selector);
        settlement.fill(o, sig, USDC_IN);
    }

    // ──────────────── the seam stays disjoint ────────────────

    /// An ordinary pull-MAKE blob opens with an address, so `>> 253 == 0` and the
    /// push branch cannot capture it: `item.amount` still governs, exactly as before.
    function test_pullMake_ordinaryBlobStillUsesItemAmount() public {
        _fundSolver(WETH_OUT);
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(pullMake),
            amount: 777,
            recipient: address(0),
            data: abi.encode(WETH) // an address in word 0 — the classic layout
        });
        Order memory o = _orderWithItems(8, items, address(0), 0);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        settlement.fill(o, sig, USDC_IN);
        assertEq(pullMake.totalFunded(), 777, "the signed amount still governs the pull shape");
    }

    /// A leg reference WITHOUT the pre-fund bit is NOT a pre-fund item: `>> 253 == 4`, so the
    /// core leaves `item.amount` governing and the blob is an ordinary pull-MAKE one.
    /// The module's own guard is the second half of the same agreement and refuses to
    /// fund from balance against an amount the core did not size. The two halves —
    /// core recipient rule and module funding shape — ride one signed bit, so they
    /// cannot disagree.
    ///
    /// `itemAmount` is non-zero here deliberately: at zero the core's dust-slice skip
    /// would retire the item before the module ever saw it, and the property under
    /// test is what the MODULE does with the blob.
    function test_pullDescriptor_doesNotReachThePreFundBody() public {
        _fundSolver(WETH_OUT);
        Order memory o = _order(9, address(preFundMake), _data(_pullLeg(0)), address(0), WETH_OUT);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert(MockPreFundMake.PreFundDescriptorRequired.selector);
        settlement.fill(o, sig, USDC_IN);
    }

    // ──────────────── the scheduled path refuses it ────────────────

    /// `matchSettle` schedules deliveries and items INDEPENDENTLY, so "the delivery
    /// landed before the item ran" would become a solver obligation — and it does not
    /// fail closed, because a module holding residue would silently fund from it.
    /// A pre-funded MAKE is op 0, so the `op >= SETTLE` range test sails past it; the
    /// descriptor is what refuses it.
    function test_matchSettle_refusesPreFundMake() public {
        _fundSolver(WETH_OUT);
        Order memory o = _order(10, address(preFundMake), _data(_preFundLeg(0)), address(preFundMake), 0);

        Order[] memory orders = new Order[](1);
        orders[0] = o;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(o);
        uint256[] memory fills = new uint256[](1);
        fills[0] = USDC_IN;
        uint256[] memory schedule = new uint256[](2);
        schedule[0] = MatchStep.PULL;
        schedule[1] = MatchStep.DELIVER | (uint256(0) << 8);

        vm.prank(solver);
        vm.expectRevert(Base.MatchSettleItemUnsupported.selector);
        settlement.matchSettle(
            MatchPlan({
                orders: orders,
                sigs: sigs,
                fillAmounts: fills,
                takerDatas: new bytes[](0),
                schedule: schedule,
                callTargets: new address[](0),
                callDatas: new bytes[](0),
                profitRecipient: address(0)
            })
        );
    }

    // ──────────────── lens preflight ────────────────
    //
    // Every defect above is a revert at FILL time. `validateOrder` is where a maker
    // should meet them instead — before a signature exists. A pre-funded MAKE
    // carries the same funding descriptor as a composite's value-IN side, so it gets
    // the same preflight; a plain pull MAKE carries none and must pass untouched.

    function _lensReason(Order memory o) internal returns (bool ok, string memory why) {
        return new SettlementLens(address(settlement)).validateOrder(o);
    }

    /// The well-formed shape the settler accepts, accepted here too.
    function test_lens_acceptsAWellFormedPreFundMake() public {
        Order memory o = _order(20, address(preFundMake), _data(_preFundLeg(0)), address(preFundMake), 0);
        (bool ok, string memory why) = _lensReason(o);
        assertTrue(ok, why);
    }

    /// THE DRIFT THIS CLOSED. The settler accepts a maker-addressed leg only while
    /// the pre-fund bit is CLEAR; with it set the leg must be addressed to the
    /// module. The lens used to apply the loose rule to both, so this order preflighted
    /// clean and then reverted `ForLegNotMakers` at fill time.
    function test_lens_flagsPreFundDescriptorOverAMakerAddressedLeg() public {
        Order memory o = _order(21, address(preFundMake), _data(_preFundLeg(0)), address(0), 0);
        (bool ok, string memory why) = _lensReason(o);
        assertFalse(ok, "a pre-fund descriptor over a maker-addressed leg must be flagged");
        assertEq(why, "pre-funded leg must be addressed to the item's module");
    }

    /// An out-of-range index is caught on this seam too.
    function test_lens_flagsOutOfRangeLegOnAPreFundMake() public {
        Order memory o = _order(22, address(preFundMake), _data(_preFundLeg(7)), address(preFundMake), 0);
        (bool ok, string memory why) = _lensReason(o);
        assertFalse(ok, "out-of-range funding leg must be flagged");
        assertEq(why, "take_for leg index out of range");
    }

    /// …and a plain PULL make is none of the preflight's business: it opens with an
    /// address, so the descriptor test misses it and the order passes untouched.
    function test_lens_ignoresAPlainPullMake() public {
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(pullMake),
            amount: 777,
            recipient: address(0),
            data: abi.encode(WETH)
        });
        Order memory o = _orderWithItems(23, items, address(0), 0);
        (bool ok, string memory why) = _lensReason(o);
        assertTrue(ok, why);
    }
}
