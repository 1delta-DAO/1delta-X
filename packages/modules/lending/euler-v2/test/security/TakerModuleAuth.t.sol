// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EulerV2ModulesBase} from "../shared/EulerV2ModulesBase.t.sol";
import {EulerV2OperatorModule} from "../../src/EulerV2OperatorModule.sol";
import {PreFundModuleBase} from "@lib/PreFundModuleBase.sol";
import {PreFundGuard} from "@lib/PreFundGuard.sol";

/// @dev The taker modules MUST reject any caller other than Permit3 — otherwise a
/// direct `takeOnBehalf(victim, amount, attacker, data)` would bypass the Permit3
/// allowance gate and drain the victim via their EVC operator grant.
contract EulerTakerModuleAuthTest is EulerV2ModulesBase {
    address attacker = address(0xBAD);

    function test_borrow_rejects_non_permit3() public {
        vm.prank(attacker);
        vm.expectRevert(PreFundModuleBase.OnlyPermit3.selector);
        operatorModule.takeOnBehalf(
            maker, 1_000e6, attacker, abi.encode(uint8(EulerV2OperatorModule.Op.Borrow), address(EUSDC))
        );
    }

    function test_withdraw_rejects_non_permit3() public {
        vm.prank(attacker);
        vm.expectRevert(PreFundModuleBase.OnlyPermit3.selector);
        operatorModule.takeOnBehalf(
            maker, 1 ether, attacker, abi.encode(uint8(EulerV2OperatorModule.Op.Withdraw), address(EWETH))
        );
    }

    function test_batch_rejects_non_permit3() public {
        EulerV2OperatorModule.BatchData memory p = EulerV2OperatorModule.BatchData({
            op: uint256(EulerV2OperatorModule.Op.BatchClose),
            collateralVault: address(EWETH),
            borrowVault: address(EUSDC),
            sideAmount: 1_000e6,
            totalAmount: 1e18
        });
        vm.prank(attacker);
        vm.expectRevert(PreFundModuleBase.OnlyPermit3.selector);
        operatorModule.takeOnBehalf(maker, 1 ether, attacker, abi.encode(p));
    }

    // ──────── what merging four contracts onto one address must not weaken ────────

    /// @dev An op this contract does not implement is rejected BY NAME, not left to a
    ///      decode that happens to fail. The merge is sound because the op sits inside
    ///      `data`, hence inside `ref = keccak256(data)` — and that only holds if an
    ///      unknown op is a hard error rather than a silent fall-through onto a real
    ///      op the grant never named.
    function test_takeOnBehalf_revertsOnUnknownOp() public {
        vm.prank(address(permit3));
        vm.expectRevert(abi.encodeWithSelector(EulerV2OperatorModule.BadOp.selector, uint256(9)));
        operatorModule.takeOnBehalf(maker, 1 ether, attacker, abi.encode(uint256(9), address(EWETH)));
    }

    /// @dev The `TAKE_FOR` seam admits `Op.Open` ONLY. The plain ops have no funding
    ///      leg for the core to size, so admitting one would mean accepting a
    ///      `forAmount` no body spends.
    function test_takeForOnBehalf_rejectsAPlainOp() public {
        // A leg-reference descriptor carrying the BORROW op in bits [244,252).
        uint256 desc = (uint256(1) << 255) | (uint256(EulerV2OperatorModule.Op.Borrow) << 244);
        bytes memory data = abi.encode(
            EulerV2OperatorModule.OpenData({
                forDesc: desc,
                forCap: 0,
                collateralVault: address(EWETH),
                borrowVault: address(EUSDC)
            })
        );
        vm.prank(address(permit3));
        vm.expectRevert(abi.encodeWithSelector(EulerV2OperatorModule.BadOp.selector, uint256(0)));
        operatorModule.takeForOnBehalf(address(settlement), maker, 1_000e6, 1 ether, attacker, data);
    }

    /// @dev The plain seam must refuse a blob whose word 0 is a FUNDING DESCRIPTOR.
    ///      Now that one contract hosts both entrypoints, this is what keeps a single
    ///      `approveTaker` from being valid for either dispatch.
    function test_takeOnBehalf_rejectsAFundingDescriptorBlob() public {
        vm.prank(address(permit3));
        vm.expectRevert(PreFundGuard.PreFundDescriptorNotAllowed.selector);
        operatorModule.takeOnBehalf(
            maker, 1 ether, attacker, abi.encode((uint256(1) << 255) | (uint256(1) << 253), address(EWETH))
        );
    }

    /// @dev `Permit3.takeFor` is a PERMISSIONLESS entrypoint and `approveTaker` lets a
    ///      caller name ITSELF spender, so `msg.sender == permit3` authorises nothing
    ///      on its own (F27/C-1). Merging did not relax the spender pin.
    function test_takeForOnBehalf_rejectsForeignSpender() public {
        uint256 desc = (uint256(1) << 255) | (uint256(EulerV2OperatorModule.Op.Open) << 244);
        bytes memory data = abi.encode(
            EulerV2OperatorModule.OpenData({
                forDesc: desc,
                forCap: 0,
                collateralVault: address(EWETH),
                borrowVault: address(EUSDC)
            })
        );
        vm.prank(address(permit3));
        vm.expectRevert(PreFundGuard.OnlySettlement.selector);
        operatorModule.takeForOnBehalf(attacker, maker, 1_000e6, 1 ether, attacker, data);
    }

    /// @dev `Op.Borrow` kept wire value 0 — which was ALSO the old `BatchMode.Open`.
    ///      A stale `BatchData` blob would otherwise decode as a clean Borrow from what
    ///      was its `collateralVault`. The exact-length pin makes it fail closed.
    function test_borrow_rejectsAStaleBatchDataBlob() public {
        bytes memory stale = abi.encode(
            EulerV2OperatorModule.BatchData({
                op: 0, // the OLD BatchMode.Open
                collateralVault: address(EWETH),
                borrowVault: address(EUSDC),
                sideAmount: 1 ether,
                totalAmount: 1_000e6
            })
        );
        vm.prank(address(permit3));
        vm.expectRevert(EulerV2OperatorModule.MalformedData.selector);
        operatorModule.takeOnBehalf(maker, 1_000e6, attacker, stale);
    }
}
