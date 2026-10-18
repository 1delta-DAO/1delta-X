// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Order, Item, ItemOp, LegIn, LegOut} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";
import {OrderState} from "@core/settlement/OrderState.sol";
import {MatchRaceGuard} from "@solvers/base/MatchRaceGuard.sol";
import {
    AggregatorFillSolver,
    RoutePlan,
    NO_PATCH,
    POOL_ROUTE,
    Permit2612,
    PoolVenue,
    ItemFillGuard
} from "@solvers/aggregator/AggregatorFillSolver.sol";
import {RouteSandbox, MULTI_ROUTE} from "@solvers/aggregator/RouteSandbox.sol";
import {NativeBalance} from "@periphery/NativeBalance.sol";
import {NftSettlementModule} from "@modules/nft/src/NftSettlementModule.sol";
import {Erc1155SettlementModule} from "@modules/nft/src/Erc1155SettlementModule.sol";
import {ISettlementModule} from "@core/interfaces/ISettlementModule.sol";

import {MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";
import {AggregatorFillSolverTest, MockRouter} from "./AggregatorFillSolver.t.sol";
import {MockWNative} from "./AggregatorNative.t.sol";
import {newAggNative, noGuard} from "./shared/AggDeploy.sol";

interface IZcfErc721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

interface IZcfErc1155Receiver {
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external returns (bytes4);
}

/// @dev Minimal ERC-721 WITH the receiver check (owner written before the hook, as OZ).
contract ZcfMock721 {
    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function setApprovalForAll(address op, bool ok) external {
        isApprovedForAll[msg.sender][op] = ok;
    }

    function safeTransferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from, "not owner");
        require(msg.sender == from || isApprovedForAll[from][msg.sender], "not approved");
        ownerOf[id] = to;
        if (to.code.length != 0) {
            require(
                IZcfErc721Receiver(to).onERC721Received(msg.sender, from, id, "")
                    == IZcfErc721Receiver.onERC721Received.selector,
                "bad receiver"
            );
        }
    }
}

/// @dev Minimal ERC-1155 WITH the receiver check (balances written before the hook).
contract ZcfMock1155 {
    mapping(uint256 => mapping(address => uint256)) internal _bal;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function balanceOf(address a, uint256 id) external view returns (uint256) {
        return _bal[id][a];
    }

    function mint(address to, uint256 id, uint256 n) external {
        _bal[id][to] += n;
    }

    function setApprovalForAll(address op, bool ok) external {
        isApprovedForAll[msg.sender][op] = ok;
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 n, bytes calldata data) external {
        require(msg.sender == from || isApprovedForAll[from][msg.sender], "not approved");
        _bal[id][from] -= n;
        _bal[id][to] += n;
        if (to.code.length != 0) {
            require(
                IZcfErc1155Receiver(to).onERC1155Received(msg.sender, from, id, n, data)
                    == IZcfErc1155Receiver.onERC1155Received.selector,
                "bad receiver"
            );
        }
    }
}

/// @dev The market a sale route sells into: pulls the asset from its caller (the
///      sandbox) and pays `price` of `payToken` to `payTo`.
contract ZcfNftMarket {
    MockERC20 immutable payToken;

    constructor(MockERC20 t) {
        payToken = t;
    }

    function buy721(ZcfMock721 c, uint256 id, uint256 price, address payTo) external {
        c.safeTransferFrom(msg.sender, address(this), id);
        payToken.transfer(payTo, price);
    }

    function buy1155(ZcfMock1155 c, uint256 id, uint256 n, uint256 price, address payTo) external {
        c.safeTransferFrom(msg.sender, address(this), id, n, "");
        payToken.transfer(payTo, price);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IZcfErc721Receiver.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return IZcfErc1155Receiver.onERC1155Received.selector;
    }
}

/// @dev A SETTLE module paying a FOREIGN ERC-20 (one no leg names) from its own stash to
///      the filler — the shape of a second-token sweep.
contract ZcfForeignReceiptModule is ISettlementModule {
    function settle(address, address filler, uint256 slice, bytes calldata data) external {
        MockERC20(abi.decode(data, (address))).transfer(filler, slice);
    }
}

