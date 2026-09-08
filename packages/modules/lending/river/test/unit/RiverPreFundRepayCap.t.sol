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
}

/// @dev TroveManager stand-in with a settable live debt.
contract MockPreFundTM {
    uint256 public debt;

    function setDebt(uint256 d) external {
        debt = d;
    }

    function getEntireDebtAndColl(address) external view returns (uint256, uint256, uint256, uint256) {
        return (debt, 0, 0, 0);
    }
}

/// @dev XApp stand-in whose `repayDebt` pulls the burn from the CALLER's scoped
///      allowance — the real diamond's value-in shape.
contract MockPreFundXApp {
    PreFundToken public immutable debtToken;
    MockPreFundTM public immutable tm;

    constructor(PreFundToken _debt, MockPreFundTM _tm) {
        debtToken = _debt;
        tm = _tm;
    }

    function repayDebt(address, address, uint256 amount, address, address) external {
        debtToken.transferFrom(msg.sender, address(this), amount);
        tm.setDebt(tm.debt() - amount);
    }
}

/// @title RiverPreFundRepayCapTest
/// @notice The cap-at-debt + surplus-sweep branch of {RiverPreFundModule},
///         which the live venue cannot exercise: retiring the ENTIRE debt via
///         `repayDebt` violates the minimum-net-debt rule (a full close is
///         `closeTrove`), so the fork suite only covers the partial-repay path.
///         Against a mock the overshoot is provable: the module repays exactly
///         the live debt and sweeps the delivered surplus to the maker —
///         funding the whole flow from its OWN balance, never a pull. The mock
///         token's `transferFrom` reverts on a missing allowance, and the maker
///         granted none: the happy path passing IS the no-`transferFrom` proof.
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

    function test_preFundRepay_capsAtDebt_andSweepsSurplusToMaker() public {
        tm.setDebt(1_000e18);
        // The core-delivered leg: 1500 satUSD already sitting on the module.
        satUSD.mint(address(preFund), 1_500e18);

        vm.prank(address(settlement));
        preFund.makeOnBehalf(MAKER, 1_500e18, _data());

        assertEq(tm.debt(), 0, "the debt is retired in full");
        assertEq(satUSD.balanceOf(MAKER), 500e18, "the surplus was swept to the maker");
        assertEq(satUSD.balanceOf(address(preFund)), 0, "module drained");
        assertEq(satUSD.balanceOf(address(xapp)), 1_000e18, "the venue received exactly the debt");
        assertEq(satUSD.allowance(address(preFund), address(xapp)), 0, "scoped approval cleared");
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
        tm.setDebt(1_000e18);
        satUSD.mint(address(preFund), 1_500e18); //  this fill's delivery
        satUSD.mint(address(preFund), 3e18); //     another fill's stranded dust

        vm.prank(address(settlement));
        preFund.makeOnBehalf(MAKER, 1_500e18, _data());

        assertEq(satUSD.balanceOf(MAKER), 500e18, "exactly this fill's surplus, not the dust");
        assertEq(satUSD.balanceOf(address(preFund)), 3e18, "the module ends where it started");
    }

    function test_preFundRepay_zeroForAmount_isANoOp() public {
        tm.setDebt(1_000e18);
        vm.prank(address(settlement));
        preFund.makeOnBehalf(MAKER, 0, _data());
        assertEq(tm.debt(), 1_000e18, "dust slice skipped");
    }
}
