// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order, Item} from "@core/settlement/Settlement.sol";

import {AcrossBridgeOutModule} from "../src/out/AcrossBridgeOutModule.sol";
import {CctpBridgeOutModule} from "../src/out/CctpBridgeOutModule.sol";
import {BridgeOutBase} from "../src/out/BridgeOutBase.sol";
import {MockSpokePool, MockTokenMessenger} from "./shared/Mocks.t.sol";
import {BridgeTestBase} from "./shared/BridgeTestBase.t.sol";

/// @dev Two things a decimal-stable route never exercises:
///
///      1. **Cross-chain decimal conversion.** The destination floor a bridge
///         enforces is in the DESTINATION token's decimals; `amount` arrives in the
///         source token's. Where they differ — USDT 6/18, WBTC 8/18 — an
///         unconverted figure does not revert, it is wrong by a power of ten. These
///         tests pin the conversion in both directions and its bounds.
///      2. **CCTP**, whose burn-and-mint shape has no fee, no counterparty and no
///         message — so it delivers exactly `amount`, and cannot carry a
///         commitment at all.
contract DecimalScalingAndCctpTest is BridgeTestBase {
    uint256 constant PAY = 500e18;
    uint256 constant BRIDGE = 100e18;
    uint16 constant RELAY_FEE_BPS = 100; // 1%

    CctpBridgeOutModule cctpOut;
    MockTokenMessenger messenger;

    uint32 constant DST_DOMAIN = 3; // Circle's domain id — deliberately != DST_CHAIN

    /// @dev Stands in for the user's {PositionFunnel} on the destination. The
    ///      module cannot verify that the recipient IS a funnel — nothing on this
    ///      chain can — so funnel-only is an authoring rule, not a check. What the
    ///      module does enforce is the shared destination sanity guard.
    address dstFunnel = address(0xF0AAE1);

    function setUp() public override {
        super.setUp();
        messenger = new MockTokenMessenger();
        cctpOut = new CctpBridgeOutModule(address(permit3), address(settlement), address(messenger));
        vm.label(address(cctpOut), "cctpOut");
        vm.label(address(messenger), "tokenMessenger");
    }

    // ──────────────────── Across: decimal scaling ────────────────────

    function _acrossSpec(int8 scaling) internal view returns (bytes memory) {
        return abi.encode(
            AcrossBridgeOutModule.AcrossSpec({
                inputToken: address(tA),
                outputToken: address(tA),
                dstChainId: DST_CHAIN,
                dstRecipient: address(inbox),
                exclusiveRelayer: address(0),
                maxRelayFeeBps: RELAY_FEE_BPS,
                dstScalingFactor: scaling,
                fillDeadlineOffset: 2 hours,
                exclusivityOffset: 0,
                dstOrderHash: bytes32(uint256(1)),
                beneficiary: beneficiary,
                commitmentExpiry: uint32(block.timestamp) + COMMITMENT_EXPIRY_OFFSET
            })
        );
    }

    function _bridgeAcross(int8 scaling) internal onSourceChain {
        Order memory src = _srcOrder(1, PAY, BRIDGE, address(acrossOut), _acrossSpec(scaling));
        _wireSourceParties(address(acrossOut), PAY, BRIDGE);
        bytes memory sig = _sign(src);
        vm.prank(solver);
        settlement.fill(src, sig, PAY);
    }

    /// The pre-existing behaviour: a decimal-stable route is untouched.
    function test_scaling_zero_isIdentity() public {
        _bridgeAcross(0);
        MockSpokePool.Deposit memory d = spokePool.depositAt(0);
        assertEq(d.inputAmount, BRIDGE, "burns the source amount");
        assertEq(d.outputAmount, BRIDGE - (BRIDGE * RELAY_FEE_BPS) / 10_000, "floor unchanged");
    }

    /// Destination is FINER (e.g. 6 → 18): the floor must scale UP, or the relayer
    /// delivers 10^12 times too little and the destination order can never fund.
    function test_scaling_destHasMoreDecimals_multipliesTheFloor() public {
        _bridgeAcross(12);
        MockSpokePool.Deposit memory d = spokePool.depositAt(0);
        uint256 srcFloor = BRIDGE - (BRIDGE * RELAY_FEE_BPS) / 10_000;
        assertEq(d.inputAmount, BRIDGE, "source amount is NOT scaled");
        assertEq(d.outputAmount, srcFloor * 1e12, "floor converted up");
    }

    /// Destination is COARSER (18 → 6): the floor scales DOWN, and rounds down —
    /// rounding up would demand more value than the source is worth and leave the
    /// deposit unfillable.
    function test_scaling_destHasFewerDecimals_dividesAndRoundsDown() public {
        _bridgeAcross(-12);
        MockSpokePool.Deposit memory d = spokePool.depositAt(0);
        uint256 srcFloor = BRIDGE - (BRIDGE * RELAY_FEE_BPS) / 10_000;
        assertEq(d.outputAmount, srcFloor / 1e12, "floor converted down");
        assertLe(d.outputAmount * 1e12, srcFloor, "never rounds up past the source value");
    }

    /// The fee bound applies in SOURCE units and the conversion happens after, so
    /// the two operations cannot round into each other.
    function test_scaling_feeBoundAppliesBeforeConversion() public {
        _bridgeAcross(6);
        MockSpokePool.Deposit memory d = spokePool.depositAt(0);
        assertEq(d.outputAmount, ((BRIDGE - (BRIDGE * RELAY_FEE_BPS) / 10_000)) * 1e6, "fee first, then scale");
    }

    /// @dev `expectRevert` has to sit immediately before the FILL, not before the
    ///      helper: the helper makes external calls of its own (signing reads
    ///      `DOMAIN_SEPARATOR`), and the cheatcode would be spent on the first of
    ///      them. Hence a separate reverting variant rather than reusing
    ///      {_bridgeAcross}.
    function _bridgeAcrossExpectingRevert(int8 scaling, bytes4 selector) internal onSourceChain {
        Order memory src = _srcOrder(1, PAY, BRIDGE, address(acrossOut), _acrossSpec(scaling));
        _wireSourceParties(address(acrossOut), PAY, BRIDGE);
        bytes memory sig = _sign(src);
        vm.prank(solver);
        vm.expectRevert(selector);
        settlement.fill(src, sig, PAY);
    }

    function test_scaling_outOfRange_reverts() public {
        _bridgeAcrossExpectingRevert(19, BridgeOutBase.ScalingFactorOutOfRange.selector);
    }

    function test_scaling_outOfRangeNegative_reverts() public {
        _bridgeAcrossExpectingRevert(-19, BridgeOutBase.ScalingFactorOutOfRange.selector);
    }

    // ──────────────────── CCTP ────────────────────

    function _cctpSpec(address recipient) internal view returns (bytes memory) {
        return abi.encode(
            CctpBridgeOutModule.CctpSpec({
                inputToken: address(tA),
                dstChainId: DST_CHAIN,
                dstDomain: DST_DOMAIN,
                dstRecipient: recipient
            })
        );
    }

    function _bridgeCctp(address recipient) internal onSourceChain {
        Order memory src = _srcOrder(2, PAY, BRIDGE, address(cctpOut), _cctpSpec(recipient));
        _wireSourceParties(address(cctpOut), PAY, BRIDGE);
        bytes memory sig = _sign(src);
        vm.prank(solver);
        settlement.fill(src, sig, PAY);
    }

    /// The headline property: burn == mint, so the delivered amount is the amount.
    /// No fee bound, no slippage allowance, nothing to author slack against.
    function test_cctp_burnsExactlyTheBridgedAmount() public {
        _bridgeCctp(dstFunnel);
        assertEq(messenger.burnCount(), 1, "one burn");
        MockTokenMessenger.Burn memory b = messenger.burnAt(0);
        assertEq(b.amount, BRIDGE, "burn is the full amount, undeducted");
        assertEq(b.burnToken, address(tA), "burns the source token");
    }

    /// Circle routes on its OWN domain id, which is unrelated to the chain id —
    /// the module carries both and must not confuse them.
    function test_cctp_routesOnDomainNotChainId() public {
        _bridgeCctp(dstFunnel);
        MockTokenMessenger.Burn memory b = messenger.burnAt(0);
        assertEq(b.destinationDomain, DST_DOMAIN, "routes on the Circle domain");
        assertTrue(uint256(b.destinationDomain) != DST_CHAIN, "domain and chain id are different numbers");
    }

    /// CCTP addresses non-EVM chains through a bytes32, so an EVM recipient is
    /// left-padded rather than truncated.
    function test_cctp_recipientIsLeftPaddedBytes32() public {
        _bridgeCctp(dstFunnel);
        assertEq(messenger.burnAt(0).mintRecipient, bytes32(uint256(uint160(dstFunnel))), "left-padded recipient");
    }

    /// The burn event is the ONLY record linking a burn to the order it funds —
    /// CCTP carries no payload and we have no destination contract on this path, so
    /// an indexer has nothing else to correlate the Circle attestation against.
    function test_cctp_emitsTheCorrelationEvent() public onSourceChain {
        Order memory src = _srcOrder(2, PAY, BRIDGE, address(cctpOut), _cctpSpec(dstFunnel));
        _wireSourceParties(address(cctpOut), PAY, BRIDGE);
        bytes memory sig = _sign(src);

        vm.expectEmit(true, true, true, true, address(cctpOut));
        emit CctpBridgeOutModule.CctpBurn(1, DST_DOMAIN, dstFunnel, address(tA), BRIDGE);
        vm.prank(solver);
        settlement.fill(src, sig, PAY);
    }

    /// Same invariant every module in this package holds: it ends the fill empty,
    /// and anything unconsumed goes back to the MAKER, never a caller-chosen party.
    function test_cctp_moduleEndsEmpty() public {
        _bridgeCctp(dstFunnel);
        assertEq(tA.balanceOf(address(cctpOut)), 0, "module holds nothing");
    }

    /// The shared destination sanity guards apply unchanged. Zero recipient is the
    /// one guard that prevents a total loss rather than an inconvenience.
    function test_cctp_rejectsZeroRecipient() public onSourceChain {
        Order memory src = _srcOrder(2, PAY, BRIDGE, address(cctpOut), _cctpSpec(address(0)));
        _wireSourceParties(address(cctpOut), PAY, BRIDGE);
        bytes memory sig = _sign(src);
        vm.prank(solver);
        vm.expectRevert(BridgeOutBase.BadDestination.selector);
        settlement.fill(src, sig, PAY);
    }

    /// Only Settlement may drive an item — the gate that makes the maker's
    /// signature the sole authority over the bridge parameters.
    function test_cctp_onlySettlementMayInvoke() public {
        vm.expectRevert(BridgeOutBase.OnlySettlement.selector);
        vm.prank(solver);
        cctpOut.makeOnBehalf(maker, BRIDGE, _cctpSpec(dstFunnel));
    }
}
