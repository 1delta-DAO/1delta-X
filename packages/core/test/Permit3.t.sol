// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {Permit3} from "../src/permit3/Permit3.sol";
import {IPermit3} from "../src/interfaces/IPermit3.sol";
import {IERC1271} from "../src/interfaces/IERC1271.sol";
import {ITakerModule} from "../src/interfaces/ITakerModule.sol";
import {SignatureVerification} from "../src/permit3/SignatureVerification.sol";

// ──────────────────── Mocks ────────────────────

/// @dev Minimal ERC20 — just enough for Permit3's transferFrom path.
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev EIP-1271 smart-account wallet controlled by a single EOA key.
contract MockERC1271Wallet is IERC1271 {
    address public immutable owner;
    bool public alwaysReject;

    constructor(address _owner) {
        owner = _owner;
    }

    function setReject(bool v) external {
        alwaysReject = v;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view override returns (bytes4) {
        if (alwaysReject) return 0xffffffff;
        require(signature.length == 65, "len");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
        if (ecrecover(hash, v, r, s) == owner) return IERC1271.isValidSignature.selector;
        return 0xffffffff;
    }
}

/// @dev Records the last take and (optionally) pulls an ERC20 leg via Permit3.
contract MockTakerModule is ITakerModule {
    Permit3 public immutable permit3;
    address public lastUser;
    uint256 public lastAmount;
    address public lastReceiver;
    bytes public lastData;

    constructor(address _permit3) {
        permit3 = Permit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        require(msg.sender == address(permit3), "only permit3");
        lastUser = onBehalfOf;
        lastAmount = amount;
        lastReceiver = receiver;
        lastData = data;
    }
}

/// @dev Re-enters Permit3.take to prove the nonReentrant guard fires.
contract ReentrantTakerModule is ITakerModule {
    Permit3 public immutable permit3;

    constructor(address _permit3) {
        permit3 = Permit3(_permit3);
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data) external override {
        // Re-enter — should revert with Reentrancy().
        permit3.take(address(this), onBehalfOf, uint160(amount), receiver, data);
    }
}

// ──────────────────── Tests ────────────────────

contract Permit3Test is Test {
    Permit3 permit3;
    MockERC20 token;
    MockTakerModule taker;

    uint256 ownerPk = 0xA11CE;
    address owner = vm.addr(0xA11CE);
    address spender = address(0xBEEF);
    address recipient = address(0xCAFE);

    // Mirror Permit3's typehash constants for signing in-test.
    bytes32 constant TOKEN_PERMIT_TH =
        keccak256("TokenPermit(address spender,address token,uint160 amount,uint48 expiration)");
    bytes32 constant TAKER_PERMIT_TH =
        keccak256("TakerPermit(address spender,bytes32 ref,uint160 amount,uint48 expiration)");
    bytes32 constant PERMIT_BATCH_TH = keccak256(
        "PermitBatch(TokenPermit[] tokens,TakerPermit[] takers,uint256 nonce,uint256 deadline)"
        "TakerPermit(address spender,bytes32 ref,uint160 amount,uint48 expiration)"
        "TokenPermit(address spender,address token,uint160 amount,uint48 expiration)"
    );
    string constant WITNESS_STUB =
        "PermitBatchWitness(TokenPermit[] tokens,TakerPermit[] takers,uint256 nonce,uint256 deadline,";
    // Witness is a bare bytes32; type defs in alphabetical order after the field.
    string constant WITNESS_TYPE_STRING =
        "bytes32 witness)"
        "TakerPermit(address spender,bytes32 ref,uint160 amount,uint48 expiration)"
        "TokenPermit(address spender,address token,uint160 amount,uint48 expiration)";

    function setUp() public {
        permit3 = new Permit3();
        token = new MockERC20();
        taker = new MockTakerModule(address(permit3));

        token.mint(owner, 1_000_000e18);
        vm.prank(owner);
        token.approve(address(permit3), type(uint256).max);
    }

    // ════════════════ Token book ════════════════

    function test_approveToken_and_transferFrom() public {
        vm.prank(owner);
        permit3.approveToken(spender, address(token), 100e18, 0);

        vm.prank(spender);
        permit3.transferFrom(owner, recipient, address(token), 40e18);

        assertEq(token.balanceOf(recipient), 40e18);
        (uint160 amount,,) = permit3.tokenAllowance(owner, spender, address(token));
        assertEq(amount, 60e18, "allowance decremented");
    }

    function test_transferFrom_infinite_notDecremented() public {
        vm.prank(owner);
        permit3.approveToken(spender, address(token), type(uint160).max, 0);

        vm.prank(spender);
        permit3.transferFrom(owner, recipient, address(token), 123e18);

        (uint160 amount,,) = permit3.tokenAllowance(owner, spender, address(token));
        assertEq(amount, type(uint160).max, "infinite allowance untouched");
    }

    function test_transferFrom_revert_insufficient() public {
        vm.prank(owner);
        permit3.approveToken(spender, address(token), 10e18, 0);

        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IPermit3.InsufficientAllowance.selector, uint160(10e18)));
        permit3.transferFrom(owner, recipient, address(token), 11e18);
    }

    function test_transferFrom_revert_expired() public {
        uint48 exp = uint48(block.timestamp + 100);
        vm.prank(owner);
        permit3.approveToken(spender, address(token), 100e18, exp);

        vm.warp(block.timestamp + 101);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IPermit3.AllowanceExpired.selector, exp));
        permit3.transferFrom(owner, recipient, address(token), 1e18);
    }

    function test_transferFrom_batch() public {
        vm.prank(owner);
        permit3.approveToken(spender, address(token), 100e18, 0);

        IPermit3.AllowanceTransferDetails[] memory d = new IPermit3.AllowanceTransferDetails[](2);
        d[0] = IPermit3.AllowanceTransferDetails(owner, recipient, 30e18, address(token));
        d[1] = IPermit3.AllowanceTransferDetails(owner, address(0xD00D), 20e18, address(token));

        vm.prank(spender);
        permit3.transferFrom(d);

        assertEq(token.balanceOf(recipient), 30e18);
        assertEq(token.balanceOf(address(0xD00D)), 20e18);
        (uint160 amount,,) = permit3.tokenAllowance(owner, spender, address(token));
        assertEq(amount, 50e18, "both legs decremented");
    }

    function test_revokeToken() public {
        vm.startPrank(owner);
        permit3.approveToken(spender, address(token), 100e18, 0);
        permit3.revokeToken(spender, address(token));
        vm.stopPrank();

        (uint160 amount,,) = permit3.tokenAllowance(owner, spender, address(token));
        assertEq(amount, 0);
    }

    // ════════════════ Lockdown ════════════════

    function test_lockdown_zeroesTokenAllowances() public {
        address spender2 = address(0x1234);
        vm.startPrank(owner);
        permit3.approveToken(spender, address(token), 100e18, 0);
        permit3.approveToken(spender2, address(token), 200e18, 0);

        IPermit3.TokenSpenderPair[] memory pairs = new IPermit3.TokenSpenderPair[](2);
        pairs[0] = IPermit3.TokenSpenderPair(address(token), spender);
        pairs[1] = IPermit3.TokenSpenderPair(address(token), spender2);

        vm.expectEmit(true, false, false, true, address(permit3));
        emit IPermit3.Lockdown(owner, address(token), spender);
        permit3.lockdown(pairs);
        vm.stopPrank();

        (uint160 a1,,) = permit3.tokenAllowance(owner, spender, address(token));
        (uint160 a2,,) = permit3.tokenAllowance(owner, spender2, address(token));
        assertEq(a1, 0);
        assertEq(a2, 0);
    }

    function test_lockdownTakers_zeroesTakerAllowances() public {
        bytes32 ref = keccak256("pos");
        // Taker book is keyed by SPENDER (the caller of `take`); this test's
        // `take` would be called by address(this), so approve that spender.
        address sp = address(this);
        vm.prank(owner);
        permit3.approveTaker(sp, ref, 100e18, 0);

        IPermit3.SpenderRefPair[] memory pairs = new IPermit3.SpenderRefPair[](1);
        pairs[0] = IPermit3.SpenderRefPair(sp, ref);
        vm.prank(owner);
        permit3.lockdownTakers(pairs);

        (uint160 amount,,) = permit3.takerAllowance(owner, sp, ref);
        assertEq(amount, 0);
    }

    // ════════════════ Taker book ════════════════

    function test_approveTaker_and_take() public {
        bytes memory data = abi.encode(address(0x1111), uint256(2));
        bytes32 ref = keccak256(data);

        // Spender = address(this) since this test calls `take` directly.
        vm.prank(owner);
        permit3.approveTaker(address(this), ref, 100e18, 0);

        permit3.take(address(taker), owner, 40e18, recipient, data);

        assertEq(taker.lastUser(), owner);
        assertEq(taker.lastAmount(), 40e18);
        assertEq(taker.lastReceiver(), recipient);
        (uint160 amount,,) = permit3.takerAllowance(owner, address(this), ref);
        assertEq(amount, 60e18, "taker allowance decremented");
    }

    /// @notice C-1 regression: the taker book is keyed by SPENDER (msg.sender of
    ///         `take`), mirroring the token book — so a standing taker allowance
    ///         granted to one spender (e.g. Settlement) CANNOT be consumed by an
    ///         attacker calling `take` directly with the same `data`/ref and a
    ///         receiver they control. Before the fix, `take` was permissionless
    ///         and keyed by module, letting anyone drain borrow/withdraw proceeds.
    function test_take_revert_unauthorizedSpender_C1() public {
        bytes memory data = abi.encode(address(0x1111), uint256(2));
        bytes32 ref = keccak256(data);

        address goodSpender = address(0x5E771E); // stand-in for Settlement
        vm.prank(owner);
        permit3.approveTaker(goodSpender, ref, 100e18, 0);

        // Attacker is not the approved spender → no allowance under their key.
        address attacker = address(0xBAD);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IPermit3.InsufficientAllowance.selector, uint160(0)));
        permit3.take(address(taker), owner, 40e18, attacker, data);

        // The approved spender can still consume it (gate is not over-broad).
        vm.prank(goodSpender);
        permit3.take(address(taker), owner, 40e18, recipient, data);
        assertEq(taker.lastReceiver(), recipient, "approved spender succeeds");
    }

    function test_take_revert_insufficient() public {
        bytes memory data = abi.encode(uint256(1));
        bytes32 ref = keccak256(data);
        vm.prank(owner);
        permit3.approveTaker(address(this), ref, 5e18, 0);

        vm.expectRevert(abi.encodeWithSelector(IPermit3.InsufficientAllowance.selector, uint160(5e18)));
        permit3.take(address(taker), owner, 6e18, recipient, data);
    }

    function test_take_nonReentrant() public {
        ReentrantTakerModule evil = new ReentrantTakerModule(address(permit3));
        bytes memory data = abi.encode(uint256(7));
        bytes32 ref = keccak256(data);
        // Outer `take` is called by address(this); its allowance must pass so the
        // re-entrant inner call is what trips the guard.
        vm.prank(owner);
        permit3.approveTaker(address(this), ref, type(uint160).max, 0);

        vm.expectRevert(IPermit3.Reentrancy.selector);
        permit3.take(address(evil), owner, 1e18, recipient, data);
    }

    // ════════════════ Signed permits (EOA) ════════════════

    function test_permitBatch_setsAllowances() public {
        IPermit3.PermitBatch memory batch = _batchSingleToken(spender, address(token), 500e18, 0, 0);
        bytes memory sig = _signBatch(batch, ownerPk);

        permit3.permitBatch(owner, batch, sig);

        (uint160 amount,,) = permit3.tokenAllowance(owner, spender, address(token));
        assertEq(amount, 500e18);
        assertTrue(permit3.isPermitNonceUsed(owner, 0));
    }

    function test_permitBatch_revert_replay() public {
        IPermit3.PermitBatch memory batch = _batchSingleToken(spender, address(token), 500e18, 0, 0);
        bytes memory sig = _signBatch(batch, ownerPk);

        permit3.permitBatch(owner, batch, sig);
        vm.expectRevert(IPermit3.PermitNonceUsed.selector);
        permit3.permitBatch(owner, batch, sig);
    }

    function test_permitBatch_revert_expiredDeadline() public {
        IPermit3.PermitBatch memory batch = _batchSingleToken(spender, address(token), 1, 0, 0);
        batch.deadline = block.timestamp - 1;
        bytes memory sig = _signBatch(batch, ownerPk);

        vm.expectRevert(IPermit3.PermitExpired.selector);
        permit3.permitBatch(owner, batch, sig);
    }

    function test_permitBatch_revert_wrongSigner() public {
        IPermit3.PermitBatch memory batch = _batchSingleToken(spender, address(token), 1, 0, 0);
        bytes memory sig = _signBatch(batch, 0xB0B); // not the owner key

        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        permit3.permitBatch(owner, batch, sig);
    }

    function test_permitBatch_revert_badLength() public {
        IPermit3.PermitBatch memory batch = _batchSingleToken(spender, address(token), 1, 0, 0);
        bytes memory sig = hex"deadbeef"; // 4 bytes

        vm.expectRevert(SignatureVerification.InvalidSignatureLength.selector);
        permit3.permitBatch(owner, batch, sig);
    }

    function test_permitBatch_compactSig_2098() public {
        IPermit3.PermitBatch memory batch = _batchSingleToken(spender, address(token), 7e18, 0, 0);
        bytes32 digest = _batchDigest(batch);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);
        // EIP-2098 compact: pack v's parity into the top bit of s.
        bytes32 vs = bytes32((uint256(v - 27) << 255)) | s;
        bytes memory sig = abi.encodePacked(r, vs);
        assertEq(sig.length, 64, "compact sig is 64 bytes");

        permit3.permitBatch(owner, batch, sig);
        (uint160 amount,,) = permit3.tokenAllowance(owner, spender, address(token));
        assertEq(amount, 7e18);
    }

    // ════════════════ Signed permits (EIP-1271) ════════════════

    function test_permitBatch_eip1271_contractSigner() public {
        MockERC1271Wallet wallet = new MockERC1271Wallet(owner);
        IPermit3.PermitBatch memory batch = _batchSingleToken(spender, address(token), 9e18, 0, 0);
        bytes memory sig = _signBatch(batch, ownerPk); // signed by wallet's controlling key

        permit3.permitBatch(address(wallet), batch, sig);

        (uint160 amount,,) = permit3.tokenAllowance(address(wallet), spender, address(token));
        assertEq(amount, 9e18, "contract-signed permit applied");
    }

    function test_permitBatch_eip1271_revert_rejected() public {
        MockERC1271Wallet wallet = new MockERC1271Wallet(owner);
        wallet.setReject(true);
        IPermit3.PermitBatch memory batch = _batchSingleToken(spender, address(token), 1, 0, 0);
        bytes memory sig = _signBatch(batch, ownerPk);

        vm.expectRevert(SignatureVerification.InvalidContractSignature.selector);
        permit3.permitBatch(address(wallet), batch, sig);
    }

    // ════════════════ EIP-7702 (delegated EOA) ════════════════

    /// @dev An EIP-7702 account carries delegate code yet keeps its key: a raw
    ///      ECDSA signature still recovers to the account address. The port now
    ///      tries ecrecover first, so this must succeed even though the signer
    ///      has code (the old `code.length == 0` gate rejected it).
    function test_permitBatch_eip7702_rawKeySigner() public {
        // 7702 delegation designator: 0xef0100 ‖ delegate address.
        vm.etch(owner, bytes.concat(hex"ef0100", abi.encodePacked(address(0xDE1E6A7E))));
        assertGt(owner.code.length, 0, "owner now carries delegate code");

        IPermit3.PermitBatch memory batch = _batchSingleToken(spender, address(token), 11e18, 0, 0);
        bytes memory sig = _signBatch(batch, ownerPk);

        permit3.permitBatch(owner, batch, sig);

        (uint160 amount,,) = permit3.tokenAllowance(owner, spender, address(token));
        assertEq(amount, 11e18, "7702 raw-key permit applied");
    }

    /// @dev A 7702 account whose delegate implements EIP-1271 must still be
    ///      honoured via the contract path when the raw recovery does not match.
    function test_permitBatch_eip7702_delegated1271() public {
        MockERC1271Wallet impl = new MockERC1271Wallet(owner);
        // Copy the delegate's runtime code onto the account, mirroring a 7702
        // account that delegates to a 1271 wallet implementation.
        vm.etch(spender, address(impl).code);

        IPermit3.PermitBatch memory batch = _batchSingleToken(recipient, address(token), 5e18, 0, 0);
        bytes memory sig = _signBatch(batch, ownerPk); // signed by the delegate's controlling key

        permit3.permitBatch(spender, batch, sig);

        (uint160 amount,,) = permit3.tokenAllowance(spender, recipient, address(token));
        assertEq(amount, 5e18, "7702 delegated-1271 permit applied");
    }

    // ════════════════ Witness binding ════════════════

    function test_permitBatchWithWitness_setsAllowances() public {
        bytes32 witness = keccak256("order-hash");
        IPermit3.PermitBatch memory batch = _batchSingleToken(spender, address(token), 3e18, 0, 0);
        bytes memory sig = _signBatchWitness(batch, witness, ownerPk);

        permit3.permitBatchWithWitness(owner, batch, witness, WITNESS_TYPE_STRING, sig);

        (uint160 amount,,) = permit3.tokenAllowance(owner, spender, address(token));
        assertEq(amount, 3e18);
    }

    function test_permitBatchWithWitness_revert_wrongWitness() public {
        bytes32 witness = keccak256("order-hash");
        IPermit3.PermitBatch memory batch = _batchSingleToken(spender, address(token), 3e18, 0, 0);
        bytes memory sig = _signBatchWitness(batch, witness, ownerPk);

        bytes32 differentWitness = keccak256("other-order");
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        permit3.permitBatchWithWitness(owner, batch, differentWitness, WITNESS_TYPE_STRING, sig);
    }

    // ════════════════ Nonce invalidation ════════════════

    function test_invalidateUnorderedNonces_blocksPermit() public {
        // nonce 5 → word 0, bit 5.
        IPermit3.PermitBatch memory batch = _batchSingleToken(spender, address(token), 1, 0, 5);
        bytes memory sig = _signBatch(batch, ownerPk);

        vm.prank(owner);
        permit3.invalidateUnorderedNonces(0, 1 << 5);
        assertTrue(permit3.isPermitNonceUsed(owner, 5));

        vm.expectRevert(IPermit3.PermitNonceUsed.selector);
        permit3.permitBatch(owner, batch, sig);
    }

    // ════════════════ Fork-safe domain separator ════════════════

    function test_domainSeparator_recomputesOnChainIdChange() public {
        bytes32 d1 = permit3.DOMAIN_SEPARATOR();
        vm.chainId(block.chainid + 1);
        bytes32 d2 = permit3.DOMAIN_SEPARATOR();
        assertTrue(d1 != d2, "domain separator follows chainid");
    }

    // ════════════════ Helpers ════════════════

    function _batchSingleToken(address sp, address tk, uint160 amount, uint48 expiration, uint256 nonce)
        internal
        view
        returns (IPermit3.PermitBatch memory batch)
    {
        IPermit3.TokenPermit[] memory tp = new IPermit3.TokenPermit[](1);
        tp[0] = IPermit3.TokenPermit(sp, tk, amount, expiration);
        batch = IPermit3.PermitBatch({
            tokens: tp,
            takers: new IPermit3.TakerPermit[](0),
            nonce: nonce,
            deadline: block.timestamp + 1 hours
        });
    }

    function _hashTokenPermits(IPermit3.TokenPermit[] memory p) internal pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](p.length);
        for (uint256 i; i < p.length; i++) {
            h[i] = keccak256(abi.encode(TOKEN_PERMIT_TH, p[i].spender, p[i].token, p[i].amount, p[i].expiration));
        }
        return keccak256(abi.encodePacked(h));
    }

    function _hashTakerPermits(IPermit3.TakerPermit[] memory p) internal pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](p.length);
        for (uint256 i; i < p.length; i++) {
            h[i] = keccak256(abi.encode(TAKER_PERMIT_TH, p[i].spender, p[i].ref, p[i].amount, p[i].expiration));
        }
        return keccak256(abi.encodePacked(h));
    }

    function _batchDigest(IPermit3.PermitBatch memory batch) internal view returns (bytes32) {
        bytes32 hashStruct = keccak256(
            abi.encode(
                PERMIT_BATCH_TH,
                _hashTokenPermits(batch.tokens),
                _hashTakerPermits(batch.takers),
                batch.nonce,
                batch.deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", permit3.DOMAIN_SEPARATOR(), hashStruct));
    }

    function _signBatch(IPermit3.PermitBatch memory batch, uint256 pk) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _batchDigest(batch));
        return abi.encodePacked(r, s, v);
    }

    function _signBatchWitness(IPermit3.PermitBatch memory batch, bytes32 witness, uint256 pk)
        internal
        view
        returns (bytes memory)
    {
        bytes32 typeHash = keccak256(abi.encodePacked(WITNESS_STUB, WITNESS_TYPE_STRING));
        bytes32 hashStruct = keccak256(
            abi.encode(
                typeHash,
                _hashTokenPermits(batch.tokens),
                _hashTakerPermits(batch.takers),
                batch.nonce,
                batch.deadline,
                witness
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", permit3.DOMAIN_SEPARATOR(), hashStruct));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
