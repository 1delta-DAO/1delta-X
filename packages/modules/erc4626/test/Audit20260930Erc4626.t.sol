// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {ERC4626WithdrawModule} from "../src/ERC4626WithdrawModule.sol";
import {MockERC20, MockPermit3} from "./ERC4626WithdrawModule.t.sol";

/// @dev An ERC-7540-style vault that IS its own share token and consumes the
///      caller's shares with an internal burn — no allowance needed. Optionally hands
///      back `refundShares` of unfulfilled shares on claim.
contract AuditSelfShareVault is MockERC20 {
    MockERC20 public underlyingAsset;
    uint256 public lockDuration;
    uint256 public refundShares;
    uint256 private _nextId = 1;

    struct Req {
        address requester;
        uint256 shares;
    }

    mapping(uint256 => Req) private _reqs;

    constructor(MockERC20 asset_) {
        underlyingAsset = asset_;
    }

    function setRefundShares(uint256 s) external {
        refundShares = s;
    }

    function asset() external view returns (address) {
        return address(underlyingAsset);
    }

    function requestRedeem(uint256 shares) external returns (uint256 id) {
        balanceOf[msg.sender] -= shares; // internal burn of the CALLER's own shares
        id = _nextId++;
        _reqs[id] = Req(msg.sender, shares);
    }

    function claimRedeem(uint256 id, address to) external returns (uint256 assets) {
        Req memory r = _reqs[id];
        require(r.requester == msg.sender, "requester");
        delete _reqs[id];
        assets = r.shares - refundShares;
        underlyingAsset.transfer(to, assets);
        if (refundShares != 0) balanceOf[msg.sender] += refundShares; // unfulfilled shares back
    }
}

/// @title Audit20260930Erc4626Test
/// @notice Regression for audit 2026-09-30 MISC-MOD-3: {ERC4626WithdrawModule} floored
///         and swept only the data-named `shareToken`, so a self-order naming a junk
///         token against a vault that burns the caller's own shares redeemed the
///         module's STRAY vault shares; and Phase 2 left shares a vault handed back
///         on the singleton.
contract Audit20260930Erc4626Test is Test {
    MockERC20 asset;
    MockERC20 junk;
    AuditSelfShareVault vault;
    MockPermit3 permit3;
    ERC4626WithdrawModule module;

    address settlement = address(0x5e77);
    address attacker = address(0xBAD);
    address user = address(0xBEEF);
    uint256 constant STRAY = 500e18;

    function setUp() public {
        asset = new MockERC20();
        junk = new MockERC20();
        vault = new AuditSelfShareVault(asset);
        permit3 = new MockPermit3();
        module = new ERC4626WithdrawModule(address(permit3), settlement);
        asset.mint(address(vault), 10_000e18);
    }

    /// The attack: stray vault shares sit on the singleton; the attacker self-signs
    /// a Phase-1 MAKE naming the real vault and a JUNK share token. The vault burns
    /// the module's own (stray) shares; before the fix the floor/sweep only watched
    /// the junk token and recorded a pending claim for the attacker.
    function test_audit_MISC_MOD_3_junkShareToken_cannotRedeemStrayVaultShares() public {
        vault.mint(address(module), STRAY); // stray / donated vault shares
        junk.mint(attacker, STRAY);
        vm.prank(attacker);
        junk.approve(address(permit3), type(uint256).max);

        vm.prank(settlement);
        vm.expectRevert(abi.encodeWithSignature("ForeignBalanceConsumed(address,uint256)", address(vault), STRAY));
        module.makeOnBehalf(attacker, STRAY, abi.encode(address(vault), address(junk)));

        assertEq(vault.balanceOf(address(module)), STRAY, "stray shares untouched");
        (address beneficiary,) = module.pendingWithdrawals(address(vault), 1);
        assertEq(beneficiary, address(0), "no claim recorded for the attacker");
    }

    /// The honest shape on the same vault (shareToken == vault) still works and
    /// leaves the stray balance where it was.
    function test_audit_MISC_MOD_3_honestRequest_leavesStrayAlone() public {
        vault.mint(address(module), STRAY);
        vault.mint(user, 100e18);
        vm.prank(user);
        vault.approve(address(permit3), type(uint256).max);

        vm.prank(settlement);
        module.makeOnBehalf(user, 100e18, abi.encode(address(vault), address(vault)));
        assertEq(vault.balanceOf(address(module)), STRAY, "only the user's own shares were consumed");
        (address beneficiary,) = module.pendingWithdrawals(address(vault), 1);
        assertEq(beneficiary, user);
    }

    /// Phase 2: shares the vault hands back on a partially honoured claim go to the
    /// beneficiary instead of staying on the singleton.
    function test_audit_MISC_MOD_3_claimRefundedShares_sweptToBeneficiary() public {
        vault.mint(user, 100e18);
        vm.prank(user);
        vault.approve(address(permit3), type(uint256).max);
        vm.prank(settlement);
        module.makeOnBehalf(user, 100e18, abi.encode(address(vault), address(vault)));

        vault.setRefundShares(40e18); // 60 fulfilled, 40 shares handed back
        vm.prank(address(permit3));
        module.takeOnBehalf(user, 60e18, address(0xCAFE), abi.encode(address(vault), uint256(1), uint256(0), 60e18));

        assertEq(asset.balanceOf(address(0xCAFE)), 60e18, "fulfilled assets forwarded");
        assertEq(vault.balanceOf(address(module)), 0, "no share residue on the singleton");
        assertEq(vault.balanceOf(user), 40e18, "unfulfilled shares returned to the beneficiary");
    }
}
