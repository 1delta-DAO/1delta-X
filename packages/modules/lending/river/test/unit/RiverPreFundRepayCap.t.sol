// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {RiverPreFundModule} from "../../src/RiverPreFundModules.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";

/// @dev Mock satUSD in the RvrToken shape (see test/unit/RiverProceeds.t.sol):
///      transferFrom UNDERFLOWS on a missing allowance, so a module that tried
///      to pull from the maker would revert this suite loudly.
contract PreFundToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }

    /// @dev satUSD's privileged burn — the diamond retires debt with NO allowance.
    function burn(address f, uint256 a) external {
        balanceOf[f] -= a;
    }
}

/// @dev TroveManager stand-in with a settable live debt.
contract MockPreFundTM {
    uint256 public debt;
    address public debtToken;

    function setDebtToken(address t) external {
        debtToken = t;
    }

    function setDebt(uint256 d) external {
        debt = d;
    }

    function getEntireDebtAndColl(address) external view returns (uint256, uint256, uint256, uint256) {
        return (debt, 0, 0, 0);
    }
}

/// @dev XApp stand-in modelled on the DEPLOYED diamond (fork-verified 2026-09-12):
///      `repayDebt` BURNS the real satUSD from `msg.sender` with NO allowance, and
///      rejects a repay that would leave net debt below the minimum (retiring the
///      whole debt reverts). It used to pull via `transferFrom` against the
///      module's scoped approval and accept a full repay, so the unit suite could
///      express neither the measured-vs-burned class (F28 #6) nor the min-debt
///      revert (2026-09-30 audit, L-LRG-5 (7)).
contract MockPreFundXApp {
    PreFundToken public immutable debtToken;
    MockPreFundTM public immutable tm;
    uint256 public constant MIN_NET_DEBT = 10e18;

    constructor(PreFundToken _debt, MockPreFundTM _tm) {
        debtToken = _debt;
        tm = _tm;
    }

    function repayDebt(address, address, uint256 amount, address, address) external {
        require(tm.debt() - amount >= MIN_NET_DEBT, "net debt below minimum");
        debtToken.burn(msg.sender, amount);
        tm.setDebt(tm.debt() - amount);
    }
}

