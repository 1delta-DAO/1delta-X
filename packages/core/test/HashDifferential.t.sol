// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    Settlement,
    Order,
    Item,
    ItemOp,
    Validator,
    LegIn,
    LegOut,
    OrderSide,
    CurvePoint
} from "@core/settlement/Settlement.sol";
import {OrderHash} from "@core/settlement/OrderHash.sol";
import {SettlementLens} from "@core/periphery/SettlementLens.sol";
import {Permit3} from "@core/permit3/Permit3.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";

/// @dev DIFFERENTIAL guard for {OrderHash}. The array-member hashers are hand-rolled
///      assembly (calldata walks for the static structs, scratch-memory encoding for
///      the ones carrying a dynamic `bytes`), on the path that decides whether a
///      maker's signature authorizes a fill. {HashGoldenTest} pins ONE canonical
///      order against a committed constant; this pins the whole function against a
///      plain-`abi.encode` REFERENCE over fuzzed shapes — every array length
///      combination including empty, and every field varying.
///
///      The reference below is deliberately the naive, obviously-correct encoding
///      (the pre-optimization implementation). If the two ever disagree, the
///      assembly is wrong.
contract HashDifferentialTest is Test {
    SettlementLens lens;

    function setUp() public {
        Permit3 permit3 = new Permit3();
        Settlement settlement = new Settlement(address(permit3));
        lens = new SettlementLens(address(settlement));
    }

    // ──────────────────── Reference implementation ────────────────────

    function _refLegsIn(LegIn[] memory legs) private pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](legs.length);
        for (uint256 i; i < legs.length; i++) {
            h[i] = keccak256(abi.encode(OrderHash.LEG_IN_TYPEHASH, legs[i].token, legs[i].start, legs[i].end));
        }
        return keccak256(abi.encodePacked(h));
    }

    function _refLegsOut(LegOut[] memory legs) private pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](legs.length);
        for (uint256 i; i < legs.length; i++) {
            h[i] = keccak256(
                abi.encode(OrderHash.LEG_OUT_TYPEHASH, legs[i].token, legs[i].start, legs[i].end, legs[i].recipient)
            );
        }
        return keccak256(abi.encodePacked(h));
    }

    function _refCurve(CurvePoint[] memory curve) private pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](curve.length);
        for (uint256 i; i < curve.length; i++) {
            h[i] = keccak256(abi.encode(OrderHash.CURVE_POINT_TYPEHASH, curve[i].timeDelta, curve[i].bumpBps));
        }
        return keccak256(abi.encodePacked(h));
    }

    function _refItems(Item[] memory items) private pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](items.length);
        for (uint256 i; i < items.length; i++) {
            h[i] = keccak256(
                abi.encode(
                    OrderHash.ITEM_TYPEHASH,
                    uint8(items[i].op),
                    items[i].module,
                    items[i].amount,
                    items[i].recipient,
                    keccak256(items[i].data)
                )
            );
        }
        return keccak256(abi.encodePacked(h));
    }

    function _refValidators(Validator[] memory vs) private pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](vs.length);
        for (uint256 i; i < vs.length; i++) {
            h[i] = keccak256(abi.encode(OrderHash.VALIDATOR_TYPEHASH, vs[i].target, keccak256(vs[i].data)));
        }
        return keccak256(abi.encodePacked(h));
    }

    /// @dev Split into three chunks purely to stay under the stack limit without
    ///      via-IR. Every one of the 19 members is a STATIC word, so each `abi.encode`
    ///      is a flat run and concatenating them is byte-identical to encoding all 19
    ///      in one call.
    function _refHash(Order memory o) private pure returns (bytes32) {
        bytes memory p1 = abi.encode(
            OrderHash.ORDER_TYPEHASH,
            o.maker,
            uint8(o.side),
            o.nonce,
            o.deadline,
            _refLegsIn(o.legsIn),
            _refLegsOut(o.legsOut)
        );
        bytes memory p2 = abi.encode(
            o.timing,
            o.exclusiveFiller,
            o.minFillAnchor,
            o.exclusivityOverrideBps,
            _refCurve(o.curve),
            o.gasBumpBps,
            o.gasPriceRef
        );
        bytes memory p3 = abi.encode(
            _refItems(o.items), _refValidators(o.validators), _refValidators(o.invariants), o.fillModule, o.fillTotal
        );
        return keccak256(bytes.concat(p1, p2, p3));
    }

    // ──────────────────── Fuzzed order construction ────────────────────

    /// @dev Array lengths are drawn 0..3 so EVERY shape — including all-empty, which
    ///      is the assembly's zero-length edge case — is reachable.
    function _build(uint256 seed, uint8 lens_) private pure returns (Order memory o) {
        o.maker = address(uint160(uint256(keccak256(abi.encode(seed, "maker")))));
        o.side = seed % 2 == 0 ? OrderSide.SELL : OrderSide.BUY;
        o.nonce = uint256(keccak256(abi.encode(seed, "nonce")));
        o.deadline = uint256(keccak256(abi.encode(seed, "deadline")));
        o.timing = uint256(keccak256(abi.encode(seed, "timing")));
        o.exclusiveFiller = address(uint160(uint256(keccak256(abi.encode(seed, "excl")))));
        o.minFillAnchor = uint256(keccak256(abi.encode(seed, "minfill")));
        o.exclusivityOverrideBps = uint256(keccak256(abi.encode(seed, "bps")));
        o.gasBumpBps = uint256(keccak256(abi.encode(seed, "gbump")));
        o.gasPriceRef = uint256(keccak256(abi.encode(seed, "gref")));
        o.fillModule = address(uint160(uint256(keccak256(abi.encode(seed, "fmod")))));
        o.fillTotal = uint256(keccak256(abi.encode(seed, "ftotal")));

        o.legsIn = new LegIn[](lens_ & 3);
        for (uint256 i; i < o.legsIn.length; i++) {
            o.legsIn[i] = LegIn({
                token: address(uint160(uint256(keccak256(abi.encode(seed, "li", i))))),
                start: uint256(keccak256(abi.encode(seed, "lis", i))),
                end: uint256(keccak256(abi.encode(seed, "lie", i)))
            });
        }

        o.legsOut = new LegOut[]((lens_ >> 2) & 3);
        for (uint256 i; i < o.legsOut.length; i++) {
            o.legsOut[i] = LegOut({
                token: address(uint160(uint256(keccak256(abi.encode(seed, "lo", i))))),
                start: uint256(keccak256(abi.encode(seed, "los", i))),
                end: uint256(keccak256(abi.encode(seed, "loe", i))),
                recipient: address(uint160(uint256(keccak256(abi.encode(seed, "lor", i)))))
            });
        }

        o.curve = new CurvePoint[]((lens_ >> 4) & 3);
        for (uint256 i; i < o.curve.length; i++) {
            o.curve[i] = CurvePoint({
                timeDelta: uint32(uint256(keccak256(abi.encode(seed, "ct", i)))),
                bumpBps: uint32(uint256(keccak256(abi.encode(seed, "cb", i))))
            });
        }

        o.items = new Item[]((lens_ >> 6) & 3);
        for (uint256 i; i < o.items.length; i++) {
            // `data` length varies 0..~90 bytes so the dynamic-tail copy is exercised
            // across and beyond a single word.
            o.items[i] = Item({
                op: ItemOp(uint256(keccak256(abi.encode(seed, "iop", i))) % 3),
                module: address(uint160(uint256(keccak256(abi.encode(seed, "im", i))))),
                amount: uint256(keccak256(abi.encode(seed, "ia", i))),
                recipient: address(uint160(uint256(keccak256(abi.encode(seed, "ir", i))))),
                data: _blob(seed, "idata", i)
            });
        }

        o.validators = new Validator[](lens_ & 3);
        for (uint256 i; i < o.validators.length; i++) {
            o.validators[i] = Validator({
                target: address(uint160(uint256(keccak256(abi.encode(seed, "vt", i))))),
                data: _blob(seed, "vdata", i)
            });
        }

        o.invariants = new Validator[]((lens_ >> 2) & 3);
        for (uint256 i; i < o.invariants.length; i++) {
            o.invariants[i] = Validator({
                target: address(uint160(uint256(keccak256(abi.encode(seed, "nt", i))))),
                data: _blob(seed, "ndata", i)
            });
        }
    }

    function _blob(uint256 seed, string memory tag, uint256 i) private pure returns (bytes memory b) {
        uint256 n = uint256(keccak256(abi.encode(seed, tag, i, "len"))) % 91;
        b = new bytes(n);
        for (uint256 k; k < n; k++) {
            b[k] = bytes1(uint8(uint256(keccak256(abi.encode(seed, tag, i, k)))));
        }
    }

    // ──────────────────── Tests ────────────────────

    function testFuzz_hashMatchesReference(uint256 seed, uint8 lens_) public view {
        Order memory o = _build(seed, lens_);
        assertEq(lens.hashOrder(o), _refHash(o), "assembly hash diverged from abi.encode reference");
    }

    /// @dev The all-empty shape: every array-member hasher takes its zero-length path
    ///      (`keccak256` over a zero-length run == `keccak256("")`).
    function test_hashMatchesReference_allArraysEmpty() public view {
        Order memory o;
        o.maker = address(0xA1);
        o.nonce = 7;
        assertEq(lens.hashOrder(o), _refHash(o));
    }

    /// @dev The property the calldata-walking hashers must preserve: `abi.encode`
    ///      MASKS an address's upper 12 bytes, so a caller supplying dirty padding
    ///      must not be able to steer the digest. A blind `calldatacopy` of the
    ///      static-struct words would fail this; the explicit mask is why it passes.
    ///
    ///      Load-bearing for COMPATIBILITY rather than for safety: an unmasked hash
    ///      is not exploitable (a digest the maker never signed authorizes nothing,
    ///      and the fill reads every field back through Solidity, so hash and
    ///      execution cannot disagree) — but it would make the on-chain hash depend on
    ///      padding a well-formed encoder never varies, diverging from the maker's and
    ///      the SDK's computation and rendering the order unfillable.
    function test_dirtyAddressPadding_doesNotChangeHash() public {
        Order memory o;
        o.maker = address(0xA1);
        o.legsIn = new LegIn[](1);
        o.legsIn[0] = LegIn({token: address(0xBEEF), start: 1e18, end: 0});
        o.legsOut = new LegOut[](1);
        o.legsOut[0] = LegOut({token: address(0xCAFE), start: 2e18, end: 0, recipient: address(0xD00D)});

        bytes32 clean = lens.hashOrder(o);

        // Re-encode the call and set the top bits of every word that holds one of the
        // order's address fields — i.e. exactly the words the calldata walk reads.
        bytes memory cd = abi.encodeCall(SettlementLens.hashOrder, (o));
        uint256 tampered = _setHighBitsOnWordsEqualTo(cd, uint256(uint160(address(0xBEEF))));
        tampered += _setHighBitsOnWordsEqualTo(cd, uint256(uint160(address(0xCAFE))));
        tampered += _setHighBitsOnWordsEqualTo(cd, uint256(uint160(address(0xD00D))));
        assertGt(tampered, 0, "test did not actually tamper any address word");

        (bool ok, bytes memory ret) = address(lens).staticcall(cd);
        // Either the ABI decoder rejects the dirty word outright, or the hash is
        // computed and must equal the clean one. Both are safe; a DIFFERENT hash is
        // not, and is what this asserts against.
        if (ok) {
            assertEq(abi.decode(ret, (bytes32)), clean, "dirty address padding changed the order hash");
        }
    }

    /// @dev OR `0xff…` into the top 12 bytes of every 32-byte word of `cd` whose
    ///      value equals `needle`. Returns how many words were touched.
    function _setHighBitsOnWordsEqualTo(bytes memory cd, uint256 needle) private pure returns (uint256 n) {
        // Start at 4 (past the selector); words are 32-byte aligned from there.
        for (uint256 off = 4; off + 32 <= cd.length; off += 32) {
            uint256 w;
            assembly {
                w := mload(add(add(cd, 0x20), off))
            }
            if (w == needle) {
                uint256 dirty = w | (type(uint256).max << 160);
                assembly {
                    mstore(add(add(cd, 0x20), off), dirty)
                }
                n++;
            }
        }
    }
}

