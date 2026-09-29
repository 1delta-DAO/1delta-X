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
import {SettlementLens} from "@periphery/SettlementLens.sol";
import {Permit3} from "@core/permit3/Permit3.sol";
import {OrderHash} from "@core/settlement/OrderHash.sol";
import {Permit3Hash} from "@core/permit3/libraries/Permit3Hash.sol";
import {PackedEncode} from "./shared/PackedEncode.sol";
import {DeployedBytecode} from "./shared/DeployedBytecode.sol";

/// @dev No-fork golden test: pins the EIP-712 struct hash of a canonical order.
///      The TypeScript SDK asserts the SAME value, cross-verifying its typed-data
///      definitions against the contract byte-for-byte. `hashOrder` is the
///      domain-independent hashStruct, so no fork / addresses / chainId needed.
contract HashGoldenTest is Test, DeployedBytecode {
    Settlement settlement;
    SettlementLens lens;

    address constant MAKER = address(0xA1);
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant MOD1 = address(0xD1);
    address constant MOD2 = address(0xD2);
    address constant VAL1 = address(0xE01);
    address constant VAL2 = address(0xE02);
    address constant FILLER = address(0xB0B);

    function setUp() public {
        // A real Permit3 only because the constructor requires a hub with code —
        // this suite exercises the domain-independent `hashOrder` and never moves a
        // token, so the hub is otherwise unused. Gas-neutral switch — see
        // {DeployedBytecode}: under DEPLOYED_BYTECODE=1 both come from the shipped
        // via-IR artifacts, and only the Settlement (and the lens) are stored.
        if (DEPLOYED_BYTECODE) {
            assembly ("memory-safe") {
                let plan := or(SHIP_ALL, shl(8, NO_SLOT)) // Permit3 not stored
                plan := or(plan, or(shl(80, settlement.offset), shl(88, settlement.slot))) // Settlement offset | slot
                plan := or(plan, or(shl(152, lens.offset), shl(160, lens.slot))) // lens offset | slot
                mstore(0x00, DEPLOY_PLAN_SELECTOR)
                mstore(0x04, plan)
                if iszero(delegatecall(gas(), DEPLOYED_BYTECODE_HELPER, 0x00, 0x24, 0x00, 0x00)) {
                    returndatacopy(0x00, 0x00, returndatasize())
                    revert(0x00, returndatasize())
                }
            }
        } else {
            settlement = new Settlement(address(new Permit3()));
            lens = new SettlementLens(address(settlement));
        }
    }

    function _canonical() internal pure returns (Order memory o) {
        // Two fixed input legs (USDC, DAI) + one DECAYING output leg to a fee
        // recipient — cross-checks LegIn/LegOut struct-array hashing + the packed
        // `timing` word.
        LegIn[] memory legsIn = new LegIn[](2);
        legsIn[0] = LegIn(USDC, 2_000e6, 0);
        legsIn[1] = LegIn(DAI, 500e18, 0);

        LegOut[] memory legsOut = new LegOut[](1);
        legsOut[0] = LegOut(WETH, 1 ether, 0.9 ether, address(0xFEE));

        Item[] memory items = new Item[](2);
        items[0] = Item({op: ItemOp.MAKE, module: MOD1, amount: 1 ether, recipient: address(0), data: hex"1234"});
        items[1] = Item({op: ItemOp.TAKE, module: MOD2, amount: 1_500e6, recipient: MAKER, data: hex"abcd"});

        Validator[] memory validators = new Validator[](1);
        validators[0] = Validator({target: VAL1, data: hex"dead"});
        Validator[] memory invariants = new Validator[](1);
        invariants[0] = Validator({target: VAL2, data: hex"beef"});

        // Non-trivial curve so the golden also cross-checks CurvePoint hashing.
        CurvePoint[] memory curve = new CurvePoint[](2);
        curve[0] = CurvePoint({timeDelta: 0, bumpBps: 1_000});
        curve[1] = CurvePoint({timeDelta: 200, bumpBps: 9_000});

        // Packed timing: decayStartTime 111 | decayDuration 222 | exclusivityEndTime 333
        // | deadline 1_000_000 (bits [160:208), the folded-in `Order.deadline`).
        uint256 timing =
            uint256(111) | (uint256(222) << 32) | (uint256(333) << 64) | (uint256(uint48(1_000_000)) << 160);

        o = Order({
            params: 25 | (50 << 16) | (30_000_000_000 << 32),
            pricingModule: address(0xF222),
            maker: MAKER,
            nonce: 1,
            legsIn: PackedEncode.legsIn(legsIn),
            legsOut: PackedEncode.legsOut(legsOut),
            timing: timing,
            exclusiveFiller: FILLER,
            minFillAnchor: 100e6,
            curve: PackedEncode.curve(curve),
            items: PackedEncode.items(items),
            validators: PackedEncode.validators(validators),
            invariants: PackedEncode.validators(invariants),
            fillModule: address(0xF111),
            fillTotal: 42
        });
    }

    /// @dev The TypeScript SDK (`packages/sdk`) asserts this SAME constant for the
    ///      same canonical order — cross-verifying its EIP-712 typed-data defs.
    bytes32 constant GOLDEN_ORDER_HASH = 0x9a3d3d3d43d1b09bbdecf71f61c62e61e533e09efcaa926384683860a4df22dd;

    function test_goldenOrderHash() public view {
        assertEq(lens.hashOrder(_canonical()), GOLDEN_ORDER_HASH, "canonical order hashStruct");
    }

    // ──────────────── the folded witness typehashes ────────────────
    //
    // Settlement passes Permit3 the FINISHED witness typehash rather than the type
    // string, which is what keeps ~470 bytes of string (and two `string` encoders)
    // out of its runtime. The constants must therefore be literals — only a literal
    // is guaranteed to fold — and these two tests are what stops a literal from
    // drifting away from the strings it stands for. If the `Order` type changes,
    // {OrderHash.WITNESS_TYPESTRING} changes, and these fail until the constants are
    // regenerated. Without them a stale constant would silently break every gasless
    // fill: the digest would no longer match what the maker's wallet signed.

    function test_permitBatchWitnessTypeHash_matchesTheTypeString() public pure {
        assertEq(
            OrderHash.PERMIT_BATCH_WITNESS_TYPEHASH,
            keccak256(abi.encodePacked(Permit3Hash.PERMIT_BATCH_WITNESS_STUB, OrderHash.WITNESS_TYPESTRING)),
            "batch witness typehash drifted from WITNESS_TYPESTRING"
        );
    }

    function test_permitTakeWitnessTypeHash_matchesTheTypeString() public pure {
        assertEq(
            OrderHash.PERMIT_TAKE_WITNESS_TYPEHASH,
            keccak256(abi.encodePacked(Permit3Hash.PERMIT_TAKE_WITNESS_STUB, OrderHash.PERMIT_TAKE_WITNESS_TYPESTRING)),
            "take witness typehash drifted from PERMIT_TAKE_WITNESS_TYPESTRING"
        );
    }

    /// @dev `Core._permitBatchHead` spells {OrderHash.SETTLEMENT_ORDER_TYPEHASH} as an
    ///      assembly LITERAL (a keccak constant is not assembly-addressable there,
    ///      and a local does not fit the stack). This pins the constant to that
    ///      literal and to its type string, so the three cannot drift apart; the
    ///      SDK pins the same literal from its side (`eip712.test.ts`).
    function test_settlementOrderTypeHash_matchesTheAssemblyLiteral() public pure {
        assertEq(
            OrderHash.SETTLEMENT_ORDER_TYPEHASH,
            bytes32(0xfa3f97538e64297a7d633bd4db49a7790146704157439bc4ba83cbf08d9853c0),
            "SettlementOrder typehash drifted from the literal in Core._permitBatchHead"
        );
        assertEq(
            OrderHash.SETTLEMENT_ORDER_TYPEHASH,
            keccak256(
                "SettlementOrder(address settlement,Order order)"
                "Order(address maker,uint256 nonce,bytes legsIn,bytes legsOut,uint256 timing,address exclusiveFiller,uint256 minFillAnchor,uint256 params,bytes curve,bytes items,bytes validators,bytes invariants,address fillModule,uint256 fillTotal,address pricingModule)"
            ),
            "SettlementOrder typehash drifted from its type string"
        );
    }
}
