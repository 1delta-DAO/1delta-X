// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Settlement, Order} from "@core/settlement/Settlement.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {OrderHash} from "@core/settlement/OrderHash.sol";
import {SignatureVerification} from "@core/permit3/SignatureVerification.sol";

import {MockSettlementBase} from "../shared/MockSettlementBase.t.sol";

/// @title PermitWitnessSettlementBinding
/// @notice Re-audit 2026-09-25: the `fillWithPermit` witness names the SETTLER.
///
///  On `fillWithPermit` the permit signature is the order's only authorization, and
///  Permit3 checks it under PERMIT3's domain — which names Permit3, not a settler —
///  while an `Order` has no settler field. With the bare order hash as the witness,
///  one signature authorized the order on EVERY Settlement wired to the same Permit3
///  (a redeploy reusing Permit3, which `Deploy.s.sol` does by design), and the
///  spent-nonce skip then let the second settler re-fill an order the first had
///  already filled in full. The witness is now `SettlementOrder{settlement, order}`.
contract PermitWitnessSettlementBindingTest is MockSettlementBase {
    uint256 constant AMOUNT_IN = 1_000e18;
    uint256 constant AMOUNT_OUT = 2e18;

    Settlement s2;

    function setUp() public override {
        super.setUp();
        // A second settler on the SAME Permit3 — the v2-redeploy shape.
        // Same switch as `settlement` (see {DeployedBytecode}), so under
        // DEPLOYED_BYTECODE=1 both settlers run the shipped via-IR bytecode: the helper
        // builds over the Permit3 in `permit3`'s slot and stores into `s2`'s.
        if (DEPLOYED_BYTECODE) {
            assembly ("memory-safe") {
                let plan := or(SHIP_SETTLEMENT, or(shl(8, permit3.offset), shl(16, permit3.slot))) // Permit3 offset | slot
                plan := or(plan, or(shl(80, s2.offset), shl(88, s2.slot))) // Settlement offset | slot
                mstore(0x00, DEPLOY_PLAN_SELECTOR)
                mstore(0x04, plan)
                if iszero(delegatecall(gas(), DEPLOYED_BYTECODE_HELPER, 0x00, 0x24, 0x00, 0x00)) {
                    returndatacopy(0x00, 0x00, returndatasize())
                    revert(0x00, returndatasize())
                }
            }
        } else {
            s2 = new Settlement(address(permit3));
        }
        vm.label(address(s2), "settlementV2");

        tA.mint(maker, 2 * AMOUNT_IN);
        vm.startPrank(maker);
        tA.approve(address(permit3), type(uint256).max);
        // The maker has migrated: a standing allowance to v2, which is what the
        // replay would have spent.
        permit3.approveToken(address(s2), address(tA), type(uint160).max, uint48(block.timestamp + 30 days));
        vm.stopPrank();

        tB.mint(solver, 2 * AMOUNT_OUT);
        _solverApprove(address(settlement), address(tB), AMOUNT_OUT);
        _solverApprove(address(s2), address(tB), AMOUNT_OUT);
    }

    function _permitFor(Order memory order, uint256 permitNonce)
        internal
        view
        returns (IPermit3.PermitBatch memory batch, bytes memory sig)
    {
        IPermit3.TokenPermit[] memory tp =
            _tokenPermit1(address(settlement), address(tA), AMOUNT_IN, uint48(block.timestamp + 1 hours));
        batch = _buildBatch(tp, permitNonce, block.timestamp + 1 hours);
        // Signed for `settlement` (v1): the helper binds `address(settlement)`.
        sig = _signPermitWitness(batch, _hashOrder(order));
    }

    /// @dev THE EXPLOIT. Filled in full on v1; the same calldata replayed on v2 finds
    ///      `filled == 0` there and the permit nonce already spent. Before the fix
    ///      the spent-nonce skip passed and v2 pulled a SECOND `AMOUNT_IN` through the
    ///      maker's v2 allowance. Now the v2 witness differs, so the signature fails.
    function test_permitWitness_filledOnV1_cannotBeReplayedOnV2() public {
        Order memory order = _plainOrder(1, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        (IPermit3.PermitBatch memory batch, bytes memory sig) = _permitFor(order, 7);

        vm.prank(solver);
        settlement.fillWithPermit(order, batch, sig, AMOUNT_IN);
        assertEq(tA.balanceOf(maker), AMOUNT_IN, "v1 took exactly one input");
        assertTrue(permit3.isPermitNonceUsed(maker, 7), "nonce spent on v1");

        vm.prank(solver);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        s2.fillWithPermit(order, batch, sig, AMOUNT_IN);

        assertEq(tA.balanceOf(maker), AMOUNT_IN, "v2 took nothing");
        assertEq(s2.filled(_hashOrder(order)), 0, "no progress on v2");
    }

    /// @dev The fresh-nonce form: a signature meant for v1 never authorizes v2,
    ///      whether or not v1 has seen it.
    function test_permitWitness_signedForV1_neverFillsOnV2() public {
        Order memory order = _plainOrder(2, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        (IPermit3.PermitBatch memory batch, bytes memory sig) = _permitFor(order, 8);

        vm.prank(solver);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        s2.fillWithPermit(order, batch, sig, AMOUNT_IN);
        assertFalse(permit3.isPermitNonceUsed(maker, 8), "nothing consumed");
    }

    /// @dev Positive control: a permit the maker signs FOR v2 fills on v2.
    function test_permitWitness_signedForV2_fillsOnV2() public {
        Order memory order = _plainOrder(3, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        IPermit3.TokenPermit[] memory tp =
            _tokenPermit1(address(s2), address(tA), AMOUNT_IN, uint48(block.timestamp + 1 hours));
        IPermit3.PermitBatch memory batch = _buildBatch(tp, 9, block.timestamp + 1 hours);
        bytes32 witnessForV2 = keccak256(abi.encode(OrderHash.SETTLEMENT_ORDER_TYPEHASH, address(s2), _hashOrder(order)));
        bytes memory sig = _signRawPermitWitnessWith(batch, witnessForV2, makerPk);

        vm.prank(solver);
        s2.fillWithPermit(order, batch, sig, AMOUNT_IN);
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "filled on the settler it was signed for");
    }
}
