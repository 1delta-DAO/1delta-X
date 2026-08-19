// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "@coretest/shared/PackedEncode.sol";

import {Order, LegOut} from "@core/settlement/Settlement.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";

import {AcrossBridgeOutModule} from "../src/out/AcrossBridgeOutModule.sol";
import {PositionFunnel} from "../src/funnel/PositionFunnel.sol";
import {PositionFunnelFactory} from "../src/funnel/PositionFunnelFactory.sol";
import {FunnelGrantModule} from "../src/funnel/FunnelGrantModule.sol";
import {BridgeTestBase} from "./shared/BridgeTestBase.t.sol";

/// @title CrossChainRootTest
/// @notice ONE owner signature authorising work on TWO chains.
///
///         The source order and the destination order are leaves of one Merkle
///         tree; the owner signs `OrderRoot(bytes32 root)` once, under the SOURCE
///         chain's Settlement domain. Two different verifiers then accept the same
///         signature:
///
///           • source chain — Settlement's EXISTING `0xB0` bulk-order envelope,
///             unchanged. This is the half that needs no new code, and these tests
///             are what proves that claim rather than asserting it.
///           • destination chain — {PositionFunnel.isValidSignature}'s new `0xB1`
///             cross-chain envelope, which additionally carries the source
///             `(chainId, settlement)` so it can rebuild that domain.
///
///         The bridge carries NO message on this path, and nothing here depends on
///         one: the order travels off-chain to a solver, authorisation is the
///         owner's signature, and availability is the funnel's balance.
contract CrossChainRootTest is BridgeTestBase {
    PositionFunnelFactory factory;
    FunnelGrantModule grantModule;
    PositionFunnel funnel;

    bytes32 constant USER_SALT = bytes32(uint256(1));

    uint256 constant PAY = 500e18;
    uint256 constant BRIDGE = 100e18;
    uint16 constant RELAY_FEE_BPS = 100;
    uint256 constant DELIVERED = BRIDGE - (BRIDGE * RELAY_FEE_BPS) / 10_000;
    uint256 constant OUT_AMOUNT = 300e18;

    bytes32 constant DOMAIN_TH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 constant ORDER_ROOT_TH = keccak256("OrderRoot(bytes32 root)");
    bytes32 constant CALL_TH = keccak256("Call(address target,uint256 value,bytes data)");
    bytes32 constant EXEC_TH = keccak256(
        "ExecuteBatch(Call[] calls,uint256 nonce,uint256 deadline)Call(address target,uint256 value,bytes data)"
    );

    function setUp() public virtual override {
        super.setUp();
        grantModule = new FunnelGrantModule(address(settlement));
        factory = new PositionFunnelFactory(address(permit3), address(settlement), address(lens), address(grantModule));
        funnel = PositionFunnel(payable(factory.funnelFor(maker, USER_SALT)));
        vm.label(address(funnel), "funnel");
    }

    // ──────────────────── Tree / envelope builders ────────────────────

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    /// @dev Settlement's domain on an arbitrary chain. Every contract here lives at
    ///      the same address on both, so `chainId` is the only difference — which is
    ///      exactly the property these tests lean on.
    function _settlementDomain(uint256 chainId) internal view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TH, keccak256("Settlement"), keccak256("1"), chainId, address(settlement)));
    }

    function _funnelDomain(uint256 chainId) internal view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TH, keccak256("PositionFunnel"), keccak256("1"), chainId, address(funnel)));
    }

    /// @dev The leaf Settlement folds on the SOURCE chain: the order STRUCT hash,
    ///      not a digest — the root's own domain is what binds it there.
    function _srcLeaf(Order memory o) internal pure returns (bytes32) {
        return _hashOrder(o);
    }

    /// @dev The leaf the funnel folds on the DESTINATION chain: the full `0x1901`
    ///      digest Settlement handed to `isValidSignature`. This is where the chain
    ///      binding lives on that side, since the root's domain is caller-named.
    function _dstLeaf(Order memory o, uint256 chainId) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", _settlementDomain(chainId), _hashOrder(o)));
    }

    function _execLeaf(PositionFunnel.Call[] memory calls, uint256 nonce, uint256 deadline, uint256 chainId)
        internal
        view
        returns (bytes32)
    {
        bytes32[] memory h = new bytes32[](calls.length);
        for (uint256 i; i < calls.length; i++) {
            h[i] = keccak256(abi.encode(CALL_TH, calls[i].target, calls[i].value, keccak256(calls[i].data)));
        }
        bytes32 structHash = keccak256(abi.encode(EXEC_TH, keccak256(abi.encodePacked(h)), nonce, deadline));
        return keccak256(abi.encodePacked(hex"1901", _funnelDomain(chainId), structHash));
    }

    /// @dev The ONE signature. `OrderRoot(root)` under the SOURCE Settlement domain —
    ///      which is precisely what Settlement's own bulk path already verifies.
    function _signRoot(bytes32 root, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = keccak256(
            abi.encodePacked(hex"1901", _settlementDomain(SRC_CHAIN), keccak256(abi.encode(ORDER_ROOT_TH, root)))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Source-chain envelope — Settlement's existing shape, untouched.
    function _bulkEnvelope(bytes memory sig, bytes32[] memory proof) internal pure returns (bytes memory e) {
        e = sig;
        for (uint256 i; i < proof.length; i++) {
            e = bytes.concat(e, proof[i]);
        }
        e = bytes.concat(e, bytes1(0xB0));
    }

    /// @dev Destination-chain envelope — the new one.
    function _crossEnvelope(bytes memory sig, bytes32[] memory proof, uint256 srcChainId, address srcSettlement)
        internal
        pure
        returns (bytes memory e)
    {
        e = sig;
        for (uint256 i; i < proof.length; i++) {
            e = bytes.concat(e, proof[i]);
        }
        e = bytes.concat(e, bytes32(srcChainId), bytes20(srcSettlement), bytes1(0xB1));
    }

    function _one(bytes32 a) internal pure returns (bytes32[] memory p) {
        p = new bytes32[](1);
        p[0] = a;
    }

    function _two(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory p) {
        p = new bytes32[](2);
        p[0] = a;
        p[1] = b;
    }

    // ──────────────────── Order builders ────────────────────

    function _acrossSpec() internal view returns (bytes memory) {
        return abi.encode(
            AcrossBridgeOutModule.AcrossSpec({
                inputToken: address(tA),
                outputToken: address(tA),
                dstChainId: DST_CHAIN,
                dstRecipient: address(funnel),
                exclusiveRelayer: address(0),
                maxRelayFeeBps: RELAY_FEE_BPS,
                dstScalingFactor: 0,
                fillDeadlineOffset: 2 hours,
                exclusivityOffset: 0,
                dstOrderHash: bytes32(0), // no commitment — the funnel path needs none
                beneficiary: address(0),
                commitmentExpiry: 0
            })
        );
    }

    function _swapOrder(uint256 nonce) internal view returns (Order memory o) {
        o = _blank(nonce);
        o.maker = address(funnel);
        o.legsIn = _legsIn1(address(tA), DELIVERED);
        LegOut[] memory l = new LegOut[](1);
        l[0] = LegOut(address(tB), OUT_AMOUNT, 0, endUser);
        o.legsOut = PackedEncode.legsOut(l);
    }

    function _fundSolverOut() internal {
        tB.mint(solver, OUT_AMOUNT);
        vm.startPrank(solver);
        tB.approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), address(tB), type(uint160).max, 0);
        vm.stopPrank();
    }

    function _deployFunnel() internal {
        address[] memory toks = new address[](1);
        toks[0] = address(tA);
        factory.deployAndEnable(maker, USER_SALT, toks);
    }

    bytes4 constant MAGIC = 0x1626ba7e;
    bytes4 constant NOT_MAGIC = 0xffffffff;

    /// @dev {PositionFunnel.isValidSignature} answers only an ALLOWED CONSUMER —
    ///      Settlement, Permit3 or the lens. Probing it as the test contract would
    ///      return the sentinel for the wrong reason, so every probe is pranked.
    function _ask(bytes32 hash, bytes memory sig) internal returns (bytes4) {
        vm.prank(address(settlement));
        return funnel.isValidSignature(hash, sig);
    }

    // ──────────────────── The headline ────────────────────

    /// @notice ONE `vm.sign` authorises the source order on chain 1 AND the
    ///         destination order on chain 31337. The source half runs through
    ///         Settlement's pre-existing bulk path with no contract change at all.
    function test_oneSignature_authorisesBothChains() public {
        Order memory src = _srcOrder(1, PAY, BRIDGE, address(acrossOut), _acrossSpec());
        Order memory dst = _swapOrder(2);

        bytes32 leafSrc = _srcLeaf(src);
        bytes32 leafDst = _dstLeaf(dst, DST_CHAIN);
        bytes32 root = _hashPair(leafSrc, leafDst);

        // ── the only signature the user ever produces ──
        bytes memory sig = _signRoot(root, makerPk);

        bytes memory srcEnv = _bulkEnvelope(sig, _one(leafDst));
        bytes memory dstEnv = _crossEnvelope(sig, _one(leafSrc), SRC_CHAIN, address(settlement));

        // ── source chain ──
        _fillSourceWith(src, srcEnv);

        assertEq(spokePool.depositAt(0).recipient, address(funnel), "bridged to the user's funnel");
        assertEq(spokePool.depositAt(0).message.length, 0, "no commitment: nothing rides the bridge");

        // ── destination chain: plain arrival, no calldata ──
        spokePool.relay(0);
        assertEq(tA.balanceOf(address(funnel)), DELIVERED, "funds waiting at the funnel");

        _deployFunnel();
        _fundSolverOut();

        vm.prank(solver);
        settlement.fill(dst, dstEnv, DELIVERED);

        assertEq(tB.balanceOf(endUser), OUT_AMOUNT, "end user paid on the destination chain");
        assertEq(tA.balanceOf(address(funnel)), 0, "bridged funds consumed");
    }

    function _fillSourceWith(Order memory src, bytes memory env) internal onSourceChain {
        _wireSourceParties(address(acrossOut), PAY, BRIDGE);
        vm.prank(solver);
        settlement.fill(src, env, PAY);
    }

    /// @notice Three leaves: the source order, the destination order, and the
    ///         {PositionFunnel.executeSigned} grant batch a leverage order needs.
    ///         Still one signature.
    function test_executeSigned_acceptsTheSameRoot() public {
        Order memory src = _srcOrder(1, PAY, BRIDGE, address(acrossOut), _acrossSpec());
        Order memory dst = _swapOrder(2);

        PositionFunnel.Call[] memory calls = new PositionFunnel.Call[](1);
        calls[0] = PositionFunnel.Call({
            target: address(permit3),
            value: 0,
            data: abi.encodeCall(IPermit3.approveToken, (address(0xBEEF), address(tA), uint160(1e18), uint48(0)))
        });
        uint256 deadline = block.timestamp + 1 days;

        bytes32 leafSrc = _srcLeaf(src);
        bytes32 leafDst = _dstLeaf(dst, DST_CHAIN);
        bytes32 leafExec = _execLeaf(calls, 7, deadline, DST_CHAIN);
        bytes32 node = _hashPair(leafSrc, leafDst);
        bytes32 root = _hashPair(node, leafExec);

        bytes memory sig = _signRoot(root, makerPk);

        _deployFunnel();
        vm.prank(solver);
        funnel.executeSigned(calls, 7, deadline, _crossEnvelope(sig, _one(node), SRC_CHAIN, address(settlement)));

        (uint160 amt,) = permit3.tokenAllowance(address(funnel), address(0xBEEF), address(tA));
        assertEq(amt, 1e18, "grant relayed under the shared root");

        // ...and the very same signature still authorises the destination order.
        assertEq(
            _ask(leafDst, _crossEnvelope(sig, _two(leafSrc, leafExec), SRC_CHAIN, address(settlement))),
            MAGIC,
            "same root also validates the destination order"
        );
    }

    // ──────────────────── Negative space ────────────────────

    /// @dev A root signed by anyone but the owner authorises nothing.
    function test_rootSignedByStranger_isRejected() public {
        Order memory dst = _swapOrder(2);
        bytes32 leafDst = _dstLeaf(dst, DST_CHAIN);
        bytes32 root = _hashPair(bytes32(uint256(1)), leafDst);

        bytes memory env = _crossEnvelope(_signRoot(root, solverPk), _one(bytes32(uint256(1))), SRC_CHAIN, address(settlement));

        _deployFunnel();
        assertEq(_ask(leafDst, env), NOT_MAGIC, "stranger's root refused");
    }

    /// @dev The chain binding lives in the LEAF. Replayed against a funnel at the
    ///      same address on a different chain, the digest Settlement computes
    ///      differs, so the leaf differs, so the fold misses the signed root.
    function test_notReplayableOnAnotherChain() public {
        Order memory dst = _swapOrder(2);
        bytes32 leafSrc = bytes32(uint256(0xABC));
        bytes32 leafDst = _dstLeaf(dst, DST_CHAIN);
        bytes32 root = _hashPair(leafSrc, leafDst);
        bytes memory env = _crossEnvelope(_signRoot(root, makerPk), _one(leafSrc), SRC_CHAIN, address(settlement));

        _deployFunnel();
        assertEq(_ask(leafDst, env), MAGIC, "valid on its own chain");

        // Same envelope, same funnel address, different chain.
        bytes32 otherLeaf = _dstLeaf(dst, 8453);
        assertTrue(otherLeaf != leafDst, "the digest is chain-bound to begin with");
        assertEq(_ask(otherLeaf, env), NOT_MAGIC, "and does not carry across");
    }

    /// @dev Tampering with the proof changes the root and therefore the signer.
    function test_tamperedProof_isRejected() public {
        Order memory dst = _swapOrder(2);
        bytes32 leafSrc = bytes32(uint256(0xABC));
        bytes32 leafDst = _dstLeaf(dst, DST_CHAIN);
        bytes memory sig = _signRoot(_hashPair(leafSrc, leafDst), makerPk);

        _deployFunnel();
        bytes memory bad = _crossEnvelope(sig, _one(bytes32(uint256(0xABD))), SRC_CHAIN, address(settlement));
        assertEq(_ask(leafDst, bad), NOT_MAGIC, "tampered proof refused");
    }

    /// @dev Naming a different source domain just changes the recovered signer — it
    ///      is not a way in, which is why the field can be caller-supplied at all.
    function test_wrongSourceDomain_isRejected() public {
        Order memory dst = _swapOrder(2);
        bytes32 leafSrc = bytes32(uint256(0xABC));
        bytes32 leafDst = _dstLeaf(dst, DST_CHAIN);
        bytes memory sig = _signRoot(_hashPair(leafSrc, leafDst), makerPk);

        _deployFunnel();
        assertEq(
            _ask(leafDst, _crossEnvelope(sig, _one(leafSrc), 999, address(settlement))),
            NOT_MAGIC,
            "wrong source chainId"
        );
        assertEq(
            _ask(leafDst, _crossEnvelope(sig, _one(leafSrc), SRC_CHAIN, address(0xDEAD))),
            NOT_MAGIC,
            "wrong source settlement"
        );
    }

    /// @dev A zero-level "tree" is refused on length: its root IS the leaf, which
    ///      would reduce the envelope to a single-order signature under a domain the
    ///      caller names.
    function test_zeroLevelEnvelope_isRefused() public {
        Order memory dst = _swapOrder(2);
        bytes32 leafDst = _dstLeaf(dst, DST_CHAIN);
        bytes memory sig = _signRoot(leafDst, makerPk);

        _deployFunnel();
        bytes memory env = _crossEnvelope(sig, new bytes32[](0), SRC_CHAIN, address(settlement));
        assertEq(env.length, 118, "the degenerate shape");
        assertEq(_ask(leafDst, env), NOT_MAGIC, "refused");
    }

    /// @dev A plain per-chain signature still works — the envelope is additive.
    function test_plainSignatureStillWorks() public {
        Order memory dst = _swapOrder(2);
        _deployFunnel();
        assertEq(
            _ask(_dstLeaf(dst, DST_CHAIN), _signWith(dst, makerPk)),
            MAGIC,
            "ordinary path untouched"
        );
    }
}
