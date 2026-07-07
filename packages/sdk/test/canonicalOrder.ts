import { getAddress, type Address } from "viem";
import { ItemOp, OrderSide, type Order } from "../src";

const A = (n: string): Address => getAddress(n);

/// Must mirror `HashGolden.t.sol::_canonical()` field-for-field.
export const CANONICAL_ORDER: Order = {
  maker: A("0x00000000000000000000000000000000000000a1"),
  side: OrderSide.SELL,
  nonce: 1n,
  deadline: 1_000_000n,
  tokenIn: [A("0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"), A("0x6b175474e89094c44da98b954eedeac495271d0f")],
  startAmountIn: [2_000_000_000n, 500_000_000_000_000_000_000n],
  endAmountIn: [2_000_000_000n, 500_000_000_000_000_000_000n],
  decayStartTime: 111,
  decayDuration: 222,
  tokenOut: [A("0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2")],
  startAmountOut: [1_000_000_000_000_000_000n],
  endAmountOut: [900_000_000_000_000_000n],
  exclusiveFiller: A("0x0000000000000000000000000000000000000b0b"),
  exclusivityEndTime: 333,
  minFillAnchor: 100_000_000n,
  exclusivityOverrideBps: 25n,
  curve: [
    { timeDelta: 0, bumpBps: 1_000 },
    { timeDelta: 200, bumpBps: 9_000 },
  ],
  gasBumpBps: 50n,
  gasPriceRef: 30_000_000_000n,
  items: [
    {
      op: ItemOp.MAKE,
      module: A("0x00000000000000000000000000000000000000d1"),
      amount: 1_000_000_000_000_000_000n,
      recipient: A("0x0000000000000000000000000000000000000000"),
      data: "0x1234",
    },
    {
      op: ItemOp.TAKE,
      module: A("0x00000000000000000000000000000000000000d2"),
      amount: 1_500_000_000n,
      recipient: A("0x00000000000000000000000000000000000000a1"),
      data: "0xabcd",
    },
  ],
  validators: [{ target: A("0x0000000000000000000000000000000000000e01"), data: "0xdead" }],
  invariants: [{ target: A("0x0000000000000000000000000000000000000e02"), data: "0xbeef" }],
};

/// Emitted by `HashGolden.t.sol` (Solidity `settlement.hashOrder`).
export const GOLDEN_ORDER_HASH = "0x37bcfdb7b3c44e91f77ea7f45229565a73c19c2502411ab374f27ec906a22f01";
