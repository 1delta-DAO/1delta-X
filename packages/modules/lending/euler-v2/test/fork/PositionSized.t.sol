// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {DustHandler} from "@lib/DustHandler.sol";
import {PositionFillModule} from "@lib/PositionFillModule.sol";

import {EulerV2OperatorModule} from "../../src/EulerV2OperatorModule.sol";
import {IEulerVault} from "../../src/interfaces/IEulerV2.sol";
import {EulerV2ModulesBase} from "../shared/EulerV2ModulesBase.t.sol";

/// @dev POSITION-SIZED FILLS ON EULER V2 — one of the four venues the 2026-09-10
/// audit found had no `positionOf` coverage at all, which is why finding 1 (the
/// reader returned `maxWithdraw`, a reachability figure `IPositionSource` forbids)
/// survived into the tree.
///
/// The headline test opens a LEVERED position, so Euler's health check clips
/// `maxWithdraw` strictly below the real balance, and asserts `positionOf` reports
/// the raw one. It fails against the pre-fix reader.
contract EulerV2PositionSizedTest is EulerV2ModulesBase {
    PositionFillModule internal fillModule;

    uint256 internal constant COLLATERAL = 5 ether;
    uint256 internal constant DEBT = 4_000e6;
    uint256 internal constant CAP = 5.25 ether;
    uint256 internal constant QUOTE = 6_000e6;

    function setUp() public virtual override {
        super.setUp();
        fillModule = new PositionFillModule();
        vm.label(address(fillModule), "positionFillModule");
    }

    function _withdrawData() internal pure returns (bytes memory) {
        return abi.encode(uint8(EulerV2OperatorModule.Op.Withdraw), address(EWETH));
    }

    /// @dev The RAW position — shares converted at the current rate, no health or
    ///      liquidity clamp. What `positionOf` must report.
    function _rawPosition(address who) internal view returns (uint256) {
        return EWETH.convertToAssets(EWETH.balanceOf(who));
    }

    function _approveMaker(bytes memory data, uint256 cap) internal {
        vm.startPrank(maker);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), WETH, uint160(cap), 0);
        permit3.approveTaker(address(settlement), address(operatorModule), keccak256(data), uint160(cap), 0);
        vm.stopPrank();
    }

    function _positionOrder(uint256 nonce) internal view returns (Order memory order) {
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.TAKE,
            module: address(operatorModule),
            amount: CAP,
            recipient: address(0),
            data: _withdrawData()
        });
        order = _order(maker, nonce, WETH, USDC, CAP, QUOTE, items);
        order.fillModule = address(fillModule);
        order.fillTotal = CAP;
    }

    /// @dev FINDING 1 REGRESSION. Both halves asserted, so it cannot pass by
    /// coincidence on an unlevered position.
    function test_positionOf_isRawPosition_notMaxWithdraw() public {
        _openEulerPosition(COLLATERAL, DEBT);

        uint256 raw = _rawPosition(maker);
        uint256 reachable = EWETH.maxWithdraw(maker);

        assertGt(raw, 0, "position exists");
        assertLt(reachable, raw, "maxWithdraw IS clipped by the open debt: the finding premise");

        (address asset, uint256 reported) = operatorModule.positionOf(maker, _withdrawData());
        assertEq(asset, EWETH.asset(), "asset read from the vault");
        assertEq(reported, raw, "positionOf reports the RAW position");
        assertGt(reported, reachable, "and therefore NOT maxWithdraw");
    }

    function test_resolveFill_pricesOffTheRawPosition() public {
        _openEulerPosition(COLLATERAL, DEBT);
        _approveMaker(_withdrawData(), CAP);

        Order memory order = _positionOrder(1);
        (uint256 delta,,) = lens.previewFill(order, order.fillTotal, solver, "");

        assertEq(delta, _rawPosition(maker), "delta is the raw position");
        assertGt(delta, EWETH.maxWithdraw(maker), "not the health-clipped figure");
    }

    function test_positionSized_withdraw_sellsWholePosition() public {
        _seedEulerCollateral(COLLATERAL);
        _approveMaker(_withdrawData(), CAP);
        deal(USDC, solver, QUOTE);
        _approveSolverSide(QUOTE, USDC);

        Order memory order = _positionOrder(2);
        bytes memory sig = _sign(order);

        (uint256 delta,,) = lens.previewFill(order, order.fillTotal, solver, "");
        assertEq(delta, _rawPosition(maker), "sized from the live position");
        assertLt(delta, CAP, "below the cap, so a partial fill");

        uint256 makerUsdcBefore = IERC20(USDC).balanceOf(maker);

        vm.prank(solver);
        uint256 paid = settlement.fill(order, sig, delta)[0];

        assertEq(paid, (delta * QUOTE + CAP - 1) / CAP, "paid pro rata (ceilDiv)");
        assertEq(IERC20(USDC).balanceOf(maker) - makerUsdcBefore, paid, "maker received it");
        assertApproxEqAbs(IERC20(WETH).balanceOf(solver), delta, 2, "solver bought the position");
        assertLe(_rawPosition(maker), 2, "position fully exited");
        assertEq(IERC20(WETH).balanceOf(address(operatorModule)), 0, "module drained");
    }

    /// @dev FINDING 2 REGRESSION on this venue: a short `Full` leg must revert
    /// rather than deliver less and let the core bill the maker's wallet.
    function test_fullMode_shortPosition_revertsInsteadOfBillingTheMaker() public {
        _seedEulerCollateral(1 ether);
        uint256 signed = 3 ether;

        bytes memory data = abi.encode(
            uint8(EulerV2OperatorModule.Op.Withdraw),
            address(EWETH),
            DustHandler.encodeMode(DustHandler.BalanceMode.Full),
            signed
        );
        _approveMaker(data, signed);

        vm.prank(address(permit3));
        vm.expectRevert(); // ShortWithdraw, or the vault on insufficient shares
        operatorModule.takeOnBehalf(maker, signed, address(settlement), data);
    }
}
