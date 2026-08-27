// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC1271} from "@core/interfaces/IERC1271.sol";
import {Order} from "@core/settlement/Settlement.sol";
import {SignatureVerification} from "@core/permit3/SignatureVerification.sol";

import {MockSettlementBase} from "../shared/MockSettlementBase.t.sol";

/// @dev The NAIVE EIP-1271 wallet — the shape ERC-7739 exists to warn about. It
///      validates by recovering to `owner` and does NOT mix its own address into
///      what it checks, so two instances with the same owner accept the same
///      signature over the same digest. Deliberately naive: a vanilla Safe rehashes
///      with its own domain and is immune, and testing only the immune shape would
///      prove nothing about our digests.
contract NaiveWallet is IERC1271 {
    address public immutable owner;

    constructor(address _owner) {
        owner = _owner;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view override returns (bytes4) {
        if (signature.length != 65) return 0xffffffff;
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

/// @dev 1271 wallets that misbehave in each of the three ways the verifier has to
///      survive: a wrong magic value, a revert, and an empty return.
contract WrongMagicWallet is IERC1271 {
    function isValidSignature(bytes32, bytes memory) external pure override returns (bytes4) {
        return 0xdeadbeef;
    }
}

contract RevertingWallet is IERC1271 {
    error Nope();

    function isValidSignature(bytes32, bytes memory) external pure override returns (bytes4) {
        revert Nope();
    }
}

contract EmptyReturnWallet {
    fallback() external {} // returns zero bytes; the bytes4 decode must not succeed
}

/// @title SignatureEdgeCases
/// @notice Adversarial coverage of the ORDER signature path — the edge cases the
///         happy-path suites do not reach, each one drawn from a published audit
///         class rather than invented.
///
///  Why this file exists: `docs/reference-audits.md` F13 was an authorisation bug in
///  this exact area, and the sweep it added asks the generalised question. These
///  tests pin the answers so a future refactor of {SignatureVerification} or
///  {Signatures._verifySignature} cannot quietly change one.
///
///  The classes covered, and what each is really asserting:
///
///   • ECDSA MALLEABILITY (EIP-2; OpenZeppelin advisory 4.7.3). {recoverCalldata}
///     applies no lower-half-`s` check AND accepts both the 65-byte and the 64-byte
///     EIP-2098 form — the precise combination OZ patched. So ONE authorisation has
///     up to FOUR distinct byte encodings. That is not a vulnerability here, and the
///     test below is what proves it: replay is bound by `filled[orderHash]`, never
///     by the signature bytes. It IS a live hazard for anything off-chain that
///     dedupes orders by signature.
///   • CROSS-ACCOUNT 1271 REPLAY (ERC-7739). A digest that does not name the account
///     is replayable across accounts that share a validation rule. `Order` binds
///     `address maker` in its typehash, so orders are immune — pinned here, because
///     the field is what buys the immunity and a typehash edit could drop it.
///   • DEGENERATE ecrecover INPUTS. `v ∉ {27,28}` and zero `r`/`s` return
///     `address(0)`; the verifier must never treat that as a match.
///   • 1271 MISBEHAVIOUR. Wrong magic, revert, empty return.
///   • DOMAIN SEPARATION ON FORK. The separator must follow `block.chainid`.
contract SignatureEdgeCasesTest is MockSettlementBase {
    uint256 constant AMOUNT_IN = 100e18;
    uint256 constant AMOUNT_OUT = 300e18;

    /// @dev secp256k1 group order. `s` and `N - s` recover the same signer.
    uint256 constant N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    function _fund() internal {
        tA.mint(maker, AMOUNT_IN * 4);
        _makerApprove(address(settlement), address(tA), AMOUNT_IN * 4);
        tB.mint(solver, AMOUNT_OUT * 4);
        _solverApprove(address(settlement), address(tB), AMOUNT_OUT * 4);
    }

    function _order(uint256 nonce) internal view returns (Order memory) {
        return _plainOrder(nonce, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
    }

    function _digest(Order memory o) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), _hashOrder(o)));
    }

    /// @dev The malleable twin of a 65-byte signature: `(r, N - s, v ^ 1)`.
    function _twin(bytes memory sig) internal pure returns (bytes memory) {
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
        return abi.encodePacked(r, bytes32(N - uint256(s)), uint8(v == 27 ? 28 : 27));
    }

    /// @dev The EIP-2098 compact (64-byte) encoding of a 65-byte signature.
    function _compact(bytes memory sig) internal pure returns (bytes memory) {
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
        bytes32 vs = bytes32(uint256(s) | (v == 28 ? (uint256(1) << 255) : 0));
        return abi.encodePacked(r, vs);
    }

    // ════════════════ ECDSA malleability ════════════════

    /// @dev The malleable twin authorises just as well as the original. Asserted
    ///      rather than assumed: {SignatureVerification.recoverCalldata} applies no
    ///      lower-half-`s` check, so this is the CURRENT contract, and a future
    ///      decision to add one should break this test loudly rather than silently
    ///      change which signatures the protocol honours.
    function test_malleability_twinAuthorizesIdentically() public {
        _fund();
        Order memory o = _order(1);
        bytes memory twin = _twin(_sign(o));

        vm.prank(solver);
        settlement.fill(o, twin, AMOUNT_IN);
        assertEq(tA.balanceOf(solver), AMOUNT_IN, "malleable twin filled the order");
    }

    /// @dev THE ONE THAT MATTERS. One authorisation has four distinct byte
    ///      encodings — 65-byte, its twin, and the EIP-2098 form of each — the exact
    ///      combination OpenZeppelin patched in 4.7.3. None of them is a second
    ///      authorisation, because replay is bound by `filled[orderHash]` and not by
    ///      the signature bytes. This is why malleability is benign HERE.
    ///
    ///      ⚠ It is NOT benign for anything that treats a signature as an order's
    ///      identity. An off-chain book deduping by `keccak256(sig)` would admit the
    ///      same order four times.
    function test_malleability_fourEncodings_stillOneFill() public {
        _fund();
        Order memory o = _order(2);
        bytes memory sig = _sign(o);

        bytes[4] memory forms = [sig, _twin(sig), _compact(sig), _compact(_twin(sig))];
        // All four are distinct byte strings...
        for (uint256 i; i < 4; i++) {
            for (uint256 j = i + 1; j < 4; j++) {
                assertTrue(keccak256(forms[i]) != keccak256(forms[j]), "encodings must differ");
            }
        }

        vm.prank(solver);
        settlement.fill(o, forms[0], AMOUNT_IN); // consumes the whole order

        // ...and every remaining one is rejected by the FILL counter, not the bytes.
        for (uint256 i = 1; i < 4; i++) {
            vm.prank(solver);
            vm.expectRevert();
            settlement.fill(o, forms[i], AMOUNT_IN);
        }
        assertEq(settlement.filled(_hashOrder(o)), AMOUNT_IN, "exactly one fill");
    }

    // ════════════════ Cross-account 1271 replay (ERC-7739) ════════════════

    /// @dev `Order` binds `address maker` in its typehash, so the digest differs per
    ///      account and a signature minted for wallet A cannot be replayed against
    ///      wallet B — even though both wallets share an owner and validate
    ///      identically (the naive shape ERC-7739 targets, and the shape Permit2 is
    ///      criticised for in its own `PermitBatch`, which carries no owner field).
    ///
    ///      Pinned because the immunity comes from ONE FIELD in the typehash.
    function test_crossAccountReplay_ordersBindTheMaker() public {
        uint256 ownerPk = 0xA11CE;
        address ownerAddr = vm.addr(ownerPk);
        NaiveWallet walletA = new NaiveWallet(ownerAddr);
        NaiveWallet walletB = new NaiveWallet(ownerAddr);

        // Both wallets are funded and approved identically.
        for (uint256 i; i < 2; i++) {
            address w = i == 0 ? address(walletA) : address(walletB);
            tA.mint(w, AMOUNT_IN);
            vm.startPrank(w);
            tA.approve(address(permit3), type(uint256).max);
            permit3.approveToken(address(settlement), address(tA), type(uint160).max, 0);
            vm.stopPrank();
        }
        tB.mint(solver, AMOUNT_OUT * 2);
        _solverApprove(address(settlement), address(tB), AMOUNT_OUT * 2);

        Order memory oA = _order(3);
        oA.maker = address(walletA);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, _digest(oA));
        bytes memory sigA = abi.encodePacked(r, s, v);

        // The same order, re-pointed at wallet B. Same owner, same validation rule.
        // Built FRESH, not `= oA`: a memory struct assignment in Solidity aliases
        // rather than copies, so mutating `oB.maker` would silently retarget `oA`
        // too and the control below would test nothing.
        Order memory oB = _order(3);
        oB.maker = address(walletB);

        vm.prank(solver);
        vm.expectRevert(); // digest differs because `maker` is in the typehash
        settlement.fill(oB, sigA, AMOUNT_IN);

        // ...and the signature is genuinely good for the account it names.
        vm.prank(solver);
        settlement.fill(oA, sigA, AMOUNT_IN);
        assertEq(tA.balanceOf(solver), AMOUNT_IN, "wallet A's own order fills");
    }

    // ════════════════ Degenerate ecrecover inputs ════════════════

    /// @dev `v ∉ {27, 28}` makes `ecrecover` return `address(0)`. The verifier must
    ///      never read that as a match — the classic "zero address recovered"
    ///      finding, which is fatal for any code that compares without checking.
    function test_reject_invalidV() public {
        _fund();
        Order memory o = _order(4);
        bytes memory sig = _sign(o);
        bytes32 r;
        bytes32 s;
        assembly {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
        }
        uint8[4] memory bad = [uint8(0), 1, 26, 29];
        for (uint256 i; i < 4; i++) {
            vm.prank(solver);
            vm.expectRevert(SignatureVerification.InvalidSigner.selector);
            settlement.fill(o, abi.encodePacked(r, s, bad[i]), AMOUNT_IN);
        }
    }

    /// @dev Zero `r` / zero `s` likewise recover to `address(0)`.
    function test_reject_zeroComponents() public {
        _fund();
        Order memory o = _order(5);
        bytes memory sig = _sign(o);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
        vm.prank(solver);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        settlement.fill(o, abi.encodePacked(bytes32(0), s, v), AMOUNT_IN);

        vm.prank(solver);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        settlement.fill(o, abi.encodePacked(r, bytes32(0), v), AMOUNT_IN);
    }

    /// @dev A length that is neither 64 nor 65 can never be ECDSA, and an EOA maker
    ///      has no `isValidSignature` to fall back to. Note 66 and 98 are NOT here:
    ///      they collide with the bulk-signature envelope and take a different
    ///      branch, which `BulkSignature.t.sol` covers.
    function test_reject_nonStandardLength_forEoaMaker() public {
        _fund();
        Order memory o = _order(6);
        uint256[3] memory lens = [uint256(1), 63, 80];
        for (uint256 i; i < 3; i++) {
            vm.prank(solver);
            vm.expectRevert(SignatureVerification.InvalidSignatureLength.selector);
            settlement.fill(o, new bytes(lens[i]), AMOUNT_IN);
        }
    }

    // ════════════════ 1271 misbehaviour ════════════════

    function _walletOrder(uint256 nonce, address wallet) internal returns (Order memory o) {
        o = _order(nonce);
        o.maker = wallet;
        tA.mint(wallet, AMOUNT_IN);
        vm.startPrank(wallet);
        tA.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(tA), type(uint160).max, 0);
        vm.stopPrank();
        tB.mint(solver, AMOUNT_OUT);
        _solverApprove(address(settlement), address(tB), AMOUNT_OUT);
    }

    function test_1271_wrongMagicValue_reverts() public {
        Order memory o = _walletOrder(7, address(new WrongMagicWallet()));
        vm.prank(solver);
        vm.expectRevert(SignatureVerification.InvalidContractSignature.selector);
        settlement.fill(o, new bytes(65), AMOUNT_IN);
    }

    function test_1271_revertingWallet_propagates() public {
        Order memory o = _walletOrder(8, address(new RevertingWallet()));
        vm.prank(solver);
        vm.expectRevert(); // the wallet's own revert, not silently treated as valid
        settlement.fill(o, new bytes(65), AMOUNT_IN);
    }

    /// @dev A wallet returning NO data must not decode as the magic value.
    function test_1271_emptyReturn_reverts() public {
        Order memory o = _walletOrder(9, address(new EmptyReturnWallet()));
        vm.prank(solver);
        vm.expectRevert();
        settlement.fill(o, new bytes(65), AMOUNT_IN);
    }

    // ════════════════ Domain separation on fork ════════════════

    /// @dev The separator must follow `block.chainid`, so an order signed before a
    ///      fork cannot be replayed after one. {EIP712} recomputes rather than
    ///      serving its cached value when the chain id moves; this asserts the
    ///      settlement's own domain does the same.
    function test_domainSeparator_followsChainId() public {
        _fund();
        Order memory o = _order(10);
        bytes memory sig = _sign(o); // signed under the current chain id

        bytes32 before_ = settlement.DOMAIN_SEPARATOR();
        vm.chainId(block.chainid + 1);
        assertTrue(settlement.DOMAIN_SEPARATOR() != before_, "separator must move with chainid");

        vm.prank(solver);
        vm.expectRevert(); // the old signature is meaningless in the new domain
        settlement.fill(o, sig, AMOUNT_IN);
    }
}
