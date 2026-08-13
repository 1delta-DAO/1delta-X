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
import {PackedEncode} from "./shared/PackedEncode.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";

/// @dev DIFFERENTIAL guard for {OrderHash.hash}, which is hand-rolled assembly —
///      bulk `calldatacopy` of the static runs plus a scoped per-blob keccak — on the
///      path that decides whether a maker's signature authorizes a fill.
///      {HashGoldenTest} pins ONE canonical order against a committed constant; this
///      pins the whole function against a plain-`abi.encode` REFERENCE over fuzzed
///      shapes: every array-length combination including empty, every field varying.
///
///      This pair is what made it safe to try three different encodings of `hash`
///      and know each produced a byte-identical digest.
contract HashDifferentialTest is Test {
    SettlementLens lens;

    function setUp() public {
        Permit3 permit3 = new Permit3();
        Settlement settlement = new Settlement(address(permit3));
        lens = new SettlementLens(address(settlement));
    }

    // ──────────────────── Reference implementation ────────────────────
    //
    // Under the PACKED encoding every dynamic member is a `bytes` blob, so EIP-712
    // pre-hashes it with a single `keccak256`. The reference below is therefore the
    // naive, obviously-correct spelling of that: `abi.encode` the 18 words and hash.
    // If {OrderHash.hash}'s hand-rolled buffer ever disagrees, the assembly is wrong.
    //
    // NOTE: the old address-padding test is GONE ON PURPOSE. It guarded the typed
    // encoding, where a 20-byte address sat in a 32-byte ABI word and dirty padding
    // could reach the digest unless masked. A packed blob stores the raw 20 bytes with
    // no padding at all, so that class of divergence is now structurally impossible.

    bytes32 constant ORDER_TH = keccak256(
        "Order(address maker,uint256 nonce,uint256 deadline,bytes legsIn,bytes legsOut,uint256 timing,address exclusiveFiller,uint256 minFillAnchor,uint256 params,bytes curve,bytes items,bytes validators,bytes invariants,address fillModule,uint256 fillTotal,address pricingModule)"
    );

    /// @dev Chunked only to stay under the stack limit; all 16 members are static
    ///      words so the concatenation is byte-identical to one 16-arg `abi.encode`.
    function _refHash(Order memory o) private pure returns (bytes32) {
        bytes memory p1 = abi.encode(ORDER_TH, o.maker, o.nonce, o.deadline, keccak256(o.legsIn), keccak256(o.legsOut));
        bytes memory p2 = abi.encode(o.timing, o.exclusiveFiller, o.minFillAnchor, o.params, keccak256(o.curve));
        bytes memory p3 = abi.encode(
            keccak256(o.items),
            keccak256(o.validators),
            keccak256(o.invariants),
            o.fillModule,
            o.fillTotal,
            o.pricingModule
        );
        return keccak256(bytes.concat(p1, p2, p3));
    }

    // ──────────────────── Fuzzed order construction ────────────────────

    /// @dev Array lengths are drawn 0..3 so EVERY shape — including all-empty, which
    ///      is the assembly's zero-length edge case — is reachable.
    function _build(uint256 seed, uint8 lens_) private pure returns (Order memory o) {
        o.maker = address(uint160(uint256(keccak256(abi.encode(seed, "maker")))));

        o.nonce = uint256(keccak256(abi.encode(seed, "nonce")));
        o.deadline = uint256(keccak256(abi.encode(seed, "deadline")));
        o.timing = uint256(keccak256(abi.encode(seed, "timing")));
        o.exclusiveFiller = address(uint160(uint256(keccak256(abi.encode(seed, "excl")))));
        o.minFillAnchor = uint256(keccak256(abi.encode(seed, "minfill")));
        o.params = uint256(keccak256(abi.encode(seed, "params")));
        o.pricingModule = address(uint160(uint256(keccak256(abi.encode(seed, "pmod")))));
        o.fillModule = address(uint160(uint256(keccak256(abi.encode(seed, "fmod")))));
        o.fillTotal = uint256(keccak256(abi.encode(seed, "ftotal")));

        LegIn[] memory li = new LegIn[](lens_ & 3);
        for (uint256 i; i < li.length; i++) {
            li[i] = LegIn({
                token: address(uint160(uint256(keccak256(abi.encode(seed, "li", i))))),
                start: uint256(keccak256(abi.encode(seed, "lis", i))),
                end: uint256(keccak256(abi.encode(seed, "lie", i)))
            });
        }

        o.legsIn = PackedEncode.legsIn(li);
        LegOut[] memory lo = new LegOut[]((lens_ >> 2) & 3);
        for (uint256 i; i < lo.length; i++) {
            lo[i] = LegOut({
                token: address(uint160(uint256(keccak256(abi.encode(seed, "lo", i))))),
                start: uint256(keccak256(abi.encode(seed, "los", i))),
                end: uint256(keccak256(abi.encode(seed, "loe", i))),
                recipient: address(uint160(uint256(keccak256(abi.encode(seed, "lor", i)))))
            });
        }

        o.legsOut = PackedEncode.legsOut(lo);
        CurvePoint[] memory cv = new CurvePoint[]((lens_ >> 4) & 3);
        for (uint256 i; i < cv.length; i++) {
            cv[i] = CurvePoint({
                timeDelta: uint32(uint256(keccak256(abi.encode(seed, "ct", i)))),
                bumpBps: uint32(uint256(keccak256(abi.encode(seed, "cb", i))))
            });
        }

        o.curve = PackedEncode.curve(cv);
        Item[] memory it = new Item[]((lens_ >> 6) & 3);
        for (uint256 i; i < it.length; i++) {
            // `data` length varies 0..~90 bytes so the dynamic-tail copy is exercised
            // across and beyond a single word.
            it[i] = Item({
                op: ItemOp(uint256(keccak256(abi.encode(seed, "iop", i))) % 3),
                module: address(uint160(uint256(keccak256(abi.encode(seed, "im", i))))),
                amount: uint256(keccak256(abi.encode(seed, "ia", i))),
                recipient: address(uint160(uint256(keccak256(abi.encode(seed, "ir", i))))),
                data: _blob(seed, "idata", i)
            });
        }

        o.items = PackedEncode.items(it);
        Validator[] memory va = new Validator[](lens_ & 3);
        for (uint256 i; i < va.length; i++) {
            va[i] = Validator({
                target: address(uint160(uint256(keccak256(abi.encode(seed, "vt", i))))), data: _blob(seed, "vdata", i)
            });
        }

        o.validators = PackedEncode.validators(va);
        Validator[] memory iv = new Validator[]((lens_ >> 2) & 3);
        for (uint256 i; i < iv.length; i++) {
            iv[i] = Validator({
                target: address(uint160(uint256(keccak256(abi.encode(seed, "nt", i))))), data: _blob(seed, "ndata", i)
            });
        }
        o.invariants = PackedEncode.validators(iv);
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
}

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
        bytes32 hashStruct = keccak256(
            abi.encode(PERMIT_BATCH_TYPEHASH, _refTokens(b.tokens), _refTakers(b.takers), b.nonce, b.deadline)
        );
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
