// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {MockSettlementBase, MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";
import {Order, Item, ItemOp, LegIn, LegOut, OrderSide} from "@core/settlement/Settlement.sol";

import {BridgedOrderInbox} from "../../src/BridgedOrderInbox.sol";
import {CommitmentCodec} from "../../src/CommitmentCodec.sol";
import {AcrossBridgeOutModule} from "../../src/out/AcrossBridgeOutModule.sol";
import {LzOftBridgeOutModule} from "../../src/out/LzOftBridgeOutModule.sol";

import {MockSpokePool, MockLzEndpoint, MockOFT} from "./Mocks.t.sol";

/// @title BridgeTestBase
/// @notice Shared harness for the cross-chain package. Both "chains" live in one
///         EVM: the mock bridges take custody on the source side and deliver to
///         the destination inbox on demand, which reproduces the sequencing the
///         real bridges provide — atomic for Across, split across two
///         transactions for LayerZero — without needing two forks.
///
///         `tA` is the bridged token (it crosses and funds the destination
///         order), `tB` is what the solver delivers to the end user on the
///         destination, `tC` is what the maker pays on the source.
abstract contract BridgeTestBase is MockSettlementBase {
    BridgedOrderInbox inbox;
    MockSpokePool spokePool;
    MockLzEndpoint lzEndpoint;
    MockOFT oft;
    AcrossBridgeOutModule acrossOut;
    LzOftBridgeOutModule lzOut;

    address endUser = address(0xE9D0);
    address beneficiary = address(0xBE9E);
    address inboxOwner = address(0x0E0E);

    uint32 constant COMMITMENT_EXPIRY_OFFSET = 3 days;

    /// @dev The harness runs both legs in one EVM but under DIFFERENT chain ids, so
    ///      chain binding is genuinely exercised rather than assumed away. The
    ///      destination is the ambient chain (every fixture and assertion runs
    ///      there); {_onSourceChain} switches to the source only for the moments a
    ///      source order is signed and filled.
    ///
    ///      This matters beyond the out-modules' `dstChainId != block.chainid`
    ///      guard: with one chain id, a source order and a destination order would
    ///      share a domain separator, and every signature would verify on both
    ///      legs — hiding exactly the class of bug we care about.
    uint64 constant SRC_CHAIN = 1;
    uint64 constant DST_CHAIN = 31_337; // foundry's default; the ambient chain here

    modifier onSourceChain() {
        vm.chainId(SRC_CHAIN);
        _;
        vm.chainId(DST_CHAIN);
    }

    function setUp() public virtual override {
        super.setUp();
        vm.chainId(DST_CHAIN);

        spokePool = new MockSpokePool();
        lzEndpoint = new MockLzEndpoint();
        oft = new MockOFT(address(tA), 0.01 ether, lzEndpoint);

        inbox = new BridgedOrderInbox(
            address(permit3), address(settlement), address(spokePool), address(lzEndpoint), inboxOwner
        );
        acrossOut = new AcrossBridgeOutModule(address(permit3), address(settlement), address(spokePool));
        lzOut = new LzOftBridgeOutModule(address(permit3), address(settlement));

        vm.startPrank(inboxOwner);
        inbox.enableToken(address(tA));
        inbox.setComposeSource(address(oft), address(tA));
        vm.stopPrank();

        vm.label(address(inbox), "inbox");
        vm.label(address(spokePool), "spokePool");
        vm.label(address(oft), "oft");
        vm.label(endUser, "endUser");
        vm.label(beneficiary, "beneficiary");
    }

    // ──────────────────── Destination side ────────────────────

    /// @dev A destination order in the shape the inbox accepts: SELL, one input
    ///      leg funded by the bridge, one output leg addressed to the end user.
    ///      The inbox is the maker, so the user signs nothing on this chain.
    function _dstOrder(uint256 nonce, uint256 amountIn, uint256 amountOut) internal view returns (Order memory o) {
        o = _blank(nonce);
        o.maker = address(inbox);
        o.legsIn = _legsIn1(address(tA), amountIn);
        LegOut[] memory _tmplegsOut = new LegOut[](1);
        _tmplegsOut[0] = LegOut(address(tB), amountOut, 0, endUser);
        o.legsOut = PackedEncode.legsOut(_tmplegsOut);
    }

    function _commitmentFor(bytes32 orderHash) internal view returns (bytes memory) {
        return _commitmentFor(orderHash, DST_CHAIN);
    }

    function _commitmentFor(bytes32 orderHash, uint64 chainId) internal view returns (bytes memory) {
        return CommitmentCodec.encode(
            CommitmentCodec.Commitment({
                orderHash: orderHash,
                beneficiary: beneficiary,
                dstChainId: chainId,
                expiry: uint32(block.timestamp) + COMMITMENT_EXPIRY_OFFSET
            })
        );
    }

    /// @dev Deliver `amount` of the bridged token to the inbox with `message`,
    ///      exactly as an Across relayer would.
    function _acrossDeliver(uint256 amount, bytes memory message) internal {
        tA.mint(address(inbox), amount);
        vm.prank(address(spokePool));
        inbox.handleV3AcrossMessage(address(tA), amount, address(spokePool), message);
    }

    /// @dev Fund the solver so it can deliver a destination order's output leg.
    function _fundSolverOut(uint256 amount) internal {
        tB.mint(solver, amount);
        vm.startPrank(solver);
        tB.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(tB), type(uint160).max, 0);
        vm.stopPrank();
    }

    // ──────────────────── Source side ────────────────────

    /// @dev The source order: the maker pays `tC`, the solver delivers the
    ///      bridgeable `tA` to the maker, and the item immediately pulls it back
    ///      and bridges it. Items run AFTER outputs are delivered, which is what
    ///      makes this a plain order plus one item rather than a special flow.
    function _srcOrder(uint256 nonce, uint256 payAmount, uint256 bridgeAmount, address module, bytes memory spec)
        internal
        view
        returns (Order memory o)
    {
        o = _blank(nonce);
        o.legsIn = _legsIn1(address(tC), payAmount);
        o.legsOut = _legsOut1(address(tA), bridgeAmount); // recipient 0 == the maker
        Item[] memory _tmpitems = new Item[](1);
        _tmpitems[0] = Item({op: ItemOp.MAKE, module: module, amount: bridgeAmount, recipient: address(0), data: spec});
        o.items = PackedEncode.items(_tmpitems);
    }

    /// @dev Sign a source order under the SOURCE chain id. The signature is
    ///      domain-bound, so it is only valid for fills that also run there.
    function _signSource(Order memory o) internal onSourceChain returns (bytes memory sig) {
        sig = _sign(o);
    }

    /// @dev Fill a source order under the SOURCE chain id.
    function _fillSourceAs(Order memory o, bytes memory sig, uint256 amount) internal onSourceChain {
        vm.prank(solver);
        settlement.fill(o, sig, amount);
    }

    /// @dev Maker pays `tC` and lets the bridge module pull the delivered `tA`;
    ///      solver delivers `tA` and receives `tC`.
    function _wireSourceParties(address module, uint256 payAmount, uint256 bridgeAmount) internal {
        tC.mint(maker, payAmount);
        _makerApprove(address(settlement), address(tC), type(uint160).max);
        _makerApprove(module, address(tA), type(uint160).max);

        tA.mint(solver, bridgeAmount);
        _solverApprove(address(settlement), address(tA), type(uint160).max);
    }
}
