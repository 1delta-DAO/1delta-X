/**
 * Three sources name the same token three ways: the market config names it the
 * way a trader would, Oku reports wrapped assets unwrapped ("ETH" for WETH),
 * and the 1delta token list uses the on-chain symbol. Matching happens on a
 * normalised form so all three agree without any of them having to change.
 */
const ALIAS: Record<string, string> = {
  WETH: "ETH",
  WRBTC: "RBTC",
  WBNB: "BNB",
  "USDC.E": "USDCE",
  USDT0: "USD0",
};

/**
 * Tether brands its ticker with U+20AE TUGRIK SIGN — the SushiSwap subgraph
 * reports `USD₮0` where Oku reports `USD0`. It is a stylised capital T, so it is
 * folded to one before any alias is applied; otherwise the two indexers describe
 * the same token with strings that can never match.
 */
function fold(symbol: string): string {
  return symbol.replace(/₮/g, "T").toUpperCase();
}

export function normSymbol(symbol: string): string {
  const s = fold(symbol);
  return ALIAS[s] ?? s;
}

export function sameSymbol(a: string, b: string): boolean {
  return normSymbol(a) === normSymbol(b);
}
