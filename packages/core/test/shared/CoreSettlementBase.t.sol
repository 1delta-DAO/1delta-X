// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

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

import {LenderRegistry, Chains, Lenders, Tokens} from "../data/LenderRegistry.sol";

/// @dev Core test harness with NO module dependency. Deploys only Permit3 +
/// Settlement and provides the order/permit EIP-712 machinery plus the
/// module-free order builders. Pure-protocol tests (plain swaps, partial fills,
/// dutch decay, exclusivity, min-fill, validators, invariants, single-signature
/// permits) inherit this directly. Module integration harnesses extend it and
/// layer their adapters on top (see the modules-aave-v3 / modules-aave-v4 packages).
abstract contract CoreSettlementBase is Test, LenderRegistry {
    Permit3 permit3;
    Settlement settlement;
    SettlementLens lens;

    uint256 makerPk = 0xA11CE;
    address maker = vm.addr(makerPk);
    address solver = address(0xBEEF);

    address WETH;
    address USDC;

    function setUp() public virtual {
        _forkEthMainnet();

        WETH = tokens[Chains.ETHEREUM_MAINNET][Tokens.WETH];
        USDC = tokens[Chains.ETHEREUM_MAINNET][Tokens.USDC];

        permit3 = new Permit3();
        settlement = new Settlement(address(permit3));
        lens = new SettlementLens(address(settlement));

        vm.label(maker, "maker");
        vm.label(solver, "solver");
        vm.label(address(permit3), "permit3");
        vm.label(address(settlement), "settlement");
        vm.label(WETH, "WETH");
        vm.label(USDC, "USDC");

        // ── Maker: bare ERC20 approves to Permit3. ──
        vm.startPrank(maker);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        vm.stopPrank();

        // ── Solver: standing Permit3 allowance to Settlement (solvers are
        //    contracts with a one-time setup). Direct-fill tests overwrite the
        //    per-token cap via `_approveSolverSide`. ──
        vm.startPrank(solver);
        IERC20(WETH).approve(address(permit3), type(uint256).max);
        IERC20(USDC).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), WETH, type(uint160).max, 0);
        permit3.approveToken(address(settlement), USDC, type(uint160).max, 0);
        vm.stopPrank();
    }

    // ──────────────────── Fork helper ────────────────────

    /// @dev Tries `ETH_RPC_URL` first (if set), then walks a baked-in list of
    ///      public mainnet RPCs until one succeeds. Reverts if all fail.
    function _forkEthMainnet() internal {
        // 1. user-supplied override
        try vm.envString("ETH_RPC_URL") returns (string memory v) {
            if (bytes(v).length > 0) {
                try this.__fork(v) {
                    return;
                } catch {}
            }
        } catch {}

        // 2. baked-in list — ordered by observed latency on the user's bench
        string[13] memory rpcs = [
            "https://eth.drpc.org",
            "https://ethereum-rpc.publicnode.com",
            "https://rpc.flashbots.net",
            "https://api.zan.top/eth-mainnet",
            "https://1rpc.io/eth",
            "https://rpc.mevblocker.io",
            "https://eth.meowrpc.com",
            "https://eth.api.onfinality.io/public",
            "https://eth-mainnet.public.blastapi.io",
            "https://gateway.tenderly.co/public/mainnet",
            "https://ethereum-public.nodies.app",
            "https://rpc.eth.gateway.fm",
            "https://0xrpc.io/eth"
        ];

        for (uint256 i = 0; i < rpcs.length; i++) {
            try this.__fork(rpcs[i]) {
                return;
            } catch {}
        }
        revert("CoreSettlementBase: no working mainnet RPC (set ETH_RPC_URL to bypass)");
    }

    /// @dev External self-call so a reverting `createSelectFork` can be caught
    ///      by try/catch (cheatcode reverts propagate through external boundaries).
    function __fork(string calldata rpc) external {
        vm.createSelectFork(rpc, _forkBlock());
    }

    /// @dev Block to pin the mainnet fork to. Default has headroom under Aave v3
    ///      market caps for deterministic tests; harnesses needing a later state
    ///      (e.g. Aave v4, deployed after this block) override it.
    function _forkBlock() internal view virtual returns (uint256) {
        return 22_000_000;
    }

    // ──────────────────── Approvals ────────────────────

    function _approveSolverSide(uint256 cap, address token) internal {
        vm.startPrank(solver);
        IERC20(token).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), token, uint160(cap), 0);
        vm.stopPrank();
    }

    /// @dev Let Settlement pull up to `cap` of `token` from the maker (tokenIn leg).
    function _approveMakerToSettlement(address token, uint256 cap) internal {
        vm.startPrank(maker);
        IERC20(token).approve(address(permit3), type(uint256).max);
        permit3.approveToken(address(settlement), token, uint160(cap), 0);
        vm.stopPrank();
    }

    // ──────────────────── Order builders (module-free) ────────────────────

    /// @dev Core fixed-price SELL builder — a single fixed input leg and a single
    ///      fixed output leg (both `end == 0`). The `_orderWith*` variants tweak one
    ///      field of this. A decaying order sets `legsOut[0].end` (or `.start`) after.
    function _sellOrder(
        uint256 nonce,
        address maker_,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        Item[] memory items
    ) internal view returns (Order memory o) {
        o = Order({
            maker: maker_,
            side: OrderSide.SELL,
            nonce: nonce,
            deadline: block.timestamp + 1 hours,
            legsIn: _legsIn1(tokenIn, amountIn),
            legsOut: _legsOut1(tokenOut, amountOut),
            timing: 0,
            exclusiveFiller: address(0),
            minFillAnchor: 0,
            exclusivityOverrideBps: 0,
            curve: _noCurve(),
            gasBumpBps: 0,
            gasPriceRef: 0,
            items: items,
            validators: new Validator[](0),
            invariants: new Validator[](0),
            fillModule: address(0),
            fillTotal: 0
        });
    }

    /// @dev Generic fixed-price single-/multi-item order with no extra gating.
    function _order(
        address _maker,
        uint256 nonce,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        Item[] memory items
    ) internal view returns (Order memory) {
        return _sellOrder(nonce, _maker, tokenIn, tokenOut, amountIn, amountOut, items);
    }

    function _orderWithExclusivity(
        uint256 nonce, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut,
        Item[] memory items, address exclusiveFiller, uint32 exclusivityEndTime
    ) internal view returns (Order memory o) {
        o = _sellOrder(nonce, maker, tokenIn, tokenOut, amountIn, amountOut, items);
        o.exclusiveFiller = exclusiveFiller;
        o.timing = _packTiming(0, 0, exclusivityEndTime);
    }

    function _orderWithMinFill(
        uint256 nonce, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut,
        Item[] memory items, uint256 minFillAmountIn
    ) internal view returns (Order memory o) {
        o = _sellOrder(nonce, maker, tokenIn, tokenOut, amountIn, amountOut, items);
        o.minFillAnchor = minFillAmountIn;
    }

    function _orderWithInvariants(
        uint256 nonce, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut,
        Item[] memory items, Validator[] memory invariants
    ) internal view returns (Order memory o) {
        o = _sellOrder(nonce, maker, tokenIn, tokenOut, amountIn, amountOut, items);
        o.invariants = invariants;
    }

    function _orderWithValidators(
        uint256 nonce, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut,
        Item[] memory items, Validator[] memory validators
    ) internal view returns (Order memory o) {
        o = _sellOrder(nonce, maker, tokenIn, tokenOut, amountIn, amountOut, items);
        o.validators = validators;
    }

    /// @dev A single fixed input leg (`end == 0`).
    function _legsIn1(address token, uint256 amount) internal pure returns (LegIn[] memory a) {
        a = new LegIn[](1);
        a[0] = LegIn(token, amount, 0);
    }

    /// @dev A single fixed output leg to the maker (`end == 0`, recipient == 0).
    function _legsOut1(address token, uint256 amount) internal pure returns (LegOut[] memory a) {
        a = new LegOut[](1);
        a[0] = LegOut(token, amount, 0, address(0));
    }

    /// @dev Pack the three uint32 clocks into `Order.timing` (mirror of {DutchAuction}).
    function _packTiming(uint32 decayStart, uint32 decayDur, uint32 exclEnd) internal pure returns (uint256) {
        return uint256(decayStart) | (uint256(decayDur) << 32) | (uint256(exclEnd) << 64);
    }

    // Bit-preserving setters for the packed `timing` word (used by tests that mutate
    // one clock without disturbing the others).
    function _setDecayStart(Order memory o, uint256 v) internal pure {
        o.timing = (o.timing & ~uint256(type(uint32).max)) | uint256(uint32(v));
    }

    function _setDecayDuration(Order memory o, uint256 v) internal pure {
        o.timing = (o.timing & ~(uint256(type(uint32).max) << 32)) | (uint256(uint32(v)) << 32);
    }

    function _setExclusivityEnd(Order memory o, uint256 v) internal pure {
        o.timing = (o.timing & ~(uint256(type(uint32).max) << 64)) | (uint256(uint32(v)) << 64);
    }

    /// @dev Split a single output leg into [gross − fee → maker, fee → recipient]
    ///      — the originator/sourcing fee as an ordinary fee OUTPUT leg. Both legs
    ///      stay fixed (`end == 0`); for a bps-of-tick fee on a decaying order set
    ///      the legs' start/end proportionally instead.
    function _splitFeeLeg(Order memory order, address recipient, uint256 fee) internal pure {
        address token = order.legsOut[0].token;
        uint256 gross = order.legsOut[0].start;
        order.legsOut = new LegOut[](2);
        order.legsOut[0] = LegOut(token, gross - fee, 0, address(0)); // maker
        order.legsOut[1] = LegOut(token, fee, 0, recipient); // fee
    }

    // ──────────────────── Array helpers (single-asset wrap) ────────────────────

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

    // ──────────────────── Permit-batch builders ────────────────────

    function _buildBatch(
        IPermit3.TokenPermit[] memory tp,
        IPermit3.TakerPermit[] memory tkp,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (IPermit3.PermitBatch memory) {
        return IPermit3.PermitBatch({tokens: tp, takers: tkp, nonce: nonce, deadline: deadline});
    }

    function _noTakerPermits() internal pure returns (IPermit3.TakerPermit[] memory) {
        return new IPermit3.TakerPermit[](0);
    }

    function _tokenPermits(
        address spender1, address token1, uint256 amt1,
        address spender2, address token2, uint256 amt2
    ) internal view returns (IPermit3.TokenPermit[] memory tp) {
        tp = new IPermit3.TokenPermit[](2);
        uint48 exp = uint48(block.timestamp + 1 hours);
        tp[0] = IPermit3.TokenPermit(spender1, token1, uint160(amt1), exp);
        tp[1] = IPermit3.TokenPermit(spender2, token2, uint160(amt2), exp);
    }

    function _tokenPermitsWithTaker(
        address spender1, address token1, uint256 amt1,
        address spender2, address token2, uint256 amt2
    ) internal view returns (IPermit3.TokenPermit[] memory) {
        return _tokenPermits(spender1, token1, amt1, spender2, token2, amt2);
    }

    function _takerPermits1(address spender, bytes32 ref, uint256 amt)
        internal
        view
        returns (IPermit3.TakerPermit[] memory tkp)
    {
        tkp = new IPermit3.TakerPermit[](1);
        tkp[0] = IPermit3.TakerPermit(spender, ref, uint160(amt), uint48(block.timestamp + 1 hours));
    }

    // ──────────────────── EIP-712 hashing + signing ────────────────────
    //
    // Type hashes must match Settlement / Permit3 exactly.

    bytes32 constant CURVE_POINT_TH = keccak256("CurvePoint(uint32 timeDelta,uint32 bumpBps)");
    bytes32 constant ITEM_TH =
        keccak256("Item(uint8 op,address module,uint256 amount,address recipient,bytes data)");
    bytes32 constant VALIDATOR_TH = keccak256("Validator(address target,bytes data)");
    bytes32 constant LEG_IN_TH = keccak256("LegIn(address token,uint256 start,uint256 end)");
    bytes32 constant LEG_OUT_TH = keccak256("LegOut(address token,uint256 start,uint256 end,address recipient)");
    bytes32 constant ORDER_TH = keccak256(
        "Order(address maker,uint8 side,uint256 nonce,uint256 deadline,LegIn[] legsIn,LegOut[] legsOut,uint256 timing,address exclusiveFiller,uint256 minFillAnchor,uint256 exclusivityOverrideBps,CurvePoint[] curve,uint256 gasBumpBps,uint256 gasPriceRef,Item[] items,Validator[] validators,Validator[] invariants,address fillModule,uint256 fillTotal)"
        "CurvePoint(uint32 timeDelta,uint32 bumpBps)"
        "Item(uint8 op,address module,uint256 amount,address recipient,bytes data)"
        "LegIn(address token,uint256 start,uint256 end)"
        "LegOut(address token,uint256 start,uint256 end,address recipient)"
        "Validator(address target,bytes data)"
    );
    bytes32 constant TOKEN_PERMIT_TH =
        keccak256("TokenPermit(address spender,address token,uint160 amount,uint48 expiration)");
    bytes32 constant TAKER_PERMIT_TH =
        keccak256("TakerPermit(address spender,bytes32 ref,uint160 amount,uint48 expiration)");

    /// @dev Must mirror Permit3's `_PERMIT_BATCH_WITNESS_STUB` + Settlement's
    ///      `_ORDER_WITNESS_TYPESTRING` exactly.
    string constant PERMIT_BATCH_WITNESS_FULL =
        "PermitBatchWitness(TokenPermit[] tokens,TakerPermit[] takers,uint256 nonce,uint256 deadline,"
        "Order witness)"
        "CurvePoint(uint32 timeDelta,uint32 bumpBps)"
        "Item(uint8 op,address module,uint256 amount,address recipient,bytes data)"
        "LegIn(address token,uint256 start,uint256 end)"
        "LegOut(address token,uint256 start,uint256 end,address recipient)"
        "Order(address maker,uint8 side,uint256 nonce,uint256 deadline,LegIn[] legsIn,LegOut[] legsOut,uint256 timing,address exclusiveFiller,uint256 minFillAnchor,uint256 exclusivityOverrideBps,CurvePoint[] curve,uint256 gasBumpBps,uint256 gasPriceRef,Item[] items,Validator[] validators,Validator[] invariants,address fillModule,uint256 fillTotal)"
        "TakerPermit(address spender,bytes32 ref,uint160 amount,uint48 expiration)"
        "TokenPermit(address spender,address token,uint160 amount,uint48 expiration)"
        "Validator(address target,bytes data)";

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

    function _hashValidators(Validator[] memory validators) internal pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](validators.length);
        for (uint256 i; i < validators.length; i++) {
            h[i] = keccak256(abi.encode(VALIDATOR_TH, validators[i].target, keccak256(validators[i].data)));
        }
        return keccak256(abi.encodePacked(h));
    }

    function _hashAddresses(address[] memory a) internal pure returns (bytes32) {
        bytes32[] memory words = new bytes32[](a.length);
        for (uint256 i; i < a.length; i++) {
            words[i] = bytes32(uint256(uint160(a[i])));
        }
        return keccak256(abi.encodePacked(words));
    }

    function _hashUints(uint256[] memory a) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(a));
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
            uint8(o.side),
            o.nonce,
            o.deadline,
            _hashLegsIn(o.legsIn),
            _hashLegsOut(o.legsOut),
            o.timing,
            o.exclusiveFiller,
            o.minFillAnchor
        );
        bytes memory tail = abi.encode(
            o.exclusivityOverrideBps,
            _hashCurve(o.curve),
            o.gasBumpBps,
            o.gasPriceRef,
            _hashItems(o.items),
            _hashValidators(o.validators),
            _hashValidators(o.invariants),
            o.fillModule,
            o.fillTotal
        );
        return keccak256(bytes.concat(head, tail));
    }

    /// @dev Signs the order with the maker's key against Settlement's domain.
    function _sign(Order memory o) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), _hashOrder(o)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, digest);
        return abi.encodePacked(r, s, v);
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

    /// @dev Signs the witness-bound permit batch against Permit3's domain.
    function _signPermitWitness(IPermit3.PermitBatch memory batch, bytes32 witness)
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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, digest);
        return abi.encodePacked(r, s, v);
    }
}
