/**
 * The live progress of a MARKET order (a quoted Dutch auction), and when to expect
 * its fill — pure, so the stage, the countdown and every label are pinned by tests.
 *
 * Where the time goes on Rootstock (2026-10-12, ~30.7 s blocks over the last 2,000):
 *   1. the order's auction starts at signing, and the core refuses a fill before
 *      `decayStartTime` (`AuctionNotStarted`), so the filler waits for the first
 *      block stamped after it: on average half a block;
 *   2. the filler sees it on its next tick (≤ 5 s) and sends;
 *   3. the fill is mined in the next block: one more block.
 * Typical ≈ 1.5 blocks + a tick (~51 s); past 3 blocks + a tick (~97 s) it is late —
 * the price is still decaying toward the maker's minimum, which only makes it more
 * attractive to fill, so "late" is information, not failure.
 */
import type { OrderPhase } from "./orderLifecycle";

/** Mean Rootstock block interval, ms (blocks 9,316,3xx–9,318,3xx). */
export const RSK_BLOCK_MS = 30_700;
/** The filler worker's tick. */
export const FILLER_TICK_MS = 5_000;

export type TrackStage = "posted" | "matching" | "sent" | "filled" | "ended";

export interface MarketTrack {
  stage: TrackStage;
  /** 0..1 — how far along the expected timeline (asymptotic while waiting, 1 when filled). */
  progress: number;
  /** Seconds to the expected fill; ≤ 0 once overdue; null when there is nothing to wait for. */
  etaSeconds: number | null;
  late: boolean;
  /** 0..1 of the Dutch auction's decay window elapsed. */
  auctionPct: number;
  headline: string;
  sub: string;
}

export interface TrackArgs {
  phase: OrderPhase;
  /** When the order was posted (ms) — its auction start. */
  createdAt: number;
  expiresAt: number;
  decaySeconds: number;
  /** When a filler's transaction was sent (ms), from the book; else the moment it was first seen. */
  sentAt?: number;
  now: number;
  blockMs?: number;
}

export function expectedFillMs(blockMs: number = RSK_BLOCK_MS): { typical: number; late: number } {
  return { typical: Math.round(blockMs * 1.5 + FILLER_TICK_MS), late: Math.round(blockMs * 3 + FILLER_TICK_MS) };
}

const secs = (ms: number) => Math.max(0, Math.ceil(ms / 1000));

/** "~45 s" / "~2 min". */
export function fmtEta(s: number): string {
  if (s >= 90) return `~${Math.round(s / 60)} min`;
  return `~${Math.max(1, Math.round(s))} s`;
}

export function marketTrack(a: TrackArgs): MarketTrack {
  const blockMs = a.blockMs ?? RSK_BLOCK_MS;
  const { typical, late } = expectedFillMs(blockMs);
  const elapsed = Math.max(0, a.now - a.createdAt);
  const auctionPct = a.decaySeconds > 0 ? Math.min(1, elapsed / (a.decaySeconds * 1000)) : 1;
  // Approaches but never reaches the end while waiting: 80 % at the typical time.
  const waiting = 1 - Math.exp((-elapsed / typical) * Math.LN2 * 2.32);
  const p = a.phase;

  if (p.kind === "filled") return { stage: "filled", progress: 1, etaSeconds: null, late: false, auctionPct, headline: "Filled", sub: "settled on-chain" };
  if (p.kind === "partial") return { stage: "filled", progress: 1, etaSeconds: null, late: false, auctionPct, headline: `Partially filled · ${p.pct.toFixed(0)}%`, sub: "settled on-chain" };
  if (p.kind === "expired" || p.kind === "cancelled" || p.kind === "off-book" || p.kind === "unknown") {
    const headline = p.kind === "expired" ? "Expired · not filled" : p.kind === "cancelled" ? "Cancelled" : p.kind === "off-book" ? "Off the book" : "Order status unknown";
    return { stage: "ended", progress: 0, etaSeconds: null, late: false, auctionPct, headline, sub: p.kind === "expired" ? "nothing left your wallet" : "" };
  }
  if (p.kind === "fill-pending") {
    const since = a.now - (a.sentAt ?? a.now);
    const eta = secs(blockMs - since);
    return {
      stage: "sent",
      progress: Math.max(0.85, Math.min(0.97, waiting)),
      etaSeconds: eta,
      late: since > blockMs * 2,
      auctionPct,
      headline: "Fill sent · confirming",
      sub: eta > 0 ? `next block ${fmtEta(eta)}` : "waiting for the next block",
    };
  }
  if (p.kind === "signing" || p.kind === "posting") {
    return { stage: "posted", progress: 0.04, etaSeconds: secs(typical), late: false, auctionPct: 0, headline: p.kind === "signing" ? "Confirm in your wallet" : "Posting to the orderbook", sub: `then usually filled in ${fmtEta(typical / 1000)}` };
  }
  // posted: the filler is matching it
  const left = typical - elapsed;
  const isLate = elapsed > late;
  const expiresIn = secs(a.expiresAt - a.now);
  return {
    stage: "matching",
    progress: Math.min(0.85, Math.max(0.08, waiting)),
    etaSeconds: secs(left),
    late: isLate,
    auctionPct,
    headline: isLate ? "Slower than usual" : "Matching with a filler",
    sub: isLate
      ? `the price keeps moving toward your minimum · expires in ${fmtEta(expiresIn)}`
      : left > 0
        ? `usually ${fmtEta(typical / 1000)} · 1–2 Rootstock blocks`
        : "any block now",
  };
}
