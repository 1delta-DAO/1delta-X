import { describe as group, expect, it } from "vitest";

import { describe, fromUnix, toUnix } from "../src/time";

group("console time zones", () => {
  it("UTC is identity", () => {
    expect(toUnix("2026-10-25", "00:00", "UTC")).toBe(Date.UTC(2026, 9, 25) / 1000);
    expect(fromUnix(Date.UTC(2026, 9, 25, 14, 30) / 1000, "UTC")).toEqual({ date: "2026-10-25", time: "14:30" });
  });

  it("CET follows Berlin's daylight saving (CEST = UTC+2 in summer, CET = UTC+1 in winter)", () => {
    expect(toUnix("2026-07-01", "12:00", "CET")).toBe(Date.UTC(2026, 6, 1, 10, 0) / 1000);
    expect(toUnix("2026-11-10", "12:00", "CET")).toBe(Date.UTC(2026, 10, 10, 11, 0) / 1000);
    // The 2026 switch back is 25 Oct 03:00 CEST → 02:00 CET.
    expect(toUnix("2026-10-25", "01:00", "CET")).toBe(Date.UTC(2026, 9, 24, 23, 0) / 1000);
    expect(toUnix("2026-10-25", "04:00", "CET")).toBe(Date.UTC(2026, 9, 25, 3, 0) / 1000);
  });

  it("round-trips and describes", () => {
    for (const [d, t] of [["2026-03-29", "05:15"], ["2026-10-20", "18:00"], ["2026-12-31", "23:59"]] as const) {
      expect(fromUnix(toUnix(d, t, "CET")!, "CET")).toEqual({ date: d, time: t });
    }
    expect(describe(Date.UTC(2026, 9, 20, 16, 0) / 1000, "CET")).toMatch(/18:00 CEST/);
    expect(describe(Date.UTC(2026, 9, 20, 16, 0) / 1000, "UTC")).toMatch(/16:00 UTC/);
    expect(toUnix("not a date", "00:00", "UTC")).toBeNull();
  });
});
