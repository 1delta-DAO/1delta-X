import type { OrderType } from "./types";

/**
 * The size the automatic limit price is sized against.
 *
 * A TWAP signs ONE slice at a time, each a fixed-price order of
 * `amount / slices`. Sizing its default price to the whole notional baked the
 * full ticket's price impact into every slice — a 1/N-sized order committed at
 * the price that clears all N, handing each filler the difference
 * (G-TS_SIGN-9). Limit orders sign the whole amount, so they size to it.
 */
export function priceSizingAmount(mode: OrderType, amount: number, slices: number): number {
  if (mode === "twap") return slices > 0 ? amount / slices : amount;
  return amount;
}
