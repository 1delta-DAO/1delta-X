import { runDurableObjectAlarm } from "cloudflare:test";
import { answersHash, claimTypedData, feedbackTypedData, type ParticipationAnswers } from "@1delta-x/sdk";
import type { Address, Hex } from "viem";
import { beforeEach, describe, expect, it } from "vitest";

import { parseRaffleConfig, raffleConfigOf } from "../src/config";
import { ADMIN_HEADER, CLIENT_IP_HEADER } from "../src/do";
import worker from "../src/index";
import { alice, bob, call, fillLog, freshBook, mallory, now, resetWorld, signed, testEnv, world } from "./helpers";

beforeEach(() => resetWorld());

const PROMOTION = "test-draw";
const TERMS = `0x${"7e".repeat(32)}` as Hex;

const ANSWERS: ParticipationAnswers = {
  rating: 4,
  safety: 3,
  purpose: ["Get RBTC"],
  ease: 4,
  fill: 4,
  friction: "none",
};

let ipSeq = 0;
const ip = () => `198.51.100.${++ipSeq % 250}`;

async function form(
  account: typeof alice,
  over: { answers?: ParticipationAnswers; issuedAt?: number; promotion?: string; terms?: Hex; participant?: Address } = {},
): Promise<string> {
  const answers = over.answers ?? ANSWERS;
  const issuedAt = BigInt(over.issuedAt ?? now());
  const participant = over.participant ?? account.address;
  const promotion = over.promotion ?? PROMOTION;
  const signature = await account.signTypedData(feedbackTypedData(Number(testEnv.CHAIN_ID), { participant, promotion, answers: answersHash(answers), issuedAt }));
  // `terms` is not part of feedback any more: when a test passes one it is an unknown field.
  return JSON.stringify({ participant, promotion, ...(over.terms ? { terms: over.terms } : {}), issuedAt: issuedAt.toString(), answers, signature });
}

async function claim(account: typeof alice, over: { draw?: string; terms?: Hex; promotion?: string; participant?: Address; issuedAt?: number } = {}): Promise<string> {
  const participant = over.participant ?? account.address;
  const promotion = over.promotion ?? PROMOTION;
  const draw = over.draw ?? "2026-10-25";
  const terms = over.terms ?? TERMS;
  const issuedAt = BigInt(over.issuedAt ?? now());
  const signature = await account.signTypedData(claimTypedData(Number(testEnv.CHAIN_ID), { participant, promotion, draw, terms, issuedAt }));
  return JSON.stringify({ participant, promotion, draw, terms, issuedAt: issuedAt.toString(), signature });
}

/** A saved draw record naming `winners` (the shape the console saves; only what the desk reads). */
const drawRecord = (winners: string[], drawnAt = now()) => ({
  kind: "period",
  period: 0,
  skipped: false,
  payouts: winners.map((_, i) => (i === 0 ? 25 : 10)),
  rules: { prizeToken: "USDRIF" },
  list: winners.map((w) => w.toLowerCase()),
  tickets: winners.map((w) => [w.toLowerCase(), 1]),
  listHash: `0x${"ab".repeat(32)}`,
  drawBlock: "123",
  result: { blockHash: `0x${"cd".repeat(32)}`, winners: winners.map((w) => w.toLowerCase()), skipped: [], drawnAt },
});

/** A book where `who` has one indexed fill as maker. */
async function bookWithFill(...who: (typeof alice)[]): Promise<DurableObjectStub> {
  const book = freshBook();
  world.head = 50n;
  world.logs = [];
  let block = 10n;
  for (const a of who) {
    const o = await signed(a);
    await call(book, "POST", "/orders", o.body, ip());
    world.filled.set(`${o.hash}@${block}`, 1_000n);
    world.logs.push(fillLog(o.hash, a.address, block, 0));
    block++;
  }
  await runDurableObjectAlarm(book);
  world.logs = [];
  return book;
}

async function admin(book: DurableObjectStub, method: string, path: string, payload?: unknown) {
  const res = await book.fetch(`https://book.test${path}`, {
    method,
    headers: { [CLIENT_IP_HEADER]: ip(), [ADMIN_HEADER]: "1", ...(payload !== undefined ? { "content-type": "application/json" } : {}) },
    ...(payload !== undefined ? { body: JSON.stringify(payload) } : {}),
  });
  return { status: res.status, body: (await res.json()) as Record<string, unknown> };
}

