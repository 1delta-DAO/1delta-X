// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Order, CallbackMode, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";
import {SafeTransferLib} from "@core/utils/SafeTransferLib.sol";
import {NativeBalance} from "@periphery/NativeBalance.sol";

import {MockSettlementBase} from "@coretest/shared/MockSettlementBase.t.sol";

/// @dev A filler that delivers a DIRECT order's native leg out of band: inside its
///      callback it sends `amount` of its own native coin to `to`.
contract NativeDeliverer {
    address public immutable EXECUTOR;

    constructor(address executor) {
        EXECUTOR = executor;
    }

    receive() external payable {}

    function pay(address to, uint256 amount) external {
        require(msg.sender == EXECUTOR, "only executor");
        (bool ok,) = to.call{value: amount}("");
        require(ok, "send");
    }
}

/// @title NativeBalanceTest
/// @notice {NativeBalance} against the REAL Settlement + Permit3: it is a sound output
///         token only on the DIRECT (delta-verify) path, and every other path that
///         would move it fails closed because it has no transfer function at all.
contract NativeBalanceTest is MockSettlementBase {
    NativeBalance nb;
    uint256 constant IN = 100e18;
    uint256 constant OUT = 1 ether;

    function setUp() public override {
        super.setUp();
        nb = new NativeBalance();
        tA.mint(maker, 1_000e18);
        _makerApprove(address(settlement), address(tA), type(uint160).max);
    }

    function _nativeOut(uint256 nonce, bool direct, address filler) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(nb), IN, OUT);
        if (direct) {
            o.timing |= uint256(1) << 104;
            o.exclusiveFiller = filler;
        }
    }

    function test_views() public {
        vm.deal(address(0xA), 7);
        assertEq(nb.balanceOf(address(0xA)), 7);
        assertEq(nb.balanceOf(address(0xB)), 0);
        assertEq(nb.decimals(), 18);
    }

    /// No function that could move value exists, and there is no fallback / receive.
    function test_noTransferSurface() public {
        bytes[] memory calls = new bytes[](5);
        calls[0] = abi.encodeWithSignature("transfer(address,uint256)", address(1), 1);
        calls[1] = abi.encodeWithSignature("transferFrom(address,address,uint256)", address(this), address(1), 1);
        calls[2] = abi.encodeWithSignature("approve(address,uint256)", address(1), 1);
        calls[3] = abi.encodeWithSignature("allowance(address,address)", address(this), address(1));
        calls[4] = abi.encodeWithSignature("totalSupply()");
        for (uint256 i; i < calls.length; i++) {
            (bool ok,) = address(nb).call(calls[i]);
            assertFalse(ok, "no such function");
        }
        vm.deal(address(this), 1);
        (bool sent,) = address(nb).call{value: 1}("");
        assertFalse(sent, "cannot receive native");
    }

    /// THE ONE SOUND USE: a DIRECT order's output leg. The filler sends native in its
    /// callback; the core measures `balanceOf` = the maker's native balance.
    function test_directOutputLeg_fills() public {
        NativeDeliverer d = new NativeDeliverer(address(settlement.EXECUTOR()));
        vm.deal(address(d), OUT);
        Order memory o = _nativeOut(1, true, address(d));
        bytes memory sig = _sign(o);
        vm.prank(address(d));
        settlement.fillWithCallback(
            o, sig, IN, address(d), abi.encodeCall(NativeDeliverer.pay, (maker, OUT)), CallbackMode.PostInputs
        );
        assertEq(maker.balance, OUT, "raw native delivered and verified");
        assertEq(tA.balanceOf(address(d)), IN, "filler paid in tA");
    }

    /// Short delivery fails the core's delta check.
    function test_directOutputLeg_shortDeliveryReverts() public {
        NativeDeliverer d = new NativeDeliverer(address(settlement.EXECUTOR()));
        vm.deal(address(d), OUT);
        Order memory o = _nativeOut(2, true, address(d));
        bytes memory sig = _sign(o);
        vm.prank(address(d));
        vm.expectRevert(Base.DeltaTooLow.selector);
        settlement.fillWithCallback(
            o, sig, IN, address(d), abi.encodeCall(NativeDeliverer.pay, (maker, OUT - 1)), CallbackMode.PostInputs
        );
    }

    /// A PULL output leg: the core pulls the leg from the filler with `transferFrom`
    /// on the view — which does not exist — so the fill reverts, even for a filler
    /// that holds native and approved everything it could.
    function test_pullOutputLeg_reverts() public {
        address filler = address(0xF111);
        vm.deal(filler, 10 ether);
        Order memory o = _nativeOut(3, false, address(0));
        bytes memory sig = _sign(o);
        vm.prank(filler);
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        settlement.fill(o, sig, IN);
        assertEq(maker.balance, 0);
    }

    /// An INPUT leg: the maker's pull is the same non-existent `transferFrom`.
    function test_inputLeg_reverts() public {
        vm.deal(maker, 10 ether);
        Order memory o = _plainOrder(4, address(nb), address(tB), OUT, 1e18);
        bytes memory sig = _sign(o);
        tB.mint(address(this), 1e18);
        tB.approve(address(settlement), type(uint256).max);
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        settlement.fill(o, sig, OUT);
        assertEq(maker.balance, 10 ether, "the maker's native cannot be 'paid'");
    }

    /// A DIRECT order naming it as BOTH input and output is refused by the shape gate
    /// (`DeltaVerifySameToken`) before anything moves.
    function test_directSameToken_reverts() public {
        NativeDeliverer d = new NativeDeliverer(address(settlement.EXECUTOR()));
        Order memory o = _plainOrder(5, address(nb), address(nb), OUT, OUT);
        o.timing |= uint256(1) << 104;
        o.exclusiveFiller = address(d);
        bytes memory sig = _sign(o);
        vm.prank(address(d));
        vm.expectRevert(Base.DeltaVerifySameToken.selector);
        settlement.fillWithCallback(o, sig, OUT, address(d), "", CallbackMode.PostInputs);
    }

    /// `matchSettle` refuses a delta-verify order at open, and a pull-shaped one cannot
    /// be delivered from the pool (no `transfer`).
    function test_matchSettle_refuses() public {
        Order memory o = _nativeOut(6, true, address(this));
        MatchPlan memory p = _onePlan(o);
        vm.expectRevert(Base.DeltaVerifyNotBatchable.selector);
        settlement.matchSettle(p);

        o = _nativeOut(7, false, address(0));
        p = _onePlan(o);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        settlement.matchSettle(p);
    }

    function _onePlan(Order memory o) internal view returns (MatchPlan memory p) {
        p.orders = new Order[](1);
        p.orders[0] = o;
        p.sigs = new bytes[](1);
        p.sigs[0] = _sign(o);
        p.fillAmounts = new uint256[](1);
        p.fillAmounts[0] = IN;
        p.schedule = new uint256[](2);
        p.schedule[0] = MatchStep.pack(MatchStep.PULL, 0, 0);
        p.schedule[1] = MatchStep.pack(MatchStep.DELIVER, 0, 0);
        p.profitRecipient = address(this);
    }
}
