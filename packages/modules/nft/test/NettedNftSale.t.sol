// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MockSettlementBase, MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Settlement, Order, Item, ItemOp, LegIn, LegOut, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";

import {NftSettlementModule} from "../src/NftSettlementModule.sol";
import {Erc1155SettlementModule} from "../src/Erc1155SettlementModule.sol";

interface INettedERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

/// @dev Minimal ERC-721 WITH the receiver hook, so the solver contract must really be
///      a receiver to be sold the token.
contract NettedMock721 {
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
                INettedERC721Receiver(to).onERC721Received(msg.sender, from, id, "")
                    == INettedERC721Receiver.onERC721Received.selector,
                "bad receiver"
            );
        }
    }
}

/// @dev Minimal ERC-1155 (no receiver hook — the slice arithmetic is the point).
contract NettedMock1155 {
    mapping(uint256 => mapping(address => uint256)) public balanceOf_;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function balanceOf(address account, uint256 id) external view returns (uint256) {
        return balanceOf_[id][account];
    }

    function mint(address to, uint256 id, uint256 amount) external {
        balanceOf_[id][to] += amount;
    }

    function setApprovalForAll(address op, bool ok) external {
        isApprovedForAll[msg.sender][op] = ok;
    }

    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata) external {
        require(msg.sender == from || isApprovedForAll[from][msg.sender], "not approved");
        balanceOf_[id][from] -= amount;
        balanceOf_[id][to] += amount;
    }
}

/// @dev The market the solver sells into: takes the asset from the caller and pays
///      the bid in `payToken`, straight to `payTo`.
contract NettedNftBuyer {
    MockERC20 immutable payToken;

    constructor(MockERC20 t) {
        payToken = t;
    }

    function buy721(NettedMock721 c, uint256 id, uint256 price, address payTo) external {
        c.safeTransferFrom(msg.sender, address(this), id);
        payToken.transfer(payTo, price);
    }

    function buy1155(NettedMock1155 c, uint256 id, uint256 units, uint256 price, address payTo) external {
        c.safeTransferFrom(msg.sender, address(this), id, units, "");
        payToken.transfer(payTo, price);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return INettedERC721Receiver.onERC721Received.selector;
    }
}

/// @dev A zero-inventory solver. It calls `matchSettle` — so it is the `filler` the
///      SETTLE item pays the asset to — and in a CALL step sells that asset to the
///      buyer, who pays the pool directly. Authenticated as a fund-releasing CALL
///      target must be (executor AND an entrypoint-armed flag).
contract NettedNftSolver {
    Settlement immutable settlement;
    NettedNftBuyer immutable buyer;
    uint256 armed = 1;

    constructor(Settlement s, NettedNftBuyer b) {
        settlement = s;
        buyer = b;
    }

    function run(MatchPlan calldata p) external {
        armed = 2;
        settlement.matchSettle(p);
        armed = 1;
    }

    function sell721(NettedMock721 c, uint256 id, uint256 price) external {
        require(msg.sender == address(settlement.EXECUTOR()) && armed == 2, "not my plan");
        c.setApprovalForAll(address(buyer), true);
        buyer.buy721(c, id, price, address(settlement));
    }

    function sell1155(NettedMock1155 c, uint256 id, uint256 units, uint256 price) external {
        require(msg.sender == address(settlement.EXECUTOR()) && armed == 2, "not my plan");
        c.setApprovalForAll(address(buyer), true);
        buyer.buy1155(c, id, units, price, address(settlement));
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return INettedERC721Receiver.onERC721Received.selector;
    }
}

