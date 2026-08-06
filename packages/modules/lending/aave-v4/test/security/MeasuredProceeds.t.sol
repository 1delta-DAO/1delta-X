// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {AaveV4WithdrawModule, AaveV4BorrowModule} from "../../src/AaveV4Modules.sol";

/// @dev Minimal ERC20 with the bits the modules touch.
contract MockToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 v) external {
        balanceOf[to] += v;
    }

    function transfer(address to, uint256 v) external returns (bool) {
        require(balanceOf[msg.sender] >= v, "insufficient");
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        return true;
    }
}

/// @dev A position manager whose REPORTED figure and ACTUAL delivery can diverge —
///      the situation a fee-on-transfer underlying, share→asset rounding, or a
///      capped/partially-filling spoke produces on a live deployment.
contract DivergentPositionManager {
    MockToken public immutable token;

    uint256 public deliver; // what actually gets transferred to the caller
    uint256 public report; // what the call claims it delivered

    constructor(MockToken _token) {
        token = _token;
    }

    function set(uint256 _deliver, uint256 _report) external {
        deliver = _deliver;
        report = _report;
    }

    function withdrawOnBehalfOf(address, uint256, uint256, address) external returns (uint256, uint256) {
        token.mint(msg.sender, deliver);
        return (0, report);
    }

    function borrowOnBehalfOf(address, uint256, uint256, address) external returns (uint256, uint256) {
        token.mint(msg.sender, deliver);
        return (0, report);
    }
}

