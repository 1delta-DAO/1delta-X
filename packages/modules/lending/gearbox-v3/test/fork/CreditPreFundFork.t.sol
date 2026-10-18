// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {CoreSettlementBase} from "@coretest/shared/CoreSettlementBase.t.sol";
import {PackedEncode} from "@coretest/shared/PackedEncode.sol";
import {Order, Item, ItemOp, LegOut, MatchPlan, MatchStep} from "@core/settlement/Settlement.sol";

import {GearboxCreditPreFundModule} from "../../src/GearboxV3PreFundModules.sol";
import {GearboxCreditWithdrawModule} from "../../src/GearboxV3Modules.sol";
import {MultiCall} from "../../src/interfaces/IGearboxV3.sol";

/// @dev The v3.1 owner surface, test-side only (same probes as `CreditFlow.t.sol`).
interface IFacadeV31 {
    function openCreditAccount(address onBehalfOf, MultiCall[] calldata calls, uint256 referralCode)
        external
        payable
        returns (address creditAccount);
    function multicall(address creditAccount, MultiCall[] calldata calls) external payable;
}

interface IFacadeV31Inner {
    function setBotPermissions(address bot, uint192 permissions) external;
    function addCollateral(address token, uint256 amount) external;
    function increaseDebt(uint256 amount) external;
}

interface ICMV31 {
    function creditAccountInfo(address creditAccount)
        external
        view
        returns (uint256 debt, uint256, uint128, uint128, uint256, uint16, uint64, address);
}

