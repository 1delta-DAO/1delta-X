// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Permit3} from "@core/permit3/Permit3.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {
    UniversalSettlement,
    Order,
    Item,
    ItemOp,
    Validator,
    OrderSide,
    CurvePoint
} from "@core/settlement/UniversalSettlement.sol";
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
    UniversalSettlement settlement;
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
        settlement = new UniversalSettlement(address(permit3));
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

    function _noCurve() internal pure returns (CurvePoint[] memory) {
        return new CurvePoint[](0);
    }

    // ──────────────────── Order builder ────────────────────

    function _plainOrder(uint256 nonce, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut)
        internal
        view
        returns (Order memory)
    {
        return Order({
            maker: maker,
            side: OrderSide.SELL,
            nonce: nonce,
            deadline: block.timestamp + 1 hours,
            tokenIn: _a1(tokenIn),
            startAmountIn: _u1(amountIn),
            endAmountIn: _u1(amountIn),
            decayStartTime: 0,
            decayDuration: 0,
            tokenOut: _a1(tokenOut),
            startAmountOut: _u1(amountOut),
            endAmountOut: _u1(amountOut),
            recipientOut: new address[](1),
            exclusiveFiller: address(0),
            exclusivityEndTime: 0,
            minFillAnchor: 0,
            exclusivityOverrideBps: 0,
            curve: _noCurve(),
            gasBumpBps: 0,
            gasPriceRef: 0,
            items: new Item[](0),
            validators: new Validator[](0),
            invariants: new Validator[](0),
            fillModule: address(0),
            fillTotal: 0
        });
    }

    /// @dev Exact-output (BUY) plain order: fixed single output, rising input
    ///      auction `startAmountIn → endAmountIn` (best-for-maker first). Fill is
    ///      denominated in tokenOut[0] units.
    function _buyOrder(
        uint256 nonce,
        address tokenIn,
        address tokenOut,
        uint256 startAmountIn,
        uint256 endAmountIn,
        uint256 amountOut
    ) internal view returns (Order memory) {
        return Order({
            maker: maker,
            side: OrderSide.BUY,
            nonce: nonce,
            deadline: block.timestamp + 1 hours,
            tokenIn: _a1(tokenIn),
            startAmountIn: _u1(startAmountIn),
            endAmountIn: _u1(endAmountIn),
            decayStartTime: 0,
            decayDuration: 0,
            tokenOut: _a1(tokenOut),
            startAmountOut: _u1(amountOut),
            endAmountOut: _u1(amountOut),
            recipientOut: new address[](1),
            exclusiveFiller: address(0),
            exclusivityEndTime: 0,
            minFillAnchor: 0,
            exclusivityOverrideBps: 0,
            curve: _noCurve(),
            gasBumpBps: 0,
            gasPriceRef: 0,
            items: new Item[](0),
            validators: new Validator[](0),
            invariants: new Validator[](0),
            fillModule: address(0),
            fillTotal: 0
        });
    }

    /// @dev Multi-output plain order (no items). `tokenIn`/`amountIn` single-leg;
    ///      `tokenOut`/`amountOut` arbitrary length. Used for duplicate-output and
    ///      multi-output reverse-mode coverage.
    function _plainOrderMultiOut(
        uint256 nonce,
        address tokenIn,
        uint256 amountIn,
        address[] memory tokenOut,
        uint256[] memory amountOut
    ) internal view returns (Order memory) {
        return Order({
            maker: maker,
            side: OrderSide.SELL,
            nonce: nonce,
            deadline: block.timestamp + 1 hours,
            tokenIn: _a1(tokenIn),
            startAmountIn: _u1(amountIn),
            endAmountIn: _u1(amountIn),
            decayStartTime: 0,
            decayDuration: 0,
            tokenOut: tokenOut,
            startAmountOut: amountOut,
            endAmountOut: amountOut,
            recipientOut: new address[](tokenOut.length),
            exclusiveFiller: address(0),
            exclusivityEndTime: 0,
            minFillAnchor: 0,
            exclusivityOverrideBps: 0,
            curve: _noCurve(),
            gasBumpBps: 0,
            gasPriceRef: 0,
            items: new Item[](0),
            validators: new Validator[](0),
            invariants: new Validator[](0),
            fillModule: address(0),
            fillTotal: 0
        });
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
    string constant PERMIT_BATCH_WITNESS_FULL =
        "PermitBatchWitness(TokenPermit[] tokens,TakerPermit[] takers,uint256 nonce,uint256 deadline,"
        "Order witness)"
        "CurvePoint(uint32 timeDelta,uint32 bumpBps)"
        "Item(uint8 op,address module,uint256 amount,address recipient,bytes data)"
        "Order(address maker,uint8 side,uint256 nonce,uint256 deadline,address[] tokenIn,uint256[] startAmountIn,uint256[] endAmountIn,uint32 decayStartTime,uint32 decayDuration,address[] tokenOut,uint256[] startAmountOut,uint256[] endAmountOut,address[] recipientOut,address exclusiveFiller,uint32 exclusivityEndTime,uint256 minFillAnchor,uint256 exclusivityOverrideBps,CurvePoint[] curve,uint256 gasBumpBps,uint256 gasPriceRef,Item[] items,Validator[] validators,Validator[] invariants,address fillModule,uint256 fillTotal)"
        "TakerPermit(address spender,bytes32 ref,uint160 amount,uint48 expiration)"
        "TokenPermit(address spender,address token,uint160 amount,uint48 expiration)"
        "Validator(address target,bytes data)";

    function _buildBatch(
        IPermit3.TokenPermit[] memory tp,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (IPermit3.PermitBatch memory) {
        return IPermit3.PermitBatch({tokens: tp, takers: new IPermit3.TakerPermit[](0), nonce: nonce, deadline: deadline});
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
    bytes32 constant ORDER_TH = keccak256(
        "Order(address maker,uint8 side,uint256 nonce,uint256 deadline,address[] tokenIn,uint256[] startAmountIn,uint256[] endAmountIn,uint32 decayStartTime,uint32 decayDuration,address[] tokenOut,uint256[] startAmountOut,uint256[] endAmountOut,address[] recipientOut,address exclusiveFiller,uint32 exclusivityEndTime,uint256 minFillAnchor,uint256 exclusivityOverrideBps,CurvePoint[] curve,uint256 gasBumpBps,uint256 gasPriceRef,Item[] items,Validator[] validators,Validator[] invariants,address fillModule,uint256 fillTotal)"
        "CurvePoint(uint32 timeDelta,uint32 bumpBps)"
        "Item(uint8 op,address module,uint256 amount,address recipient,bytes data)"
        "Validator(address target,bytes data)"
    );

    function _hashAddresses(address[] memory a) internal pure returns (bytes32) {
        bytes32[] memory w = new bytes32[](a.length);
        for (uint256 i; i < a.length; i++) {
            w[i] = bytes32(uint256(uint160(a[i])));
        }
        return keccak256(abi.encodePacked(w));
    }

    function _hashUints(uint256[] memory a) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(a));
    }

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

    function _hashOrder(Order memory o) internal pure returns (bytes32) {
        bytes memory head = abi.encode(
            ORDER_TH,
            o.maker,
            uint8(o.side),
            o.nonce,
            o.deadline,
            _hashAddresses(o.tokenIn),
            _hashUints(o.startAmountIn),
            _hashUints(o.endAmountIn),
            o.decayStartTime,
            o.decayDuration
        );
        bytes memory mid = abi.encode(
            _hashAddresses(o.tokenOut),
            _hashUints(o.startAmountOut),
            _hashUints(o.endAmountOut),
            _hashAddresses(o.recipientOut),
            o.exclusiveFiller,
            o.exclusivityEndTime,
            o.minFillAnchor,
            o.exclusivityOverrideBps
        );
        bytes memory tail = abi.encode(
            _hashCurve(o.curve),
            o.gasBumpBps,
            o.gasPriceRef,
            _hashItems(o.items),
            _hashValidators(o.validators),
            _hashValidators(o.invariants), o.fillModule, o.fillTotal
        );
        return keccak256(bytes.concat(head, mid, tail));
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
