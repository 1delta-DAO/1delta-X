declare const __TERMS_HASH__: `0x${string}`;

/** keccak256 of the TC.md this console was built with (vite.config.ts). */
export const TERMS_HASH: `0x${string}` = __TERMS_HASH__;

/**
 * The orderbook, through this console's own same-origin proxy (`public/_worker.js` →
 * the ORDERBOOK service binding). Overridable for a local worker.
 */
export const ORDERBOOK_URL: string = (import.meta.env.VITE_ORDERBOOK_URL as string | undefined)?.trim().replace(/\/+$/, "") || "/api/book";
