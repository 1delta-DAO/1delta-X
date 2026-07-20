// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "@core/settlement/Base.sol";
import {Settlement, Order, Validator} from "@core/settlement/Settlement.sol";
import {IOrderValidator} from "@core/interfaces/IOrderValidator.sol";
import {IERC1271} from "@core/interfaces/IERC1271.sol";
import {FillerAttestationValidator} from "@core/validators/FillerAttestationValidator.sol";

import {MockSettlementBase} from "../shared/MockSettlementBase.t.sol";

/// @dev Minimal EIP-1271 smart-account wallet controlled by a single EOA key —
///      stands in for a multisig / Gnosis Safe attester. Validates any signature
///      the `owner` key produces over the queried hash.
contract MockAttesterWallet is IERC1271 {
    address public immutable owner;

    constructor(address o) {
        owner = o;
    }

    function isValidSignature(bytes32 hash, bytes memory sig) external view override returns (bytes4) {
        if (sig.length != 65) return 0xffffffff;
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(sig, 0x20))
            s := mload(add(sig, 0x40))
            v := byte(0, mload(add(sig, 0x60)))
        }
        if (ecrecover(hash, v, r, s) == owner) return IERC1271.isValidSignature.selector;
        return 0xffffffff;
    }
}

/// @dev Tiny validator that passes iff the shared `takerData` blob hashes to a
///      pinned value. Proves takerData is threaded from the fill entrypoint into
///      the validators (and that the 3-arg wrapper defaults it to empty).
contract TakerDataAsserter is IOrderValidator {
    bytes32 public immutable expected;

    constructor(bytes32 e) {
        expected = e;
    }

    function validate(Order calldata, address, bytes calldata, bytes calldata takerData)
        external
        view
        override
        returns (bool)
    {
        return keccak256(takerData) == expected;
    }
}

