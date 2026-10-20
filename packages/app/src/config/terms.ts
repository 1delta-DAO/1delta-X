declare const __TERMS_HASH__: `0x${string}`;

/**
 * keccak256 of the TC.md this build ships (vite.config.ts `define`) — the Terms
 * version a prize-draw entrant signs. Not the text: the trading bundle needs to
 * name the document, not carry it (see TermsLink.tsx).
 */
export const TERMS_HASH: `0x${string}` = __TERMS_HASH__;