describe("prize draw — participation entries", () => {
  it("feedback is gated on a first fill (TC §4.1: it is not an entry; the draw lists every trader)", async () => {
    const book = await bookWithFill(alice);

    const before = await call(book, "GET", `/raffle/status/${bob.address}`, undefined, ip());
    expect(before.body).toMatchObject({ live: true, promotion: PROMOTION, terms: TERMS, traded: false, entered: false });
    // No swap → no entry, whatever the app shows.
    expect((await call(book, "POST", "/raffle/entries", await form(bob), ip())).status).toBe(403);

    const st = await call(book, "GET", `/raffle/status/${alice.address}`, undefined, ip());
    expect(st.body).toMatchObject({ traded: true, entered: false });

    const res = await call(book, "POST", "/raffle/entries", await form(alice), ip());
    expect(res.status).toBe(201);
    expect(res.body).toMatchObject({ entered: true, updated: false, address: alice.address.toLowerCase() });

    const after = await call(book, "GET", `/raffle/status/${alice.address}`, undefined, ip());
    expect(after.body).toMatchObject({ traded: true, entered: true });
    const list = await call(book, "GET", "/raffle/entrants", undefined, ip());
    expect(list.body).toMatchObject({ promotion: PROMOTION, count: 1, entrants: [{ address: alice.address.toLowerCase() }] });
    // The public list carries no answers.
    expect(JSON.stringify(list.body)).not.toContain("answers");
    expect((await call(book, "GET", "/raffle", undefined, ip())).body).toMatchObject({ live: true, entrants: 1, rules: { periodDays: 1, prizes: [10], prizeToken: "USDRIF", pot: 100, paidOut: 0 } });
  });

  it("refuses a forged participant, another promotion, a stale or bad form; the Terms are not part of feedback", async () => {
    const book = await bookWithFill(alice);
    // Mallory signs a form naming alice.
    expect((await call(book, "POST", "/raffle/entries", await form(mallory, { participant: alice.address }), ip())).status).toBe(401);
    expect((await call(book, "POST", "/raffle/entries", await form(alice, { promotion: "other" }), ip())).status).toBe(409);
    expect((await call(book, "POST", "/raffle/entries", await form(alice, { terms: TERMS }), ip())).status).toBe(400);
    expect((await call(book, "POST", "/raffle/entries", await form(alice, { issuedAt: now() - 3 * 86400 }), ip())).status).toBe(400);
    const bad = await call(book, "POST", "/raffle/entries", await form(alice, { answers: { ...ANSWERS, ease: 9 } }), ip());
    expect(bad.status).toBe(400);
    expect(String(bad.body.error)).toMatch(/1 to 5/);
    // Answers swapped after signing: the hash no longer matches.
    const signedBody = JSON.parse(await form(alice)) as Record<string, unknown>;
    const tampered = JSON.stringify({ ...signedBody, answers: { ...ANSWERS, ease: 1 } });
    expect((await call(book, "POST", "/raffle/entries", tampered, ip())).status).toBe(401);
    expect((await call(book, "GET", "/raffle/entrants", undefined, ip())).body.count).toBe(0);
  });

  it("lets a newer form replace the answers and refuses replaying the older one", async () => {
    const book = await bookWithFill(alice);
    const first = await form(alice, { issuedAt: now() - 60 });
    expect((await call(book, "POST", "/raffle/entries", first, ip())).status).toBe(201);
    const second = await form(alice, { answers: { ...ANSWERS, ease: 2 } });
    const res = await call(book, "POST", "/raffle/entries", second, ip());
    expect(res.status).toBe(200);
    expect(res.body.updated).toBe(true);
    expect((await call(book, "POST", "/raffle/entries", first, ip())).status).toBe(409);

    const exp = await admin(book, "GET", "/raffle/admin/entries");
    expect(exp.status).toBe(200);
    const entries = exp.body.entries as Array<Record<string, unknown>>;
    expect(entries).toHaveLength(1);
    expect(entries[0]!.answers).toMatchObject({ ease: 2 });
  });

  it("takes no personal data: a contact field is refused, the export has none, and only an admin reads it", async () => {
    const book = await bookWithFill(alice);
    const refused = await call(book, "POST", "/raffle/entries", await form(alice, { answers: { ...ANSWERS, contact: "@alice" } }), ip());
    expect(refused.status).toBe(400);
    expect(String(refused.body.error)).toMatch(/unknown question "contact"/);
    expect((await call(book, "POST", "/raffle/entries", await form(alice), ip())).status).toBe(201);
    expect((await call(book, "GET", "/raffle/admin/entries", undefined, ip())).status).toBe(403);
    const e = ((await admin(book, "GET", "/raffle/admin/entries")).body.entries as Array<Record<string, unknown>>)[0]!;
    expect("contact" in e).toBe(false);
    expect((await admin(book, "POST", "/raffle/admin/purge-contacts")).status).toBe(404);
  });

  it("a drawn winner claims by signing the confirmations; nobody else can, and the window closes", async () => {
    const book = await bookWithFill(alice, bob);
    const st0 = await call(book, "GET", `/raffle/status/${alice.address}`, undefined, ip());
    expect(st0.body.wins).toEqual([]);
    // Before any draw: no claim possible.
    expect((await call(book, "POST", "/raffle/claims", await claim(alice), ip())).status).toBe(403);
    expect((await admin(book, "PUT", "/raffle/admin/draws/2026-10-25", drawRecord([alice.address, bob.address]))).status).toBe(200);

    const st = await call(book, "GET", `/raffle/status/${alice.address}`, undefined, ip());
    expect(st.body.wins).toMatchObject([{ day: "2026-10-25", payout: 25, token: "USDRIF", claimed: false }]);
    // Mallory cannot claim alice's prize, nor sign as alice.
    expect((await call(book, "POST", "/raffle/claims", await claim(mallory), ip())).status).toBe(403);
    expect((await call(book, "POST", "/raffle/claims", await claim(mallory, { participant: alice.address }), ip())).status).toBe(401);
    // Other Terms, another promotion, stale: refused.
    expect((await call(book, "POST", "/raffle/claims", await claim(alice, { terms: `0x${"00".repeat(32)}` }), ip())).status).toBe(409);
    expect((await call(book, "POST", "/raffle/claims", await claim(alice, { promotion: "other" }), ip())).status).toBe(409);
    expect((await call(book, "POST", "/raffle/claims", await claim(alice, { issuedAt: now() - 3 * 86400 }), ip())).status).toBe(400);

    const ok = await call(book, "POST", "/raffle/claims", await claim(alice), ip());
    expect(ok.status).toBe(201);
    expect(ok.body).toMatchObject({ claimed: true, day: "2026-10-25", payout: 25, token: "USDRIF" });
    expect((await call(book, "POST", "/raffle/claims", await claim(alice), ip())).body).toMatchObject({ claimed: true, already: true });
    expect(((await call(book, "GET", `/raffle/status/${alice.address}`, undefined, ip())).body.wins as Array<Record<string, unknown>>)[0]).toMatchObject({ claimed: true });
    // Public: the draw record shows who has claimed, no signatures.
    const pub = (await call(book, "GET", "/raffle/draws", undefined, ip())).body.draws as Array<Record<string, unknown>>;
    expect(pub[0]!.claimed).toEqual([alice.address.toLowerCase()]);
    expect(JSON.stringify(pub)).not.toContain('"signature"');

    // Bob waits past the window (14 days): the desk refuses, an admin can still confirm by hand.
    world.offset += 15 * 86400;
    const late = await call(book, "POST", "/raffle/claims", await claim(bob), ip());
    expect(late.status).toBe(403);
    expect(String(late.body.error)).toMatch(/window/);
    expect((await admin(book, "POST", "/raffle/admin/claims", { address: bob.address, day: "2026-10-25" })).status).toBe(400); // no note
    expect((await admin(book, "POST", "/raffle/admin/claims", { address: bob.address, day: "2026-10-25", note: "confirmed by signed message in Telegram" })).status).toBe(201);
    expect((await admin(book, "POST", "/raffle/admin/claims", { address: mallory.address, day: "2026-10-25", note: "x" })).status).toBe(409);
    const all = (await admin(book, "GET", "/raffle/admin/claims")).body.claims as Array<Record<string, unknown>>;
    expect(all.map((c) => [c.address, c.source])).toEqual([
      [alice.address.toLowerCase(), "signed"],
      [bob.address.toLowerCase(), "manual"],
    ]);
    // Deleting the draw record drops its claims; a reset removes everything.
    await admin(book, "DELETE", "/raffle/admin/draws/2026-10-25");
    expect(((await admin(book, "GET", "/raffle/admin/claims")).body.claims as unknown[]).length).toBe(0);
  });

  it("closes entries at RAFFLE_ENDS_AT", async () => {
    const book = await bookWithFill(alice);
    world.offset = 4_102_444_800 - Math.floor(Date.now() / 1000) + 10;
    const res = await call(book, "POST", "/raffle/entries", await form(alice), ip());
    expect(res.status).toBe(403);
    expect(String(res.body.error)).toMatch(/closed/);
    expect((await call(book, "GET", `/raffle/status/${alice.address}`, undefined, ip())).body.live).toBe(false);
  });

  it("the entry worker sets the admin header only for the right bearer token", async () => {
    const get = (auth?: string) =>
      worker.fetch(
        new Request("https://book.test/raffle/admin/entries", { headers: { "cf-connecting-ip": "203.0.113.9", ...(auth ? { authorization: auth } : {}) } }),
        testEnv,
      );
    expect((await get()).status).toBe(403);
    expect((await get("Bearer wrong")).status).toBe(403);
    // A client cannot set the internal header itself.
    const spoof = await worker.fetch(new Request("https://book.test/raffle/admin/entries", { headers: { "cf-connecting-ip": "203.0.113.9", [ADMIN_HEADER]: "1" } }), testEnv);
    expect(spoof.status).toBe(403);
    expect((await get("Bearer test-admin-token")).status).toBe(200);
  });
});

