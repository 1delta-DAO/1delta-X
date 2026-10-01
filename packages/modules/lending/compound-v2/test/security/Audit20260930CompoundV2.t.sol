// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order, Item, ItemOp, LegIn, LegOut} from "@core/settlement/Settlement.sol";
import {IProceedsAsset} from "@core/interfaces/IProceedsAsset.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {MockSettlementBase, MockERC20} from "@coretest/shared/MockSettlementBase.t.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";

import {CompoundV2RepayModule, CompoundV2WithdrawModule} from "../../src/CompoundV2Modules.sol";
import {CompoundV2NativeWithdrawModule} from "../../src/CompoundV2NativeModules.sol";

// ════════════════════════════════════════════════════════════════════════════
//  2026-09-30 whole-tree audit — compound-v2 regressions (group B-lend1).
//
//  Real Permit3 + real Settlement (MockSettlementBase, no fork) + the real modules;
//  only the venue (cToken / cEther) and the ERC-20s are mocks. Every test asserts
//  the SAFE end state and fails on the pre-fix source.
// ════════════════════════════════════════════════════════════════════════════

/// @dev ATTACKER-CONTROLLED "cToken" (X-STATIC-1): reports no debt and on `mint`
///      spends the module's scoped approval, pulling the residual to the attacker,
///      then returns a non-zero Compound error code.
contract AuditEvilRecycleCToken {
    address public immutable attacker;
    address internal _underlying;

    constructor(address attacker_) {
        attacker = attacker_;
    }

    function setUnderlying(address u) external {
        _underlying = u;
    }

    function borrowBalanceCurrent(address) external pure returns (uint256) {
        return 0;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function mint(uint256 amount) external returns (uint256) {
        MockERC20(_underlying).transferFrom(msg.sender, attacker, amount);
        return 1;
    }
}

/// @dev Honest failure: returns an error code WITHOUT spending the approval (what a
///      paused real Compound v2 market does).
contract AuditHonestFailingCToken {
    function borrowBalanceCurrent(address) external pure returns (uint256) {
        return 0;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function mint(uint256) external pure returns (uint256) {
        return 1;
    }
}

/// @dev A cErc20 whose redeem pays the redeemer `amount - fee` and the rest to a
///      treasury — the BSC Venus core-pool `redeemFresh` shape with a non-zero
///      `treasuryPercent` (G-VENUE_A-2), reachable through this module when a maker
///      points it at a Compound-v2-fork vToken. 1:1 exchange rate for clarity.
///      `underlying()` is configurable so the same mock drives the L-CV2-4 binding.
contract AuditFeeCToken is MockERC20 {
    MockERC20 public immutable realUnderlying;
    address public reportedUnderlying;
    uint256 public feeBps;
    address constant TREASURY = address(0x7EA5);

    constructor(MockERC20 u, uint256 feeBps_) MockERC20("cFee") {
        realUnderlying = u;
        reportedUnderlying = address(u);
        feeBps = feeBps_;
    }

    function setReportedUnderlying(address u) external {
        reportedUnderlying = u;
    }

    function underlying() external view returns (address) {
        return reportedUnderlying;
    }

    function exchangeRateCurrent() external pure returns (uint256) {
        return 1e18;
    }

    function redeemUnderlying(uint256 amount) external returns (uint256) {
        balanceOf[msg.sender] -= amount;
        uint256 fee = amount * feeBps / 10_000;
        realUnderlying.transfer(TREASURY, fee);
        realUnderlying.transfer(msg.sender, amount - fee);
        return 0;
    }

    function redeem(uint256 cAmount) external returns (uint256) {
        balanceOf[msg.sender] -= cAmount;
        uint256 fee = cAmount * feeBps / 10_000;
        realUnderlying.transfer(TREASURY, fee);
        realUnderlying.transfer(msg.sender, cAmount - fee);
        return 0;
    }
}

/// @dev Minimal WETH for the native module.
contract AuditMockWETH is MockERC20 {
    constructor() MockERC20("WETH") {}

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
    }
}

/// @dev A cEther whose redeem pays `amount - fee` in native ETH (vBNB with a
///      treasury fee, G-VENUE_A-2). 1:1 exchange rate.
contract AuditFeeCEther is MockERC20 {
    uint256 public feeBps;

    constructor(uint256 feeBps_) MockERC20("cETH") {
        feeBps = feeBps_;
    }

    receive() external payable {}

    function exchangeRateCurrent() external pure returns (uint256) {
        return 1e18;
    }

    function redeemUnderlying(uint256 amount) external returns (uint256) {
        balanceOf[msg.sender] -= amount;
        uint256 fee = amount * feeBps / 10_000;
        payable(address(0x7EA5)).transfer(fee);
        payable(msg.sender).transfer(amount - fee);
        return 0;
    }
}

contract Audit20260930CompoundV2Test is MockSettlementBase {
    /// @dev `CompoundV2WithdrawModule.UnderlyingMismatch(address,address)`, spelled out
    ///      so this file also compiles against the pre-fix module (fails-before proof).
    bytes4 constant UNDERLYING_MISMATCH = bytes4(keccak256("UnderlyingMismatch(address,address)"));

    CompoundV2RepayModule repayModule;
    CompoundV2WithdrawModule withdrawModule;

    address victim = address(0xB0B);
    uint256 constant STRANDED = 500e18;

    function setUp() public override {
        super.setUp();
        repayModule = new CompoundV2RepayModule(address(permit3), address(settlement));
        withdrawModule = new CompoundV2WithdrawModule(address(permit3));
    }

    // ─────────────────────────── X-STATIC-1 ───────────────────────────

    function _strand() internal {
        tA.mint(victim, STRANDED);
        vm.prank(victim);
        tA.transfer(address(repayModule), STRANDED);
    }

    function _recycleSelfOrder(uint256 nonce, address cToken, uint256 amount) internal view returns (Order memory o) {
        Item[] memory items = new Item[](1);
        items[0] = Item(
            ItemOp.MAKE,
            address(repayModule),
            amount,
            address(0),
            abi.encode(cToken, address(tA), uint256(1)) // DustAction.Recycle
        );
        o = _blank(nonce);
        o.items = PackedEncode.items(items);
        o.fillTotal = 1; // explicit denominator: no anchor leg needed
    }

    /// The exploit from the PoC, asserting the SAFE end state: a cToken that spends
    /// the approval and then returns an error code can take only the residual it was
    /// approved for — never the module's pre-existing (`floor`) balance.
    function test_audit_X_STATIC_1_recycleErrorCode_preservesFloor() public {
        _strand();
        AuditEvilRecycleCToken evil = new AuditEvilRecycleCToken(maker);
        evil.setUnderlying(address(tA));

        tA.mint(maker, STRANDED);
        _makerApprove(address(repayModule), address(tA), STRANDED);

        Order memory o = _recycleSelfOrder(1, address(evil), STRANDED);
        bytes memory sig = _sign(o);
        vm.prank(maker);
        settlement.fill(o, sig, 1);

        // F19: the module ends where it started.
        assertEq(tA.balanceOf(address(repayModule)), STRANDED, "stranded floor preserved");
        // The attacker paid B and got back exactly B (via the evil mint) — no gain.
        assertEq(tA.balanceOf(maker), STRANDED, "attacker gains nothing");
        assertEq(tA.allowance(address(repayModule), address(evil)), 0, "approval cleared");
    }

    /// Control: an honest error-code cToken (approval unspent) still refunds the
    /// whole residual through the measured sweep, and leaves the floor.
    function test_audit_X_STATIC_1_honestErrorCode_sweepsResidual() public {
        _strand();
        AuditHonestFailingCToken honest = new AuditHonestFailingCToken();
        tA.mint(maker, STRANDED);
        _makerApprove(address(repayModule), address(tA), STRANDED);

        Order memory o = _recycleSelfOrder(2, address(honest), STRANDED);
        bytes memory sig = _sign(o);
        vm.prank(maker);
        settlement.fill(o, sig, 1);

        assertEq(tA.balanceOf(address(repayModule)), STRANDED, "floor preserved");
        assertEq(tA.balanceOf(maker), STRANDED, "own residual refunded in full");
    }

    /// Partial consumption: the callee takes HALF the approved residual and returns
    /// an error. The measured sweep refunds the other half — exactly the delta still
    /// on the module above `floor` — and the floor survives.
    function test_audit_X_STATIC_1_partialConsumption_refundsOnlyRemainder() public {
        _strand();
        AuditHalfEvilCToken half = new AuditHalfEvilCToken(maker, address(tA));
        tA.mint(maker, STRANDED);
        _makerApprove(address(repayModule), address(tA), STRANDED);

        Order memory o = _recycleSelfOrder(3, address(half), STRANDED);
        bytes memory sig = _sign(o);
        vm.prank(maker);
        settlement.fill(o, sig, 1);

        assertEq(tA.balanceOf(address(repayModule)), STRANDED, "floor preserved");
        // half pulled by the callee + half refunded by the measured sweep = B.
        assertEq(tA.balanceOf(maker), STRANDED, "maker ends with exactly its own B");
    }

    // ───────────────────── G-VENUE_A-2 / L-CV2-1 (Exact) ─────────────────────

    function _withdrawOrder(uint256 nonce, address cToken, uint256 amount, uint256 outAmt)
        internal
        view
        returns (Order memory o, bytes memory data)
    {
        data = abi.encode(cToken, address(tA));
        Item[] memory items = new Item[](1);
        items[0] = Item(ItemOp.TAKE, address(withdrawModule), amount, address(0), data);
        o = _plainOrder(nonce, address(tA), address(tB), amount, outAmt);
        o.items = PackedEncode.items(items);
    }

    /// A redeem that pays the module `amount - fee` used to be forwarded short, and
    /// the core silently pulled the fee-sized gap from the MAKER'S WALLET (through
    /// the standing Settlement allowance). The Exact branch now fails closed.
    function test_audit_G_VENUE_A_2_exactWithdraw_redeemFee_revertsInsteadOfBillingWallet() public {
        uint256 amount = 1_000e18;
        AuditFeeCToken cFee = new AuditFeeCToken(tA, 10); // 0.1 % treasury fee
        tA.mint(address(cFee), amount);
        cFee.mint(maker, amount); // maker's 1:1 supply position

        (Order memory o, bytes memory data) = _withdrawOrder(10, address(cFee), amount, 900e18);
        vm.startPrank(maker);
        cFee.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(withdrawModule), address(cFee), type(uint160).max, 0);
        permit3.approveTaker(address(settlement), address(withdrawModule), keccak256(data), uint160(amount), 0);
        vm.stopPrank();
        // The maker ALSO holds wallet tA with a standing Settlement allowance — the
        // funds the pre-fix core billed the fee to.
        tA.mint(maker, 10e18);
        _makerApprove(address(settlement), address(tA), type(uint160).max);
        tB.mint(solver, 900e18);
        _solverApprove(address(settlement), address(tB), type(uint160).max);

        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(FullFillGuard.ShortWithdraw.selector, amount - 1e18, amount));
        settlement.fill(o, sig, amount);

        assertEq(tA.balanceOf(maker), 10e18, "maker wallet untouched");
        assertEq(cFee.balanceOf(maker), amount, "position untouched");
    }

    /// The honest venue (no fee) still fills an Exact withdraw slice exactly — the
    /// bound cannot misfire on a pro-rated slice.
    function test_audit_G_VENUE_A_2_exactWithdraw_noFee_partialFillStillWorks() public {
        uint256 amount = 1_000e18;
        AuditFeeCToken c0 = new AuditFeeCToken(tA, 0);
        tA.mint(address(c0), amount);
        c0.mint(maker, amount);

        (Order memory o, bytes memory data) = _withdrawOrder(11, address(c0), amount, 900e18);
        vm.startPrank(maker);
        c0.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(withdrawModule), address(c0), type(uint160).max, 0);
        permit3.approveTaker(address(settlement), address(withdrawModule), keccak256(data), uint160(amount), 0);
        vm.stopPrank();
        tB.mint(solver, 900e18);
        _solverApprove(address(settlement), address(tB), type(uint160).max);

        bytes memory sig = _sign(o);
        vm.prank(solver);
        settlement.fill(o, sig, amount / 4);
        assertEq(tA.balanceOf(solver), amount / 4, "solver got the slice");
        assertEq(c0.balanceOf(maker), amount - amount / 4, "position down by the slice");
        assertEq(tA.balanceOf(maker), 0, "nothing billed to the wallet");
    }

    /// Native sibling: a cEther / vBNB redeem with a treasury fee.
    function test_audit_G_VENUE_A_2_nativeExactWithdraw_redeemFee_reverts() public {
        AuditMockWETH weth = new AuditMockWETH();
        CompoundV2NativeWithdrawModule nativeWithdraw = new CompoundV2NativeWithdrawModule(address(permit3), address(weth));
        AuditFeeCEther cEth = new AuditFeeCEther(10);
        uint256 amount = 10 ether;
        vm.deal(address(cEth), amount);
        cEth.mint(maker, amount);
        vm.startPrank(maker);
        cEth.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(nativeWithdraw), address(cEth), type(uint160).max, 0);
        vm.stopPrank();

        vm.prank(address(permit3));
        vm.expectRevert(abi.encodeWithSelector(FullFillGuard.ShortWithdraw.selector, amount - 0.01 ether, amount));
        nativeWithdraw.takeOnBehalf(maker, amount, address(0x5E77), abi.encode(address(cEth)));
    }

    // ─────────────────────────── L-CV2-4 ───────────────────────────

    /// A mis-encoded `underlying` used to be measured as a zero delta: the module
    /// forwarded 0, the real redeemed underlying stayed stranded on the singleton,
    /// and the core billed the whole input leg to the maker's wallet. Now rejected.
    function test_audit_L_CV2_4_withdraw_underlyingMismatch_reverts() public {
        uint256 amount = 100e18;
        AuditFeeCToken c = new AuditFeeCToken(tC, 0); // REAL underlying = tC
        tC.mint(address(c), amount);
        c.mint(maker, amount);

        // The maker's order names tA as the underlying (encoder bug).
        (Order memory o, bytes memory data) = _withdrawOrder(20, address(c), amount, 90e18);
        vm.startPrank(maker);
        c.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(withdrawModule), address(c), type(uint160).max, 0);
        permit3.approveTaker(address(settlement), address(withdrawModule), keccak256(data), uint160(amount), 0);
        vm.stopPrank();
        tA.mint(maker, amount); // wallet funds the pre-fix core would have billed
        _makerApprove(address(settlement), address(tA), type(uint160).max);
        tB.mint(solver, 90e18);
        _solverApprove(address(settlement), address(tB), type(uint160).max);

        bytes memory sig = _sign(o);
        vm.prank(solver);
        vm.expectRevert(
            abi.encodeWithSelector(UNDERLYING_MISMATCH, address(tA), address(tC))
        );
        settlement.fill(o, sig, amount);

        assertEq(tA.balanceOf(maker), amount, "wallet not billed");
        assertEq(tC.balanceOf(address(withdrawModule)), 0, "nothing stranded on the module");
    }

    // ─────────────────────────── L-CMT-6 ───────────────────────────

    /// Read through a raw staticcall so the test compiles — and FAILS — against the
    /// pre-fix modules, which did not answer the selector (the lens then SKIPPED the
    /// F22 stranded-proceeds check).
    function _proceeds(address module, bytes memory data) internal view returns (address a) {
        (bool ok, bytes memory ret) = module.staticcall(abi.encodeCall(IProceedsAsset.proceedsAsset, (data)));
        assertTrue(ok && ret.length == 32, "module answers proceedsAsset");
        a = abi.decode(ret, (address));
    }

    function test_audit_L_CMT_6_withdraw_declaresProceedsAsset() public {
        assertEq(_proceeds(address(withdrawModule), abi.encode(address(0xC0), address(tA))), address(tA));
        // Full-mode blob: the trailing words do not change the answer.
        assertEq(
            _proceeds(address(withdrawModule), abi.encode(address(0xC0), address(tA), uint256(0xB0DE0001), 1e18)),
            address(tA)
        );
        AuditMockWETH weth = new AuditMockWETH();
        CompoundV2NativeWithdrawModule nativeWithdraw = new CompoundV2NativeWithdrawModule(address(permit3), address(weth));
        assertEq(_proceeds(address(nativeWithdraw), abi.encode(address(0xCE))), address(weth), "native -> WETH");
    }
}

/// @dev Consumes HALF of the approved residual, then reports failure.
contract AuditHalfEvilCToken {
    address public immutable attacker;
    address public immutable underlyingToken;

    constructor(address attacker_, address u) {
        attacker = attacker_;
        underlyingToken = u;
    }

    function borrowBalanceCurrent(address) external pure returns (uint256) {
        return 0;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function mint(uint256 amount) external returns (uint256) {
        MockERC20(underlyingToken).transferFrom(msg.sender, attacker, amount / 2);
        return 1;
    }
}