/// @title AaveV4MeasuredProceedsTest
/// @notice Regression test for the v4 taker legs forwarding NOMINAL rather than
///         MEASURED amounts.
///
///  `AaveV4WithdrawModule`'s Exact branch forwarded the position manager's
///  reported `assets`, and `AaveV4BorrowModule` forwarded the requested `amount`
///  without looking at the result at all. Neither figure is a claim about this
///  module's balance. When the op under-delivers, a nominal transfer still moves
///  the full figure — silently topping up the shortfall from whatever else the
///  module happens to hold and paying it to the order, while the user keeps the
///  full debt or loses collateral they never received credit for.
///
///  This is the same shape as the H-3 River finding and the M-4 measured-delta
///  rule already applied elsewhere; the `Full` branch of this very module already
///  measured. Both legs now measure a balance delta and fail closed below it.
contract AaveV4MeasuredProceedsTest is Test {
    address constant PERMIT3 = address(0xBEEF);
    address constant SPOKE = address(0x5904E);
    uint256 constant RESERVE_ID = 1;

    address maker = address(0xA11CE);
    address receiver = address(0x5011E4); // stands in for Settlement

    MockToken token;
    DivergentPositionManager pm;
    AaveV4WithdrawModule withdrawModule;
    AaveV4BorrowModule borrowModule;

    function setUp() public {
        token = new MockToken();
        pm = new DivergentPositionManager(token);
        withdrawModule = new AaveV4WithdrawModule(PERMIT3);
        borrowModule = new AaveV4BorrowModule(PERMIT3);
    }

    /// 128 bytes exactly ⇒ no trailing mode word ⇒ `BalanceMode.Exact`.
    function _data() internal view returns (bytes memory) {
        return abi.encode(SPOKE, address(pm), RESERVE_ID, address(token));
    }

    /// A stray balance is what an under-delivery would be covered FROM. Modules are
    /// meant to end every call empty, but a donation or a prior rounding residue
    /// puts funds here, and nominal forwarding spends them.
    function _seedStray(address module, uint256 v) internal {
        token.mint(module, v);
    }

    // ── Withdraw ──────────────────────────────────────────────────────────────

    /// The honest case is unchanged: deliver == request, receiver gets it all.
    function test_withdraw_exactDelivery_forwardsFull() public {
        pm.set(100e6, 100e6);

        vm.prank(PERMIT3);
        withdrawModule.takeOnBehalf(maker, 100e6, receiver, _data());

        assertEq(token.balanceOf(receiver), 100e6, "receiver paid in full");
        assertEq(token.balanceOf(address(withdrawModule)), 0, "module ends empty");
    }

    /// The defect: the PM claims 100 but delivers 90. Nominal forwarding would
    /// hand the receiver 100, taking 10 from the module's stray balance.
    function test_withdraw_underDelivery_failsClosed() public {
        _seedStray(address(withdrawModule), 50e6);
        pm.set(90e6, 100e6); // delivers 90, reports 100

        vm.prank(PERMIT3);
        vm.expectRevert("insufficient withdrawn");
        withdrawModule.takeOnBehalf(maker, 100e6, receiver, _data());

        assertEq(token.balanceOf(receiver), 0, "receiver paid nothing");
        assertEq(token.balanceOf(address(withdrawModule)), 50e6, "stray balance untouched");
    }

    /// Over-delivery goes to the position owner, not into the module for the next
    /// fill to sweep.
    function test_withdraw_overDelivery_surplusToUser() public {
        pm.set(110e6, 100e6);

        vm.prank(PERMIT3);
        withdrawModule.takeOnBehalf(maker, 100e6, receiver, _data());

        assertEq(token.balanceOf(receiver), 100e6, "receiver gets the signed amount");
        assertEq(token.balanceOf(maker), 10e6, "surplus to the user");
        assertEq(token.balanceOf(address(withdrawModule)), 0, "module ends empty");
    }

    // ── Borrow ────────────────────────────────────────────────────────────────

    function test_borrow_exactDelivery_forwardsFull() public {
        pm.set(100e6, 100e6);

        vm.prank(PERMIT3);
        borrowModule.takeOnBehalf(maker, 100e6, receiver, _data());

        assertEq(token.balanceOf(receiver), 100e6, "receiver paid in full");
        assertEq(token.balanceOf(address(borrowModule)), 0, "module ends empty");
    }

    /// The sharper of the two: the old borrow path ignored the return value
    /// entirely and transferred the requested `amount`. A short borrow was paid
    /// out of the module's stray balance while the maker kept the whole debt.
    function test_borrow_underDelivery_failsClosed() public {
        _seedStray(address(borrowModule), 50e6);
        pm.set(90e6, 90e6);

        vm.prank(PERMIT3);
        vm.expectRevert("insufficient borrowed");
        borrowModule.takeOnBehalf(maker, 100e6, receiver, _data());

        assertEq(token.balanceOf(receiver), 0, "receiver paid nothing");
        assertEq(token.balanceOf(address(borrowModule)), 50e6, "stray balance untouched");
    }

    /// A borrow that delivers nothing at all must not pay out either.
    function test_borrow_zeroDelivery_failsClosed() public {
        _seedStray(address(borrowModule), 100e6);
        pm.set(0, 100e6);

        vm.prank(PERMIT3);
        vm.expectRevert("insufficient borrowed");
        borrowModule.takeOnBehalf(maker, 100e6, receiver, _data());

        assertEq(token.balanceOf(receiver), 0, "no payout from a zero borrow");
    }

    function test_borrow_overDelivery_surplusToUser() public {
        pm.set(105e6, 105e6);

        vm.prank(PERMIT3);
        borrowModule.takeOnBehalf(maker, 100e6, receiver, _data());

        assertEq(token.balanceOf(receiver), 100e6, "receiver gets the signed amount");
        assertEq(token.balanceOf(maker), 5e6, "surplus to the user");
        assertEq(token.balanceOf(address(borrowModule)), 0, "module ends empty");
    }

    // ── The property both legs now hold ───────────────────────────────────────

    /// However the op under-delivers, the module's pre-existing balance is never
    /// what pays the order.
    function testFuzz_strayBalanceNeverCoversAShortfall(uint96 stray, uint96 shortfall) public {
        uint256 request = 100e6;
        vm.assume(shortfall > 0 && shortfall <= request);
        _seedStray(address(borrowModule), stray);
        pm.set(request - shortfall, request);

        vm.prank(PERMIT3);
        vm.expectRevert("insufficient borrowed");
        borrowModule.takeOnBehalf(maker, request, receiver, _data());

        assertEq(token.balanceOf(receiver), 0, "receiver never paid from stray funds");
    }
}
