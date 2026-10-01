// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Permit3} from "@core/permit3/Permit3.sol";

import {RiverRepayModule, RiverTakerModule} from "../../src/RiverModules.sol";
import {PreFundToken} from "./RiverPreFundRepayCap.t.sol";

/// @dev Per-account TroveManager stand-in.
contract AuditRiverTM {
    address public debtToken;
    mapping(address => uint256) public debtOf;

    constructor(address d) {
        debtToken = d;
    }

    function setDebt(address a, uint256 d) external {
        debtOf[a] = d;
    }

    function getEntireDebtAndColl(address a) external view returns (uint256, uint256, uint256, uint256) {
        return (debtOf[a], 0, 0, 0);
    }
}

/// @dev Diamond stand-in with the deployed semantics: caller-or-delegate check on
///      every op keyed by `account`, `repayDebt` burns from `msg.sender` with no
///      allowance and enforces a minimum net debt, value-out lands on `msg.sender`.
contract AuditRiverXApp {
    PreFundToken public immutable satUSD;
    AuditRiverTM public immutable tm;
    mapping(address => mapping(address => bool)) public isApprovedDelegate;
    uint256 public constant MIN_NET_DEBT = 10e18;

    constructor(PreFundToken s, AuditRiverTM t) {
        satUSD = s;
        tm = t;
    }

    function setDelegateApproval(address d, bool ok) external {
        isApprovedDelegate[msg.sender][d] = ok;
    }

    function _auth(address account) internal view {
        require(msg.sender == account || isApprovedDelegate[account][msg.sender], "Caller not approved");
    }

    function repayDebt(address, address account, uint256 amount, address, address) external {
        _auth(account);
        require(tm.debtOf(account) - amount >= MIN_NET_DEBT, "net debt below minimum");
        satUSD.burn(msg.sender, amount);
        tm.setDebt(account, tm.debtOf(account) - amount);
    }

    function withdrawDebt(address, address account, uint256, uint256 amount, address, address) external {
        _auth(account);
        tm.setDebt(account, tm.debtOf(account) + amount);
        satUSD.mint(msg.sender, amount);
    }
}

/// @title 2026-09-30 audit, L-LRG-5 — River pull repay module and cross-principal binding.
/// @notice `RiverRepayModule` was never instantiated by any test (L-LRG-5 (2)), its
///         `DebtTokenMismatch` pin had no negative test (L-LRG-5 (1)), and River had
///         no cross-principal negative (L-LRG-5 (6)): the binding is structural —
///         every venue call passes `account = onBehalfOf` — and this pins it.
contract AuditRiverModulesTest is Test {
    Permit3 permit3;
    PreFundToken satUSD;
    AuditRiverTM tm;
    AuditRiverXApp xapp;
    RiverRepayModule repayModule;
    RiverTakerModule takerModule;

    address settlement = address(0x5E77);
    address maker = address(0xA11CE);
    address attacker = address(0xBAD);
    address receiver = address(0xFEE);

    function setUp() public {
        permit3 = new Permit3();
        satUSD = new PreFundToken();
        tm = new AuditRiverTM(address(satUSD));
        xapp = new AuditRiverXApp(satUSD, tm);
        repayModule = new RiverRepayModule(address(permit3), settlement);
        takerModule = new RiverTakerModule(address(permit3));

        tm.setDebt(maker, 2_000e18);
        vm.startPrank(maker);
        xapp.setDelegateApproval(address(repayModule), true);
        xapp.setDelegateApproval(address(takerModule), true);
        satUSD.approve(address(permit3), type(uint256).max);
        vm.stopPrank();
    }

    function _repayData(address token) internal view returns (bytes memory) {
        return abi.encode(address(xapp), address(tm), token, address(0), address(0));
    }

    function _grant(uint256 amount) internal {
        satUSD.mint(maker, amount);
        vm.prank(maker);
        permit3.approveToken(address(repayModule), address(satUSD), uint160(amount), 0);
    }

    function test_audit_L_LRG_5_riverPullRepay_partial_burnsAndSweeps() public {
        _grant(500e18);
        vm.prank(settlement);
        repayModule.makeOnBehalf(maker, 500e18, _repayData(address(satUSD)));

        assertEq(tm.debtOf(maker), 1_500e18, "debt reduced by the slice");
        assertEq(satUSD.balanceOf(maker), 0, "pulled from the maker");
        assertEq(satUSD.balanceOf(address(repayModule)), 0, "module holds nothing");
    }

    function test_audit_L_LRG_5_riverPullRepay_fullDebt_failsClosedNamed() public {
        _grant(3_000e18);
        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSelector(RiverRepayModule.FullCloseNotSupported.selector, 2_000e18));
        repayModule.makeOnBehalf(maker, 3_000e18, _repayData(address(satUSD)));
    }

    function test_audit_L_LRG_5_riverPullRepay_misnamedDebtToken_reverts() public {
        PreFundToken fake = new PreFundToken();
        vm.prank(settlement);
        vm.expectRevert(
            abi.encodeWithSelector(RiverRepayModule.DebtTokenMismatch.selector, address(fake), address(satUSD))
        );
        repayModule.makeOnBehalf(maker, 1e18, _repayData(address(fake)));
    }

    /// An attacker self-approves a taker ref over borrow data and runs it with
    /// THEMSELVES as principal: the module passes `account = onBehalfOf = attacker`,
    /// so the venue checks the ATTACKER's delegation and the victim's trove — which
    /// did delegate the module — is untouchable.
    function test_audit_L_LRG_5_riverTaker_crossPrincipal_actsOnlyOnOwnAccount() public {
        bytes memory data =
            abi.encode(uint8(0), address(xapp), address(tm), address(satUSD), uint256(0.05e18), address(0), address(0));
        vm.prank(attacker);
        permit3.approveTaker(settlement, address(takerModule), keccak256(data), type(uint160).max, 0);

        vm.prank(settlement);
        vm.expectRevert(bytes("Caller not approved"));
        permit3.take(address(takerModule), attacker, uint160(100e18), attacker, data);
        assertEq(tm.debtOf(maker), 2_000e18, "victim's trove untouched");

        // Control: the maker's own order works.
        vm.prank(maker);
        permit3.approveTaker(settlement, address(takerModule), keccak256(data), uint160(100e18), 0);
        vm.prank(settlement);
        permit3.take(address(takerModule), maker, uint160(100e18), receiver, data);
        assertEq(tm.debtOf(maker), 2_100e18, "maker's own borrow");
        assertEq(satUSD.balanceOf(receiver), 100e18, "proceeds forwarded");
    }
}
