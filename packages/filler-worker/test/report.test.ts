import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { setDeps } from "../src/do";
import { freshFiller, resetWorld, seedBook, testDeps, tick, world } from "./helpers";

beforeEach(() => resetWorld());
afterEach(() => setDeps(testDeps));

describe("fill reports to the orderbook (POST /fills/report)", () => {
  it("broadcast → pending (with the order), success receipt → confirmed; the binding key is presented", async () => {
    const stub = freshFiller();
    const [h] = seedBook(1);
    const sent = await tick(stub);
    expect(sent.sent).toMatchObject({ kind: "fill" });
    const tx = world.sent[0]!.hash;
    expect(world.reports).toEqual([{ body: { txHash: tx, orderHash: h, status: "pending" }, key: "test-book-key" }]);

    // Still waiting for the receipt: nothing more reported.
    await tick(stub);
    expect(world.reports).toHaveLength(1);

    world.receipt = "success";
    const s = await tick(stub);
    expect(s.resolution).toMatchObject({ status: "success", kind: "fill" });
    expect(world.reports[1]).toEqual({ body: { txHash: tx, status: "confirmed" }, key: "test-book-key" });
  });

  it("a reverted receipt is reported failed, never confirmed", async () => {
    const stub = freshFiller();
    seedBook(1);
    await tick(stub);
    world.receipt = "reverted";
    const s = await tick(stub);
    expect(s.resolution?.status).toBe("reverted");
    expect(world.reports.map((r) => r.body.status)).toEqual(["pending", "failed"]);
    expect(world.reports.some((r) => r.body.status === "confirmed")).toBe(false);
  });

  it("a dropped tx is reported failed; a receipt timeout reports nothing", async () => {
    const stub = freshFiller();
    seedBook(1);
    await tick(stub);
    world.offset = 3 * 60_000;
    expect((await tick(stub)).resolution?.status).toBe("timeout");
    expect(world.reports).toHaveLength(1);
    world.offset = 16 * 60_000;
    world.known = false;
    expect((await tick(stub)).resolution?.status).toBe("dropped");
    expect(world.reports.map((r) => r.body.status)).toEqual(["pending", "failed"]);
  });

  for (const mode of ["throw", "500"] as const) {
    it(`a book that ${mode === "throw" ? "is unreachable" : "answers 500"} never fails or stalls the tick`, async () => {
      world.reportMode = mode;
      const stub = freshFiller();
      seedBook(1);
      const s1 = await tick(stub);
      expect(s1.sent).toMatchObject({ kind: "fill" });
      expect(s1.errors).toEqual([]);
      world.receipt = "success";
      const s2 = await tick(stub);
      expect(s2.resolution).toMatchObject({ status: "success" });
      expect(s2.errors).toEqual([]);
      expect(world.reports.map((r) => r.body.status)).toEqual(["pending", "confirmed"]);
    });
  }

  it("a book that never answers costs at most the report timeout", async () => {
    setDeps({ ...testDeps, reportTimeoutMs: 300 });
    world.reportMode = "hang";
    const stub = freshFiller();
    seedBook(1);
    world.receipt = "success";
    const t0 = Date.now();
    const s = await tick(stub);
    expect(s.sent).toMatchObject({ kind: "fill" });
    expect(s.errors).toEqual([]);
    expect(Date.now() - t0).toBeLessThan(3_000);
    expect(world.reports).toHaveLength(1);
  });
});
