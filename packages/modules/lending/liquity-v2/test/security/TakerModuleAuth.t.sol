// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {LiquityV2TakerModule} from "../../src/LiquityV2Modules.sol";

/// @dev The taker module MUST reject any caller other than Permit3 — otherwise a
/// direct `takeOnBehalf` would bypass the Permit3 allowance gate and drain the
/// victim via their per-trove remove-manager grant. Runs without a fork.
contract LiquityV2TakerModuleAuthTest is Test {
    LiquityV2TakerModule taker;

    address permit3 = address(0xBEEF);
    address maker = address(0xA11CE);
    address attacker = address(0xBAD);
    address registry = address(0x0B5); // unused: every test here reverts on the msg.sender gate first
    uint256 troveId = uint256(keccak256("trove"));
    address token = address(0x5A7);

    function setUp() public {
        taker = new LiquityV2TakerModule(permit3, registry);
    }

    function _borrowData() internal view returns (bytes memory) {
        return abi.encode(uint8(LiquityV2TakerModule.Op.Borrow), uint256(0), troveId, token, uint256(1e16), uint256(1e18));
    }

    function _withdrawData() internal view returns (bytes memory) {
        return abi.encode(uint8(LiquityV2TakerModule.Op.WithdrawColl), uint256(0), troveId, token);
    }

    function test_borrow_rejects_non_permit3() public {
        vm.prank(attacker);
        vm.expectRevert(LiquityV2TakerModule.OnlyPermit3.selector);
        taker.takeOnBehalf(maker, 1e18, attacker, _borrowData());
    }

    function test_withdraw_rejects_non_permit3() public {
        vm.prank(attacker);
        vm.expectRevert(LiquityV2TakerModule.OnlyPermit3.selector);
        taker.takeOnBehalf(maker, 1e18, attacker, _withdrawData());
    }

    /// @dev `data` with its leading op word raised by 256 — the value a bare
    ///      `uint8(...)` cast read back as the SAME op.
    function _opPlus256(bytes memory d) internal pure returns (bytes memory) {
        assembly {
            mstore(add(d, 0x20), add(mload(add(d, 0x20)), 256))
        }
        return d;
    }

    /// @dev Re-audit F30: an out-of-range op word reverts at dispatch. (It already
    ///      reverted in every branch's own `uint8` decode; this pins the property to
    ///      the dispatch so a future branch that skips the re-decode cannot run op
    ///      `word mod 256`.)
    function test_opWordAbove255_reverts() public {
        vm.prank(permit3);
        vm.expectRevert();
        taker.takeOnBehalf(maker, 1e18, attacker, _opPlus256(_borrowData()));
    }
}
