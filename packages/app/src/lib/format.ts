export function fmt(n: number, dp: number): string {
  if (!isFinite(n)) return "—";
  return n.toLocaleString("en-US", { minimumFractionDigits: dp, maximumFractionDigits: dp });
}

/** Amounts span WBTC-sized and USDC-sized in the same UI, so scale the precision. */
export function fmtAmt(n: number): string {
  if (!isFinite(n)) return "—";
  const abs = Math.abs(n);
  if (abs >= 1000) return fmt(n, 0);
  if (abs >= 1) return fmt(n, 2);
  if (abs === 0) return "0";
  return fmt(n, 6);
}

export function fmtPrice(n: number, tick: number): string {
  return isFinite(n) ? n.toFixed(tick) : "—";
}

export function shortHex(h: string, lead = 6, tail = 4): string {
  return h.length <= lead + tail + 2 ? h : `${h.slice(0, lead)}…${h.slice(-tail)}`;
}

export function ago(ts: number, now = Date.now()): string {
  const s = Math.max(0, Math.round((now - ts) / 1000));
  if (s < 10) return "just now";
  if (s < 60) return `${s}s ago`;
  const m = Math.round(s / 60);
  if (m < 60) return `${m} min ago`;
  const h = Math.floor(m / 60);
  return `${h}h ${m % 60}m ago`;
}

export function until(ts: number, now = Date.now()): string {
  const s = Math.max(0, Math.round((ts - now) / 1000));
  if (s <= 0) return "expired";
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  return h > 0 ? `${h}h ${String(m).padStart(2, "0")}m` : `${m}m ${String(s % 60).padStart(2, "0")}s`;
}

/**
 * A stable colour per symbol so a token keeps its mark across the whole app
 * without an icon file or a network request.
 */
export function symbolHue(symbol: string): number {
  let h = 0;
  for (let i = 0; i < symbol.length; i++) h = (h * 31 + symbol.charCodeAt(i)) % 360;
  return h;
}