describe("prize draw — admin", () => {
  const cfg = { id: "rehearsal-1", terms: TERMS, startsAt: 1_600_000_000, endsAt: 4_102_444_800, qualifierUsd: 20, exclude: [], testers: [] as string[] };

  it("every admin route needs the admin header", async () => {
    const book = freshBook();
    for (const [m, p] of [["GET", "/raffle/admin/config"], ["PUT", "/raffle/admin/config"], ["POST", "/raffle/admin/reset"], ["GET", "/raffle/admin/promotions"], ["DELETE", `/raffle/admin/entries/${alice.address}`]] as const) {
      expect((await call(book, m, p, m === "GET" || m === "DELETE" ? undefined : "{}", ip())).status).toBe(403);
    }
  });

  it("overrides the env config, switches it off, and falls back to the env", async () => {
    const book = freshBook();
    expect((await admin(book, "GET", "/raffle/admin/config")).body).toMatchObject({ source: "env", effective: { id: PROMOTION } });
    expect((await admin(book, "PUT", "/raffle/admin/config", { ...cfg, id: "Bad Id" })).status).toBe(400);
    expect((await admin(book, "PUT", "/raffle/admin/config", cfg)).body).toMatchObject({ source: "admin", effective: { id: "rehearsal-1" }, live: true });
    expect((await call(book, "GET", "/raffle", undefined, ip())).body).toMatchObject({ live: true, promotion: "rehearsal-1" });
    expect((await admin(book, "PUT", "/raffle/admin/config", { disabled: true })).body).toMatchObject({ source: "disabled", effective: null });
    expect((await call(book, "GET", "/raffle", undefined, ip())).body).toEqual({ live: false });
    expect((await admin(book, "DELETE", "/raffle/admin/config")).body).toMatchObject({ source: "env", effective: { id: PROMOTION } });
  });

  it("test mode: live only for testers, invisible to everyone else", async () => {
    const book = await bookWithFill(alice, bob);
    await admin(book, "PUT", "/raffle/admin/config", { ...cfg, testers: [alice.address] });
    expect((await call(book, "GET", "/raffle", undefined, ip())).body).toEqual({ live: false });
    expect((await call(book, "GET", `/raffle/status/${bob.address}`, undefined, ip())).body.live).toBe(false);
    expect((await call(book, "GET", `/raffle/status/${alice.address}`, undefined, ip())).body).toMatchObject({ live: true, testMode: true, traded: true });
    expect((await call(book, "POST", "/raffle/entries", await form(bob, { promotion: "rehearsal-1" }), ip())).status).toBe(403);
    expect((await call(book, "POST", "/raffle/entries", await form(alice, { promotion: "rehearsal-1" }), ip())).status).toBe(201);
    expect((await call(book, "GET", "/raffle/entrants", undefined, ip())).status).toBe(404);
  });

  it("removes a feedback form by hand (a data-deletion request); forms cannot be added by hand", async () => {
    const book = await bookWithFill(alice);
    expect((await admin(book, "POST", "/raffle/admin/entries", { address: alice.address, note: "x" })).status).toBe(405);
    expect((await call(book, "POST", "/raffle/entries", await form(alice), ip())).status).toBe(201);
    expect((await admin(book, "DELETE", `/raffle/admin/entries/${alice.address}`)).body).toMatchObject({ removed: true });
    expect((await call(book, "GET", "/raffle/entrants", undefined, ip())).body.count).toBe(0);
  });

  it("saves draw records, serves them publicly, and a reset wipes a promotion", async () => {
    const book = await bookWithFill(alice);
    await call(book, "POST", "/raffle/entries", await form(alice), ip());
    const rec = { listHash: `0x${"ab".repeat(32)}`, list: [alice.address.toLowerCase()], drawBlock: "123" };
    expect((await admin(book, "PUT", "/raffle/admin/draws/2026-10-25", rec)).status).toBe(200);
    expect((await call(book, "GET", "/raffle/draws", undefined, ip())).body).toMatchObject({ promotion: PROMOTION, draws: [{ day: "2026-10-25", ...rec }] });
    expect((await admin(book, "GET", "/raffle/admin/promotions")).body).toMatchObject({ promotions: [{ promotion: PROMOTION, entries: 1, draws: 1 }] });
    expect((await admin(book, "POST", "/raffle/admin/reset", { promotion: PROMOTION })).status).toBe(400);
    expect((await admin(book, "POST", "/raffle/admin/reset", { promotion: PROMOTION, confirm: PROMOTION })).body).toMatchObject({ entriesRemoved: 1, drawsRemoved: 1, claimsRemoved: 0 });
    expect((await admin(book, "GET", "/raffle/admin/promotions")).body).toEqual({ promotions: [] });
  });

  it("looks an address up for a support case", async () => {
    const book = await bookWithFill(alice);
    expect((await admin(book, "GET", `/raffle/admin/status?address=${alice.address}`)).body).toMatchObject({ fills: 1, entered: false, promotion: PROMOTION });
  });
});

