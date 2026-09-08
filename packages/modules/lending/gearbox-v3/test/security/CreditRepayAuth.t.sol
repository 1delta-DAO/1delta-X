// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {GearboxCreditRepayModule, GearboxCreditAuth} from "../../src/GearboxV3Modules.sol";
import {IGearboxCreditFacadeV3Multicall, MultiCall} from "../../src/interfaces/IGearboxV3.sol";

contract MockERC20R {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    /// @dev Test-only, so the Permit3 stub can move custody without an allowance.
    function burnFrom(address from, uint256 amount) external {
        if (balanceOf[from] >= amount) balanceOf[from] -= amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Permit3 stub that ACTUALLY MOVES the tokens. It used to be a no-op, with
///      custody faked by pre-minting to the module — which the residual floor
///      (F25/G-1) correctly reads as a pre-existing stranded balance rather than as
///      this call's proceeds. Minting inside the pull is what makes the delta real,
///      so the sweep tests below exercise the code rather than the simulation.
contract MockPermit3R {
    function transferFrom(address from, address to, address token, uint160 amount) external {
        MockERC20R(token).burnFrom(from, amount);
        MockERC20R(token).mint(to, amount);
    }
}

contract MockCreditManagerR {
    address public creditFacade;
    mapping(address => address) public borrowers;

    error NoBorrower();

    constructor(address _facade) {
        creditFacade = _facade;
    }

    function setBorrower(address creditAccount, address owner) external {
        borrowers[creditAccount] = owner;
    }

    function getBorrowerOrRevert(address creditAccount) external view returns (address) {
        address b = borrowers[creditAccount];
        if (b == address(0)) revert NoBorrower();
        return b;
    }
}

contract MockCreditAccountR {
    address public creditManager;

    constructor(address _cm) {
        creditManager = _cm;
    }
}

/// @dev Records the multicall's sub-call selectors so the test can assert the
///      exact addCollateral → decreaseDebt sequence, not just "was called".
contract RecordingFacade {
    uint256 public callCount;
    bytes4[] public selectors;

    function botMulticall(address, MultiCall[] calldata calls) external {
        callCount++;
        for (uint256 i; i < calls.length; i++) {
            selectors.push(bytes4(calls[i].callData));
        }
    }

    function selectorCount() external view returns (uint256) {
        return selectors.length;
    }
}

/// @title GearboxCreditRepayAuthTest
/// @notice The repay leg's security + wiring: the {GearboxCreditAuth} borrower
///         binding (same drain class as borrow — Permit3's taker book is keyed by
///         the approver, so only the borrower check stops a self-approved
///         attacker), the exact bot mask, the addCollateral→decreaseDebt
///         sequence, and the end-holding-nothing residual sweep.
contract GearboxCreditRepayAuthTest is Test {
    GearboxCreditRepayModule repayModule;
    RecordingFacade facade;
    MockCreditManagerR cm;
    MockERC20R asset;
    address ca;

    address permit3;
    address settlement = address(0x5E77);
    address user = address(0xA11CE);
    address attacker = address(0xBAD);

    function setUp() public {
        permit3 = address(new MockPermit3R());
        repayModule = new GearboxCreditRepayModule(permit3, settlement);
        facade = new RecordingFacade();
        cm = new MockCreditManagerR(address(facade));
        ca = address(new MockCreditAccountR(address(cm)));
        cm.setBorrower(ca, user);
        asset = new MockERC20R();
    }

    function test_attacker_cannot_repayPath_victim_account() public {
        vm.prank(settlement);
        vm.expectRevert(GearboxCreditAuth.InvalidCaller.selector);
        repayModule.makeOnBehalf(attacker, 1e18, abi.encode(ca, address(asset)));
        assertEq(facade.callCount(), 0, "botMulticall never reached");
    }

    function test_gatedToSettlement() public {
        vm.expectRevert(GearboxCreditRepayModule.NotSettlement.selector);
        repayModule.makeOnBehalf(user, 1e18, abi.encode(ca, address(asset)));
    }

    function test_repay_sequence_addCollateralThenDecreaseDebt() public {
        vm.prank(settlement);
        repayModule.makeOnBehalf(user, 1e18, abi.encode(ca, address(asset)));

        assertEq(facade.callCount(), 1, "one multicall");
        assertEq(facade.selectorCount(), 2, "two sub-calls");
        assertEq(facade.selectors(0), IGearboxCreditFacadeV3Multicall.addCollateral.selector, "fund first");
        assertEq(facade.selectors(1), IGearboxCreditFacadeV3Multicall.decreaseDebt.selector, "then burn debt");
        assertEq(asset.allowance(address(repayModule), address(cm)), 0, "manager allowance reset");
    }

    /// @dev Anything the manager did not pull returns to the maker. The mock facade
    ///      pulls nothing, so the whole pulled amount is the residual and comes back.
    function test_repay_sweepsResidualToMaker() public {
        asset.mint(user, 1e18);
        uint256 before = asset.balanceOf(user);

        vm.prank(settlement);
        repayModule.makeOnBehalf(user, 1e18, abi.encode(ca, address(asset)));

        assertEq(asset.balanceOf(address(repayModule)), 0, "module ends where it started (empty)");
        assertEq(asset.balanceOf(user), before, "the unpulled amount came back to the maker");
    }

    /// @dev F25/G-1. A balance already sitting at the module is NOT this call's
    ///      residual: it is a donation, or someone else's stranded funds, and
    ///      sweeping it would hand it to whoever authors the next order against this
    ///      shared module. The invariant is "the module ends where it STARTED", not
    ///      "ends empty" — see {DustHandler.disposeResidual}'s floor overload.
    function test_repay_doesNotSweepAStrandedBalance() public {
        asset.mint(address(repayModule), 123e18); // stranded/donated, not this maker's
        asset.mint(user, 1e18);
        uint256 before = asset.balanceOf(user);

        vm.prank(settlement);
        repayModule.makeOnBehalf(user, 1e18, abi.encode(ca, address(asset)));

        assertEq(asset.balanceOf(address(repayModule)), 123e18, "stranded balance stays put");
        assertEq(asset.balanceOf(user), before, "maker gets back only their own unpulled amount");
    }

    function test_requiredPermissions_mask() public view {
        // ADD_COLLATERAL (bit 0) | DECREASE_DEBT (bit 2) — value-in only.
        assertEq(repayModule.requiredPermissions(), 0x05, "repay mask");
    }
}
