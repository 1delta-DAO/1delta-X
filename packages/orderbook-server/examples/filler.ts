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
import { Book, CancelVerifier, ChainWatcher, HttpTransport, Verifier } from "@1delta-x/orderbook";
import { createPublicClient, http } from "viem";

import { loadEnv } from "../src/env";

const { config } = loadEnv();
const baseUrl = process.env.BASE_URL ?? "http://localhost:8080";

const rpc = createPublicClient({ transport: http(config.rpcUrl) });

// Watching Settlement logs is what makes eviction cheap: a cancellation event
// carries maker + which nonces/hash died, so the book drops them with no view
// call at all and roughly one block after the fact, instead of waiting up to a
// full sweep period. Set OCO_MODULE to also retire bracket siblings the moment
// their winner lands.
const ocoModule = process.env.OCO_MODULE as `0x${string}` | undefined;
const watcher = new ChainWatcher({
  client: rpc,
  config,
  ...(ocoModule ? { ocoModules: [ocoModule] } : {}),
  onError: (e) => console.error("watcher:", e),
});

const book = new Book({
  transport: new HttpTransport({ baseUrl, config }),
  config,
  verifier: new Verifier(rpc, config),
  cancelVerifier: new CancelVerifier(rpc, config),
  watcher,
  // This filler only takes unconditional orders, so a failing validator means
  // the order is dead TO IT — including a retired OCO leg. A book serving
  // filler-conditional orders must NOT set this.
  evictWhen: (_e, s) => !s.ok || !s.validatorsPass,
});
book.onError((e) => console.error("revalidate:", e));

book.onAdd((e) => console.log("＋", e.orderHash, "fillable", e.state?.fillableAmount?.toString() ?? "?"));
book.onRemove((e) => console.log("－", e.orderHash));

await watcher.start();
await book.start();
console.log(`watching ${baseUrl} — book size ${book.size}`);
