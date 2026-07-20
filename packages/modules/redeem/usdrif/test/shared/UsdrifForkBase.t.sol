// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Permit3} from "@core/permit3/Permit3.sol";
import {
    Settlement,
    Order,
    Item,
    Validator,
    LegIn,
    LegOut,
    CurvePoint
} from "@core/settlement/Settlement.sol";

import {IMocRif, IMocQueue} from "../../src/interfaces/IMoc.sol";

/// @dev Rootstock-mainnet fork harness for the USDRIF→USDT0 exit flow. Forks RSK
/// (chain id 30), deploys a fresh Permit3 + Settlement, and provides
/// the verified MoC / token addresses plus the order EIP-712 signing helpers.
///
/// All on-chain facts verified against Rootstock mainnet (see
/// intents-integration-plan.md §5 and the package README).
abstract contract UsdrifForkBase is Test {
    // ──────────────────── Verified Rootstock mainnet addresses ────────────────────

    address internal constant USDRIF = 0x3A15461d8aE0F0Fb5Fa2629e9DA7D66A794a6e37;
    address internal constant RIF = 0x2AcC95758f8b5F583470ba265EB685a8F45fC9D5;
    address internal constant USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;

    address internal constant MOC_CORE = 0xA27024Ed70035E46dba712609fc2Afa1c97aA36A;
    address internal constant MOC_QUEUE = 0x47f5014115d3bb29B20b5168Ee75050D6f8c3Bf1;
    address internal constant MOC_PRICE_PROVIDER = 0x6a5b2C84E63b5C1330bf4CcCff1Ad6F23116CC14;
    address internal constant MOC_GUARD = 0x0237Ad1f0831b479a344E56646BC48B0885cF46F;

    /// @dev `OperType.redeemTP` index in the MoC queue enum {none,mintTC,redeemTC,mintTP,redeemTP,...}.
    uint8 internal constant OPER_REDEEM_TP = 4;

    Permit3 internal permit3;
    Settlement internal settlement;

    uint256 internal makerPk = 0xA11CE;
    address internal maker = vm.addr(makerPk);
    address internal solver = address(0xBEEF);

    function setUp() public virtual {
        _forkRootstock();

        permit3 = new Permit3();
        settlement = new Settlement(address(permit3));

        vm.label(maker, "maker");
        vm.label(solver, "solver");
        vm.label(address(permit3), "permit3");
        vm.label(address(settlement), "settlement");
        vm.label(USDRIF, "USDRIF");
        vm.label(RIF, "RIF");
        vm.label(USDT0, "USDT0");
        vm.label(MOC_CORE, "mocCore");
        vm.label(MOC_QUEUE, "mocQueue");
    }

    // ──────────────────── Fork helper ────────────────────

    /// @dev Tries `RSK_RPC_URL` first (if set), then a list of public Rootstock
    ///      RPCs. Pinned to a block whose archive state the public nodes serve.
    function _forkRootstock() internal {
        try vm.envString("RSK_RPC_URL") returns (string memory v) {
            if (bytes(v).length > 0 && _tryFork(v)) return;
        } catch {}

        string[3] memory rpcs = [
            "https://public-node.rsk.co",
            "https://mycrypto.rsk.co",
            "https://rootstock.drpc.org"
        ];
        for (uint256 i = 0; i < rpcs.length; i++) {
            if (_tryFork(rpcs[i])) return;
        }
        revert("UsdrifForkBase: no working Rootstock RPC (set RSK_RPC_URL to bypass)");
    }

    function _tryFork(string memory rpc) internal returns (bool) {
        try this.__fork(rpc) {
            return true;
        } catch {
            return false;
        }
    }

    function __fork(string calldata rpc) external {
        vm.createSelectFork(rpc, 8_920_000);
    }

    // ──────────────────── Order EIP-712 signing ────────────────────

    bytes32 internal constant CURVE_POINT_TH = keccak256("CurvePoint(uint32 timeDelta,uint32 bumpBps)");
    bytes32 internal constant ITEM_TH =
        keccak256("Item(uint8 op,address module,uint256 amount,address recipient,bytes data)");
    bytes32 internal constant VALIDATOR_TH = keccak256("Validator(address target,bytes data)");
    bytes32 internal constant LEG_IN_TH = keccak256("LegIn(address token,uint256 start,uint256 end)");
    bytes32 internal constant LEG_OUT_TH = keccak256("LegOut(address token,uint256 start,uint256 end,address recipient)");
    bytes32 internal constant ORDER_TH = keccak256(
        "Order(address maker,uint8 side,uint256 nonce,uint256 deadline,LegIn[] legsIn,LegOut[] legsOut,uint256 timing,address exclusiveFiller,uint256 minFillAnchor,uint256 exclusivityOverrideBps,CurvePoint[] curve,uint256 gasBumpBps,uint256 gasPriceRef,Item[] items,Validator[] validators,Validator[] invariants,address fillModule,uint256 fillTotal)"
        "CurvePoint(uint32 timeDelta,uint32 bumpBps)"
        "Item(uint8 op,address module,uint256 amount,address recipient,bytes data)"
        "LegIn(address token,uint256 start,uint256 end)"
        "LegOut(address token,uint256 start,uint256 end,address recipient)"
        "Validator(address target,bytes data)"
    );

    function _noCurve() internal pure returns (CurvePoint[] memory) {
        return new CurvePoint[](0);
    }

    function _hashCurve(CurvePoint[] memory curve) internal pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](curve.length);
        for (uint256 i; i < curve.length; i++) {
            h[i] = keccak256(abi.encode(CURVE_POINT_TH, curve[i].timeDelta, curve[i].bumpBps));
        }
        return keccak256(abi.encodePacked(h));
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

    function _hashValidators(Validator[] memory validators) internal pure returns (bytes32) {
        bytes32[] memory h = new bytes32[](validators.length);
        for (uint256 i; i < validators.length; i++) {
            h[i] = keccak256(abi.encode(VALIDATOR_TH, validators[i].target, keccak256(validators[i].data)));
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

    /// @dev Pack the three uint32 clocks into `Order.timing`.
    function _packTiming(uint32 decayStart, uint32 decayDur, uint32 exclEnd) internal pure returns (uint256) {
        return uint256(decayStart) | (uint256(decayDur) << 32) | (uint256(exclEnd) << 64);
    }

    function _setDecayStart(Order memory o, uint256 v) internal pure {
        o.timing = (o.timing & ~uint256(type(uint32).max)) | uint256(uint32(v));
    }

    function _setDecayDuration(Order memory o, uint256 v) internal pure {
        o.timing = (o.timing & ~(uint256(type(uint32).max) << 32)) | (uint256(uint32(v)) << 32);
    }

    function _setExclusivityEnd(Order memory o, uint256 v) internal pure {
        o.timing = (o.timing & ~(uint256(type(uint32).max) << 64)) | (uint256(uint32(v)) << 64);
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

    function _sign(Order memory o) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", settlement.DOMAIN_SEPARATOR(), _hashOrder(o)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    // ──────────────────── MoC helpers ────────────────────

    /// @dev Impersonate the multi-collateral guard and execute the queued op(s).
    ///      We rolled forward past `minOperWaitingBlk` (1) without warping the
    ///      timestamp, so the MoC price feed stays fresh while the op becomes
    ///      executable (`block.number - 1 >= queuedBlk`).
    function _executeQueue() internal {
        vm.roll(block.number + 2);
        vm.prank(MOC_GUARD);
        IMocQueue(MOC_QUEUE).execute(solver, 10, 1);
    }
}
