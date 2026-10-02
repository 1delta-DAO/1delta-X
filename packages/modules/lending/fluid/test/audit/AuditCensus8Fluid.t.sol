// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Permit3} from "@core/permit3/Permit3.sol";
import {FullFillGuard} from "@lib/FullFillGuard.sol";
import {DustHandler} from "@lib/DustHandler.sol";

import {FluidModulesBase} from "../shared/FluidModulesBase.t.sol";
import {FluidDepositModule, FluidTakerModule} from "../../src/FluidModules.sol";

/// @title 2026-09-30 audit L-CENSUS-8 — Fluid sibling asymmetries, on the LIVE vault.
/// @notice Mainnet fork against the Fluid ETH-USDC T1 vault (see {FluidModulesBase}):
///   (3) the value-in repay leg is bound to the maker's OWN position;
///   (4) `FluidRepayModule` gains a live-debt clamp — the tagged `Full` mode repays
///       ALL with Fluid's sentinel against a signed ceiling and returns the rest.
contract AuditCensus8FluidForkTest is FluidModulesBase {
    address internal stranger = address(0x5742);

    function _grantRepay(uint256 amount) internal {
        deal(USDC, maker, amount);
        vm.prank(maker);
        permit3.approveToken(address(repayModule), USDC, uint160(amount), 0);
    }

    /// (3) A signed `nftId` that is a STRANGER's position used to spend the maker's
    /// USDC paying down the stranger's debt (payback is permissionless on Fluid).
    function test_audit_L_CENSUS_8_repayRefusesStrangersPosition() public {
        uint256 strangersId = _openPosition(stranger, 1 ether, 1000e6);
        _grantRepay(500e6);

        vm.prank(address(settlement));
        try repayModule.makeOnBehalf(maker, 500e6, abi.encode(VAULT, USDC, strangersId)) {} catch {}

        assertEq(IERC20(USDC).balanceOf(maker), 500e6, "maker's USDC not spent on a stranger's debt");
    }

    /// The binding names the reason.
    function test_audit_L_CENSUS_8_repayStrangerRevertsNotPositionOwner() public {
        uint256 strangersId = _openPosition(stranger, 1 ether, 1000e6);
        _grantRepay(500e6);
        vm.prank(address(settlement));
        vm.expectRevert(abi.encodeWithSignature("NotPositionOwner(uint256,address)", strangersId, stranger));
        repayModule.makeOnBehalf(maker, 500e6, abi.encode(VAULT, USDC, strangersId));
    }

    /// (4) The live-debt clamp. The maker signs a CEILING above the debt (interest
    /// accrues between signing and the fill). An `Exact` literal over-payback reverts
    /// on Fluid; `Full` repays exactly the live debt and returns the buffer.
    function test_audit_L_CENSUS_8_fullRepayClampsAtLiveDebt() public {
        uint256 nftId = _openPosition(maker, 1 ether, 1000e6);
        vm.warp(block.timestamp + 30 days); // accrue
        uint256 ceiling = 1_100e6;
        _grantRepay(ceiling);

        bytes memory data =
            abi.encode(VAULT, USDC, nftId, DustHandler.encodeMode(DustHandler.BalanceMode.Full), ceiling);
        vm.prank(address(settlement));
        repayModule.makeOnBehalf(maker, ceiling, data);

        uint256 spent = ceiling - IERC20(USDC).balanceOf(maker);
        assertGe(spent, 1000e6, "paid at least the principal");
        assertLt(spent, 1_020e6, "paid only the live debt, buffer returned");
        assertEq(IERC20(USDC).balanceOf(address(repayModule)), 0, "module holds no residual");
        assertEq(IERC20(USDC).allowance(address(repayModule), VAULT), 0, "vault grant cleared");
        assertEq(_ownerOf(nftId), maker, "maker still owns the position");

        // The debt is gone: a further 1-unit payback has nothing to retire.
        _grantRepay(1);
        vm.prank(address(settlement));
        vm.expectRevert();
        repayModule.makeOnBehalf(maker, 1, abi.encode(VAULT, USDC, nftId));
    }

    /// `Full` is full-fill only: a slice of a ceiling is not a ceiling.
    function test_audit_L_CENSUS_8_fullRepayIsFullFillOnly() public {
        uint256 nftId = _openPosition(maker, 1 ether, 1000e6);
        _grantRepay(1_100e6);
        bytes memory data =
            abi.encode(VAULT, USDC, nftId, DustHandler.encodeMode(DustHandler.BalanceMode.Full), uint256(1_100e6));
        vm.prank(address(settlement));
        vm.expectRevert(abi.encodeWithSelector(FullFillGuard.PartialFillUnsupported.selector, 550e6, 1_100e6));
        repayModule.makeOnBehalf(maker, 550e6, data);
    }

    /// An untagged `1` is not `Full` (the DustHandler posture).
    function test_audit_L_CENSUS_8_untaggedModeWordReverts() public {
        uint256 nftId = _openPosition(maker, 1 ether, 1000e6);
        _grantRepay(100e6);
        vm.prank(address(settlement));
        vm.expectRevert(abi.encodeWithSelector(DustHandler.InvalidModeWord.selector, uint256(1)));
        repayModule.makeOnBehalf(maker, 100e6, abi.encode(VAULT, USDC, nftId, uint256(1), uint256(100e6)));
    }
}