/// @title FillerAttestationTest
/// @notice Coverage for {FillerAttestationValidator} and the taker-supplied data
///         channel: a maker gates a fill on an off-chain attester credential the
///         filler carries in `takerData`. Exercises the happy path, wrong-signer /
///         expired rejections, the Fusion open-up fallback, the two replay
///         defences (cross-filler + cross-domain), the generic takerData-threading
///         guarantee, per-order batch alignment + length mismatch, and the
///         validator working as a post-execution invariant.
contract FillerAttestationTest is MockSettlementBase {
    uint256 constant AMOUNT_IN = 100e18; // tA maker gives
    uint256 constant AMOUNT_OUT = 300e18; // tB maker gets
    uint256 constant LIST_ID = 7;

    FillerAttestationValidator av;

    uint256 attesterPk = 0xA77E57; // the maker-trusted attester
    address attester = vm.addr(attesterPk);
    uint256 badPk = 0xBAD5; // a non-attester key
    address filler2 = address(0xF2); // a second filler (never issued a credential)
    address outsider = address(0x0DD); // used for the open-up fallback

    function setUp() public override {
        super.setUp();
        av = new FillerAttestationValidator();

        tA.mint(maker, 1_000e18);
        _makerApprove(address(settlement), address(tA), type(uint160).max);

        // Every filler can deliver tokenOut, so the ONLY separator is the gate.
        _fundFiller(solver);
        _fundFiller(filler2);
        _fundFiller(outsider);
    }

    // ──────────────────── Helpers ────────────────────

    function _fundFiller(address f) internal {
        tB.mint(f, 1_000e18);
        vm.startPrank(f);
        tB.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(tB), type(uint160).max, 0);
        vm.stopPrank();
    }

    /// @dev Order gated by `av` under `attester` / `LIST_ID` / `openAfter`.
    function _gated(uint256 nonce, uint256 openAfter) internal view returns (Order memory o) {
        return _gatedBy(nonce, openAfter, attester);
    }

    /// @dev Same, but with an explicit `att` address as the maker-trusted attester —
    ///      lets a test point the gate at a contract-wallet / 7702 attester.
    function _gatedBy(uint256 nonce, uint256 openAfter, address att) internal view returns (Order memory o) {
        o = _plainOrder(nonce, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        o.deadline = block.timestamp + 3 hours; // survive warps in the fallback/expiry tests
        Validator[] memory v = new Validator[](1);
        v[0] = Validator({target: address(av), data: abi.encode(att, LIST_ID, openAfter)});
        o.validators = v;
    }

    /// @dev Build `takerData = abi.encode(expiry, sig)` where `sig` is `signerPk`'s
    ///      signature over `validator`'s attestation digest for `(filler, LIST_ID,
    ///      expiry)`. Uses the validator's own view so the digest is exactly what it
    ///      will recompute on-chain.
    function _credential(
        FillerAttestationValidator validator,
        address filler,
        uint256 expiry,
        uint256 signerPk
    ) internal view returns (bytes memory) {
        bytes32 digest = validator.attestationDigest(filler, LIST_ID, expiry);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encode(expiry, abi.encodePacked(r, s, v));
    }

    function _expectValidationFailed() internal {
        vm.expectRevert(abi.encodeWithSelector(Base.ValidationFailed.selector, uint256(0)));
    }

    // ──────────────────── Happy path ────────────────────

    function test_attest_happyPath() public {
        Order memory o = _gated(1, 0);
        bytes memory sig = _sign(o);
        bytes memory takerData = _credential(av, solver, block.timestamp + 1 hours, attesterPk);

        vm.prank(solver);
        settlement.fill(o, sig, AMOUNT_IN, takerData);
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "maker got output");
        assertEq(tA.balanceOf(solver), AMOUNT_IN, "attested solver got input");
    }

    // ──────────────────── Contract-signer / EIP-7702 attesters ────────────────────

    /// @dev The attester is a smart-account wallet (multisig / Gnosis Safe stand-in)
    ///      that validates via EIP-1271. The credential is signed by the wallet's
    ///      owner key; the validator's ecrecover recovers the owner (≠ the wallet
    ///      address), then falls through to `wallet.isValidSignature` which accepts.
    function test_attest_contractSignerAttester_eip1271() public {
        MockAttesterWallet wallet = new MockAttesterWallet(attester);
        Order memory o = _gatedBy(1, 0, address(wallet)); // gate trusts the WALLET
        bytes memory sig = _sign(o);
        // Credential signed by the wallet's owner key over the (filler, listId, expiry) digest.
        bytes memory takerData = _credential(av, solver, block.timestamp + 1 hours, attesterPk);

        vm.prank(solver);
        settlement.fill(o, sig, AMOUNT_IN, takerData);
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "1271 attester: maker got output");
        assertEq(tA.balanceOf(solver), AMOUNT_IN, "1271-attested solver got input");
    }

    /// @dev A wrong key signing for a 1271 attester wallet is rejected: the owner
    ///      check inside `isValidSignature` fails → magic value not returned → gate false.
    function test_attest_contractSignerAttester_wrongKeyReverts() public {
        MockAttesterWallet wallet = new MockAttesterWallet(attester);
        Order memory o = _gatedBy(1, 0, address(wallet));
        bytes memory sig = _sign(o);
        bytes memory takerData = _credential(av, solver, block.timestamp + 1 hours, badPk);

        vm.prank(solver);
        _expectValidationFailed();
        settlement.fill(o, sig, AMOUNT_IN, takerData);
    }

    /// @dev THE Permit2 7702 failure mode, guarded: the attester is an EIP-7702
    ///      account — same address as its signing key, but now carrying bytecode.
    ///      Because ecrecover is tried FIRST, its regular signature is honoured and
    ///      the 1271 path is never consulted. We etch STOP code (which would return
    ///      empty → 1271 false) precisely so a pass proves the ecrecover-first path.
    function test_attest_eip7702RawKeyAttester() public {
        vm.etch(attester, hex"00"); // non-empty code at the key's own address; not a 1271 impl
        Order memory o = _gated(1, 0); // gate still trusts `attester`
        bytes memory sig = _sign(o);
        bytes memory takerData = _credential(av, solver, block.timestamp + 1 hours, attesterPk);

        vm.prank(solver);
        settlement.fill(o, sig, AMOUNT_IN, takerData);
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "7702 raw-key attester: maker got output");
        assertEq(tA.balanceOf(solver), AMOUNT_IN, "7702 raw-key attester accepted");
    }

    // ──────────────────── Rejections ────────────────────

    function test_attest_wrongSignerReverts() public {
        Order memory o = _gated(1, 0);
        bytes memory sig = _sign(o);
        // A non-attester key signs the same (filler, listId, expiry).
        bytes memory takerData = _credential(av, solver, block.timestamp + 1 hours, badPk);

        vm.prank(solver);
        _expectValidationFailed();
        settlement.fill(o, sig, AMOUNT_IN, takerData);
    }

    function test_attest_expiredCredentialReverts() public {
        Order memory o = _gated(1, 0);
        bytes memory sig = _sign(o);
        uint256 expiry = block.timestamp + 10;
        bytes memory takerData = _credential(av, solver, expiry, attesterPk);

        vm.warp(expiry + 1); // now past expiry
        vm.prank(solver);
        _expectValidationFailed();
        settlement.fill(o, sig, AMOUNT_IN, takerData);
    }

    function test_attest_emptyTakerDataReverts() public {
        Order memory o = _gated(1, 0); // hard gate (openAfter == 0)
        bytes memory sig = _sign(o);

        vm.prank(solver);
        _expectValidationFailed();
        settlement.fill(o, sig, AMOUNT_IN, "");
    }

    // ──────────────────── Open-up fallback ────────────────────

    function test_attest_openAfterElapsedNeedsNoCredential() public {
        uint256 openAfter = block.timestamp + 30 minutes;
        Order memory o = _gated(1, openAfter);
        bytes memory sig = _sign(o);

        // Before the window: even with no credential the order is attestation-gated.
        vm.prank(outsider);
        _expectValidationFailed();
        settlement.fill(o, sig, AMOUNT_IN, "");

        // After the window: any filler settles with EMPTY takerData.
        vm.warp(openAfter);
        vm.prank(outsider);
        settlement.fill(o, sig, AMOUNT_IN, "");
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "open-up: maker got output");
        assertEq(tA.balanceOf(outsider), AMOUNT_IN, "open-up: outsider filled");
    }

    // ──────────────────── Replay defences ────────────────────

    /// @dev THE key security test: a credential issued to filler A cannot be
    ///      presented by filler B — the on-chain `filler` binds the digest.
    function test_attest_crossFillerReplayFails() public {
        Order memory o = _gated(1, 0);
        bytes memory sig = _sign(o);
        // Attester issues a credential to `solver`.
        bytes memory credForSolver = _credential(av, solver, block.timestamp + 1 hours, attesterPk);

        // filler2 replays solver's EXACT (expiry, sig): its digest binds to filler2,
        // so recovery != attester → fail.
        vm.prank(filler2);
        _expectValidationFailed();
        settlement.fill(o, sig, AMOUNT_IN, credForSolver);
        assertEq(tB.balanceOf(maker), 0, "nothing delivered to maker");

        // The bound filler (solver) fills with the very same credential.
        vm.prank(solver);
        settlement.fill(o, sig, AMOUNT_IN, credForSolver);
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "bound filler settles");
    }

    /// @dev A credential minted for a DIFFERENT validator instance (same attester,
    ///      same filler) fails — the domain binds to `address(this)`.
    function test_attest_crossDomainReplayFails() public {
        FillerAttestationValidator av2 = new FillerAttestationValidator();
        Order memory o = _gated(1, 0); // gated by `av`
        bytes memory sig = _sign(o);
        // Sign against av2's domain, present to av.
        bytes memory credForAv2 = _credential(av2, solver, block.timestamp + 1 hours, attesterPk);

        vm.prank(solver);
        _expectValidationFailed();
        settlement.fill(o, sig, AMOUNT_IN, credForAv2);
    }

    // ──────────────────── Generic takerData threading ────────────────────

    /// @dev Proves takerData reaches validators via the 4-arg overload and that the
    ///      3-arg wrapper defaults it to empty.
    function test_takerData_threadedToValidators() public {
        bytes memory blob = hex"c0ffee";
        TakerDataAsserter asserter = new TakerDataAsserter(keccak256(blob));
        Order memory o = _plainOrder(1, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        Validator[] memory v = new Validator[](1);
        v[0] = Validator({target: address(asserter), data: ""});
        o.validators = v;
        bytes memory sig = _sign(o);

        // 3-arg wrapper → empty takerData → keccak("") != expected → fails.
        vm.prank(solver);
        _expectValidationFailed();
        settlement.fill(o, sig, AMOUNT_IN);

        // 4-arg overload carrying the blob → keccak matches → settles.
        vm.prank(solver);
        settlement.fill(o, sig, AMOUNT_IN, blob);
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "blob reached the validator");
    }

    // ──────────────────── batchFill per-order alignment ────────────────────

    function test_attest_batchFillPerOrderTakerDatas() public {
        Order memory gated = _gated(1, 0); // needs a credential
        Order memory open = _plainOrder(2, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT); // no gate

        Order[] memory orders = new Order[](2);
        orders[0] = gated;
        orders[1] = open;
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(gated);
        sigs[1] = _sign(open);
        uint256[] memory amts = new uint256[](2);
        amts[0] = AMOUNT_IN;
        amts[1] = AMOUNT_IN;
        bytes[] memory takerDatas = new bytes[](2);
        takerDatas[0] = _credential(av, solver, block.timestamp + 1 hours, attesterPk);
        takerDatas[1] = ""; // open order needs nothing

        vm.prank(solver);
        (, bool[] memory ok) = settlement.batchFill(orders, sigs, amts, false, takerDatas);
        assertTrue(ok[0], "gated order settled with its credential");
        assertTrue(ok[1], "open order settled with empty takerData");
        assertEq(tB.balanceOf(maker), AMOUNT_OUT * 2, "both delivered");
    }

    function test_attest_batchFillLengthMismatchReverts() public {
        Order memory o = _gated(1, 0);
        Order[] memory orders = new Order[](1);
        orders[0] = o;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(o);
        uint256[] memory amts = new uint256[](1);
        amts[0] = AMOUNT_IN;
        bytes[] memory takerDatas = new bytes[](2); // misaligned

        vm.prank(solver);
        vm.expectRevert(Base.LengthMismatch.selector);
        settlement.batchFill(orders, sigs, amts, false, takerDatas);
    }

    // ──────────────────── As a post-execution invariant ────────────────────

    function test_attest_asPostExecutionInvariant() public {
        // Same validator, placed in `invariants` instead of `validators`.
        Order memory o = _plainOrder(1, address(tA), address(tB), AMOUNT_IN, AMOUNT_OUT);
        Validator[] memory inv = new Validator[](1);
        inv[0] = Validator({target: address(av), data: abi.encode(attester, LIST_ID, uint256(0))});
        o.invariants = inv;
        bytes memory sig = _sign(o);
        bytes memory cred = _credential(av, solver, block.timestamp + 1 hours, attesterPk);

        // No credential → the invariant unwinds the whole fill AFTER transfers.
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(Base.InvariantFailed.selector, uint256(0)));
        settlement.fill(o, sig, AMOUNT_IN, "");
        assertEq(tB.balanceOf(maker), 0, "unwound: maker kept nothing");

        // With the credential the same invariant passes.
        vm.prank(solver);
        settlement.fill(o, sig, AMOUNT_IN, cred);
        assertEq(tB.balanceOf(maker), AMOUNT_OUT, "invariant satisfied by credential");
    }
}
