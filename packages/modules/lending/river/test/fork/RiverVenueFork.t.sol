// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, stdError} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Permit3} from "@core/permit3/Permit3.sol";

import {RiverRepayModule} from "../../src/RiverModules.sol";
import {RiverPreFundModule} from "../../src/RiverPreFundModules.sol";
import {IRiverXApp, IRiverTroveManager} from "../../src/interfaces/IRiver.sol";

/// @dev A TroveManager the diamond never registered, answering the module's pin
///      with the REAL satUSD — the shape the River trust premise must reject.
contract FakeRiverTM {
    address public debtToken;
    address public collateralToken;

    constructor(address d, address c) {
        debtToken = d;
        collateralToken = c;
    }

    function getEntireDebtAndColl(address) external pure returns (uint256, uint256, uint256, uint256) {
        return (1_000_000e18, 0, 0, 0);
    }
}

/// @title 2026-09-30 audit, L-LRG-5 / L-LRG-4 — River against the deployed BSC diamond.
/// @notice (5) the debt-token pin `tm.debtToken()` trusts the DIAMOND to reject an
///         unregistered TroveManager — pinned here; (2) the pull `RiverRepayModule`
///         on the live venue; (L-LRG-4) the venue premise behind both repay modules'
///         `FullCloseNotSupported` (retiring the whole debt reverts on River) and the
///         pre-fund module now naming it. Forks BSC LATEST (relative assertions);
///         override with `BSC_RPC_URL`.
contract RiverVenueForkTest is Test {
    address constant XAPP = 0x07BbC5A83B83a5C440D1CAedBF1081426d0AA4Ec;
    address constant SAT_USD = 0xb4818BB69478730EF4e33Cc068dD94278e2766cB;
    address constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
    address constant TM = 0x5EA26D0A1a9aa6731F9BFB93fCd654cd1C3079Ec;
    uint256 constant MAX_FEE = 0.05e18;

    Permit3 permit3;
    address settlement = makeAddr("settlement");
    address maker = makeAddr("riverMaker");
    RiverRepayModule repayModule;
    RiverPreFundModule preFund;

    function setUp() public {
        string memory rpc = "https://bsc-dataseed1.bnbchain.org";
        try vm.envString("BSC_RPC_URL") returns (string memory v) {
            if (bytes(v).length > 0) rpc = v;
        } catch {}
        vm.createSelectFork(rpc);

        permit3 = new Permit3();
        repayModule = new RiverRepayModule(address(permit3), settlement);
        preFund = new RiverPreFundModule(address(permit3), settlement);

        // Open the maker's trove directly; keep the minted satUSD.
        deal(BTCB, maker, 2 ether);
        vm.startPrank(maker);
        IERC20(BTCB).approve(XAPP, 2 ether);
        IRiverXApp(XAPP).openTrove(TM, maker, MAX_FEE, 2 ether, 3000e18, address(0), address(0));
        IRiverXApp(XAPP).setDelegateApproval(address(repayModule), true);
        IRiverXApp(XAPP).setDelegateApproval(address(preFund), true);
        IERC20(SAT_USD).approve(address(permit3), type(uint256).max);
        vm.stopPrank();
    }

    function _debt() internal view returns (uint256 d) {
        (d,,,) = IRiverTroveManager(TM).getEntireDebtAndColl(maker);
    }

    /// (5) The trust premise: a fake TM that passes the module's `debtToken()` pin is
    /// rejected by the deployed diamond.
    function test_audit_L_LRG_5_diamondRejectsUnregisteredTroveManager() public {
        FakeRiverTM fake = new FakeRiverTM(SAT_USD, BTCB);
        assertEq(fake.debtToken(), SAT_USD, "the fake passes the module pin");

        vm.prank(maker);
        permit3.approveToken(address(repayModule), SAT_USD, uint160(100e18), 0);
        uint256 debtBefore = _debt();

        vm.prank(settlement);
        vm.expectRevert(bytes("Collateral not enabled")); // the diamond's TM registry check
        repayModule.makeOnBehalf(maker, 100e18, abi.encode(XAPP, address(fake), SAT_USD, address(0), address(0)));
        assertEq(_debt(), debtBefore, "real trove untouched");
    }

    /// (2) The pull repay module on the live venue.
    function test_audit_L_LRG_5_riverPullRepay_live_partial() public {
        uint256 amount = 500e18;
        vm.prank(maker);
        permit3.approveToken(address(repayModule), SAT_USD, uint160(amount), 0);
        uint256 debtBefore = _debt();
        uint256 balBefore = IERC20(SAT_USD).balanceOf(maker);

        vm.prank(settlement);
        repayModule.makeOnBehalf(maker, amount, abi.encode(XAPP, TM, SAT_USD, address(0), address(0)));

        assertEq(debtBefore - _debt(), amount, "debt retired by the slice");
        assertEq(balBefore - IERC20(SAT_USD).balanceOf(maker), amount, "pulled exactly the slice");
        assertEq(IERC20(SAT_USD).balanceOf(address(repayModule)), 0, "module holds nothing");
    }

    /// The venue premise both repay modules' `FullCloseNotSupported` rests on: the
    /// live diamond REJECTS retiring the whole debt (unlike Liquity v2, which clamps).
    function test_audit_L_LRG_4_venuePremise_fullDebtRepayReverts() public {
        uint256 debt = _debt();
        deal(SAT_USD, maker, debt);
        vm.prank(maker);
        // Observed: an arithmetic underflow inside the diamond (the entire debt
        // includes the non-repayable gas-compensation reserve) — opaque, which is
        // exactly why the modules name the case themselves.
        vm.expectRevert(stdError.arithmeticError);
        IRiverXApp(XAPP).repayDebt(TM, maker, debt, address(0), address(0));
    }

    /// The pre-fund module now names that case instead of an opaque venue revert.
    function test_audit_L_LRG_4_preFundRepay_overDebt_namedRevert_live() public {
        uint256 debt = _debt();
        uint256 forAmount = debt + 10e18;
        deal(SAT_USD, address(preFund), forAmount);
        uint256 desc = (uint256(1) << 255) | (uint256(1) << 253) | (uint256(uint160(SAT_USD)) << 16)
            | (uint256(RiverPreFundModule.Op.Repay) << 244);

        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(RiverPreFundModule.FullCloseNotSupported.selector, debt));
        preFund.makeOnBehalf(maker, forAmount, abi.encode(desc, XAPP, TM, SAT_USD, address(0), address(0)));
    }
}
