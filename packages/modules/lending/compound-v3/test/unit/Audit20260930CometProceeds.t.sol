// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IProceedsAsset} from "@core/interfaces/IProceedsAsset.sol";
import {DustHandler} from "@lib/DustHandler.sol";

import {CometTakerModule} from "../../src/CompoundV3Modules.sol";

/// @title Audit20260930CometProceedsTest
/// @notice 2026-09-30 audit, L-CMT-6: `SettlementLens` SKIPS its F22
///         stranded-proceeds preflight for a taker module that does not answer
///         `IProceedsAsset.proceedsAsset`. `CometTakerModule` did not, although its
///         proceeds token is static (`asset`, word 2, on both ops). Read through a
///         raw staticcall so the test compiles — and FAILS — against the pre-fix
///         module.
contract Audit20260930CometProceedsTest is Test {
    CometTakerModule taker;
    address constant COMET = address(0xC0E7);
    address constant BASE = address(0xBA5E);
    address constant COLL = address(0xC011);

    function setUp() public {
        taker = new CometTakerModule(address(0xBEEF));
    }

    function _proceeds(bytes memory data) internal view returns (address) {
        (bool ok, bytes memory ret) = address(taker).staticcall(abi.encodeCall(IProceedsAsset.proceedsAsset, (data)));
        assertTrue(ok && ret.length == 32, "answers proceedsAsset");
        return abi.decode(ret, (address));
    }

    function test_audit_L_CMT_6_comet_declaresProceedsAsset() public view {
        // Borrow: the base.
        assertEq(_proceeds(abi.encode(uint8(CometTakerModule.Op.Borrow), COMET, BASE)), BASE);
        // Exact withdraw of collateral, with an explicit Exact mode word + allow block.
        assertEq(
            _proceeds(
                abi.encode(uint8(CometTakerModule.Op.Withdraw), COMET, COLL, uint256(0), uint256(1), uint256(2), uint8(27), bytes32(0), bytes32(0))
            ),
            COLL
        );
        // Full withdraw.
        assertEq(
            _proceeds(
                abi.encode(
                    uint8(CometTakerModule.Op.Withdraw), COMET, COLL, DustHandler.encodeMode(DustHandler.BalanceMode.Full), 1e18
                )
            ),
            COLL
        );
    }
}
