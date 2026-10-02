// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Order, Item, LegOut, Validator, CallbackMode, Settlement} from "@core/settlement/Settlement.sol";
import {Base} from "@core/settlement/Base.sol";
import {OrderGates} from "@core/settlement/OrderGates.sol";
import {Proportional} from "@core/settlement/Proportional.sol";
import {IOrderValidator} from "@core/interfaces/IOrderValidator.sol";
import {IERC1271} from "@core/interfaces/IERC1271.sol";

import {Erc721OwnerInvariant, Erc1155BalanceInvariant} from "@validators/OwnershipInvariants.sol";
import {MinBalanceInvariant} from "@validators/MinBalanceInvariant.sol";
import {InvariantReceiptGuard} from "@validators/InvariantReceiptGuard.sol";
import {
    ChainlinkRead,
    ChainlinkPriceGte,
    ChainlinkPriceLte,
    ChainlinkTickFloorValidator
} from "@validators/ChainlinkPriceValidators.sol";
import {PredicateStaticCall} from "@validators/PredicateStaticCall.sol";
import {ConditionTreeValidator} from "@validators/ConditionTreeValidator.sol";
import {FillerAttestationValidator} from "@validators/FillerAttestationValidator.sol";
import {TimestampValidator} from "@validators/TimestampValidator.sol";

import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";
import {MockSettlementBase} from "@coretest/shared/MockSettlementBase.t.sol";

// ═════════════════════════════ shared mocks ═════════════════════════════

/// @dev Minimal ERC-721 (external asset).
contract Audit0930Nft721 {
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from && msg.sender == from, "not owner");
        ownerOf[id] = to;
    }
}

/// @dev Minimal ERC-1155 (external asset).
contract Audit0930Nft1155 {
    mapping(uint256 => mapping(address => uint256)) internal bal;

    function balanceOf(address account, uint256 id) external view returns (uint256) {
        return bal[id][account];
    }

    function mint(address to, uint256 id, uint256 amount) external {
        bal[id][to] += amount;
    }

    function transfer(address to, uint256 id, uint256 amount) external {
        bal[id][msg.sender] -= amount;
        bal[id][to] += amount;
    }
}

/// @dev The filler's delivery arm, reached through Settlement's callback executor.
contract Audit0930DeliveryArm {
    function deliver721(Audit0930Nft721 c, uint256 id, address to) external {
        c.transferFrom(address(this), to, id);
    }

    function deliver1155(Audit0930Nft1155 c, uint256 id, uint256 amount, address to) external {
        c.transfer(to, id, amount);
    }
}

/// @dev The VAL-1 PoC attacker: honestly fills the maker's raised bid O2 (one
///      delivery), then fills the stale bid O1 delivering nothing.
contract Audit0930DoubleDipFiller {
    Settlement immutable settlement;
    Audit0930DeliveryArm public immutable arm;

    constructor(Settlement s) {
        settlement = s;
        arm = new Audit0930DeliveryArm();
    }

    function run(
        Order calldata o2,
        bytes calldata sig2,
        uint256 amt2,
        bytes calldata deliverCall,
        Order calldata o1,
        bytes calldata sig1,
        uint256 amt1
    ) external {
        settlement.fillWithCallback(o2, sig2, amt2, address(arm), deliverCall, CallbackMode.PostInputs);
        settlement.fill(o1, sig1, amt1);
    }
}

/// @dev External marketplace stand-in: the maker buys #id at the ask.
contract Audit0930Market {
    function buy(IERC20 pay, uint256 price, Audit0930Nft721 c, uint256 id, address seller) external {
        require(pay.transferFrom(msg.sender, seller, price), "pay");
        c.transferFrom(address(this), msg.sender, id);
    }
}

// ═════════════════════════════ VAL-1 ═════════════════════════════

