// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Permit3} from "@core/permit3/Permit3.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {GearboxCreditBorrowModule, GearboxCreditAuth} from "../../src/GearboxV3Modules.sol";
import {ICreditAccountV3, ICreditManagerV3} from "../../src/interfaces/IGearboxV3.sol";

/// @title GearboxV3ForkAuthTest
/// @notice Ethereum-mainnet fork validation of the credit-account ownership
///         binding — the sibling of `LiquityV2ForkAuth.t.sol`.
///
///  The unit tests run against mocks, so they can only prove the module matches MY
///  model of Gearbox. This proves the model is real: that the three getters the
///  binding derives (`creditAccount.creditManager()`,
///  `creditManager.creditFacade()`, `creditManager.getBorrowerOrRevert()`) exist
///  and round-trip on a live credit suite. The equivalent check on Liquity found a
///  genuine bug (its chain had to be rerooted), which is why it is worth pinning
///  here even though this one resolved correctly first time.
///
///  Addresses are the wstETH credit suite, the same deployment the 1delta composer
///  fork-tests against (`test/composer/lending/gearbox/GearboxV3Fork.t.sol`).
contract GearboxV3ForkAuthTest is Test {
    address internal constant CREDIT_MANAGER = 0x9fB5493dEb601A0329ad8bFF43cD182a61321ca7;
    address internal constant CREDIT_FACADE = 0xE667676B28C270f5478299CF136Db5407Bf384Ce;
    /// @dev A live credit account of that manager at the pinned block.
    address internal constant CREDIT_ACCOUNT = 0xd4Bab1f9AF7Bd43fc9D048e6423aEb0F21B4f19A;
    address internal constant BORROWER = 0x9f127B66B1620D97de98746C27e245612E40285c;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    uint256 internal constant FORK_BLOCK = 25_600_000;

    Permit3 internal permit3;
    GearboxCreditBorrowModule internal borrowModule;

    address internal settlement = address(0x5E77);
    address internal attacker = address(0xBAD);

    function _forkMainnet() internal {
        try vm.envString("ETH_RPC_URL") returns (string memory v) {
            if (bytes(v).length > 0 && _tryFork(v)) return;
        } catch {}
        if (_tryFork("https://gateway.tenderly.co/public/mainnet")) return;
        revert("GearboxV3Fork: no archive-capable mainnet RPC (set ETH_RPC_URL)");
    }

    function _tryFork(string memory rpc) internal returns (bool) {
        try this.__fork(rpc) {
            return true;
        } catch {
            return false;
        }
    }

    function __fork(string calldata rpc) external {
        vm.createSelectFork(rpc, FORK_BLOCK);
    }

    function setUp() public {
        _forkMainnet();
        permit3 = new Permit3();
        borrowModule = new GearboxCreditBorrowModule(address(permit3));
        vm.label(CREDIT_MANAGER, "CreditManager");
        vm.label(CREDIT_ACCOUNT, "CreditAccount");
        vm.label(BORROWER, "borrower");
    }

    function _data(address creditAccount) internal pure returns (bytes memory) {
        return abi.encode(creditAccount, WSTETH);
    }

    // ──────────────── The address chain ────────────────

    /// Pins every getter `GearboxCreditAuth` derives. All three selectors also
    /// match the 1delta composer's hardcoded, production-verified constants
    /// (0xc12c21c0 / 0x2f7a1881 / 0xc53afb1e).
    function test_authChain_resolvesOnMainnet() public view {
        assertEq(ICreditAccountV3(CREDIT_ACCOUNT).creditManager(), CREDIT_MANAGER, "ca.creditManager()");
        assertEq(ICreditManagerV3(CREDIT_MANAGER).creditFacade(), CREDIT_FACADE, "cm.creditFacade()");
        assertEq(
            ICreditManagerV3(CREDIT_MANAGER).getBorrowerOrRevert(CREDIT_ACCOUNT), BORROWER, "cm.getBorrowerOrRevert()"
        );
    }

    /// An address that is not one of this manager's accounts REVERTS rather than
    /// resolving to `address(0)` — the property that makes a fabricated account
    /// fail closed instead of matching a zero principal.
    function test_unknownAccount_failsClosed() public {
        vm.expectRevert();
        ICreditManagerV3(CREDIT_MANAGER).getBorrowerOrRevert(address(0xDEAD));
    }

    // ──────────────── The attack, against a REAL credit account ────────────────

    /// The drain, on real mainnet state. The attacker self-approves a ref computed
    /// over the victim's live credit account and has their own order filled;
    /// Permit3's gate passes and only the module's binding stops it.
    function test_attacker_cannot_borrow_against_real_account() public {
        bytes memory victimData = _data(CREDIT_ACCOUNT);

        vm.prank(attacker);
        permit3.approveTaker(settlement, keccak256(victimData), type(uint160).max, 0);

        vm.prank(settlement);
        vm.expectRevert(GearboxCreditAuth.InvalidCaller.selector);
        permit3.take(address(borrowModule), attacker, uint160(1e18), attacker, victimData);
    }

    /// The control: the REAL borrower gets past the binding. The call still reverts
    /// — this module is not registered as a bot on that account — but it must fail
    /// for that reason, NOT with `InvalidCaller`. Without this, the test above
    /// could be passing for an unrelated reason.
    function test_realBorrower_passesTheBinding() public {
        bytes memory data = _data(CREDIT_ACCOUNT);

        vm.prank(BORROWER);
        permit3.approveTaker(settlement, keccak256(data), type(uint160).max, 0);

        vm.prank(settlement);
        (bool ok, bytes memory ret) = address(permit3)
            .call(abi.encodeCall(IPermit3.take, (address(borrowModule), BORROWER, uint160(1e18), BORROWER, data)));
        assertFalse(ok, "not registered as a bot, so the dispatch still fails");

        bytes4 sel;
        if (ret.length >= 4) {
            assembly {
                sel := mload(add(ret, 0x20))
            }
        }
        assertTrue(sel != GearboxCreditAuth.InvalidCaller.selector, "must NOT fail on the ownership binding");
    }
}
