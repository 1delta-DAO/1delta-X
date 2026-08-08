// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackedEncode} from "../shared/PackedEncode.sol";

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Permit3} from "@core/permit3/Permit3.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
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
import {SettlementLens} from "@core/periphery/SettlementLens.sol";

/// @dev Minimal, freely-mintable ERC20. Enough for Permit3's transfer paths —
///      no fork / real tokens, so the pure-protocol suites run fast and are
///      RPC-independent.
contract MockERC20 {
    string public name;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name) {
        name = _name;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
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

/// @dev Non-fork harness for the pure-protocol suites (relevant-state, batch fill,
///      nonce/cancellation). Deploys Permit3 + Settlement + three mock tokens and
///      provides EIP-712 order builders + signing. Mirrors the hashing in
///      {OrderHash} byte-for-byte.
abstract contract MockSettlementBase is Test {
    Permit3 permit3;
    Settlement settlement;
    SettlementLens lens;

    uint256 makerPk = 0xA11CE;
    address maker = vm.addr(makerPk);
    uint256 solverPk = 0x50_1E5;
    address solver = vm.addr(solverPk);

    MockERC20 tA; // "maker gives" default (tokenIn)
    MockERC20 tB; // "maker gets" default (tokenOut)
    MockERC20 tC; // spare, for multi-input / pair tests

    function setUp() public virtual {
        permit3 = new Permit3();
        settlement = new Settlement(address(permit3));
        lens = new SettlementLens(address(settlement));

        tA = new MockERC20("tA");
        tB = new MockERC20("tB");
        tC = new MockERC20("tC");

        vm.label(maker, "maker");
        vm.label(solver, "solver");
        vm.label(address(settlement), "settlement");
    }

    // ──────────────────── Approvals / funding ────────────────────

    /// @dev Maker: ERC20→Permit3 once, then a per-token Permit3 allowance to a spender.
    function _makerApprove(address spender, address token, uint256 cap) internal {
        vm.startPrank(maker);
        MockERC20(token).approve(address(permit3), type(uint256).max);
        permit3.approveToken(spender, token, uint160(cap), 0);
        vm.stopPrank();
    }

    function _solverApprove(address spender, address token, uint256 cap) internal {
        vm.startPrank(solver);
        MockERC20(token).approve(address(permit3), type(uint256).max);
        permit3.approveToken(spender, token, uint160(cap), 0);
        vm.stopPrank();
    }

    // ──────────────────── Array helpers ────────────────────

    function _a1(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _u1(uint256 x) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = x;
    }

    /// @dev An EMPTY packed curve blob — the byte `0x00`, not a zero-length array.
    function _noCurve() internal pure returns (bytes memory) {
        return PackedEncode.noCurve();
    }

    // ──────────────────── Order builder ────────────────────

    function _legsIn1(address token, uint256 amount) internal pure returns (bytes memory) {
        return PackedEncode.oneLegIn(token, amount, 0);
    }

    function _legsOut1(address token, uint256 amount) internal pure returns (bytes memory) {
        return PackedEncode.oneLegOut(token, amount, 0, address(0));
    }

    // Bit-preserving setters for the packed `timing` word.
    function _setDecayStart(Order memory o, uint256 v) internal pure {
        o.timing = (o.timing & ~uint256(type(uint32).max)) | uint256(uint32(v));
    }

    function _setDecayDuration(Order memory o, uint256 v) internal pure {
        o.timing = (o.timing & ~(uint256(type(uint32).max) << 32)) | (uint256(uint32(v)) << 32);
    }

    function _setExclusivityEnd(Order memory o, uint256 v) internal pure {
        o.timing = (o.timing & ~(uint256(type(uint32).max) << 64)) | (uint256(uint32(v)) << 64);
    }

    /// @dev Empty-body Order with common defaults; callers set legsIn/legsOut/side.
    function _blank(uint256 nonce) internal view returns (Order memory o) {
        o = Order({
            maker: maker,
            nonce: nonce,
            deadline: block.timestamp + 1 hours,
            legsIn: PackedEncode.legsIn(new LegIn[](0)),
            legsOut: PackedEncode.legsOut(new LegOut[](0)),
            timing: 0,
            exclusiveFiller: address(0),
            minFillAnchor: 0,
            exclusivityOverrideBps: 0,
            curve: PackedEncode.noCurve(),
            gasBumpBps: 0,
            gasPriceRef: 0,
            items: PackedEncode.noItems(),
            validators: PackedEncode.noValidators(),
            invariants: PackedEncode.noValidators(),
            fillModule: address(0),
            fillTotal: 0
        });
    }

    function _plainOrder(uint256 nonce, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut)
        internal
        view
        returns (Order memory o)
    {
        o = _blank(nonce);
        o.legsIn = _legsIn1(tokenIn, amountIn);
        o.legsOut = _legsOut1(tokenOut, amountOut);
    }

    /// @dev Exact-output (BUY) plain order: fixed single output, rising input
    ///      auction `startAmountIn → endAmountIn` (best-for-maker first). Fill is
    ///      denominated in legsOut[0] units.
    function _buyOrder(
        uint256 nonce,
        address tokenIn,
        address tokenOut,
        uint256 startAmountIn,
        uint256 endAmountIn,
        uint256 amountOut
    ) internal view returns (Order memory o) {
        o = _blank(nonce);
        o.timing |= uint256(1) << 101; // BUY (timing bit 101)
        o.legsIn = PackedEncode.oneLegIn(tokenIn, startAmountIn, endAmountIn); // rising input (end = ceiling)
        o.legsOut = _legsOut1(tokenOut, amountOut);
    }

    /// @dev Multi-output plain order (no items). Single fixed input; `tokenOut`/
    ///      `amountOut` arbitrary length (fixed legs). Duplicate-output + reverse-mode
    ///      coverage.
    function _plainOrderMultiOut(
        uint256 nonce,
        address tokenIn,
        uint256 amountIn,
        address[] memory tokenOut,
        uint256[] memory amountOut
    ) internal view returns (Order memory o) {
        o = _blank(nonce);
        o.legsIn = _legsIn1(tokenIn, amountIn);
        LegOut[] memory lo = new LegOut[](tokenOut.length);
        for (uint256 j; j < tokenOut.length; j++) {
            lo[j] = LegOut(tokenOut[j], amountOut[j], 0, address(0));
        }
        o.legsOut = PackedEncode.legsOut(lo);
    }

    // ──────────────────── Permit-batch (witness) builders ────────────────────
    //
    // Mirror the CoreSettlementBase helpers so the single-signature `fillWithPermit`
    // path can be exercised without a fork.

    bytes32 constant TOKEN_PERMIT_TH =
        keccak256("TokenPermit(address spender,address token,uint160 amount,uint48 expiration)");
    bytes32 constant TAKER_PERMIT_TH =
        keccak256("TakerPermit(address spender,bytes32 ref,uint160 amount,uint48 expiration)");

    /// @dev Must mirror Permit3's `_PERMIT_BATCH_WITNESS_STUB` + Settlement's
    ///      `OrderHash.WITNESS_TYPESTRING` exactly.
    string constant PERMIT_BATCH_WITNESS_FULL = "PermitBatchWitness(TokenPermit[] tokens,TakerPermit[] takers,uint256 nonce,uint256 deadline,"
        "Order witness)"
        "Order(address maker,uint256 nonce,uint256 deadline,bytes legsIn,bytes legsOut,uint256 timing,address exclusiveFiller,uint256 minFillAnchor,uint256 exclusivityOverrideBps,bytes curve,uint256 gasBumpBps,uint256 gasPriceRef,bytes items,bytes validators,bytes invariants,address fillModule,uint256 fillTotal)"
        "TakerPermit(address spender,bytes32 ref,uint160 amount,uint48 expiration)"
        "TokenPermit(address spender,address token,uint160 amount,uint48 expiration)";

    function _buildBatch(IPermit3.TokenPermit[] memory tp, uint256 nonce, uint256 deadline)
        internal
        pure
        returns (IPermit3.PermitBatch memory)
    {
        return
            IPermit3.PermitBatch({tokens: tp, takers: new IPermit3.TakerPermit[](0), nonce: nonce, deadline: deadline});
    }

    function _tokenPermit1(address spender, address token, uint256 amt, uint48 exp)
        internal
        pure
        returns (IPermit3.TokenPermit[] memory tp)
    {
        tp = new IPermit3.TokenPermit[](1);
        tp[0] = IPermit3.TokenPermit(spender, token, uint160(amt), exp);
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

    /// @dev Signs the witness-bound permit batch against Permit3's domain with `pk`.
    function _signPermitWitnessWith(IPermit3.PermitBatch memory batch, bytes32 witness, uint256 pk)
        internal
        view
        returns (bytes memory)
    {
        bytes32 typeHash = keccak256(bytes(PERMIT_BATCH_WITNESS_FULL));
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

    function _signPermitWitness(IPermit3.PermitBatch memory batch, bytes32 witness)
        internal
        view
        returns (bytes memory)
    {
        return _signPermitWitnessWith(batch, witness, makerPk);
    }

    // ──────────────────── EIP-712: Order (mirrors OrderHash.sol) ────────────────────

    bytes32 constant CURVE_POINT_TH = keccak256("CurvePoint(uint32 timeDelta,uint32 bumpBps)");
    bytes32 constant ITEM_TH = keccak256("Item(uint8 op,address module,uint256 amount,address recipient,bytes data)");
    bytes32 constant VALIDATOR_TH = keccak256("Validator(address target,bytes data)");
    bytes32 constant LEG_IN_TH = keccak256("LegIn(address token,uint256 start,uint256 end)");
    bytes32 constant LEG_OUT_TH = keccak256("LegOut(address token,uint256 start,uint256 end,address recipient)");
    bytes32 constant ORDER_TH = keccak256(
        "Order(address maker,uint256 nonce,uint256 deadline,bytes legsIn,bytes legsOut,uint256 timing,address exclusiveFiller,uint256 minFillAnchor,uint256 exclusivityOverrideBps,bytes curve,uint256 gasBumpBps,uint256 gasPriceRef,bytes items,bytes validators,bytes invariants,address fillModule,uint256 fillTotal)"
    );

    function _hashItems(Item[] memory items) internal pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](items.length);
        for (uint256 i; i < items.length; i++) {
            h[i] = keccak256(
                abi.encode(
                    ITEM_TH,
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

    function _hashValidators(Validator[] memory v) internal pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](v.length);
        for (uint256 i; i < v.length; i++) {
            h[i] = keccak256(abi.encode(VALIDATOR_TH, v[i].target, keccak256(v[i].data)));
        }
        return keccak256(abi.encodePacked(h));
    }

    function _hashCurve(CurvePoint[] memory curve) internal pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](curve.length);
        for (uint256 i; i < curve.length; i++) {
            h[i] = keccak256(abi.encode(CURVE_POINT_TH, curve[i].timeDelta, curve[i].bumpBps));
        }
        return keccak256(abi.encodePacked(h));
    }

    function _hashLegsIn(LegIn[] memory legs) internal pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](legs.length);
        for (uint256 i; i < legs.length; i++) {
            h[i] = keccak256(abi.encode(LEG_IN_TH, legs[i].token, legs[i].start, legs[i].end));
        }
        return keccak256(abi.encodePacked(h));
    }

    function _hashLegsOut(LegOut[] memory legs) internal pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](legs.length);
        for (uint256 i; i < legs.length; i++) {
            h[i] = keccak256(abi.encode(LEG_OUT_TH, legs[i].token, legs[i].start, legs[i].end, legs[i].recipient));
        }
        return keccak256(abi.encodePacked(h));
    }

    function _hashOrder(Order memory o) internal pure returns (bytes32) {
        bytes memory head = abi.encode(
            ORDER_TH,
            o.maker,
            o.nonce,
            o.deadline,
            keccak256(o.legsIn),
            keccak256(o.legsOut),
            o.timing,
            o.exclusiveFiller,
            o.minFillAnchor
        );
        bytes memory tail = abi.encode(
            o.exclusivityOverrideBps,
            keccak256(o.curve),
            o.gasBumpBps,
            o.gasPriceRef,
            keccak256(o.items),
            keccak256(o.validators),
            keccak256(o.invariants),
            o.fillModule,
            o.fillTotal
        );
        return keccak256(bytes.concat(head, tail));
    }

    function _sign(Order memory o) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), _hashOrder(o)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Sign an order with an arbitrary key (for bad-signature tests).
    function _signWith(Order memory o, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), _hashOrder(o)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