/// @dev DIFFERENTIAL guard for {Permit3}'s permit-array hashers, which use the same
///      static-struct calldata walk as {OrderHash}'s leg hashers and sit on the same
///      kind of path — the digest a maker signs to hand out allowances.
///
///      `_hashTokenPermits` / `_hashTakerPermits` are private, so this asserts the
///      equivalence END-TO-END and in the direction that matters: the digest is
///      rebuilt here from a plain-`abi.encode` reference, SIGNED, and handed to
///      `permitBatch`. If the contract's assembly computed anything other than the
///      reference, the recovered signer would not match and the call would revert.
///      The EIP-712 type strings are re-declared rather than imported, so this also
///      pins them.
contract Permit3HashDifferentialTest is Test {
    Permit3 permit3;

    uint256 constant OWNER_PK = 0xA11CE;
    address owner;

    bytes32 constant TOKEN_PERMIT_TYPEHASH =
        keccak256("TokenPermit(address spender,address token,uint160 amount,uint48 expiration)");
    bytes32 constant TAKER_PERMIT_TYPEHASH =
        keccak256("TakerPermit(address spender,bytes32 ref,uint160 amount,uint48 expiration)");
    bytes32 constant PERMIT_BATCH_TYPEHASH = keccak256(
        "PermitBatch(TokenPermit[] tokens,TakerPermit[] takers,uint256 nonce,uint256 deadline)"
        "TakerPermit(address spender,bytes32 ref,uint160 amount,uint48 expiration)"
        "TokenPermit(address spender,address token,uint160 amount,uint48 expiration)"
    );

    function setUp() public {
        permit3 = new Permit3();
        owner = vm.addr(OWNER_PK);
    }

    // ──────────────────── Reference implementation ────────────────────

    function _refTokens(IPermit3.TokenPermit[] memory ps) private pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](ps.length);
        for (uint256 i; i < ps.length; i++) {
            h[i] = keccak256(
                abi.encode(TOKEN_PERMIT_TYPEHASH, ps[i].spender, ps[i].token, ps[i].amount, ps[i].expiration)
            );
        }
        return keccak256(abi.encodePacked(h));
    }

    function _refTakers(IPermit3.TakerPermit[] memory ps) private pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](ps.length);
        for (uint256 i; i < ps.length; i++) {
            h[i] =
                keccak256(abi.encode(TAKER_PERMIT_TYPEHASH, ps[i].spender, ps[i].ref, ps[i].amount, ps[i].expiration));
        }
        return keccak256(abi.encodePacked(h));
    }

    function _refDigest(IPermit3.PermitBatch memory b) private view returns (bytes32) {
        bytes32 hashStruct =
            keccak256(abi.encode(PERMIT_BATCH_TYPEHASH, _refTokens(b.tokens), _refTakers(b.takers), b.nonce, b.deadline));
        return keccak256(abi.encodePacked("\x19\x01", permit3.DOMAIN_SEPARATOR(), hashStruct));
    }

    // ──────────────────── Tests ────────────────────

    /// @dev Array lengths are drawn 0..3 so every shape — including both-empty, the
    ///      assembly's zero-length path — is reachable.
    function testFuzz_permitBatchAcceptsReferenceDigest(uint256 seed, uint8 lens_, uint256 nonce) public {
        IPermit3.PermitBatch memory b;
        b.nonce = nonce;
        b.deadline = block.timestamp + 1 days;

        b.tokens = new IPermit3.TokenPermit[](lens_ & 3);
        for (uint256 i; i < b.tokens.length; i++) {
            b.tokens[i] = IPermit3.TokenPermit({
                spender: address(uint160(uint256(keccak256(abi.encode(seed, "ts", i))))),
                token: address(uint160(uint256(keccak256(abi.encode(seed, "tt", i))))),
                amount: uint160(uint256(keccak256(abi.encode(seed, "ta", i)))),
                expiration: uint48(uint256(keccak256(abi.encode(seed, "te", i))))
            });
        }

        b.takers = new IPermit3.TakerPermit[]((lens_ >> 2) & 3);
        for (uint256 i; i < b.takers.length; i++) {
            b.takers[i] = IPermit3.TakerPermit({
                spender: address(uint160(uint256(keccak256(abi.encode(seed, "ks", i))))),
                ref: keccak256(abi.encode(seed, "kr", i)),
                amount: uint160(uint256(keccak256(abi.encode(seed, "ka", i)))),
                expiration: uint48(uint256(keccak256(abi.encode(seed, "ke", i))))
            });
        }

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, _refDigest(b));
        // Reverts (InvalidSigner) iff the contract's hashers diverge from the reference.
        permit3.permitBatch(owner, b, abi.encodePacked(r, s, v));

        // And the allowances the reference-signed batch authorized really landed.
        for (uint256 i; i < b.tokens.length; i++) {
            (uint160 amt,,) = permit3.tokenAllowance(owner, b.tokens[i].spender, b.tokens[i].token);
            assertEq(amt, b.tokens[i].amount, "token allowance not applied");
        }
        for (uint256 i; i < b.takers.length; i++) {
            (uint160 amt,,) = permit3.takerAllowance(owner, b.takers[i].spender, b.takers[i].ref);
            assertEq(amt, b.takers[i].amount, "taker allowance not applied");
        }
    }

    /// @dev Both arrays empty — each hasher's zero-length path.
    function test_permitBatch_bothArraysEmpty() public {
        IPermit3.PermitBatch memory b;
        b.nonce = 1;
        b.deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, _refDigest(b));
        permit3.permitBatch(owner, b, abi.encodePacked(r, s, v));
        assertTrue(permit3.isPermitNonceUsed(owner, 1));
    }
}
