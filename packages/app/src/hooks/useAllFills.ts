import { useEffect, useState } from "react";

import { ORDERBOOK_URL } from "../backend/book";
import type { FillWire } from "../lib/dashboard";

/** Pages read on the first load (500 fills each); later refreshes read only the newest page. */
const MAX_PAGES = 20;
const PAGE = 500;
const REFRESH_MS = 60_000;

const keyOf = (f: FillWire) => `${f.txHash ?? ""}:${f.logIndex ?? 0}`;

async function page(
  cursor?: string,
): Promise<{ fills: FillWire[]; next?: string }> {
  const q = new URLSearchParams({
    limit: String(PAGE),
    ...(cursor ? { cursor } : {}),
  });
  const res = await fetch(`${ORDERBOOK_URL}/fills?${q}`, {
    headers: { accept: "application/json" },
  });
  if (!res.ok)
    throw new Error(
      res.status === 429
        ? "the orderbook is rate-limiting us; retrying shortly"
        : `orderbook answered ${res.status}`,
    );
  const body = (await res.json()) as {
    fills?: FillWire[];
    nextCursor?: string;
  };
  return {
    fills: Array.isArray(body.fills) ? body.fills : [],
    ...(body.nextCursor ? { next: body.nextCursor } : {}),
  };
}

/**
 * Every fill the orderbook has indexed, newest first (`GET /fills` without a maker):
 * the full history once on mount (up to {@link MAX_PAGES} pages), then the newest page
 * merged in every minute. Only while `active` (the dashboard is on screen).
 */
export function useAllFills(active: boolean): {
  fills: FillWire[];
  loading: boolean;
  error: string | null;
  complete: boolean;
} {
  const [state, setState] = useState<{
    fills: FillWire[];
    loading: boolean;
    error: string | null;
    complete: boolean;
  }>({
    fills: [],
    loading: true,
    error: null,
    complete: true,
  });
  useEffect(() => {
    if (!active || !ORDERBOOK_URL) {
      if (!ORDERBOOK_URL)
        setState({
          fills: [],
          loading: false,
          error: "no orderbook server in this build",
          complete: true,
        });
      return;
    }
    let alive = true;
    let complete = false;
    const byKey = new Map<string, FillWire>();
    const publish = (complete: boolean, error: string | null = null) => {
      if (!alive) return;
      const fills = [...byKey.values()].sort(
        (a, b) =>
          Number(BigInt(b.blockNumber ?? "0") - BigInt(a.blockNumber ?? "0")) ||
          (b.logIndex ?? 0) - (a.logIndex ?? 0),
      );
      setState({ fills, loading: false, error, complete });
    };
    const full = async () => {
      let cursor: string | undefined;
      let n = 0;
      try {
        do {
          const p = await page(cursor);
          for (const f of p.fills) byKey.set(keyOf(f), f);
          cursor = p.next;
          n++;
        } while (alive && cursor && n < MAX_PAGES);
        complete = !cursor;
        publish(complete);
      } catch (e) {
        publish(false, e instanceof Error ? e.message : String(e));
      }
    };
    void full();
    const t = setInterval(async () => {
      try {
        const p = await page();
        for (const f of p.fills) byKey.set(keyOf(f), f);
        publish(complete);
      } catch {
        // keep what is on screen; the next minute retries
      }
    }, REFRESH_MS);
    return () => {
      alive = false;
      clearInterval(t);
    };
  }, [active]);
  return state;
}