/// @title NettedNftSaleTest
/// @notice The NFT / 1155 sale on the NETTED path. On the single-order path the filler
///         pays the maker BEFORE the SETTLE item hands it the asset, so it needs the
///         full price in inventory. `matchSettle` (SETTLE admitted since task 31) lets
///         the solver schedule ITEM → CALL (sell the asset) → DELIVER (pay the maker
///         out of the sale), i.e. a sale with zero solver capital.
///
///         The SETTLE item pays `ctx.filler`, which on this path is `matchSettle`'s
///         `msg.sender` — the same party that owes the delivery — so the asset never
///         enters the pool and cannot be swept to anyone else.
contract NettedNftSaleTest is MockSettlementBase {
    NftSettlementModule nft721;
    Erc1155SettlementModule nft1155;
    NettedMock721 collection;
    NettedMock1155 multi;
    NettedNftBuyer buyer;
    NettedNftSolver nftSolver;

    uint256 constant PRICE = 2_000e18; // the maker's ask, in tB
    uint256 constant BID = 2_050e18; //   what the market pays the solver

    function setUp() public override {
        super.setUp();
        nft721 = new NftSettlementModule(address(settlement));
        nft1155 = new Erc1155SettlementModule(address(settlement));
        collection = new NettedMock721();
        multi = new NettedMock1155();
        buyer = new NettedNftBuyer(tB);
        nftSolver = new NettedNftSolver(settlement, buyer);
        tB.mint(address(buyer), 10 * BID);
    }

    /// @dev BUY shape: the fixed tB output is the anchor, no input legs, and the SETTLE
    ///      item hands the asset to whoever fills.
    function _sale(uint256 nonce, address module, uint256 amount, bytes memory data, uint256 price)
        internal
        view
        returns (Order memory o)
    {
        o = _blank(nonce);
        o.timing |= uint256(1) << 101; // BUY
        o.legsOut = PackedEncode.oneLegOut(address(tB), price, 0, address(0));
        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.SETTLE, module, amount, address(0), data);
        o.items = PackedEncode.items(items);
    }

    function _step(uint256 kind, uint256 a, uint256 b) internal pure returns (uint256) {
        return MatchStep.pack(kind, a, b);
    }

    function _plan1(Order memory o, uint256 fill, uint256[] memory s, bytes memory callData)
        internal
        view
        returns (MatchPlan memory p)
    {
        Order[] memory orders = new Order[](1);
        orders[0] = o;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(o);
        uint256[] memory fills = new uint256[](1);
        fills[0] = fill;
        address[] memory targets = new address[](1);
        targets[0] = address(nftSolver);
        bytes[] memory datas = new bytes[](1);
        datas[0] = callData;
        p = MatchPlan({
            orders: orders,
            sigs: sigs,
            fillAmounts: fills,
            takerDatas: new bytes[](0),
            schedule: s,
            callTargets: targets,
            callDatas: datas,
            profitRecipient: address(0)
        });
    }

    function _itemCallDeliver() internal pure returns (uint256[] memory s) {
        s = new uint256[](3);
        s[0] = _step(MatchStep.ITEM, 0, 0); //    asset → solver (the filler)
        s[1] = _step(MatchStep.CALL, 0, 0); //    solver sells it; the bid lands in the pool
        s[2] = _step(MatchStep.DELIVER, 0, 0); // the maker is paid out of the sale
    }

    // ── ERC-721 ──

    function test_netted_721Sale_zeroCapital() public {
        uint256 id = 7;
        collection.mint(maker, id);
        vm.prank(maker);
        collection.setApprovalForAll(address(nft721), true);

        Order memory o = _sale(1, address(nft721), 1, abi.encode(address(collection), id, uint256(1)), PRICE);
        o.minFillAnchor = PRICE; // indivisible lot
        MatchPlan memory p =
            _plan1(o, PRICE, _itemCallDeliver(), abi.encodeCall(NettedNftSolver.sell721, (collection, id, BID)));

        assertEq(tB.balanceOf(address(nftSolver)), 0, "solver starts with no tB");
        nftSolver.run(p);

        assertEq(collection.ownerOf(id), address(buyer), "the NFT went maker -> solver -> market");
        assertEq(tB.balanceOf(maker), PRICE, "maker paid its ask");
        assertEq(tB.balanceOf(address(nftSolver)), BID - PRICE, "solver keeps only the spread");
        assertEq(tB.balanceOf(address(settlement)), 0, "nothing pooled");
    }

    /// The forward ordering (DELIVER first) is the one that needs capital: with an
    /// empty pool and no inventory the delivery cannot be paid, and the plan reverts
    /// atomically — the NFT never leaves the maker.
    function test_netted_721Sale_deliverFirst_needsCapital() public {
        uint256 id = 8;
        collection.mint(maker, id);
        vm.prank(maker);
        collection.setApprovalForAll(address(nft721), true);

        Order memory o = _sale(2, address(nft721), 1, abi.encode(address(collection), id, uint256(1)), PRICE);
        o.minFillAnchor = PRICE;
        uint256[] memory s = new uint256[](3);
        s[0] = _step(MatchStep.DELIVER, 0, 0);
        s[1] = _step(MatchStep.ITEM, 0, 0);
        s[2] = _step(MatchStep.CALL, 0, 0);
        MatchPlan memory p = _plan1(o, PRICE, s, abi.encodeCall(NettedNftSolver.sell721, (collection, id, BID)));

        vm.expectRevert();
        nftSolver.run(p);
        assertEq(collection.ownerOf(id), maker, "atomic: the maker still owns the NFT");
    }

    // ── ERC-1155: the slice is honoured on the netted path ──

    /// A 30% partial fill through `matchSettle` moves exactly 30 of 100 units to the
    /// filler and pays the maker 30% of the ask — the same pro-rata slice the
    /// single-order path computes.
    function test_netted_1155PartialSale_movesExactlyTheSlice() public {
        uint256 id = 5;
        uint256 units = 100;
        multi.mint(maker, id, units);
        vm.prank(maker);
        multi.setApprovalForAll(address(nft1155), true);

        uint256 fill = (PRICE * 30) / 100;
        uint256 bid = (BID * 30) / 100;
        Order memory o = _sale(3, address(nft1155), units, abi.encode(address(multi), id), PRICE);
        MatchPlan memory p =
            _plan1(o, fill, _itemCallDeliver(), abi.encodeCall(NettedNftSolver.sell1155, (multi, id, 30, bid)));

        nftSolver.run(p);

        assertEq(multi.balanceOf(address(buyer), id), 30, "exactly the 30-unit slice was sold through");
        assertEq(multi.balanceOf(maker, id), 70, "the rest stays with the maker");
        assertEq(tB.balanceOf(maker), fill, "maker paid its slice of the ask");
        assertEq(tB.balanceOf(address(nftSolver)), bid - fill, "solver keeps the spread");
    }
}
