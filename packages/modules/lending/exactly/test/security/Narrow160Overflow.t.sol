// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order, Item, ItemOp, LegIn, LegOut} from "@core/settlement/Settlement.sol";
import {Settlement} from "@core/settlement/Settlement.sol";
import {Permit3} from "@core/permit3/Permit3.sol";
import {SettlementLens} from "@periphery/SettlementLens.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";
import {Narrow160} from "@lib/Narrow160.sol";

import {ExactlyRepayModule} from "../../src/ExactlyModules.sol";

/// @dev Minimal ERC-20 with uint256 balances, so the maker can hold more than
///      2^160 - 1 and the at-max boundary fill can actually settle.
contract WideToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Exactly Market stand-in for the fixed-pool repay: takes exactly the face
///      `positionAssets` from the caller and ignores the rest of the approval,
///      so the module's pulled surplus is left for its residual sweep.
contract MockFixedMarket {
    uint256 public calls;

    function repayAtMaturity(uint256, uint256 positionAssets, uint256, address) external returns (uint256) {
        calls++;
        WideToken(_asset).transferFrom(msg.sender, address(this), positionAssets);
        return positionAssets;
    }

    address internal _asset;

    constructor(address asset_) {
        _asset = asset_;
    }
}

/// @title ExactlyNarrow160OverflowTest
/// @notice Pins the {Narrow160} guard at the FIXED-maturity branch of
///         {ExactlyRepayModule._pullAndRepay}:
///
///             permit3.transferFrom(onBehalfOf, address(this), asset, Narrow160.to160(maxAssets));
///             SafeTransferLib.forceApprove(asset, market, maxAssets);
///
///  `maxAssets` is decoded from the MAKER-SIGNED item `data` (word at offset 96), not from
///  the core slice — the core's `slice > type(uint160).max` check never sees it.
///  On a full fill (`slice == totalAmount` at offset 160) {ProratedBound.scale} returns it
///  unchanged, so a signed `maxAssets = 2^160` reaches the narrowing verbatim.
///  Before the guard a bare `uint160(maxAssets)` clipped the pull to 0 while the
///  venue approve kept the full 2^160: the drain shape the guard closed.
///
///  Entry path: the real `Settlement.fill` (signed order, MAKE item → module →
///  real Permit3). No fork: this harness overrides {CoreSettlementBase.setUp} and
///  deploys Permit3 + Settlement against local mock tokens / market, reusing only
///  the base's order builders and EIP-712 signer.
contract ExactlyNarrow160OverflowTest is CoreSettlementBase {
    ExactlyRepayModule internal repay;
    MockFixedMarket internal market;
    WideToken internal debtToken; //  the repaid asset (the site's `asset`)
    WideToken internal feeToken; //   the order's fill-denominator input leg

    uint256 internal constant MATURITY = 1_800_000_000;
    uint256 internal constant FACE = 1_000e6; //   item amount == face repaid
    uint256 internal constant LEG = 1e6; //       fixed input leg, the fill anchor
    uint32 internal constant DURATION = 1000;

    function setUp() public override {
        // Deliberately NOT super.setUp(): that forks mainnet. Same deployments, local.
        permit3 = new Permit3();
        settlement = new Settlement(address(permit3));
        lens = new SettlementLens(address(settlement));

        debtToken = new WideToken();
        feeToken = new WideToken();
        market = new MockFixedMarket(address(debtToken));
        repay = new ExactlyRepayModule(address(permit3), address(settlement));

        vm.label(address(repay), "exactlyRepay");
        vm.label(address(market), "market");
        vm.label(address(debtToken), "debtToken");
        vm.label(address(feeToken), "feeToken");

        // Maker holds MORE than 2^160 - 1 so the at-max boundary is funded.
        debtToken.mint(maker, uint256(type(uint160).max) + FACE);
        feeToken.mint(maker, LEG);

        vm.startPrank(maker);
        debtToken.approve(address(permit3), type(uint256).max);
        feeToken.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(repay), address(debtToken), type(uint160).max, 0);
        permit3.approveToken(address(settlement), address(feeToken), type(uint160).max, 0);
        vm.stopPrank();
    }

    /// @dev Fixed-branch repay data: (market, asset, maturity, maxAssets, DustAction, totalAmount).
    function _repayData(uint256 maxAssets) internal view returns (bytes memory) {
        return abi.encode(address(market), address(debtToken), MATURITY, maxAssets, uint256(0), FACE);
    }

    function _order(uint256 nonce, uint256 maxAssets) internal view returns (Order memory) {
        Item[] memory items = new Item[](1);
        items[0] = Item({
            op: ItemOp.MAKE, module: address(repay), amount: FACE, recipient: address(0), data: _repayData(maxAssets)
        });
        LegIn[] memory legsIn = new LegIn[](1);
        legsIn[0] = LegIn(address(feeToken), LEG, 0); // end == 0 ⇒ fixed
        return Order({
            params: 0,
            pricingModule: address(0),
            maker: maker,
            nonce: nonce,
            legsIn: PackedEncode.legsIn(legsIn),
            legsOut: PackedEncode.legsOut(new LegOut[](0)),
            timing: _packTiming(uint32(block.timestamp), DURATION, 0) | _expiryBits(block.timestamp + 1 hours),
            exclusiveFiller: address(0),
            minFillAnchor: 0,
            curve: PackedEncode.noCurve(),
            items: PackedEncode.items(items),
            validators: PackedEncode.noValidators(),
            invariants: PackedEncode.noValidators(),
            fillModule: address(0),
            fillTotal: 0
        });
    }

    struct Snap {
        uint256 makerDebt;
        uint256 moduleDebt;
        uint256 marketDebt;
        uint256 settlementDebt;
        uint256 solverFee;
        uint256 makerFee;
        uint160 repayAllowance;
        uint160 settlementAllowance;
        uint256 moduleToMarketApproval;
        uint256 marketCalls;
    }

    function _snap() internal view returns (Snap memory s) {
        s.makerDebt = debtToken.balanceOf(maker);
        s.moduleDebt = debtToken.balanceOf(address(repay));
        s.marketDebt = debtToken.balanceOf(address(market));
        s.settlementDebt = debtToken.balanceOf(address(settlement));
        s.solverFee = feeToken.balanceOf(solver);
        s.makerFee = feeToken.balanceOf(maker);
        (s.repayAllowance,) = permit3.tokenAllowance(maker, address(repay), address(debtToken));
        (s.settlementAllowance,) = permit3.tokenAllowance(maker, address(settlement), address(feeToken));
        s.moduleToMarketApproval = debtToken.allowance(address(repay), address(market));
        s.marketCalls = market.calls();
    }

    function _assertSame(Snap memory a, Snap memory b) internal pure {
        assertEq(a.makerDebt, b.makerDebt, "maker debt-token balance");
        assertEq(a.moduleDebt, b.moduleDebt, "module debt-token balance");
        assertEq(a.marketDebt, b.marketDebt, "market debt-token balance");
        assertEq(a.settlementDebt, b.settlementDebt, "settlement debt-token balance");
        assertEq(a.solverFee, b.solverFee, "solver fee-token balance");
        assertEq(a.makerFee, b.makerFee, "maker fee-token balance");
        assertEq(a.repayAllowance, b.repayAllowance, "Permit3 maker->repay allowance");
        assertEq(a.settlementAllowance, b.settlementAllowance, "Permit3 maker->settlement allowance");
        assertEq(a.moduleToMarketApproval, b.moduleToMarketApproval, "module->market approval");
        assertEq(a.marketCalls, b.marketCalls, "market never called");
    }

    /// @dev maxAssets = 2^160: one past the width. A clipping cast would pull 0 and
    ///      approve 2^160; the guard reverts the whole fill with the RAW selector —
    ///      Settlement bubbles the module's revert data unwrapped.
    function test_narrow160_fixedRepayMaxAssets_reverts() public {
        Order memory order = _order(0, uint256(type(uint160).max) + 1);
        bytes memory sig = _sign(order); // sign BEFORE prank: _sign consumes a pending prank

        Snap memory before = _snap();

        vm.prank(solver);
        vm.expectRevert(Narrow160.AmountOverflow.selector);
        settlement.fill(order, sig, LEG);

        _assertSame(before, _snap());
    }

    /// @dev maxAssets = 2^160 - 1: exactly the width. Passes the narrowing and the
    ///      whole fill SETTLES: the module pulls the full bound, the market takes
    ///      the face, the surplus is swept back to the maker, the scoped venue
    ///      approval is cleared.
    function test_narrow160_fixedRepayMaxAssets_atMaxPassesNarrowing() public {
        uint256 bound = type(uint160).max;
        Order memory order = _order(1, bound);
        bytes memory sig = _sign(order);

        Snap memory before = _snap();

        vm.prank(solver);
        settlement.fill(order, sig, LEG);

        assertEq(market.calls(), 1, "venue reached");
        assertEq(debtToken.balanceOf(address(market)), FACE, "market took exactly the face");
        assertEq(debtToken.balanceOf(maker), before.makerDebt - FACE, "maker net cost = face; surplus swept back");
        assertEq(debtToken.balanceOf(address(repay)), 0, "module holds nothing");
        assertEq(debtToken.allowance(address(repay), address(market)), 0, "venue approval cleared");
        assertEq(feeToken.balanceOf(solver), LEG, "solver paid the input leg");
    }
}
