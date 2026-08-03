// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order, Item, ItemOp, LegOut} from "@core/settlement/Settlement.sol";

import {AcrossBridgeOutModule} from "../src/out/AcrossBridgeOutModule.sol";
import {BridgedOrderInbox} from "../src/BridgedOrderInbox.sol";
import {BridgeOutBase} from "../src/out/BridgeOutBase.sol";
import {MockSpokePool} from "./shared/Mocks.t.sol";
import {BridgeTestBase} from "./shared/BridgeTestBase.t.sol";

/// @title AcrossPathTest
/// @notice The whole sequential cross-chain flow over Across, both legs, in one
///         EVM: the maker's source order settles and bridges, the relayer
///         delivers, the destination order activates, and a solver fills it to
///         the end user.
contract AcrossPathTest is BridgeTestBase {
    uint256 constant PAY = 500e18; // tC the maker pays on the source chain
    uint256 constant BRIDGE = 100e18; // tA the solver delivers, then gets bridged
    uint16 constant RELAY_FEE_BPS = 100; // 1%
    uint256 constant DELIVERED = BRIDGE - (BRIDGE * RELAY_FEE_BPS) / 10_000;
    uint256 constant DST_OUT = 300e18; // tB the end user receives

    function _spec(bytes32 dstOrderHash) internal view returns (bytes memory) {
        return abi.encode(
            AcrossBridgeOutModule.AcrossSpec({
                inputToken: address(tA),
                outputToken: address(tA),
                dstChainId: DST_CHAIN,
                dstRecipient: address(inbox),
                exclusiveRelayer: address(0),
                maxRelayFeeBps: RELAY_FEE_BPS,
                fillDeadlineOffset: 2 hours,
                exclusivityOffset: 0,
                dstOrderHash: dstOrderHash,
                beneficiary: beneficiary,
                commitmentExpiry: uint32(block.timestamp) + COMMITMENT_EXPIRY_OFFSET
            })
        );
    }

    /// @dev Settle the source order, which bridges as its item.
    function _fillSource(bytes32 dstOrderHash) internal onSourceChain {
        Order memory src = _srcOrder(1, PAY, BRIDGE, address(acrossOut), _spec(dstOrderHash));
        _wireSourceParties(address(acrossOut), PAY, BRIDGE);
        bytes memory sig = _sign(src);
        vm.prank(solver);
        settlement.fill(src, sig, PAY);
    }

    // ──────────────────── End to end ────────────────────

    function test_endToEnd_sourceBridges_destinationFillsToEndUser() public {
        Order memory dst = _dstOrder(1, DELIVERED, DST_OUT);
        bytes32 dstHash = _hashOrder(dst);

        _fillSource(dstHash);

        // Source leg settled exactly like any other order.
        assertEq(tC.balanceOf(solver), PAY, "solver was paid the maker's input");
        assertEq(tA.balanceOf(maker), 0, "the delivered token went straight to the bridge");

        MockSpokePool.Deposit memory d = spokePool.depositAt(0);
        assertEq(d.depositor, maker, "refunds return to the maker, not the module");
        assertEq(d.recipient, address(inbox), "addressed to the destination inbox");
        assertEq(d.inputAmount, BRIDGE, "full delivered amount bridged");
        assertEq(d.outputAmount, DELIVERED, "guaranteed floor after the signed fee bound");
        assertEq(d.message, _commitmentFor(dstHash), "commitment names the destination order");

        // Relayer delivers on the destination — tokens and message together.
        spokePool.relay(0);
        assertEq(inbox.missingFunding(dstHash, DELIVERED), 0, "fully funded");

        inbox.activate(dst);
        _fundSolverOut(DST_OUT);
        vm.prank(solver);
        settlement.fill(dst, "", DELIVERED);

        assertEq(tB.balanceOf(endUser), DST_OUT, "end user received the destination output");
        assertEq(tA.balanceOf(address(inbox)), 0, "escrow emptied");
    }

    /// @dev The destination order's input leg MUST be authored against the
    ///      bridge's guaranteed floor. Authoring it against the pre-fee amount
    ///      leaves the order permanently unactivatable — fail-safe, and the funds
    ///      come back through {settle}.
    function test_destinationAuthoredAboveFloor_neverActivates_butRefunds() public {
        Order memory dst = _dstOrder(1, BRIDGE, DST_OUT); // ignores the relay fee
        bytes32 dstHash = _hashOrder(dst);

        _fillSource(dstHash);
        spokePool.relay(0);

        vm.expectRevert(BridgedOrderInbox.Underfunded.selector);
        inbox.activate(dst);

        vm.warp(block.timestamp + COMMITMENT_EXPIRY_OFFSET + 1);
        inbox.settle(dstHash);
        assertEq(tA.balanceOf(beneficiary), DELIVERED, "user made whole on the destination");
    }

    /// @dev Reverting in the Across handler is the SAFE posture: the relayer's
    ///      fill unwinds, so they never take the deposit, and it refunds on the
    ///      origin chain. Nothing is stranded on the destination.
    function test_badMessage_relayReverts_nothingStranded() public {
        Order memory dst = _dstOrder(1, DELIVERED, DST_OUT);
        _fillSource(_hashOrder(dst));

        vm.expectRevert(BridgedOrderInbox.BadCommitment.selector);
        spokePool.relayWith(0, hex"c0ffee");
        assertEq(inbox.liability(address(tA)), 0, "nothing credited");
    }

    /// @dev A message naming a different chain is rejected the same way.
    function test_wrongChainCommitment_relayReverts() public {
        Order memory dst = _dstOrder(1, DELIVERED, DST_OUT);
        bytes32 dstHash = _hashOrder(dst);
        _fillSource(dstHash);

        vm.expectRevert(BridgedOrderInbox.WrongChain.selector);
        spokePool.relayWith(0, _commitmentFor(dstHash, uint64(block.chainid) + 1));
    }

    // ──────────────────── Source-module guards ────────────────────

    function test_module_onlySettlement() public {
        vm.prank(solver);
        vm.expectRevert(BridgeOutBase.OnlySettlement.selector);
        acrossOut.makeOnBehalf(maker, BRIDGE, _spec(bytes32(uint256(1))));
    }

    /// @dev A mis-encoded fee bound cannot quietly hand the transfer to relayers.
    function test_module_rejectsAbsurdFeeBound() public onSourceChain {
        Order memory dst = _dstOrder(1, DELIVERED, DST_OUT);
        bytes memory spec = abi.encode(
            AcrossBridgeOutModule.AcrossSpec({
                inputToken: address(tA),
                outputToken: address(tA),
                dstChainId: DST_CHAIN,
                dstRecipient: address(inbox),
                exclusiveRelayer: address(0),
                maxRelayFeeBps: 5_000, // 50%
                fillDeadlineOffset: 2 hours,
                exclusivityOffset: 0,
                dstOrderHash: _hashOrder(dst),
                beneficiary: beneficiary,
                commitmentExpiry: uint32(block.timestamp) + COMMITMENT_EXPIRY_OFFSET
            })
        );
        Order memory src = _srcOrder(1, PAY, BRIDGE, address(acrossOut), spec);
        _wireSourceParties(address(acrossOut), PAY, BRIDGE);
        bytes memory sig = _sign(src);

        vm.prank(solver);
        vm.expectRevert(BridgeOutBase.DeductionTooHigh.selector);
        settlement.fill(src, sig, PAY);
    }

    /// @dev Partial source fills bridge in slices against one destination hash.
    ///      Each slice rounds its fee deduction DOWN, so the slices sum to at
    ///      least the whole-order floor and the destination still activates.
    function test_partialSourceFills_accumulateToTheFloor() public {
        Order memory dst = _dstOrder(1, DELIVERED, DST_OUT);
        bytes32 dstHash = _hashOrder(dst);

        Order memory src = _srcOrder(1, PAY, BRIDGE, address(acrossOut), _spec(dstHash));
        _wireSourceParties(address(acrossOut), PAY, BRIDGE);
        bytes memory sig = _signSource(src);

        _fillSourceAs(src, sig, PAY / 2);
        _fillSourceAs(src, sig, PAY / 2);

        spokePool.relay(0);
        spokePool.relay(1);

        assertEq(inbox.missingFunding(dstHash, DELIVERED), 0, "two slices covered the floor");
        inbox.activate(dst);

        _fundSolverOut(DST_OUT);
        vm.prank(solver);
        settlement.fill(dst, "", DELIVERED);
        assertEq(tB.balanceOf(endUser), DST_OUT, "end user paid out");
    }
}
