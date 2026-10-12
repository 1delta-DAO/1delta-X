import { describe, expect, it } from "vitest";

import { FILLER_TICK_MS, RSK_BLOCK_MS, expectedFillMs, fmtEta, marketTrack } from "../src/lib/marketTrack";

const T0 = 1_791_805_000_000;
const base = { createdAt: T0, expiresAt: T0 + 300_000, decaySeconds: 210 };
const posted = { kind: "posted", simulated: false } as const;

describe("marketTrack: a market order's live stage and ETA", () => {
  it("expected fill: half a block to the auction start + a filler tick + one block to mine (~51 s); late past 3 blocks", () => {
    const e = expectedFillMs();
    expect(e.typical).toBe(Math.round(RSK_BLOCK_MS * 1.5 + FILLER_TICK_MS));
    expect(e.typical).toBeGreaterThan(45_000);
    expect(e.typical).toBeLessThan(60_000);
    expect(e.late).toBe(Math.round(RSK_BLOCK_MS * 3 + FILLER_TICK_MS));
  });

  it("posted: matching, counting down to the typical time, progress rising but never complete", () => {
    const a = marketTrack({ ...base, phase: posted, now: T0 + 10_000 });
    const b = marketTrack({ ...base, phase: posted, now: T0 + 40_000 });
    expect(a.stage).toBe("matching");
    expect(a.headline).toBe("Matching with a filler");
    expect(a.etaSeconds).toBe(Math.ceil((expectedFillMs().typical - 10_000) / 1000));
    expect(a.sub).toMatch(/^usually ~\d+ s · 1–2 Rootstock blocks$/);
    expect(b.progress).toBeGreaterThan(a.progress);
    expect(b.progress).toBeLessThanOrEqual(0.85);
    expect(a.late).toBe(false);
    expect(a.auctionPct).toBeCloseTo(10 / 210, 9);
  });

  it("past the typical time: 'any block now'; past 3 blocks: late, with the expiry", () => {
    const due = marketTrack({ ...base, phase: posted, now: T0 + expectedFillMs().typical + 1_000 });
    expect(due.etaSeconds).toBe(0);
    expect(due.sub).toBe("any block now");
    const late = marketTrack({ ...base, phase: posted, now: T0 + expectedFillMs().late + 1_000 });
    expect(late.late).toBe(true);
    expect(late.headline).toBe("Slower than usual");
    expect(late.sub).toMatch(/expires in ~\d+ (s|min)$/);
  });

  it("fill sent: confirming, next block counted from the send", () => {
    const t = marketTrack({ ...base, phase: { kind: "fill-pending", tx: "0x01" }, sentAt: T0 + 30_000, now: T0 + 40_000 });
    expect(t.stage).toBe("sent");
    expect(t.etaSeconds).toBe(Math.ceil((RSK_BLOCK_MS - 10_000) / 1000));
    expect(t.progress).toBeGreaterThanOrEqual(0.85);
    expect(t.progress).toBeLessThan(1);
  });

  it("finished: filled completes the bar; expired / cancelled end it with nothing to wait for", () => {
    const f = marketTrack({ ...base, phase: { kind: "filled", tx: "0x01" }, now: T0 + 50_000 });
    expect([f.stage, f.progress, f.etaSeconds]).toEqual(["filled", 1, null]);
    const x = marketTrack({ ...base, phase: { kind: "expired", pct: 0 }, now: T0 + 400_000 });
    expect([x.stage, x.etaSeconds, x.headline]).toEqual(["ended", null, "Expired · not filled"]);
    expect(x.auctionPct).toBe(1);
  });

  it("fmtEta", () => {
    expect(fmtEta(0.2)).toBe("~1 s");
    expect(fmtEta(44.6)).toBe("~45 s");
    expect(fmtEta(150)).toBe("~3 min");
  });
});
