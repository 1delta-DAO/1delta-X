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

/// @dev CROSS-FUNCTION reentrancy probe. `Permit3.take` locks itself and
///      `permitTake` and NOTHING ELSE — deliberately: a module funds its own leg
///      with `permit3.transferFrom` from inside `takeOnBehalf`, which every shipped
///      pull-funded module does ({ERC20PermitTransferModule}, the Dolomite fused
///      module, the River modules). So the guard is not what keeps a hostile module
///      contained. THIS is:
///
///        every mutating Permit3 entry is keyed by `msg.sender`, either as the
///        OWNER whose books are written (`approveTaker`, `revokeToken`,
///        `lockdown*`, `setStrictMode`, `invalidateUnorderedNonces`) or as the
///        SPENDER whose bucket is spent (`transferFrom`, `take`, and the signed
///        paths, where the signed spender IS `msg.sender`).
///
///      A re-entering module therefore wields exactly the authority it has when
///      called cold, never the victim's. This module walks into each open door
///      while dispatched so the tests below can pin that, one entry point at a
///      time — the classic `take → take` case ({ReentrantTakerModule}) proves only
///      the guard, which is the smaller half of the story.
contract CrossFunctionReentrantModule is ITakerModule {
    enum Attack {
        None,
        Take, // the classic — locked
        PermitTake, // cross-function with `take`: same `_locked`
        TransferFrom, // open by design — spends the MODULE's own token bucket
        ApproveTaker, // writes the MODULE's own taker book
        RevokeTaker,
        LockdownTakers,
        LockdownTokens,
        InvalidateNonces,
        SetStrictMode,
        PermitBatchForged // no signature ⇒ no grant, however it is dispatched

    }

    Permit3 public immutable permit3;

    Attack public attack;
    address public victim;
    address public victimSpender;
    address public victimToken;
    bytes32 public victimRef;
    uint160 public pullAmount;
    /// @dev Set only if the re-entrant call RETURNED. A test that expects the outer
    ///      `take` to survive asserts on this; one that expects a revert cannot.
    bool public reentered;

    constructor(address _permit3) {
        permit3 = Permit3(_permit3);
    }

    function arm(Attack a, address _victim, address _spender, address _token, bytes32 _ref, uint160 _pull) external {
        attack = a;
        victim = _victim;
        victimSpender = _spender;
        victimToken = _token;
        victimRef = _ref;
        pullAmount = _pull;
    }

    function takeOnBehalf(address onBehalfOf, uint256 amount, address receiver, bytes calldata data)
        external
        override
    {
        require(msg.sender == address(permit3), "only permit3");
        Attack a = attack;

        if (a == Attack.Take) {
            permit3.take(address(this), onBehalfOf, uint160(amount), receiver, data);
        } else if (a == Attack.PermitTake) {
            // The guard is on the modifier, so it fires before the (unsigned) body.
            IPermit3.PermitTake memory p = IPermit3.PermitTake({
                module: address(this),
                ref: keccak256(data),
                amount: uint160(amount),
                nonce: 0,
                deadline: type(uint256).max
            });
            permit3.permitTake(p, onBehalfOf, receiver, data, hex"");
        } else if (a == Attack.TransferFrom) {
            // Reaches for the VICTIM's tokens. `msg.sender` here is this module, so
            // the bucket consulted is `[victim][module][token]` — never the one the
            // victim granted `victimSpender`.
            permit3.transferFrom(victim, address(this), victimToken, pullAmount);
        } else if (a == Attack.ApproveTaker) {
            // Owner is `msg.sender` = this module, so this grants against the
            // MODULE's own (empty) position, not the victim's.
            permit3.approveTaker(address(this), address(this), victimRef, type(uint160).max, 0);
        } else if (a == Attack.RevokeTaker) {
            permit3.revokeTaker(victimSpender, address(this), victimRef);
        } else if (a == Attack.LockdownTakers) {
            IPermit3.SpenderRefPair[] memory pairs = new IPermit3.SpenderRefPair[](1);
            pairs[0] = IPermit3.SpenderRefPair({spender: victimSpender, module: address(this), ref: victimRef});
            permit3.lockdownTakers(pairs);
        } else if (a == Attack.LockdownTokens) {
            IPermit3.TokenSpenderPair[] memory pairs = new IPermit3.TokenSpenderPair[](1);
            pairs[0] = IPermit3.TokenSpenderPair({token: victimToken, spender: victimSpender});
            permit3.lockdown(pairs);
        } else if (a == Attack.InvalidateNonces) {
            permit3.invalidateUnorderedNonces(0, type(uint256).max);
        } else if (a == Attack.SetStrictMode) {
            permit3.setStrictMode(true);
        } else if (a == Attack.PermitBatchForged) {
            IPermit3.PermitBatch memory batch;
            batch.tokens = new IPermit3.TokenPermit[](1);
            batch.tokens[0] = IPermit3.TokenPermit({
                spender: address(this),
                token: victimToken,
                amount: type(uint160).max,
                expiration: 0
            });
            batch.takers = new IPermit3.TakerPermit[](0);
            batch.nonce = 999;
            batch.deadline = type(uint256).max;
            // 65 well-formed bytes that recover to somebody else entirely.
            permit3.permitBatch(victim, batch, abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)), uint8(27)));
        }
        reentered = true;
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
        keccak256("TakerPermit(address spender,address module,bytes32 ref,uint160 amount,uint48 expiration)");
    bytes32 constant PERMIT_BATCH_TH = keccak256(
        "PermitBatch(TokenPermit[] tokens,TakerPermit[] takers,uint256 nonce,uint256 deadline)"
        "TakerPermit(address spender,address module,bytes32 ref,uint160 amount,uint48 expiration)"
        "TokenPermit(address spender,address token,uint160 amount,uint48 expiration)"
    );
    string constant WITNESS_STUB =
        "PermitBatchWitness(TokenPermit[] tokens,TakerPermit[] takers,uint256 nonce,uint256 deadline,";
    // Witness is a bare bytes32; type defs in alphabetical order after the field.
    string constant WITNESS_TYPE_STRING = "bytes32 witness)"
        "TakerPermit(address spender,address module,bytes32 ref,uint160 amount,uint48 expiration)"
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
        (uint160 amount,) = permit3.tokenAllowance(owner, spender, address(token));
        assertEq(amount, 60e18, "allowance decremented");
    }

    function test_transferFrom_infinite_notDecremented() public {
        vm.prank(owner);
        permit3.approveToken(spender, address(token), type(uint160).max, 0);

        vm.prank(spender);
        permit3.transferFrom(owner, recipient, address(token), 123e18);

        (uint160 amount,) = permit3.tokenAllowance(owner, spender, address(token));
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
        (uint160 amount,) = permit3.tokenAllowance(owner, spender, address(token));
        assertEq(amount, 50e18, "both legs decremented");
    }

    function test_revokeToken() public {
        vm.startPrank(owner);
        permit3.approveToken(spender, address(token), 100e18, 0);
        permit3.revokeToken(spender, address(token));
        vm.stopPrank();

        (uint160 amount,) = permit3.tokenAllowance(owner, spender, address(token));
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

        (uint160 a1,) = permit3.tokenAllowance(owner, spender, address(token));
        (uint160 a2,) = permit3.tokenAllowance(owner, spender2, address(token));
        assertEq(a1, 0);
        assertEq(a2, 0);
    }

    function test_lockdownTakers_zeroesTakerAllowances() public {
        bytes32 ref = keccak256("pos");
        // Taker book is keyed by SPENDER (the caller of `take`); this test's
        // `take` would be called by address(this), so approve that spender.
        address sp = address(this);
        address module = address(taker);
        vm.prank(owner);
        permit3.approveTaker(sp, module, ref, 100e18, 0);

        IPermit3.SpenderRefPair[] memory pairs = new IPermit3.SpenderRefPair[](1);
        pairs[0] = IPermit3.SpenderRefPair(sp, module, ref);
        vm.prank(owner);
        permit3.lockdownTakers(pairs);

        (uint160 amount,) = permit3.takerAllowance(owner, sp, module, ref);
        assertEq(amount, 0);
    }

    // ════════════════ Taker book ════════════════

    function test_approveTaker_and_take() public {
        bytes memory data = abi.encode(address(0x1111), uint256(2));
        bytes32 ref = keccak256(data);

        // Spender = address(this) since this test calls `take` directly.
        vm.prank(owner);
        permit3.approveTaker(address(this), address(taker), ref, 100e18, 0);

        permit3.take(address(taker), owner, 40e18, recipient, data);

        assertEq(taker.lastUser(), owner);
        assertEq(taker.lastAmount(), 40e18);
        assertEq(taker.lastReceiver(), recipient);
        (uint160 amount,) = permit3.takerAllowance(owner, address(this), address(taker), ref);
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
        permit3.approveTaker(goodSpender, address(taker), ref, 100e18, 0);

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
        permit3.approveTaker(address(this), address(taker), ref, 5e18, 0);

        vm.expectRevert(abi.encodeWithSelector(IPermit3.InsufficientAllowance.selector, uint160(5e18)));
        permit3.take(address(taker), owner, 6e18, recipient, data);
    }

    /// @notice A zero-amount `take` is rejected before dispatch. `_spend(bucket, 0)`
    ///         does NOT revert even against an empty allowance, so without the guard
    ///         an unauthorised caller (no taker allowance under their key) could
    ///         reach `module.takeOnBehalf(victim, 0, attacker, data)`. The guard
    ///         closes that path for every present and future module.
    function test_take_revert_zeroAmount_unauthorized() public {
        bytes memory data = abi.encode(uint256(1));
        // Attacker holds NO allowance for `owner` under their own key, yet a
        // zero-amount spend would otherwise pass — the guard must still reject it.
        address attacker = address(0xBAD);
        vm.prank(attacker);
        vm.expectRevert(IPermit3.ZeroAmount.selector);
        permit3.take(address(taker), owner, 0, attacker, data);

        // The module was never invoked.
        assertEq(taker.lastUser(), address(0), "module not dispatched on zero-amount take");
    }

    function test_take_nonReentrant() public {
        ReentrantTakerModule evil = new ReentrantTakerModule(address(permit3));
        bytes memory data = abi.encode(uint256(7));
        bytes32 ref = keccak256(data);
        // Outer `take` is called by address(this); its allowance must pass so the
        // re-entrant inner call is what trips the guard.
        vm.prank(owner);
        permit3.approveTaker(address(this), address(evil), ref, type(uint160).max, 0);

        vm.expectRevert(IPermit3.Reentrancy.selector);
        permit3.take(address(evil), owner, 1e18, recipient, data);
    }

    // ════════════════ Signed permits (EOA) ════════════════

    function test_permitBatch_setsAllowances() public {
        IPermit3.PermitBatch memory batch = _batchSingleToken(spender, address(token), 500e18, 0, 0);
        bytes memory sig = _signBatch(batch, ownerPk);

        permit3.permitBatch(owner, batch, sig);

        (uint160 amount,) = permit3.tokenAllowance(owner, spender, address(token));
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
        (uint160 amount,) = permit3.tokenAllowance(owner, spender, address(token));
        assertEq(amount, 7e18);
    }

    // ════════════════ Signed permits (EIP-1271) ════════════════

    function test_permitBatch_eip1271_contractSigner() public {
        MockERC1271Wallet wallet = new MockERC1271Wallet(owner);
        IPermit3.PermitBatch memory batch = _batchSingleToken(spender, address(token), 9e18, 0, 0);
        bytes memory sig = _signBatch(batch, ownerPk); // signed by wallet's controlling key

        permit3.permitBatch(address(wallet), batch, sig);

        (uint160 amount,) = permit3.tokenAllowance(address(wallet), spender, address(token));
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

        (uint160 amount,) = permit3.tokenAllowance(owner, spender, address(token));
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

        (uint160 amount,) = permit3.tokenAllowance(spender, recipient, address(token));
        assertEq(amount, 5e18, "7702 delegated-1271 permit applied");
    }

    // ════════════════ Witness binding ════════════════

    function test_permitBatchWithWitness_setsAllowances() public {
        bytes32 witness = keccak256("order-hash");
        IPermit3.PermitBatch memory batch = _batchSingleToken(spender, address(token), 3e18, 0, 0);
        bytes memory sig = _signBatchWitness(batch, witness, ownerPk);

        permit3.permitBatchWithWitness(owner, batch, witness, WITNESS_TYPE_STRING, sig);

        (uint160 amount,) = permit3.tokenAllowance(owner, spender, address(token));
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
            tokens: tp, takers: new IPermit3.TakerPermit[](0), nonce: nonce, deadline: block.timestamp + 1 hours
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
            h[i] = keccak256(
                abi.encode(TAKER_PERMIT_TH, p[i].spender, p[i].module, p[i].ref, p[i].amount, p[i].expiration)
            );
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

    // ════════════════ One-shot signed take (permitTake) ════════════════

    bytes32 constant PERMIT_TAKE_TH =
        keccak256("PermitTake(address module,bytes32 ref,uint160 amount,address spender,uint256 nonce,uint256 deadline)");

    function _signPermitTake(IPermit3.PermitTake memory permit, address spender, uint256 pk)
        internal
        view
        returns (bytes memory)
    {
        bytes32 hashStruct = keccak256(
            abi.encode(PERMIT_TAKE_TH, permit.module, permit.ref, permit.amount, spender, permit.nonce, permit.deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", permit3.DOMAIN_SEPARATOR(), hashStruct));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _permitTakeFor(bytes memory data, uint160 amount, uint256 nonce)
        internal
        view
        returns (IPermit3.PermitTake memory p)
    {
        p = IPermit3.PermitTake({
            module: address(taker),
            ref: keccak256(data),
            amount: amount,
            nonce: nonce,
            deadline: block.timestamp + 1 hours
        });
    }

    function test_permitTake_dispatchesWithoutStandingAllowance() public {
        bytes memory data = abi.encode(uint256(9));
        IPermit3.PermitTake memory permit = _permitTakeFor(data, 40e18, 3);
        bytes memory sig = _signPermitTake(permit, address(this), ownerPk);

        // No approveTaker anywhere — the signature alone authorises the dispatch.
        permit3.permitTake(permit, owner, recipient, data, sig);

        assertEq(taker.lastUser(), owner, "module dispatched");
        assertEq(taker.lastAmount(), 40e18);
        assertEq(taker.lastReceiver(), recipient);
        // Nothing left behind: no allowance bucket was written.
        (uint160 left,) = permit3.takerAllowance(owner, address(this), address(taker), keccak256(data));
        assertEq(left, 0, "no standing allowance created");
        assertTrue(permit3.isPermitNonceUsed(owner, 3), "nonce consumed");
    }

    function test_permitTake_revert_refMismatch() public {
        bytes memory data = abi.encode(uint256(9));
        IPermit3.PermitTake memory permit = _permitTakeFor(data, 40e18, 3);
        bytes memory sig = _signPermitTake(permit, address(this), ownerPk);

        // Present DIFFERENT data than the signed ref.
        vm.expectRevert(IPermit3.RefMismatch.selector);
        permit3.permitTake(permit, owner, recipient, abi.encode(uint256(10)), sig);
    }

    function test_permitTake_revert_zeroAmount() public {
        bytes memory data = abi.encode(uint256(9));
        IPermit3.PermitTake memory permit = _permitTakeFor(data, 0, 3);
        bytes memory sig = _signPermitTake(permit, address(this), ownerPk);

        vm.expectRevert(IPermit3.ZeroAmount.selector);
        permit3.permitTake(permit, owner, recipient, data, sig);
    }

    function test_permitTake_revert_replay() public {
        bytes memory data = abi.encode(uint256(9));
        IPermit3.PermitTake memory permit = _permitTakeFor(data, 40e18, 3);
        bytes memory sig = _signPermitTake(permit, address(this), ownerPk);

        permit3.permitTake(permit, owner, recipient, data, sig);
        vm.expectRevert(IPermit3.PermitNonceUsed.selector);
        permit3.permitTake(permit, owner, recipient, data, sig);
    }

    function test_permitTake_revert_leakedSigUselessToOtherSpender() public {
        bytes memory data = abi.encode(uint256(9));
        IPermit3.PermitTake memory permit = _permitTakeFor(data, 40e18, 3);
        // Signed for spender == address(this); a different caller cannot use it.
        bytes memory sig = _signPermitTake(permit, address(this), ownerPk);

        vm.prank(address(0xBEEF));
        vm.expectRevert(); // digest binds spender = original caller, so verify fails
        permit3.permitTake(permit, owner, recipient, data, sig);
    }

    // ════════════════ Combined revocation (lockdownAll) ════════════════

    function test_lockdownAll_revokesBothBooksAndNonces() public {
        bytes32 ref = keccak256("pos");
        vm.startPrank(owner);
        permit3.approveToken(spender, address(token), 100e18, 0);
        permit3.approveTaker(spender, address(taker), ref, 100e18, 0);

        IPermit3.TokenSpenderPair[] memory tokens = new IPermit3.TokenSpenderPair[](1);
        tokens[0] = IPermit3.TokenSpenderPair(address(token), spender);
        IPermit3.SpenderRefPair[] memory takers = new IPermit3.SpenderRefPair[](1);
        takers[0] = IPermit3.SpenderRefPair(spender, address(taker), ref);
        uint256[] memory words = new uint256[](1);
        uint256[] memory masks = new uint256[](1);
        words[0] = 0;
        masks[0] = (1 << 5) | (1 << 9);
        permit3.lockdownAll(tokens, takers, words, masks);
        vm.stopPrank();

        (uint160 tAmt,) = permit3.tokenAllowance(owner, spender, address(token));
        (uint160 kAmt,) = permit3.takerAllowance(owner, spender, address(taker), ref);
        assertEq(tAmt, 0, "token allowance zeroed");
        assertEq(kAmt, 0, "taker allowance zeroed");
        assertTrue(permit3.isPermitNonceUsed(owner, 5), "nonce 5 invalidated");
        assertTrue(permit3.isPermitNonceUsed(owner, 9), "nonce 9 invalidated");
    }

    function test_lockdownAll_revert_nonceArrayLengthMismatch() public {
        IPermit3.TokenSpenderPair[] memory tokens = new IPermit3.TokenSpenderPair[](0);
        IPermit3.SpenderRefPair[] memory takers = new IPermit3.SpenderRefPair[](0);
        uint256[] memory words = new uint256[](1);
        uint256[] memory masks = new uint256[](2);
        vm.prank(owner);
        vm.expectRevert(IPermit3.NonceArrayLengthMismatch.selector);
        permit3.lockdownAll(tokens, takers, words, masks);
    }

    // ════════════════ ERC-5267 ════════════════

    function test_eip712Domain_matchesSeparator() public view {
        (bytes1 fields, string memory name, string memory version, uint256 chainId, address vc, bytes32 salt,) =
            permit3.eip712Domain();
        assertEq(fields, hex"0f");
        assertEq(name, "Permit3");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(vc, address(permit3));
        assertEq(salt, bytes32(0));
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                vc
            )
        );
        assertEq(expected, permit3.DOMAIN_SEPARATOR(), "5267 fields rebuild the separator");
    }

    // ════════════════ Idempotent signed batch (S-1) ════════════════

    function test_permitBatchWithWitnessIfNeeded_skipsSpentNonce() public {
        IPermit3.PermitBatch memory batch = _batchSingleToken(spender, address(token), 500e18, 0, 4);
        bytes32 witness = keccak256("order");
        bytes memory sig = _signBatchWitness(batch, witness, ownerPk);

        // First application grants the allowance and spends the nonce.
        permit3.permitBatchWithWitnessIfNeeded(owner, batch, witness, WITNESS_TYPE_STRING, sig);
        (uint160 a1,) = permit3.tokenAllowance(owner, spender, address(token));
        assertEq(a1, 500e18);

        // Draw the allowance down, then re-present the SAME batch: the spent nonce is
        // skipped (no revert), and crucially the grant is NOT re-applied.
        vm.prank(spender);
        permit3.transferFrom(owner, recipient, address(token), 200e18);
        permit3.permitBatchWithWitnessIfNeeded(owner, batch, witness, WITNESS_TYPE_STRING, sig);
        (uint160 a2,) = permit3.tokenAllowance(owner, spender, address(token));
        assertEq(a2, 300e18, "grant not re-applied on the idempotent re-call");
    }

    function test_permitBatchWithWitnessIfNeeded_revert_badSig() public {
        IPermit3.PermitBatch memory batch = _batchSingleToken(spender, address(token), 500e18, 0, 4);
        bytes32 witness = keccak256("order");
        // Sign with the wrong key — the signature is verified UNCONDITIONALLY.
        bytes memory sig = _signBatchWitness(batch, witness, 0xB0B);
        vm.expectRevert();
        permit3.permitBatchWithWitnessIfNeeded(owner, batch, witness, WITNESS_TYPE_STRING, sig);
    }

    // ════════════════ Cross-function reentrancy (the OTHER doors) ════════════════
    //
    // `test_take_nonReentrant` above proves the guard. It does not prove the thing
    // the guard is NOT: `take` locks only itself and `permitTake`, and every other
    // Permit3 entry stays open to a dispatched module ON PURPOSE — that is how a
    // pull-funded module funds its own leg mid-op. What actually contains a hostile
    // module is that EVERY mutating entry is keyed by `msg.sender`, so the module
    // re-enters with its own authority and nobody else's. One test per door.
    //
    // See {CrossFunctionReentrantModule}.

    address constant GOOD_SPENDER = address(0x5E771E); // stand-in for Settlement

    /// @dev A module the victim has authorised for 100e18 through `GOOD_SPENDER`,
    ///      plus a 500e18 token grant to `GOOD_SPENDER` for the module to reach for.
    function _armEvil() internal returns (CrossFunctionReentrantModule evil, bytes memory data, bytes32 ref) {
        evil = new CrossFunctionReentrantModule(address(permit3));
        data = abi.encode(uint256(7));
        ref = keccak256(data);
        vm.prank(owner);
        permit3.approveTaker(GOOD_SPENDER, address(evil), ref, 100e18, 0);
        vm.prank(owner);
        permit3.approveToken(GOOD_SPENDER, address(token), 500e18, 0);
    }

    /// @notice `permitTake` shares `take`'s `_locked`, so the one-shot signed path is
    ///         not a way around the guard. Untested until now — the classic case only
    ///         covers `take → take`.
    function test_reentrancy_permitTake_isLockedBy_take() public {
        (CrossFunctionReentrantModule evil, bytes memory data, bytes32 ref) = _armEvil();
        evil.arm(CrossFunctionReentrantModule.Attack.PermitTake, owner, GOOD_SPENDER, address(token), ref, 0);

        vm.prank(GOOD_SPENDER);
        vm.expectRevert(IPermit3.Reentrancy.selector);
        permit3.take(address(evil), owner, 40e18, recipient, data);
    }

    /// @notice And the other direction: a module dispatched by `permitTake` cannot
    ///         re-enter `take`. Same `_locked`, so the lock is genuinely cross-function
    ///         rather than per-entry.
    function test_reentrancy_take_isLockedBy_permitTake() public {
        (CrossFunctionReentrantModule evil, bytes memory data, bytes32 ref) = _armEvil();
        evil.arm(CrossFunctionReentrantModule.Attack.Take, owner, GOOD_SPENDER, address(token), ref, 0);

        IPermit3.PermitTake memory permit = IPermit3.PermitTake({
            module: address(evil),
            ref: ref,
            amount: 40e18,
            nonce: 11,
            deadline: block.timestamp + 1 hours
        });
        // The signed spender is always `msg.sender` — here, the test contract.
        bytes memory sig = _signPermitTake(permit, address(this), ownerPk);

        vm.expectRevert(IPermit3.Reentrancy.selector);
        permit3.permitTake(permit, owner, recipient, data, sig);
    }

    /// @notice THE LOAD-BEARING ONE. `transferFrom` is deliberately unguarded, so a
    ///         dispatched module can call it — but the bucket it reaches is
    ///         `[victim][MODULE][token]`, never the one the victim granted the
    ///         spender. A module with no grant of its own gets nothing, and the
    ///         failure unwinds the whole take.
    function test_reentrancy_transferFrom_cannotReachTheSpendersBucket() public {
        (CrossFunctionReentrantModule evil, bytes memory data, bytes32 ref) = _armEvil();
        evil.arm(CrossFunctionReentrantModule.Attack.TransferFrom, owner, GOOD_SPENDER, address(token), ref, 30e18);

        vm.prank(GOOD_SPENDER);
        vm.expectRevert(abi.encodeWithSelector(IPermit3.InsufficientAllowance.selector, uint160(0)));
        permit3.take(address(evil), owner, 40e18, recipient, data);

        (uint160 spenderBucket,) = permit3.tokenAllowance(owner, GOOD_SPENDER, address(token));
        assertEq(spenderBucket, 500e18, "the spender's grant was never in reach");
        assertEq(token.balanceOf(address(evil)), 0, "nothing moved");
    }

    /// @notice The same call with a grant the module DOES hold — the shipped channel
    ///         ({ERC20PermitTransferModule}, the Dolomite/River fused modules).
    ///
    ///         ⚠ AND THE PROPERTY IT PINS: the pull is NOT bounded by the `take`
    ///         amount. Here a 40e18 take pulls 200e18, because the binding cap for a
    ///         pull-funded module is the TOKEN-BOOK grant the user made to that
    ///         module, not the taker allowance the fill consumes. The taker gate
    ///         sizes the protocol-native op; it says nothing about what the module
    ///         moves alongside it. What actually pins the side leg is `ref =
    ///         keccak256(data)` (the amount is inside the maker-signed bytes) plus
    ///         the module's own full-fill guard — i.e. module code, per the trust
    ///         model in {ITakerModule}. Asserted rather than assumed, because a
    ///         reader who takes "amount-gated" at face value would get this wrong.
    function test_reentrancy_transferFrom_ownBucket_isNotBoundedByTheTakeAmount() public {
        (CrossFunctionReentrantModule evil, bytes memory data, bytes32 ref) = _armEvil();
        vm.prank(owner);
        permit3.approveToken(address(evil), address(token), 500e18, 0);
        evil.arm(CrossFunctionReentrantModule.Attack.TransferFrom, owner, GOOD_SPENDER, address(token), ref, 200e18);

        vm.prank(GOOD_SPENDER);
        permit3.take(address(evil), owner, 40e18, recipient, data);

        assertTrue(evil.reentered(), "the re-entrant transferFrom returned");
        assertEq(token.balanceOf(address(evil)), 200e18, "pull exceeds the 40e18 take amount");

        (uint160 moduleBucket,) = permit3.tokenAllowance(owner, address(evil), address(token));
        assertEq(moduleBucket, 300e18, "spent its OWN bucket");
        (uint160 spenderBucket,) = permit3.tokenAllowance(owner, GOOD_SPENDER, address(token));
        assertEq(spenderBucket, 500e18, "the spender's bucket is untouched");
        (uint160 takerLeft,) = permit3.takerAllowance(owner, GOOD_SPENDER, address(evil), ref);
        assertEq(takerLeft, 60e18, "taker book decremented by exactly the take");
    }

    /// @notice `approveTaker` re-entered mid-dispatch grants against the MODULE's own
    ///         position (owner is `msg.sender`), which is worth nothing. The victim's
    ///         bucket moves only by the take that is legitimately in flight.
    function test_reentrancy_approveTaker_writesOnlyItsOwnBook() public {
        (CrossFunctionReentrantModule evil, bytes memory data, bytes32 ref) = _armEvil();
        evil.arm(CrossFunctionReentrantModule.Attack.ApproveTaker, owner, GOOD_SPENDER, address(token), ref, 0);

        vm.prank(GOOD_SPENDER);
        permit3.take(address(evil), owner, 40e18, recipient, data);

        (uint160 victimLeft,) = permit3.takerAllowance(owner, GOOD_SPENDER, address(evil), ref);
        assertEq(victimLeft, 60e18, "only the in-flight take moved the victim's bucket");
        (uint160 selfGrant,) = permit3.takerAllowance(address(evil), address(evil), address(evil), ref);
        assertEq(selfGrant, type(uint160).max, "the grant landed under the module's own key");
    }

    /// @notice Revocation is owner-keyed too, so a module cannot revoke a grant it is
    ///         being dispatched under (nor any other user's).
    function test_reentrancy_revokeTaker_cannotTouchTheVictimsGrant() public {
        (CrossFunctionReentrantModule evil, bytes memory data, bytes32 ref) = _armEvil();
        evil.arm(CrossFunctionReentrantModule.Attack.RevokeTaker, owner, GOOD_SPENDER, address(token), ref, 0);

        vm.prank(GOOD_SPENDER);
        permit3.take(address(evil), owner, 40e18, recipient, data);

        assertTrue(evil.reentered());
        (uint160 victimLeft,) = permit3.takerAllowance(owner, GOOD_SPENDER, address(evil), ref);
        assertEq(victimLeft, 60e18, "victim's taker grant survives");
    }

    function test_reentrancy_lockdownTakers_cannotTouchTheVictimsGrant() public {
        (CrossFunctionReentrantModule evil, bytes memory data, bytes32 ref) = _armEvil();
        evil.arm(CrossFunctionReentrantModule.Attack.LockdownTakers, owner, GOOD_SPENDER, address(token), ref, 0);

        vm.prank(GOOD_SPENDER);
        permit3.take(address(evil), owner, 40e18, recipient, data);

        assertTrue(evil.reentered());
        (uint160 victimLeft,) = permit3.takerAllowance(owner, GOOD_SPENDER, address(evil), ref);
        assertEq(victimLeft, 60e18, "victim's taker grant survives");
    }

    function test_reentrancy_lockdownTokens_cannotTouchTheVictimsGrant() public {
        (CrossFunctionReentrantModule evil, bytes memory data, bytes32 ref) = _armEvil();
        evil.arm(CrossFunctionReentrantModule.Attack.LockdownTokens, owner, GOOD_SPENDER, address(token), ref, 0);

        vm.prank(GOOD_SPENDER);
        permit3.take(address(evil), owner, 40e18, recipient, data);

        assertTrue(evil.reentered());
        (uint160 spenderBucket,) = permit3.tokenAllowance(owner, GOOD_SPENDER, address(token));
        assertEq(spenderBucket, 500e18, "victim's token grant survives");
    }

    /// @notice Nonce invalidation is `msg.sender`-keyed, so a module cannot burn a
    ///         maker's permit nonce mid-fill (which would otherwise be a clean way to
    ///         brick a gasless order — see {SignedPermits.permitBatchWithWitnessIfNeeded}).
    function test_reentrancy_invalidateNonces_cannotBurnTheVictimsNonce() public {
        (CrossFunctionReentrantModule evil, bytes memory data, bytes32 ref) = _armEvil();
        evil.arm(CrossFunctionReentrantModule.Attack.InvalidateNonces, owner, GOOD_SPENDER, address(token), ref, 0);

        vm.prank(GOOD_SPENDER);
        permit3.take(address(evil), owner, 40e18, recipient, data);

        assertTrue(evil.reentered());
        assertFalse(permit3.isPermitNonceUsed(owner, 0), "victim's nonce untouched");
        assertTrue(permit3.isPermitNonceUsed(address(evil), 0), "the module burned its OWN");
    }

    /// @notice Same for strict mode — a module cannot flip a payer into (or out of)
    ///         the {Permit3TransferLib} fallback refusal.
    function test_reentrancy_setStrictMode_onlyItsOwn() public {
        (CrossFunctionReentrantModule evil, bytes memory data, bytes32 ref) = _armEvil();
        evil.arm(CrossFunctionReentrantModule.Attack.SetStrictMode, owner, GOOD_SPENDER, address(token), ref, 0);

        vm.prank(GOOD_SPENDER);
        permit3.take(address(evil), owner, 40e18, recipient, data);

        assertTrue(evil.reentered());
        assertFalse(permit3.strictMode(owner), "victim's flag untouched");
        assertTrue(permit3.strictMode(address(evil)), "the module set its OWN");
    }

    /// @notice The signed-grant path needs a signature the module cannot produce, so
    ///         re-entering it forges nothing and takes the whole fill down with it.
    function test_reentrancy_permitBatch_cannotForgeAGrant() public {
        (CrossFunctionReentrantModule evil, bytes memory data, bytes32 ref) = _armEvil();
        evil.arm(CrossFunctionReentrantModule.Attack.PermitBatchForged, owner, GOOD_SPENDER, address(token), ref, 0);

        vm.prank(GOOD_SPENDER);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        permit3.take(address(evil), owner, 40e18, recipient, data);

        (uint160 moduleBucket,) = permit3.tokenAllowance(owner, address(evil), address(token));
        assertEq(moduleBucket, 0, "no grant was forged");
    }
}
