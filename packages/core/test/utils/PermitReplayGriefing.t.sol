// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {PermitHelper} from "@core/utils/PermitHelper.sol";
import {DelegationHelper} from "@core/utils/DelegationHelper.sol";

/// @dev ERC-2612 token with a real per-owner nonce, so a replayed permit reverts
///      exactly as a production token would.
contract NonceToken {
    mapping(address => uint256) public nonces;
    mapping(address => mapping(address => uint256)) public allowance;

    error PermitNonceUsed();

    /// @dev `v` doubles as the "signature" here — a given (owner, v) may be
    ///      submitted once. Signature cryptography is not what this test is about;
    ///      the nonce burn is.
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8, bytes32, bytes32)
        external
    {
        require(block.timestamp <= deadline, "expired");
        if (nonces[owner] != 0) revert PermitNonceUsed(); // already consumed
        nonces[owner] = 1;
        allowance[owner][spender] = value;
    }
}

/// @dev Aave-style credit delegation with the same one-shot nonce behaviour.
contract NonceDebtToken {
    mapping(address => uint256) public used;
    mapping(address => mapping(address => uint256)) public borrowAllowance;

    error DelegationNonceUsed();

    function delegationWithSig(
        address delegator,
        address delegatee,
        uint256 value,
        uint256 deadline,
        uint8,
        bytes32,
        bytes32
    ) external {
        require(block.timestamp <= deadline, "expired");
        if (used[delegator] != 0) revert DelegationNonceUsed();
        used[delegator] = 1;
        borrowAllowance[delegator][delegatee] = value;
    }
}

/// @dev Thin wrappers so the internal library functions are reachable externally.
contract HelperHarness {
    function replayPermit(bytes calldata data, uint256 baseLen, address token, address owner, address spender, uint256 amount)
        external
    {
        PermitHelper.replayIfPresent(data, baseLen, token, owner, spender, amount);
    }

    function replayDelegation(bytes calldata data, uint256 baseLen, address delegator, address delegatee, uint256 value)
        external
    {
        DelegationHelper.replayAaveDelegation(data, baseLen, delegator, delegatee, value);
    }
}

/// @title PermitReplayGriefingTest
/// @notice Regression tests for the front-run griefing vector on the optional
///         permit / delegation blocks.
///
///         The attack: those signature bytes live inside the module's `data`,
///         which is part of both the order hash and `ref = keccak256(data)`. So an
///         attacker who lands the same permit first — trivial, it is sitting in the
///         mempool — used to make the victim's fill revert FOREVER, with no way to
///         re-encode the order. Cost to the attacker: one cheap transaction.
///
///         The replays are now best-effort, so an already-consumed nonce is a
///         no-op. The subsequent Permit3 pull (not modelled here) remains the real
///         gate.
contract PermitReplayGriefingTest is Test {
    HelperHarness harness;
    NonceToken token;
    NonceDebtToken debtToken;

    address maker = address(0xA11CE);
    address spender = address(0x9E3D);
    address griefer = address(0xBAD);

    uint256 constant AMOUNT = 1_000e18;

    function setUp() public {
        harness = new HelperHarness();
        token = new NonceToken();
        debtToken = new NonceDebtToken();
    }

    function _permitBlock() internal view returns (bytes memory) {
        // base = 64 (two addresses), then the 128-byte permit block.
        return abi.encode(address(0xBA5E), address(0xBA5E2), block.timestamp + 1 days, uint8(27), bytes32(0), bytes32(0));
    }

    function _delegationBlock() internal view returns (bytes memory) {
        // base = 64, then the 160-byte delegation block.
        return abi.encode(
            address(0xBA5E),
            address(0xBA5E2),
            address(debtToken),
            block.timestamp + 1 days,
            uint8(27),
            bytes32(0),
            bytes32(0)
        );
    }

    // ──────────────── Permit ────────────────

    function test_permit_isAppliedWhenUnconsumed() public {
        harness.replayPermit(_permitBlock(), 64, address(token), maker, spender, AMOUNT);
        assertEq(token.allowance(maker, spender), AMOUNT, "permit applied on the happy path");
    }

    /// The griefing attack: the attacker lands the maker's permit first, burning
    /// the nonce. The fill must still go through.
    function test_frontRunDoesNotBrickTheFill() public {
        // Attacker replays the maker's signature directly — same effect, their gas.
        vm.prank(griefer);
        token.permit(maker, spender, AMOUNT, block.timestamp + 1 days, 27, bytes32(0), bytes32(0));
        assertEq(token.nonces(maker), 1, "nonce burned by the griefer");

        // The module's replay now hits an already-used nonce and must NOT revert.
        harness.replayPermit(_permitBlock(), 64, address(token), maker, spender, AMOUNT);

        // The allowance the fill needs is present regardless of who set it.
        assertEq(token.allowance(maker, spender), AMOUNT, "fill can still proceed");
    }

    /// Control: the hard call really would have reverted, so the test above is
    /// exercising the swallow rather than passing vacuously.
    function test_control_rawPermitRevertsOnReplay() public {
        vm.prank(griefer);
        token.permit(maker, spender, AMOUNT, block.timestamp + 1 days, 27, bytes32(0), bytes32(0));

        vm.expectRevert(NonceToken.PermitNonceUsed.selector);
        token.permit(maker, spender, AMOUNT, block.timestamp + 1 days, 27, bytes32(0), bytes32(0));
    }

    /// An expired permit is also swallowed — same reasoning, and the pull still
    /// gates the actual movement of funds.
    function test_expiredPermit_isSwallowed() public {
        bytes memory data = abi.encode(
            address(0xBA5E), address(0xBA5E2), block.timestamp - 1, uint8(27), bytes32(0), bytes32(0)
        );
        harness.replayPermit(data, 64, address(token), maker, spender, AMOUNT);
        assertEq(token.allowance(maker, spender), 0, "no allowance, but no revert either");
    }

    // ──────────────── Delegation ────────────────

    function test_delegation_isAppliedWhenUnconsumed() public {
        harness.replayDelegation(_delegationBlock(), 64, maker, spender, AMOUNT);
        assertEq(debtToken.borrowAllowance(maker, spender), AMOUNT, "delegation applied");
    }

    function test_delegationFrontRunDoesNotBrickTheFill() public {
        vm.prank(griefer);
        debtToken.delegationWithSig(maker, spender, AMOUNT, block.timestamp + 1 days, 27, bytes32(0), bytes32(0));

        harness.replayDelegation(_delegationBlock(), 64, maker, spender, AMOUNT);
        assertEq(debtToken.borrowAllowance(maker, spender), AMOUNT, "fill can still proceed");
    }
}