describe("raffleConfigOf", () => {
  it("validates the draw rules from the console", () => {
    const base = { id: "x", terms: TERMS };
    expect(parseRaffleConfig({ ...base, periodDays: 7, minQualifiers: 1, prizes: [50, 25, 25], prizeToken: "USD₮0", onePrizePerAddress: false })).toMatchObject({ periodDays: 7, minQualifiers: 1, prizes: [50, 25, 25], prizeToken: "USD₮0", onePrizePerAddress: false });
    expect(() => parseRaffleConfig({ ...base, periodDays: 0 })).toThrow(/periodDays/);
    expect(() => parseRaffleConfig({ ...base, periodDays: 2.5 })).toThrow(/periodDays/);
    expect(() => parseRaffleConfig({ ...base, minQualifiers: 0 })).toThrow(/minQualifiers/);
    expect(() => parseRaffleConfig({ ...base, prizes: [] })).toThrow(/prizes/);
    expect(() => parseRaffleConfig({ ...base, prizes: [25, -1] })).toThrow(/positive/);
    expect(() => parseRaffleConfig({ ...base, prizeToken: "not a token!" })).toThrow(/prizeToken/);
    expect(parseRaffleConfig({ ...base, pot: 0 }).pot).toBe(0);
    expect(() => parseRaffleConfig({ ...base, pot: -5 })).toThrow(/pot/);
  });

  it("is off without RAFFLE_ID and validates the rest", () => {
    expect(raffleConfigOf({})).toBeUndefined();
    expect(raffleConfigOf({ RAFFLE_ID: "x", RAFFLE_TERMS_HASH: TERMS })).toMatchObject({ id: "x", startsAt: 0, periodDays: 1, minQualifiers: 3, prizes: [10], prizeToken: "USDRIF", onePrizePerAddress: true, pot: 100 });
    expect(() => raffleConfigOf({ RAFFLE_ID: "Bad Id", RAFFLE_TERMS_HASH: TERMS })).toThrow(/RAFFLE_ID/);
    expect(() => raffleConfigOf({ RAFFLE_ID: "x" })).toThrow(/RAFFLE_TERMS_HASH/);
    expect(() => raffleConfigOf({ RAFFLE_ID: "x", RAFFLE_TERMS_HASH: TERMS, RAFFLE_STARTS_AT: "10", RAFFLE_ENDS_AT: "5" })).toThrow(/after/);
  });
});
