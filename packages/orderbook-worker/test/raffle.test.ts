import { runDurableObjectAlarm } from "cloudflare:test";
import { answersHash, participationTypedData, type ParticipationAnswers } from "@1delta-x/sdk";
import type { Address, Hex } from "viem";
import { beforeEach, describe, expect, it } from "vitest";

import { raffleConfigOf } from "../src/config";
import { ADMIN_HEADER, CLIENT_IP_HEADER } from "../src/do";
import worker from "../src/index";
import { alice, bob, call, fillLog, freshBook, mallory, now, resetWorld, signed, testEnv, world } from "./helpers";

beforeEach(() => resetWorld());

const PROMOTION = "test-draw";
const TERMS = `0x${"7e".repeat(32)}` as Hex;

const ANSWERS: ParticipationAnswers = {
  heard: "A friend",
  funds: "I bridged USD₮0 from another chain",
  fundsChain: "Arbitrum",
  purpose: ["Get RBTC"],
  ease: 4,
  fill: 4,
  friction: "none",
  contact: "@alice",
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
  const terms = over.terms ?? TERMS;
  const signature = await account.signTypedData(participationTypedData(Number(testEnv.CHAIN_ID), { participant, promotion, terms, answers: answersHash(answers), issuedAt }));
  return JSON.stringify({ participant, promotion, terms, issuedAt: issuedAt.toString(), answers, signature });
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
  it("gates Participate on a first fill, then takes the signed form once", async () => {
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
    // The public list carries no answers and no contact.
    expect(JSON.stringify(list.body)).not.toContain("@alice");
    expect((await call(book, "GET", "/raffle", undefined, ip())).body).toMatchObject({ live: true, entrants: 1 });
  });

  it("refuses a forged participant, another promotion, other Terms, a stale or bad form", async () => {
    const book = await bookWithFill(alice);
    // Mallory signs a form naming alice.
    expect((await call(book, "POST", "/raffle/entries", await form(mallory, { participant: alice.address }), ip())).status).toBe(401);
    expect((await call(book, "POST", "/raffle/entries", await form(alice, { promotion: "other" }), ip())).status).toBe(409);
    expect((await call(book, "POST", "/raffle/entries", await form(alice, { terms: `0x${"00".repeat(32)}` }), ip())).status).toBe(409);
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
    const second = await form(alice, { answers: { ...ANSWERS, ease: 2, contact: "" } });
    const res = await call(book, "POST", "/raffle/entries", second, ip());
    expect(res.status).toBe(200);
    expect(res.body.updated).toBe(true);
    expect((await call(book, "POST", "/raffle/entries", first, ip())).status).toBe(409);

    const exp = await admin(book, "GET", "/raffle/admin/entries");
    expect(exp.status).toBe(200);
    const entries = exp.body.entries as Array<Record<string, unknown>>;
    expect(entries).toHaveLength(1);
    expect(entries[0]!.answers).toMatchObject({ ease: 2 });
    expect(entries[0]!.contact).toBeNull();
  });

  it("keeps the contact out of the answers, exports it to the admin only, and purges it", async () => {
    const book = await bookWithFill(alice);
    await call(book, "POST", "/raffle/entries", await form(alice), ip());
    expect((await call(book, "GET", "/raffle/admin/entries", undefined, ip())).status).toBe(403);
    const exp = await admin(book, "GET", "/raffle/admin/entries");
    const e = (exp.body.entries as Array<Record<string, unknown>>)[0]!;
    expect(e.contact).toBe("@alice");
    expect((e.answers as Record<string, unknown>).contact).toBeUndefined();
    expect((await call(book, "POST", "/raffle/admin/purge-contacts", "{}", ip())).status).toBe(403);
    expect((await admin(book, "POST", "/raffle/admin/purge-contacts")).body).toMatchObject({ purged: 1 });
    expect(((await admin(book, "GET", "/raffle/admin/entries")).body.entries as Array<Record<string, unknown>>)[0]!.contact).toBeNull();
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

  it("adds and removes an entry by hand; a signed form later supersedes it", async () => {
    const book = await bookWithFill(alice);
    expect((await admin(book, "POST", "/raffle/admin/entries", { address: alice.address })).status).toBe(400); // no note
    const added = await admin(book, "POST", "/raffle/admin/entries", { address: alice.address, note: "support #12: signed but not listed", enteredAt: 1_700_000_000 });
    expect(added.status).toBe(201);
    expect(added.body.entry).toMatchObject({ source: "manual", note: "support #12: signed but not listed", enteredAt: 1_700_000_000 });
    expect((await call(book, "GET", `/raffle/status/${alice.address}`, undefined, ip())).body.entered).toBe(true);
    // The user's own signed form replaces the manual row.
    expect((await call(book, "POST", "/raffle/entries", await form(alice), ip())).status).toBe(200);
    const e = ((await admin(book, "GET", "/raffle/admin/entries")).body.entries as Array<Record<string, unknown>>)[0]!;
    expect(e).toMatchObject({ source: "signed", enteredAt: 1_700_000_000 });
    // A manual write over a signed entry needs overwrite.
    expect((await admin(book, "POST", "/raffle/admin/entries", { address: alice.address, note: "x" })).status).toBe(409);
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
    expect((await admin(book, "POST", "/raffle/admin/reset", { promotion: PROMOTION, confirm: PROMOTION })).body).toMatchObject({ entriesRemoved: 1, drawsRemoved: 1 });
    expect((await admin(book, "GET", "/raffle/admin/promotions")).body).toEqual({ promotions: [] });
  });

  it("looks an address up for a support case", async () => {
    const book = await bookWithFill(alice);
    expect((await admin(book, "GET", `/raffle/admin/status?address=${alice.address}`)).body).toMatchObject({ fills: 1, entered: false, promotion: PROMOTION });
  });
});

describe("raffleConfigOf", () => {
  it("is off without RAFFLE_ID and validates the rest", () => {
    expect(raffleConfigOf({})).toBeUndefined();
    expect(raffleConfigOf({ RAFFLE_ID: "x", RAFFLE_TERMS_HASH: TERMS })).toMatchObject({ id: "x", startsAt: 0 });
    expect(() => raffleConfigOf({ RAFFLE_ID: "Bad Id", RAFFLE_TERMS_HASH: TERMS })).toThrow(/RAFFLE_ID/);
    expect(() => raffleConfigOf({ RAFFLE_ID: "x" })).toThrow(/RAFFLE_TERMS_HASH/);
    expect(() => raffleConfigOf({ RAFFLE_ID: "x", RAFFLE_TERMS_HASH: TERMS, RAFFLE_STARTS_AT: "10", RAFFLE_ENDS_AT: "5" })).toThrow(/after/);
  });
});
