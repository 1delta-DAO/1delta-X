/**
 * The protobuf-free half of the library — `@1delta-x/orderbook/pure`.
 *
 * Everything here is plain TypeScript over viem + the SDK: the Layer 1/2
 * {@link Verifier}, the soft-cancel {@link CancelVerifier}, the admission policy,
 * the chain-event types and the query/summary helpers. It deliberately does NOT
 * reach `./proto/codec` (directly or through `./book` / `./client`): protobufjs
 * compiles its codecs with `new Function`, which Cloudflare Workers and any
 * strict-CSP page forbid. `@1delta-x/orderbook-worker` imports only this entry,
 * and its bundle check fails if protobufjs ever leaks in.
 */
export * from "./messages";
export * from "./config";
export * from "./verify";
export * from "./cancels";
export * from "./ecdsa";
export * from "./admission";
export { isOcoGroupLeg, type ChainEvent } from "./watcher";
export { anchorAmounts, orderPrice, tokensIn, tokensOut, summarize, type OrderSummary } from "./query";
export type { BookEntry } from "./book";
