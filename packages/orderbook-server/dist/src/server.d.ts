import { Book, InMemoryTransport, Verifier, type OrderbookConfig } from "@1delta-x/orderbook";
import { type FastifyInstance } from "fastify";
import { type PublicClient } from "viem";
export interface BuildServerOptions {
    config: OrderbookConfig;
    /** Inject a viem client (tests / custom RPC). Defaults to `http(config.rpcUrl)`. */
    client?: PublicClient;
    /** Inject a verifier (tests use a stub to skip the chain). */
    verifier?: Verifier;
    /** Inject the internal bus (tests). */
    transport?: InMemoryTransport;
    /** Inject a preconfigured book (tests: e.g. `revalidateMs: 0`). */
    book?: Book;
    logger?: boolean;
}
export interface OrderbookServer {
    app: FastifyInstance;
    book: Book;
    transport: InMemoryTransport;
    config: OrderbookConfig;
    close: () => Promise<void>;
}
/**
 * The demo backend as an "infra node": an `InMemoryTransport` bus, a verified
 * `Book`, and a Fastify REST + WebSocket access layer bridging browser
 * makers/fillers to that bus. Protobuf on the wire throughout. To go P2P, swap
 * the `InMemoryTransport` for a Waku transport — the routes, the Book, and the
 * verification are unchanged.
 *
 * Routes:
 *   POST /orders        protobuf OrderAnnounce  → verify (L1+L2) → publish  → 202
 *   GET  /orders        → protobuf OrderList (filters: maker,tokenIn,tokenOut,side)
 *   GET  /orders/:hash  → protobuf OrderAnnounce
 *   POST /cancels       protobuf OrderSoftCancel → verify maker sig → evict → 202
 *   GET  /stream (ws)   → SNAPSHOT then live ADD / CANCEL StreamMessages
 *   GET  /health        → chain config + book size
 */
export declare function buildServer(opts: BuildServerOptions): Promise<OrderbookServer>;
