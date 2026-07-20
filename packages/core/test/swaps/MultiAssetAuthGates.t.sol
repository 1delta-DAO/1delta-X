// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {OrderState} from "@core/settlement/OrderState.sol";
import {Base} from "@core/settlement/Base.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {IERC1271} from "@core/interfaces/IERC1271.sol";
import {IOrderValidator} from "@core/interfaces/IOrderValidator.sol";
import {Order, Item, Validator, LegIn, LegOut, OrderSide} from "@core/settlement/Settlement.sol";
import {Settlement} from "@core/settlement/Settlement.sol";

import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

/// @dev EIP-1271 wallet controlled by one EOA key (validates makerPk sigs).
contract MockMakerWallet is IERC1271 {
    address public immutable owner;

    constructor(address _owner) {
        owner = _owner;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view override returns (bytes4) {
        require(signature.length == 65, "len");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
        if (ecrecover(hash, v, r, s) == owner) return IERC1271.isValidSignature.selector;
        return 0xffffffff;
    }
}

/// @dev Trivial validator: passes iff `data` decodes to `true`. Lets a test
///      flip a gate on/off while keeping the target/data in the signed order.
contract BoolValidator is IOrderValidator {
    function validate(Order calldata, address, bytes calldata data, bytes calldata) external pure override returns (bool) {
        return abi.decode(data, (bool));
    }
}

/// @dev Auth paths (single-signature permit witness, EIP-1271, EIP-7702) and
///      order-level gates (validators, invariants, exclusivity, min-fill,
///      deadline) all exercised over a MULTI-ASSET order, to prove the array
///      generalization didn't regress any dimension — most importantly that the
///      witness typestring still hashes array fields correctly.
contract MultiAssetAuthGatesTest is CoreSettlementBase {
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    BoolValidator val;

    function setUp() public override {
        super.setUp();
        val = new BoolValidator();
        vm.label(DAI, "DAI");
        vm.startPrank(maker);
        IERC20(DAI).approve(address(permit3), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(solver);
        IERC20(DAI).approve(address(permit3), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Multi-out fixed-price order (USDC → {WETH, DAI}) with optional gates.
    function _multiOut(uint256 nonce, Validator[] memory validators, Validator[] memory invariants)
        internal
        view
        returns (Order memory)
    {
        LegOut[] memory legsOut = new LegOut[](2);
        legsOut[0] = LegOut(WETH, 1 ether, 0, address(0));
        legsOut[1] = LegOut(DAI, 1_000e18, 0, address(0));
        return Order({
            maker: maker,
            side: OrderSide.SELL,
            nonce: nonce,
            deadline: block.timestamp + 1 hours,
            legsIn: _legsIn1(USDC, 2_000e6),
            legsOut: legsOut,
            timing: 0,
            exclusiveFiller: address(0),
            minFillAnchor: 0,
            exclusivityOverrideBps: 0,
            curve: _noCurve(),
            gasBumpBps: 0,
            gasPriceRef: 0,
            items: new Item[](0),
            validators: validators,
            invariants: invariants,
            fillModule: address(0),
            fillTotal: 0
        });
    }

    function _fundMultiOut() internal {
        deal(USDC, maker, 2_000e6);
        deal(WETH, solver, 1 ether);
        deal(DAI, solver, 1_000e18);
        _approveMakerToSettlement(USDC, 2_000e6);
        _approveSolverSide(1 ether, WETH);
        _approveSolverSide(1_000e18, DAI);
    }

    function _noV() internal pure returns (Validator[] memory) {
        return new Validator[](0);
    }

    function _oneV(bool pass) internal view returns (Validator[] memory v) {
        v = new Validator[](1);
        v[0] = Validator({target: address(val), data: abi.encode(pass)});
    }

    function _assertBasketDelivered() internal view {
        assertEq(IERC20(WETH).balanceOf(maker), 1 ether, "maker WETH");
        assertEq(IERC20(DAI).balanceOf(maker), 1_000e18, "maker DAI");
        assertEq(IERC20(USDC).balanceOf(solver), 2_000e6, "solver USDC");
    }

    // ──────────────────── single-signature permit witness (arrays) ────────────────────

    /// @dev The critical array-witness case: one maker signature over a Permit3
    ///      PermitBatch witnessed by a MULTI-IN order hash authorizes both input
    ///      pulls. Proves WITNESS_TYPESTRING hashes address[]/uint256[] correctly.
    function test_multiIn_fillWithPermit_witness() public {
        uint256 wethIn = 1 ether;
        uint256 usdcIn = 500e6;
        uint256 daiOut = 1_500e18;

        deal(WETH, maker, wethIn);
        deal(USDC, maker, usdcIn);
        deal(DAI, solver, daiOut);
        _approveSolverSide(daiOut, DAI);

        LegIn[] memory legsIn = new LegIn[](2);
        legsIn[0] = LegIn(WETH, wethIn, 0);
        legsIn[1] = LegIn(USDC, usdcIn, 0);
        Order memory order = Order({
            maker: maker,
            side: OrderSide.SELL,
            nonce: 0,
            deadline: block.timestamp + 1 hours,
            legsIn: legsIn,
            legsOut: _legsOut1(DAI, daiOut),
            timing: 0,
            exclusiveFiller: address(0),
            minFillAnchor: 0,
            exclusivityOverrideBps: 0,
            curve: _noCurve(),
            gasBumpBps: 0,
            gasPriceRef: 0,
            items: new Item[](0),
            validators: _noV(),
            invariants: _noV(),
            fillModule: address(0),
            fillTotal: 0
        });

        // Two token permits — one per input leg — all endorsed by the order witness.
        IPermit3.TokenPermit[] memory tp = new IPermit3.TokenPermit[](2);
        tp[0] = IPermit3.TokenPermit(address(settlement), WETH, uint160(wethIn), uint48(order.deadline));
        tp[1] = IPermit3.TokenPermit(address(settlement), USDC, uint160(usdcIn), uint48(order.deadline));
        IPermit3.PermitBatch memory batch = _buildBatch(tp, _noTakerPermits(), 0, order.deadline);
        bytes memory sig = _signPermitWitness(batch, _hashOrder(order));

        vm.prank(solver);
        uint256[] memory paid = settlement.fillWithPermit(order, batch, sig, wethIn);
        assertEq(paid[0], daiOut, "DAI delivered");
        assertEq(IERC20(WETH).balanceOf(solver), wethIn, "solver got WETH");
        assertEq(IERC20(USDC).balanceOf(solver), usdcIn, "solver got USDC");
        assertEq(IERC20(DAI).balanceOf(maker), daiOut, "maker got DAI");
    }

    function test_multiOut_fillWithPermit_witness() public {
        _fundMultiOut();
        // maker's standing USDC approval isn't set here; the permit authorizes it.
        Order memory order = _multiOut(1, _noV(), _noV());

        IPermit3.TokenPermit[] memory tp = new IPermit3.TokenPermit[](1);
        tp[0] = IPermit3.TokenPermit(address(settlement), USDC, uint160(2_000e6), uint48(order.deadline));
        IPermit3.PermitBatch memory batch = _buildBatch(tp, _noTakerPermits(), 1, order.deadline);
        bytes memory sig = _signPermitWitness(batch, _hashOrder(order));

        vm.prank(solver);
        settlement.fillWithPermit(order, batch, sig, 2_000e6);
        _assertBasketDelivered();
    }

    // ──────────────────── contract / delegated makers ────────────────────

    function test_multiOut_eip1271Maker() public {
        MockMakerWallet wallet = new MockMakerWallet(maker);
        deal(USDC, address(wallet), 2_000e6);
        deal(WETH, solver, 1 ether);
        deal(DAI, solver, 1_000e18);
        vm.startPrank(address(wallet));
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), USDC, uint160(2_000e6), 0);
        vm.stopPrank();
        _approveSolverSide(1 ether, WETH);
        _approveSolverSide(1_000e18, DAI);

        Order memory order = _multiOut(2, _noV(), _noV());
        order.maker = address(wallet);
        bytes memory sig = _sign(order); // makerPk → validated by wallet's 1271

        vm.prank(solver);
        settlement.fill(order, sig, 2_000e6);
        assertEq(IERC20(WETH).balanceOf(address(wallet)), 1 ether, "1271 maker WETH");
        assertEq(IERC20(DAI).balanceOf(address(wallet)), 1_000e18, "1271 maker DAI");
    }

    function test_multiOut_eip7702RawKeyMaker() public {
        vm.etch(maker, bytes.concat(hex"ef0100", abi.encodePacked(address(0xDE1E6A7E))));
        _fundMultiOut();
        Order memory order = _multiOut(3, _noV(), _noV());
        bytes memory sig = _sign(order);

        vm.prank(solver);
        settlement.fill(order, sig, 2_000e6);
        _assertBasketDelivered();
    }

    // ──────────────────── validators (pre-execution) ────────────────────

    function test_multiOut_validatorPass() public {
        _fundMultiOut();
        Order memory order = _multiOut(4, _oneV(true), _noV());
        bytes memory sig = _sign(order);
        vm.prank(solver);
        settlement.fill(order, sig, 2_000e6);
        _assertBasketDelivered();
    }

    function test_multiOut_validatorFail() public {
        _fundMultiOut();
        Order memory order = _multiOut(5, _oneV(false), _noV());
        bytes memory sig = _sign(order);
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.ValidationFailed.selector, uint256(0)));
        settlement.fill(order, sig, 2_000e6);
    }

    // ──────────────────── invariants (post-execution) ────────────────────

    function test_multiOut_invariantPass() public {
        _fundMultiOut();
        Order memory order = _multiOut(6, _noV(), _oneV(true));
        bytes memory sig = _sign(order);
        vm.prank(solver);
        settlement.fill(order, sig, 2_000e6);
        _assertBasketDelivered();
    }

    function test_multiOut_invariantFail() public {
        _fundMultiOut();
        Order memory order = _multiOut(7, _noV(), _oneV(false));
        bytes memory sig = _sign(order);
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.InvariantFailed.selector, uint256(0)));
        settlement.fill(order, sig, 2_000e6);
    }

    // ──────────────────── exclusivity window ────────────────────

    function test_multiOut_exclusivity() public {
        _fundMultiOut();
        Order memory order = _multiOut(8, _noV(), _noV());
        order.exclusiveFiller = address(0xE);
        _setExclusivityEnd(order, uint32(block.timestamp + 100));
        bytes memory sig = _sign(order);

        // Non-exclusive solver blocked during the window.
        vm.prank(solver);
        vm.expectRevert(Base.NotExclusiveFiller.selector);
        settlement.fill(order, sig, 2_000e6);

        // After the window, anyone can fill.
        vm.warp(block.timestamp + 200);
        vm.prank(solver);
        settlement.fill(order, sig, 2_000e6);
        _assertBasketDelivered();
    }

    // ──────────────────── min-fill floor ────────────────────

    function test_multiOut_minFill() public {
        _fundMultiOut();
        Order memory order = _multiOut(9, _noV(), _noV());
        order.minFillAnchor = 2_000e6; // all-or-nothing
        bytes memory sig = _sign(order);
        vm.prank(solver);
        vm.expectRevert(OrderState.FillTooSmall.selector);
        settlement.fill(order, sig, 1_000e6);
    }

    // ──────────────────── deadline ────────────────────

    function test_multiOut_expired() public {
        _fundMultiOut();
        Order memory order = _multiOut(10, _noV(), _noV());
        bytes memory sig = _sign(order);
        vm.warp(order.deadline + 1);
        vm.prank(solver);
        vm.expectRevert(Base.OrderExpired.selector);
        settlement.fill(order, sig, 2_000e6);
    }
}
