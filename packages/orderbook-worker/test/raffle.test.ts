import { runDurableObjectAlarm } from "cloudflare:test";
import { answersHash, feedbackTypedData, type ParticipationAnswers } from "@1delta-x/sdk";
import type { Address, Hex } from "viem";
import { beforeEach, describe, expect, it } from "vitest";

import { parseRaffleConfig, raffleConfigOf } from "../src/config";
import { ADMIN_HEADER, CLIENT_IP_HEADER } from "../src/do";
import worker from "../src/index";
import { alice, bob, call, fillLog, freshBook, mallory, now, resetWorld, signed, testEnv, world } from "./helpers";

beforeEach(() => resetWorld());

const PROMOTION = "test-draw";

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
  over: { answers?: ParticipationAnswers; issuedAt?: number; promotion?: string; terms?: string; participant?: Address } = {},
): Promise<string> {
  const answers = over.answers ?? ANSWERS;
  const issuedAt = BigInt(over.issuedAt ?? now());
  const participant = over.participant ?? account.address;
  const promotion = over.promotion ?? PROMOTION;
  const signature = await account.signTypedData(feedbackTypedData(Number(testEnv.CHAIN_ID), { participant, promotion, answers: answersHash(answers), issuedAt }));
  // `terms` is not part of feedback any more: when a test passes one it is an unknown field.
  return JSON.stringify({ participant, promotion, ...(over.terms ? { terms: over.terms } : {}), issuedAt: issuedAt.toString(), answers, signature });
}

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
    expect(before.body).toMatchObject({ live: true, promotion: PROMOTION, qualifierUsd: 20, traded: false, entered: false });
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
    expect((await call(book, "GET", "/raffle", undefined, ip())).body).toMatchObject({ live: true, feedback: 1 });
  });

  it("refuses a forged participant, another promotion, a stale or bad form; the Terms are not part of feedback", async () => {
    const book = await bookWithFill(alice);
    // Mallory signs a form naming alice.
    expect((await call(book, "POST", "/raffle/entries", await form(mallory, { participant: alice.address }), ip())).status).toBe(401);
    expect((await call(book, "POST", "/raffle/entries", await form(alice, { promotion: "other" }), ip())).status).toBe(409);
    expect((await call(book, "POST", "/raffle/entries", await form(alice, { terms: `0x${"7e".repeat(32)}` }), ip())).status).toBe(400);
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

  it("closes entries at RAFFLE_ENDS_AT", async () => {
    const book = await bookWithFill(alice);
    world.offset = 4_102_444_800 - Math.floor(Date.now() / 1000) + 10;
    const res = await call(book, "POST", "/raffle/entries", await form(alice), ip());
    expect(res.status).toBe(403);
    expect(String(res.body.error)).toMatch(/ended/);
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
  const cfg = { id: "rehearsal-1", startsAt: 1_600_000_000, endsAt: 4_102_444_800, qualifierUsd: 20, exclude: [] as string[] };

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

  it("the exclusion list is saved lower-case and published to the console only", async () => {
    const book = freshBook();
    const saved = await admin(book, "PUT", "/raffle/admin/config", { ...cfg, exclude: [alice.address.toUpperCase().replace("0X", "0x")] });
    expect(saved.body).toMatchObject({ source: "admin", effective: { exclude: [alice.address.toLowerCase()] } });
    expect((await admin(book, "PUT", "/raffle/admin/config", { ...cfg, exclude: ["nope"] })).status).toBe(400);
    expect((await admin(book, "PUT", "/raffle/admin/config", { ...cfg, testers: [] })).status).toBe(400); // retired field
    expect(JSON.stringify((await call(book, "GET", "/raffle", undefined, ip())).body)).not.toContain("exclude");
  });

  it("removes a feedback form by hand (a data-deletion request); forms cannot be added by hand", async () => {
    const book = await bookWithFill(alice);
    expect((await admin(book, "POST", "/raffle/admin/entries", { address: alice.address, note: "x" })).status).toBe(405);
    expect((await call(book, "POST", "/raffle/entries", await form(alice), ip())).status).toBe(201);
    expect((await admin(book, "DELETE", `/raffle/admin/entries/${alice.address}`)).body).toMatchObject({ removed: true });
    expect((await call(book, "GET", "/raffle/entrants", undefined, ip())).body.count).toBe(0);
  });

  it("lists promotions and a reset wipes a promotion's feedback", async () => {
    const book = await bookWithFill(alice);
    await call(book, "POST", "/raffle/entries", await form(alice), ip());
    expect((await admin(book, "GET", "/raffle/admin/promotions")).body).toMatchObject({ promotions: [{ promotion: PROMOTION, entries: 1 }] });
    expect((await admin(book, "POST", "/raffle/admin/reset", { promotion: PROMOTION })).status).toBe(400);
    expect((await admin(book, "POST", "/raffle/admin/reset", { promotion: PROMOTION, confirm: PROMOTION })).body).toMatchObject({ entriesRemoved: 1 });
    expect((await admin(book, "GET", "/raffle/admin/promotions")).body).toEqual({ promotions: [] });
  });

  it("looks an address up for a support case", async () => {
    const book = await bookWithFill(alice);
    expect((await admin(book, "GET", `/raffle/admin/status?address=${alice.address}`)).body).toMatchObject({ fills: 1, entered: false, promotion: PROMOTION });
  });
});

describe("raffleConfigOf", () => {
  it("validates the console's config and the env defaults", () => {
    expect(parseRaffleConfig({ id: "x" })).toEqual({ id: "x", startsAt: 0, endsAt: Number.MAX_SAFE_INTEGER, qualifierUsd: 20, exclude: [] });
    expect(() => parseRaffleConfig({ id: "x", qualifierUsd: -1 })).toThrow(/qualifierUsd/);
    expect(() => parseRaffleConfig({ id: "x", startsAt: 10, endsAt: 5 })).toThrow(/after/);
    expect(raffleConfigOf({})).toBeUndefined();
    expect(raffleConfigOf({ RAFFLE_ID: "x" })).toMatchObject({ id: "x", startsAt: 0, qualifierUsd: 20 });
    expect(() => raffleConfigOf({ RAFFLE_ID: "Bad Id" })).toThrow(/RAFFLE_ID/);
    expect(() => raffleConfigOf({ RAFFLE_ID: "x", RAFFLE_STARTS_AT: "10", RAFFLE_ENDS_AT: "5" })).toThrow(/after/);
  });
});
