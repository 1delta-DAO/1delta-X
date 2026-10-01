// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {MockSettlementBase, MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";

import {Base} from "@core/settlement/Base.sol";
import {Order, Item, ItemOp, Validator} from "@core/settlement/Settlement.sol";

import {OcoGroupModule} from "../src/OcoGroupModule.sol";
import {ChainlinkPriceLte} from "@validators/ChainlinkPriceValidators.sol";

/// @dev Chainlink-shaped feed the test moves (external to the protocol).
contract AuditOcoFeed {
    int256 public answer;
    uint256 public updatedAt;

    function set(int256 a) external {
        answer = a;
        updatedAt = block.timestamp;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @title Audit20260930OcoTest
/// @notice Regression for audit 2026-09-30 PRICE-2 (OCO dust-kill): an unprivileged
///         EOA used to retire a maker's stop-loss for ~gas by filling 1 wei of the
///         untriggered take-profit. The claim item now carries a maker-signed
///         `minClaim`; the claiming fill must be at least that big.
contract Audit20260930OcoTest is MockSettlementBase {
    uint256 constant SIZE = 10e18; //        10 "WETH" per leg (the anchor)
    uint256 constant TP_OUT = 35_000e6; //   take-profit at 3,500
    uint256 constant SL_OUT = 29_000e6; //   stop-loss floor at 2,900
    int256 constant SL_TRIGGER = 3_000e8; // stop fires when ETH <= 3,000
    uint256 constant MIN_CLAIM = 1e18; //    10% of the leg retires the siblings

    uint256 constant GROUP = uint256(keccak256("bracket-1"));
    uint256 constant TP_NONCE = 11;
    uint256 constant SL_NONCE = 12;

    OcoGroupModule oco;
    ChainlinkPriceLte lte;
    AuditOcoFeed feed;

    address attacker = makeAddr("attacker");

    function setUp() public override {
        super.setUp();
        oco = new OcoGroupModule(address(settlement));
        lte = new ChainlinkPriceLte();
        feed = new AuditOcoFeed();
        vm.warp(1_800_000_000);
        feed.set(3_200e8);

        tA.mint(maker, SIZE);
        _makerApprove(address(settlement), address(tA), type(uint160).max);

        tB.mint(solver, 1_000_000e6);
        _solverApprove(address(settlement), address(tB), type(uint160).max);

        tB.mint(attacker, 1_000_000e6);
        vm.startPrank(attacker);
        MockERC20(address(tB)).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(tB), type(uint160).max, 0);
        vm.stopPrank();
    }

    function _leg(Order memory o, Validator memory trigger, bool hasTrigger, bytes memory claimData)
        internal
        view
        returns (Order memory)
    {
        Validator[] memory v = new Validator[](hasTrigger ? 2 : 1);
        uint256 k;
        if (hasTrigger) v[k++] = trigger;
        v[k] = Validator({target: address(oco), data: abi.encode(GROUP)});
        o.validators = PackedEncode.validators(v);

        Item[] memory items = new Item[](1);
        items[0] = Item({op: ItemOp.SETTLE, module: address(oco), amount: SIZE, recipient: address(0), data: claimData});
        o.items = PackedEncode.items(items);
        return o;
    }

    function _bracket(uint256 minClaim) internal view returns (Order memory tp, Order memory sl) {
        Validator memory none;
        tp = _leg(
            _plainOrder(TP_NONCE, address(tA), address(tB), SIZE, TP_OUT),
            none,
            false,
            abi.encode(GROUP, TP_NONCE, minClaim)
        );
        _setExpiry(tp, block.timestamp + 30 days);
        Validator memory stop =
            Validator({target: address(lte), data: abi.encode(address(feed), SL_TRIGGER, uint256(1 hours))});
        sl = _leg(
            _plainOrder(SL_NONCE, address(tA), address(tB), SIZE, SL_OUT),
            stop,
            true,
            abi.encode(GROUP, SL_NONCE, minClaim)
        );
        _setExpiry(sl, block.timestamp + 30 days);
    }

    /// The PoC's attack, end to end: the 1-wei take-profit fill is refused, the
    /// group stays open, and after the crash the stop-loss executes at its floor.
    function test_audit_PRICE_2_dustFillCannotRetireStopLoss() public {
        (Order memory tp, Order memory sl) = _bracket(MIN_CLAIM);
        bytes memory tpSig = _sign(tp);
        bytes memory slSig = _sign(sl);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("ClaimTooSmall(uint256,uint256)", uint256(1), MIN_CLAIM));
        settlement.fill(tp, tpSig, 1);

        // Just under the floor is refused too.
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSignature("ClaimTooSmall(uint256,uint256)", MIN_CLAIM - 1, MIN_CLAIM));
        settlement.fill(tp, tpSig, MIN_CLAIM - 1);

        assertEq(oco.claim(maker, GROUP), 0, "group still unclaimed");
        assertFalse(oco.isRetiredFor(maker, GROUP, SL_NONCE), "stop-loss still live");

        vm.warp(block.timestamp + 1 days);
        feed.set(2_500e8);
        vm.prank(solver);
        settlement.fill(sl, slSig, SIZE);
        assertEq(tB.balanceOf(maker), SL_OUT, "maker exited at the signed stop-loss floor");
        assertEq(tA.balanceOf(maker), 0, "all WETH sold");
    }

    /// A claim at the floor is a real trade at the maker's price and does retire the
    /// siblings; the winner's later slices may then be any size (they write nothing).
    function test_audit_PRICE_2_claimAtFloor_thenWinnerFillsFreely() public {
        (Order memory tp, Order memory sl) = _bracket(MIN_CLAIM);
        bytes memory tpSig = _sign(tp);
        bytes memory slSig = _sign(sl);

        vm.prank(attacker);
        settlement.fill(tp, tpSig, MIN_CLAIM);
        assertEq(oco.claim(maker, GROUP), TP_NONCE + 1, "claimed by a floor-sized fill");
        assertEq(tB.balanceOf(maker), TP_OUT / 10, "maker was paid its take-profit price for the claim");

        vm.prank(solver);
        settlement.fill(tp, tpSig, 1); // dust slices of the WINNER are fine
        assertEq(settlement.filled(_hashOrder(tp)), MIN_CLAIM + 1);

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.ValidationFailed.selector, uint256(0)));
        settlement.fill(sl, slSig, SIZE);
    }

    /// The floor is mandatory: a leg with `minClaim == 0`, the legacy two-word blob,
    /// or a floor above the item amount fails closed at validation.
    function test_audit_PRICE_2_missingOrUnreachableFloor_failsClosed() public {
        _assertRefused(abi.encode(GROUP, TP_NONCE, uint256(0)), 0); //  floor unset
        _assertRefused(abi.encode(GROUP, TP_NONCE), 1); //              legacy two-word blob
        _assertRefused(abi.encode(GROUP, TP_NONCE, SIZE + 1), 2); //    floor above the item
        assertEq(oco.claim(maker, GROUP), 0);
    }

    function _assertRefused(bytes memory blob, uint256 salt) internal {
        Validator memory none;
        Order memory tp = _leg(_plainOrder(TP_NONCE, address(tA), address(tB), SIZE, TP_OUT), none, false, blob);
        _setExpiry(tp, block.timestamp + 30 days + salt);
        assertFalse(oco.validate(tp, attacker, abi.encode(GROUP), ""), "unfloored leg refused");
        bytes memory sig = _sign(tp);
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.ValidationFailed.selector, uint256(0)));
        settlement.fill(tp, sig, SIZE);
    }
}
