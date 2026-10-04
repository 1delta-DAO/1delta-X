import type { OrderAnnounce, SignedSoftCancel } from "@1delta-x/orderbook";
import {
  announceFromJson as sdkAnnounceFromJson,
  JsonBodyError,
  orderFromJson,
  softCancelFromJson as sdkSoftCancelFromJson,
} from "@1delta-x/sdk";

/**
 * JSON request bodies for `POST /orders` and `POST /cancels`.
 *
 * The strict parsers moved to the SDK (`@1delta-x/sdk` `json.ts`) so the
 * Cloudflare Worker orderbook, the app and the filler share them byte for byte;
 * this module keeps the server's names and its orderbook-typed results. See the
 * SDK module for the shape and the strictness rules.
 */
export { JsonBodyError, orderFromJson };

/** `{ order, sig }` → `OrderAnnounce`. Throws {@link JsonBodyError}. */
export function announceFromJson(v: unknown): OrderAnnounce {
  return sdkAnnounceFromJson(v);
}

/** `{ cancel, sig }` → `SignedSoftCancel`. Throws {@link JsonBodyError}. */
export function softCancelFromJson(v: unknown): SignedSoftCancel {
  return sdkSoftCancelFromJson(v);
}

/** Parse raw JSON bytes; any syntax error is a {@link JsonBodyError}. */
export function parseJsonBytes(raw: Uint8Array): unknown {
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(raw);
  } catch {
    throw new JsonBodyError("body is not valid UTF-8");
  }
  try {
    return JSON.parse(text);
  } catch {
    throw new JsonBodyError("body is not valid JSON");
  }
}