/// @title Audit20260930_VAL1_Test
/// @notice VAL-1 — an invariant-only purchase (SELL, empty legsOut) used to be
///         fillable by ANY filler, and the absolute end-state invariant accepted an
///         inflow the maker paid for elsewhere as this fill's delivery. Fixed in the
///         invariants ({InvariantReceiptGuard}): with no output leg, the fill must
///         come from the order's named `exclusiveFiller`. Each test is the PoC
///         (docs/local/audit-2026-09-30/pocs/VAL_1.t.sol) asserting the SAFE end state.
contract Audit20260930_VAL1_Test is CoreSettlementBase {
    Erc721OwnerInvariant ownerInv;
    Erc1155BalanceInvariant balance1155Inv;
    MinBalanceInvariant minBalInv;
    Audit0930Nft721 nft;
    Audit0930Nft1155 multi;

    uint256 constant PRICE1 = 10_000e6; // stale bid
    uint256 constant PRICE2 = 10_500e6; // raised bid
    uint256 constant ID = 7;

    function setUp() public override {
        super.setUp();
        ownerInv = new Erc721OwnerInvariant();
        balance1155Inv = new Erc1155BalanceInvariant();
        minBalInv = new MinBalanceInvariant();
        nft = new Audit0930Nft721();
        multi = new Audit0930Nft1155();
    }

    function _inv(address target, bytes memory data) internal pure returns (Validator[] memory v) {
        v = new Validator[](1);
        v[0] = Validator(target, data);
    }

    function _purchase(uint256 nonce, address payToken, uint256 price, address invTarget, bytes memory invData)
        internal
        view
        returns (Order memory o)
    {
        o = _sellOrder(nonce, maker, payToken, address(0), price, 0, new Item[](0));
        o.legsOut = PackedEncode.legsOut(new LegOut[](0));
        o.minFillAnchor = price;
        o.invariants = PackedEncode.validators(_inv(invTarget, invData));
    }

    /// @dev The settler now refuses an unnamed filler on a no-output-leg invariant
    ///      order itself ({Base._runInvariants}, VAL-1 core rule) before the
    ///      invariant's own {InvariantReceiptGuard} runs; the guard stays as defence
    ///      in depth and is unit-tested directly below.
    function _expectReceiptRefused() internal {
        vm.expectRevert(OrderGates.NotExclusiveFiller.selector);
    }

    /// PoC 1: two live bids, one delivery — the attacker can no longer be paid twice.
    function test_audit_VAL_1_erc721_twoBids_oneDelivery_cannotDoubleDip() public {
        Audit0930DoubleDipFiller attacker = new Audit0930DoubleDipFiller(settlement);
        nft.mint(address(attacker.arm()), ID);
        deal(USDC, maker, PRICE1 + PRICE2);
        _approveMakerToSettlement(USDC, PRICE1 + PRICE2);

        Order memory o1 = _purchase(1, USDC, PRICE1, address(ownerInv), abi.encode(address(nft), ID, maker));
        Order memory o2 = _purchase(2, USDC, PRICE2, address(ownerInv), abi.encode(address(nft), ID, maker));
        bytes memory sig1 = _sign(o1);
        bytes memory sig2 = _sign(o2);

        vm.prank(address(0xBAD));
        _expectReceiptRefused();
        attacker.run(
            o2, sig2, PRICE2, abi.encodeCall(Audit0930DeliveryArm.deliver721, (nft, ID, maker)), o1, sig1, PRICE1
        );

        assertEq(IERC20(USDC).balanceOf(maker), PRICE1 + PRICE2, "maker keeps both payments");
        assertEq(IERC20(USDC).balanceOf(address(attacker)), 0, "attacker collected nothing");
    }

    /// PoC 2: the maker bought #7 elsewhere — the stale bid is no longer a free payout.
    function test_audit_VAL_1_erc721_makerBoughtElsewhere_botCannotDrainStaleBid() public {
        Audit0930Market market = new Audit0930Market();
        nft.mint(address(market), ID);
        deal(USDC, maker, PRICE1 + PRICE2);
        _approveMakerToSettlement(USDC, PRICE1);

        Order memory o1 = _purchase(1, USDC, PRICE1, address(ownerInv), abi.encode(address(nft), ID, maker));
        bytes memory sig1 = _sign(o1);

        vm.startPrank(maker);
        IERC20(USDC).approve(address(market), PRICE2);
        market.buy(IERC20(USDC), PRICE2, nft, ID, address(0x5E11));
        vm.stopPrank();
        assertEq(nft.ownerOf(ID), maker);

        address bot = address(0xB07);
        vm.prank(bot);
        _expectReceiptRefused();
        settlement.fill(o1, sig1, PRICE1);

        assertEq(IERC20(USDC).balanceOf(bot), 0, "bot took nothing");
        assertEq(IERC20(USDC).balanceOf(maker), PRICE1, "maker keeps the stale bid's funds");
    }

    /// PoC 3: ERC-1155 absolute floor — one lot cannot satisfy two open orders.
    function test_audit_VAL_1_erc1155_twoBids_oneDelivery_cannotDoubleDip() public {
        uint256 id = 9;
        uint256 qty = 40;
        Audit0930DoubleDipFiller attacker = new Audit0930DoubleDipFiller(settlement);
        multi.mint(address(attacker.arm()), id, qty);
        deal(USDC, maker, PRICE1 + PRICE2);
        _approveMakerToSettlement(USDC, PRICE1 + PRICE2);

        bytes memory d = abi.encode(address(multi), maker, id, qty);
        Order memory o1 = _purchase(11, USDC, PRICE1, address(balance1155Inv), d);
        Order memory o2 = _purchase(12, USDC, PRICE2, address(balance1155Inv), d);
        bytes memory sig1 = _sign(o1);
        bytes memory sig2 = _sign(o2);

        vm.prank(address(0xBAD));
        _expectReceiptRefused();
        attacker.run(
            o2,
            sig2,
            PRICE2,
            abi.encodeCall(Audit0930DeliveryArm.deliver1155, (multi, id, qty, maker)),
            o1,
            sig1,
            PRICE1
        );
        assertEq(IERC20(USDC).balanceOf(maker), PRICE1 + PRICE2, "maker keeps both payments");
    }

    /// PoC 4: MinBalance as the sole consideration — a floor met elsewhere is not a delivery.
    function test_audit_VAL_1_minBalance_floorMetElsewhere_noFreeFill() public {
        deal(USDC, maker, PRICE1);
        _approveMakerToSettlement(USDC, PRICE1);
        Order memory o1 = _purchase(21, USDC, PRICE1, address(minBalInv), abi.encode(WETH, maker, uint256(5 ether)));
        bytes memory sig1 = _sign(o1);
        deal(WETH, maker, 5 ether);

        address bot = address(0xB07);
        vm.prank(bot);
        _expectReceiptRefused();
        settlement.fill(o1, sig1, PRICE1);
        assertEq(IERC20(USDC).balanceOf(maker), PRICE1, "maker keeps 10,000 USDC");
    }

    /// Liveness: the named filler still completes a real purchase; any other filler
    /// (even one that WOULD deliver) is refused for the whole life of the order.
    function test_audit_VAL_1_namedFiller_canStillPurchase_othersRefused() public {
        Audit0930DeliveryArm arm = new Audit0930DeliveryArm();
        nft.mint(address(arm), ID);
        deal(USDC, maker, PRICE1);
        _approveMakerToSettlement(USDC, PRICE1);

        Order memory o = _purchase(31, USDC, PRICE1, address(ownerInv), abi.encode(address(nft), ID, maker));
        o.exclusiveFiller = solver;
        bytes memory sig = _sign(o);
        bytes memory deliver = abi.encodeCall(Audit0930DeliveryArm.deliver721, (nft, ID, maker));

        vm.prank(address(0xF00));
        _expectReceiptRefused();
        settlement.fillWithCallback(o, sig, PRICE1, address(arm), deliver, CallbackMode.PostInputs);

        vm.prank(solver);
        settlement.fillWithCallback(o, sig, PRICE1, address(arm), deliver, CallbackMode.PostInputs);
        assertEq(nft.ownerOf(ID), maker, "maker received the NFT");
        assertEq(IERC20(USDC).balanceOf(solver), PRICE1, "named filler paid");
    }

    /// Unit: the guard fires only on the invariant-receipt shape. With an output leg
    /// the invariant is a floor on top of a delivered leg, and any filler passes.
    function test_audit_VAL_1_guard_onlyOnNoOutputLegShape() public {
        deal(WETH, maker, 5 ether);
        bytes memory d = abi.encode(WETH, maker, uint256(5 ether));
        Order memory withLeg = _sellOrder(41, maker, USDC, WETH, PRICE1, 1 ether, new Item[](0));
        assertTrue(minBalInv.validate(withLeg, address(0xF00), d, ""), "output-leg order: open filler fine");

        Order memory noLeg = _purchase(42, USDC, PRICE1, address(minBalInv), d);
        vm.expectRevert(InvariantReceiptGuard.ReceiptNeedsNamedFiller.selector);
        minBalInv.validate(noLeg, address(0xF00), d, "");

        noLeg.exclusiveFiller = address(0xF00);
        assertTrue(minBalInv.validate(noLeg, address(0xF00), d, ""), "named filler passes");
        // exclusiveFiller == 0 can never be matched (filler is never address(0) on-chain,
        // and a zero filler is refused explicitly).
        noLeg.exclusiveFiller = address(0);
        vm.expectRevert(InvariantReceiptGuard.ReceiptNeedsNamedFiller.selector);
        minBalInv.validate(noLeg, address(0), d, "");
    }
}

