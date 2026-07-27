/**
 * Filler example: run a live, verified `Book` over the HTTP transport against
 * the demo backend. `book.onAdd`/`onRemove` print the reconstructed book.
 *
 *   CHAIN_ID=31 SETTLEMENT=0x… PERMIT3=0x… LENS=0x… RPC_URL=… \
 *   node dist/examples/filler.js
 *
 * The point of the seam: swap `new HttpTransport(...)` for a `WakuTransport`
 * later and this file does not change at all. From here a real filler would take
 * an `onAdd` order and submit `fill()` (see the SDK `encodeFill`).
 */
import { Book, HttpTransport, Verifier } from "@1delta-x/orderbook";
import { createPublicClient, http } from "viem";

import { loadEnv } from "../src/env";

const { config } = loadEnv();
const baseUrl = process.env.BASE_URL ?? "http://localhost:8080";

const rpc = createPublicClient({ transport: http(config.rpcUrl) });
const book = new Book({
  transport: new HttpTransport({ baseUrl, config }),
  config,
  verifier: new Verifier(rpc, config),
});

book.onAdd((e) => console.log("＋", e.orderHash, "fillable", e.state?.fillableAmount?.toString() ?? "?"));
book.onRemove((e) => console.log("－", e.orderHash));

await book.start();
console.log(`watching ${baseUrl} — book size ${book.size}`);
