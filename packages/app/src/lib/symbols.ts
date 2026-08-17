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

export function normSymbol(symbol: string): string {
  const s = symbol.toUpperCase();
  return ALIAS[s] ?? s;
}

export function sameSymbol(a: string, b: string): boolean {
  return normSymbol(a) === normSymbol(b);
}