/// @title AggregatorZeroCapitalFillsTest
/// @notice Review 2026-10-18 (REVIEW-2026-10-18-zero-capital-fills.md §2) — the solver
///         findings closed in {AggregatorFillSolver}:
///           S-1 inventory as a capped, operator-only top-up (pull / netted / direct /
///               empty route);
///           S-2 NFT receipts (hooks + forward to the sandbox) and listed foreign ERC-20
///               receipts, sold by a MULTICALL route — a zero-capital NFT sale through
///               the REAL solver;
///           S-3 multi-input orders routed (netted MULTICALL) or refused;
///           S-5 the remainder sentinel on executeFill (pro-rata `minOut`) and the
///               {MatchRaceGuard} checks on executeItemFill;
///           S-6 the item path's absolute `minOut` floor;
///           S-7 (native shapes) in {AggregatorZeroCapitalNativeTest} below.
contract AggregatorZeroCapitalFillsTest is AggregatorFillSolverTest {
    uint256 constant AMOUNT_WORD = 4; // `swap(amountIn, …)`'s amount word

    function _np() internal pure returns (Permit2612[] memory) {
        return new Permit2612[](0);
    }

    function _empty() internal view returns (RoutePlan memory p) {
        p = _plan(address(aggSolver), 0);
        p.router = POOL_ROUTE;
        p.data = "";
    }

    function _digest(Order memory o) internal view returns (bytes32) {
        return _hashOrder(o); // `filled` is keyed by the struct hash (`order.hash()`)
    }

    // ═══════════════════════════ S-1: inventory ═══════════════════════════

    /// PULL: the route comes up 5 short of the maker's price; 5 of held inventory covers
    /// it, exactly — and nothing more is drawn or left approved.
    function test_S1_pull_inventoryCoversRouteShortfall() public {
        router.setRate(8_500); // 100 tA -> 85 tB, maker wants 90
        tB.mint(address(aggSolver), 10e18); // inventory
        Order memory o = _order(1);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _plan(address(aggSolver), 85e18);
        p.inventory = 50e18; // generous cap: the core pulls only the priced legs
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());

        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "maker paid in full");
        assertEq(tB.balanceOf(address(aggSolver)), 5e18, "exactly the 5 shortfall drawn");
        assertEq(tB.allowance(address(aggSolver), address(settlement)), 0, "no allowance survives");
    }

    /// The cap binds: a draw beyond it is refused (the core's pull fails, atomically).
    function test_S1_pull_inventoryCapBinds() public {
        router.setRate(8_500);
        tB.mint(address(aggSolver), 10e18);
        Order memory o = _order(2);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _plan(address(aggSolver), 0);
        p.inventory = 4e18;
        vm.expectRevert();
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
        assertEq(tB.balanceOf(address(aggSolver)), 10e18, "inventory untouched");
    }

    /// `inventory == 0` keeps the delta-only rule: held value is unreachable.
    function test_S1_zeroCapIsDeltaOnly() public {
        router.setRate(8_500);
        tB.mint(address(aggSolver), 10e18);
        Order memory o = _order(3);
        bytes memory sig = _sign(o);
        vm.expectRevert();
        aggSolver.executeFill(o, sig, AMOUNT_IN, _plan(address(aggSolver), 0), "", _np());
    }

    /// An EMPTY route (POOL_ROUTE, no data) is an inventory fill: the maker's tA stays
    /// here (retain mode) and the output comes from inventory.
    function test_S1_pull_emptyRoute_inventoryFill() public {
        tB.mint(address(aggSolver), 100e18);
        Order memory o = _order(4);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _empty();
        p.inventory = AMOUNT_OUT;
        p.profitRecipient = address(aggSolver);
        uint256 routerA = tA.balanceOf(address(router));
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());

        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "maker paid from inventory");
        assertEq(tB.balanceOf(address(aggSolver)), 10e18, "inventory spent exactly the price");
        assertEq(tA.balanceOf(address(aggSolver)), AMOUNT_IN, "the maker's input is the new inventory");
        assertEq(tA.balanceOf(address(router)), routerA, "no route ran");
    }

    /// `maxPay` still caps the total, inventory included.
    function test_S1_maxPayCapsInventory() public {
        tB.mint(address(aggSolver), 100e18);
        Order memory o = _order(5);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _empty();
        p.inventory = AMOUNT_OUT;
        p.maxPay = AMOUNT_OUT - 1;
        vm.expectRevert();
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
    }

    function test_S1_inventoryAbove128BitsRefused() public {
        Order memory o = _order(6);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _empty();
        p.inventory = uint256(1) << 128;
        vm.expectRevert(AggregatorFillSolver.AmountTooLarge.selector);
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
    }

    /// DIRECT (the app's default delivery): an empty route, the leg paid from inventory.
    function test_S1_direct_emptyRoute_inventoryFill() public {
        tB.mint(address(aggSolver), 100e18);
        Order memory o = _directOrder(7);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _empty();
        p.inventory = 100e18;
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());

        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "maker paid exactly the live price");
        assertEq(tB.balanceOf(address(aggSolver)), 10e18, "inventory drew exactly the price");
    }

    /// DIRECT top-up is the MEASURED shortfall: the route paid the maker 85, the solver
    /// sends exactly 5 although the cap is 50.
    function test_S1_direct_topUpIsTheMeasuredShortfall() public {
        router.setRate(8_500);
        tB.mint(address(aggSolver), 50e18);
        Order memory o = _directOrder(8);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _planFor(AMOUNT_IN, maker, 0, NO_PATCH); // pays the maker directly
        p.inventory = 50e18;
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());

        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "maker: exactly the price");
        assertEq(tB.balanceOf(address(aggSolver)), 45e18, "5 drawn, not the cap");
    }

    /// DIRECT: a route that already paid in full draws nothing.
    function test_S1_direct_noDrawWhenTheRouteCovers() public {
        tB.mint(address(aggSolver), 50e18);
        Order memory o = _directOrder(9);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _planFor(AMOUNT_IN, maker, 0, NO_PATCH);
        p.inventory = 50e18;
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
        assertEq(tB.balanceOf(address(aggSolver)), 50e18, "inventory untouched");
    }

    /// DIRECT: a shortfall beyond the cap fails closed in the core's delta check.
    function test_S1_direct_shortfallBeyondCapFails() public {
        router.setRate(8_500);
        tB.mint(address(aggSolver), 50e18);
        Order memory o = _directOrder(10);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _planFor(AMOUNT_IN, maker, 0, NO_PATCH);
        p.inventory = 4e18;
        vm.expectRevert(Base.DeltaTooLow.selector);
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
    }

    /// NETTED: the draw is pushed, the pool delivers, the unused part is swept straight
    /// back — net, exactly the shortfall left the inventory.
    function test_S1_netted_inventoryCoversShortfall_unusedSweptBack() public {
        router.setRate(8_500);
        tB.mint(address(aggSolver), 50e18);
        Order memory o = _order(11);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _plan(address(aggSolver), 85e18);
        p.inventory = 50e18;
        aggSolver.executeItemFill(o, sig, AMOUNT_IN, p, "", 0, _np(), noGuard());

        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "maker paid");
        assertEq(tB.balanceOf(address(aggSolver)), 45e18, "net draw = the 5 shortfall");
        assertEq(tB.balanceOf(address(settlement)), 0, "nothing pooled");
    }

    // ═══════════════════════════ S-5: races ═══════════════════════════

    /// executeFill + the remainder sentinel: a competitor took 40 first; the stale
    /// full-size quote (100 in, minOut 95) still settles the 60 that are left — the
    /// floor scales to 57 — where the exact size reverts `OverFill`.
    function test_S5_maxSentinel_fillsTheRemainderAfterACompetitor() public {
        Order memory o = _order(20);
        bytes memory sig = _sign(o);
        aggSolver.executeFill(o, sig, 40e18, _planFor(40e18, address(aggSolver), 0, AMOUNT_WORD), "", _np());
        assertEq(settlement.filled(_digest(o)), 40e18, "the competitor's slice");

        RoutePlan memory stale = _planFor(AMOUNT_IN, address(aggSolver), 95e18, AMOUNT_WORD);
        vm.expectRevert(OrderState.OverFill.selector);
        aggSolver.executeFill(o, sig, AMOUNT_IN, stale, "", _np());

        uint256 makerB = tB.balanceOf(maker);
        aggSolver.executeFill(o, sig, type(uint256).max, stale, "", _np());
        assertEq(tB.balanceOf(maker) - makerB, 54e18, "the remainder, at the maker's price");
        assertEq(settlement.filled(_digest(o)), AMOUNT_IN, "order complete");
    }

    /// The scaled floor is still a price floor: the remainder at a worse rate misses it.
    function test_S5_maxSentinel_proRataFloorStillBinds() public {
        Order memory o = _order(21);
        bytes memory sig = _sign(o);
        aggSolver.executeFill(o, sig, 40e18, _planFor(40e18, address(aggSolver), 0, AMOUNT_WORD), "", _np());
        router.setRate(9_400); // 60 -> 56.4 < 57 (= 95 · 60 / 100)
        vm.expectRevert(
            _wrapped(abi.encodeWithSelector(AggregatorFillSolver.InsufficientOutput.selector, 564e17, 57e18))
        );
        aggSolver.executeFill(
            o, sig, type(uint256).max, _planFor(AMOUNT_IN, address(aggSolver), 95e18, AMOUNT_WORD), "", _np()
        );
    }

    /// executeItemFill's race guard: a stale `expectedFilled` reverts `OrderTaken`
    /// before the permits, the plan build and `matchSettle` — for a fraction of the
    /// unguarded loss.
    function test_S5_itemFill_guardRefusesATakenOrderCheaply() public {
        Order memory o = _order(22);
        bytes memory sig = _sign(o);
        ItemFillGuard memory g = noGuard();
        g.orderHash = _digest(o);
        aggSolver.executeItemFill(o, sig, 40e18, _planFor(40e18, address(aggSolver), 0, AMOUNT_WORD), "", 0, _np(), g);

        RoutePlan memory p = _planFor(AMOUNT_IN, address(aggSolver), 0, AMOUNT_WORD);
        uint256 g0 = gasleft();
        (bool ok, bytes memory ret) =
            address(aggSolver).call(abi.encodeCall(aggSolver.executeItemFill, (o, sig, AMOUNT_IN, p, "", 0, _np(), g)));
        uint256 guarded = g0 - gasleft();
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(MatchRaceGuard.OrderTaken.selector, 0, 0, 40e18), "typed race loss");

        g0 = gasleft();
        (ok,) = address(aggSolver)
            .call(abi.encodeCall(aggSolver.executeItemFill, (o, sig, AMOUNT_IN, p, "", 0, _np(), noGuard())));
        uint256 unguarded = g0 - gasleft();
        assertFalse(ok, "the unguarded stale fill fails too, later");
        emit log_named_uint("lost race, guarded   ", guarded);
        emit log_named_uint("lost race, unguarded ", unguarded);
        assertLt(guarded * 3, unguarded, "the guard makes losing cheap");

        g.expectedFilled = 40e18; // the state actually on chain: fills the rest
        aggSolver.executeItemFill(o, sig, 60e18, _planFor(60e18, address(aggSolver), 0, AMOUNT_WORD), "", 0, _np(), g);
        assertEq(settlement.filled(_digest(o)), AMOUNT_IN, "complete");
    }

    /// The nonce half (fill-once / nonce-cancelled orders, which `filled` cannot show).
    function test_S5_itemFill_liveNonceGuard() public {
        Order memory o = _order(23);
        bytes memory sig = _sign(o);
        uint256[] memory n = new uint256[](1);
        n[0] = 23;
        vm.prank(maker);
        settlement.cancelOrders(n);

        ItemFillGuard memory g = noGuard();
        g.liveNonce = true;
        vm.expectRevert(abi.encodeWithSelector(MatchRaceGuard.NonceTaken.selector, 0, maker, 23));
        aggSolver.executeItemFill(o, sig, AMOUNT_IN, _plan(address(aggSolver), 0), "", 0, _np(), g);
    }

    // ═══════════════════════════ S-6: the item path's floor ═══════════════════════════

    /// `minOut` is ABSOLUTE on executeItemFill (no core bump floor there): an input
    /// smaller than the quote misses it, where executeFill would scale it.
    function test_S6_itemPath_minOutIsAbsolute() public {
        Order memory o = _order(30);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _planFor(AMOUNT_IN, address(aggSolver), 95e18, AMOUNT_WORD);
        vm.expectRevert(); // InsufficientOutput(60e18 - 1, 95e18), wrapped by the executor
        aggSolver.executeItemFill(o, sig, 60e18, p, "", 0, _np(), noGuard());

        aggSolver.executeFill(o, sig, 60e18, p, "", _np()); // pro rata: the floor is 57
        assertEq(tB.balanceOf(maker), 54e18, "the pull path takes the smaller fill");
    }

    /// The SELL side of the item floor: `maxPay` below what the maker is owed now.
    function test_S6_itemPath_maxPayCapsTheOutput() public {
        Order memory o = _order(31);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _plan(address(aggSolver), 0);
        p.maxPay = AMOUNT_OUT - 1;
        vm.expectRevert();
        aggSolver.executeItemFill(o, sig, AMOUNT_IN, p, "", 0, _np(), noGuard());
    }

    // ═══════════════════════════ S-3: multi-input ═══════════════════════════

    function _twoInputOrder(uint256 nonce) internal returns (Order memory o) {
        tC.mint(maker, 5e18);
        _makerApprove(address(settlement), address(tC), type(uint160).max);
        LegIn[] memory legsIn = new LegIn[](2);
        legsIn[0] = LegIn(address(tA), AMOUNT_IN, 0);
        legsIn[1] = LegIn(address(tC), 5e18, 0);
        o = _order(nonce);
        o.legsIn = PackedEncode.legsIn(legsIn);
    }

    /// A single-target route (opaque or pool) cannot spend a second input currency, so
    /// the item path refuses it too rather than keep it as residue.
    function test_S3_itemPath_singleRouteRefusesASecondInput() public {
        Order memory o = _twoInputOrder(40);
        bytes memory sig = _sign(o);
        vm.expectRevert(AggregatorFillSolver.MultiInputUnrouted.selector);
        aggSolver.executeItemFill(o, sig, AMOUNT_IN, _plan(address(aggSolver), 0), "", 0, _np(), noGuard());
        RoutePlan memory p = _empty();
        vm.expectRevert(AggregatorFillSolver.MultiInputUnrouted.selector);
        aggSolver.executeItemFill(o, sig, AMOUNT_IN, p, "", 0, _np(), noGuard());
    }

    // ═══════════════════════════ S-2: receipts ═══════════════════════════

    uint256 constant PRICE = 2_000e18;
    uint256 constant BID = 2_050e18;

    function _sale(uint256 nonce, address module, uint256 amount, bytes memory data)
        internal
        view
        returns (Order memory o)
    {
        o = _blank(nonce);
        o.timing |= uint256(1) << 101; // BUY: the fixed tB price is the anchor, no input leg
        o.legsOut = PackedEncode.oneLegOut(address(tB), PRICE, 0, address(0));
        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.SETTLE, module, amount, address(0), data);
        o.items = PackedEncode.items(items);
        o.minFillAnchor = PRICE;
    }

    function _multi(address t0, bytes memory d0, address t1, bytes memory d1)
        internal
        view
        returns (RoutePlan memory p)
    {
        address[] memory targets = new address[](2);
        bytes[] memory datas = new bytes[](2);
        (targets[0], datas[0]) = (t0, d0);
        (targets[1], datas[1]) = (t1, d1);
        p = _plan(address(aggSolver), PRICE);
        p.router = MULTI_ROUTE;
        p.data = abi.encode(targets, datas);
    }

    /// THE ZERO-CAPITAL NFT SALE, THROUGH THE REAL SOLVER (the bespoke-solver version is
    /// packages/modules/nft/test/NettedNftSale.t.sol): SETTLE (early) hands the NFT to
    /// the solver, whose hook forwards it to the sandbox; the MULTICALL route sells it
    /// (approve the market, `buy721` paying the solver); the bid pays the maker; the
    /// spread is the filler's. The solver holds no tB at any point before the sale.
    function test_S2_nft721Sale_zeroCapital() public {
        NftSettlementModule nft721 = new NftSettlementModule(address(settlement));
        ZcfMock721 c = new ZcfMock721();
        ZcfNftMarket market = new ZcfNftMarket(tB);
        tB.mint(address(market), BID);
        c.mint(maker, 7);
        vm.prank(maker);
        c.setApprovalForAll(address(nft721), true);

        Order memory o = _sale(50, address(nft721), 1, abi.encode(address(c), uint256(7), uint256(1)));
        bytes memory sig = _sign(o);
        RoutePlan memory p = _multi(
            address(c),
            abi.encodeCall(ZcfMock721.setApprovalForAll, (address(market), true)),
            address(market),
            abi.encodeCall(ZcfNftMarket.buy721, (c, 7, BID, address(aggSolver)))
        );
        assertEq(tB.balanceOf(address(aggSolver)), 0, "no capital");
        aggSolver.executeItemFill(o, sig, PRICE, p, "", 0, _np(), noGuard());

        assertEq(c.ownerOf(7), address(market), "maker -> solver -> sandbox -> market");
        assertEq(tB.balanceOf(maker), PRICE, "maker paid its ask");
        assertEq(tB.balanceOf(address(this)), BID - PRICE - 1, "the spread, less the self-seeded floor");
        assertEq(tB.balanceOf(address(aggSolver)), 1, "the floor");
        assertEq(tB.balanceOf(address(settlement)), 0, "nothing pooled");
    }

    /// The same for an ERC-1155 lot (3 units).
    function test_S2_nft1155Sale_zeroCapital() public {
        Erc1155SettlementModule m1155 = new Erc1155SettlementModule(address(settlement));
        ZcfMock1155 c = new ZcfMock1155();
        ZcfNftMarket market = new ZcfNftMarket(tB);
        tB.mint(address(market), BID);
        c.mint(maker, 9, 3);
        vm.prank(maker);
        c.setApprovalForAll(address(m1155), true);

        // The item amount is the lot at full fill (the slice scales with the anchor).
        Order memory o = _sale(51, address(m1155), 3, abi.encode(address(c), uint256(9)));
        bytes memory sig = _sign(o);
        RoutePlan memory p = _multi(
            address(c),
            abi.encodeCall(ZcfMock1155.setApprovalForAll, (address(market), true)),
            address(market),
            abi.encodeCall(ZcfNftMarket.buy1155, (c, 9, 3, BID, address(aggSolver)))
        );
        aggSolver.executeItemFill(o, sig, PRICE, p, "", 0, _np(), noGuard());

        assertEq(c.balanceOf(address(market), 9), 3, "the lot reached the market");
        assertEq(c.balanceOf(address(aggSolver.SANDBOX()), 9), 0, "nothing left in the sandbox");
        assertEq(tB.balanceOf(maker), PRICE, "maker paid");
    }

    /// Outside an armed item fill the hooks refuse: no transfer can park an NFT on the
    /// solver (it could never move it out).
    function test_S2_nftHooksRefuseOutsideAFill() public {
        ZcfMock721 c = new ZcfMock721();
        c.mint(maker, 1);
        vm.prank(maker);
        vm.expectRevert();
        c.safeTransferFrom(maker, address(aggSolver), 1);

        ZcfMock1155 m = new ZcfMock1155();
        m.mint(maker, 1, 1);
        vm.prank(maker);
        vm.expectRevert();
        m.safeTransferFrom(maker, address(aggSolver), 1, 1, "");

        // An unknown selector reaches the fallback and is refused too.
        (bool ok,) = address(aggSolver).call(abi.encodeWithSignature("nope()"));
        assertFalse(ok);
    }

    /// The sandbox accepts an NFT only when its owner (the solver) moved it there.
    function test_S2_sandboxHooksAcceptOnlyTheOwner() public {
        RouteSandbox sb = aggSolver.SANDBOX();
        vm.expectRevert(RouteSandbox.OnlyOwner.selector);
        sb.onERC721Received(address(this), address(this), 1, "");
        vm.expectRevert(RouteSandbox.OnlyOwner.selector);
        sb.onERC1155Received(address(this), address(this), 1, 1, "");
        assertEq(
            sb.onERC721Received(address(aggSolver), address(aggSolver), 1, ""), RouteSandbox.onERC721Received.selector
        );
    }

    /// A FOREIGN ERC-20 receipt (no leg names tC): listed in the guard it is pushed to
    /// the sandbox and sold by the MULTICALL route; unlisted it is not routable (the
    /// route finds nothing to spend and the fill fails, atomically).
    function test_S2_foreignErc20Receipt_listedAndSold() public {
        ZcfForeignReceiptModule mod = new ZcfForeignReceiptModule();
        tC.mint(address(mod), 10_000e18);
        MockRouter routerC = new MockRouter(address(tC), address(tB));
        tB.mint(address(routerC), 10_000e18);

        Order memory o = _sale(52, address(mod), BID, abi.encode(address(tC)));
        bytes memory sig = _sign(o);
        RoutePlan memory p = _multi(
            address(tC),
            abi.encodeCall(tC.approve, (address(routerC), BID)),
            address(routerC),
            abi.encodeCall(MockRouter.swap, (BID, address(aggSolver)))
        );

        vm.expectRevert(); // unlisted: the receipt stays on the solver, the route can't spend it
        aggSolver.executeItemFill(o, sig, PRICE, p, "", 0, _np(), noGuard());

        ItemFillGuard memory g = noGuard();
        g.receipts = new address[](1);
        g.receipts[0] = address(tC);
        aggSolver.executeItemFill(o, sig, PRICE, p, "", 0, _np(), g);
        assertEq(tB.balanceOf(maker), PRICE, "maker paid out of the sold receipt");
        assertEq(tC.balanceOf(address(aggSolver)), 0, "the receipt was routed, not retained");
        assertEq(tC.balanceOf(address(routerC)), BID, "sold");
    }

    // ═══════════════════════════ S-7: zero output legs ═══════════════════════════

    /// An order with no output legs (a pure payment to the filler) fills route-less:
    /// nothing to deliver, the input is residue.
    function test_S7_zeroOutputLegs_routeLessFill() public {
        Order memory o = _blank(60);
        o.legsIn = _legsIn1(address(tA), 10e18);
        bytes memory sig = _sign(o);
        aggSolver.executeFill(o, sig, 10e18, _empty(), "", _np());
        assertEq(tA.balanceOf(address(this)), 10e18 - 1, "the input reached the filler (less the floor)");
    }

    // ═══════════════════════════ the sandbox's multicall mode ═══════════════════════════

    function test_multicall_forbiddenTargetRefusedPerCall() public {
        Order memory o = _order(70);
        bytes memory sig = _sign(o);
        RoutePlan memory p =
            _multi(address(tA), abi.encodeCall(tA.approve, (address(router), AMOUNT_IN)), address(permit3), "");
        vm.expectRevert(_wrapped(abi.encodeWithSelector(RouteSandbox.ForbiddenTarget.selector, address(permit3))));
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
    }

    function test_multicall_lengthMismatchRefused() public {
        Order memory o = _order(71);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _plan(address(aggSolver), 0);
        p.router = MULTI_ROUTE;
        p.data = abi.encode(new address[](1), new bytes[](0));
        vm.expectRevert(_wrapped(abi.encodeWithSelector(RouteSandbox.BadMulticall.selector)));
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
    }

    /// A multicall route on the PULL path: approve + swap as two calls.
    function test_multicall_pullFill() public {
        Order memory o = _order(72);
        bytes memory sig = _sign(o);
        RoutePlan memory p = _multi(
            address(tA),
            abi.encodeCall(tA.approve, (address(router), AMOUNT_IN)),
            address(router),
            abi.encodeCall(MockRouter.swap, (AMOUNT_IN, address(aggSolver)))
        );
        p.minOut = AMOUNT_OUT;
        aggSolver.executeFill(o, sig, AMOUNT_IN, p, "", _np());
        assertEq(tB.balanceOf(maker), AMOUNT_OUT);
    }
}

