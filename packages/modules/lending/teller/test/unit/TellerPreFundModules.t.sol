// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {TellerPreFundModule} from "../../src/TellerPreFundModules.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";

// ──────────────────── mocks (no fork) ────────────────────

/// @dev Minimal mintable ERC20.
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Stands in for Permit3 as the modules' gate address. Its fallback REVERTS,
///      so the happy-path tests double as the funding-side proof: had a push
///      module called `permit3.transferFrom` (or anything else on Permit3), the
///      fill would have failed loudly instead of succeeding.
contract RevertingPermit3 {
    fallback() external {
        revert("permit3 must never be called by a pre-fund module");
    }
}

/// @dev ERC-4626-shaped Teller pool: `deposit` pulls exactly `assets` from the
///      caller and credits `receiver`.
contract MockTellerPool {
    MockERC20 public immutable asset;
    mapping(address => uint256) public sharesOf;
    uint256 public depositCalls;

    constructor(MockERC20 _asset) {
        asset = _asset;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        asset.transferFrom(msg.sender, address(this), assets);
        sharesOf[receiver] += assets;
        depositCalls++;
        return assets;
    }
}

/// @dev TellerV2 repay surface: `repayLoanFull` pulls exactly what is owed;
///      `repayLoan` clamps a final overshooting payment to the outstanding
///      balance (as the real `_repayLoan` does) — so the module's delta-sweep is
///      what returns any unused buffer.
contract MockTellerV2 {
    MockERC20 public immutable principal;
    mapping(uint256 => uint256) public owed;

    constructor(MockERC20 _principal) {
        principal = _principal;
    }

    function setOwed(uint256 bidId, uint256 amount) external {
        owed[bidId] = amount;
    }

    function repayLoanFull(uint256 bidId) external {
        uint256 due = owed[bidId];
        owed[bidId] = 0;
        principal.transferFrom(msg.sender, address(this), due);
    }

    function repayLoan(uint256 bidId, uint256 amount) external {
        uint256 due = owed[bidId];
        uint256 pay = amount < due ? amount : due;
        owed[bidId] = due - pay;
        principal.transferFrom(msg.sender, address(this), pay);
    }
}