// ─────────────────────────── unit (no fork) ───────────────────────────

contract C8Token {
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

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

contract C8Factory {
    mapping(uint256 => address) public ownerOf;
    address public vault;

    function setOwner(uint256 id, address o) external {
        ownerOf[id] = o;
    }

    function setVault(address v) external {
        vault = v;
    }

    function getVaultAddress(uint256) external view returns (address) {
        return vault;
    }

    function transferFrom(address, address to, uint256 id) external {
        ownerOf[id] = to;
    }
}

/// @dev ERC20-collateral T1-shaped vault: credits supplied collateral per position and,
///      on a value-out `operate`, optionally calls back into its `hook` (to model a
///      re-entrant venue/receiver).
contract C8Vault {
    C8Factory public immutable factory;
    C8Token public immutable token;
    mapping(uint256 => uint256) public col;
    address public hook;

    constructor(C8Factory f, C8Token t) {
        factory = f;
        token = t;
    }

    function setHook(address h) external {
        hook = h;
    }

    function VAULT_ID() external pure returns (uint256) {
        return 1;
    }

    function constantsView() external view returns (address, address, address, address, address, address) {
        return (address(0), address(factory), address(0), address(0), address(token), address(token));
    }

    function operate(uint256 nftId, int256 newCol, int256 newDebt, address to)
        external
        payable
        returns (uint256, int256, int256)
    {
        if (newCol > 0) {
            token.transferFrom(msg.sender, address(this), uint256(newCol));
            col[nftId] += uint256(newCol);
        } else if (newDebt > 0) {
            if (hook != address(0)) C8Reenter(hook).reenter();
            token.transfer(to == address(0) ? msg.sender : to, uint256(newDebt));
        }
        return (nftId, newCol, newDebt);
    }
}

interface C8Reenter {
    function reenter() external;
}

/// @title L-CENSUS-8 (3)/(5) — mock-venue unit regressions (no fork).
contract AuditCensus8FluidUnitTest is Test {
    Permit3 permit3;
    C8Token token;
    C8Factory factory;
    C8Vault vault;
    FluidDepositModule deposit;
    FluidTakerModule taker;

    address settlement = address(0x5E77);
    address maker = address(0xA11CE);
    address stranger = address(0x5742);

    uint256 constant MAKER_ID = 1;
    uint256 constant STRANGER_ID = 2;

    bool public innerSucceeded;
    bool internal armed;

    function setUp() public {
        permit3 = new Permit3();
        token = new C8Token();
        factory = new C8Factory();
        vault = new C8Vault(factory, token);
        factory.setVault(address(vault));
        factory.setOwner(MAKER_ID, maker);
        factory.setOwner(STRANGER_ID, stranger);
        deposit = new FluidDepositModule(address(permit3), settlement);
        // `permit3` = this test, so the test can drive (and re-enter) `takeOnBehalf`.
        taker = new FluidTakerModule(address(this), address(factory), address(0xE7));
        token.mint(address(vault), 1_000e18);
    }

    /// (3) A deposit into a STRANGER's position used to credit the stranger with the
    /// maker's collateral. Now refused; the maker keeps its tokens.
    function test_audit_L_CENSUS_8_depositRefusesStrangersPosition() public {
        token.mint(maker, 100e18);
        vm.startPrank(maker);
        token.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(deposit), address(token), uint160(100e18), 0);
        vm.stopPrank();

        vm.prank(settlement);
        try deposit.makeOnBehalf(maker, 100e18, abi.encode(address(vault), address(token), STRANGER_ID)) {} catch {}

        assertEq(vault.col(STRANGER_ID), 0, "stranger not credited");
        assertEq(token.balanceOf(maker), 100e18, "maker keeps its collateral");

        // Its own position still works.
        vm.prank(settlement);
        deposit.makeOnBehalf(maker, 100e18, abi.encode(address(vault), address(token), MAKER_ID));
        assertEq(vault.col(MAKER_ID), 100e18, "own position credited");
    }

    /// (5) `FluidTakerModule` now carries the same `_locked` guard as its custody
    /// siblings: a re-entrant `takeOnBehalf` from inside the venue call (with the NFT
    /// resident in the module) is refused instead of running a nested custody cycle.
    function test_audit_L_CENSUS_8_takerModuleRefusesReentry() public {
        vault.setHook(address(this));
        armed = true;
        bytes memory d = abi.encode(uint8(FluidTakerModule.Op.Borrow), address(vault), address(factory), MAKER_ID);
        taker.takeOnBehalf(maker, 10e18, address(0xCAFE), d);
        assertFalse(innerSucceeded, "nested custody cycle refused");
        assertEq(factory.ownerOf(MAKER_ID), maker, "position handed back");
    }

    function reenter() external {
        if (!armed) return;
        armed = false;
        bytes memory d = abi.encode(uint8(FluidTakerModule.Op.Borrow), address(vault), address(factory), MAKER_ID);
        try taker.takeOnBehalf(maker, 1e18, address(0xBEEF), d) {
            innerSucceeded = true;
        } catch {}
    }
}