// ═════════════════════════════ oracle / tree / attestation mocks ═════════════════════════════

/// @dev Chainlink-shaped feed with a controllable `startedAt` (used as an L2
///      sequencer-uptime feed: answer 0 = up, 1 = down).
contract Audit0930Feed {
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;

    function set(int256 answer_, uint256 startedAt_, uint256 updatedAt_) external {
        answer = answer_;
        startedAt = startedAt_;
        updatedAt = updatedAt_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (10, answer, startedAt, updatedAt, 10);
    }
}

contract Audit0930Reverter {
    function boom() external pure returns (uint256) {
        revert("boom");
    }
}

/// @dev Expensive read: ~`n` keccak rounds. Returns 1 when it completes.
contract Audit0930GasHog is IOrderValidator {
    function burn(uint256 n) public pure returns (uint256) {
        bytes32 h;
        assembly {
            for { let i := 0 } lt(i, n) { i := add(i, 1) } {
                mstore(0x00, h)
                mstore(0x20, i)
                h := keccak256(0x00, 0x40)
            }
        }
        return h == bytes32(0) ? 2 : 1;
    }

    function validate(Order calldata, address, bytes calldata, bytes calldata) external pure returns (bool) {
        return burn(20_000) == 1;
    }
}

/// @dev 1271 attester whose `isValidSignature` is expensive.
contract Audit0930GasHogAttester is IERC1271 {
    function isValidSignature(bytes32, bytes memory) external pure override returns (bytes4) {
        bytes32 h;
        assembly {
            for { let i := 0 } lt(i, 20000) { i := add(i, 1) } {
                mstore(0x00, h)
                mstore(0x20, i)
                h := keccak256(0x00, 0x40)
            }
        }
        return h == bytes32(0) ? bytes4(0) : IERC1271.isValidSignature.selector;
    }
}

