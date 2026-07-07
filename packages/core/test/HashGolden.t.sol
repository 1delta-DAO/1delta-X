// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {UniversalSettlement, Order, Item, ItemOp, Validator, OrderSide} from "@core/settlement/UniversalSettlement.sol";

/// @dev No-fork golden test: pins the EIP-712 struct hash of a canonical order.
///      The TypeScript SDK asserts the SAME value, cross-verifying its typed-data
///      definitions against the contract byte-for-byte. `hashOrder` is the
///      domain-independent hashStruct, so no fork / addresses / chainId needed.
contract HashGoldenTest is Test {
    UniversalSettlement settlement;

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
        settlement = new UniversalSettlement(address(0xdead));
    }

    function _canonical() internal pure returns (Order memory o) {
        address[] memory tokenIn = new address[](2);
        tokenIn[0] = USDC;
        tokenIn[1] = DAI;
        uint256[] memory amountIn = new uint256[](2);
        amountIn[0] = 2_000e6;
        amountIn[1] = 500e18;

        address[] memory tokenOut = new address[](1);
        tokenOut[0] = WETH;
        uint256[] memory startOut = new uint256[](1);
        startOut[0] = 1 ether;
        uint256[] memory endOut = new uint256[](1);
        endOut[0] = 0.9 ether;

        Item[] memory items = new Item[](2);
        items[0] = Item({op: ItemOp.MAKE, module: MOD1, amount: 1 ether, recipient: address(0), data: hex"1234"});
        items[1] = Item({op: ItemOp.TAKE, module: MOD2, amount: 1_500e6, recipient: MAKER, data: hex"abcd"});

        Validator[] memory validators = new Validator[](1);
        validators[0] = Validator({target: VAL1, data: hex"dead"});
        Validator[] memory invariants = new Validator[](1);
        invariants[0] = Validator({target: VAL2, data: hex"beef"});

        o = Order({
            maker: MAKER,
            side: OrderSide.SELL,
            nonce: 1,
            deadline: 1_000_000,
            tokenIn: tokenIn,
            startAmountIn: amountIn,
            endAmountIn: amountIn,
            decayStartTime: 111,
            decayDuration: 222,
            tokenOut: tokenOut,
            startAmountOut: startOut,
            endAmountOut: endOut,
            exclusiveFiller: FILLER,
            exclusivityEndTime: 333,
            minFillAnchor: 100e6,
            items: items,
            validators: validators,
            invariants: invariants
        });
    }

    /// @dev The TypeScript SDK (`packages/sdk`) asserts this SAME constant for the
    ///      same canonical order — cross-verifying its EIP-712 typed-data defs.
    bytes32 constant GOLDEN_ORDER_HASH = 0x95d6af839695566cded188dbc4361f7ba22aa108e80ba3c633988069a335a210;

    function test_goldenOrderHash() public view {
        assertEq(settlement.hashOrder(_canonical()), GOLDEN_ORDER_HASH, "canonical order hashStruct");
    }
}
