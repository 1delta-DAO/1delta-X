// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Permit3} from "@core/permit3/Permit3.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";

import {AaveV3PreFundModule} from "../../src/AaveV3PreFundModules.sol";

contract Tok {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[t] += a; return true;
    }
}

/// @dev "The caller simply has no debt on the named market" — what a real Aave
///      debt token, Comet, Silo, Morpho or Midnight returns for an empty address.
///      No attacker logic at all: this is the zero-debt sweep's whole precondition.
contract NoDebt {
    function balanceOf(address) external pure returns (uint256) { return 0; }
}

/// @dev Drains a scoped approval the instant it is granted.
contract EvilPool {
    address immutable tok;
    address immutable thief;

    constructor(address _tok, address _thief) { tok = _tok; thief = _thief; }

    function supply(address, uint256, address, uint16) external {
        Tok(tok).transferFrom(msg.sender, thief, Tok(tok).balanceOf(msg.sender));
    }
}

/// @notice F27/C-1, after the one-sided pre-fund family moved to the MAKE seam.
///
///         C-1 was: a PRE-FUND module funds `forAmount` from its OWN balance, and
///         `Permit3.takeFor` is a permissionless entrypoint whose `forAmount`
///         argument nothing meters. `approveTaker` lets a caller name ITSELF
///         spender, so one self-granted unit of taker allowance moved a
///         singleton's entire balance — no order, no maker signature, no
///         Settlement, no capital. The answer was a forwarded `spender` word the
///         module compared against its pinned Settlement.
///
///         ON THE MAKE SEAM THE CHANNEL DOES NOT EXIST. Settlement calls this
///         module DIRECTLY, so the caller is `msg.sender` — asserted by the EVM,
///         not carried in a parameter anyone has to remember to compare. There is
///         no permissionless hub in front of the entrypoint to be abused, and the
///         module no longer implements `takeForOnBehalf` at all, so `takeFor`
///         cannot dispatch to it however the taker book is granted.
///
///         The drain PAYLOADS are kept verbatim below — the zero-debt sweep and
///         the attacker-venue approval — so what is asserted is that the attacks
///         are refused at the door, not that they became unrepresentable.
contract PreFundSpenderAuthTest is Test {
    Permit3 permit3;
    Tok usdc;

    address constant SETTLEMENT = address(0x5E77);
    address constant MALLORY = address(0xBAD);

    function setUp() public {
        permit3 = new Permit3();
        usdc = new Tok();
    }

    /// @dev `(5 << 253)` — leg reference + PRE-FUND shape, which is what
    ///      {PreFundModuleBase._gatePreFundMake} requires of every blob reaching this
    ///      module. `op` rides in bits [244,252).
    function _desc(AaveV3PreFundModule.Op op, address token) internal pure returns (uint256) {
        return (uint256(5) << 253) | (uint256(uint160(token)) << 16) | (uint256(op) << 244);
    }

    function _repayPayload() internal returns (bytes memory) {
        return abi.encode(_desc(AaveV3PreFundModule.Op.Repay, address(usdc)), address(0xDEAD), address(usdc), uint256(2), address(new NoDebt()));
    }

    // ──────────────── the permissionless channel is gone ────────────────

    /// THE HEADLINE. The taker book will happily record a self-grant — it always
    /// would — but there is nothing on the other side to dispatch to. `takeFor`
    /// invokes `ITakerForModule.takeForOnBehalf`, a selector this contract does not
    /// implement, so the call reverts on dispatch rather than on a guard the module
    /// had to remember to write.
    function test_permit3_takeFor_noLongerReachesTheModule() public {
        AaveV3PreFundModule mod = new AaveV3PreFundModule(address(permit3), SETTLEMENT);
        usdc.mint(address(mod), 100_000e6);
        bytes memory data = _repayPayload();

        vm.startPrank(MALLORY);
        vm.expectRevert();
        permit3.takeFor(address(mod), MALLORY, 1, uint160(100_000e6), address(0), data);
        vm.stopPrank();

        assertEq(usdc.balanceOf(MALLORY), 0, "attacker took funds");
        assertEq(usdc.balanceOf(address(mod)), 100_000e6, "singleton drained");
    }

    // ──────────────── and the direct surface is pinned to Settlement ────────────────

    /// @dev Variant (a): the zero-debt sweep. Name a debt token reporting zero and
    ///      `toRepay == 0` skips the venue entirely, so the surplus sweep would pay
    ///      the caller `forAmount` straight out of the module's balance. Refused on
    ///      `msg.sender`.
    function test_direct_makeOnBehalf_zeroDebtSweep_refused() public {
        AaveV3PreFundModule mod = new AaveV3PreFundModule(address(permit3), SETTLEMENT);
        usdc.mint(address(mod), 100_000e6);

        bytes memory data = _repayPayload(); // deploys a mock: build it BEFORE the cheatcodes
        vm.prank(MALLORY);
        vm.expectRevert(PreFundGuard.OnlySettlement.selector);
        mod.makeOnBehalf(MALLORY, 100_000e6, data);

        assertEq(usdc.balanceOf(MALLORY), 0, "attacker took funds");
        assertEq(usdc.balanceOf(address(mod)), 100_000e6, "singleton drained");
    }

    /// @dev Variant (b): the scoped approval. `pool` is decoded from `data`, so the
    ///      F25/A-3 scoping bounds the approval at the caller's own number — which
    ///      is the whole problem when the caller picks it. Refused on `msg.sender`.
    function test_direct_makeOnBehalf_attackerVenue_refused() public {
        AaveV3PreFundModule mod = new AaveV3PreFundModule(address(permit3), SETTLEMENT);
        usdc.mint(address(mod), 100_000e6);
        address evil = address(new EvilPool(address(usdc), MALLORY));
        bytes memory data = abi.encode(_desc(AaveV3PreFundModule.Op.Supply, address(usdc)), evil, address(usdc));

        vm.prank(MALLORY);
        vm.expectRevert(PreFundGuard.OnlySettlement.selector);
        mod.makeOnBehalf(MALLORY, 100_000e6, data);

        assertEq(usdc.balanceOf(MALLORY), 0, "attacker took funds");
        assertEq(usdc.balanceOf(address(mod)), 100_000e6, "singleton drained");
    }

    /// @dev Not a blanket freeze: the pinned Settlement makes the same call with the
    ///      same data and gets PAST the gate (on into the venue, which is why it
    ///      reverts elsewhere rather than at `OnlySettlement`).
    function test_pinned_settlement_passes_the_gate() public {
        AaveV3PreFundModule mod = new AaveV3PreFundModule(address(permit3), SETTLEMENT);
        usdc.mint(address(mod), 100_000e6);

        bytes memory data = _repayPayload(); // deploys a mock: build it BEFORE the prank
        vm.prank(SETTLEMENT);
        try mod.makeOnBehalf(SETTLEMENT, 100_000e6, data) {}
        catch (bytes memory err) {
            assertTrue(
                bytes4(err) != PreFundGuard.OnlySettlement.selector, "pinned settlement was rejected by the caller gate"
            );
        }
    }

    // ──────────────── why the seam matters, not just the guard ────────────────
    //
    // On the `TAKE_FOR` seam this module carried THREE addresses and only ONE of
    // them was worth gating on:
    //
    //   spender     `Permit3.takeFor`'s own `msg.sender`, FORWARDED. Trustworthy,
    //               but only because every module remembered to compare it.
    //   receiver    an ARGUMENT. Caller-chosen on the direct path.
    //   onBehalfOf  an ARGUMENT (`user`). Caller-chosen likewise.
    //
    // A gate written against either argument is worthless — the attacker passes the
    // value the gate wants. Here there is one address to get right and the EVM
    // supplies it, so the class of mistake has no room left to occur.

    /// @dev `onBehalfOf` is still caller-chosen and still proves nothing: naming
    ///      Settlement as the beneficiary does not make the CALLER Settlement.
    function test_onBehalfOfIsNotASubstituteForTheCaller() public {
        AaveV3PreFundModule mod = new AaveV3PreFundModule(address(permit3), SETTLEMENT);
        usdc.mint(address(mod), 100_000e6);

        bytes memory data = _repayPayload(); // deploys a mock: build it BEFORE the cheatcodes
        vm.prank(MALLORY);
        vm.expectRevert(PreFundGuard.OnlySettlement.selector);
        // every argument set to what a naive gate would want — only the CALLER is wrong
        mod.makeOnBehalf(SETTLEMENT, 100_000e6, data);

        assertEq(usdc.balanceOf(address(mod)), 100_000e6, "singleton drained");
        assertEq(usdc.balanceOf(MALLORY), 0, "attacker took funds");
    }
}
