// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";

import {Order, ItemOp, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";

import {LzOftBridgeOutModule} from "../src/out/LzOftBridgeOutModule.sol";

import {BridgeTestBase} from "./shared/BridgeTestBase.t.sol";

/// @title NettedLzOftSettleTest
/// @notice {LzOftBridgeOutModule.settle} on the NETTED path. Since task 31
///         `matchSettle` admits SETTLE items, so a SPONSORED LayerZero send (the one
///         shape that must ride SETTLE, because it binds the filler) can now be
///         CoW-matched. The question for this module is only whether the filler it
///         binds is still the party that owes the fill: on this path `ctx.filler` is
///         `matchSettle`'s `msg.sender` — the solver that runs the plan — so the
///         sponsor binding means the same thing it means on `fill`.
///
///         Funding is unchanged too: the bridged tokens are PULLED from the maker
///         under its own Permit3 grant (never from the module's resident balance),
///         with a pre-pull floor, so another order's in-flight value cannot be sent.
contract NettedLzOftSettleTest is BridgeTestBase {
    uint256 carolPk = 0xCA201;
    address carol = vm.addr(carolPk);

    uint256 constant PAY = 500e18; //    tC the maker pays
    uint256 constant BRIDGE = 100e18; // tA delivered to the maker, then bridged

    function _sponsoredSpec(bytes32 dstHash) internal view returns (bytes memory) {
        return abi.encode(
            LzOftBridgeOutModule.LzSpec({
                oft: address(oft),
                inputToken: address(tA),
                dstEid: 30_101,
                dstChainId: DST_CHAIN,
                dstRecipient: address(inbox),
                maxSlippageBps: 50,
                maxNativeFee: 0.05 ether,
                feePayer: solver, // the sponsor
                extraOptions: "",
                dstOrderHash: dstHash,
                beneficiary: beneficiary,
                commitmentExpiry: uint32(block.timestamp) + COMMITMENT_EXPIRY_OFFSET,
                totalAmount: BRIDGE
            })
        );
    }

    /// @dev The sponsor (`solver`) tops up and sponsors the maker; the maker pays tC
    ///      and lets the module pull the delivered tA; Carol sells exactly that tA
    ///      for the maker's tC — the CoW side, so nobody fronts inventory.
    function _wire() internal {
        vm.deal(solver, 1 ether);
        vm.startPrank(solver);
        lzOut.topUpFor{value: 0.5 ether}(solver);
        lzOut.approveFeeSponsorship(maker, 0.2 ether, 0.05 ether);
        vm.stopPrank();

        tC.mint(maker, PAY);
        _makerApprove(address(settlement), address(tC), type(uint160).max);
        _makerApprove(address(lzOut), address(tA), type(uint160).max);

        tA.mint(carol, BRIDGE);
        vm.startPrank(carol);
        MockERC20(address(tA)).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(tA), type(uint160).max, 0);
        vm.stopPrank();
    }

    function _step(uint256 kind, uint256 a, uint256 b) internal pure returns (uint256) {
        return MatchStep.pack(kind, a, b);
    }

    /// @dev [source (sponsored SETTLE send), Carol]. PULL both, DELIVER the tA to the
    ///      maker, run the send, pay Carol.
    function _plan() internal view returns (MatchPlan memory p) {
        Order memory src =
            _srcOrderOp(1, PAY, BRIDGE, address(lzOut), _sponsoredSpec(keccak256("d")), ItemOp.SETTLE);
        Order memory c = _blank(1);
        c.maker = carol;
        c.legsIn = PackedEncode.oneLegIn(address(tA), BRIDGE, 0);
        c.legsOut = PackedEncode.oneLegOut(address(tC), PAY, 0, address(0));

        Order[] memory orders = new Order[](2);
        orders[0] = src;
        orders[1] = c;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(src);
        sigs[1] = _signWith(c, carolPk);
        uint256[] memory fills = new uint256[](2);
        fills[0] = PAY;
        fills[1] = BRIDGE;
        uint256[] memory s = new uint256[](5);
        s[0] = _step(MatchStep.PULL, 0, 0);
        s[1] = _step(MatchStep.PULL, 1, 0);
        s[2] = _step(MatchStep.DELIVER, 0, 0);
        s[3] = _step(MatchStep.ITEM, 0, 0);
        s[4] = _step(MatchStep.DELIVER, 1, 0);
        p = MatchPlan({
            orders: orders,
            sigs: sigs,
            fillAmounts: fills,
            takerDatas: new bytes[](0),
            schedule: s,
            callTargets: new address[](0),
            callDatas: new bytes[](0),
            profitRecipient: address(0)
        });
    }

    /// The sponsor runs the plan itself: the send goes out, the sponsor pays exactly
    /// one message, and the solver fronts nothing.
    function test_netted_sponsoredSend_bySponsor_settlesZeroCapital() public onSourceChain {
        _wire();
        MatchPlan memory p = _plan();

        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(oft.sentCount(), 1, "one LayerZero send");
        assertEq(lzOut.feeAllowance(solver, maker), 0.19 ether, "sponsor charged exactly one message");
        assertEq(tC.balanceOf(carol), PAY, "carol paid by the maker");
        assertEq(tA.balanceOf(maker), 0, "the delivered tA was bridged out");
        assertEq(tA.balanceOf(address(lzOut)), 0, "nothing stranded on the module");
        assertEq(tA.balanceOf(solver) + tC.balanceOf(solver), 0, "zero solver capital");
    }

    /// Anyone may call `matchSettle`, and on this path the SETTLE item's filler is
    /// that caller — so a stranger running the same plan is a stranger to the
    /// sponsorship, exactly as on `fill`, and the sponsor is charged nothing.
    function test_netted_sponsoredSend_byStranger_reverts() public onSourceChain {
        _wire();
        MatchPlan memory p = _plan();
        address stranger = makeAddr("stranger");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(LzOftBridgeOutModule.FillerNotSponsor.selector, stranger));
        settlement.matchSettle(p);
        assertEq(lzOut.feeAllowance(solver, maker), 0.2 ether, "sponsor allowance untouched");
        assertEq(lzOut.nativeCredit(solver), 0.5 ether, "sponsor credit untouched");
    }
}
