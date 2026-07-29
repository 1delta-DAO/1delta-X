// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    GearboxCreditBorrowModule,
    GearboxCreditAddCollateralModule,
    GearboxCreditAuth
} from "../../src/GearboxV3Modules.sol";
import {MultiCall} from "../../src/interfaces/IGearboxV3.sol";

/// @dev Minimal stand-ins for the Gearbox credit stack. Only the three views the
///      auth chain reads plus `botMulticall` are modelled — enough to exercise
///      the binding without a mainnet fork.
contract MockCreditManager {
    address public creditFacade;
    mapping(address => address) public borrowers; // creditAccount => owner

    error NoBorrower();

    constructor(address _facade) {
        creditFacade = _facade;
    }

    function setBorrower(address creditAccount, address owner) external {
        borrowers[creditAccount] = owner;
    }

    /// @dev Mirrors Gearbox: reverts for an account this manager does not know.
    function getBorrowerOrRevert(address creditAccount) external view returns (address) {
        address b = borrowers[creditAccount];
        if (b == address(0)) revert NoBorrower();
        return b;
    }
}

contract MockCreditAccount {
    address public creditManager;

    constructor(address _cm) {
        creditManager = _cm;
    }
}

contract MockFacade {
    /// @dev Records that the drain actually reached Gearbox, so a test asserting
    ///      "no call happened" cannot pass vacuously.
    uint256 public callCount;

    function botMulticall(address, MultiCall[] calldata) external {
        callCount++;
    }
}

/// @title GearboxCreditAccountAuthTest
/// @notice Regression tests for the credit-account ownership binding. Mirrors the
///         1delta composer's `test_gearboxV3_unauthorized_caller_cannot_drain_ca`
///         and `test_gearboxV3_fake_ca_cannot_drain_real_ca` (see
///         `contracts/1delta/composer/lending/GEARBOX.md` rows A1–A3).
///
///         The attack these pin: Permit3's taker book is keyed by the APPROVER, so
///         an attacker can self-approve a `ref` computed over a VICTIM's credit
///         account and sign their own order carrying it. Gearbox's own auth cannot
///         stop this — it authorises the bot (the module), which is registered on
///         every onboarded account. Only the module's borrower check does.
contract GearboxCreditAccountAuthTest is Test {
    GearboxCreditBorrowModule borrowModule;
    GearboxCreditAddCollateralModule depositModule;

    MockFacade facade;
    MockCreditManager cm;
    address victimCA;

    address permit3 = address(0xBEEF);
    address settlement = address(0x5E77);
    address victim = address(0xA11CE);
    address attacker = address(0xBAD);
    address asset = address(0xA55E7);

    function setUp() public {
        borrowModule = new GearboxCreditBorrowModule(permit3);
        depositModule = new GearboxCreditAddCollateralModule(permit3, settlement);

        facade = new MockFacade();
        cm = new MockCreditManager(address(facade));
        victimCA = address(new MockCreditAccount(address(cm)));
        cm.setBorrower(victimCA, victim);
    }

    // ──────────────── A1: impersonated principal ────────────────

    /// The core drain. The attacker is the Permit3 principal (they self-approved
    /// the ref and signed their own order) but names the VICTIM's credit account.
    function test_attacker_cannot_borrow_against_victim_account() public {
        vm.prank(permit3); // gate 1 passes: the call really does come from Permit3
        vm.expectRevert(GearboxCreditAuth.InvalidCaller.selector);
        borrowModule.takeOnBehalf(attacker, 1e18, attacker, abi.encode(victimCA, asset));

        assertEq(facade.callCount(), 0, "botMulticall must never be reached");
    }

    /// The same binding on the deposit leg — an attacker must not be able to shove
    /// funds into someone else's account either.
    function test_attacker_cannot_add_collateral_to_victim_account() public {
        vm.prank(settlement);
        vm.expectRevert(GearboxCreditAuth.InvalidCaller.selector);
        depositModule.makeOnBehalf(attacker, 1e18, abi.encode(victimCA, asset));

        assertEq(facade.callCount(), 0, "botMulticall must never be reached");
    }

    /// Sanity: the check is a real binding, not a blanket revert. The genuine owner
    /// passes auth and reaches Gearbox.
    function test_owner_reaches_gearbox() public {
        vm.prank(permit3);
        borrowModule.takeOnBehalf(victim, 1e18, victim, abi.encode(victimCA, asset));

        assertEq(facade.callCount(), 1, "owner's borrow reached botMulticall");
    }

    // ──────────────── A2/A3: fabricated account ────────────────

    /// A fabricated account that reports the REAL manager fails closed, because
    /// `getBorrowerOrRevert` does not know it.
    function test_fake_account_reporting_real_manager_reverts() public {
        address fakeCA = address(new MockCreditAccount(address(cm))); // never registered

        vm.prank(permit3);
        vm.expectRevert(MockCreditManager.NoBorrower.selector);
        borrowModule.takeOnBehalf(attacker, 1e18, attacker, abi.encode(fakeCA, asset));

        assertEq(facade.callCount(), 0, "real facade untouched");
    }

    /// A fully attacker-owned chain (fake account -> fake manager that lies about
    /// the borrower) passes auth, but dispatch follows the SAME chain — so it lands
    /// on the attacker's own facade and the real one is never reached. This is why
    /// the facade must be DERIVED: taking it from calldata would let authorization
    /// read the fake chain while dispatch hit the real account.
    function test_fake_chain_cannot_reach_real_facade() public {
        MockFacade fakeFacade = new MockFacade();
        MockCreditManager fakeCm = new MockCreditManager(address(fakeFacade));
        address fakeCA = address(new MockCreditAccount(address(fakeCm)));
        fakeCm.setBorrower(fakeCA, attacker); // the lie
        fakeCm.setBorrower(victimCA, attacker); // and a lie about the victim's CA

        vm.prank(permit3);
        borrowModule.takeOnBehalf(attacker, 1e18, attacker, abi.encode(fakeCA, asset));

        assertEq(fakeFacade.callCount(), 1, "attacker only reached their own facade");
        assertEq(facade.callCount(), 0, "real facade untouched");
    }

    // ──────────────── Bot registration ────────────────

    /// `BotListV3.setBotPermissions` enforces an EXACT match against the bot's
    /// published mask, so these values are consensus-critical: a wrong mask makes
    /// the module unregisterable (and previously, having no `requiredPermissions()`
    /// at all made these modules impossible to onboard).
    function test_requiredPermissions_masks() public view {
        // INCREASE_DEBT (bit 1) | WITHDRAW_COLLATERAL (bit 5)
        assertEq(borrowModule.requiredPermissions(), 0x22, "borrow mask");
        // ADD_COLLATERAL (bit 0) only — deposit can never draw debt.
        assertEq(depositModule.requiredPermissions(), 0x01, "deposit mask");
    }
}
