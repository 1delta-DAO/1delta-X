// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {Order} from "@core/settlement/Structs.sol";
import {DutchAuction} from "@core/settlement/DutchAuction.sol";
import {Proportional} from "@core/settlement/Proportional.sol";
import {IOrderValidator} from "@core/interfaces/IOrderValidator.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {ConditionTreeValidator} from "@validators/ConditionTreeValidator.sol";
import {OcoGroupModule} from "@modules/oco/src/OcoGroupModule.sol";
import {CosignedQuotePriceModule} from "@modules/pricing/quotes/src/CosignedQuotePriceModule.sol";
import {ChainlinkTickFloorValidator} from "@validators/ChainlinkPriceValidators.sol";
import {LegIn, LegOut, Item, ItemOp} from "@core/settlement/Structs.sol";
import {PackedEncode} from "./shared/PackedEncode.sol";

/// @dev `PreFundGuard` reads `bytes calldata`; an external self-call is the way to
///      hand it the fixture bytes as calldata.
contract PreFundGuardProbe {
    function fundingToken(bytes calldata d) external pure returns (address) {
        return PreFundGuard.fundingToken(d);
    }

    function requireLegRef(bytes calldata d) external pure {
        PreFundGuard.requireLegRef(d);
    }

    function requirePlainTake(bytes calldata d) external pure {
        PreFundGuard.requirePlainTake(d);
    }

    function requireFundingDescriptor(bytes calldata d) external pure {
        PreFundGuard.requireFundingDescriptor(d);
    }
}

/// @dev The `DutchAuction` accessors read `Order calldata`. Same trick.
contract OrderProbe {
    using DutchAuction for Order;

    function clocks(Order calldata o) external pure returns (uint256, uint256, uint256) {
        return (o.decayStartTime(), o.decayDuration(), o.exclusivityEndTime());
    }

    function flags(Order calldata o) external pure returns (bool, bool, bool, bool, uint256) {
        return (o.blockClock(), o.priorityAuction(), o.deltaVerifyOutputs(), o.useNonceInvalidator(), o.itemPolicy());
    }

    function params(Order calldata o) external pure returns (uint256, uint256, uint256, uint256, uint256) {
        return (o.overrideBps(), o.gasBumpBps(), o.gasPriceRef(), o.priorityScale(), o.baselinePriorityFeeWei());
    }
}

/// @dev A condition leaf with a fixed answer, or one that reverts. `vm.etch`ed at
///      the fixture's leaf addresses — the answer is an immutable, so it travels
///      with the runtime code.
contract LeafTrue is IOrderValidator {
    function validate(Order calldata, address, bytes calldata, bytes calldata) external pure returns (bool) {
        return true;
    }
}

contract LeafFalse is IOrderValidator {
    function validate(Order calldata, address, bytes calldata, bytes calldata) external pure returns (bool) {
        return false;
    }
}

contract LeafRevert is IOrderValidator {
    function validate(Order calldata, address, bytes calldata, bytes calldata) external pure returns (bool) {
        revert("leaf down");
    }
}

/// @dev An 8-decimal feed with a settable answer, etched at the fixture's feed address.
contract FeedStub {
    int256 public answer;

    function set(int256 a) external {
        answer = a;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, block.timestamp, block.timestamp, 1);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}