// ═════════════════════════════ X-ARITH-1.v1, PRICE-8 / VAL-4, VAL-2, VAL-6 ═════════════════════════════

contract Audit20260930ValidatorsTest is MockSettlementBase {
    Audit0930Feed feed;
    Audit0930Feed uptime;
    ChainlinkPriceGte gte;
    ChainlinkPriceLte lte;
    ChainlinkTickFloorValidator tickFloor;
    PredicateStaticCall predicate;
    ConditionTreeValidator tree;
    FillerAttestationValidator av;
    TimestampValidator timeGate;
    Audit0930GasHog hog;

    uint8 constant NEGATE = 1;
    uint8 constant TRY = 2;
    uint256 constant GRACE = 1 hours;
    // Selectors spelled out (not `X.Err.selector`) so this suite also COMPILES
    // against the pre-fix sources — that is how "fails before the fix" is shown.
    bytes4 constant UNCAPPED_PROPORTIONAL = bytes4(keccak256("UncappedProportional()"));
    bytes4 constant SEQUENCER_DOWN = bytes4(keccak256("SequencerDown()"));
    bytes4 constant GRACE_NOT_OVER = bytes4(keccak256("GracePeriodNotOver()"));
    bytes4 constant PREDICATE_FAILED = bytes4(keccak256("PredicateFailed()"));

    function setUp() public override {
        super.setUp();
        feed = new Audit0930Feed();
        uptime = new Audit0930Feed();
        gte = new ChainlinkPriceGte();
        lte = new ChainlinkPriceLte();
        tickFloor = new ChainlinkTickFloorValidator();
        predicate = new PredicateStaticCall();
        tree = new ConditionTreeValidator();
        av = new FillerAttestationValidator();
        timeGate = new TimestampValidator();
        hog = new Audit0930GasHog();
        vm.warp(1_700_000_000);
    }

    function _withValidator(Order memory o, address target, bytes memory data) internal pure returns (Order memory) {
        Validator[] memory v = new Validator[](1);
        v[0] = Validator(target, data);
        o.validators = PackedEncode.validators(v);
        return o;
    }

    function _fund(uint256 inAmt, uint256 outAmt) internal {
        tA.mint(maker, inAmt);
        tB.mint(solver, outAmt);
        _makerApprove(address(settlement), address(tA), type(uint160).max);
        _solverApprove(address(settlement), address(tB), type(uint160).max);
    }

    function _leaf(address target, uint8 flags, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodePacked(flags, target, uint16(data.length), data);
    }

    function _tree1(bytes memory leaf) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(1), uint8(1), leaf);
    }

    // ──────────────────── X-ARITH-1.v1: tick floor × Proportional ────────────────────

    /// @dev SELL 100% of the maker's tA (cap 1000e18) for a fixed 2e18 tB, gated by a
    ///      zero-tolerance tick floor (num/den = 1/1e8): passes iff 2e18/in0 ≥ price.
    function _propTickOrder(uint256 nonce, uint256 cap) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), 1_000e18, 2e18);
        o.legsIn = PackedEncode.setLegInStart(o.legsIn, 0, Proportional.encode(10_000));
        o.legsIn = PackedEncode.setLegInEnd(o.legsIn, 0, cap);
        o = _withValidator(o, address(tickFloor), abi.encode(address(feed), uint256(1 hours), uint256(1), uint256(1e8)));
    }

    function test_audit_X_ARITH_1_v1_tickFloor_proportionalOrder_fills() public {
        _fund(1_000e18, 2e18);
        Order memory o = _propTickOrder(1, 1_000e18);
        bytes memory sig = _sign(o);
        feed.set(int256(0.0015e8), 0, block.timestamp); // market 1.5e15 < tick 2e15 → in limit

        vm.prank(solver);
        settlement.fill(o, sig, 1_000e18);
        assertEq(tA.balanceOf(solver), 1_000e18, "proportional sweep filled under the tick floor");
        assertEq(tB.balanceOf(maker), 2e18, "maker paid in full");
    }

    function test_audit_X_ARITH_1_v1_tickFloor_proportional_stillBlocksRunawayMarket() public {
        _fund(1_000e18, 2e18);
        Order memory o = _propTickOrder(2, 1_000e18);
        bytes memory sig = _sign(o);
        feed.set(int256(0.0025e8), 0, block.timestamp); // market 2.5e15 > tick 2e15

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.ValidationFailed.selector, uint256(0)));
        settlement.fill(o, sig, 1_000e18);
    }

    /// Priced at the CAP, never the live balance: sound in the invariant position too
    /// (where a balance read would see the post-sweep 0 and fail open).
    function test_audit_X_ARITH_1_v1_tickFloor_pricesAtCap_andRefusesUncapped() public {
        Order memory o = _propTickOrder(3, 1_000e18);
        bytes memory d = PackedEncode.getValidatorData(o.validators, 0);
        // maker holds NOTHING (as after the sweep): the cap still prices the check.
        feed.set(int256(0.0025e8), 0, block.timestamp);
        assertFalse(tickFloor.validate(o, solver, d, ""), "post-sweep zero balance does not fail open");
        feed.set(int256(0.002e8), 0, block.timestamp);
        assertTrue(tickFloor.validate(o, solver, d, ""), "at the cap rate passes");

        o.legsIn = PackedEncode.setLegInEnd(o.legsIn, 0, Proportional.SENTINEL_FLOOR);
        vm.expectRevert(UNCAPPED_PROPORTIONAL);
        tickFloor.validate(o, solver, d, "");
        o.legsIn = PackedEncode.setLegInEnd(o.legsIn, 0, 0);
        vm.expectRevert(UNCAPPED_PROPORTIONAL);
        tickFloor.validate(o, solver, d, "");
    }

    // ──────────────────── PRICE-8 / VAL-4: L2 sequencer uptime ────────────────────

    function _gteL2() internal view returns (bytes memory) {
        return abi.encode(address(feed), int256(1000e8), uint256(24 hours), address(uptime), GRACE);
    }

    function test_audit_PRICE_8_gte_sequencerDown_reverts() public {
        feed.set(1500e8, 0, block.timestamp - 3 hours); // frozen, inside the 24h heartbeat
        uptime.set(1, block.timestamp - 3 hours, block.timestamp); // sequencer DOWN
        Order memory o = _plainOrder(10, address(tA), address(tB), 1_000e18, 2e18);
        vm.expectRevert(SEQUENCER_DOWN);
        gte.validate(o, solver, _gteL2(), "");
    }

    function test_audit_PRICE_8_gte_withinGraceAfterRestart_reverts_thenPasses() public {
        feed.set(1500e8, 0, block.timestamp - 3 hours);
        uptime.set(0, block.timestamp - 10 minutes, block.timestamp); // up again, 10 min ago
        Order memory o = _plainOrder(11, address(tA), address(tB), 1_000e18, 2e18);
        vm.expectRevert(GRACE_NOT_OVER);
        gte.validate(o, solver, _gteL2(), "");

        vm.warp(block.timestamp + GRACE); // grace elapsed (and the feed still within 24h)
        assertTrue(gte.validate(o, solver, _gteL2(), ""), "past grace: fresh enough again");

        uptime.set(0, 0, block.timestamp); // uninitialised uptime round
        vm.expectRevert(GRACE_NOT_OVER);
        gte.validate(o, solver, _gteL2(), "");
    }

    /// The frozen-answer stop-loss of the VAL-4 scenario, through a real fill.
    function test_audit_VAL_4_lte_stopLoss_postRestart_blocksFill() public {
        _fund(1_000e18, 2e18);
        feed.set(900e8, 0, block.timestamp - 2 hours); // stale pre-outage answer at the stop
        uptime.set(0, block.timestamp - 5 minutes, block.timestamp); // just restarted
        Order memory o = _withValidator(
            _plainOrder(12, address(tA), address(tB), 1_000e18, 2e18),
            address(lte),
            abi.encode(address(feed), int256(1000e8), uint256(24 hours), address(uptime), GRACE)
        );
        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.ValidationFailed.selector, uint256(0)));
        settlement.fill(o, sig, 1_000e18);
        assertEq(tA.balanceOf(maker), 1_000e18, "stop-loss did not fire on the frozen answer");
    }

    function test_audit_PRICE_8_tickFloor_sequencerDown_reverts() public {
        Order memory o = _plainOrder(13, address(tA), address(tB), 1e18, 2_500e6);
        feed.set(int256(2_500e8), 0, block.timestamp);
        uptime.set(1, block.timestamp - 1 hours, block.timestamp);
        bytes memory d = abi.encode(address(feed), uint256(1 hours), uint256(1), uint256(1e20), address(uptime), GRACE);
        vm.expectRevert(SEQUENCER_DOWN);
        tickFloor.validate(o, solver, d, "");
    }

    /// Back-compat: a pre-existing blob (no trailing pair) and an explicit zero
    /// uptime feed both mean "no sequencer check".
    function test_audit_PRICE_8_legacyBlobAndZeroFeed_unchanged() public {
        feed.set(1500e8, 0, block.timestamp);
        uptime.set(1, block.timestamp, block.timestamp); // would be DOWN, but not consulted
        Order memory o = _plainOrder(14, address(tA), address(tB), 1_000e18, 2e18);
        assertTrue(gte.validate(o, solver, abi.encode(address(feed), int256(1000e8), uint256(1 hours)), ""));
        assertTrue(
            gte.validate(o, solver, abi.encode(address(feed), int256(1000e8), uint256(1 hours), address(0), GRACE), "")
        );
    }

    // ──────────────────── VAL-2: NEGATE over laundered failures / out-of-gas ────────────────────

    /// NOT(predicate) over a BROKEN predicate target used to evaluate TRUE.
    function test_audit_VAL_2_negatedPredicate_revertingTarget_isError() public {
        Audit0930Reverter r = new Audit0930Reverter();
        bytes memory pdata = abi.encode(address(r), abi.encodeCall(Audit0930Reverter.boom, ()));
        bytes memory t = _tree1(_leaf(address(predicate), NEGATE, pdata));
        Order memory o = _plainOrder(20, address(tA), address(tB), 1_000e18, 2e18);
        vm.expectRevert(ConditionTreeValidator.ConditionErrored.selector);
        tree.validate(o, solver, t, "");

        // …and through a fill it blocks rather than opens the order.
        _fund(1_000e18, 2e18);
        o = _withValidator(o, address(tree), t);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.ValidationFailed.selector, uint256(0)));
        settlement.fill(o, sig, 1_000e18);
    }

    /// Codeless / short-returning targets are errors too (were a clean `false`).
    function test_audit_VAL_2_predicate_codelessOrShort_reverts() public {
        Order memory o = _plainOrder(21, address(tA), address(tB), 1_000e18, 2e18);
        vm.expectRevert(PREDICATE_FAILED);
        predicate.validate(o, solver, abi.encode(address(0xC0DE1E55), hex"12345678"), "");
    }

    function _negatedTreeCall(bytes memory t, uint256 gasLimit) internal view returns (bool ok, bool passed) {
        Order memory o = _plainOrder(22, address(tA), address(tB), 1_000e18, 2e18);
        bytes memory ret;
        (ok, ret) =
            address(tree).staticcall{gas: gasLimit}(abi.encodeCall(IOrderValidator.validate, (o, solver, t, "")));
        passed = ok && ret.length >= 32 && abi.decode(ret, (bool));
    }

    /// Filler-forced out-of-gas on a TRY|NEGATE leaf used to read as `false` → TRUE.
    function test_audit_VAL_2_tryNegateLeaf_outOfGas_neverPasses() public view {
        bytes memory t = _tree1(_leaf(address(hog), TRY | NEGATE, ""));
        (bool okFull, bool passedFull) = _negatedTreeCall(t, 30_000_000);
        assertTrue(okFull && !passedFull, "with enough gas: NOT(true) = false");
        for (uint256 g = 200_000; g <= 2_000_000; g += 200_000) {
            (, bool passed) = _negatedTreeCall(t, g);
            assertFalse(passed, "a starved leaf must never make NOT(leaf) pass");
        }
    }

    /// Same lever one hop deeper: the predicate's INNER call starved.
    function test_audit_VAL_2_negatedPredicate_innerOutOfGas_neverPasses() public view {
        bytes memory pdata = abi.encode(address(hog), abi.encodeCall(Audit0930GasHog.burn, (20_000)));
        bytes memory t = _tree1(_leaf(address(predicate), NEGATE, pdata));
        (bool okFull, bool passedFull) = _negatedTreeCall(t, 30_000_000);
        assertTrue(okFull && !passedFull, "with enough gas: NOT(true) = false");
        for (uint256 g = 200_000; g <= 2_000_000; g += 200_000) {
            (, bool passed) = _negatedTreeCall(t, g);
            assertFalse(passed, "a starved predicate must never make NOT(predicate) pass");
        }
    }

    /// A starved 1271 attester is an out-of-gas, not a `false` the filler can pick.
    function test_audit_VAL_2_attestation_1271OutOfGas_propagates() public {
        Audit0930GasHogAttester att = new Audit0930GasHogAttester();
        Order memory o = _plainOrder(23, address(tA), address(tB), 1_000e18, 2e18);
        bytes memory data = abi.encode(address(att), uint256(7), uint256(0));
        bytes memory takerData = abi.encode(block.timestamp + 1 hours, new bytes(70));
        (bool okFull, bytes memory retFull) = address(av).staticcall{gas: 30_000_000}(
            abi.encodeCall(IOrderValidator.validate, (o, solver, data, takerData))
        );
        assertTrue(okFull && abi.decode(retFull, (bool)), "with enough gas the attester accepts");
        (bool ok,) =
            address(av).staticcall{gas: 300_000}(abi.encodeCall(IOrderValidator.validate, (o, solver, data, takerData)));
        assertFalse(ok, "starved: the validator call fails rather than answering false");
    }

    // ──────────────────── VAL-6: malformed takerData is "no credential" ────────────────────

    function test_audit_VAL_6_malformedTakerData_returnsFalse() public view {
        Order memory o = _plainOrder(30, address(tA), address(tB), 1_000e18, 2e18);
        bytes memory data = abi.encode(address(0xA77E57), uint256(7), uint256(0));
        // packed CosignedQuote-style blob: filler(20) ‖ bumpBps(32) ‖ deadline(32) ‖ sig(65)
        bytes memory quote = abi.encodePacked(solver, uint256(500), uint256(block.timestamp + 60), new bytes(65));
        assertFalse(av.validate(o, solver, data, quote), "foreign blob: false, no revert");
        assertFalse(av.validate(o, solver, data, hex"01"), "short blob: false");
        assertFalse(av.validate(o, solver, data, abi.encode(uint256(1), uint256(type(uint256).max))), "huge offset");
        assertFalse(
            av.validate(o, solver, data, abi.encode(uint256(block.timestamp + 1), uint256(0x40), uint256(1000))),
            "length past the end"
        );
    }

    /// The composability failure itself: `(attested) OR (timestamp)` with a foreign
    /// takerData used to abort with ConditionErrored before group 2 was reached.
    function test_audit_VAL_6_treeOrGroup_reachableWithForeignTakerData() public view {
        Order memory o = _plainOrder(31, address(tA), address(tB), 1_000e18, 2e18);
        bytes memory g1 =
            abi.encodePacked(uint8(1), _leaf(address(av), 0, abi.encode(address(0xA77E57), uint256(7), uint256(0))));
        bytes memory g2 =
            abi.encodePacked(uint8(1), _leaf(address(timeGate), 0, abi.encode(block.timestamp - 1, uint256(0))));
        bytes memory t = abi.encodePacked(uint8(2), g1, g2);
        bytes memory quote = abi.encodePacked(solver, uint256(500), uint256(block.timestamp + 60), new bytes(65));
        assertTrue(tree.validate(o, solver, t, quote), "group 2 satisfies the expression");
    }
}
