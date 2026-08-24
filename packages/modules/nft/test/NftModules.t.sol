// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, LegIn, LegOut} from "@core/settlement/Settlement.sol";

import {NftSettlementModule} from "../src/NftSettlementModule.sol";
import {Erc1155SettlementModule} from "../src/Erc1155SettlementModule.sol";

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";

interface IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

/// @dev Minimal ERC-721: mint + setApprovalForAll + safeTransferFrom (with the
///      receiver hook, so a non-receiver contract can't be sold an NFT).
contract MockERC721 {
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
                IERC721Receiver(to).onERC721Received(msg.sender, from, id, "")
                    == IERC721Receiver.onERC721Received.selector,
                "bad receiver"
            );
        }
    }
}

/// @dev Minimal ERC-1155.
contract MockERC1155 {
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

/// @title NftModules
/// @notice The two shipped `ISettlementModule` products, end to end through a real
///         fill: the INDIVISIBLE 721 sale and the DIVISIBLE 1155 sale.
///
///  Core's own SETTLE semantics — dispatch, filler-awareness, the pro-rata slice and
///  the {Base.SettleSliceZero} floor — are proven in core against local mocks
///  (`SettleSlice.t.sol`, `NftSettlement.t.sol`). What is proven HERE is what these
///  two contracts add on top: that the encoded `(collection, id)` reaches the right
///  token transfer, that the 1155 one honours `slice` while the 721 one ignores it,
///  and that both refuse a caller that is not the settlement.
contract NftModulesTest is CoreSettlementBase {
    NftSettlementModule nft721;
    Erc1155SettlementModule nft1155;
    MockERC721 collection;
    MockERC1155 multi;

    uint256 constant PRICE = 2_000e6;

    function setUp() public override {
        super.setUp();
        nft721 = new NftSettlementModule(address(settlement));
        nft1155 = new Erc1155SettlementModule(address(settlement));
        collection = new MockERC721();
        multi = new MockERC1155();
    }

    /// @dev BUY shape: the fixed USDC output is the anchor, the SETTLE item hands the
    ///      ware to whoever fills.
    function _saleOrder(uint256 nonce, address module, uint256 amount, bytes memory data)
        internal
        view
        returns (Order memory o)
    {
        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.SETTLE, module, amount, address(0), data);
        LegOut[] memory legsOut = new LegOut[](1);
        legsOut[0] = LegOut(USDC, PRICE, 0, address(0));
        o = _sellOrder(nonce, maker, address(0), address(0), 0, 0, items);
        o.timing |= uint256(1) << 101; // BUY
        o.legsIn = PackedEncode.legsIn(new LegIn[](0));
        o.legsOut = PackedEncode.legsOut(legsOut);
    }

    function _fundSolver(uint256 usdc) internal {
        deal(USDC, solver, usdc);
        _approveSolverSide(usdc, USDC);
    }

    // ── ERC-721: indivisible ──

    function test_721_saleDeliversTheTokenToTheFiller() public {
        uint256 id = 7;
        collection.mint(maker, id);
        vm.prank(maker);
        collection.setApprovalForAll(address(nft721), true);
        _fundSolver(PRICE);

        Order memory o = _saleOrder(1, address(nft721), 1, abi.encode(address(collection), id));
        o.minFillAnchor = PRICE; // indivisible lot — full-fill only
        bytes memory sig = _sign(o);

        vm.prank(solver);
        settlement.fill(o, sig, PRICE);

        assertEq(collection.ownerOf(id), solver, "filler received the NFT");
        assertEq(IERC20(USDC).balanceOf(maker), PRICE, "maker was paid first");
    }

    function test_721_directCall_reverts() public {
        collection.mint(maker, 1);
        vm.expectRevert(NftSettlementModule.OnlySettlement.selector);
        nft721.settle(maker, solver, 1, abi.encode(address(collection), uint256(1)));
    }

    // ── ERC-1155: divisible, slice-honouring ──

    function test_1155_partialFillsMoveExactQuantities() public {
        uint256 id = 5;
        uint256 units = 100;
        multi.mint(maker, id, units);
        vm.prank(maker);
        multi.setApprovalForAll(address(nft1155), true);
        _fundSolver(PRICE);

        Order memory o = _saleOrder(2, address(nft1155), units, abi.encode(address(multi), id));
        bytes memory sig = _sign(o);

        vm.startPrank(solver);
        settlement.fill(o, sig, (PRICE * 30) / 100);
        assertEq(multi.balanceOf(solver, id), 30, "first slice: 30 units");
        settlement.fill(o, sig, PRICE - (PRICE * 30) / 100);
        vm.stopPrank();

        assertEq(multi.balanceOf(solver, id), units, "slices accumulate to the full quantity");
        assertEq(multi.balanceOf(maker, id), 0, "maker sold out");
        assertEq(IERC20(USDC).balanceOf(maker), PRICE, "maker fully paid");
    }

    function test_1155_directCall_reverts() public {
        vm.expectRevert(Erc1155SettlementModule.OnlySettlement.selector);
        nft1155.settle(maker, solver, 1, abi.encode(address(multi), uint256(5)));
    }
}