/// @title EncodingGoldenTest
/// @notice THE SDK'S ENCODING VECTORS, RUN THROUGH THE REAL INTERPRETERS.
///
///  `HashGolden.t.sol` pins the order hash: if the SDK's `packOrder` drifts from
///  `OrderHash`, one side's constant changes. It says nothing about the words the
///  settler and the modules INTERPRET once the hash has passed — funding
///  descriptors, proportional markers, the `timing`/`params` bit-fields, the
///  condition-tree blob, the OCO item blob, the quote takerData head. Each is a
///  serialization boundary between the SDK (encoder) and a contract (interpreter),
///  and that boundary is where 1inch Aqua's only High of H1 2026 lived — a
///  MakerTraits hook-flag mismatch, fixed in the SDK (docs/reference-bounties.md
///  B4). The SDK's `sdk-packed-order-sync` episode was our own mild form.
///
///  This test reads `packages/sdk/test/fixtures/encoding-vectors.json` — the SAME
///  file `encodingGolden.test.ts` asserts the SDK still produces — and hands every
///  vector to the Solidity code that consumes it in production: `PreFundGuard`
///  (the module half of the descriptor seam), `DutchAuction`'s accessors,
///  `Proportional`, a deployed `ConditionTreeValidator`, `OcoGroupModule` and
///  `CosignedQuotePriceModule`. One fixture, two consumers, no constant to update
///  on two schedules. A contract change that moves a bit fails HERE; an SDK change
///  that moves a bit fails there; only a change to both, committed together with a
///  regenerated fixture, passes.
contract EncodingGoldenTest is Test {
    string constant FIXTURE = "packages/sdk/test/fixtures/encoding-vectors.json";
    string json;

    PreFundGuardProbe guard;
    OrderProbe probe;

    function setUp() public {
        json = vm.readFile(FIXTURE);
        guard = new PreFundGuardProbe();
        probe = new OrderProbe();
    }

    // ──────────────────── fixture readers ────────────────────

    function _word(string memory key) internal view returns (uint256) {
        return uint256(vm.parseJsonBytes32(json, key));
    }

    function _uint(string memory key) internal view returns (uint256) {
        return vm.parseJsonUint(json, key);
    }

    function _addr(string memory key) internal view returns (address) {
        return vm.parseJsonAddress(json, key);
    }

    function _bytes(string memory key) internal view returns (bytes memory) {
        return vm.parseJsonBytes(json, key);
    }

    /// @dev A minimal order carrying only the words under test.
    function _order(uint256 timing, uint256 params, uint256 nonce) internal pure returns (Order memory o) {
        o.maker = address(0xA1);
        o.nonce = nonce;
        o.timing = timing;
        o.params = params;
        o.curve = PackedEncode.noCurve();
        o.validators = PackedEncode.noValidators();
        o.invariants = PackedEncode.noValidators();
    }

    // ──────────────────── funding descriptors ────────────────────

    /// @dev The pre-fund leg reference: `>> 253 == 5`, token at [16:176), index low.
    ///      `PreFundGuard.fundingToken` is the module half of `Base._forSlice`'s
    ///      token binding; both read the same bits, and this is the SDK's word.
    function test_forLegPreFund_isReadByPreFundGuard() public view {
        bytes memory d = abi.encode(_word(".descriptors.forLegPreFund_1_WETH"), address(0));
        assertEq(guard.fundingToken(d), _addr(".descriptors.token"), "funding token bits [16:176)");
        guard.requireLegRef(d); // does not revert
        guard.requireFundingDescriptor(d); // bit 255 set
        assertEq(_word(".descriptors.forLegPreFund_1_WETH") & 0xffff, 1, "leg index in the low 16 bits");
    }

    /// @dev A pre-fund word must NOT be readable as a plain TAKE blob, and the plain
    ///      pull leg reference must NOT be readable as pre-fund — the two data
    ///      spaces are disjoint on bit 253.
    function test_descriptorShapes_areDisjoint() public {
        bytes memory pre = abi.encode(_word(".descriptors.forLegPreFund_1_WETH"));
        vm.expectRevert(PreFundGuard.PreFundDescriptorNotAllowed.selector);
        guard.requirePlainTake(pre);

        bytes memory pull = abi.encode(_word(".descriptors.forLeg_3"));
        vm.expectRevert(PreFundGuard.PreFundDescriptorRequired.selector);
        guard.requireLegRef(pull);
        guard.requireFundingDescriptor(pull); // still a funding descriptor (bit 255)
        assertEq(_word(".descriptors.forLeg_3") & 0xffff, 3, "pull leg index");

        bytes memory bal = abi.encode(_word(".descriptors.forBalance_WETH_default"));
        vm.expectRevert(PreFundGuard.PreFundDescriptorRequired.selector);
        guard.requireLegRef(bal); // bit 254 set ⇒ balance form, not a leg ref

        bytes memory lit = abi.encode(_word(".descriptors.forTotal_123e18"));
        vm.expectRevert(PreFundGuard.LiteralDescriptorNotAllowed.selector);
        guard.requireFundingDescriptor(lit);
        guard.requirePlainTake(lit); // a literal opens with a small word: plain
    }

    /// @dev The balance form, exactly as `Base._forSlice` reads it: bits 255+254,
    ///      the token in the low 160, the floor at [160:176) with `0` resolving to
    ///      the full cap. These three lines ARE the settler's decode
    ///      (`address(uint160(desc))`, `(desc >> 160) & 0xffff`, `== 0 ⇒ 10_000`).
    function test_forBalance_layoutMatchesForSlice() public view {
        address token = _addr(".descriptors.token");
        uint256 dflt = _word(".descriptors.forBalance_WETH_default");
        uint256 eighty = _word(".descriptors.forBalance_WETH_8000");
        uint256 one = _word(".descriptors.forBalance_WETH_1");
        for (uint256 i; i < 3; ++i) {
            uint256 d = i == 0 ? dflt : i == 1 ? eighty : one;
            assertEq(d >> 254, 3, "bits 255 and 254 set");
            assertEq((d >> 253) & 1, 0, "bit 253 clear");
            assertEq(address(uint160(d)), token, "token in the low 160 bits");
        }
        assertEq((dflt >> 160) & 0xffff, 10_000, "default floor is the full cap, written explicitly");
        assertEq((eighty >> 160) & 0xffff, 8_000, "floor 8000");
        assertEq((one >> 160) & 0xffff, 1, "floor 1");
        assertEq(_word(".descriptors.forTotal_123e18"), 123e18, "literal total is the number itself");
    }

    // ──────────────────── proportional markers ────────────────────

    function test_proportionalMarkers_decodeToTheirBps() public view {
        uint256 m25 = _word(".proportional.bps_2500");
        uint256 m100 = _word(".proportional.bps_10000");
        uint256 m1 = _word(".proportional.bps_1");
        assertTrue(Proportional.isProportional(m25) && Proportional.isProportional(m100) && Proportional.isProportional(m1));
        assertEq(Proportional.bps(m25), 2_500);
        assertEq(Proportional.bps(m100), 10_000);
        assertEq(Proportional.bps(m1), 1);
        assertEq(Proportional.encode(2_500), m25, "Proportional.encode round-trips the SDK marker");
        assertFalse(Proportional.isProportional(_word(".descriptors.forTotal_123e18")), "an ordinary amount is not a marker");
    }

    // ──────────────────── timing + params bit-fields ────────────────────

    function test_timing_clocksAndFlags() public view {
        (uint256 s, uint256 d, uint256 e) = probe.clocks(_order(_word(".timing.base_111_222_333"), 0, 0));
        assertEq(s, 111);
        assertEq(d, 222);
        assertEq(e, 333);

        (bool bc, bool pa, bool dv, bool fo, uint256 pol) = probe.flags(_order(_word(".timing.base_111_222_333"), 0, 0));
        assertTrue(!bc && !pa && !dv && !fo && pol == 0, "base word carries no flags");

        (bc,,,,) = probe.flags(_order(_word(".timing.blockClock"), 0, 0));
        assertTrue(bc, "bit 102");
        (, pa,,,) = probe.flags(_order(_word(".timing.priorityAuction"), 0, 0));
        assertTrue(pa, "bit 103");
        (,, dv,,) = probe.flags(_order(_word(".timing.deltaVerifyOutputs"), 0, 0));
        assertTrue(dv, "bit 104");
        (,,, fo,) = probe.flags(_order(_word(".timing.fillOnce"), 0, 0));
        assertTrue(fo, "bit 100");
        (,,,, pol) = probe.flags(_order(_word(".timing.itemPolicyCanonical"), 0, 0));
        assertEq(pol, 3, "ItemPolicy.CANONICAL at [96:100)");
        (,,,, pol) = probe.flags(_order(_word(".timing.itemPolicyAtomic"), 0, 0));
        assertEq(pol, 2, "ItemPolicy.ATOMIC at [96:100)");

        // The clocks survive every flag.
        (s, d, e) = probe.clocks(_order(_word(".timing.itemPolicyCanonical"), 0, 0));
        assertTrue(s == 111 && d == 222 && e == 333, "flags do not disturb the clocks");
    }

    function test_params_fiveFields() public view {
        (uint256 ov, uint256 gb, uint256 gp, uint256 ps, uint256 bp) = probe.params(_order(0, _word(".params.packed"), 0));
        assertEq(ov, _uint(".params.overrideBps"));
        assertEq(gb, _uint(".params.gasBumpBps"));
        assertEq(gp, _uint(".params.gasPriceRef"));
        assertEq(ps, _uint(".params.priorityScale"));
        assertEq(bp, _uint(".params.baselinePriorityFeeWei"));
    }

    // ──────────────────── condition tree ────────────────────

    /// @dev `(A) OR (NOT B AND TRY C)`, evaluated by the deployed validator on the
    ///      SDK's blob with the leaves etched at the fixture's addresses.
    function _leaves(bool a, bool b, uint8 c) internal {
        vm.etch(_addr(".conditions.leafA"), address(a ? IOrderValidator(new LeafTrue()) : new LeafFalse()).code);
        vm.etch(_addr(".conditions.leafB"), address(b ? IOrderValidator(new LeafTrue()) : new LeafFalse()).code);
        address cImpl = c == 0 ? address(new LeafFalse()) : c == 1 ? address(new LeafTrue()) : address(new LeafRevert());
        vm.etch(_addr(".conditions.leafC"), cImpl.code);
    }

    function test_conditionTree_dnfBlobEvaluates() public {
        ConditionTreeValidator tree = new ConditionTreeValidator();
        bytes memory blob = _bytes(".conditions.blob");
        Order memory o = _order(0, 0, 0);

        _leaves(true, true, 0);
        assertTrue(tree.validate(o, address(0), blob, ""), "A alone satisfies");
        _leaves(false, false, 1);
        assertTrue(tree.validate(o, address(0), blob, ""), "NOT(false) AND TRY(true)");
        _leaves(false, true, 1);
        assertFalse(tree.validate(o, address(0), blob, ""), "NOT(true) kills the second group");
        _leaves(false, false, 2);
        assertFalse(tree.validate(o, address(0), blob, ""), "TRY folds a reverting leaf to false");
    }

    // ──────────────────── OCO group module ────────────────────

    function test_oco_itemAndValidatorBlobs() public {
        OcoGroupModule oco = new OcoGroupModule(address(this)); // this test is the "settlement"
        address maker = address(0xA1);
        uint256 groupId = _uint(".oco.groupId");
        uint256 nonce = _uint(".oco.nonce");
        bytes memory item = _bytes(".oco.itemData");
        bytes memory val = _bytes(".oco.validatorData");

        // The validator binds the claim item to the order (F29 finding 3): the leg
        // must carry the SETTLE record encoding its own nonce.
        Order memory leg = _order(0, 0, nonce);
        leg.items = _ocoItems(address(oco), item);
        Order memory sibling = _order(0, 0, nonce + 1);
        sibling.items = _ocoItems(address(oco), abi.encode(groupId, nonce + 1, _uint(".oco.minClaim")));

        assertTrue(oco.validate(leg, address(0), val, ""), "open group admits the leg");
        assertFalse(oco.validate(_order(0, 0, nonce), address(0), val, ""), "a leg without its claim item is refused");
        // The SDK's third word is the maker-signed claim floor (2026-09-30 PRICE-2):
        // a claiming fill under it is refused, at it the group is claimed.
        uint256 minClaim = _uint(".oco.minClaim");
        vm.expectRevert(abi.encodeWithSelector(OcoGroupModule.ClaimTooSmall.selector, minClaim - 1, minClaim));
        oco.settle(maker, address(0), minClaim - 1, item);
        oco.settle(maker, address(0), minClaim, item);
        assertTrue(oco.validate(leg, address(0), val, ""), "the claimant stays fillable");
        assertFalse(oco.validate(sibling, address(0), val, ""), "a sibling is retired");
        assertTrue(oco.isRetiredFor(maker, groupId, nonce + 1));
        assertFalse(oco.isRetiredFor(maker, groupId, nonce));
    }

    // ──────────────────── Chainlink tick floor ────────────────────

    /// @dev The SDK's 4-word blob for the 18-in / 6-out / 8-dec shape, run through
    ///      the real validator: blocks a runaway market, passes at market. This is
    ///      the shape whose 1e18 scale truncated to 0 (F29 finding 1).
    function test_tickFloorData_isReadByTheValidator() public {
        ChainlinkTickFloorValidator v = new ChainlinkTickFloorValidator();
        address feed = _addr(".tickFloor.feed");
        vm.etch(feed, address(new FeedStub()).code);
        bytes memory d = _bytes(".tickFloor.data");

        Order memory o = _order(0, 0, 0);
        LegIn[] memory li = new LegIn[](1);
        li[0] = LegIn(address(0x1111), 1e18, 0); // 18-dec in
        LegOut[] memory lo = new LegOut[](1);
        lo[0] = LegOut(address(0x2222), 2_500e6, 0, address(0)); // 6-dec out
        o.legsIn = PackedEncode.legsIn(li);
        o.legsOut = PackedEncode.legsOut(lo);

        FeedStub(feed).set(4_000e8);
        assertFalse(v.validate(o, address(0), d, ""), "2500 < 4000 * 0.98: blocked");
        FeedStub(feed).set(2_500e8);
        assertTrue(v.validate(o, address(0), d, ""), "at market: passes");
        // The fixture's num/den are the ones the contract multiplied by.
        assertEq(_uint(".tickFloor.num"), 9_800);
        assertEq(_uint(".tickFloor.den"), 10_000 * 1e20);
    }

    function _ocoItems(address module, bytes memory data) internal pure returns (bytes memory) {
        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.SETTLE, module: module, amount: 1_000, recipient: address(0), data: data});
        return PackedEncode.items(items);
    }

    // ──────────────────── cosigned quote takerData ────────────────────

    /// @dev The SDK's 84-byte head + a signature the module's OWN digest accepts:
    ///      proves the head's slicing ([0:20] filler, [20:52] bump, [52:84]
    ///      deadline) and that the module reads the bump the SDK wrote.
    function test_quoteTakerDataHead_isSlicedByTheModule() public {
        (address cosigner, uint256 pk) = makeAddrAndKey("cosigner");
        CosignedQuotePriceModule m = new CosignedQuotePriceModule(cosigner, 0);
        address filler = _addr(".quote.filler");
        uint256 bumpBps = _uint(".quote.bumpBps");
        uint256 deadline = _uint(".quote.deadline");
        bytes memory head = _bytes(".quote.takerDataHead");
        assertEq(head.length, 84, "head is exactly filler|bump|deadline");

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, m.quoteDigest(bytes32(0), filler, bumpBps, deadline));
        bytes memory takerData = bytes.concat(head, abi.encodePacked(r, s, v));

        vm.warp(deadline - 1);
        uint256 got = m.bump(bytes32(0), address(0), filler, 0, 0, 0, "", "", takerData);
        assertEq(got, bumpBps, "module returned the SDK's bump");

        // Same bytes, wrong filler: the head's [0:20] is what the module compares.
        vm.expectRevert(CosignedQuotePriceModule.QuoteNotForFiller.selector);
        m.bump(bytes32(0), address(0), address(0xBAD), 0, 0, 0, "", "", takerData);
    }
}
