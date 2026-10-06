/**
 * M3 (staging 2026-10-05): a lost broadcast stalled the filler for up to 15 min. The
 * pending record now carries the signed raw tx; a tx the node DEFINITELY does not know
 * is re-broadcast verbatim (same nonce, same hash); an RPC error is never read as a drop.
 */
import { HttpRequestError, keccak256, parseTransaction, TransactionNotFoundError, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { describe, expect, it } from "vitest";

import { loadConfig } from "../src/config";
import { BACKOFF, broadcast, GAS, Guard, REBROADCAST, resolvePending, type PendingTx } from "../src/guard";
import { Budget } from "../src/policy";

const KEY = ("0x" + "11".repeat(32)) as Hex;
const ACCOUNT = privateKeyToAccount(KEY);
const ENV = {
  PRIVATE_KEY: KEY,
  SETTLEMENT: "0x0000000000000000000000000000000000000001",
  PERMIT3: "0x0000000000000000000000000000000000000002",
  LENS: "0x0000000000000000000000000000000000000003",
  ORDERBOOK_URL: "http://unused.invalid",
};
const policy = () => loadConfig(ENV).gas;
const SOLVER = "0x00000000000000000000000000000000000050a1" as const;

/** A node: `known` holds the hashes in its mempool; sends can be lost or refused; lookups can fail. */
function node() {
  const n = {
    known: new Set<string>(),
    mined: new Set<string>(),
    sends: [] as Hex[],
    /** The next sendRawTransaction never reaches the node, and the client sees a transport error. */
    loseNext: false,
    /** sendRawTransaction refuses with this message. */
    refuse: undefined as string | undefined,
    /** getTransaction fails with an RPC error (not a "not found"). */
    lookupError: undefined as Error | undefined,
    lookups: 0,
    /** Nonces consumed by txs this filler did not send (a hand-replacement). */
    foreign: 0,
    /** Receipt status of a mined tx. */
    status: "success" as "success" | "reverted",
    /** The next N receipt reads miss even for a mined tx (it mines between two reads). */
    receiptMisses: 0,
    /** getTransactionCount fails with an RPC error. */
    countError: undefined as Error | undefined,
  };
  const pub = {
    getTransactionCount: async () => {
      if (n.countError) throw n.countError;
      return n.mined.size + n.foreign;
    },
    sendRawTransaction: async ({ serializedTransaction }: { serializedTransaction: Hex }) => {
      n.sends.push(serializedTransaction);
      if (n.loseNext) {
        n.loseNext = false;
        throw new HttpRequestError({ url: "http://rpc.invalid", details: "socket hang up" });
      }
      if (n.refuse) throw new Error(n.refuse);
      const hash = keccak256(serializedTransaction);
      n.known.add(hash);
      return hash;
    },
    getTransaction: async ({ hash }: { hash: Hex }) => {
      n.lookups++;
      if (n.lookupError) throw n.lookupError;
      if (!n.known.has(hash)) throw new TransactionNotFoundError({ hash });
      return { hash };
    },
    getTransactionReceipt: async ({ hash }: { hash: Hex }) => {
      if (!n.mined.has(hash) || n.receiptMisses-- > 0) throw new Error("Transaction receipt could not be found");
      return { status: n.status, gasUsed: 100_000n, effectiveGasPrice: 1n };
    },
  };
  return { n, chain: { pub, account: ACCOUNT, me: ACCOUNT.address, chainId: 30 } as never };
}

const ORDER = `0x${"01".repeat(32)}` as const;
const TOKEN = "0x00000000000000000000000000000000000070c1" as const;
const send = (chain: never, g: Guard, now: number, reserve?: bigint) =>
  broadcast(
    chain,
    g,
    {
      to: SOLVER, data: "0x1234", gas: 100_000n, gasPrice: 1n, kind: "fill", strategy: "route", orderHash: ORDER,
      ...(reserve !== undefined ? { reserve: { budget: "inventory", token: TOKEN, amount: reserve } } : {}),
    },
    now,
  );
/** A Guard with a 1000-unit "inventory" budget registered (the reservation sends can make). */
const withBudget = (commit?: () => Promise<void>) => {
  const g = new Guard(policy(), {}, () => {}, commit);
  const b = new Budget({ [TOKEN]: 1_000n });
  g.register("inventory", b);
  return { g, b };
};

describe("M3: the pending record keeps the signed bytes", () => {
  it("broadcast records the raw tx (its keccak is the hash) and the broadcast time", async () => {
    const { chain } = node();
    const g = new Guard(policy());
    const r = await send(chain, g, 1_000);
    expect(r.kind).toBe("sent");
    expect(g.pending).toMatchObject({ raw: expect.stringMatching(/^0x/), lastBroadcastAt: 1_000, sentAt: 1_000 });
    expect(keccak256(g.pending!.raw!)).toBe(g.pending!.hash);
    expect(parseTransaction(g.pending!.raw!)).toMatchObject({ nonce: 0, gas: 100_000n });
  });
});

describe("M3: a broadcast lost in flight is re-broadcast verbatim", () => {
  it("unknown to the node ≥ 60 s after its broadcast → the SAME bytes again; the tx then mines and resolves", async () => {
    const { n, chain } = node();
    const g = new Guard(policy());
    n.lookupError = new Error("connection reset"); // the post-send check cannot tell either
    n.loseNext = true;
    const r = await send(chain, g, 0);
    // An RPC error on the check is no evidence of a refusal: kept pending, NOT undone.
    expect(r.kind).toBe("sent");
    const raw = g.pending!.raw!;
    n.lookupError = undefined;
    expect(n.known.size).toBe(0);

    // Inside the 60 s window the node is not even asked.
    const lookups = n.lookups;
    expect((await resolvePending(chain, g, 30_000))?.status).toBe("waiting");
    expect(n.lookups).toBe(lookups);
    // 60 s after the broadcast: definitely unknown → re-broadcast the recorded bytes.
    const res = await resolvePending(chain, g, REBROADCAST.afterMs);
    expect(res).toMatchObject({ status: "waiting", rebroadcast: { attempt: 1 } });
    expect(n.sends).toEqual([raw, raw]);
    expect(g.pending).toMatchObject({ rebroadcasts: 1, lastBroadcastAt: REBROADCAST.afterMs, hash: keccak256(raw) });
    // Now known: no further re-broadcast; once mined, it resolves as usual.
    expect((await resolvePending(chain, g, REBROADCAST.afterMs * 2 + 1))?.rebroadcast).toBeUndefined();
    expect(n.sends).toHaveLength(2);
    n.mined.add(keccak256(raw));
    expect((await resolvePending(chain, g, REBROADCAST.afterMs * 3))?.status).toBe("success");
    expect(g.pending).toBeUndefined();
  });

  it("re-broadcasts are spaced ≥ 60 s apart and bounded; a refused re-broadcast is reported, not fatal", async () => {
    const { n, chain } = node();
    const g = new Guard(policy());
    n.loseNext = true;
    n.lookupError = new Error("timeout");
    await send(chain, g, 0);
    n.lookupError = undefined;
    n.refuse = "nonce too low";
    const attempts: number[] = [];
    for (let t = 10_000; t < BACKOFF.pendingDropMs; t += 10_000) {
      const res = await resolvePending(chain, g, t);
      if (res?.rebroadcast) {
        attempts.push(t);
        expect(res.rebroadcast.error).toMatch(/nonce too low/);
      }
    }
    expect(attempts).toEqual([60_000, 120_000, 180_000, 240_000, 300_000]); // REBROADCAST.max = 5
    expect(n.sends).toHaveLength(1 + REBROADCAST.max);
    // Still definitely unknown at 15 min: dropped, as before.
    expect((await resolvePending(chain, g, BACKOFF.pendingDropMs))?.status).toBe("dropped");
  });

  it("a pre-2026-10 record without raw bytes is never re-broadcast (but is still dropped after 15 min)", async () => {
    const { n, chain } = node();
    const g = new Guard(policy());
    const p: PendingTx = { hash: `0x${"ab".repeat(32)}`, nonce: 0, gasLimit: "1", gasPrice: "1", kind: "fill", strategy: "route", expiry: "0", sentAt: 0 };
    g.setPending(p);
    expect((await resolvePending(chain, g, 120_000))?.rebroadcast).toBeUndefined();
    expect(n.sends).toHaveLength(0);
    expect((await resolvePending(chain, g, BACKOFF.pendingDropMs))?.status).toBe("dropped");
  });
});

describe("M3: only a definite TransactionNotFoundError means 'not known'", () => {
  for (const [what, err] of [
    ["a timeout", new Error("The request took too long to respond.")],
    ["an HTTP 429", new HttpRequestError({ url: "http://rpc.invalid", status: 429, details: "Too Many Requests" })],
    ["a 5xx", new HttpRequestError({ url: "http://rpc.invalid", status: 503 })],
  ] as const) {
    it(`${what} on the lookup is no evidence: no re-broadcast, never dropped`, async () => {
      const { n, chain } = node();
      const g = new Guard(policy());
      n.loseNext = true;
      n.lookupError = err;
      expect((await send(chain, g, 0)).kind).toBe("sent");
      for (const t of [60_000, 120_000, BACKOFF.pendingDropMs, BACKOFF.pendingDropMs * 3]) {
        const res = await resolvePending(chain, g, t);
        expect(res?.status === "waiting" || res?.status === "timeout").toBe(true);
        expect(res?.rebroadcast).toBeUndefined();
      }
      expect(g.pending).toBeDefined();
      expect(n.sends).toHaveLength(1);
    });
  }

  it("broadcast: a send the node refused AND does not know is undone (charges and record)", async () => {
    const { n, chain } = node();
    const g = new Guard(policy());
    n.refuse = "insufficient funds";
    const r = await send(chain, g, 0);
    expect(r).toMatchObject({ kind: "failed", reason: expect.stringMatching(/insufficient funds/) });
    expect(g.pending).toBeUndefined();
  });
});

describe("M3: the 'untracked tx in flight' refusal streak is tracked for the alert", () => {
  it("since = the first refusal of the streak, lastAt = the latest; a send that passes the check clears it", async () => {
    const { n, chain } = node();
    const pub = (chain as unknown as { pub: Record<string, unknown> }).pub;
    let extra = 1;
    pub.getTransactionCount = async ({ blockTag }: { blockTag: string }) => n.mined.size + (blockTag === "pending" ? extra : 0);
    const g = new Guard(policy());
    expect((await send(chain, g, 1_000)).kind).toBe("refused");
    expect((await send(chain, g, 5_000)).kind).toBe("refused");
    expect(g.untracked).toEqual({ since: 1_000, lastAt: 5_000, count: 1 });
    expect(g.toJSON().untracked).toEqual({ since: 1_000, lastAt: 5_000, count: 1 }); // persisted
    expect(new Guard(policy(), g.toJSON()).untracked).toEqual({ since: 1_000, lastAt: 5_000, count: 1 });
    extra = 0;
    expect((await send(chain, g, 9_000)).kind).toBe("sent");
    expect(g.untracked).toBeUndefined();
  });
});

describe("review 2026-10-05 §6: a receipt after RECEIPT_TIMEOUT_MS still settles the gas", () => {
  for (const status of ["success", "reverted"] as const) {
    it(`late ${status}: gas → the receipt's cost (as the fills row records it); the reservation stays final`, async () => {
      const { n, chain } = node();
      const { g, b } = withBudget();
      await send(chain, g, 0, 400n);
      expect(g.gas.remaining(GAS, 0)).toBe(policy().hourlyWei - 100_000n); // limit × price
      const timeout = policy().receiptTimeoutMs;
      expect((await resolvePending(chain, g, timeout))?.status).toBe("timeout");
      n.status = status;
      n.mined.add(g.pending!.hash);
      const r = await resolvePending(chain, g, timeout + 1_000);
      // gasUsed 100k × effectiveGasPrice 1 — the SAME figure for gas_used and gas_cost_wei.
      expect(r).toMatchObject({ status, gasUsed: 100_000n, gasCostWei: 100_000n });
      expect(g.gas.remaining(GAS, timeout + 1_000)).toBe(policy().hourlyWei - 100_000n);
      expect(b.remaining(TOKEN, timeout + 1_000)).toBe(600n); // not released, even on a revert
    });
  }

  it("the receipt's gas is what is charged, not the limit (gasUsed < limit)", async () => {
    const { n, chain } = node();
    const g = new Guard(policy());
    const pub = (chain as unknown as { pub: Record<string, unknown> }).pub;
    await send(chain, g, 0);
    await resolvePending(chain, g, policy().receiptTimeoutMs);
    pub.getTransactionReceipt = async () => ({ status: "success", gasUsed: 60_000n, effectiveGasPrice: 1n });
    n.mined.add(g.pending!.hash);
    expect(await resolvePending(chain, g, policy().receiptTimeoutMs + 1)).toMatchObject({ gasCostWei: 60_000n });
    expect(g.gas.remaining(GAS, policy().receiptTimeoutMs + 1)).toBe(policy().hourlyWei - 60_000n);
  });

  it("a receipt after the hourly window: nothing left to settle, the row still gets the real cost", async () => {
    const { n, chain } = node();
    const g = new Guard(policy());
    await send(chain, g, 0);
    n.lookupError = new Error("timeout"); // the overdue lookups cannot tell: it stays pending
    await resolvePending(chain, g, policy().receiptTimeoutMs);
    n.mined.add(g.pending!.hash);
    const t = 2 * 3_600_000;
    expect(await resolvePending(chain, g, t)).toMatchObject({ status: "success", gasCostWei: 100_000n });
    expect(g.gas.remaining(GAS, t)).toBe(policy().hourlyWei);
  });
});

describe("review 2026-10-05 §6: a nonce taken by another tx resolves at once", () => {
  it("overdue, no receipt, mined nonce past ours → dropped as replaced: no re-broadcasts, no 15 min wait", async () => {
    const { n, chain } = node();
    const g = new Guard(policy());
    await send(chain, g, 0);
    n.known.clear(); // the replacement evicted it from the mempool
    n.foreign = 1; // a hand-sent tx mined at our nonce
    // Not overdue yet: not even the nonce is read.
    expect((await resolvePending(chain, g, 30_000))?.status).toBe("waiting");
    const r = await resolvePending(chain, g, REBROADCAST.afterMs);
    expect(r).toMatchObject({ status: "dropped", replaced: true, gasCostWei: 100_000n });
    expect(g.pending).toBeUndefined();
    expect(n.sends).toHaveLength(1); // never re-broadcast
    expect(g.entry(ORDER)?.reason).toMatch(/replaced/);
    expect(g.admit(ORDER, "route", REBROADCAST.afterMs)).toMatchObject({ global: true }); // the drop's short backoff
    expect(g.admit(ORDER, "route", REBROADCAST.afterMs + BACKOFF.simBaseMs)).toBeUndefined();
    // Charges kept: a same-data speed-up may have filled the order under another hash.
    expect(g.gas.remaining(GAS, REBROADCAST.afterMs)).toBe(policy().hourlyWei - 100_000n);
  });

  it("our own tx mining between the two reads is a success, not a replacement", async () => {
    const { n, chain } = node();
    const g = new Guard(policy());
    await send(chain, g, 0);
    n.mined.add(g.pending!.hash);
    n.receiptMisses = 1; // the first read misses it
    expect(await resolvePending(chain, g, REBROADCAST.afterMs)).toMatchObject({ status: "success", gasCostWei: 100_000n });
  });

  it("an RPC error on the nonce read changes nothing; a pre-2026-10 record (nonce -1) is never checked", async () => {
    const { n, chain } = node();
    const g = new Guard(policy());
    await send(chain, g, 0);
    n.foreign = 1;
    n.countError = new Error("429");
    expect((await resolvePending(chain, g, REBROADCAST.afterMs))?.status).toBe("waiting");
    n.countError = undefined;
    g.setPending({ ...g.pending!, nonce: -1 });
    expect((await resolvePending(chain, g, REBROADCAST.afterMs + 30_000))?.status).toBe("waiting");
    expect(g.pending).toBeDefined();
  });
});

describe("review 2026-10-05 §6: a failed commit rolls the send back", () => {
  it("storage throws in commit → nothing broadcast, no pending, gas and reservation released; the error propagates", async () => {
    const { n, chain } = node();
    let fail = true;
    const { g, b } = withBudget(async () => {
      if (fail) throw new Error("storage put failed");
    });
    await expect(send(chain, g, 0, 400n)).rejects.toThrow(/storage put failed/);
    expect(n.sends).toHaveLength(0);
    expect(g.pending).toBeUndefined();
    expect(g.toJSON().pending).toBeUndefined();
    expect(g.gas.remaining(GAS, 0)).toBe(policy().hourlyWei);
    expect(b.remaining(TOKEN, 0)).toBe(1_000n);
    // The next tick can send at once (no stale pending record to wait out).
    fail = false;
    expect((await send(chain, g, 1_000, 400n)).kind).toBe("sent");
    expect(n.sends).toHaveLength(1);
    expect(b.remaining(TOKEN, 1_000)).toBe(600n);
  });
});
