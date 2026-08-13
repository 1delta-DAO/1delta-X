import { getAddress, type Address } from "viem";
import { ItemOp, OrderSide, packTiming, type Order } from "../src";

const A = (n: string): Address => getAddress(n);

/// Must mirror `HashGolden.t.sol::_canonical()` field-for-field.
export const CANONICAL_ORDER: Order = {
  maker: A("0x00000000000000000000000000000000000000a1"),
  side: OrderSide.SELL,
  nonce: 1n,
  deadline: 1_000_000n,
  // Two fixed input legs (USDC, DAI) — end == 0 ⇒ fixed at start.
  // NOTE these stay STRUCTURED here; `packOrder` produces the packed wire form.
  legsIn: [
    { token: A("0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"), start: 2_000_000_000n, end: 0n },
    { token: A("0x6b175474e89094c44da98b954eedeac495271d0f"), start: 500_000_000_000_000_000_000n, end: 0n },
  ],
  // One DECAYING output leg to a non-zero fee recipient — cross-checks LegOut
  // struct-array hashing (token + start/end + recipient).
  legsOut: [
    {
      token: A("0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"),
      start: 1_000_000_000_000_000_000n,
      end: 900_000_000_000_000_000n,
      recipient: A("0x0000000000000000000000000000000000000fee"),
    },
  ],
  // Packed timing: decayStartTime 111 | decayDuration 222 | exclusivityEndTime 333.
  timing: packTiming(111, 222, 333),
  exclusiveFiller: A("0x0000000000000000000000000000000000000b0b"),
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
  // Non-zero fill fields — cross-check the two tail words hash.
  fillModule: A("0x000000000000000000000000000000000000f111"),
  fillTotal: 42n,
  priorityScale: 0n,
  pricingModule: "0x000000000000000000000000000000000000f222" as Address,
};

/// Emitted by `HashGolden.t.sol` (Solidity `lens.hashOrder`) for the SAME order.
///
/// ⚠ This constant and `HashGolden.t.sol::GOLDEN_ORDER_HASH` must be identical.
/// They are the cross-language check that the SDK's encoding still matches the
/// contract's — and duplicating it is exactly how that check was once defeated:
/// each side was updated on its own schedule, both suites stayed green, and the
/// SDK silently signed hashes the contract rejected for two migrations. If you
/// change one, change the other in the same commit; `eip712.test.ts` also pins
/// the typestring so a field-type change cannot slip through unnoticed.
export const GOLDEN_ORDER_HASH = "0x627e590874df6c58eba2354e7f1cf0c103f72bc95d48a01e758493e7a5bbcfef";
