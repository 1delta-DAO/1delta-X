// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {FluidBase, FluidDepositModule, FluidRepayModule} from "../../src/FluidModules.sol";

/// @dev Stands in for Permit3. Reverting on the pull lets a test prove the
///      `nftId == 0` guard fires BEFORE the module takes custody of any funds —
///      the distinction between "fails closed" and "fails after the money moved".
contract RevertingPermit3 {
    error Pulled();

    function transferFrom(address, address, address, uint160) external pure {
        revert Pulled();
    }
}

/// @dev A vault that reproduces Fluid's actual `nftId == 0` behaviour: the
///      sentinel MINTS a fresh position, and `operate` mints it to `msg.sender`.
///      Used to show what the guard prevents.
contract FreshMintingVault {
    uint256 public nextId = 7;

    mapping(uint256 => address) public ownerOf;

    function operate(uint256 nftId, int256, int256, address) external returns (uint256 id, int256, int256) {
        if (nftId == 0) {
            id = nextId++;
            // Fluid mints the new position to the caller — here, the module.
            ownerOf[id] = msg.sender;
        } else {
            id = nftId;
        }
        return (id, int256(0), int256(0));
    }
}

/// @dev Minimal ERC20 for the deposit path's pull + approve.
contract MintableToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 v) external {
        balanceOf[to] += v;
    }

    function approve(address s, uint256 v) external returns (bool) {
        allowance[msg.sender][s] = v;
        return true;
    }

    function transfer(address to, uint256 v) external returns (bool) {
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        return true;
    }

    function transferFrom(address f, address t, uint256 v) external returns (bool) {
        allowance[f][msg.sender] -= v;
        balanceOf[f] -= v;
        balanceOf[t] += v;
        return true;
    }
}

/// @dev Permit3 stand-in that actually moves tokens, so the "stranded" scenario
///      can be played out end-to-end.
contract FundingPermit3 {
    function transferFrom(address from, address to, address token, uint160 amount) external {
        MintableToken(token).transferFrom(from, to, amount);
    }
}

/// @title FluidFreshPositionTest
/// @notice Regression test for `nftId == 0` stranding a deposit.
///
///  Fluid overloads `nftId == 0` as "open a NEW position", and `operate` mints
///  that position NFT to `msg.sender`. On the single-op maker legs `msg.sender`
///  is the MODULE — a contract with no NFT custody step and no transfer path out.
///  So a deposit signed with `nftId == 0` pulled the user's collateral, supplied
///  it into a brand-new position, and left that position owned by the module
///  forever. Nobody can steal it, but the user cannot reach it either: the funds
///  are simply gone, which is strictly worse than a revert.
///
///  Opening a position is `FluidOperateModule`'s Open path, which captures the
///  minted id from `operate`'s return value and hands the NFT to the user in the
///  same call. The single-op legs now reject the sentinel outright.
contract FluidFreshPositionTest is Test {
    address constant SETTLEMENT = address(0x5E77);
    address constant TOKEN = address(0x3333);

    address maker = address(0xA11CE);

    RevertingPermit3 permit3;
    FluidDepositModule deposit;
    FluidRepayModule repay;

    function setUp() public {
        permit3 = new RevertingPermit3();
        deposit = new FluidDepositModule(address(permit3), SETTLEMENT);
        repay = new FluidRepayModule(address(permit3), SETTLEMENT);
    }

    // ── The guard ─────────────────────────────────────────────────────────────

    function test_deposit_rejectsFreshPositionSentinel() public {
        vm.prank(SETTLEMENT);
        vm.expectRevert(FluidBase.FreshPositionUnsupported.selector);
        deposit.makeOnBehalf(maker, 1_000e6, abi.encode(address(0x1111), TOKEN, uint256(0)));
    }

    function test_repay_rejectsFreshPositionSentinel() public {
        vm.prank(SETTLEMENT);
        vm.expectRevert(FluidBase.FreshPositionUnsupported.selector);
        repay.makeOnBehalf(maker, 1_000e6, abi.encode(address(0x1111), TOKEN, uint256(0)));
    }

    /// The guard runs BEFORE the Permit3 pull: the revert is `FreshPositionUnsupported`,
    /// not the pull's `Pulled`. Fail-closed without ever taking custody.
    function test_guardPrecedesCustody() public {
        vm.prank(SETTLEMENT);
        vm.expectRevert(FluidBase.FreshPositionUnsupported.selector);
        deposit.makeOnBehalf(maker, 1_000e6, abi.encode(address(0x1111), TOKEN, uint256(0)));

        // Sanity: a NON-zero nftId gets past the guard and reaches the pull, which
        // is what proves the guard is the thing rejecting the sentinel above and
        // not some unrelated earlier revert.
        vm.prank(SETTLEMENT);
        vm.expectRevert(RevertingPermit3.Pulled.selector);
        deposit.makeOnBehalf(maker, 1_000e6, abi.encode(address(0x1111), TOKEN, uint256(42)));
    }

    /// Only Settlement may drive the maker legs — the guard does not weaken the
    /// existing auth gate (which is checked first).
    function test_authStillCheckedFirst() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(FluidDepositModule.NotSettlement.selector);
        deposit.makeOnBehalf(maker, 1_000e6, abi.encode(address(0x1111), TOKEN, uint256(0)));
    }

    // ── What the guard prevents ───────────────────────────────────────────────

    /// Plays the defect out against a vault that mints like Fluid does: without
    /// the guard the module ends up owning the freshly minted position, with the
    /// user's collateral inside it and no way to get it back.
    function test_unguarded_wouldStrandPositionInModule() public {
        MintableToken token = new MintableToken();
        FreshMintingVault vault = new FreshMintingVault();
        FundingPermit3 funding = new FundingPermit3();
        FluidDepositModule mod = new FluidDepositModule(address(funding), SETTLEMENT);

        token.mint(maker, 1_000e6);
        vm.prank(maker);
        token.approve(address(funding), type(uint256).max);

        // The guard rejects it today...
        vm.prank(SETTLEMENT);
        vm.expectRevert(FluidBase.FreshPositionUnsupported.selector);
        mod.makeOnBehalf(maker, 1_000e6, abi.encode(address(vault), address(token), uint256(0)));

        // ...and the user's funds are untouched, which is the whole point.
        assertEq(token.balanceOf(maker), 1_000e6, "collateral never left the maker");
        assertEq(token.balanceOf(address(mod)), 0, "module holds nothing");

        // Had it gone through, `operate(0, ...)` would have minted the position to
        // the module — this is the outcome the guard exists to prevent.
        vm.prank(address(mod));
        (uint256 mintedId,,) = vault.operate(0, int256(1), int256(0), address(0));
        assertEq(vault.ownerOf(mintedId), address(mod), "fresh position mints to the module, not the user");
    }
}
