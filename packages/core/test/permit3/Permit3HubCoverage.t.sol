// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {Permit3} from "../../src/permit3/Permit3.sol";
import {IPermit3} from "../../src/interfaces/IPermit3.sol";
import {ITakerModule} from "../../src/interfaces/ITakerModule.sol";
import {ITakerForModule} from "../../src/interfaces/ITakerForModule.sol";
import {SignatureVerification} from "../../src/permit3/SignatureVerification.sol";
import {DeployedBytecode} from "../shared/DeployedBytecode.sol";
import {MockERC20, MockTakerModule} from "../Permit3.t.sol";

/// @dev Records a `takeFor` dispatch, including the forwarded spender.
contract HubCovTakerForModule is ITakerModule, ITakerForModule {
    address public lastSpender;
    uint256 public lastAmount;
    uint256 public lastFor;
    uint256 public calls;

    function takeOnBehalf(address, uint256 amount, address, bytes calldata) external override {
        lastAmount = amount;
        ++calls;
    }

    function takeForOnBehalf(address spender, address, uint256 amount, uint256 forAmount, address, bytes calldata)
        external
        override
    {
        lastSpender = spender;
        lastAmount = amount;
        lastFor = forAmount;
        ++calls;
    }
}

/// @dev Re-enters `takeFor` from inside a `take` dispatch.
contract HubCovReenterTakeFor is ITakerModule {
    Permit3 immutable P3;

    constructor(Permit3 p) {
        P3 = p;
    }

    function takeOnBehalf(address user, uint256 amount, address receiver, bytes calldata data) external override {
        P3.takeFor(address(this), user, uint160(amount), 0, receiver, data);
    }
}

