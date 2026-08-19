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
import {SettlementLens} from "@core/periphery/SettlementLens.sol";
import {Permit3} from "@core/permit3/Permit3.sol";
import {PackedEncode} from "./shared/PackedEncode.sol";

/// @dev No-fork golden test: pins the EIP-712 struct hash of a canonical order.
///      The TypeScript SDK asserts the SAME value, cross-verifying its typed-data
///      definitions against the contract byte-for-byte. `hashOrder` is the
///      domain-independent hashStruct, so no fork / addresses / chainId needed.
contract HashGoldenTest is Test {
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
        // token, so the hub is otherwise unused.
        settlement = new Settlement(address(new Permit3()));
        lens = new SettlementLens(address(settlement));
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
}
