// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Permit3} from "@core/permit3/Permit3.sol";
import {IProceedsAsset} from "@core/interfaces/IProceedsAsset.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";

import {AaveV3CreditModule} from "../../src/AaveV3CreditModule.sol";
import {AaveV3WithdrawModule} from "../../src/AaveV3Modules.sol";

contract AuditCreditTok {
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
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

/// @dev A pool that would happily pay a borrow to whoever asks — so a test that
///      reverts is proving the MODULE refused, not that the venue was absent.
contract AuditOpenPool {
    AuditCreditTok public immutable borrowTok;

    constructor(AuditCreditTok t) {
        borrowTok = t;
    }

    function borrow(address, uint256 amount, uint256, uint16, address) external {
        borrowTok.mint(msg.sender, amount);
    }

    function supply(address asset, uint256 amount, address, uint16) external {
        AuditCreditTok(asset).transferFrom(msg.sender, address(this), amount);
    }
}

/// @title Audit20260930CreditModuleTest
/// @notice 2026-09-30 audit, L-AAVE-5 (2)/(4): `AaveV3CreditModule` is the one
///         contract where a permissionless primitive (`Permit3.takeFor`) and a
///         pre-fund body meet (I-7), yet its funding-seam guards had no negative
///         test — the pins were enforced only syntactically by the shapes checker.
///         Each case below drives the guard with an otherwise-working venue.
contract Audit20260930CreditModuleTest is Test {
    Permit3 permit3;
    AuditCreditTok collat;
    AuditCreditTok debt;
    AuditOpenPool pool;
    AaveV3CreditModule credit;

    address constant SETTLEMENT = address(0x5E77);
    address constant MALLORY = address(0xBAD);
    address constant VICTIM = address(0xB0B);

    function setUp() public {
        permit3 = new Permit3();
        collat = new AuditCreditTok();
        debt = new AuditCreditTok();
        pool = new AuditOpenPool(debt);
        credit = new AaveV3CreditModule(address(permit3), SETTLEMENT);
    }

    /// `(5 << 253)` leg reference + PRE-FUND, op Leverage in bits [244,252), the
    /// funding token in bits [16,176).
    function _preFundDesc(address token) internal pure returns (uint256) {
        return (uint256(5) << 253) | (uint256(AaveV3CreditModule.Op.Leverage) << 244) | (uint256(uint160(token)) << 16);
    }

    function _fundedData(uint256 desc, address collateralAsset) internal view returns (bytes memory) {
        return abi.encode(desc, uint256(0), address(pool), address(debt), uint256(2), collateralAsset);
    }

    /// I-7 / F27-C-1: a caller that grants ITSELF taker allowance and calls the
    /// permissionless `Permit3.takeFor` is refused by the spender pin — the module
    /// never funds `forAmount` out of its own balance for a non-Settlement caller.
    function test_audit_L_AAVE_5_selfGrantedTakeFor_refused() public {
        collat.mint(address(credit), 100e18); // a stranded balance worth stealing
        bytes memory data = _fundedData(_preFundDesc(address(collat)), address(collat));

        vm.startPrank(MALLORY);
        permit3.approveTaker(MALLORY, address(credit), keccak256(data), type(uint160).max, 0);
        vm.expectRevert(PreFundGuard.OnlySettlement.selector);
        permit3.takeFor(address(credit), MALLORY, 1, 100e18, MALLORY, data);
        vm.stopPrank();
        assertEq(collat.balanceOf(address(credit)), 100e18, "stranded balance untouched");
    }

    /// The literal funding form overlaps the plain-take data space, so the funding
    /// seam refuses it even from the pinned Settlement.
    function test_audit_L_AAVE_5_literalDescriptor_refused() public {
        bytes memory data = _fundedData(uint256(1e18), address(collat)); // literal: >> 253 == 0
        vm.prank(address(permit3));
        vm.expectRevert(PreFundGuard.LiteralDescriptorNotAllowed.selector);
        credit.takeForOnBehalf(SETTLEMENT, VICTIM, 1, 1e18, SETTLEMENT, data);
    }

    /// The descriptor names token A, the module would spend collateral token B:
    /// the pre-fund floor refuses the mis-pairing.
    function test_audit_L_AAVE_5_preFundTokenMismatch_refused() public {
        AuditCreditTok other = new AuditCreditTok();
        other.mint(address(credit), 1e18); // as if a delivery of `other` had landed
        bytes memory data = _fundedData(_preFundDesc(address(collat)), address(other));
        vm.prank(address(permit3));
        vm.expectRevert(PreFundGuard.FundingTokenMismatch.selector);
        credit.takeForOnBehalf(SETTLEMENT, VICTIM, 1, 1e18, SETTLEMENT, data);
    }

    /// A bare Borrow has no funding leg; it is not reachable on the funding seam.
    function test_audit_L_AAVE_5_borrowOpOnFundingSeam_refused() public {
        uint256 desc = (uint256(5) << 253) | (uint256(AaveV3CreditModule.Op.Borrow) << 244)
            | (uint256(uint160(address(collat))) << 16);
        bytes memory data = _fundedData(desc, address(collat));
        vm.prank(address(permit3));
        vm.expectRevert(abi.encodeWithSelector(AaveV3CreditModule.BadOp.selector, uint256(0)));
        credit.takeForOnBehalf(SETTLEMENT, VICTIM, 1, 1e18, SETTLEMENT, data);
    }

    /// (4) A victim's standing credit delegation to the module is not consumable by
    /// a third party: Permit3's taker book is keyed by the USER and the SPENDER, so
    /// neither a direct `take` nor a self-granted `takeFor` naming the victim moves
    /// anything without the victim's own grant.
    function test_audit_L_AAVE_5_victimDelegation_notConsumableByThirdParty() public {
        bytes memory borrowData = abi.encode(uint256(AaveV3CreditModule.Op.Borrow), address(pool), address(debt), uint256(2));
        vm.startPrank(MALLORY);
        permit3.approveTaker(MALLORY, address(credit), keccak256(borrowData), type(uint160).max, 0); // own book only
        vm.expectRevert();
        permit3.take(address(credit), VICTIM, 1_000e18, MALLORY, borrowData);
        vm.stopPrank();
        assertEq(debt.balanceOf(MALLORY), 0, "no borrow on the victim's credit line");
    }

    /// The module declares its proceeds (pre-existing IProceedsAsset; pinned here so
    /// the L-CMT-6 coverage table includes the aave-v3 taker modules).
    function test_audit_L_CMT_6_aaveV3_takers_declareProceeds() public {
        bytes memory borrowData = abi.encode(uint256(AaveV3CreditModule.Op.Borrow), address(pool), address(debt), uint256(2));
        assertEq(IProceedsAsset(address(credit)).proceedsAsset(borrowData), address(debt));
        AaveV3WithdrawModule w = new AaveV3WithdrawModule(address(permit3));
        assertEq(IProceedsAsset(address(w)).proceedsAsset(abi.encode(address(pool), address(collat), address(0xA7))), address(collat));
    }
}
