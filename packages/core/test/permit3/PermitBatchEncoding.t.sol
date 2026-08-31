// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IERC1271} from "@core/interfaces/IERC1271.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {ITakerModule} from "@core/interfaces/ITakerModule.sol";
import {Order, Item, ItemOp} from "@core/settlement/Settlement.sol";
import {OrderHash} from "@core/settlement/OrderHash.sol";

import {CoreSettlementBase} from "../shared/CoreSettlementBase.t.sol";

/// @dev A minimal borrow: hands `produce` of `token` (both in `data`) to the
///      receiver. Its only job here is to CONSUME a taker permit, so the test can
///      prove the `takers` array reached Permit3 intact.
contract MockTakerStash is ITakerModule {
    address public immutable permit3;

    constructor(address _permit3) {
        permit3 = _permit3;
    }

    function takeOnBehalf(address, uint256, address receiver, bytes calldata data) external override {
        require(msg.sender == permit3, "only permit3");
        (address token, uint256 produce) = abi.decode(data, (address, uint256));
        IERC20(token).transfer(receiver, produce);
    }
}

/// @dev A contract maker whose 1271 signature is an ECDSA pair followed by ARBITRARY
///      trailing bytes — the shape a Safe's dynamic part or a WebAuthn/passkey blob
///      actually has. It exists so a `sig` far longer than 65 bytes reaches the
///      hand-rolled encoder: that is the only way to drive `calldatacopy` over a
///      multi-word tail and to make the padding word land somewhere other than the
///      one offset a 64/65-byte signature can produce.
/// @dev Etched over Permit3 for the differential test below. `vm.expectCall` cannot
///      do this job: its calldata form is a PREFIX match, so an encoder emitting a
///      correct prefix followed by trailing slop — a `total` a word too long, a stale
///      padding word counted in — satisfies it. Verified: a mutation adding 0x20 to
///      `total` passes `expectCall` and fails against this. Capturing `msg.data`
///      verbatim is the only way to compare LENGTH as well as content.
contract CalldataRecorder {
    bytes public seen;

    /// @dev SELECTOR-FILTERED, not "first call wins". Once etched, this contract
    ///      answers EVERY call the fill makes to the hub — the permit, then the
    ///      transfers that follow it — so an unfiltered recorder ends up holding the
    ///      last one. (Measured the hard way: it captured a 132-byte `transferFrom`.)
    fallback() external {
        if (msg.sig == IPermit3.permitBatchWithWitnessHashIfNeeded.selector) seen = msg.data;
    }
}

contract PaddedSigWallet is IERC1271 {
    address public immutable owner;

    constructor(address _owner) {
        owner = _owner;
    }

    /// @dev Test-only: the wallet has to be able to grant Permit3 at the ERC-20
    ///      level, which a bare 1271 stub cannot do.
    function approveMax(address token, address spender) external {
        IERC20(token).approve(spender, type(uint256).max);
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view override returns (bytes4) {
        if (signature.length < 65) return 0xffffffff;
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }
        // Everything past byte 65 is ignored, exactly as a wallet with a static part
        // plus an opaque dynamic part behaves.
        if (ecrecover(hash, v, r, s) == owner) return IERC1271.isValidSignature.selector;
        return 0xffffffff;
    }
}

/// @dev The four-argument `fillWithPermit`, named unambiguously so a test can reach
///      `abi.encodeCall` for it — the overloaded member on `Settlement` cannot be.
interface IFillWithPermit {
    function fillWithPermit(
        Order calldata order,
        IPermit3.PermitBatch calldata batch,
        bytes calldata sig,
        uint256 fillAmount
    ) external returns (uint256[] memory);
}

