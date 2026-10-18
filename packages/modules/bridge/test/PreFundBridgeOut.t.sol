// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";

import {Order, Item, ItemOp, LegOut} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";

import {AcrossBridgeOutModule} from "../src/out/AcrossBridgeOutModule.sol";
import {CctpBridgeOutModule} from "../src/out/CctpBridgeOutModule.sol";
import {LzOftBridgeOutModule} from "../src/out/LzOftBridgeOutModule.sol";
import {MockSpokePool, MockOFT, MockTokenMessenger} from "./shared/Mocks.t.sol";
import {BridgeTestBase} from "./shared/BridgeTestBase.t.sol";

/// @title PreFundBridgeOutTest
/// @notice The PRE-FUNDED form of the three bridge-out modules on the single-order
///         path (review 2026-10-18 M-5, and M-4 for the LayerZero fee).
///
///         Shape: `legsOut[j]` is addressed to the MODULE, the item's `data` opens
///         with `forLegPreFund(j, inputToken)`, and the core sizes the item from its
///         delivery ledger. The maker grants the module NOTHING — every test here
///         wires the maker with a Settlement allowance for its own input token only.
///
///         LayerZero additionally takes its messaging fee from a wrapped-native
///         output leg ({LzOftBridgeOutModule.OP_FEE_CREDIT}), so the fill needs no
///         native float parked on the module beforehand.
contract PreFundBridgeOutTest is BridgeTestBase {
    uint256 constant PAY = 500e18; //      tC the maker pays
    uint256 constant BRIDGE = 100e18; //   tA delivered to the module, then bridged
    uint256 constant RESIDUE = 7e18; //    stray tA already on a module singleton
    uint256 constant FEE_BUDGET = 0.03 ether; // wrapped native delivered for the LZ fee
    uint256 constant LZ_FEE = 0.01 ether; //    MockOFT's quote
    uint16 constant RELAY_FEE_BPS = 100;

    CctpBridgeOutModule cctpOut;
    MockTokenMessenger messenger;

    function setUp() public override {
        super.setUp();
        messenger = new MockTokenMessenger();
        cctpOut = new CctpBridgeOutModule(address(permit3), address(settlement), address(messenger));
    }

    // ──────────────────── builders ────────────────────

    /// @dev `(5 << 253) | token << 16 | j` — pre-fund leg reference to `legsOut[j]`.
    function _forLeg(address token, uint256 j) internal pure returns (uint256) {
        return (uint256(5) << 253) | (uint256(uint160(token)) << 16) | j;
    }

    function _acrossSpec(bytes32 dstHash, uint256 total) internal view returns (AcrossBridgeOutModule.AcrossSpec memory) {
        return AcrossBridgeOutModule.AcrossSpec({
            inputToken: address(tA),
            outputToken: address(tA),
            dstChainId: DST_CHAIN,
            dstRecipient: address(inbox),
            exclusiveRelayer: address(0),
            maxRelayFeeBps: RELAY_FEE_BPS,
            dstScalingFactor: 0,
            fillDeadlineOffset: 2 hours,
            exclusivityOffset: 0,
            dstOrderHash: dstHash,
            beneficiary: beneficiary,
            commitmentExpiry: uint32(block.timestamp) + COMMITMENT_EXPIRY_OFFSET,
            totalAmount: total
        });
    }

    function _lzSpec(address feePayer) internal view returns (LzOftBridgeOutModule.LzSpec memory) {
        return LzOftBridgeOutModule.LzSpec({
            oft: address(oft),
            inputToken: address(tA),
            dstEid: 30_101,
            dstChainId: DST_CHAIN,
            dstRecipient: address(inbox),
            maxSlippageBps: 50,
            maxNativeFee: 0.05 ether,
            feePayer: feePayer,
            extraOptions: hex"0003",
            dstOrderHash: keccak256("dst"),
            beneficiary: beneficiary,
            commitmentExpiry: uint32(block.timestamp) + COMMITMENT_EXPIRY_OFFSET,
            totalAmount: BRIDGE
        });
    }

    /// @dev Pays `tC`, one `token` leg of `amount` addressed to `module`, one item.
    function _preSrc(uint256 nonce, address module, address token, uint256 amount, ItemOp op, bytes memory data)
        internal
        view
        returns (Order memory o)
    {
        o = _blank(nonce);
        o.legsIn = _legsIn1(address(tC), PAY);
        o.legsOut = PackedEncode.oneLegOut(token, amount, 0, module);
        Item[] memory items = new Item[](1);
        items[0] = Item({op: op, module: module, amount: 0, recipient: address(0), data: data});
        o.items = PackedEncode.items(items);
    }

    /// @dev The LayerZero fee-from-legs order: `[tA → lzOut, WETH → lzOut]` and two
    ///      items — the fee credit (leg 1) first, then the pre-funded send (leg 0).
    function _lzFeeFromLegs(uint256 nonce, uint256 feeBudget) internal view returns (Order memory o) {
        o = _blank(nonce);
        o.legsIn = _legsIn1(address(tC), PAY);
        LegOut[] memory outs = new LegOut[](2);
        outs[0] = LegOut(address(tA), BRIDGE, 0, address(lzOut));
        outs[1] = LegOut(address(weth), feeBudget, 0, address(lzOut));
        o.legsOut = PackedEncode.legsOut(outs);
        Item[] memory items = new Item[](2);
        items[0] = Item({
            op: ItemOp.MAKE,
            module: address(lzOut),
            amount: 0,
            recipient: address(0),
            data: abi.encode(_forLeg(address(weth), 1) | (lzOut.OP_FEE_CREDIT() << 244))
        });
        items[1] = Item({
            op: ItemOp.MAKE,
            module: address(lzOut),
            amount: 0,
            recipient: address(0),
            data: abi.encode(_forLeg(address(tA), 0), _lzSpec(maker))
        });
        o.items = PackedEncode.items(items);
    }

    /// @dev Maker: a Settlement allowance for its own `tC` — and NOTHING to any
    ///      bridge module. Solver: `tA` (+ wrapped native) to deliver.
    function _wire() internal {
        tC.mint(maker, PAY);
        _makerApprove(address(settlement), address(tC), type(uint160).max);
        tA.mint(solver, BRIDGE);
        _solverApprove(address(settlement), address(tA), type(uint160).max);
    }

    function _wireSolverWeth(uint256 amount) internal {
        vm.deal(solver, amount);
        vm.prank(solver);
        weth.deposit{value: amount}();
        _solverApprove(address(settlement), address(weth), type(uint160).max);
    }

    function _fill(Order memory o, uint256 amount) internal onSourceChain {
        bytes memory sig = _sign(o);
        vm.prank(solver);
        settlement.fill(o, sig, amount);
    }

    function _expectFillRevert(Order memory o, uint256 amount, bytes memory err) internal onSourceChain {
        bytes memory sig = _sign(o);
        vm.expectRevert(err);
        vm.prank(solver);
        settlement.fill(o, sig, amount);
    }

    function _noModuleGrant(address module) internal view {
        (uint160 amt,) = permit3.tokenAllowance(maker, module, address(tA));
        assertEq(amt, 0, "maker granted the module nothing");
    }

    // ──────────────────── Across ────────────────────

    /// The leg lands on the module, the module bridges exactly that delivery, the
    /// maker never holds `tA` and never approved the module. Resident residue is not
    /// touched.
    function test_preFund_across_bridgesTheDeliveryWithoutAnyMakerGrant() public {
        _wire();
        tA.mint(address(acrossOut), RESIDUE);
        bytes memory data = abi.encode(_forLeg(address(tA), 0), _acrossSpec(keccak256("d"), BRIDGE));
        _fill(_preSrc(1, address(acrossOut), address(tA), BRIDGE, ItemOp.MAKE, data), PAY);

        MockSpokePool.Deposit memory d = spokePool.depositAt(0);
        assertEq(d.inputAmount, BRIDGE, "bridged exactly the delivery");
        assertEq(d.depositor, maker, "origin refunds still go to the maker");
        assertEq(d.outputAmount, BRIDGE - (BRIDGE * RELAY_FEE_BPS) / 10_000, "floor from the signed bound");
        assertEq(tA.balanceOf(maker), 0, "the tokens never transited the wallet");
        assertEq(tA.balanceOf(address(acrossOut)), RESIDUE, "module ends where it started");
        assertEq(tC.balanceOf(solver), PAY, "solver paid");
        _noModuleGrant(address(acrossOut));
    }

    /// On the pre-funded form the slice is the DELIVERY, so `totalAmount` is a floor:
    /// a leg above it bridges (where the pull form's equality would revert) …
    function test_preFund_across_totalAmountIsAFloor_deliveryAboveItPasses() public {
        _wire();
        bytes memory data = abi.encode(_forLeg(address(tA), 0), _acrossSpec(keccak256("d"), BRIDGE - 1e18));
        _fill(_preSrc(1, address(acrossOut), address(tA), BRIDGE, ItemOp.MAKE, data), PAY);
        assertEq(spokePool.depositAt(0).inputAmount, BRIDGE, "the whole delivery bridged");
    }

    /// … and a partial fill of an inbox-committed deposit still cannot slip under it.
    function test_preFund_across_partialFillBelowTotal_reverts() public {
        _wire();
        bytes memory data = abi.encode(_forLeg(address(tA), 0), _acrossSpec(keccak256("d"), BRIDGE));
        Order memory o = _preSrc(1, address(acrossOut), address(tA), BRIDGE, ItemOp.MAKE, data);
        _expectFillRevert(
            o,
            PAY / 2,
            abi.encodeWithSelector(FullFillGuard.PartialFillUnsupported.selector, BRIDGE / 2, BRIDGE)
        );
    }

    /// The descriptor's signed token must be the asset the spec bridges. A `tB` leg
    /// delivered to the module cannot be used to bridge the module's resident `tA`.
    function test_preFund_across_tokenMismatch_cannotSpendResidue() public {
        _wire();
        tA.mint(address(acrossOut), BRIDGE); // residue the attacker wants
        tB.mint(solver, BRIDGE);
        _solverApprove(address(settlement), address(tB), type(uint160).max);
        bytes memory data = abi.encode(_forLeg(address(tB), 0), _acrossSpec(bytes32(0), 0));
        Order memory o = _preSrc(1, address(acrossOut), address(tB), BRIDGE, ItemOp.MAKE, data);
        _expectFillRevert(o, PAY, abi.encodeWithSelector(PreFundGuard.FundingTokenMismatch.selector));
    }

    /// The core's bijection: a pre-fund descriptor over a MAKER-addressed leg is
    /// refused before the module runs, so the pre-fund branch can only ever see a
    /// delivery made to itself.
    function test_preFund_across_legNotAddressedToModule_refusedByCore() public {
        _wire();
        tA.mint(address(acrossOut), BRIDGE); // residue that would cover it
        bytes memory data = abi.encode(_forLeg(address(tA), 0), _acrossSpec(bytes32(0), 0));
        Order memory o = _preSrc(1, address(0), address(tA), BRIDGE, ItemOp.MAKE, data);
        // leg recipient = 0 (the maker), item module = acrossOut
        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.MAKE, module: address(acrossOut), amount: 0, recipient: address(0), data: data});
        o.items = PackedEncode.items(items);
        _expectFillRevert(o, PAY, abi.encodeWithSelector(Base.ForLegInvalid.selector));
    }

    /// The pull form is unchanged: same module, plain spec, maker grant.
    function test_pull_across_stillWorks() public {
        _wire();
        bytes memory data = abi.encode(_acrossSpec(bytes32(0), 0));
        Order memory o = _srcOrder(1, PAY, BRIDGE, address(acrossOut), data);
        _makerApprove(address(acrossOut), address(tA), type(uint160).max);
        _fill(o, PAY);
        assertEq(spokePool.depositAt(0).inputAmount, BRIDGE, "pull form bridges");
    }

    // ──────────────────── CCTP ────────────────────

    function test_preFund_cctp_burnsTheDeliveryWithoutAnyMakerGrant() public {
        _wire();
        tA.mint(address(cctpOut), RESIDUE);
        address funnel = makeAddr("dstFunnel");
        bytes memory data = abi.encode(
            _forLeg(address(tA), 0),
            CctpBridgeOutModule.CctpSpec({
                inputToken: address(tA),
                dstChainId: DST_CHAIN,
                dstDomain: 3,
                dstRecipient: funnel,
                maxFeeBps: 10,
                minFinalityThreshold: 2000
            })
        );
        _fill(_preSrc(1, address(cctpOut), address(tA), BRIDGE, ItemOp.MAKE, data), PAY);

        MockTokenMessenger.Burn memory b = messenger.burnAt(0);
        assertEq(b.amount, BRIDGE, "burned exactly the delivery");
        assertEq(b.mintRecipient, bytes32(uint256(uint160(funnel))), "to the funnel");
        assertEq(tA.balanceOf(address(cctpOut)), RESIDUE, "module ends where it started");
        assertEq(tA.balanceOf(maker), 0, "never transited the wallet");
        _noModuleGrant(address(cctpOut));
    }

    // ──────────────────── LayerZero: pre-funded send + fee from legs ────────────────────

    /// M-4: the messaging fee comes from a wrapped-native OUTPUT leg. Nothing is
    /// parked on the module before the fill — no `topUpFor`, no sponsor — and the
    /// maker grants nothing. The unused budget stays the maker's credit.
    function test_preFund_lz_feeFromLegs_noFloatNoGrant() public {
        _wire();
        _wireSolverWeth(FEE_BUDGET);
        assertEq(address(lzOut).balance, 0, "no native float before the fill");
        assertEq(lzOut.nativeCredit(maker), 0, "no prior top-up");

        _fill(_lzFeeFromLegs(1, FEE_BUDGET), PAY);

        MockOFT.Sent memory s = oft.sentAt(0);
        assertEq(s.amountLD, BRIDGE, "bridged exactly the delivery");
        assertEq(s.nativeFee, LZ_FEE, "fee paid");
        assertEq(s.refundAddress, maker, "self-paid: executor change to the maker");
        assertEq(lzOut.nativeCredit(maker), FEE_BUDGET - LZ_FEE, "unused budget is the maker's credit");
        assertEq(address(lzOut).balance, FEE_BUDGET - LZ_FEE, "native held == ledger");
        assertEq(weth.balanceOf(address(lzOut)), 0, "the wrapped leg was unwrapped in full");
        assertEq(tA.balanceOf(address(lzOut)), 0, "nothing stranded");
        assertEq(tA.balanceOf(maker), 0, "never transited the wallet");
        _noModuleGrant(address(lzOut));

        // The leftover is the maker's, reclaimable at will.
        vm.prank(maker);
        lzOut.withdrawNative(FEE_BUDGET - LZ_FEE);
        assertEq(maker.balance, FEE_BUDGET - LZ_FEE, "maker reclaimed the unused budget");
    }

    /// A fee budget below the quote fails closed rather than borrowing anyone else's
    /// credit — even with a stranger's credit sitting in the module.
    function test_preFund_lz_feeBudgetBelowQuote_reverts() public {
        _wire();
        _wireSolverWeth(LZ_FEE - 1);
        address other = makeAddr("other");
        vm.deal(other, 1 ether);
        vm.prank(other);
        lzOut.topUpFor{value: 1 ether}(other);
        _expectFillRevert(
            _lzFeeFromLegs(1, LZ_FEE - 1), PAY, abi.encodeWithSelector(LzOftBridgeOutModule.InsufficientNativeCredit.selector)
        );
        assertEq(lzOut.nativeCredit(other), 1 ether, "other payer untouched");
    }

    /// Residue wrapped native on the singleton is never credited: the credit is the
    /// core-sized delivery, not the module's balance.
    function test_preFund_lz_feeCredit_ignoresResidueWeth() public {
        _wire();
        _wireSolverWeth(FEE_BUDGET);
        vm.deal(address(this), 1 ether);
        weth.deposit{value: 1 ether}();
        weth.transfer(address(lzOut), 1 ether); // stray WETH on the module

        _fill(_lzFeeFromLegs(1, FEE_BUDGET), PAY);
        assertEq(lzOut.nativeCredit(maker), FEE_BUDGET - LZ_FEE, "credited the delivery, not the residue");
        assertEq(weth.balanceOf(address(lzOut)), 1 ether, "residue untouched");
    }

    /// A fee-credit descriptor whose token is not the wrapped native is refused.
    function test_preFund_lz_feeCredit_wrongToken_reverts() public {
        _wire();
        bytes memory data = abi.encode(_forLeg(address(tA), 0) | (lzOut.OP_FEE_CREDIT() << 244));
        Order memory o = _preSrc(1, address(lzOut), address(tA), BRIDGE, ItemOp.MAKE, data);
        _expectFillRevert(o, PAY, abi.encodeWithSelector(PreFundGuard.FundingTokenMismatch.selector));
    }

    /// A deployment without a wrapped native has no fee-credit op.
    function test_preFund_lz_feeCredit_disabledWithoutWrappedNative() public {
        LzOftBridgeOutModule bare = new LzOftBridgeOutModule(address(permit3), address(settlement), address(0));
        _wire();
        _wireSolverWeth(FEE_BUDGET);
        bytes memory data = abi.encode(_forLeg(address(weth), 0) | (bare.OP_FEE_CREDIT() << 244));
        Order memory o = _preSrc(1, address(bare), address(weth), FEE_BUDGET, ItemOp.MAKE, data);
        _expectFillRevert(o, PAY, abi.encodeWithSelector(LzOftBridgeOutModule.NoWrappedNative.selector));
    }

    /// The pre-funded send also works against a fee the maker topped up earlier
    /// (the old self-paid credit), without the module grant.
    function test_preFund_lz_sendWithPriorCredit() public {
        _wire();
        vm.deal(maker, 1 ether);
        vm.prank(maker);
        lzOut.topUpFor{value: 0.1 ether}(maker);
        bytes memory data = abi.encode(_forLeg(address(tA), 0), _lzSpec(maker));
        _fill(_preSrc(1, address(lzOut), address(tA), BRIDGE, ItemOp.MAKE, data), PAY);
        assertEq(oft.sentAt(0).amountLD, BRIDGE, "bridged the delivery");
        assertEq(lzOut.nativeCredit(maker), 0.1 ether - LZ_FEE, "fee from the maker's credit");
        _noModuleGrant(address(lzOut));
    }

    /// A pre-funded blob on the SETTLE seam is refused: the core does not size SETTLE
    /// slices from its delivery ledger, so the delivery would be unbound.
    function test_preFund_lz_onSettleSeam_refused() public {
        _wire();
        bytes memory data = abi.encode(_forLeg(address(tA), 0), _lzSpec(maker));
        Order memory o = _preSrc(1, address(lzOut), address(tA), BRIDGE, ItemOp.SETTLE, data);
        // SETTLE slices pro-rate `item.amount`; give it one so the item runs.
        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.SETTLE, module: address(lzOut), amount: BRIDGE, recipient: address(0), data: data});
        o.items = PackedEncode.items(items);
        _expectFillRevert(o, PAY, abi.encodeWithSelector(LzOftBridgeOutModule.PreFundNeedsMake.selector));
    }

    /// A sponsored spec stays PULL/SETTLE-only: on the pre-funded MAKE form it is
    /// refused exactly like the pull MAKE form refuses it.
    function test_preFund_lz_sponsoredSpec_refused() public {
        _wire();
        bytes memory data = abi.encode(_forLeg(address(tA), 0), _lzSpec(solver));
        Order memory o = _preSrc(1, address(lzOut), address(tA), BRIDGE, ItemOp.MAKE, data);
        _expectFillRevert(o, PAY, abi.encodeWithSelector(LzOftBridgeOutModule.SponsoredSendNeedsSettle.selector));
    }

    /// An op outside {OP_SEND, OP_FEE_CREDIT} is refused.
    function test_preFund_lz_unknownOp_reverts() public {
        _wire();
        bytes memory data = abi.encode(_forLeg(address(tA), 0) | (uint256(2) << 244), _lzSpec(maker));
        Order memory o = _preSrc(1, address(lzOut), address(tA), BRIDGE, ItemOp.MAKE, data);
        _expectFillRevert(o, PAY, abi.encodeWithSelector(LzOftBridgeOutModule.BadOp.selector));
    }

    /// Bare native is refused: credit only ever enters through `topUpFor` or the
    /// fee-credit op's unwrap.
    function test_lz_receive_onlyFromWrappedNative() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(lzOut).call{value: 1}("");
        assertFalse(ok, "a bare transfer is refused");
    }

    /// The module entrypoints stay Settlement-only on the pre-funded form.
    function test_preFund_directCall_refused() public {
        bytes memory data = abi.encode(_forLeg(address(tA), 0), _lzSpec(maker));
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OnlySettlement()"))));
        lzOut.makeOnBehalf(maker, BRIDGE, data);
        tA.mint(address(acrossOut), BRIDGE);
        vm.expectRevert(abi.encodeWithSelector(bytes4(keccak256("OnlySettlement()"))));
        acrossOut.makeOnBehalf(maker, BRIDGE, abi.encode(_forLeg(address(tA), 0), _acrossSpec(bytes32(0), 0)));
    }
}