/// @title Permit3HubCoverage
/// @notice Hub-level gaps listed by audit 2026-09-30 P3-3: `takeFor` (zero amount,
///         the bucket it shares with `take`, the shared lock, the forwarded spender),
///         taker-book expiry through `take`, the INCLUSIVE expiry/deadline boundaries,
///         the string `permitTakeWithWitness` variant, `permitTake`'s deadline, and
///         that the caller-supplied-typehash entries reject a signature made for a
///         different Permit3 message type.
contract Permit3HubCoverageTest is Test, DeployedBytecode {
    Permit3 permit3;
    MockERC20 token;
    MockTakerModule taker;
    HubCovTakerForModule forMod;

    uint256 ownerPk = 0xA11CE;
    address owner = vm.addr(0xA11CE);
    address recipient = address(0xCAFE);

    bytes32 constant PERMIT_TAKE_TH =
        keccak256("PermitTake(address module,bytes32 ref,uint160 amount,address spender,uint256 nonce,uint256 deadline)");
    string constant TAKE_WITNESS_STUB =
        "PermitTakeWitness(address module,bytes32 ref,uint160 amount,address spender,uint256 nonce,uint256 deadline,";
    string constant TAKE_WITNESS_TYPE_STRING = "bytes32 witness)";
    bytes32 constant TOKEN_PERMIT_TH =
        keccak256("TokenPermit(address spender,address token,uint160 amount,uint48 expiration)");
    bytes32 constant PERMIT_BATCH_TH = keccak256(
        "PermitBatch(TokenPermit[] tokens,TakerPermit[] takers,uint256 nonce,uint256 deadline)"
        "TakerPermit(address spender,address module,bytes32 ref,uint160 amount,uint48 expiration)"
        "TokenPermit(address spender,address token,uint160 amount,uint48 expiration)"
    );

    function setUp() public {
        if (DEPLOYED_BYTECODE) {
            assembly ("memory-safe") {
                let plan := or(SHIP_PERMIT3, or(shl(8, permit3.offset), shl(16, permit3.slot)))
                plan := or(plan, shl(80, NO_SLOT))
                mstore(0x00, DEPLOY_PLAN_SELECTOR)
                mstore(0x04, plan)
                if iszero(delegatecall(gas(), DEPLOYED_BYTECODE_HELPER, 0x00, 0x24, 0x00, 0x00)) {
                    returndatacopy(0x00, 0x00, returndatasize())
                    revert(0x00, returndatasize())
                }
            }
        } else {
            permit3 = new Permit3();
        }
        token = new MockERC20();
        taker = new MockTakerModule(address(permit3));
        forMod = new HubCovTakerForModule();
        token.mint(owner, 1_000e18);
        vm.prank(owner);
        token.approve(address(permit3), type(uint256).max);
    }

    function _sign(bytes32 hashStruct) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", permit3.DOMAIN_SEPARATOR(), hashStruct));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    // ──────────────────── takeFor ────────────────────

    function test_audit_P3_3_takeFor_zeroAmount_reverts() public {
        vm.expectRevert(IPermit3.ZeroAmount.selector);
        permit3.takeFor(address(forMod), owner, 0, 1, recipient, "");
        assertEq(forMod.calls(), 0, "module never reached");
    }

    function test_audit_P3_3_takeFor_sharesTakesBucket_andForwardsSpender() public {
        bytes memory data = abi.encode(uint256(1));
        vm.prank(owner);
        permit3.approveTaker(address(this), address(forMod), keccak256(data), 100e18, 0);

        permit3.take(address(forMod), owner, 40e18, recipient, data);
        permit3.takeFor(address(forMod), owner, 60e18, 7, recipient, data);
        assertEq(forMod.lastSpender(), address(this), "spender forwarded verbatim");
        assertEq(forMod.lastFor(), 7);

        vm.expectRevert(abi.encodeWithSelector(IPermit3.InsufficientAllowance.selector, uint160(0)));
        permit3.takeFor(address(forMod), owner, 1, 0, recipient, data);
    }

    function test_audit_P3_3_takeFor_lockedByTake() public {
        HubCovReenterTakeFor evil = new HubCovReenterTakeFor(permit3);
        bytes memory data = abi.encode(uint256(2));
        vm.prank(owner);
        permit3.approveTaker(address(this), address(evil), keccak256(data), type(uint160).max, 0);
        vm.expectRevert(IPermit3.Reentrancy.selector);
        permit3.take(address(evil), owner, 1e18, recipient, data);
    }

    // ──────────────────── taker-book expiry + inclusive boundaries ────────────────────

    function test_audit_P3_3_takerExpiry_inclusiveThenExpired() public {
        bytes memory data = abi.encode(uint256(3));
        uint48 exp = uint48(block.timestamp + 100);
        vm.prank(owner);
        permit3.approveTaker(address(this), address(taker), keccak256(data), 100e18, exp);

        vm.warp(exp); // exactly at expiration: still live
        permit3.take(address(taker), owner, 1e18, recipient, data);

        vm.warp(uint256(exp) + 1);
        vm.expectRevert(abi.encodeWithSelector(IPermit3.AllowanceExpired.selector, exp));
        permit3.take(address(taker), owner, 1e18, recipient, data);
    }

    function test_audit_P3_3_tokenExpiry_inclusive() public {
        uint48 exp = uint48(block.timestamp + 100);
        vm.prank(owner);
        permit3.approveToken(address(this), address(token), 100e18, exp);
        vm.warp(exp);
        permit3.transferFrom(owner, recipient, address(token), 1e18);
        assertEq(token.balanceOf(recipient), 1e18);
    }

    function _batch(uint256 nonce, uint256 deadline) internal view returns (IPermit3.PermitBatch memory b) {
        IPermit3.TokenPermit[] memory tp = new IPermit3.TokenPermit[](1);
        tp[0] = IPermit3.TokenPermit(address(this), address(token), 50e18, 0);
        b = IPermit3.PermitBatch({tokens: tp, takers: new IPermit3.TakerPermit[](0), nonce: nonce, deadline: deadline});
    }

    function _batchHash(IPermit3.PermitBatch memory b) internal pure returns (bytes32) {
        bytes32 tph = keccak256(
            abi.encodePacked(
                keccak256(
                    abi.encode(TOKEN_PERMIT_TH, b.tokens[0].spender, b.tokens[0].token, b.tokens[0].amount, b.tokens[0].expiration)
                )
            )
        );
        return keccak256(abi.encode(PERMIT_BATCH_TH, tph, keccak256(""), b.nonce, b.deadline));
    }

    function test_audit_P3_3_permitBatch_deadlineInclusive() public {
        IPermit3.PermitBatch memory b = _batch(1, block.timestamp + 10);
        bytes memory sig = _sign(_batchHash(b));
        vm.warp(b.deadline);
        permit3.permitBatch(owner, b, sig);
        (uint160 amt,) = permit3.tokenAllowance(owner, address(this), address(token));
        assertEq(amt, 50e18, "applied exactly at the deadline");
    }

    // ──────────────────── permitTake variants ────────────────────

    function _take(bytes memory data, uint256 nonce, uint256 deadline) internal view returns (IPermit3.PermitTake memory) {
        return IPermit3.PermitTake({module: address(taker), ref: keccak256(data), amount: 5e18, nonce: nonce, deadline: deadline});
    }

    function test_audit_P3_3_permitTake_deadline_inclusiveThenExpired() public {
        bytes memory data = abi.encode(uint256(4));
        IPermit3.PermitTake memory p = _take(data, 5, block.timestamp + 10);
        bytes memory sig = _sign(
            keccak256(abi.encode(PERMIT_TAKE_TH, p.module, p.ref, p.amount, address(this), p.nonce, p.deadline))
        );
        vm.warp(p.deadline + 1);
        vm.expectRevert(IPermit3.PermitExpired.selector);
        permit3.permitTake(p, owner, recipient, data, sig);

        vm.warp(p.deadline);
        permit3.permitTake(p, owner, recipient, data, sig);
        assertEq(taker.lastAmount(), 5e18, "dispatched exactly at the deadline");
    }

    function _takeWitnessHash(IPermit3.PermitTake memory p, bytes32 witness) internal view returns (bytes32) {
        bytes32 th = keccak256(abi.encodePacked(TAKE_WITNESS_STUB, TAKE_WITNESS_TYPE_STRING));
        return keccak256(abi.encode(th, p.module, p.ref, p.amount, address(this), p.nonce, p.deadline, witness));
    }

    function test_audit_P3_3_permitTakeWithWitness_stringVariant() public {
        bytes memory data = abi.encode(uint256(5));
        IPermit3.PermitTake memory p = _take(data, 6, block.timestamp + 1 hours);
        bytes32 witness = keccak256("order");
        bytes memory sig = _sign(_takeWitnessHash(p, witness));

        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        permit3.permitTakeWithWitness(p, owner, recipient, data, keccak256("other"), TAKE_WITNESS_TYPE_STRING, sig);

        permit3.permitTakeWithWitness(p, owner, recipient, data, witness, TAKE_WITNESS_TYPE_STRING, sig);
        assertEq(taker.lastAmount(), 5e18);
        assertTrue(permit3.isPermitNonceUsed(owner, 6));
    }

    // ──────────────────── cross-type rejection on the typehash-taking entries ────────────────────

    /// @dev A plain `PermitTake` signature is not a witness signature under any
    ///      caller-supplied typehash — even the PermitTake typehash itself, because the
    ///      witness entry always appends the witness word.
    function test_audit_P3_3_permitTakeWithWitnessHash_rejectsPlainPermitTakeSig() public {
        bytes memory data = abi.encode(uint256(6));
        IPermit3.PermitTake memory p = _take(data, 7, block.timestamp + 1 hours);
        bytes memory sig = _sign(
            keccak256(abi.encode(PERMIT_TAKE_TH, p.module, p.ref, p.amount, address(this), p.nonce, p.deadline))
        );
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        permit3.permitTakeWithWitnessHash(p, owner, recipient, data, bytes32(0), PERMIT_TAKE_TH, sig);
    }

    /// @dev Likewise a plain `PermitBatch` signature on the batch witness-hash entry.
    function test_audit_P3_3_permitBatchWithWitnessHashIfNeeded_rejectsPlainBatchSig() public {
        IPermit3.PermitBatch memory b = _batch(8, block.timestamp + 1 hours);
        bytes memory sig = _sign(_batchHash(b));
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        permit3.permitBatchWithWitnessHashIfNeeded(owner, b, bytes32(0), PERMIT_BATCH_TH, sig);
        (uint160 amt,) = permit3.tokenAllowance(owner, address(this), address(token));
        assertEq(amt, 0, "nothing granted");
    }
}
