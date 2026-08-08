// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "../shared/PackedEncode.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, LegIn, LegOut, OrderSide, Validator, CallbackMode} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";
import {SettlementLens} from "@core/periphery/SettlementLens.sol";
import {NftSettlementModule} from "@core/modules/NftSettlementModule.sol";
import {Erc1155SettlementModule} from "@core/modules/Erc1155SettlementModule.sol";
import {Erc721OwnerInvariant, Erc1155BalanceInvariant} from "@core/validators/OwnershipInvariants.sol";
import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

/// @dev Minimal ERC-721 (no receiver hook — keeps the swap helpers simple).
contract Mock721 {
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
    }
}

/// @dev Minimal ERC-1155.
contract Mock1155 {
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

/// @dev The filler's delivery arm for purchase/swap fills: called through the
///      settlement's allowance-less EXECUTOR during `fillWithCallback`, transfers
///      an asset THIS contract owns to the maker. (In production this is the
///      solver's own executor logic.)
contract NftDeliveryHelper {
    function deliver721(address collection, uint256 id, address to) external {
        Mock721(collection).safeTransferFrom(address(this), to, id);
    }

    function deliver1155(address token, uint256 id, uint256 amount, address to) external {
        Mock1155(token).safeTransferFrom(address(this), to, id, amount, "");
    }

    function nothing() external {}
}

/// @title ExoticSettlement
/// @notice The three shapes {OwnershipInvariants} + {Erc1155SettlementModule}
///         unlock beyond the plain NFT sale:
///           • token-for-NFT — the maker BUYS: pays a fungible input leg, the
///             filler delivers the NFT in its callback, {Erc721OwnerInvariant}
///             makes delivery reverting-mandatory;
///           • NFT-for-NFT — maker's NFT leaves via a SETTLE item, the incoming
///             one is proven by the invariant; pure-NFT denominators via
///             `fillTotal`;
///           • ERC-1155 quantities — divisible SETTLE slices that compose with
///             partial fills, plus the 1155 purchase floor.
contract ExoticSettlementTest is CoreSettlementBase {
    NftSettlementModule nft721Module;
    Erc1155SettlementModule nft1155Module;
    Erc721OwnerInvariant ownerInv;
    Erc1155BalanceInvariant balance1155Inv;
    Mock721 nftA; // maker's collection in swaps; filler's ware in purchases
    Mock721 nftB;
    Mock1155 multi;
    NftDeliveryHelper helper;

    uint256 constant PRICE = 2_000e6;

    function setUp() public override {
        super.setUp();
        nft721Module = new NftSettlementModule(address(settlement));
        nft1155Module = new Erc1155SettlementModule(address(settlement));
        ownerInv = new Erc721OwnerInvariant();
        balance1155Inv = new Erc1155BalanceInvariant();
        nftA = new Mock721();
        nftB = new Mock721();
        multi = new Mock1155();
        helper = new NftDeliveryHelper();
    }

    function _invariant1(address target, bytes memory data) internal pure returns (Validator[] memory v) {
        v = new Validator[](1);
        v[0] = Validator(target, data);
    }

    // ════════════════ token-for-NFT: the maker BUYS an NFT ════════════════

    /// @dev SELL shape: maker pays USDC (`legsIn`), no fungible output, no items —
    ///      the receipt is enforced purely by the signed {Erc721OwnerInvariant}.
    ///      The filler is paid FIRST (PostInputs) and delivers from the callback —
    ///      a zero-inventory NFT fill.
    function _purchaseOrder(uint256 nonce, uint256 wantId) internal view returns (Order memory o) {
        o = _sellOrder(nonce, maker, USDC, address(0), PRICE, 0, new Item[](0));
        o.legsOut = PackedEncode.legsOut(new LegOut[](0));
        o.minFillAnchor = PRICE; // indivisible purchase — full-fill only
        o.invariants = PackedEncode.validators(_invariant1(address(ownerInv), abi.encode(address(nftA), wantId, maker)));
    }

    function test_nftPurchase_fillerDelivers_viaInvariant() public {
        uint256 id = 7;
        nftA.mint(address(helper), id); // the filler's inventory arm holds the ware
        deal(USDC, maker, PRICE);
        _approveMakerToSettlement(USDC, PRICE);

        Order memory order = _purchaseOrder(1, id);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fillWithCallback(
            order,
            sig,
            PRICE,
            address(helper),
            abi.encodeCall(NftDeliveryHelper.deliver721, (address(nftA), id, maker)),
            CallbackMode.PostInputs
        );

        assertEq(nftA.ownerOf(id), maker, "maker received the NFT");
        assertEq(IERC20(USDC).balanceOf(solver), PRICE, "filler received the price");
    }

    function test_nftPurchase_undelivered_reverts_makerKeepsFunds() public {
        uint256 id = 8;
        nftA.mint(address(helper), id);
        deal(USDC, maker, PRICE);
        _approveMakerToSettlement(USDC, PRICE);

        Order memory order = _purchaseOrder(2, id);
        bytes memory sig = _sign(order);

        // Callback does nothing → the ownership invariant fails → whole fill unwinds.
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.InvariantFailed.selector, 0));
        settlement.fillWithCallback(
            order, sig, PRICE, address(helper), abi.encodeCall(NftDeliveryHelper.nothing, ()), CallbackMode.PostInputs
        );

        assertEq(IERC20(USDC).balanceOf(maker), PRICE, "maker keeps the funds");
        assertEq(nftA.ownerOf(id), address(helper), "NFT never moved");
    }

    /// @dev The purchase shape must be lens-clean: SELL + empty legsOut + no items
    ///      is legitimate WITH a signed invariant (was: "giveaway" false-reject).
    function test_lens_acceptsInvariantProtectedPurchase() public view {
        (bool ok, string memory reason) = lens.validateOrder(_purchaseOrder(3, 9));
        assertTrue(ok, string.concat("purchase shape should validate: ", reason));
    }

    // ════════════════ NFT-for-NFT swap ════════════════

    /// @dev Pure NFT swap: no fungible legs at all — `fillTotal = 1` supplies the
    ///      denominator. Maker's nftA #1 leaves via the SETTLE item; the incoming
    ///      nftB #2 is proven by the ownership invariant. The filler delivers its
    ///      side in a PreDelivery callback, then the item hands over the maker's.
    function test_nftForNft_swap() public {
        nftA.mint(maker, 1);
        nftB.mint(address(helper), 2);
        vm.prank(maker);
        nftA.setApprovalForAll(address(nft721Module), true);

        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.SETTLE, address(nft721Module), 1, address(0), abi.encode(address(nftA), 1));

        Order memory order = _sellOrder(10, maker, address(0), address(0), 0, 0, items);
        order.legsIn = PackedEncode.legsIn(new LegIn[](0));
        order.legsOut = PackedEncode.legsOut(new LegOut[](0));
        order.fillTotal = 1; //     pure-NFT denominator (1 lot)
        order.minFillAnchor = 1; // full-fill only
        order.invariants = PackedEncode.validators(_invariant1(address(ownerInv), abi.encode(address(nftB), 2, maker)));
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fillWithCallback(
            order,
            sig,
            1,
            address(helper),
            abi.encodeCall(NftDeliveryHelper.deliver721, (address(nftB), 2, maker)),
            CallbackMode.PreDelivery
        );

        assertEq(nftA.ownerOf(1), solver, "filler got the maker's NFT");
        assertEq(nftB.ownerOf(2), maker, "maker got the filler's NFT");
    }

    // ════════════════ ERC-1155: divisible SETTLE quantities ════════════════

    /// @dev 1155 sale: 100 units of id 5 for PRICE USDC total, partial-fillable —
    ///      each fill moves its exact pro-rata quantity (divisible SETTLE).
    function _erc1155SaleOrder(uint256 nonce, uint256 units) internal view returns (Order memory o) {
        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.SETTLE, address(nft1155Module), units, address(0), abi.encode(address(multi), 5));
        LegOut[] memory legsOut = new LegOut[](1);
        legsOut[0] = LegOut(USDC, PRICE, 0, address(0));
        o = _sellOrder(nonce, maker, address(0), address(0), 0, 0, items);
        o.timing |= uint256(1) << 101; // BUY (timing bit 101) // fixed USDC output = the anchor/price
        o.legsIn = PackedEncode.legsIn(new LegIn[](0));
        o.legsOut = PackedEncode.legsOut(legsOut);
    }

    function test_erc1155Sale_partialFills_exactQuantities() public {
        uint256 units = 100;
        multi.mint(maker, 5, units);
        vm.prank(maker);
        multi.setApprovalForAll(address(nft1155Module), true);
        _fundSolverUsdc(solver, PRICE);

        Order memory order = _erc1155SaleOrder(20, units);
        (bool ok, string memory reason) = lens.validateOrder(order);
        assertTrue(ok, string.concat("divisible SETTLE partials should validate: ", reason));
        bytes memory sig = _sign(order);

        vm.startPrank(solver);
        settlement.fill(order, sig, (PRICE * 30) / 100); // 30%
        assertEq(multi.balanceOf(solver, 5), 30, "first slice: 30 units");
        settlement.fill(order, sig, PRICE - (PRICE * 30) / 100); // the rest
        vm.stopPrank();

        assertEq(multi.balanceOf(solver, 5), units, "slices accumulate to the full quantity");
        assertEq(multi.balanceOf(maker, 5), 0, "maker sold out");
        assertEq(IERC20(USDC).balanceOf(maker), PRICE, "maker fully paid");
    }

    /// @dev 1155 purchase: maker pays USDC, filler delivers 40 units of id 9;
    ///      receipt proven by {Erc1155BalanceInvariant}.
    function test_erc1155Purchase_viaBalanceInvariant() public {
        multi.mint(address(helper), 9, 40);
        deal(USDC, maker, PRICE);
        _approveMakerToSettlement(USDC, PRICE);

        Order memory order = _sellOrder(21, maker, USDC, address(0), PRICE, 0, new Item[](0));
        order.legsOut = PackedEncode.legsOut(new LegOut[](0));
        order.minFillAnchor = PRICE;
        order.invariants = PackedEncode.validators(
            _invariant1(address(balance1155Inv), abi.encode(address(multi), maker, uint256(9), uint256(40)))
        );
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fillWithCallback(
            order,
            sig,
            PRICE,
            address(helper),
            abi.encodeCall(NftDeliveryHelper.deliver1155, (address(multi), 9, 40, maker)),
            CallbackMode.PostInputs
        );

        assertEq(multi.balanceOf(maker, 9), 40, "maker received the quantity");
        assertEq(IERC20(USDC).balanceOf(solver), PRICE, "filler paid");
    }

    function _fundSolverUsdc(address who, uint256 usdc) internal {
        deal(USDC, who, usdc);
        vm.startPrank(who);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDC, uint160(usdc), 0);
        vm.stopPrank();
    }
}
