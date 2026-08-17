// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {Permit3} from "../../src/permit3/Permit3.sol";
import {IPermit3} from "../../src/interfaces/IPermit3.sol";
import {ISignatureTransfer} from "../../src/interfaces/ISignatureTransfer.sol";
import {SignatureVerification} from "../../src/permit3/SignatureVerification.sol";

/// @dev Minimal ERC20 — just enough for the transfer path.
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

/// @title SignatureTransferTest
/// @notice One-shot signed transfers: a signature moves tokens once and leaves no
///         allowance behind. The properties that matter are that the spender is
///         pinned to `msg.sender`, that the cap is a ceiling and not an amount,
///         and that the nonce is shared with the allowance-permit flow.
contract SignatureTransferTest is Test {
    Permit3 permit3;
    MockERC20 token;

    uint256 ownerPk = 0xA11CE;
    address owner = vm.addr(0xA11CE);
    address spender = address(0xBEEF);
    address recipient = address(0xCAFE);

    // Mirror Permit3Hash's constants for signing in-test.
    bytes32 constant TOKEN_PERMISSIONS_TH = keccak256("TokenPermissions(address token,uint256 amount)");
    bytes32 constant PERMIT_TRANSFER_FROM_TH = keccak256(
        "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)"
        "TokenPermissions(address token,uint256 amount)"
    );
    bytes32 constant PERMIT_BATCH_TRANSFER_FROM_TH = keccak256(
        "PermitBatchTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline)"
        "TokenPermissions(address token,uint256 amount)"
    );
    string constant WITNESS_STUB =
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";
    string constant WITNESS_TYPE_STRING = "bytes32 witness)TokenPermissions(address token,uint256 amount)";

    function setUp() public {
        permit3 = new Permit3();
        token = new MockERC20();

        token.mint(owner, 1_000_000e18);
        vm.prank(owner);
        token.approve(address(permit3), type(uint256).max);
    }

    // ──────────────────── Helpers ────────────────────

    function _permit(uint256 amount, uint256 nonce)
        internal
        view
        returns (ISignatureTransfer.PermitTransferFrom memory)
    {
        return ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(token), amount: amount}),
            nonce: nonce,
            deadline: block.timestamp + 1 hours
        });
    }

    function _hashPermitted(ISignatureTransfer.TokenPermissions memory p) internal pure returns (bytes32) {
        return keccak256(abi.encode(TOKEN_PERMISSIONS_TH, p.token, p.amount));
    }

    function _sign(bytes32 hashStruct) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", permit3.DOMAIN_SEPARATOR(), hashStruct));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signSingle(ISignatureTransfer.PermitTransferFrom memory permit, address theSpender)
        internal
        view
        returns (bytes memory)
    {
        return _sign(
            keccak256(
                abi.encode(
                    PERMIT_TRANSFER_FROM_TH, _hashPermitted(permit.permitted), theSpender, permit.nonce, permit.deadline
                )
            )
        );
    }

    function _signSingleWitness(
        ISignatureTransfer.PermitTransferFrom memory permit,
        address theSpender,
        bytes32 witness
    ) internal view returns (bytes memory) {
        bytes32 typeHash = keccak256(abi.encodePacked(WITNESS_STUB, WITNESS_TYPE_STRING));
        return _sign(
            keccak256(
                abi.encode(
                    typeHash, _hashPermitted(permit.permitted), theSpender, permit.nonce, permit.deadline, witness
                )
            )
        );
    }

    function _details(address to, uint256 amount)
        internal
        pure
        returns (ISignatureTransfer.SignatureTransferDetails memory)
    {
        return ISignatureTransfer.SignatureTransferDetails({to: to, requestedAmount: amount});
    }

    // ════════════════ Single ════════════════

    function test_permitTransferFrom_movesTokens_andLeavesNoAllowance() public {
        ISignatureTransfer.PermitTransferFrom memory permit = _permit(100e18, 1);
        bytes memory sig = _signSingle(permit, spender);

        vm.prank(spender);
        permit3.permitTransferFrom(permit, _details(recipient, 100e18), owner, sig);

        assertEq(token.balanceOf(recipient), 100e18, "tokens delivered");
        (uint160 amount,) = permit3.tokenAllowance(owner, spender, address(token));
        assertEq(amount, 0, "no standing allowance created");
        assertTrue(permit3.isPermitNonceUsed(owner, 1), "nonce spent");
    }

    /// @dev The cap is a ceiling, not an amount — a spender may draw less.
    function test_permitTransferFrom_partialDraw() public {
        ISignatureTransfer.PermitTransferFrom memory permit = _permit(100e18, 1);
        bytes memory sig = _signSingle(permit, spender);

        vm.prank(spender);
        permit3.permitTransferFrom(permit, _details(recipient, 30e18), owner, sig);

        assertEq(token.balanceOf(recipient), 30e18);
        // The unused 70e18 is NOT claimable later: the nonce is spent.
        vm.prank(spender);
        vm.expectRevert(IPermit3.PermitNonceUsed.selector);
        permit3.permitTransferFrom(permit, _details(recipient, 70e18), owner, sig);
    }

    function test_permitTransferFrom_revert_overCap() public {
        ISignatureTransfer.PermitTransferFrom memory permit = _permit(100e18, 1);
        bytes memory sig = _signSingle(permit, spender);

        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(ISignatureTransfer.InvalidAmount.selector, 100e18));
        permit3.permitTransferFrom(permit, _details(recipient, 100e18 + 1), owner, sig);
    }

    /// @dev THE property of a signature transfer: the signed spender is
    ///      `msg.sender`, so a leaked signature is useless to anyone else.
    function test_permitTransferFrom_revert_wrongSpender() public {
        ISignatureTransfer.PermitTransferFrom memory permit = _permit(100e18, 1);
        bytes memory sig = _signSingle(permit, spender);

        vm.prank(address(0xBAD));
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        permit3.permitTransferFrom(permit, _details(address(0xBAD), 100e18), owner, sig);

        assertEq(token.balanceOf(address(0xBAD)), 0);
    }

    function test_permitTransferFrom_revert_replay() public {
        ISignatureTransfer.PermitTransferFrom memory permit = _permit(100e18, 7);
        bytes memory sig = _signSingle(permit, spender);

        vm.startPrank(spender);
        permit3.permitTransferFrom(permit, _details(recipient, 40e18), owner, sig);
        vm.expectRevert(IPermit3.PermitNonceUsed.selector);
        permit3.permitTransferFrom(permit, _details(recipient, 40e18), owner, sig);
        vm.stopPrank();
    }

    function test_permitTransferFrom_revert_expired() public {
        ISignatureTransfer.PermitTransferFrom memory permit = _permit(100e18, 1);
        bytes memory sig = _signSingle(permit, spender);

        uint256 deadline = permit.deadline;
        vm.warp(deadline + 1);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(ISignatureTransfer.SignatureExpired.selector, deadline));
        permit3.permitTransferFrom(permit, _details(recipient, 1e18), owner, sig);
    }

    function test_permitTransferFrom_revert_wrongSigner() public {
        ISignatureTransfer.PermitTransferFrom memory permit = _permit(100e18, 1);
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                permit3.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        PERMIT_TRANSFER_FROM_TH,
                        _hashPermitted(permit.permitted),
                        spender,
                        permit.nonce,
                        permit.deadline
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xB0B, digest);

        vm.prank(spender);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        permit3.permitTransferFrom(permit, _details(recipient, 1e18), owner, abi.encodePacked(r, s, v));
    }

    /// @dev A nonce is a nonce: spending it through a signature transfer must also
    ///      burn it for the allowance-permit flow, and vice versa.
    function test_nonceSpace_sharedWithPermitBatch() public {
        ISignatureTransfer.PermitTransferFrom memory permit = _permit(100e18, 42);
        bytes memory sig = _signSingle(permit, spender);

        vm.prank(spender);
        permit3.permitTransferFrom(permit, _details(recipient, 1e18), owner, sig);

        // Same nonce, now through the allowance flow.
        IPermit3.PermitBatch memory batch = IPermit3.PermitBatch({
            tokens: new IPermit3.TokenPermit[](0),
            takers: new IPermit3.TakerPermit[](0),
            nonce: 42,
            deadline: block.timestamp + 1 hours
        });
        bytes memory batchSig = _sign(
            keccak256(
                abi.encode(
                    keccak256(
                        "PermitBatch(TokenPermit[] tokens,TakerPermit[] takers,uint256 nonce,uint256 deadline)"
                        "TakerPermit(address spender,address module,bytes32 ref,uint160 amount,uint48 expiration)"
                        "TokenPermit(address spender,address token,uint160 amount,uint48 expiration)"
                    ),
                    keccak256(""),
                    keccak256(""),
                    batch.nonce,
                    batch.deadline
                )
            )
        );
        vm.expectRevert(IPermit3.PermitNonceUsed.selector);
        permit3.permitBatch(owner, batch, batchSig);
    }

    function test_invalidateUnorderedNonces_cancelsSignedTransfer() public {
        ISignatureTransfer.PermitTransferFrom memory permit = _permit(100e18, 5);
        bytes memory sig = _signSingle(permit, spender);

        vm.prank(owner);
        permit3.invalidateUnorderedNonces(0, 1 << 5);

        vm.prank(spender);
        vm.expectRevert(IPermit3.PermitNonceUsed.selector);
        permit3.permitTransferFrom(permit, _details(recipient, 1e18), owner, sig);
    }

    // ════════════════ Witness ════════════════

    function test_permitWitnessTransferFrom() public {
        ISignatureTransfer.PermitTransferFrom memory permit = _permit(100e18, 1);
        bytes32 witness = keccak256("order");
        bytes memory sig = _signSingleWitness(permit, spender, witness);

        vm.prank(spender);
        permit3.permitWitnessTransferFrom(permit, _details(recipient, 100e18), owner, witness, WITNESS_TYPE_STRING, sig);

        assertEq(token.balanceOf(recipient), 100e18);
    }

    function test_permitWitnessTransferFrom_revert_witnessSwap() public {
        ISignatureTransfer.PermitTransferFrom memory permit = _permit(100e18, 1);
        bytes memory sig = _signSingleWitness(permit, spender, keccak256("order"));

        vm.prank(spender);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        permit3.permitWitnessTransferFrom(
            permit, _details(recipient, 100e18), owner, keccak256("other order"), WITNESS_TYPE_STRING, sig
        );
    }

    // ════════════════ Batch ════════════════

    function _batchPermit(uint256 legs, uint256 nonce)
        internal
        view
        returns (ISignatureTransfer.PermitBatchTransferFrom memory permit)
    {
        ISignatureTransfer.TokenPermissions[] memory permitted = new ISignatureTransfer.TokenPermissions[](legs);
        for (uint256 i; i < legs; ++i) {
            permitted[i] = ISignatureTransfer.TokenPermissions({token: address(token), amount: (i + 1) * 10e18});
        }
        permit = ISignatureTransfer.PermitBatchTransferFrom({
            permitted: permitted, nonce: nonce, deadline: block.timestamp + 1 hours
        });
    }

    function _signBatch(ISignatureTransfer.PermitBatchTransferFrom memory permit, address theSpender)
        internal
        view
        returns (bytes memory)
    {
        bytes32[] memory hashes = new bytes32[](permit.permitted.length);
        for (uint256 i; i < permit.permitted.length; ++i) {
            hashes[i] = _hashPermitted(permit.permitted[i]);
        }
        return _sign(
            keccak256(
                abi.encode(
                    PERMIT_BATCH_TRANSFER_FROM_TH,
                    keccak256(abi.encodePacked(hashes)),
                    theSpender,
                    permit.nonce,
                    permit.deadline
                )
            )
        );
    }

    function test_permitBatchTransferFrom() public {
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _batchPermit(3, 1);
        bytes memory sig = _signBatch(permit, spender);

        ISignatureTransfer.SignatureTransferDetails[] memory details =
            new ISignatureTransfer.SignatureTransferDetails[](3);
        details[0] = _details(recipient, 10e18);
        details[1] = _details(address(0xD00D), 20e18);
        // Third leg skipped — a zero request is a legal no-op.
        details[2] = _details(recipient, 0);

        vm.prank(spender);
        permit3.permitTransferFrom(permit, details, owner, sig);

        assertEq(token.balanceOf(recipient), 10e18);
        assertEq(token.balanceOf(address(0xD00D)), 20e18);
        assertTrue(permit3.isPermitNonceUsed(owner, 1), "one nonce for the whole batch");
    }

    function test_permitBatchTransferFrom_revert_lengthMismatch() public {
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _batchPermit(2, 1);
        bytes memory sig = _signBatch(permit, spender);

        ISignatureTransfer.SignatureTransferDetails[] memory details =
            new ISignatureTransfer.SignatureTransferDetails[](1);
        details[0] = _details(recipient, 10e18);

        vm.prank(spender);
        vm.expectRevert(ISignatureTransfer.LengthMismatch.selector);
        permit3.permitTransferFrom(permit, details, owner, sig);
    }

    function test_permitBatchTransferFrom_revert_legOverCap() public {
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _batchPermit(2, 1);
        bytes memory sig = _signBatch(permit, spender);

        ISignatureTransfer.SignatureTransferDetails[] memory details =
            new ISignatureTransfer.SignatureTransferDetails[](2);
        details[0] = _details(recipient, 10e18);
        details[1] = _details(recipient, 20e18 + 1); // leg cap is 20e18

        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(ISignatureTransfer.InvalidAmount.selector, 20e18));
        permit3.permitTransferFrom(permit, details, owner, sig);
    }

    function test_permitBatchTransferFrom_revert_wrongSpender() public {
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _batchPermit(1, 1);
        bytes memory sig = _signBatch(permit, spender);

        ISignatureTransfer.SignatureTransferDetails[] memory details =
            new ISignatureTransfer.SignatureTransferDetails[](1);
        details[0] = _details(address(0xBAD), 10e18);

        vm.prank(address(0xBAD));
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        permit3.permitTransferFrom(permit, details, owner, sig);
    }
}