/// @title PermitBatchEncoding
/// @notice `fillWithPermit`'s call into Permit3 is HAND-ENCODED
///         ({Core._permitBatchTail} / {Core._permitBatchHead}): 297 bytes of
///         Settlement runtime smaller and ~590–1,660 gas cheaper per fill than the
///         typed call. These tests exist because that encoder is now ours:
///
///           • the SELECTOR is a literal in assembly, so it is pinned here against
///             the interface rather than trusted;
///           • the `takers` array had NO coverage anywhere in the suite before this
///             file — every existing permit test passes `new TakerPermit[](0)` — and
///             it is the array whose stride (5 words, against `tokens`' 4) the
///             assembly has to get right;
///           • the digest Permit3 verifies is computed over the bytes WE built, so a
///             mis-placed offset shows up as a signature failure rather than as a
///             wrong-but-successful settlement. Asserting on the resulting ALLOWANCE
///             BOOK is what proves each element landed at the right index.
contract PermitBatchEncodingTest is CoreSettlementBase {
    MockTakerStash stash;

    uint256 constant USDC_IN = 2_000e6;
    uint256 constant WETH_OUT = 1 ether;

    function setUp() public override {
        super.setUp();
        stash = new MockTakerStash(address(permit3));
        vm.label(address(stash), "takerStash");
    }

    /// @dev The literal in {Core._permitBatchHead}. If the interface ever changes,
    ///      this fails loudly instead of the call landing on a different function.
    function test_selectorMatchesTheInterface() public pure {
        assertEq(
            IPermit3.permitBatchWithWitnessHashIfNeeded.selector,
            bytes4(0x6c837b2e),
            "hand-encoded selector drifted from the interface"
        );
    }

    /// @dev The shape with NOTHING in it: both arrays empty. Degenerate lengths are
    ///      where a hand-rolled encoder's offsets are easiest to get wrong, and the
    ///      order still has to settle.
    function test_bothArraysEmpty_stillSettles() public {
        deal(USDC, maker, USDC_IN);
        deal(WETH, solver, WETH_OUT);
        _approveSolverSide(WETH_OUT, WETH);
        // No token permit in the batch, so the maker's pull rides a standing grant.
        vm.prank(maker);
        permit3.approveToken(address(settlement), USDC, uint160(USDC_IN), 0);

        Order memory order = _order(maker, 1, USDC, WETH, USDC_IN, WETH_OUT, new Item[](0));
        IPermit3.PermitBatch memory batch =
            _buildBatch(new IPermit3.TokenPermit[](0), _noTakerPermits(), 0, _expiry(order));
        bytes memory sig = _signPermitWitness(batch, _hashOrder(order));

        vm.prank(solver);
        settlement.fillWithPermit(order, batch, sig, USDC_IN);

        assertEq(IERC20(WETH).balanceOf(maker), WETH_OUT, "settled on an empty batch");
    }

    // ──────────── the differential pin: every byte, against solc's own encoder ────────────

    /// @dev THE STRONGEST PIN AVAILABLE FOR A HAND-ROLLED ENCODER, and the one the
    ///      behavioural tests below cannot give.
    ///
    ///      Every other test in this file asserts an OUTCOME — the fill settled, the
    ///      permit landed at its index. Those run through Permit3's decoder, which is
    ///      tolerant: it reads offsets and lengths and ignores anything they do not
    ///      cover. So a malformed-but-decodable encoding — a slack offset, junk left
    ///      in a padding word, a `total` a few bytes long — passes every one of them
    ///      while sending bytes no honest encoder would produce. That matters because
    ///      the digest Permit3 signs over is computed from the DECODED values, not the
    ///      wire bytes, so wire-level slop is exactly the class of defect an
    ///      outcome test is blind to.
    ///
    ///      This captures the bytes {Core._permitBatch} actually sends and compares them
    ///      against `abi.encodeCall` — solc's own encoder, the thing the assembly
    ///      replaced — by LENGTH and by hash. Note it does NOT use `vm.expectCall`:
    ///      that cheatcode's calldata form is a PREFIX match, so an encoder emitting
    ///      a correct prefix followed by trailing slop satisfies it. Measured: a
    ///      mutation adding one word to `total` passes `expectCall` and fails here.
    ///
    ///      MUTATION-TESTED, and the results are worth recording because two of four
    ///      are NOT caught and pretending otherwise is how a pin rots:
    ///        • `total` a word too long  → CAUGHT (length assertion)
    ///        • a wrong `takers` offset  → CAUGHT (hash assertion)
    ///        • the padding `mstore` deleted → NOT caught. The write is unconditional,
    ///          so removing it is observable only when the memory above the free
    ///          pointer is already dirty, which a test cannot arrange reliably. The
    ///          zeroing rests on review, not on this.
    ///        • {Core._permitBatchHead} re-deriving its base from `mload(0x40)`
    ///          instead of taking it → NOT caught, because nothing between the two
    ///          halves allocates TODAY. That hazard is latent by nature, which is
    ///          exactly why it is closed by threading the pointer rather than by a
    ///          test.
    ///
    ///      Swept across the shapes whose OFFSETS differ (empty/empty, n/0, 0/n, n/m)
    ///      crossed with the signature lengths that hit every padding residue: 64
    ///      (exactly two words, no padding — the case a stale scratch word corrupts),
    ///      65 (31 bytes of padding, the ECDSA default) and a long 1271 blob spanning
    ///      several words.
    function test_handEncodedCalldata_isByteIdenticalToSolcs() public {
        _assertEncodingMatches(0, 0, 65, 20);
        _assertEncodingMatches(1, 0, 65, 21);
        _assertEncodingMatches(0, 1, 65, 22);
        _assertEncodingMatches(2, 3, 65, 23);
        _assertEncodingMatches(1, 1, 64, 24); // no padding word at all
        _assertEncodingMatches(2, 2, 160, 25); // a multi-word 1271-shaped tail
        _assertEncodingMatches(3, 1, 96, 26); // exactly three words
    }

    /// @dev Build a batch of the given shape, then assert the settler sends Permit3
    ///      precisely `abi.encodeCall(...)`. The fill is expected to REVERT (the
    ///      signature is junk, so Permit3 rejects it) — irrelevant here, because
    ///      `expectCall` is checked on the calldata that was dispatched, and the
    ///      encoder runs to completion before Permit3 looks at anything. That is the
    ///      point: it isolates the ENCODER from every downstream consequence, so this
    ///      test keeps working even if the permit semantics change.
    function _assertEncodingMatches(uint256 nTokens, uint256 nTakers, uint256 sigLen, uint256 nonce) private {
        Order memory order = _order(maker, nonce, USDC, WETH, USDC_IN, WETH_OUT, new Item[](0));
        uint48 exp = uint48(_expiry(order));

        IPermit3.TokenPermit[] memory tp = new IPermit3.TokenPermit[](nTokens);
        for (uint256 i; i < nTokens; i++) {
            tp[i] = IPermit3.TokenPermit(address(settlement), USDC, uint160(USDC_IN + i), exp);
        }
        IPermit3.TakerPermit[] memory tkp = new IPermit3.TakerPermit[](nTakers);
        for (uint256 i; i < nTakers; i++) {
            tkp[i] = IPermit3.TakerPermit(
                address(settlement), address(stash), keccak256(abi.encode(i, nonce)), uint160(i + 1), exp
            );
        }
        IPermit3.PermitBatch memory batch = _buildBatch(tp, tkp, nonce, exp);

        // Deliberately NOT a valid signature: this pins the encoder, not the crypto,
        // and a junk blob is the only way to vary `sig.length` freely.
        bytes memory sig = new bytes(sigLen);
        for (uint256 i; i < sigLen; i++) {
            sig[i] = bytes1(uint8(i + 1));
        }

        bytes memory expected = abi.encodeCall(
            IPermit3.permitBatchWithWitnessHashIfNeeded,
            (maker, batch, _hashOrder(order), OrderHash.PERMIT_BATCH_WITNESS_TYPEHASH, sig)
        );

        // Etch the recorder over Permit3 so the call lands somewhere that keeps the
        // bytes. The fill then fails downstream (the hub no longer grants anything) —
        // caught and discarded, because the encoder has already run by then.
        bytes memory recorderCode = address(new CalldataRecorder()).code;
        vm.etch(address(permit3), recorderCode);
        vm.prank(solver);
        try settlement.fillWithPermit(order, batch, sig, USDC_IN) {} catch {}

        bytes memory actual = CalldataRecorder(address(permit3)).seen();
        // LENGTH FIRST, and it is the assertion `expectCall` could not make: a prefix
        // match is blind to trailing bytes, which is precisely how an off-by-a-word
        // `total` presents.
        assertEq(actual.length, expected.length, "hand-encoded calldata is the wrong length");
        assertEq(keccak256(actual), keccak256(expected), "hand-encoded calldata differs from solc's");
    }

    /// @dev THE COVERAGE GAP THIS FILE OPENED WITH: two token permits AND two taker
    ///      permits in one batch, with element 0 of each actually used by the fill.
    ///
    ///      Every assertion is on Permit3's own books, so each element is checked at
    ///      its own index: get the `takers` stride wrong and the digest changes (the
    ///      signature fails); get the OFFSET wrong and the second element lands as
    ///      the first. Neither can pass this quietly.
    function test_multiElementArrays_landAtTheRightIndices() public {
        bytes memory itemData = abi.encode(USDC, USDC_IN);
        bytes32 ref = keccak256(itemData);
        bytes32 otherRef = keccak256("some other position");

        Item[] memory items = new Item[](1);
        items[0] =
            Item({op: ItemOp.TAKE, module: address(stash), amount: USDC_IN, recipient: address(0), data: itemData});
        // The maker's USDC input leg is funded by the borrow, not by their wallet.
        Order memory order = _order(maker, 2, USDC, WETH, USDC_IN, WETH_OUT, items);

        deal(USDC, address(stash), USDC_IN); // the "lender" holds what it lends
        deal(WETH, solver, WETH_OUT);
        _approveSolverSide(WETH_OUT, WETH);

        uint48 exp = uint48(_expiry(order));
        IPermit3.TokenPermit[] memory tp = new IPermit3.TokenPermit[](2);
        tp[0] = IPermit3.TokenPermit(address(settlement), USDC, uint160(USDC_IN), exp);
        tp[1] = IPermit3.TokenPermit(address(settlement), WETH, uint160(WETH_OUT), exp); // unused, but encoded
        IPermit3.TakerPermit[] memory tkp = new IPermit3.TakerPermit[](2);
        tkp[0] = IPermit3.TakerPermit(address(settlement), address(stash), ref, uint160(USDC_IN), exp);
        tkp[1] = IPermit3.TakerPermit(address(settlement), address(stash), otherRef, uint160(7), exp);

        IPermit3.PermitBatch memory batch = _buildBatch(tp, tkp, 0, exp);
        bytes memory sig = _signPermitWitness(batch, _hashOrder(order));

        vm.prank(solver);
        settlement.fillWithPermit(order, batch, sig, USDC_IN);

        // The fill itself.
        assertEq(IERC20(WETH).balanceOf(maker), WETH_OUT, "maker received the output leg");
        assertEq(IERC20(USDC).balanceOf(solver), USDC_IN, "solver paid from the borrow proceeds");

        // takers[0] was granted AND spent by the item; takers[1] was granted and left
        // alone — so both elements were decoded at their own offsets.
        (uint160 spent,) = permit3.takerAllowance(maker, address(settlement), address(stash), ref);
        assertEq(spent, 0, "takers[0] granted and consumed");
        (uint160 untouched, uint48 untouchedExp) =
            permit3.takerAllowance(maker, address(settlement), address(stash), otherRef);
        assertEq(untouched, 7, "takers[1] landed at its own index");
        assertEq(untouchedExp, exp, "with its own expiration");

        // Same for the token array's second element, which nothing in the fill spends.
        (uint160 wethCap,) = permit3.tokenAllowance(maker, address(settlement), WETH);
        assertEq(wethCap, uint160(WETH_OUT), "tokens[1] landed at its own index");
    }

    /// @dev A 64-byte EIP-2098 signature exercises the encoder's PADDING branch from
    ///      the other side: 65 bytes needs 31 bytes of zero padding, 64 needs none,
    ///      and a stale word left in scratch memory would corrupt exactly one of the
    ///      two. Both shapes must verify.
    function test_compact64ByteSignature_encodesWithoutPadding() public {
        deal(USDC, maker, USDC_IN);
        deal(WETH, solver, WETH_OUT);
        _approveSolverSide(WETH_OUT, WETH);

        Order memory order = _order(maker, 3, USDC, WETH, USDC_IN, WETH_OUT, new Item[](0));
        uint48 exp = uint48(_expiry(order));
        IPermit3.TokenPermit[] memory tp = new IPermit3.TokenPermit[](1);
        tp[0] = IPermit3.TokenPermit(address(settlement), USDC, uint160(USDC_IN), exp);
        IPermit3.PermitBatch memory batch = _buildBatch(tp, _noTakerPermits(), 0, exp);

        bytes memory long = _signPermitWitness(batch, _hashOrder(order));
        assertEq(long.length, 65, "the reference signature is 65 bytes");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(long, 0x20))
            s := mload(add(long, 0x40))
            v := byte(0, mload(add(long, 0x60)))
        }
        bytes memory compact = abi.encodePacked(r, bytes32(uint256(s) | (uint256(v - 27) << 255)));
        assertEq(compact.length, 64, "compact signature is 64 bytes");

        vm.prank(solver);
        settlement.fillWithPermit(order, batch, compact, USDC_IN);

        assertEq(IERC20(WETH).balanceOf(maker), WETH_OUT, "settled on a 64-byte signature");
    }

    /// @dev And the failure direction still reverts through the same path: Permit3's
    ///      revert must bubble verbatim, not be swallowed by the low-level call.
    function test_badSignature_bubblesPermit3sRevert() public {
        deal(USDC, maker, USDC_IN);
        deal(WETH, solver, WETH_OUT);
        _approveSolverSide(WETH_OUT, WETH);

        Order memory order = _order(maker, 4, USDC, WETH, USDC_IN, WETH_OUT, new Item[](0));
        uint48 exp = uint48(_expiry(order));
        IPermit3.TokenPermit[] memory tp = new IPermit3.TokenPermit[](1);
        tp[0] = IPermit3.TokenPermit(address(settlement), USDC, uint160(USDC_IN), exp);
        IPermit3.PermitBatch memory batch = _buildBatch(tp, _noTakerPermits(), 0, exp);
        // A perfectly valid signature — over a DIFFERENT witness, so the digest the
        // hand-built calldata makes Permit3 compute cannot match it.
        bytes memory sig = _signPermitWitness(batch, keccak256("not this order"));

        vm.prank(solver);
        vm.expectRevert();
        settlement.fillWithPermit(order, batch, sig, USDC_IN);
    }

    // ──────────────────── The shapes the file opened without ────────────────────

    /// @dev EMPTY `tokens`, NON-EMPTY `takers`. The asymmetric case, and the one the
    ///      offset math is most likely to get wrong: `takers`' offset is written as
    ///      `0xa0 + tokBytes`, so with `tokBytes == 0` the two arrays' tails start at
    ///      the same word and a stride bug has nowhere to hide. Every other test in
    ///      this file has at least one token permit, so this branch was unexercised.
    ///
    ///      The fill needs no token permit at all: the maker's USDC input leg is
    ///      funded entirely by the TAKE item's proceeds, so nothing is pulled from
    ///      their wallet.
    function test_emptyTokensWithTakers_landAtTheRightIndices() public {
        bytes memory itemData = abi.encode(USDC, USDC_IN);
        bytes32 ref = keccak256(itemData);
        bytes32 otherRef = keccak256("a second position");

        Item[] memory items = new Item[](1);
        items[0] =
            Item({op: ItemOp.TAKE, module: address(stash), amount: USDC_IN, recipient: address(0), data: itemData});
        Order memory order = _order(maker, 5, USDC, WETH, USDC_IN, WETH_OUT, items);

        deal(USDC, address(stash), USDC_IN);
        deal(WETH, solver, WETH_OUT);
        _approveSolverSide(WETH_OUT, WETH);

        uint48 exp = uint48(_expiry(order));
        IPermit3.TakerPermit[] memory tkp = new IPermit3.TakerPermit[](2);
        tkp[0] = IPermit3.TakerPermit(address(settlement), address(stash), ref, uint160(USDC_IN), exp);
        tkp[1] = IPermit3.TakerPermit(address(settlement), address(stash), otherRef, uint160(11), exp);

        IPermit3.PermitBatch memory batch = _buildBatch(new IPermit3.TokenPermit[](0), tkp, 0, exp);
        bytes memory sig = _signPermitWitness(batch, _hashOrder(order));

        vm.prank(solver);
        settlement.fillWithPermit(order, batch, sig, USDC_IN);

        assertEq(IERC20(WETH).balanceOf(maker), WETH_OUT, "settled with no token permits at all");
        (uint160 spent,) = permit3.takerAllowance(maker, address(settlement), address(stash), ref);
        assertEq(spent, 0, "takers[0] granted and consumed");
        (uint160 untouched,) = permit3.takerAllowance(maker, address(settlement), address(stash), otherRef);
        assertEq(untouched, 11, "takers[1] landed at its own index with tokBytes == 0");
    }

    /// @dev A signature FAR longer than 65 bytes, from a contract maker — the shape a
    ///      Safe's dynamic part or a passkey blob has. Two things only this reaches:
    ///      `calldatacopy` over a multi-word `sig` tail, and the trailing zero-word
    ///      write at a length whose residue mod 32 is neither 0 (the 64-byte case) nor
    ///      1 (the 65-byte one). A stale word left in scratch memory past the copy
    ///      changes the bytes Permit3 hashes, so it fails as a signature error.
    function test_longContractSignature_encodesTheTailAndItsPadding() public {
        PaddedSigWallet wallet = new PaddedSigWallet(maker);
        vm.label(address(wallet), "paddedSigWallet");

        deal(USDC, address(wallet), USDC_IN);
        wallet.approveMax(USDC, address(permit3));
        deal(WETH, solver, WETH_OUT);
        _approveSolverSide(WETH_OUT, WETH);

        Order memory order = _order(address(wallet), 6, USDC, WETH, USDC_IN, WETH_OUT, new Item[](0));
        uint48 exp = uint48(_expiry(order));
        IPermit3.TokenPermit[] memory tp = new IPermit3.TokenPermit[](1);
        tp[0] = IPermit3.TokenPermit(address(settlement), USDC, uint160(USDC_IN), exp);
        IPermit3.PermitBatch memory batch = _buildBatch(tp, _noTakerPermits(), 0, exp);

        // 65 real bytes + 35 of opaque trailer = 100, which pads to 128: the zeroing
        // word lands mid-tail rather than at either end.
        bytes memory sig = bytes.concat(_signPermitWitness(batch, _hashOrder(order)), new bytes(35));
        assertEq(sig.length, 100, "a genuinely multi-word signature");

        vm.prank(solver);
        settlement.fillWithPermit(order, batch, sig, USDC_IN);

        assertEq(IERC20(WETH).balanceOf(address(wallet)), WETH_OUT, "settled on a 100-byte 1271 signature");
    }

    /// @dev THE PROPERTY THE ENCODER IS WRITTEN FIELD-BY-FIELD FOR, and the one thing
    ///      a `calldatacopy` of the whole `batch` region could not provide.
    ///
    ///      ABI offsets are CALLER-controlled, and solc's decoder accepts layouts that
    ///      are not canonical — here, a 32-byte gap between the `order` tail and the
    ///      `batch` tail, with the head offsets moved to match. A verbatim copy would
    ///      forward those bytes and Permit3 would hash something other than what the
    ///      settler decoded; rebuilding from the decoded `.offset`/`.length` cannot,
    ///      because the canonical form is a function of the VALUES, not the layout.
    ///
    ///      The signature is over the canonical batch, so this passing IS the proof:
    ///      the digest Permit3 computed from our re-encoded bytes matched a signature
    ///      made without any knowledge of the wire layout.
    function test_nonCanonicalCalldata_reEncodesFromTheDecodedValues() public {
        bytes32 ref = keccak256(abi.encode(USDC, USDC_IN));
        Order memory order;
        {
            Item[] memory items = new Item[](1);
            items[0] = Item({
                op: ItemOp.TAKE,
                module: address(stash),
                amount: USDC_IN,
                recipient: address(0),
                data: abi.encode(USDC, USDC_IN)
            });
            order = _order(maker, 7, USDC, WETH, USDC_IN, WETH_OUT, items);
        }

        deal(USDC, address(stash), USDC_IN);
        deal(WETH, solver, WETH_OUT);
        _approveSolverSide(WETH_OUT, WETH);

        IPermit3.PermitBatch memory batch;
        {
            uint48 exp = uint48(_expiry(order));
            IPermit3.TokenPermit[] memory tp = new IPermit3.TokenPermit[](1);
            tp[0] = IPermit3.TokenPermit(address(settlement), USDC, uint160(USDC_IN), exp);
            IPermit3.TakerPermit[] memory tkp = new IPermit3.TakerPermit[](1);
            tkp[0] = IPermit3.TakerPermit(address(settlement), address(stash), ref, uint160(USDC_IN), exp);
            batch = _buildBatch(tp, tkp, 0, exp);
        }

        // The encode / splice / call lives in its own frame: three `bytes` locals plus
        // the success flag do not fit alongside the order and the batch under the
        // legacy (non-via-IR) codegen this suite builds with.
        _fillThroughASplicedCalldata(order, batch, _signPermitWitness(batch, _hashOrder(order)));

        assertEq(IERC20(WETH).balanceOf(maker), WETH_OUT, "maker received the output leg");
        (uint160 spent,) = permit3.takerAllowance(maker, address(settlement), address(stash), ref);
        assertEq(spent, 0, "the taker permit landed and was consumed");
    }

    /// @dev Encode the fill canonically, make it non-canonical, and send it.
    function _fillThroughASplicedCalldata(
        Order memory order,
        IPermit3.PermitBatch memory batch,
        bytes memory sig
    ) private {
        bytes memory cd = abi.encodeCall(IFillWithPermit.fillWithPermit, (order, batch, sig, USDC_IN));
        bytes memory spliced = _withGapInsideBatch(cd);
        // Without this the test would pass on a splice that did nothing at all.
        assertEq(spliced.length, cd.length + 32, "the layout really is non-canonical");

        vm.prank(solver);
        (bool ok,) = address(settlement).call(spliced);
        assertTrue(ok, "a non-canonical but valid encoding still settles");
    }

    // ──────────────────── Calldata surgery for the test above ────────────────────

    /// @dev Splice 32 bytes of junk INSIDE the `batch` region — between the `tokens`
    ///      tail and the `takers` tail — and move the one offset word that points past
    ///      it, plus the outer `sig` offset. The call decodes to identical VALUES from
    ///      a layout no encoder would emit.
    ///
    ///      ⚠ INSIDE, NOT BEFORE, AND THAT IS THE WHOLE POINT. A gap placed ahead of
    ///      the batch region moves where the region starts but leaves the region itself
    ///      canonical — a verbatim `calldatacopy(batch.offset, batchLen)` would copy
    ///      exactly the right bytes and such a test would pass against the very
    ///      implementation it is supposed to reject. Putting the gap between the two
    ///      array tails is what makes the copy and the re-encode disagree: a copy
    ///      forwards the junk and shifts `takers` by a word, so Permit3 hashes
    ///      something the maker never signed and the signature fails.
    ///
    ///      Junk is 0xff rather than zeros for the same reason — zeros are
    ///      indistinguishable from ABI padding and could verify by luck.
    function _withGapInsideBatch(bytes memory cd) internal returns (bytes memory out) {
        uint256 batchOff;
        uint256 takersOff;
        assembly {
            // Head word i of the call lives at data-index `4 + 32*i`; word 1 is `batch`.
            batchOff := mload(add(cd, 0x44))
            // Inside the batch tuple, word 1 is the `takers` array offset, relative to
            // the tuple's own start.
            takersOff := mload(add(cd, add(0x44, batchOff)))
        }
        uint256 cut = 4 + batchOff + takersOff; // absolute index of the `takers` tail
        bytes memory junk = new bytes(32);
        for (uint256 k; k < 32; ++k) {
            junk[k] = 0xff;
        }
        out = bytes.concat(_slice(cd, 0, cut), junk, _slice(cd, cut, cd.length - cut));
        assembly {
            // `takers` now sits a word later, relative to the tuple start...
            mstore(add(out, add(0x44, batchOff)), add(takersOff, 0x20))
            // ...and `sig`, whose tail follows the whole batch, a word later too.
            // (`batch`'s own offset is unchanged: the gap is inside it, not before it.)
            mstore(add(out, 0x64), add(mload(add(out, 0x64)), 0x20))
        }
        // THE ASSERTION THAT MAKES THIS TEST ABLE TO FAIL. The junk has to land inside
        // the byte range a verbatim `calldatacopy(batch.offset, batchLen)` would
        // forward — past the tuple's start, not merely somewhere in the calldata — or
        // the copy and the re-encode would agree and the fill below would prove
        // nothing about either.
        assertGt(cut, 4 + batchOff, "the gap is inside the batch region, not before it");
        assertEq(uint8(out[cut]), 0xff, "junk landed at the takers tail");
    }

    function _slice(bytes memory b, uint256 start, uint256 len) internal pure returns (bytes memory r) {
        r = new bytes(len);
        for (uint256 i; i < len; ++i) {
            r[i] = b[start + i];
        }
    }
}
