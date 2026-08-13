// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "../shared/PackedEncode.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp, LegIn, LegOut, OrderSide, Validator} from "@core/settlement/Settlement.sol";
import {Settlement} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";
import {SettlementLens} from "@core/periphery/SettlementLens.sol";
import {NftSettlementModule} from "@core/modules/NftSettlementModule.sol";
import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

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

interface IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

/// @dev The `SETTLE` op: a generic, FILLER-AWARE solver↔maker exchange. Proven
/// here on an NFT sale — the maker gives an ERC-721 to WHOEVER fills, and is paid
/// USDC via an inline `tokenOut` leg. No exclusive filler, no solver callback, no
/// ownership invariant: the maker's receipt is the mandatory fungible delivery
/// (run before items), and the NFT hands off only after the maker is paid.
///
///   side     = BUY (fixed USDC output = the price / anchor)
///   tokenOut = [USDC] → maker      (inline, mandatory delivery)
///   items    = [ SETTLE NftSettlementModule → maker's NFT to the filler ]
contract NftSettlementTest is CoreSettlementBase {
    NftSettlementModule nftModule;
    MockERC721 nft;
    uint256 constant TOKEN_ID = 1234;
    uint256 constant PRICE = 2_000e6; // USDC the maker wants

    function setUp() public override {
        super.setUp();
        nftModule = new NftSettlementModule(address(settlement));
        nft = new MockERC721();
        vm.label(address(nftModule), "nftSettlementModule");
        vm.label(address(nft), "mockNFT");

        // Maker owns the NFT and approves the settle module to move it.
        nft.mint(maker, TOKEN_ID);
        vm.prank(maker);
        nft.setApprovalForAll(address(nftModule), true);
    }

    function _nftSaleOrder(uint256 nonce) internal view returns (Order memory order) {
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.SETTLE,
            module: address(nftModule),
            amount: 1, //                one NFT
            recipient: address(0), //    unused by SETTLE (the module routes to the filler)
            data: abi.encode(address(nft), TOKEN_ID)
        });
        LegOut[] memory legsOut = new LegOut[](1);
        legsOut[0] = LegOut(USDC, PRICE, 0, address(0)); // fixed output to maker
        order = Order({
            params: 0,
            pricingModule: address(0),
            maker: maker,
            nonce: nonce,
            deadline: block.timestamp + 1 hours,
            legsIn: PackedEncode.legsIn(new LegIn[](0)), //   consideration is the NFT item, not a fungible input
            legsOut: PackedEncode.legsOut(legsOut),
            timing: 0,
            exclusiveFiller: address(0), //  OPEN — any solver may fill
            minFillAnchor: PRICE, //         full-fill only (indivisible)
            curve: PackedEncode.noCurve(),
            items: PackedEncode.items(items),
            validators: PackedEncode.noValidators(),
            invariants: PackedEncode.noValidators(),
            fillModule: address(0),
            fillTotal: 0
        });
        order.timing |= uint256(1) << 101; // BUY — fixed output = the price
    }

    function _fundSolver(address who, uint256 usdc) internal {
        deal(USDC, who, usdc);
        vm.startPrank(who);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDC, uint160(usdc), 0);
        vm.stopPrank();
    }

    // ── The NFT goes to whoever fills; the maker is paid USDC inline. No exclusivity. ──
    function test_nftSale_toOpenFiller() public {
        _fundSolver(solver, PRICE);
        Order memory order = _nftSaleOrder(1);
        bytes memory sig = _sign(order);

        assertEq(nft.ownerOf(TOKEN_ID), maker, "maker owns NFT pre-fill");
        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);

        vm.prank(solver); // a non-exclusive, unnamed filler
        settlement.fill(order, sig, PRICE);

        assertEq(nft.ownerOf(TOKEN_ID), solver, "NFT delivered to the filler");
        assertEq(IERC20(USDC).balanceOf(maker) - makerUsdcBefore, PRICE, "maker paid the price in USDC");
        assertEq(IERC20(USDC).balanceOf(solver), 0, "solver spent the full price");
    }

    // ── Filler-aware: a DIFFERENT filler receives the NFT — the module routes to
    //    ctx.filler, not a signed address, so there is no exclusivity. ──
    function test_nftSale_differentFiller_getsNft() public {
        address otherSolver = address(0xCAFE);
        _fundSolver(otherSolver, PRICE);
        Order memory order = _nftSaleOrder(2);
        bytes memory sig = _sign(order);

        vm.prank(otherSolver);
        settlement.fill(order, sig, PRICE);

        assertEq(nft.ownerOf(TOKEN_ID), otherSolver, "the actual filler got the NFT");
    }

    // ── Atomicity: if the solver can't pay, delivery reverts BEFORE the NFT
    //    moves — the maker never loses the NFT without being paid. ──
    function test_nftSale_unpaidSolver_reverts_nftUntouched() public {
        // Solver has no USDC / no approval → the mandatory tokenOut delivery fails.
        Order memory order = _nftSaleOrder(3);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert();
        settlement.fill(order, sig, PRICE);

        assertEq(nft.ownerOf(TOKEN_ID), maker, "NFT stayed with the maker on revert");
    }

    // ── Direct call to the module (bypassing Settlement) reverts. ──
    function test_settleModule_directCall_reverts() public {
        vm.expectRevert(NftSettlementModule.OnlySettlement.selector);
        nftModule.settle(maker, solver, 1, abi.encode(address(nft), TOKEN_ID));
    }

    // ── Lens ACCEPTS the canonical NFT-sale order (BUY, empty tokenIn, one SETTLE
    //    item). Regression: the empty-tokenIn preflight used to false-reject it,
    //    making the feature undiscoverable to solvers running getOrderRelevantState. ──
    function test_lens_acceptsNftSaleOrder() public {
        _fundSolver(solver, PRICE);
        Order memory order = _nftSaleOrder(4);
        bytes memory sig = _sign(order);

        (bool ok, string memory reason) = lens.validateOrder(order);
        assertTrue(ok, string.concat("NFT sale order should validate: ", reason));

        (SettlementLens.OrderStatus status, uint256 fillable,,) = lens.getOrderRelevantState(order, sig, solver, "");
        assertEq(uint8(status), uint8(SettlementLens.OrderStatus.Fillable), "preflight: Fillable, not Invalid");
        assertEq(fillable, PRICE, "full anchor fillable");
    }

    // ── Lens REJECTS a partial-fillable SETTLE order (footgun: a partial fill
    //    floors the NFT slice to 0 → first filler pays and gets nothing). ──
    function test_lens_rejectsPartialFillableSettle() public view {
        Order memory order = _nftSaleOrder(5);
        order.minFillAnchor = 0; // allow partial fills — the footgun
        (bool ok, string memory reason) = lens.validateOrder(order);
        assertFalse(ok, "partial-fillable SETTLE rejected");
        assertEq(reason, "settle item requires full-fill");
    }

    // ── ON-CHAIN guard: the same footgun now reverts at fill time, not just in
    //    the lens preflight. A partial fill of a (misparameterized) partial-
    //    fillable SETTLE order floors the slice to 0 → {SettleSliceZero} — the
    //    filler can never pay pro-rata and receive nothing. ──
    function test_settleGuard_partialFill_reverts() public {
        _fundSolver(solver, PRICE);
        Order memory order = _nftSaleOrder(6);
        order.minFillAnchor = 0; // maker signed away the full-fill floor anyway
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(Base.SettleSliceZero.selector);
        settlement.fill(order, sig, PRICE / 2);

        assertEq(nft.ownerOf(TOKEN_ID), maker, "NFT untouched");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "maker not paid on the reverted fill");
    }

    // ── ON-CHAIN guard: a zero `amount` sentinel makes even a FULL fill slice 0.
    //    Previously the maker was paid while the NFT transfer silently skipped;
    //    now the order is simply unfillable. ──
    function test_settleGuard_zeroAmountSentinel_reverts() public {
        _fundSolver(solver, PRICE);
        Order memory order = _nftSaleOrder(7);
        order.items = PackedEncode.setItemAmount(order.items, 0, 0); // the broken sentinel
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(Base.SettleSliceZero.selector);
        settlement.fill(order, sig, PRICE);

        assertEq(nft.ownerOf(TOKEN_ID), maker, "NFT untouched");
    }
}
