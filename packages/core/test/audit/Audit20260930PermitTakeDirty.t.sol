// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "../shared/PackedEncode.sol";
import {MockSettlementBase} from "../shared/MockSettlementBase.t.sol";
import {AuditFundingTaker} from "./Audit20260930Core.t.sol";

import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";

/// @title Audit20260930PermitTakeDirtyTest
/// @notice X-ASM-3 sub-item (d): {Core.fillWithPermitTake} `calldatacopy`s the
///         `PermitTake` words RAW into `FillCtx.permitTake` (no ABI re-encode), and
///         {Base._takeByPermit} reads them back by pointer. A filler controls the
///         calldata, so it can set the high bits of the two NARROW words — `module`
///         (address, 96 spare bits) and `amount` (uint160, 96 spare bits). Those bits
///         must never change what the fill does: the item compare
///         (`permit.module != module || permit.amount != slice`) and the ABI-encoded
///         `permitTakeWithWitnessHash` call must both see the CLEAN values, so a dirty
///         permit settles byte-for-byte like the clean one the maker signed — the
///         same draw, the same nonce burnt, nothing more.
contract Audit20260930PermitTakeDirtyTest is MockSettlementBase {
    uint256 constant IN_ = 1_000e18;
    uint256 constant OUT_ = 2e18;

    bytes32 constant PERMIT_TAKE_WITNESS_TH = keccak256(
        bytes(
            "PermitTakeWitness(address module,bytes32 ref,uint160 amount,address spender,uint256 nonce,uint256 deadline,Order witness)Order(address maker,uint256 nonce,bytes legsIn,bytes legsOut,uint256 timing,address exclusiveFiller,uint256 minFillAnchor,uint256 params,bytes curve,bytes items,bytes validators,bytes invariants,address fillModule,uint256 fillTotal,address pricingModule)"
        )
    );

    // Calldata word offsets of the INLINE (static) PermitTake struct, after the
    // selector and the order's offset word: module, ref, amount, nonce, deadline.
    uint256 constant MODULE_AT = 4 + 32;
    uint256 constant AMOUNT_AT = 4 + 32 * 3;

    function _signPermitTake(IPermit3.PermitTake memory p, bytes32 witness) internal view returns (bytes memory) {
        bytes32 hs = keccak256(
            abi.encode(
                PERMIT_TAKE_WITNESS_TH, p.module, p.ref, p.amount, address(settlement), p.nonce, p.deadline, witness
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", permit3.DOMAIN_SEPARATOR(), hs));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _setup() internal returns (bytes memory cd, AuditFundingTaker taker) {
        taker = new AuditFundingTaker(address(permit3));
        tA.mint(address(taker), IN_);
        tB.mint(solver, OUT_);
        _solverApprove(address(settlement), address(tB), OUT_);

        bytes memory data = abi.encode(address(tA), IN_);
        Order memory o = _plainOrder(1, address(tA), address(tB), IN_, OUT_);
        Item[] memory its = new Item[](1);
        its[0] = Item({op: ItemOp.TAKE, module: address(taker), amount: IN_, recipient: address(0), data: data});
        o.items = PackedEncode.items(its);

        IPermit3.PermitTake memory p = IPermit3.PermitTake({
            module: address(taker), ref: keccak256(data), amount: uint160(IN_), nonce: 77, deadline: block.timestamp + 1 hours
        });
        bytes memory psig = _signPermitTake(p, _hashOrder(o));
        cd = abi.encodeWithSelector(
            bytes4(keccak256(
                "fillWithPermitTake((address,uint256,bytes,bytes,uint256,address,uint256,uint256,bytes,bytes,bytes,bytes,address,uint256,address),(address,bytes32,uint160,uint256,uint256),bytes,uint256,uint256)"
            )),
            o,
            p,
            psig,
            IN_,
            uint256(0)
        );
        // Sanity: the layout constants point at the words we think they do.
        assertEq(_word(cd, MODULE_AT), uint256(uint160(address(taker))), "module word");
        assertEq(_word(cd, AMOUNT_AT), IN_, "amount word");
    }

    function _word(bytes memory b, uint256 at) internal pure returns (uint256 w) {
        assembly {
            w := mload(add(add(b, 0x20), at))
        }
    }

    function _setWord(bytes memory b, uint256 at, uint256 w) internal pure {
        assembly {
            mstore(add(add(b, 0x20), at), w)
        }
    }

    function _assertCleanOutcome(AuditFundingTaker taker) internal view {
        assertEq(tA.balanceOf(solver), IN_, "solver paid exactly the signed draw");
        assertEq(tA.balanceOf(address(taker)), 0, "the module drew exactly the signed amount");
        assertEq(tB.balanceOf(maker), OUT_, "maker received the output");
        assertEq(tA.balanceOf(address(settlement)), 0, "nothing stranded");
        assertTrue(permit3.isPermitNonceUsed(maker, 77), "the signed permit nonce is the one burnt");
    }

    /// @dev Control: the clean calldata settles.
    function test_audit_X_ASM_3_permitTake_cleanControl() public {
        (bytes memory cd, AuditFundingTaker taker) = _setup();
        vm.prank(solver);
        (bool ok,) = address(settlement).call(cd);
        assertTrue(ok, "clean permit-take fill");
        _assertCleanOutcome(taker);
    }

    /// @dev Dirty high bits in BOTH narrow words: the fill must settle exactly like
    ///      the clean one (the maker's signature over the clean values verifies,
    ///      the item compare matches the clean module/amount).
    function testFuzz_audit_X_ASM_3_permitTake_dirtyHighBits_settleClean(uint96 dirtyModule, uint96 dirtyAmount)
        public
    {
        (bytes memory cd, AuditFundingTaker taker) = _setup();
        _setWord(cd, MODULE_AT, _word(cd, MODULE_AT) | (uint256(dirtyModule) << 160));
        _setWord(cd, AMOUNT_AT, _word(cd, AMOUNT_AT) | (uint256(dirtyAmount) << 160));

        vm.prank(solver);
        (bool ok,) = address(settlement).call(cd);
        assertTrue(ok, "dirty high bits are cleaned, never a different permit");
        _assertCleanOutcome(taker);
    }

    /// @dev Dirty bits do not make a permit for a DIFFERENT amount pass: the low
    ///      160 bits are the amount, and a mismatch there still reverts.
    function test_audit_X_ASM_3_permitTake_dirtyHighBits_wrongLowBitsStillRefused() public {
        (bytes memory cd, AuditFundingTaker taker) = _setup();
        _setWord(cd, AMOUNT_AT, (uint256(1) << 200) | (IN_ - 1));
        vm.prank(solver);
        (bool ok,) = address(settlement).call(cd);
        assertFalse(ok, "a different signed amount is refused");
        assertEq(tA.balanceOf(address(taker)), IN_, "nothing drawn");
        assertFalse(permit3.isPermitNonceUsed(maker, 77), "nonce intact");
    }
}