/// @dev The PRE-FUNDED one-sided Teller modules, unit-tested against mock
///      venues (this package has no fork harness): the permit3 gate, the
///      leg-reference-only descriptor rule, and mock-venue happy paths funded
///      purely from the module's own balance — `permit3` is a reverting stub, so
///      success IS the proof that no funding-side `transferFrom` exists.
contract TellerPreFundModulesTest is Test {
    TellerPreFundModule preFund;
    address settlement = address(0x5E77);
    MockERC20 asset;
    MockTellerPool pool;
    MockTellerV2 tellerV2;
    RevertingPermit3 permit3;

    address maker = address(0xA11CE);
    address attacker = address(0xBAD);

    uint256 constant BID_ID = 42;

    function setUp() public {
        asset = new MockERC20();
        pool = new MockTellerPool(asset);
        tellerV2 = new MockTellerV2(asset);
        permit3 = new RevertingPermit3();

        preFund = new TellerPreFundModule(address(permit3), address(settlement));
    }

    /// @dev `(1 << 255) | index` — fund from `legsOut[index]`.
    function _forLeg(uint256 index, address token) internal pure returns (uint256) {
        // bit 255 = leg reference; bit 253 = the PRE-FUND shape, which makes the core
        // require `legsOut[index].recipient == module` (F27/H-1).
        return (uint256(1) << 255) | (uint256(1) << 253) | (uint256(uint160(token)) << 16) | index;
    }

    /// @dev Same leg reference, with the op in descriptor bits [244,252).
    function _forLegOp(uint256 index, address token, TellerPreFundModule.Op op) internal pure returns (uint256) {
        return _forLeg(index, token) | (uint256(op) << 244);
    }

    function _depositData() internal view returns (bytes memory) {
        return abi.encode(_forLeg(0, address(asset)), address(pool), address(asset));
    }

    function _repayData(bool full) internal view returns (bytes memory) {
        return abi.encode(_forLegOp(0, address(asset), TellerPreFundModule.Op.Repay), address(tellerV2), address(asset), BID_ID, full);
    }

    // ──────────────────── permit3 gate ────────────────────

    function test_deposit_rejects_non_settlement() public {
        vm.prank(attacker);
        vm.expectRevert(PreFundGuard.OnlySettlement.selector);
        preFund.makeOnBehalf(maker, 1e18, _depositData());
    }

    function test_repay_rejects_non_settlement() public {
        vm.prank(attacker);
        vm.expectRevert(PreFundGuard.OnlySettlement.selector);
        preFund.makeOnBehalf(maker, 1e18, _repayData(true));
    }

    // ──────────────────── descriptor rule: leg-reference ONLY ────────────────────

    function test_deposit_rejects_literal_descriptor() public {
        // Top bit clear = literal total: no delivery backs it.
        bytes memory data = abi.encode(uint256(1e18), address(pool), address(asset));
        vm.prank(address(settlement));
        vm.expectRevert(PreFundGuard.PreFundDescriptorRequired.selector);
        preFund.makeOnBehalf(maker, 1e18, data);
    }

    function test_deposit_rejects_balance_descriptor() public {
        // Top TWO bits set = balance-relative: reads the MAKER's wallet while this
        // module funds from its own — a mis-pairing by construction.
        bytes memory data = abi.encode((uint256(3) << 254) | uint160(address(asset)), address(pool), address(asset));
        vm.prank(address(settlement));
        vm.expectRevert(PreFundGuard.PreFundDescriptorRequired.selector);
        preFund.makeOnBehalf(maker, 1e18, data);
    }

    function test_repay_rejects_literal_descriptor() public {
        bytes memory data = abi.encode(uint256(1e18), address(tellerV2), address(asset), BID_ID, true);
        vm.prank(address(settlement));
        vm.expectRevert(PreFundGuard.PreFundDescriptorRequired.selector);
        preFund.makeOnBehalf(maker, 1e18, data);
    }

    // ──────────────────── deposit happy path ────────────────────

    // The delivered leg sits on the module (the core delivered it there before
    // dispatch); the module funds the venue from that balance ALONE — permit3 is
    // a reverting stub, so no transferFrom can have happened.
    function test_deposit_fundsFromOwnBalance_creditsMaker() public {
        uint256 forAmount = 1_000e6;
        asset.mint(address(preFund), forAmount); // the delivered output leg

        vm.prank(address(settlement));
        preFund.makeOnBehalf(maker, forAmount, _depositData());

        assertEq(pool.sharesOf(maker), forAmount, "maker credited with the pool shares");
        assertEq(asset.balanceOf(address(pool)), forAmount, "pool received the delivery");
        assertEq(asset.balanceOf(address(preFund)), 0, "module drained");
        assertEq(asset.allowance(address(preFund), address(pool)), 0, "scoped approval cleared");
    }

    function test_deposit_zeroForAmount_skips() public {
        vm.prank(address(settlement));
        preFund.makeOnBehalf(maker, 0, _depositData());
        assertEq(pool.depositCalls(), 0, "dust slice: venue untouched");
    }

    // ──────────────────── repay happy paths ────────────────────

    function test_repayFull_sweepsSurplusToMaker_preservesFloor() public {
        uint256 dust = 3; //          another fill's dust, already on the singleton
        uint256 debt = 800e6;
        uint256 forAmount = 1_000e6; // over-delivery: the auction cleared above the debt

        tellerV2.setOwed(BID_ID, debt);
        asset.mint(address(preFund), dust);
        asset.mint(address(preFund), forAmount); // the delivered output leg

        vm.prank(address(settlement));
        preFund.makeOnBehalf(maker, forAmount, _repayData(true));

        assertEq(tellerV2.owed(BID_ID), 0, "debt retired in full");
        assertEq(asset.balanceOf(maker), forAmount - debt, "surplus swept to the maker");
        assertEq(asset.balanceOf(address(preFund)), dust, "pre-existing floor untouched");
        assertEq(asset.allowance(address(preFund), address(tellerV2)), 0, "scoped approval cleared");
    }

    function test_repayPartial_consumesExactlyTheDelivery() public {
        uint256 debt = 1_000e6;
        uint256 forAmount = 400e6;

        tellerV2.setOwed(BID_ID, debt);
        asset.mint(address(preFund), forAmount);

        vm.prank(address(settlement));
        preFund.makeOnBehalf(maker, forAmount, _repayData(false));

        assertEq(tellerV2.owed(BID_ID), debt - forAmount, "partial repay applied");
        assertEq(asset.balanceOf(maker), 0, "nothing to sweep");
        assertEq(asset.balanceOf(address(preFund)), 0, "module drained");
    }

    // A leg NOT addressed to this module leaves no balance behind the instructed
    // `forAmount` — the mis-pairing fails closed at the floor computation.
    function test_repay_withoutDelivery_failsClosed() public {
        tellerV2.setOwed(BID_ID, 800e6);
        vm.prank(address(settlement));
        vm.expectRevert(); // balance − forAmount underflows
        preFund.makeOnBehalf(maker, 1_000e6, _repayData(true));
    }

    // ──────────────────── funding-source preflight ────────────────────

    function test_fundingSource_views() public view {
        (address a1, uint256 avail1) = preFund.fundingSource(maker, _depositData());
        assertEq(a1, address(asset));
        assertEq(avail1, type(uint256).max, "funded by the fill's own delivery");

        (address a2, uint256 avail2) = preFund.fundingSource(maker, _repayData(true));
        assertEq(a2, address(asset));
        assertEq(avail2, type(uint256).max);
    }
}
