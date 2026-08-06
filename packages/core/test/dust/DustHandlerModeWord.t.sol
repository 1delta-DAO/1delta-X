// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {DustHandler} from "@core/dust/DustHandler.sol";

/// @dev `calldata`-taking wrapper: `readAction` / `readBalanceMode` slice a
///      `bytes calldata`, so they cannot be reached from a `memory` blob in the
///      test body. An external call gives them a real calldata region.
contract ModeReader {
    function action(bytes calldata data, uint256 baseLen) external pure returns (DustHandler.DustAction) {
        return DustHandler.readAction(data, baseLen);
    }

    function balanceMode(bytes calldata data, uint256 baseLen) external pure returns (DustHandler.BalanceMode) {
        return DustHandler.readBalanceMode(data, baseLen);
    }
}

/// @title DustHandlerModeWordTest
/// @notice Regression test for the trailing mode word being narrowed to `uint8`
///         BEFORE the enum bounds check.
///
///  The trailing field is a full 32-byte word, but the decode was
///  `DustAction(uint8(word))`. Solidity's enum conversion only range-checks the
///  `uint8` it is handed, so the high 248 bits were discarded first and never
///  checked. `word = 256` therefore did not revert as an out-of-range value — it
///  truncated to `0` and read as a perfectly well-formed `SweepToUser` / `Exact`,
///  which is precisely the DEFAULT mode. A malformed or differently-encoded blob
///  was accepted as the safe default instead of being rejected.
///
///  The value lives inside `ref = keccak256(data)`, so a filler cannot alter it —
///  this is a maker-authored encoding error, not a filler-reachable exploit. But
///  the whole point of the trailing field is that its meaning is unambiguous, and
///  the library's own docstring claimed out-of-range "reverts on the enum
///  conversion". It did not.
contract DustHandlerModeWordTest is Test {
    uint256 constant BASE_LEN = 64;

    ModeReader reader;

    function setUp() public {
        reader = new ModeReader();
    }

    function _blob(uint256 word) internal pure returns (bytes memory) {
        // A `BASE_LEN`-byte static base, then the trailing mode word.
        return abi.encodePacked(new bytes(BASE_LEN), bytes32(word));
    }

    // ── The in-range values still decode exactly as before ────────────────────

    function test_inRange_action() public view {
        assertEq(uint256(reader.action(_blob(0), BASE_LEN)), uint256(DustHandler.DustAction.SweepToUser));
        assertEq(uint256(reader.action(_blob(1), BASE_LEN)), uint256(DustHandler.DustAction.Recycle));
    }

    function test_inRange_balanceMode() public view {
        assertEq(uint256(reader.balanceMode(_blob(0), BASE_LEN)), uint256(DustHandler.BalanceMode.Exact));
        assertEq(uint256(reader.balanceMode(_blob(1), BASE_LEN)), uint256(DustHandler.BalanceMode.Full));
    }

    /// An absent trailing field is still the documented default, not a revert.
    function test_absentField_defaults() public view {
        bytes memory short = new bytes(BASE_LEN);
        assertEq(uint256(reader.action(short, BASE_LEN)), uint256(DustHandler.DustAction.SweepToUser));
        assertEq(uint256(reader.balanceMode(short, BASE_LEN)), uint256(DustHandler.BalanceMode.Exact));
    }

    // ── The fix: the FULL word is range-checked ───────────────────────────────

    /// 256 is the canonical witness: it is out of range, yet its low byte is `0`,
    /// so the old code silently returned the default.
    function test_truncatingWord_reverts_action() public {
        vm.expectRevert(abi.encodeWithSelector(DustHandler.InvalidModeWord.selector, 256));
        reader.action(_blob(256), BASE_LEN);
    }

    function test_truncatingWord_reverts_balanceMode() public {
        vm.expectRevert(abi.encodeWithSelector(DustHandler.InvalidModeWord.selector, 256));
        reader.balanceMode(_blob(256), BASE_LEN);
    }

    /// 257 truncates to `1` — the old code read this as `Recycle` / `Full`, i.e.
    /// it silently ACTIVATED a non-default mode from a malformed word.
    function test_truncatingWord_reverts_ratherThanActivatingMode() public {
        vm.expectRevert(abi.encodeWithSelector(DustHandler.InvalidModeWord.selector, 257));
        reader.balanceMode(_blob(257), BASE_LEN);
    }

    /// Plain out-of-range (no truncation involved) reverts with the named error
    /// rather than a bare enum-conversion panic.
    function test_outOfRange_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(DustHandler.InvalidModeWord.selector, 2));
        reader.action(_blob(2), BASE_LEN);
    }

    /// Nothing outside `{0, 1}` decodes, however the high bits are arranged.
    function testFuzz_anyOutOfRangeWordReverts(uint256 word) public {
        word = bound(word, 2, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(DustHandler.InvalidModeWord.selector, word));
        reader.balanceMode(_blob(word), BASE_LEN);
    }

    /// The property the old code violated, stated directly: a word whose low byte
    /// is in range but whose high bits are set must NOT decode to that low byte.
    function testFuzz_highBitsNeverSilentlyDiscarded(uint8 lowByte, uint248 highBits) public {
        vm.assume(highBits != 0);
        uint256 word = (uint256(highBits) << 8) | uint256(lowByte);
        vm.expectRevert(abi.encodeWithSelector(DustHandler.InvalidModeWord.selector, word));
        reader.balanceMode(_blob(word), BASE_LEN);
    }
}