/// @title RiverPreFundRepayCapTest
/// @notice The live-debt cap of {RiverPreFundModule}. Retiring the ENTIRE debt via
///         `repayDebt` violates the venue's minimum-net-debt rule (a full close is
///         `closeTrove`), so the cap's saturating case is a named
///         `FullCloseNotSupported` revert, as on the pull sibling — this suite used
///         to assert the debt "retired in full", an outcome the live venue
///         rejects (2026-09-30 audit, L-LRG-4/L-LRG-5). Below the debt the module
///         funds the repay from its OWN balance, never a pull: the mock token's
///         `transferFrom` reverts on a missing allowance and the maker granted none.
contract RiverPreFundRepayCapTest is Test {
    RiverPreFundModule preFund;
    address settlement = address(0x5E77);
    /// @dev Permit3 stand-in address — the module only gates `msg.sender` on it.
    address constant PERMIT3 = address(0xBEEF);
    address constant MAKER = address(0xA11CE);

    PreFundToken satUSD;
    MockPreFundTM tm;
    MockPreFundXApp xapp;

    function setUp() public {
        satUSD = new PreFundToken();
        tm = new MockPreFundTM();
        tm.setDebtToken(address(satUSD));
        xapp = new MockPreFundXApp(satUSD, tm);
        preFund = new RiverPreFundModule(PERMIT3, address(settlement));
    }

    function _forLeg(uint256 index, address token) internal view returns (uint256) {
        // bit 255 = leg reference; bit 253 = the PRE-FUND shape, which makes the core
        // require `legsOut[index].recipient == module` (F27/H-1).
        // Repay-only fixture: the op rides in descriptor bits [244,252).
        return (uint256(1) << 255) | (uint256(1) << 253) | (uint256(uint160(token)) << 16)
            | (uint256(RiverPreFundModule.Op.Repay) << 244) | index;
    }

    function _data() internal view returns (bytes memory) {
        return abi.encode(_forLeg(0, address(satUSD)), address(xapp), address(tm), address(satUSD), address(0), address(0));
    }

    /// REPLACES `test_preFundRepay_capsAtDebt_andSweepsSurplusToMaker`, which asserted
    /// the debt retired to 0 — the outcome the live diamond rejects.
    function test_audit_L_LRG_4_preFundRepay_overDebt_failsClosedNamed() public {
        tm.setDebt(1_000e18);
        satUSD.mint(address(preFund), 1_500e18);

        vm.prank(address(settlement));
        vm.expectRevert(abi.encodeWithSelector(RiverPreFundModule.FullCloseNotSupported.selector, 1_000e18));
        preFund.makeOnBehalf(MAKER, 1_500e18, _data());
    }

    function test_preFundRepay_belowDebt_repaysFromOwnBalance() public {
        tm.setDebt(2_000e18);
        satUSD.mint(address(preFund), 1_500e18);

        vm.prank(address(settlement));
        preFund.makeOnBehalf(MAKER, 1_500e18, _data());

        assertEq(tm.debt(), 500e18, "the delivery retired that much debt");
        assertEq(satUSD.balanceOf(address(preFund)), 0, "module drained");
        assertEq(satUSD.allowance(address(preFund), address(xapp)), 0, "scoped approval cleared");
    }

    /// L-LRG-5 (1)/(7): the debt-token pin, now expressible because the mock burns
    /// the REAL token from the module with no allowance. A maker naming a worthless
    /// token is rejected before anything is measured or burned — the module's real
    /// satUSD residue is untouched.
    function test_audit_L_LRG_5_preFundRepay_misnamedDebtToken_reverts() public {
        PreFundToken fake = new PreFundToken();
        tm.setDebt(2_000e18);
        satUSD.mint(address(preFund), 50e18); // real residue on the singleton
        fake.mint(address(preFund), 100e18);
        bytes memory data = abi.encode(
            _forLeg(0, address(fake)), address(xapp), address(tm), address(fake), address(0), address(0)
        );

        vm.prank(address(settlement));
        vm.expectRevert(
            abi.encodeWithSelector(RiverPreFundModule.DebtTokenMismatch.selector, address(fake), address(satUSD))
        );
        preFund.makeOnBehalf(MAKER, 100e18, data);
        assertEq(satUSD.balanceOf(address(preFund)), 50e18, "real satUSD residue untouched");
        assertEq(tm.debt(), 2_000e18, "no debt retired");
    }

    function test_preFundRepay_zeroDebt_sweepsEverythingToMaker() public {
        tm.setDebt(0);
        satUSD.mint(address(preFund), 700e18);

        vm.prank(address(settlement));
        preFund.makeOnBehalf(MAKER, 700e18, _data());

        assertEq(satUSD.balanceOf(MAKER), 700e18, "with no debt the whole delivery is the maker's");
        assertEq(satUSD.balanceOf(address(preFund)), 0, "module drained");
    }

    function test_preFundRepay_neverTouchesStrandedDust() public {
        tm.setDebt(2_000e18);
        satUSD.mint(address(preFund), 1_500e18); //  this fill's delivery
        satUSD.mint(address(preFund), 3e18); //     another fill's stranded dust

        vm.prank(address(settlement));
        preFund.makeOnBehalf(MAKER, 1_500e18, _data());

        assertEq(satUSD.balanceOf(MAKER), 0, "the whole delivery was burned; the dust is not swept out");
        assertEq(tm.debt(), 500e18, "only this fill's delivery was burned");
        assertEq(satUSD.balanceOf(address(preFund)), 3e18, "the module ends where it started");
    }

    function test_preFundRepay_zeroForAmount_isANoOp() public {
        tm.setDebt(1_000e18);
        vm.prank(address(settlement));
        preFund.makeOnBehalf(MAKER, 0, _data());
        assertEq(tm.debt(), 1_000e18, "dust slice skipped");
    }
}
