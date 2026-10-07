// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order, Item, ItemOp, ItemPolicy, LegIn} from "@core/settlement/Structs.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {ITakerForModule} from "@core/interfaces/ITakerForModule.sol";
import {IFundingSource} from "@core/interfaces/IFundingSource.sol";
import {IProceedsAsset} from "@core/interfaces/IProceedsAsset.sol";
import {SettlementLens} from "@periphery/SettlementLens.sol";
import {FundingPreflight} from "@lib/FundingPreflight.sol";

import {ListaSmartTakerModule} from "@modules/lending/lista/src/ListaSmartModules.sol";
import {MarketParams} from "@modules/lending/lista/src/interfaces/ILista.sol";
import {ExactlyTakerModule} from "@modules/lending/exactly/src/ExactlyModules.sol";

import {MockSettlementBase, MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

/// @dev The SmartProvider's `dex()` and the pool's `coins(i)` — the two reads
///      {ListaSmartTakerModule.proceedsAsset} goes through. Nothing else is called by
///      the lens.
contract MockSmartDex1006 {
    address[2] public roster;

    constructor(address c0, address c1) {
        roster = [c0, c1];
    }

    function coins(uint256 i) external view returns (address) {
        require(i < 2, "Invalid token index");
        return roster[i];
    }
}

contract MockSmartProvider1006 {
    address public dex;

    constructor(address d) {
        dex = d;
    }
}

/// @dev A PULL-funded composite (TAKE_FOR) module shaped like the real ones: its
///      funding preflight is {FundingPreflight.pullable} — `min(book, wallet, ERC-20
///      approval to Permit3)` — read BEFORE the fill delivers the leg it funds from.
contract MockPullTakeFor1006 is ITakerForModule, IFundingSource, IProceedsAsset {
    IPermit3 public immutable permit3;

    constructor(address _permit3) {
        permit3 = IPermit3(_permit3);
    }

    function takeForOnBehalf(address, address onBehalfOf, uint256 amount, uint256 forAmount, address receiver, bytes calldata data)
        external
        override
    {
        require(msg.sender == address(permit3), "only permit3");
        (, address fundingToken, address proceedsToken) = abi.decode(data, (uint256, address, address));
        if (forAmount != 0) permit3.transferFrom(onBehalfOf, address(this), fundingToken, uint160(forAmount));
        MockERC20(proceedsToken).transfer(receiver, amount);
    }

    function fundingSource(address onBehalfOf, bytes calldata data)
        external
        view
        override
        returns (address asset, uint256 available)
    {
        (, asset,) = abi.decode(data, (uint256, address, address));
        available = FundingPreflight.pullable(permit3, address(this), onBehalfOf, asset);
    }

    function proceedsAsset(bytes calldata data) external pure override returns (address asset) {
        (,, asset) = abi.decode(data, (uint256, address, address));
    }
}

/// @dev A TAKE module that only names its proceeds asset — all the B8 rule reads.
contract ProceedsOnlyTake1006 is IProceedsAsset {
    address public immutable ASSET;

    constructor(address a) {
        ASSET = a;
    }

    function proceedsAsset(bytes calldata) external view override returns (address) {
        return ASSET;
    }
}

/// @title Review 2026-10-06 — lens rules for tasks 11, 12 and 13 (item 1)
/// @notice 11: a Lista SmartLP withdraw whose LP-unit rate floor does not cover its
///         coin-unit input leg is malformed; the coin is resolved through the provider.
///         12: a pre-maturity Exactly fixed withdraw with `minAssetsRequired == 0` is
///         malformed. 13.1: a pull leg-reference previews as funded by the fill's own
///         delivery. Both module rules are recognised by {ITakeFloor} answering — the
///         REAL module contracts are used, against mock venues the lens reads.
contract Review20261006LensTest is MockSettlementBase {
    uint256 constant IN_ = 1_000e18;
    uint256 constant OUT_ = 2_500e18;
    uint256 constant LP = 1_000e18; //   LP units burned (item.amount)
    address constant MOOLAH = address(0x3001);
    string constant FLOOR_WHY = "item proceeds floor does not bound the wallet draw on its input leg";

    ListaSmartTakerModule listaTaker;
    ExactlyTakerModule exactlyTaker;
    MockSmartProvider1006 provider;
    MockPullTakeFor1006 pullTakeFor;

    function setUp() public override {
        super.setUp();
        listaTaker = new ListaSmartTakerModule(address(permit3));
        exactlyTaker = new ExactlyTakerModule(address(permit3));
        // Pool roster [tA, tC]: coin 0 is the maker's input-leg token.
        provider = new MockSmartProvider1006(address(new MockSmartDex1006(address(tA), address(tC))));
        pullTakeFor = new MockPullTakeFor1006(address(permit3));
    }

    // ──────────────────── helpers ────────────────────

    function _item(ItemOp op, address module, uint256 amount, bytes memory data) internal pure returns (bytes memory) {
        Item[] memory its = new Item[](1);
        its[0] = Item({op: op, module: module, amount: amount, recipient: address(0), data: data});
        return PackedEncode.items(its);
    }

    function _listaData(uint256 coinIndex, uint256 rate) internal view returns (bytes memory) {
        MarketParams memory mp = MarketParams(address(tB), address(0x4001), address(0x4002), address(0x4003), 0.9e18);
        return abi.encode(address(provider), MOOLAH, coinIndex, rate, mp);
    }

    /// SELL tA (IN_) for tB; the tA is produced by a Lista one-coin withdraw of `LP`.
    function _listaOrder(uint256 nonce, uint256 coinIndex, uint256 rate) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), IN_, OUT_);
        o.items = _item(ItemOp.TAKE, address(listaTaker), LP, _listaData(coinIndex, rate));
    }

    function _exactlyData(uint256 op, uint256 maturity, uint256 bound) internal view returns (bytes memory) {
        return abi.encode(uint8(op), address(0x5001), address(tA), maturity, bound, IN_);
    }

    function _exactlyOrder(uint256 nonce, uint256 op, uint256 maturity, uint256 bound)
        internal
        view
        returns (Order memory o)
    {
        o = _plainOrder(nonce, address(tA), address(tB), IN_, OUT_);
        o.items = _item(ItemOp.TAKE, address(exactlyTaker), IN_, _exactlyData(op, maturity, bound));
    }

    /// An input-funding TAKE passes only under CANONICAL (B8, 2026-10-06).
    function _canonical(Order memory o) internal pure returns (Order memory) {
        o.timing = ItemPolicy.pack(o.timing, ItemPolicy.CANONICAL);
        return o;
    }

    function _assertOk(Order memory o, string memory label) internal view {
        (bool ok, string memory why) = lens.validateOrder(o);
        assertTrue(ok, string.concat(label, ": ", why));
    }

    function _assertFlag(Order memory o, string memory reason) internal view {
        (bool ok, string memory why) = lens.validateOrder(o);
        assertFalse(ok, "flagged");
        assertEq(why, reason);
    }

    // ═══════════ task 11: Lista SmartLP — LP-unit item, coin-unit leg ═══════════

    function test_lista_proceedsAsset_isTheProviderCoin() public view {
        assertEq(listaTaker.proceedsAsset(_listaData(0, 1e18)), address(tA), "coin 0 through provider.dex()");
        assertEq(listaTaker.proceedsAsset(_listaData(1, 1e18)), address(tC), "coin 1");
    }

    /// The signed floor `LP · rate / 1e18` below `legsIn[0].start` is a wallet draw.
    function test_lista_rateFloorBelowLeg_flagged() public view {
        _assertFlag(_listaOrder(1, 0, 0.9e18), FLOOR_WHY); //       900e18 < 1000e18
        _assertFlag(_listaOrder(2, 0, 1e18 - 1), FLOOR_WHY); //     one wei short
        _assertFlag(_listaOrder(3, 0, 0), FLOOR_WHY); //            no floor at all
    }

    function test_lista_rateFloorAtOrAboveLeg_passes() public view {
        _assertOk(_canonical(_listaOrder(4, 0, 1e18)), "at the leg");
        _assertOk(_canonical(_listaOrder(5, 0, 1.05e18)), "above the leg");
    }

    /// The coin the provider pays is not `legsIn[0].token`: with no leg in that coin
    /// the stranded-proceeds preflight (now running for this module) names it; with
    /// the coin on a LATER leg the floor rule names it (the floor bridges leg 0).
    function test_lista_coinMismatch_flagged() public view {
        _assertFlag(_listaOrder(6, 1, 1.05e18), "item delivers a token no input leg can consume");

        Order memory o = _listaOrder(7, 1, 1.05e18);
        LegIn[] memory legs = new LegIn[](2);
        legs[0] = LegIn(address(tA), IN_, 0);
        legs[1] = LegIn(address(tC), 1, 0);
        o.legsIn = PackedEncode.legsIn(legs);
        _assertFlag(o, FLOOR_WHY);
    }

    /// A rate whose multiply overflows reverts every fill; the module reports it
    /// rather than reverting the preflight.
    function test_lista_overflowingRate_flagged() public view {
        _assertFlag(_listaOrder(8, 0, type(uint256).max), FLOOR_WHY);
    }

    /// Routed away from the settler (`recipient != 0`), nothing is measured, so the
    /// rule does not apply — same gate as the proceeds-asset check.
    function test_lista_recipientMaker_notChecked() public view {
        Order memory o = _plainOrder(9, address(tA), address(tB), IN_, OUT_);
        Item[] memory its = new Item[](1);
        its[0] = Item({op: ItemOp.TAKE, module: address(listaTaker), amount: LP, recipient: maker, data: _listaData(0, 0)});
        o.items = PackedEncode.items(its);
        _assertOk(o, "recipient maker");
    }

    // ═══════════ task 12: Exactly pre-maturity fixed withdraw ═══════════

    function test_exactly_preMaturityWithdraw_zeroFloor_flagged() public view {
        _assertFlag(_exactlyOrder(20, 1, block.timestamp + 30 days, 0), FLOOR_WHY);
    }

    /// A non-zero floor passes even below the leg: the discount is legitimate and the
    /// maker signs the draw they accept (`owed − minAssetsRequired`).
    function test_exactly_preMaturityWithdraw_nonZeroFloor_passes() public view {
        _assertOk(_exactlyOrder(21, 1, block.timestamp + 30 days, IN_ * 99 / 100), "floored");
        _assertOk(_exactlyOrder(22, 1, block.timestamp + 30 days, 1), "any non-zero floor");
    }

    function test_exactly_otherBranches_zeroBound_pass() public {
        _assertOk(_exactlyOrder(23, 1, 0, 0), "floating withdraw");
        _assertOk(_exactlyOrder(24, 0, block.timestamp + 30 days, 0), "fixed borrow");
        _assertOk(_exactlyOrder(25, 1, block.timestamp, 0), "at maturity");
        // Time-dependent: the same order stops being flagged once maturity passes.
        Order memory o = _exactlyOrder(26, 1, block.timestamp + 1 hours, 0);
        o.timing = _expiryBits(block.timestamp + 2 days);
        _assertFlag(o, FLOOR_WHY);
        vm.warp(block.timestamp + 1 hours);
        _assertOk(o, "matured");
    }

    // ═══════════ task 13 item 1: pull leg-ref funded by the fill's own delivery ═══════════

    function _pullOrder(uint256 nonce) internal view returns (Order memory o, bytes memory data) {
        data = abi.encode((uint256(1) << 255) | 0, address(tB), address(tA)); // fund from legsOut[0]
        o = _plainOrder(nonce, address(tA), address(tB), IN_, OUT_);
        o.items = _item(ItemOp.TAKE_FOR, address(pullTakeFor), IN_, data);
    }

    function _grant(bytes memory data, uint256 fundCap) internal {
        vm.startPrank(maker);
        tB.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(pullTakeFor), address(tB), uint160(fundCap), 0);
        permit3.approveTaker(address(settlement), address(pullTakeFor), keccak256(data), uint160(IN_), 0);
        vm.stopPrank();
    }

    /// The maker holds NO tB: the fill delivers OUT_ tB to the maker, then the module
    /// pulls it. The preview used to read the empty wallet and report 0.
    function test_pullLegRef_previewsFundedByItsOwnDelivery_andFills() public {
        (Order memory o, bytes memory data) = _pullOrder(30);
        _grant(data, type(uint160).max);
        assertEq(tB.balanceOf(maker), 0, "wallet empty");

        SettlementLens.ItemFunding memory f = lens.previewItemFunding(o);
        assertEq(f.required[0], OUT_);
        assertEq(f.available[0], OUT_, "the delivery counts");

        // Predictive: it fills.
        tA.mint(address(pullTakeFor), IN_);
        tB.mint(solver, OUT_);
        _solverApprove(address(settlement), address(tB), type(uint160).max);
        bytes memory sig = _sign(o);
        vm.prank(solver);
        settlement.fill(o, sig, IN_);
        assertEq(tB.balanceOf(address(pullTakeFor)), OUT_, "funded from the delivery");
        assertEq(tA.balanceOf(solver), IN_, "solver paid by the take");
    }

    /// The lift keeps the other two Permit3 caps: a short book, a lapsed book, and a
    /// revoked ERC-20 approval to Permit3 each still read short.
    function test_pullLegRef_liftKeepsBookAndApprovalCaps() public {
        (Order memory o, bytes memory data) = _pullOrder(31);
        _grant(data, OUT_ / 2);
        assertEq(lens.previewItemFunding(o).available[0], OUT_ / 2, "book binds");

        vm.prank(maker);
        permit3.approveToken(address(pullTakeFor), address(tB), type(uint160).max, uint48(block.timestamp + 1));
        assertEq(lens.previewItemFunding(o).available[0], OUT_, "live book");
        vm.warp(block.timestamp + 2);
        assertEq(lens.previewItemFunding(o).available[0], 0, "lapsed book funds nothing");

        vm.startPrank(maker);
        permit3.approveToken(address(pullTakeFor), address(tB), type(uint160).max, 0);
        tB.approve(address(permit3), OUT_ / 4);
        vm.stopPrank();
        assertEq(lens.previewItemFunding(o).available[0], OUT_ / 4, "ERC-20 approval to Permit3 binds");
    }

    /// A leg in another token than the module's funding asset is not lifted (the
    /// delivery does not fund it) — and `validateOrder` names that order anyway.
    function test_pullLegRef_otherTokenLeg_notLifted() public {
        bytes memory data = abi.encode((uint256(1) << 255) | 0, address(tC), address(tA));
        Order memory o = _plainOrder(32, address(tA), address(tB), IN_, OUT_);
        o.items = _item(ItemOp.TAKE_FOR, address(pullTakeFor), IN_, data);
        vm.startPrank(maker);
        tC.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(pullTakeFor), address(tC), type(uint160).max, 0);
        vm.stopPrank();
        assertEq(lens.previewItemFunding(o).available[0], 0);
    }

    // ═══════════ ACCEPTED-PATTERNS-REVIEW B8: late TAKE on an input-leg token ═══════════
    //
    // A TAKE that credits an input leg, signed below CANONICAL, lets any `matchSettle`
    // caller PULL that leg first — the maker's Permit3 allowance is spent twice for
    // one fill. The core behaviour is pinned in
    // `AggregatorAmountMismatch.t.sol::test_S2_lateTakeOnInputToken_burnsTheMakerAllowance`.

    string constant B8_WHY = "input-funding TAKE needs ItemPolicy.CANONICAL (late TAKE spends the allowance twice)";

    /// SELL tA for tB; one TAKE whose proceeds (`asset`) go to `to`, signed at `policy`.
    function _b8Order(uint256 nonce, address asset, address to, uint256 policy) internal returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), IN_, OUT_);
        Item[] memory its = new Item[](1);
        its[0] = Item({op: ItemOp.TAKE, module: address(new ProceedsOnlyTake1006(asset)), amount: IN_, recipient: to, data: ""});
        o.items = PackedEncode.items(its);
        o.timing = ItemPolicy.pack(o.timing, policy);
    }

    function test_B8_inputFundingTake_belowCanonical_flagged() public {
        _assertFlag(_b8Order(40, address(tA), address(0), ItemPolicy.ANY), B8_WHY);
        _assertFlag(_b8Order(41, address(tA), address(settlement), ItemPolicy.ANY), B8_WHY);
        // ORDERED / ATOMIC order the items among themselves; the PULL stays free.
        _assertFlag(_b8Order(42, address(tA), address(0), ItemPolicy.ORDERED), B8_WHY);
        _assertFlag(_b8Order(43, address(tA), address(0), ItemPolicy.ATOMIC), B8_WHY);
    }

    function test_B8_inputFundingTake_canonical_passes() public {
        _assertOk(_b8Order(44, address(tA), address(0), ItemPolicy.CANONICAL), "canonical");
    }

    /// The input token on a LATER leg (a rising fee leg) is still an input leg.
    function test_B8_inputFundingTake_laterLeg_flagged() public {
        Order memory o = _b8Order(45, address(tC), address(0), ItemPolicy.ANY);
        LegIn[] memory legs = new LegIn[](2);
        legs[0] = LegIn(address(tA), IN_, 0);
        legs[1] = LegIn(address(tC), 1, 0);
        o.legsIn = PackedEncode.legsIn(legs);
        _assertFlag(o, B8_WHY);
    }

    /// No false positives: a TAKE in an OUTPUT-only token routed to the maker (borrow
    /// after the deposit), an input-token TAKE routed to the maker, and a module that
    /// cannot name its proceeds are all left alone at ANY.
    function test_B8_noFalsePositives() public {
        _assertOk(_b8Order(46, address(tB), maker, ItemPolicy.ANY), "output-token borrow to the maker");
        _assertOk(_b8Order(47, address(tA), maker, ItemPolicy.ANY), "input-token take to the maker");
        Order memory o = _plainOrder(48, address(tA), address(tB), IN_, OUT_);
        Item[] memory its = new Item[](1);
        its[0] = Item({op: ItemOp.TAKE, module: address(0xdead), amount: IN_, recipient: address(0), data: ""});
        o.items = PackedEncode.items(its);
        _assertOk(o, "silent module");
        // A plain order with no items at all.
        _assertOk(_plainOrder(49, address(tA), address(tB), IN_, OUT_), "no items");
    }

    /// TAKE_FOR is exempt: `matchSettle` refuses any order carrying one, so no
    /// schedule can put a PULL ahead of it.
    function test_B8_takeFor_notFlagged() public view {
        (Order memory o,) = _pullOrder(50);
        _assertOk(o, "TAKE_FOR at ANY");
    }
}