/// @title GearboxCreditPreFundForkTest
/// @notice The two new credit-account modules on the LIVE mainnet wstETH credit suite
///         (CreditFacadeV3 `3_10`, `debtLimits() = (20e18, 1000e18)`, underlying =
///         wstETH) — the same deployment `CreditFlow.t.sol` validates:
///           • {GearboxCreditWithdrawModule} (review 2026-10-18 M-2) — collateral out
///             with NO debt, under the narrow `0x20` bot mask, and Gearbox's collateral
///             check refusing a withdraw past the position's headroom;
///           • {GearboxCreditPreFundModule} (M-1) — AddCollateral / Repay from the
///             module's own balance under the `0x05` mask, `decreaseDebt`'s cap at the
///             total debt (the over-delivery recycled onto the account), the
///             `minDebt` edge, and the underlying binding.
///         Then the REAL Settlement's `matchSettle` runs a one-order acyclic full close
///         ("repay with collateral": withdraw TAKE early, Repay late) at zero capital,
///         and the debt-free account releases its collateral through the withdraw
///         module — a close through modules end to end.
contract GearboxCreditPreFundForkTest is CoreSettlementBase {
    address internal constant CREDIT_MANAGER = 0x9fB5493dEb601A0329ad8bFF43cD182a61321ca7;
    address internal constant CREDIT_FACADE = 0xE667676B28C270f5478299CF136Db5407Bf384Ce;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    uint256 internal constant COLLATERAL = 60e18;
    uint256 internal constant BORROW = 25e18;
    uint256 internal constant RESIDUE = 1e15;

    GearboxCreditPreFundModule internal preFund;
    GearboxCreditWithdrawModule internal withdrawer;
    address internal creditAccount;
    address internal recv = address(0xCAFE);

    function _forkBlock() internal pure override returns (uint256) {
        return 25_600_000;
    }

    function setUp() public override {
        super.setUp();
        preFund = new GearboxCreditPreFundModule(address(permit3), address(settlement));
        withdrawer = new GearboxCreditWithdrawModule(address(permit3));
        vm.label(CREDIT_MANAGER, "CreditManager");
        vm.label(CREDIT_FACADE, "CreditFacade");
        vm.label(WSTETH, "wstETH");
        vm.label(address(preFund), "gearboxCreditPreFund");
        vm.label(address(withdrawer), "gearboxCreditWithdraw");

        // A live account: 60 wstETH collateral, 25 wstETH drawn (the borrow stays on
        // the account as underlying, so it holds 85), opened by the owner directly.
        deal(WSTETH, maker, COLLATERAL);
        vm.startPrank(maker);
        IERC20(WSTETH).approve(CREDIT_MANAGER, COLLATERAL);
        creditAccount = IFacadeV31(CREDIT_FACADE).openCreditAccount(maker, new MultiCall[](0), 0);
        MultiCall[] memory calls = new MultiCall[](4);
        calls[0] = _inner(abi.encodeCall(IFacadeV31Inner.addCollateral, (WSTETH, COLLATERAL)));
        calls[1] = _inner(abi.encodeCall(IFacadeV31Inner.increaseDebt, (BORROW)));
        calls[2] = _inner(
            abi.encodeCall(IFacadeV31Inner.setBotPermissions, (address(preFund), preFund.requiredPermissions()))
        );
        calls[3] = _inner(
            abi.encodeCall(IFacadeV31Inner.setBotPermissions, (address(withdrawer), withdrawer.requiredPermissions()))
        );
        IFacadeV31(CREDIT_FACADE).multicall(creditAccount, calls);
        vm.stopPrank();
        vm.label(creditAccount, "creditAccount");

        deal(WSTETH, address(preFund), RESIDUE);
        // Gearbox allows one debt update per block per account.
        vm.roll(block.number + 1);
    }

    // ──────────────────── helpers ────────────────────

    function _inner(bytes memory cd) internal pure returns (MultiCall memory) {
        return MultiCall({target: CREDIT_FACADE, callData: cd});
    }

    function _debt() internal view returns (uint256 d) {
        (d,,,,,,,) = ICMV31(CREDIT_MANAGER).creditAccountInfo(creditAccount);
    }

    function _ca() internal view returns (uint256) {
        return IERC20(WSTETH).balanceOf(creditAccount);
    }

    function _desc(uint256 op, address token) internal pure returns (uint256) {
        return (uint256(5) << 253) | (op << 244) | (uint256(uint160(token)) << 16);
    }

    function _pfData(uint256 op, address token) internal view returns (bytes memory) {
        return abi.encode(_desc(op, token), creditAccount, token);
    }

    function _make(uint256 op, uint256 amt) internal {
        deal(WSTETH, address(preFund), IERC20(WSTETH).balanceOf(address(preFund)) + amt);
        bytes memory data = _pfData(op, WSTETH);
        vm.prank(address(settlement));
        preFund.makeOnBehalf(maker, amt, data);
    }

    function _withdrawData() internal view returns (bytes memory) {
        return abi.encode(creditAccount, WSTETH);
    }

    function _take(uint256 amt, address to) internal {
        bytes memory data = _withdrawData();
        vm.prank(maker);
        permit3.approveTaker(address(settlement), address(withdrawer), keccak256(data), type(uint160).max, 0);
        vm.prank(address(settlement));
        permit3.take(address(withdrawer), maker, uint160(amt), to, data);
    }

    // ──────────────────── the withdraw-only TAKE (M-2) ────────────────────

    /// The exact masks were accepted by the REAL BotListV3 in setUp.
    function test_fork_masks() public view {
        assertEq(withdrawer.requiredPermissions(), 0x20, "withdraw-only");
        assertEq(preFund.requiredPermissions(), 0x05, "ADD_COLLATERAL | DECREASE_DEBT");
    }

    function test_fork_withdraw_movesCollateralOut_withNoNewDebt() public {
        assertEq(_ca(), COLLATERAL + BORROW, "seeded");
        _take(10e18, recv);
        assertEq(IERC20(WSTETH).balanceOf(recv), 10e18, "collateral to the receiver");
        assertEq(_ca(), COLLATERAL + BORROW - 10e18, "left the account");
        assertEq(_debt(), BORROW, "no debt drawn");
    }

    /// Past the headroom, Gearbox's end-of-multicall collateral check refuses — the
    /// LTV-edge close is a true cycle and stays with the flash family.
    function test_fork_withdraw_pastHeadroom_reverts() public {
        bytes memory data = _withdrawData();
        vm.prank(maker);
        permit3.approveTaker(address(settlement), address(withdrawer), keccak256(data), type(uint160).max, 0);
        vm.prank(address(settlement));
        vm.expectRevert(abi.encodeWithSignature("NotEnoughCollateralException()"));
        permit3.take(address(withdrawer), maker, uint160(70e18), recv, data);
    }

    // ──────────────────── the pre-funded credit MAKE (M-1) ────────────────────

    function test_fork_preFund_addCollateral_addsTheDelivery() public {
        uint256 before = _ca();
        _make(0, 5e18);
        assertEq(_ca(), before + 5e18, "delivery added as collateral");
        assertEq(IERC20(WSTETH).balanceOf(address(preFund)), RESIDUE, "singleton back to its residue");
        assertEq(IERC20(WSTETH).allowance(address(preFund), CREDIT_MANAGER), 0, "manager grant cleared");
    }

    function test_fork_preFund_repay_partial_burnsTheDelivery() public {
        _make(1, 4e18);
        assertEq(_debt(), BORROW - 4e18, "decreaseDebt burned exactly the delivery");
        assertEq(_ca(), COLLATERAL + BORROW, "addCollateral in + burn out nets to zero on the account");
        assertEq(IERC20(WSTETH).balanceOf(address(preFund)), RESIDUE, "singleton back to its residue");
    }

    /// After 30 days of accrual the STORED principal is stale; a delivery signed with
    /// headroom closes the debt to zero and the over-delivery stays on the account.
    function test_fork_preFund_repay_withHeadroom_closesToZero_afterAccrual() public {
        vm.warp(block.timestamp + 30 days);
        uint256 caBefore = _ca();
        _make(1, BORROW + 1e18);
        assertEq(_debt(), 0, "debt closed");
        assertGt(_ca(), caBefore, "the uncapped part recycled onto the maker's account");
        assertLt(_ca(), caBefore + 1e18, "and only that part (interest was paid)");
        assertEq(IERC20(WSTETH).balanceOf(address(preFund)), RESIDUE, "nothing stranded on the module");
    }

    function test_fork_preFund_repay_residualBelowMinDebt_reverts() public {
        deal(WSTETH, address(preFund), RESIDUE + 10e18);
        bytes memory data = _pfData(1, WSTETH);
        vm.prank(address(settlement));
        vm.expectRevert(abi.encodeWithSignature("BorrowAmountOutOfLimitsException()"));
        preFund.makeOnBehalf(maker, 10e18, data);
    }

    function test_fork_preFund_repay_notUnderlying_refused() public {
        deal(USDC, address(preFund), 100e6);
        bytes memory data = _pfData(1, USDC);
        vm.prank(address(settlement));
        vm.expectRevert(abi.encodeWithSelector(GearboxCreditPreFundModule.NotUnderlying.selector, USDC, WSTETH));
        preFund.makeOnBehalf(maker, 100e6, data);
    }

    // ──────────────────── end to end through the real matchSettle ────────────────────

    /// "Repay with collateral" as ONE netted order, no counterparty, no capital: the
    /// withdraw TAKE runs early and credits the order's input leg; that leg funds the
    /// delivery to the pre-fund module; Repay runs late and closes the debt. The
    /// debt-free account then releases its collateral through the withdraw module.
    function test_fork_matchSettle_acyclicFullClose_thenWithdrawAll() public {
        uint256 amt = BORROW + 1e18;
        bytes memory wData = _withdrawData();
        Item[] memory items = new Item[](2);
        items[0] = Item(ItemOp.TAKE, address(withdrawer), amt, address(0), wData);
        items[1] = Item(ItemOp.MAKE, address(preFund), 0, address(0), _pfData(1, WSTETH));
        Order memory o = _order(maker, 1, WSTETH, WSTETH, amt, amt, items);
        LegOut[] memory legsOut = new LegOut[](1);
        legsOut[0] = LegOut(WSTETH, amt, 0, address(preFund));
        o.legsOut = PackedEncode.legsOut(legsOut);
        vm.prank(maker);
        permit3.approveTaker(address(settlement), address(withdrawer), keccak256(wData), type(uint160).max, 0);

        Order[] memory orders = new Order[](1);
        orders[0] = o;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(o);
        uint256[] memory s = new uint256[](4);
        s[0] = MatchStep.pack(MatchStep.ITEM, 0, 0);
        s[1] = MatchStep.pack(MatchStep.PULL, 0, 0);
        s[2] = MatchStep.pack(MatchStep.DELIVER, 0, 0);
        s[3] = MatchStep.pack(MatchStep.ITEM, 0, 1);
        MatchPlan memory p = MatchPlan({
            orders: orders,
            sigs: sigs,
            fillAmounts: _u1(amt),
            takerDatas: new bytes[](0),
            schedule: s,
            callTargets: new address[](0),
            callDatas: new bytes[](0),
            profitRecipient: address(0)
        });
        vm.prank(solver);
        settlement.matchSettle(p);

        assertEq(_debt(), 0, "debt closed");
        assertEq(_ca(), COLLATERAL, "85 - 26 out + 26 in - 25 burned");
        assertEq(IERC20(WSTETH).balanceOf(solver), 0, "zero solver capital");
        assertEq(IERC20(WSTETH).balanceOf(maker), 0, "maker wallet untouched");
        assertEq(IERC20(WSTETH).balanceOf(address(preFund)), RESIDUE, "singleton back to its residue");
        (uint160 a,) = permit3.tokenAllowance(maker, address(preFund), WSTETH);
        assertEq(a, 0, "no receive-side allowance existed");

        // Debt-free: everything left can leave through the withdraw-only module.
        _take(COLLATERAL, maker);
        assertEq(_ca(), 0, "account emptied");
        assertEq(IERC20(WSTETH).balanceOf(maker), COLLATERAL, "collateral home");
    }
}
