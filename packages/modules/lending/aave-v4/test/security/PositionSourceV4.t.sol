// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order} from "@core/settlement/Settlement.sol";
import {IPositionSource} from "@core/interfaces/IPositionSource.sol";
import {PositionFillModule} from "@lib/PositionFillModule.sol";

import {ISpokeV4} from "../../src/interfaces/IAaveV4.sol";
import {AaveV4ModulesBase} from "../shared/AaveV4ModulesBase.t.sol";

/// @title Audit 2026-09-30 L-LIB-8 — AaveV4WithdrawModule reports the live position
/// @notice A position-sized exit ({PositionFillModule}) reverted `NoPositionItem` on
///         v4 because the withdraw module exposed no reader. Raw staticcalls so the
///         test compiles — and fails — against the pre-fix module.
contract PositionSourceV4Test is AaveV4ModulesBase {
    function test_audit_L_LIB_8_aaveV4PositionOfAndPositionSizedFill() public {
        _seedV4WethPosition(2 ether);
        bytes memory data = abi.encode(MAIN_SPOKE, TAKER_PM, wethReserveId, WETH);

        (bool ok, bytes memory ret) =
            address(withdrawModule).staticcall(abi.encodeCall(IPositionSource.positionOf, (maker, data)));
        assertTrue(ok && ret.length == 64, "withdraw module answers positionOf");
        (address asset, uint256 amount) = abi.decode(ret, (address, uint256));
        uint256 supplied = ISpokeV4(MAIN_SPOKE).getUserSuppliedAssets(wethReserveId, maker);
        assertEq(asset, WETH, "denominated in the underlying");
        assertEq(amount, supplied, "the raw supplied position");

        // A position-sized exit capped at 3 WETH resolves to the live 2 WETH position.
        PositionFillModule pfm = new PositionFillModule();
        Order memory o = _buildV4WithdrawOrder(3 ether, 6_000e6, data);
        o.fillModule = address(pfm);
        o.fillTotal = 3 ether;
        assertEq(pfm.resolveFill(o, 0, type(uint256).max, ""), supplied, "fill sized from the position");
    }
}
