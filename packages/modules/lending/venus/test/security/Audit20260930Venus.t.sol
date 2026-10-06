// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {IProceedsAsset} from "@core/interfaces/IProceedsAsset.sol";
import {DustHandler} from "@lib/DustHandler.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";

import {VenusTakerModule} from "../../src/VenusModules.sol";
import {VenusModulesBase} from "../shared/VenusModulesBase.t.sol";

/// @dev `VenusTakerModule.UnderlyingMismatch(address,address)`, spelled out so these
///      files also compile against the pre-fix module (fails-before proof).
bytes4 constant UNDERLYING_MISMATCH = bytes4(keccak256("UnderlyingMismatch(address,address)"));

/// @title Audit20260930VenusForkTest
/// @notice 2026-09-30 audit (group B-lend1) against the LIVE Venus pool the package
///         harness forks:
///   • L-CV2-7 — `VenusTakerModule` op=1 (Exact `redeemUnderlyingBehalf` and Full
///     `redeemBehalf`) had never run against a live pool.
///   • L-CV2-4 — a blob naming the wrong underlying for a real vToken is rejected.
contract Audit20260930VenusForkTest is VenusModulesBase {
    function _withdrawItemOrder(uint256 nonce, bytes memory data, address tokenIn, uint256 amount, uint256 usdcOut)
        internal
        view
        returns (Order memory)
    {
        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE, address(takerModule), amount, address(0), data);
        return _order(maker, nonce, tokenIn, USDC, amount, usdcOut, items);
    }

    function _grantTaker(bytes memory data, uint256 cap) internal {
        vm.prank(maker);
        permit3.approveTaker(address(settlement), address(takerModule), keccak256(data), uint160(cap), 0);
    }

    /// Exact: `redeemUnderlyingBehalf` sized at the slice, the WETH forwarded to the
    /// solver; two partial fills sum to the signed amount.
    function test_audit_L_CV2_7_exactWithdraw_live() public {
        _seedVenusCollateral(2 ether);
        uint256 sell = 1 ether;
        bytes memory data = _withdrawData();
        _grantTaker(data, sell);
        deal(USDC, solver, 3_000e6);
        _approveSolverSide(3_000e6, USDC);

        Order memory order = _withdrawItemOrder(1, data, WETH, sell, 2_000e6);
        bytes memory sig = _sign(order);
        uint256 collBefore = _wethCollateral(maker);

        vm.prank(solver);
        settlement.fill(order, sig, sell / 2);
        vm.prank(solver);
        settlement.fill(order, sig, sell / 2);

        assertEq(IERC20(WETH).balanceOf(solver), sell, "solver received the signed WETH");
        assertApproxEqRel(collBefore - _wethCollateral(maker), sell, 1e10, "position down by the amount (vToken rounding)");
        // The isolated-pool redeem rounds redeemTokens UP, so it can deliver a few wei
        // MORE than asked; the module returns that surplus to the maker.
        assertLt(IERC20(WETH).balanceOf(maker), 1e10, "wallet only receives the rounding surplus");
        assertEq(IERC20(WETH).balanceOf(address(takerModule)), 0, "module holds nothing");
    }

    /// Full: `redeemBehalf` of the whole vToken balance, the signed amount to the
    /// solver and the remainder back to the maker.
    function test_audit_L_CV2_7_fullWithdraw_live() public {
        _seedVenusCollateral(2 ether);
        uint256 sell = 1.5 ether;
        bytes memory data = abi.encode(
            uint8(VenusTakerModule.Op.Withdraw),
            address(VWETH),
            WETH,
            DustHandler.encodeMode(DustHandler.BalanceMode.Full),
            sell
        );
        _grantTaker(data, sell);
        deal(USDC, solver, 3_000e6);
        _approveSolverSide(3_000e6, USDC);

        Order memory order = _withdrawItemOrder(2, data, WETH, sell, 2_000e6);
        bytes memory sig = _sign(order);
        uint256 collBefore = _wethCollateral(maker);

        vm.prank(solver);
        settlement.fill(order, sig, sell);

        assertEq(VWETH.balanceOf(maker), 0, "whole position redeemed");
        assertEq(IERC20(WETH).balanceOf(solver), sell, "solver got the signed amount");
        assertApproxEqAbs(IERC20(WETH).balanceOf(maker), collBefore - sell, 1e9, "remainder swept to maker");
        assertEq(IERC20(WETH).balanceOf(address(takerModule)), 0, "module holds nothing");
    }

    /// L-CV2-4 on the live pool: vWETH named with USDC as its underlying. Before the
    /// binding the module measured a zero USDC delta, forwarded 0, stranded the
    /// redeemed WETH on the singleton for good, and the core pulled the whole USDC
    /// input leg from the maker's wallet.
    function test_audit_L_CV2_4_withdraw_wrongUnderlying_reverts() public {
        _seedVenusCollateral(2 ether);
        uint256 sell = 1_000e6;
        bytes memory data = abi.encode(uint8(VenusTakerModule.Op.Withdraw), address(VWETH), USDC); // encoder bug
        _grantTaker(data, sell);
        deal(USDC, maker, sell);
        vm.prank(maker);
        permit3.approveToken(address(settlement), USDC, type(uint160).max, 0);
        deal(USDC, solver, 3_000e6);
        _approveSolverSide(3_000e6, USDC);

        // Sell USDC "from the withdraw" for USDC is degenerate but keeps one token;
        // what matters is the module's answer.
        Order memory order = _withdrawItemOrder(3, data, USDC, sell, 900e6);
        bytes memory sig = _sign(order);

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(UNDERLYING_MISMATCH, USDC, WETH));
        settlement.fill(order, sig, sell);

        assertEq(IERC20(USDC).balanceOf(maker), sell, "wallet not billed");
        assertEq(IERC20(WETH).balanceOf(address(takerModule)), 0, "nothing stranded");
    }

    /// Borrow sibling of L-CV2-4: vUSDC named with WETH.
    function test_audit_L_CV2_4_borrow_wrongUnderlying_reverts() public {
        _seedVenusCollateral(2 ether);
        bytes memory data = abi.encode(uint8(VenusTakerModule.Op.Borrow), address(VUSDC), WETH);
        vm.prank(address(permit3));
        vm.expectRevert(abi.encodeWithSelector(UNDERLYING_MISMATCH, WETH, USDC));
        takerModule.takeOnBehalf(maker, 100e6, address(settlement), data);
    }
}

