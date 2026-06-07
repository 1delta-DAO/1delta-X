// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Permit3} from "@core/permit3/Permit3.sol";
import {IPermit3} from "@core/interfaces/IPermit3.sol";
import {
    LimitOrderSettlement,
    LimitOrder,
    Item,
    ItemOp,
    Validator
} from "@core/settlement/LimitOrderSettlement.sol";

import {LenderRegistry, Chains, Lenders, Tokens} from "../data/LenderRegistry.sol";

/// @dev Core test harness with NO module dependency. Deploys only Permit3 +
/// LimitOrderSettlement and provides the order/permit EIP-712 machinery plus the
/// module-free order builders. Pure-protocol tests (plain swaps, partial fills,
/// dutch decay, exclusivity, min-fill, validators, invariants, single-signature
/// permits) inherit this directly. Module integration harnesses extend it and
/// layer their adapters on top (see the modules-aave package).
abstract contract CoreSettlementBase is Test, LenderRegistry {
    Permit3 permit3;
    LimitOrderSettlement settlement;

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
        settlement = new LimitOrderSettlement(address(permit3));

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
        // Pin to a block with headroom under Aave market caps for deterministic tests.
        vm.createSelectFork(rpc, 22_000_000);
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

    /// @dev Generic fixed-price single-/multi-item order with no extra gating.
    function _order(
        address _maker,
        uint256 nonce,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        Item[] memory items
    ) internal view returns (LimitOrder memory) {
        return LimitOrder({
            maker: _maker,
            nonce: nonce,
            deadline: block.timestamp + 1 hours,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            decayStartTime: 0,
            decayDuration: 0,
            startAmountOut: amountOut,
            endAmountOut: amountOut,
            exclusiveFiller: address(0),
            exclusivityEndTime: 0,
            minFillAmountIn: 0,
            items: items,
            validators: new Validator[](0),
            invariants: new Validator[](0)
        });
    }

    function _orderWithExclusivity(
        uint256 nonce, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut,
        Item[] memory items, address exclusiveFiller, uint32 exclusivityEndTime
    ) internal view returns (LimitOrder memory) {
        return LimitOrder({
            maker: maker, nonce: nonce, deadline: block.timestamp + 1 hours,
            tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn,
            decayStartTime: 0, decayDuration: 0,
            startAmountOut: amountOut, endAmountOut: amountOut,
            exclusiveFiller: exclusiveFiller,
            exclusivityEndTime: exclusivityEndTime,
            minFillAmountIn: 0,
            items: items,
            validators: new Validator[](0),
            invariants: new Validator[](0)
        });
    }

    function _orderWithMinFill(
        uint256 nonce, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut,
        Item[] memory items, uint256 minFillAmountIn
    ) internal view returns (LimitOrder memory) {
        return LimitOrder({
            maker: maker, nonce: nonce, deadline: block.timestamp + 1 hours,
            tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn,
            decayStartTime: 0, decayDuration: 0,
            startAmountOut: amountOut, endAmountOut: amountOut,
            exclusiveFiller: address(0), exclusivityEndTime: 0,
            minFillAmountIn: minFillAmountIn,
            items: items,
            validators: new Validator[](0),
            invariants: new Validator[](0)
        });
    }

    function _orderWithInvariants(
        uint256 nonce, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut,
        Item[] memory items, Validator[] memory invariants
    ) internal view returns (LimitOrder memory) {
        return LimitOrder({
            maker: maker, nonce: nonce, deadline: block.timestamp + 1 hours,
            tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn,
            decayStartTime: 0, decayDuration: 0,
            startAmountOut: amountOut, endAmountOut: amountOut,
            exclusiveFiller: address(0), exclusivityEndTime: 0, minFillAmountIn: 0,
            items: items,
            validators: new Validator[](0),
            invariants: invariants
        });
    }

    function _orderWithValidators(
        uint256 nonce,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        Item[] memory items,
        Validator[] memory validators
    ) internal view returns (LimitOrder memory) {
        return LimitOrder({
            maker: maker,
            nonce: nonce,
            deadline: block.timestamp + 1 hours,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            decayStartTime: 0,
            decayDuration: 0,
            startAmountOut: amountOut,
            endAmountOut: amountOut,
            exclusiveFiller: address(0),
            exclusivityEndTime: 0,
            minFillAmountIn: 0,
            items: items,
            validators: validators,
            invariants: new Validator[](0)
        });
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

    function _takerPermits1(address module, bytes32 ref, uint256 amt)
        internal
        view
        returns (IPermit3.TakerPermit[] memory tkp)
    {
        tkp = new IPermit3.TakerPermit[](1);
        tkp[0] = IPermit3.TakerPermit(module, ref, uint160(amt), uint48(block.timestamp + 1 hours));
    }

    // ──────────────────── EIP-712 hashing + signing ────────────────────
    //
    // Type hashes must match LimitOrderSettlement / Permit3 exactly.

    bytes32 constant ITEM_TH =
        keccak256("Item(uint8 op,address module,uint256 amount,address recipient,bytes data)");
    bytes32 constant VALIDATOR_TH = keccak256("Validator(address target,bytes data)");
    bytes32 constant ORDER_TH = keccak256(
        "LimitOrder(address maker,uint256 nonce,uint256 deadline,address tokenIn,address tokenOut,uint256 amountIn,uint32 decayStartTime,uint32 decayDuration,uint256 startAmountOut,uint256 endAmountOut,address exclusiveFiller,uint32 exclusivityEndTime,uint256 minFillAmountIn,Item[] items,Validator[] validators,Validator[] invariants)"
        "Item(uint8 op,address module,uint256 amount,address recipient,bytes data)"
        "Validator(address target,bytes data)"
    );
    bytes32 constant TOKEN_PERMIT_TH =
        keccak256("TokenPermit(address spender,address token,uint160 amount,uint48 expiration)");
    bytes32 constant TAKER_PERMIT_TH =
        keccak256("TakerPermit(address module,bytes32 ref,uint160 amount,uint48 expiration)");

    /// @dev Must mirror Permit3's `_PERMIT_BATCH_WITNESS_STUB` + Settlement's
    ///      `_LIMIT_ORDER_WITNESS_TYPESTRING` exactly.
    string constant PERMIT_BATCH_WITNESS_FULL =
        "PermitBatchWitness(TokenPermit[] tokens,TakerPermit[] takers,uint256 nonce,uint256 deadline,"
        "LimitOrder witness)"
        "Item(uint8 op,address module,uint256 amount,address recipient,bytes data)"
        "LimitOrder(address maker,uint256 nonce,uint256 deadline,address tokenIn,address tokenOut,uint256 amountIn,uint32 decayStartTime,uint32 decayDuration,uint256 startAmountOut,uint256 endAmountOut,address exclusiveFiller,uint32 exclusivityEndTime,uint256 minFillAmountIn,Item[] items,Validator[] validators,Validator[] invariants)"
        "TakerPermit(address module,bytes32 ref,uint160 amount,uint48 expiration)"
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

    function _hashOrder(LimitOrder memory o) internal pure returns (bytes32) {
        bytes memory head = abi.encode(
            ORDER_TH,
            o.maker,
            o.nonce,
            o.deadline,
            o.tokenIn,
            o.tokenOut,
            o.amountIn,
            o.decayStartTime,
            o.decayDuration,
            o.startAmountOut,
            o.endAmountOut
        );
        bytes memory tail = abi.encode(
            o.exclusiveFiller,
            o.exclusivityEndTime,
            o.minFillAmountIn,
            _hashItems(o.items),
            _hashValidators(o.validators),
            _hashValidators(o.invariants)
        );
        return keccak256(bytes.concat(head, tail));
    }

    /// @dev Signs the order with the maker's key against Settlement's domain.
    function _sign(LimitOrder memory o) internal view returns (bytes memory) {
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
            h[i] = keccak256(abi.encode(TAKER_PERMIT_TH, p[i].module, p[i].ref, p[i].amount, p[i].expiration));
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
