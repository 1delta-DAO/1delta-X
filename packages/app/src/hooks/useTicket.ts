import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { defaultChain, marketById, marketFor, marketsOn, pairsWith } from "../config/markets";
import { clearingPrice } from "../lib/ladder";
import type { Level, OrderType, Side } from "../lib/types";

export interface TicketDeps {
  /** The merged ladder the auto price is sized against. */
  bids: Level[];
  asks: Level[];
  tick: number;
  /** Per config symbol. `undefined` means unknown (no wallet), not zero. */
  balances: Record<string, number | undefined>;
}

const OPENS_ON = defaultChain();

/**
 * Everything the order form and the ladder both need to agree on, plus the
 * chain and market selection they hang off.
 *
 * Direction is derived from the tokens rather than kept as a separate toggle:
 * picking what you pay with IS picking the side, and a second control that can
 * disagree with the token pair is a bug waiting to happen.
 */
export function useTicket(deps: TicketDeps) {
  const [chainId, setChainId] = useState(OPENS_ON);
  const [marketId, setMarketId] = useState(() => marketsOn(OPENS_ON)[0]!.id);
  const [side, setSide] = useState<Side>("sell");
  const [mode, setMode] = useState<OrderType>("market");
  const [amountStr, setAmountStr] = useState("");
  const [amountTouched, setAmountTouched] = useState(false);
  const [limitStr, setLimitStr] = useState("");
  const [priceTouched, setPriceTouched] = useState(false);
  const [slices, setSlices] = useState(12);
  const [everyMin, setEveryMin] = useState(30);

  const market = marketById(marketId);
  const payToken = side === "sell" ? market.base : market.quote;
  const recvToken = side === "sell" ? market.quote : market.base;
  const amount = Number(amountStr) || 0;
  const limit = mode === "market" ? null : Number(limitStr) || null;
  const payBalance = deps.balances[payToken];

  const applyMarket = useCallback((id: string, pay: string) => {
    const m = marketById(id);
    setMarketId(id);
    setChainId(m.chainId);
    setSide(m.base === pay ? "sell" : "buy");
    setPriceTouched(false);
  }, []);

  const setChain = useCallback(
    (next: number) => {
      const first = marketsOn(next)[0];
      if (!first) return;
      applyMarket(first.id, first.base);
    },
    [applyMarket],
  );

  const setPay = useCallback(
    (symbol: string) => {
      if (symbol === payToken) return;
      const m = marketFor(chainId, symbol, recvToken) ?? marketFor(chainId, symbol, pairsWith(chainId, symbol)[0]);
      if (m) applyMarket(m.id, symbol);
    },
    [applyMarket, chainId, payToken, recvToken],
  );

  const setRecv = useCallback(
    (symbol: string) => {
      if (symbol === recvToken) return;
      const m = marketFor(chainId, payToken, symbol);
      if (m) applyMarket(m.id, payToken);
    },
    [applyMarket, chainId, payToken, recvToken],
  );

  const flip = useCallback(() => applyMarket(marketId, recvToken), [applyMarket, marketId, recvToken]);

  const selectMarket = useCallback((id: string) => applyMarket(id, marketById(id).base), [applyMarket]);

  const setAmount = useCallback((v: string) => {
    setAmountStr(v);
    setAmountTouched(true);
  }, []);

  const setLimit = useCallback((v: string) => {
    setLimitStr(v);
    setPriceTouched(true);
  }, []);

  /**
   * Empty the ticket after it has been signed. Without this the form keeps
   * previewing an order that now exists in the ladder, showing the same size
   * twice — once as a preview and once as the real resting rung.
   */
  const clearAmount = useCallback(() => {
    setAmountStr("");
    setAmountTouched(true);
  }, []);

  /** Give an untouched ticket a size worth quoting, once a balance is known. */
  useEffect(() => {
    if (amountTouched || payBalance === undefined || payBalance <= 0) return;
    const suggested = payBalance * 0.25;
    setAmountStr(String(Number(suggested.toPrecision(3))));
  }, [amountTouched, payBalance]);

  /**
   * Keep the limit sized to the book until the user names a price themselves —
   * by typing, or by clicking a rung. Anchoring to the top of the book instead
   * would only ever fill one level of a large order.
   */
  const levels = side === "sell" ? deps.bids : deps.asks;
  const autoPrice = useMemo(
    () => (levels.length ? clearingPrice(levels, amount, side) : null),
    [levels, amount, side],
  );
  const lastAuto = useRef<number | null>(null);
  useEffect(() => {
    if (mode === "market" || priceTouched || autoPrice === null) return;
    if (lastAuto.current === autoPrice) return;
    lastAuto.current = autoPrice;
    setLimitStr(autoPrice.toFixed(deps.tick));
  }, [mode, priceTouched, autoPrice, deps.tick]);

  const resetAutoPrice = useCallback(() => {
    lastAuto.current = null;
    setPriceTouched(false);
  }, []);

  /** Clicking a rung names that price and, from a market ticket, becomes a limit. */
  const takePriceFromLadder = useCallback(
    (price: number, rungSide: "bid" | "ask") => {
      const want: Side = rungSide === "bid" ? "sell" : "buy";
      if (want !== side) applyMarket(marketId, want === "sell" ? market.base : market.quote);
      setMode((m) => (m === "market" ? "limit" : m));
      setPriceTouched(true);
      setLimitStr(price.toFixed(deps.tick));
    },
    [applyMarket, deps.tick, market.base, market.quote, marketId, side],
  );

  return {
    chainId,
    market,
    marketId,
    side,
    mode,
    payToken,
    recvToken,
    payBalance,
    amount,
    amountStr,
    limit,
    limitStr,
    priceTouched,
    slices,
    everyMin,
    setChain,
    setMode,
    setAmount,
    setLimit,
    clearAmount,
    setSlices,
    setEveryMin,
    setPay,
    setRecv,
    flip,
    selectMarket,
    resetAutoPrice,
    takePriceFromLadder,
  };
}

export type Ticket = ReturnType<typeof useTicket>;