// ──────────────────────────── unit (no fork) ────────────────────────────

contract AuditVenusMockToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 v) external {
        balanceOf[to] += v;
    }

    function transfer(address to, uint256 v) external returns (bool) {
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        return true;
    }
}

/// @dev BSC core-pool `redeemFresh` with `treasuryPercent != 0`: the redeemer (the
///      module) receives `amount - fee`, the treasury the fee (G-VENUE_A-2).
contract AuditVenusFeeVToken {
    AuditVenusMockToken public immutable u;
    uint256 public immutable feeBps;

    constructor(AuditVenusMockToken u_, uint256 feeBps_) {
        u = u_;
        feeBps = feeBps_;
    }

    function underlying() external view returns (address) {
        return address(u);
    }

    function redeemUnderlyingBehalf(address, uint256 amount) external returns (uint256) {
        uint256 fee = amount * feeBps / 10_000;
        u.transfer(address(0x7EA5), fee);
        u.transfer(msg.sender, amount - fee);
        return 0;
    }

    /// @dev A borrow over a fee-on-transfer underlying (Venus's `doTransferOut` pays
    ///      `amount`, the token takes its cut): the module receives `amount − fee`.
    function borrowBehalf(address, uint256 amount) external returns (uint256) {
        uint256 fee = amount * feeBps / 10_000;
        u.transfer(address(0x7EA5), fee);
        u.transfer(msg.sender, amount - fee);
        return 0;
    }
}