/// @title AggregatorZeroCapitalNativeTest
/// @notice S-7 (native shapes) and S-1 on a native order: WNATIVE beside the
///         `NativeBalance` leg — as an input (a pure unwrap, zero capital), as a fee leg
///         to the solver itself, as a fee leg to a third party paid by the route — and
///         WNATIVE inventory for the unwrap.
contract AggregatorZeroCapitalNativeTest is AggregatorFillSolverTest {
    MockWNative wn;
    NativeBalance nb;
    AggregatorFillSolver ns;
    MockRouter wnRouter; // tA -> WNATIVE

    function setUp() public override {
        super.setUp();
        wn = new MockWNative();
        nb = new NativeBalance();
        ns = newAggNative(address(settlement), _ops(), _noSplit(), new PoolVenue[](0), address(nb), address(wn));
        wnRouter = new MockRouter(address(tA), address(wn));
        _fundWn(address(wnRouter), 1_000e18);
    }

    function _fundWn(address to, uint256 amt) internal {
        vm.deal(address(this), amt);
        wn.deposit{value: amt}();
        wn.transfer(to, amt);
    }

    function _np() internal pure returns (Permit2612[] memory) {
        return new Permit2612[](0);
    }

    function _native(uint256 nonce, bytes memory legsIn, bytes memory legsOut) internal view returns (Order memory o) {
        o = _blank(nonce);
        o.legsIn = legsIn;
        o.legsOut = legsOut;
        o.timing |= uint256(1) << 104;
        o.exclusiveFiller = address(ns);
    }

    function _emptyRoute() internal view returns (RoutePlan memory p) {
        p = _plan(address(ns), 0);
        p.router = POOL_ROUTE;
        p.data = "";
    }

    /// WRBTC in, native out, NO route: the solver unwraps the maker's own WNATIVE.
    function test_S7_wnativeInput_pureUnwrap_zeroCapital() public {
        _fundWn(maker, 10e18);
        _makerApprove(address(settlement), address(wn), type(uint160).max);
        Order memory o =
            _native(1, _legsIn1(address(wn), 10e18), PackedEncode.oneLegOut(address(nb), 99e17, 0, address(0)));
        bytes memory sig = _sign(o);
        uint256 nativeBefore = maker.balance;
        ns.executeFill(o, sig, 10e18, _emptyRoute(), "", _np());
        assertEq(maker.balance - nativeBefore, 99e17, "native delivered");
        assertEq(wn.balanceOf(address(this)), 1e17 - 1, "the unwrap fee is the filler's, less the floor");
    }

    /// tA + WRBTC in, native out: the WRBTC is the slot's pre-route inflow — counted
    /// toward the send, netted out of the route's `minOut`.
    function test_S7_wnativeSecondInput_netsIntoTheUnwrap() public {
        _fundWn(maker, 5e18);
        _makerApprove(address(settlement), address(wn), type(uint160).max);
        LegIn[] memory li = new LegIn[](2);
        li[0] = LegIn(address(tA), AMOUNT_IN, 0);
        li[1] = LegIn(address(wn), 5e18, 0);
        Order memory o = _native(2, PackedEncode.legsIn(li), PackedEncode.oneLegOut(address(nb), 104e18, 0, address(0)));
        bytes memory sig = _sign(o);
        RoutePlan memory p = _planFor(AMOUNT_IN, address(ns), 100e18, NO_PATCH);
        p.router = address(wnRouter);
        uint256 nativeBefore = maker.balance;
        ns.executeFill(o, sig, AMOUNT_IN, p, "", _np());
        assertEq(maker.balance - nativeBefore, 104e18, "100 routed + 5 paid in, 104 sent");

        // The maker's 5 WRBTC alone cannot satisfy the route's own floor.
        Order memory o2 =
            _native(3, PackedEncode.legsIn(li), PackedEncode.oneLegOut(address(nb), 104e18, 0, address(0)));
        _fundWn(maker, 5e18);
        bytes memory sig2 = _sign(o2);
        p.minOut = 101e18; // the route makes 100
        vm.expectRevert();
        ns.executeFill(o2, sig2, AMOUNT_IN, p, "", _np());
    }

    /// A WRBTC fee leg to the solver ITSELF (the relayer's fee): the route pays here, the
    /// unwrap takes the native leg, the fee is what remains — any route works.
    function test_S7_wnativeFeeLegToTheSolver() public {
        LegOut[] memory lo = new LegOut[](2);
        lo[0] = LegOut(address(nb), 90e18, 0, address(0));
        lo[1] = LegOut(address(wn), 1e18, 0, address(ns));
        Order memory o = _native(4, _legsIn1(address(tA), AMOUNT_IN), PackedEncode.legsOut(lo));
        bytes memory sig = _sign(o);
        RoutePlan memory p = _planFor(AMOUNT_IN, address(ns), 0, NO_PATCH);
        p.router = address(wnRouter);
        uint256 nativeBefore = maker.balance;
        ns.executeFill(o, sig, AMOUNT_IN, p, "", _np());
        assertEq(maker.balance - nativeBefore, 90e18, "native leg");
        assertEq(wn.balanceOf(address(this)), 10e18 - 1, "fee + spread to the filler, less the floor");
    }

    /// A WRBTC fee leg to a THIRD party, paid by the route itself (a multicall: two
    /// swaps, one paying the fee recipient). The core verifies both legs.
    function test_S7_wnativeFeeLegToAThirdParty_paidByTheRoute() public {
        address fee = address(0xFEE);
        LegOut[] memory lo = new LegOut[](2);
        lo[0] = LegOut(address(nb), 90e18, 0, address(0));
        lo[1] = LegOut(address(wn), 1e18, 0, fee);
        Order memory o = _native(5, _legsIn1(address(tA), AMOUNT_IN), PackedEncode.legsOut(lo));
        bytes memory sig = _sign(o);
        address[] memory targets = new address[](3);
        bytes[] memory datas = new bytes[](3);
        (targets[0], datas[0]) = (address(tA), abi.encodeCall(tA.approve, (address(wnRouter), AMOUNT_IN)));
        (targets[1], datas[1]) = (address(wnRouter), abi.encodeCall(MockRouter.swap, (99e18, address(ns))));
        (targets[2], datas[2]) = (address(wnRouter), abi.encodeCall(MockRouter.swap, (1e18, fee)));
        RoutePlan memory p = _plan(address(ns), 0);
        p.router = MULTI_ROUTE;
        p.data = abi.encode(targets, datas);
        ns.executeFill(o, sig, AMOUNT_IN, p, "", _np());
        assertEq(wn.balanceOf(fee), 1e18, "fee leg paid by the route");
        assertEq(maker.balance, 90e18, "native leg");
    }

    /// S-1 on a native order: an empty route, the unwrap paid from WNATIVE inventory.
    function test_S1_native_emptyRoute_unwrapsInventory() public {
        _fundWn(address(ns), 100e18);
        Order memory o =
            _native(6, _legsIn1(address(tA), AMOUNT_IN), PackedEncode.oneLegOut(address(nb), 90e18, 0, address(0)));
        bytes memory sig = _sign(o);
        RoutePlan memory p = _emptyRoute();
        p.inventory = 90e18;
        uint256 nativeBefore = maker.balance;
        ns.executeFill(o, sig, AMOUNT_IN, p, "", _np());
        assertEq(maker.balance - nativeBefore, 90e18, "native from inventory");
        assertEq(wn.balanceOf(address(ns)), 10e18, "inventory drew exactly the leg");

        // Without the cap the held WNATIVE is unreachable.
        Order memory o2 =
            _native(7, _legsIn1(address(tA), AMOUNT_IN), PackedEncode.oneLegOut(address(nb), 5e18, 0, address(0)));
        bytes memory sig2 = _sign(o2);
        vm.expectRevert();
        ns.executeFill(o2, sig2, AMOUNT_IN, _emptyRoute(), "", _np());
    }
}
