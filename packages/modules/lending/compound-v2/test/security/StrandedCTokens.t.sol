// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Permit3} from "@core/permit3/Permit3.sol";
import {CompoundV2WithdrawModule} from "../../src/CompoundV2Modules.sol";

contract Tok {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        balanceOf[f] -= a; balanceOf[t] += a; return true;
    }
}

/// Minimal cToken: rate 1e18 ⇒ 1 cToken == 1 underlying, so the arithmetic is trivial.
contract CTok is Tok {
    Tok public immutable u;
    constructor(Tok _u) { u = _u; }
    function exchangeRateCurrent() external pure returns (uint256) { return 1e18; }
    function redeemUnderlying(uint256 amount) external returns (uint256) {
        balanceOf[msg.sender] -= amount;      // burn the caller's cTokens 1:1
        u.transfer(msg.sender, amount);       // hand over the underlying
        return 0;
    }
}

/// @title CompoundV2StrandedCTokensTest
/// @notice F26/2a regression — the exact-withdraw branch must return only the
///         change THIS call produced, never the module's whole cToken balance.
///
///  The precondition is real rather than theoretical: the pull ceils
///  (`ceil(amount * 1e18 / rate)`) and Compound's burn truncates, so a remainder
///  exists on EVERY fill. The sweep branch is the normal path, not an edge case.
///
///  Before the floor, the assertions below read `500e18` and `0` — a one-wei order
///  authored by anyone collected the module's entire stranded balance.
contract CompoundV2StrandedCTokensTest is Test {
    Permit3 permit3;
    Tok underlying;
    CTok cToken;
    CompoundV2WithdrawModule mod;

    address victim = address(0xA11CE);
    address attacker = address(0xBAD);

    function setUp() public {
        permit3 = new Permit3();
        underlying = new Tok();
        cToken = new CTok(underlying);
        mod = new CompoundV2WithdrawModule(address(permit3));
        underlying.mint(address(cToken), 1_000_000e18); // pool liquidity
    }

    function test_oneWeiOrder_cannotSweepStrandedCTokens() public {
        // ── Precondition: 500 cTokens are sitting on the shared module. Any route
        //    gets them there (a donation, a mis-sized pull, a partially-consumed
        //    redeem on a fork whose rate moved between the read and the burn).
        cToken.mint(address(mod), 500e18);

        // ── The attacker authors a ONE WEI withdraw for themselves.
        cToken.mint(attacker, 1);
        vm.startPrank(attacker);
        cToken.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(mod), address(cToken), type(uint160).max, 0);

        bytes memory data = abi.encode(address(cToken), address(underlying));
        permit3.approveTaker(attacker, address(mod), keccak256(data), type(uint160).max, 0);
        permit3.take(address(mod), attacker, 1, attacker, data); // amount = 1 wei
        vm.stopPrank();

        // The module ends where it STARTED, not empty. The attacker gets back only
        // the change from their own one-wei pull.
        assertEq(cToken.balanceOf(address(mod)), 500e18, "stranded balance stays at the module");
        assertLt(cToken.balanceOf(attacker), 500e18, "attacker did not collect the stranded balance");
    }

    /// @dev The floor must not break what it guards: a genuine remainder from the
    ///      caller's own over-pull still comes back to them.
    function test_ownRemainder_isStillReturned() public {
        cToken.mint(address(mod), 500e18); // someone else's, must not move
        cToken.mint(attacker, 10e18);

        vm.startPrank(attacker);
        cToken.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(mod), address(cToken), type(uint160).max, 0);
        bytes memory data = abi.encode(address(cToken), address(underlying));
        permit3.approveTaker(attacker, address(mod), keccak256(data), type(uint160).max, 0);
        uint256 before = cToken.balanceOf(attacker);
        permit3.take(address(mod), attacker, 1, attacker, data);
        vm.stopPrank();

        assertEq(cToken.balanceOf(address(mod)), 500e18, "still ends where it started");
        assertEq(cToken.balanceOf(attacker), before - 1, "paid exactly the 1 wei of cTokens the redeem burned");
    }
}
