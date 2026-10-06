import type { Env } from "./config";

/**
 * Client-IP resolution for the rate limiter. Lives in its own module because the
 * Worker's entry module (`index.ts`) may export ONLY Workers entrypoints: workerd
 * treats every named export of the main module as one and refuses to start the
 * script on anything else ("Incorrect type for map entry 'BINDING_IP_HEADER': the
 * provided value is not of type 'function or ExportedHandler'") — which is what the
 * string constants below did when they were exported from `index.ts`.
 */

/** Headers the app's Pages worker sets on a service-binding call. See README §"Client IP and spoofing". */
export const BINDING_IP_HEADER = "x-orderbook-client-ip";
export const BINDING_KEY_HEADER = "x-orderbook-binding-key";

/** Constant-time string compare (both sides are short secrets / header values). */
function safeEqual(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

const IP = /^[0-9a-fA-F:.]{2,45}$/;

/**
 * The client address the rate limiter bills.
 *
 *   1. `x-orderbook-client-ip`, ONLY when `x-orderbook-binding-key` equals the
 *      `BINDING_KEY` secret — i.e. the request came through the app's Pages
 *      worker over the service binding, which sets both from the visitor's own
 *      `cf-connecting-ip`. Without a configured key the header is ignored.
 *   2. `cf-connecting-ip` — set by Cloudflare's edge on every request from the
 *      internet, so a client cannot choose it on the public route.
 *
 * `x-forwarded-for` is never read: it is client-writable.
 */
export function clientIp(request: Request, env: Pick<Env, "BINDING_KEY">): string {
  const key = env.BINDING_KEY?.trim();
  const claimed = request.headers.get(BINDING_IP_HEADER)?.trim();
  const presented = request.headers.get(BINDING_KEY_HEADER) ?? "";
  if (key && claimed && IP.test(claimed) && safeEqual(presented, key)) return claimed;
  const edge = request.headers.get("cf-connecting-ip")?.trim();
  return edge && IP.test(edge) ? edge : "unknown";
}
