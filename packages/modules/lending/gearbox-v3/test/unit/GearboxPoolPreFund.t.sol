// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";
import {GearboxPoolPreFundDepositModule} from "../../src/GearboxV3PreFundModules.sol";

// ── Mocks ────────────────────────────────────────────────────────────────────

contract PreFundToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev ERC-4626-shaped PoolV3 stand-in: `deposit` pulls the assets from the
///      CALLER (the real pool's `transferFrom(msg.sender, …)`) and credits the
///      shares to `receiver` — the two properties the pre-fund module depends on.
contract PreFundPool {
    PreFundToken public immutable token;
    mapping(address => uint256) public shares;

    constructor(PreFundToken _token) {
        token = _token;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256) {
        token.transferFrom(msg.sender, address(this), assets);
        shares[receiver] += assets;
        return assets;
    }
}

/// @dev Stands in for Permit3. The module must treat it as a SENDER GATE only:
///      the funding side of a pre-fund module never pulls, so any call INTO this
///      contract (a `transferFrom`, anything) fails the test loudly.
contract Permit3Sentinel {
    fallback() external {
        revert("pre-fund module must never call permit3");
    }
}

/// @dev The pool-side pre-fund deposit, on mocks — no fork: the happy path proves
///      the module funds the venue op from its OWN balance (the Permit3 stand-in
///      reverts on ANY inbound call, so a `transferFrom` attempt cannot hide),
///      and the gates prove only Permit3 dispatches and only a leg-reference
///      descriptor is accepted.
contract GearboxPoolPreFundTest is Test {
    address settlement = address(0x5E77);
    PreFundToken token;
    PreFundPool pool;
    Permit3Sentinel permit3;
    GearboxPoolPreFundDepositModule preFundDeposit;

    address maker = address(0xA11CE);
    address attacker = address(0xBAD);

    uint256 constant DELIVERED = 5e18;

    function setUp() public {
        token = new PreFundToken();
        pool = new PreFundPool(token);
        permit3 = new Permit3Sentinel();
        preFundDeposit = new GearboxPoolPreFundDepositModule(address(permit3), address(settlement));
    }

    function _legRefData() internal view returns (bytes memory) {
        return abi.encode(
            (uint256(1) << 255) | (uint256(1) << 253) | (uint256(uint160(address(token))) << 16) | 0,
            address(pool), address(token)
        );
    }

    // ── happy path: fund from the module's own balance, never permit3 ──

    function test_preFundDeposit_fundsFromModuleBalance_neverCallsPermit3() public {
        // The delivered output leg: Settlement paid the module directly.
        token.mint(address(preFundDeposit), DELIVERED);

        vm.prank(settlement);
        preFundDeposit.makeOnBehalf(maker, DELIVERED, _legRefData());

        assertEq(pool.shares(maker), DELIVERED, "shares credited to the maker");
        assertEq(token.balanceOf(address(pool)), DELIVERED, "assets entered the pool");
        assertEq(token.balanceOf(address(preFundDeposit)), 0, "module drained");
        assertEq(token.allowance(address(preFundDeposit), address(pool)), 0, "scoped approval cleared");
    }

    /// @dev A dust slice flooring the funding leg to zero is a clean no-op.
    function test_zero_forAmount_is_a_noop() public {
        vm.prank(settlement);
        preFundDeposit.makeOnBehalf(maker, 0, _legRefData());

        assertEq(pool.shares(maker), 0, "no deposit happened");
        assertEq(token.allowance(address(preFundDeposit), address(pool)), 0, "no approval granted");
    }

    // ── gates ──

    function test_rejects_non_settlement() public {
        vm.prank(attacker);
        vm.expectRevert(PreFundGuard.OnlySettlement.selector);
        preFundDeposit.makeOnBehalf(maker, DELIVERED, _legRefData());
    }

    function test_rejects_literal_descriptor() public {
        bytes memory data = abi.encode(uint256(1e18), address(pool), address(token));
        vm.prank(settlement);
        vm.expectRevert(PreFundGuard.PreFundDescriptorRequired.selector);
        preFundDeposit.makeOnBehalf(maker, DELIVERED, data);
    }

    function test_rejects_balance_descriptor() public {
        bytes memory data =
            abi.encode((uint256(3) << 254) | uint256(uint160(address(token))), address(pool), address(token));
        vm.prank(settlement);
        vm.expectRevert(PreFundGuard.PreFundDescriptorRequired.selector);
        preFundDeposit.makeOnBehalf(maker, DELIVERED, data);
    }

    // ── preflight ──

    function test_fundingSource_reportsSelfFunding() public view {
        (address asset, uint256 available) = preFundDeposit.fundingSource(maker, _legRefData());
        assertEq(asset, address(token), "funding asset = the delivered underlying");
        assertEq(available, type(uint256).max, "self-funded: never previews short");
    }
}
