// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Order} from "@core/settlement/Settlement.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";

import {FlashSolverAudit20260930Test} from "./FlashSolverAudit.t.sol";

/// @title FlashPermitEnvelopeTest
/// @notice Audit 2026-09-30 AGG-6 (the permit half): a single-signature order —
///         the maker signed a Permit3 `PermitBatchWitness`, not an EIP-712 Order —
///         takes its first fill only through `Settlement.fillWithPermit`, which runs
///         no filler callback, so no zero-inventory filler in the repo could serve
///         it. Every flash solver already pays the outputs out of the flash, so it
///         now takes such an order through a permit-enveloped `sig`
///         ({BaseFlashSolver.PERMIT_ENVELOPE}).
///
///         Written against the envelope's LAYOUT, not the solver's constant, so the
///         file compiles against the pre-fix solvers: there the envelope reaches
///         `fill` as an order signature and every fill reverts.
contract FlashPermitEnvelopeTest is FlashSolverAudit20260930Test {
    bytes32 constant ENVELOPE = keccak256("1delta.BaseFlashSolver.PermitEnvelope");

    /// @dev A maker that has granted NOTHING beyond the ERC-20 approval to Permit3:
    ///      the permit inside the envelope is its only authorisation.
    function _permitMaker(uint256 pk) internal returns (address m) {
        m = vm.addr(pk);
        tB.mint(m, IN_B);
        vm.prank(m);
        tB.approve(address(permit3), type(uint256).max);
    }

    function _envelope(Order memory o, uint256 pk, uint256 permitNonce) internal view returns (bytes memory) {
        IPermit3.PermitBatch memory batch = _buildBatch(
            _tokenPermit1(address(settlement), address(tB), IN_B, uint48(block.timestamp + 1 hours)),
            permitNonce,
            block.timestamp + 1 hours
        );
        bytes memory psig = _signPermitWitnessWith(batch, _hashOrder(o), pk);
        return abi.encode(ENVELOPE, batch, psig, uint256(0));
    }

    /// AGG-6: every one of the ten flash solvers fills a PermitBatchWitness order
    /// with zero inventory and ends holding nothing. Fails before the fix (the
    /// envelope was handed to `fill` as an order signature).
    function test_audit_AGG_6_flashSolversFillPermitWitnessOrders() public {
        address[10] memory all = _all();
        for (uint256 i; i < all.length; i++) {
            uint256 pk = 0xF1A5 + i;
            address m = _permitMaker(pk);
            Order memory o = _order(500 + i);
            o.maker = m;
            bytes memory env = _envelope(o, pk, i);

            _exec(i, o, env, IN_B);

            assertEq(tA.balanceOf(m), OUT_A, "maker paid out of the flash");
            assertEq(tB.balanceOf(m), 0, "maker's input taken under the permit");
            assertEq(settlement.filled(_hashOrder(o)), IN_B, "filled through fillWithPermit");
            assertEq(tA.balanceOf(all[i]), 0, "no tA residue");
            assertEq(tB.balanceOf(all[i]), 0, "no tB residue");
        }
    }

    /// AGG-6: the envelope carries no authority of its own — a permit signed by
    /// someone other than the order's maker is refused by the settler.
    function test_audit_AGG_6_permitEnvelopeSignedByStrangerReverts() public {
        address m = _permitMaker(0xF1B0);
        Order memory o = _order(600);
        o.maker = m;
        bytes memory env = _envelope(o, 0xBAD, 0);
        vm.expectRevert();
        _exec(1, o, env, IN_B);
        assertEq(tB.balanceOf(m), IN_B, "maker untouched");
    }

    /// AGG-6: the solver's constant and builder match the layout off-chain callers use.
    function test_audit_AGG_6_permitEnvelopeHelperMatchesLayout() public view {
        (bool ok, bytes memory ret) = address(aaveS).staticcall(abi.encodeWithSignature("PERMIT_ENVELOPE()"));
        assertTrue(ok);
        assertEq(abi.decode(ret, (bytes32)), ENVELOPE);

        IPermit3.PermitBatch memory batch = _buildBatch(
            _tokenPermit1(address(settlement), address(tB), IN_B, uint48(block.timestamp + 1 hours)), 7, block.timestamp
        );
        bytes memory psig = hex"1234";
        (ok, ret) = address(aaveS).staticcall(
            abi.encodeWithSignature(
                "permitEnvelope(((address,address,uint160,uint48)[],(address,address,bytes32,uint160,uint48)[],uint256,uint256),bytes,uint256)",
                batch,
                psig,
                uint256(5)
            )
        );
        assertTrue(ok);
        assertEq(abi.decode(ret, (bytes)), abi.encode(ENVELOPE, batch, psig, uint256(5)));
    }
}