contract Audit20260930VenusUnitTest is Test {
    address constant PERMIT3 = address(0xBEEF);
    address maker = address(0xA11CE);
    address receiver = address(0x5E77);

    VenusTakerModule taker;
    AuditVenusMockToken token;

    function setUp() public {
        taker = new VenusTakerModule(PERMIT3);
        token = new AuditVenusMockToken();
    }

    /// The Exact withdraw used to forward `amount - fee` and let the core bill the
    /// fee to the maker's wallet. It now reverts (the venue call is sized at the
    /// slice, so the bound cannot misfire on a partial fill).
    function test_audit_G_VENUE_A_2_exactWithdraw_treasuryFee_reverts() public {
        AuditVenusFeeVToken v = new AuditVenusFeeVToken(token, 10); // 0.1 %
        token.mint(address(v), 1_000e18);
        // A stray balance on the module must not paper over the shortfall either.
        token.mint(address(taker), 50e18);

        bytes memory data = abi.encode(uint8(VenusTakerModule.Op.Withdraw), address(v), address(token));
        vm.prank(PERMIT3);
        vm.expectRevert(abi.encodeWithSelector(FullFillGuard.ShortWithdraw.selector, 999e18, 1_000e18));
        taker.takeOnBehalf(maker, 1_000e18, receiver, data);
    }

    /// Review 2026-10-06: the Borrow branch was cap-only — a short borrow was
    /// forwarded short and the core billed the gap to the maker's wallet while the
    /// maker kept the full debt. It now fails closed like its withdraw siblings.
    function test_review_venusBorrow_shortDelivery_reverts() public {
        AuditVenusFeeVToken v = new AuditVenusFeeVToken(token, 10); // 0.1 %
        token.mint(address(v), 1_000e18);
        token.mint(address(taker), 50e18); // a stray balance must not paper over it
        bytes memory data = abi.encode(uint8(VenusTakerModule.Op.Borrow), address(v), address(token));
        vm.prank(PERMIT3);
        vm.expectRevert(abi.encodeWithSelector(FullFillGuard.ShortWithdraw.selector, 999e18, 1_000e18));
        taker.takeOnBehalf(maker, 1_000e18, receiver, data);
    }

    /// …and an exact borrow is untouched by the bound.
    function test_review_venusBorrow_exactDelivery_forwards() public {
        AuditVenusFeeVToken v = new AuditVenusFeeVToken(token, 0);
        token.mint(address(v), 1_000e18);
        bytes memory data = abi.encode(uint8(VenusTakerModule.Op.Borrow), address(v), address(token));
        vm.prank(PERMIT3);
        taker.takeOnBehalf(maker, 400e18, receiver, data);
        assertEq(token.balanceOf(receiver), 400e18);
        assertEq(token.balanceOf(address(taker)), 0);
    }

    /// No fee ⇒ exact delivery ⇒ the bound is silent.
    function test_audit_G_VENUE_A_2_exactWithdraw_noFee_forwards() public {
        AuditVenusFeeVToken v = new AuditVenusFeeVToken(token, 0);
        token.mint(address(v), 1_000e18);
        bytes memory data = abi.encode(uint8(VenusTakerModule.Op.Withdraw), address(v), address(token));
        vm.prank(PERMIT3);
        taker.takeOnBehalf(maker, 400e18, receiver, data);
        assertEq(token.balanceOf(receiver), 400e18);
        assertEq(token.balanceOf(address(taker)), 0);
    }

    /// L-CMT-6: the module declares its proceeds token, so the lens's F22 check runs.
    /// Raw staticcall so this compiles — and FAILS — against the pre-fix module.
    function test_audit_L_CMT_6_declaresProceedsAsset() public view {
        bytes[2] memory blobs = [
            abi.encode(uint8(0), address(0xCAFE), address(token)),
            abi.encode(uint8(1), address(0xCAFE), address(token), DustHandler.encodeMode(DustHandler.BalanceMode.Full), 1)
        ];
        for (uint256 i; i < 2; ++i) {
            (bool ok, bytes memory ret) =
                address(taker).staticcall(abi.encodeCall(IProceedsAsset.proceedsAsset, (blobs[i])));
            assertTrue(ok && ret.length == 32, "answers proceedsAsset");
            assertEq(abi.decode(ret, (address)), address(token), "the underlying");
        }
    }
}
