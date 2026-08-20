/**
 * Maker example: build a SELL dutch-auction order, sign it with the SDK, and
 * publish it to the demo backend over the protobuf HTTP transport.
 *
 *   MAKER_PK=0x…  TOKEN_IN=0x…  TOKEN_OUT=0x…  AMOUNT_IN=1000000 \
 *   CHAIN_ID=31 SETTLEMENT=0x… PERMIT3=0x… LENS=0x… RPC_URL=… \
 *   node dist/examples/maker.js
 *
 * The maker must hold TOKEN_IN and have approved Permit3 for it — otherwise the
 * backend's Layer-2 lens check reports a 0 fillable amount and rejects (422).
 */
import { HttpTransport, OrderbookClient, toDeployment } from "@1delta-x/orderbook";
import { hashOrderStruct, OrderSide, packTiming, signOrder, type Order } from "@1delta-x/sdk";
import { getAddress, zeroAddress, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";

import { loadEnv } from "../src/env";

const { config } = loadEnv();
const baseUrl = process.env.BASE_URL ?? "http://localhost:8080";

const pk = process.env.MAKER_PK as Hex | undefined;
if (!pk) throw new Error("MAKER_PK is required");
const maker = privateKeyToAccount(pk);

const tokenIn = getAddress(process.env.TOKEN_IN ?? "");
const tokenOut = getAddress(process.env.TOKEN_OUT ?? "");
const amountIn = BigInt(process.env.AMOUNT_IN ?? "1000000");
const startOut = BigInt(process.env.START_OUT ?? "1000000");
const endOut = BigInt(process.env.END_OUT ?? "990000");

const now = Math.floor(Date.now() / 1000);
const order: Order = {
  maker: maker.address,
  side: OrderSide.SELL,
  nonce: BigInt(process.env.NONCE ?? now),
  expiry: BigInt(now + 3600),
  legsIn: [{ token: tokenIn, start: amountIn, end: 0n }], // fixed input
  legsOut: [{ token: tokenOut, start: startOut, end: endOut, recipient: zeroAddress }], // decays start→floor
  timing: packTiming(now, 600, 0), // 10-min decay from now
  exclusiveFiller: zeroAddress,
  minFillAnchor: 0n,
  exclusivityOverrideBps: 0n,
  curve: [],
  gasBumpBps: 0n,
  gasPriceRef: 0n,
  items: [],
  validators: [],
  invariants: [],
  fillModule: zeroAddress,
  fillTotal: 0n,
  priorityScale: 0n,
  pricingModule: zeroAddress,
};

const sig = await signOrder(maker, order, toDeployment(config));
const client = new OrderbookClient(new HttpTransport({ baseUrl, config }), config);
await client.publishOrder(order, sig);

console.log("published order", hashOrderStruct(order), "to", baseUrl);
