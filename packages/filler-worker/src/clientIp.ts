import { safeEqual } from "./auth";

/**
 * Who the public `POST /quote` rate limiter bills. Its own module: the entry module
 * (`index.ts`) may export only Workers entrypoints (workerd refuses a main module that
 * exports a string).
 *
 *   1. `x-filler-client-ip`, ONLY when `x-filler-binding-key` equals the
 *      `QUOTE_BINDING_KEY` secret — the app's Pages worker forwards `/api/quote` over
 *      the FILLER service binding and copies the visitor's edge-set `cf-connecting-ip`
 *      into it (the orderbook's `x-orderbook-client-ip` scheme). Without the secret
 *      configured the header is ignored.
 *   2. `cf-connecting-ip` — set by Cloudflare's edge on every request from the
 *      internet; a client cannot choose it on the public route.
 *   3. `unknown` — one shared bucket.
 *
 * `x-forwarded-for` is never read: it is client-writable.
 */
export const QUOTE_IP_HEADER = "x-filler-client-ip";
export const QUOTE_KEY_HEADER = "x-filler-binding-key";
/** How the entry worker hands the resolved address to the Durable Object. */
export const DO_IP_HEADER = "x-quote-client-ip";

const IP = /^[0-9a-fA-F:.]{2,45}$/;

export async function quoteClientIp(request: Request, bindingKey: unknown): Promise<string> {
  const key = typeof bindingKey === "string" ? bindingKey.trim() : "";
  const claimed = request.headers.get(QUOTE_IP_HEADER)?.trim();
  if (key && claimed && IP.test(claimed) && (await safeEqual(request.headers.get(QUOTE_KEY_HEADER) ?? "", key))) return claimed;
  const edge = request.headers.get("cf-connecting-ip")?.trim();
  return edge && IP.test(edge) ? edge : "unknown";
}
