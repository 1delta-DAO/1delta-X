/**
 * THE DRAWS, from the terminal — the offline twin of the console's Draws tab (same
 * rules: src/draw.ts). Records are JSON files in `--out` (default `raffle/`); the carry
 * and the prior winners come from the records already there, so keep the directory.
 *
 * 1. RECORD a period (after it ends; the next period without a record by default):
 *
 *      pnpm --filter @1delta-x/raffle-admin raffle-draw snapshot --book https://<app>/api/book \
 *        [--period N] [--exclude team.txt] [--out raffle/]
 *
 *    Rules (period length, qualifier, minimum, prizes) come from the book's `GET /raffle`.
 *    Below the minimum the record says "carried forward" and there is nothing to draw.
 *    Otherwise publish the printed line (tickets, `listHash`, draw block) BEFORE the block.
 *
 * 2. DRAW (once the block is 12 deep):
 *
 *      pnpm --filter @1delta-x/raffle-admin raffle-draw draw --snapshot raffle/<day>.json [--skip <address>]…
 *
 * 3. FINAL (after the end date): `snapshot --final` spends the carry nobody won among
 *    addresses with ≥ 2 qualifying days overall.
 *
 * Not decided here: the eligibility review of a winner (TC §5, §7.5) and the payout.
 * An excluded winner is replaced by re-running `draw` with `--skip <address>`.
 */
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { createPublicClient, http } from "viem";
import { rootstock } from "viem/chains";

import type { FillWire } from "@app/lib/dashboard";
import { announcement, buildFinalSnapshot, buildSnapshot, completedPeriods, DRAW_CONFIRMATIONS, DRAW_DELAY_BLOCKS, listHashOf, pickWinners, pricesFrom, type Rules, type Snapshot } from "../src/draw";
import { fetchUsdTable } from "@app/lib/usdPrices";

const CHAIN_ID = 30;

function arg(name: string, fallback?: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 && process.argv[i + 1] !== undefined ? process.argv[i + 1] : fallback;
}
function args(name: string): string[] {
  const out: string[] = [];
  process.argv.forEach((a, i) => a === `--${name}` && process.argv[i + 1] && out.push(process.argv[i + 1]!));
  return out;
}

async function getJson<T>(url: string): Promise<T> {
  for (let attempt = 0; ; attempt++) {
    const res = await fetch(url, { headers: { accept: "application/json" } });
    if (res.status === 429 && attempt < 5) {
      await new Promise((r) => setTimeout(r, 1000 * Number(res.headers.get("retry-after") ?? "5")));
      continue;
    }
    if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
    return (await res.json()) as T;
  }
}

async function allFills(book: string, fromSec: number): Promise<FillWire[]> {
  const out: FillWire[] = [];
  let cursor: string | undefined;
  for (;;) {
    const q = new URLSearchParams({ limit: "500", ...(cursor ? { cursor } : {}) });
    const page = await getJson<{ fills: FillWire[]; nextCursor?: string }>(`${book}/fills?${q}`);
    out.push(...page.fills);
    const oldest = page.fills[page.fills.length - 1]?.at;
    // Newest first: stop once the page reaches before the window.
    if (!page.nextCursor || (typeof oldest === "number" && oldest < fromSec)) break;
    cursor = page.nextCursor;
  }
  return out;
}

interface PublicRaffle {
  live: boolean;
  promotion?: string;
  startsAt?: number;
  endsAt?: number | null;
  rules?: Rules;
}

/** Earlier records in `dir` (the carry and the prior winners come from them). */
function savedRecords(dir: string, promotion: string): Snapshot[] {
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((f) => f.endsWith(".json"))
    .map((f) => JSON.parse(readFileSync(join(dir, f), "utf8")) as Snapshot)
    .filter((r) => r.promotion === promotion && r.kind !== undefined);
}

async function snapshot(): Promise<void> {
  const book = (arg("book") ?? "").replace(/\/+$/, "");
  if (!book) throw new Error("usage: snapshot --book <url> [--period N | --final] [--out dir]");
  const exclude = arg("exclude") ? readFileSync(arg("exclude")!, "utf8").split(/\s+/).filter(Boolean) : [];
  const dir = arg("out", "raffle")!;

  const pub = await getJson<PublicRaffle>(`${book}/raffle`);
  if (!pub.promotion || !pub.rules || pub.startsAt === undefined) throw new Error("the book runs no public promotion, or an old worker without published rules");
  if (pub.startsAt <= 0) throw new Error("the promotion has no start date: periods cannot be counted");
  const rules = pub.rules;
  const endsAt = pub.endsAt ?? Number.MAX_SAFE_INTEGER;
  const now = Math.floor(Date.now() / 1000);
  const records = savedRecords(dir, pub.promotion);

  const isFinal = process.argv.includes("--final");
  const done = completedPeriods(pub.startsAt, rules.periodDays, now, endsAt);
  let period: number | undefined;
  if (!isFinal) {
    const want = arg("period");
    period = want !== undefined ? Number(want) : done.find((p) => !records.some((r) => r.kind === "period" && r.period === p.k))?.k;
    if (period === undefined) throw new Error("every completed period has a record (pass --period N to recompute one, or --final)");
    if (!done.some((p) => p.k === period)) throw new Error(`period ${period} has not ended yet; completed: ${done.map((p) => p.k).join(", ") || "none"}`);
  } else if (now < endsAt) {
    console.log("⚠ the promotion has not ended: this final draw uses the carry so far");
  }

  const prices = arg("prices")
    ? (JSON.parse(readFileSync(arg("prices")!, "utf8")) as Snapshot).prices
    : pricesFrom(await fetchUsdTable(CHAIN_ID).catch(() => ({}) as Record<string, number>));

  const rsk = createPublicClient({ chain: rootstock, transport: http(arg("rpc")) });
  const head = await rsk.getBlockNumber();
  const drawBlock = arg("draw-block") ? BigInt(arg("draw-block")!) : head + BigInt(arg("delay", DRAW_DELAY_BLOCKS.toString())!);
  if (drawBlock <= head) throw new Error(`draw block ${drawBlock} is not in the future (head ${head})`);

  const windowFrom = isFinal ? Math.floor(pub.startsAt / 86_400) * 86_400 : done.find((p) => p.k === period)!.window[0];
  const common = { promotion: pub.promotion, startsAt: pub.startsAt, fills: await allFills(book, windowFrom), cutoff: now, rules, prices, exclude, records, drawBlock };
  const snap = isFinal ? buildFinalSnapshot({ ...common, endsAt }) : buildSnapshot({ ...common, period: period! });

  mkdirSync(dir, { recursive: true });
  const file = join(dir, `${snap.kind === "final" ? "final-" : ""}${snap.day}.json`);
  writeFileSync(file, JSON.stringify(snap, null, 2) + "\n");
  writeFileSync(
    file.replace(/\.json$/, ".csv"),
    ["address,usd,fills,unsized,days,tickets", ...snap.volumes.map((v) => `${v.address},${v.usd},${v.fills},${v.unsized},${v.days},${snap.tickets.find(([a]) => a === v.address)?.[1] ?? 0}`)].join("\n") + "\n",
  );
  console.log(`${file}: ${snap.volumes.length} traded, ${snap.list.length} qualify (${rules.minQualifiers} needed), carried in ${snap.carriedIn} ${rules.prizeToken}`);
  const unsized = snap.volumes.filter((v) => v.unsized > 0);
  if (unsized.length) console.log(`⚠ ${unsized.length} entrant(s) have fills the book could not size (no served order / no price) — review before publishing: ${unsized.map((v) => v.address).join(", ")}`);
  if (snap.skipped) {
    console.log(`\nNo draw: ${announcement(snap)}`);
    return;
  }
  console.log(`\nPUBLISH NOW, before block ${drawBlock} (head ${head}, ~${((Number(drawBlock - head) * 29.3) / 60).toFixed(0)} min):`);
  console.log(`  ${announcement(snap)}`);
}

async function draw(): Promise<void> {
  const file = arg("snapshot");
  if (!file) throw new Error("usage: draw --snapshot <file> [--skip <address>]…");
  const snap = JSON.parse(readFileSync(file, "utf8")) as Snapshot;
  if (snap.skipped) throw new Error("this record was carried forward: there is nothing to draw");
  if (listHashOf(snap.tickets) !== snap.listHash) throw new Error("the tickets do not match their published hash");
  const rsk = createPublicClient({ chain: rootstock, transport: http(arg("rpc")) });
  const target = BigInt(snap.drawBlock);
  const head = await rsk.getBlockNumber();
  if (head < target + DRAW_CONFIRMATIONS) throw new Error(`block ${target} is not ${DRAW_CONFIRMATIONS} deep yet (head ${head})`);
  const block = await rsk.getBlock({ blockNumber: target });
  const skip = args("skip").map((a) => a.toLowerCase());
  const winners = pickWinners(snap.tickets, block.hash!, snap.payouts.length, skip, snap.priorWinners);
  snap.result = { blockHash: block.hash!, winners, skipped: skip, drawnAt: Math.floor(Date.now() / 1000) };
  writeFileSync(file, JSON.stringify(snap, null, 2) + "\n");
  console.log(`${snap.day}: block ${target} hash ${block.hash} → ${winners.length ? winners.map((w, i) => `${w} (${snap.payouts[i]} ${snap.rules.prizeToken})`).join(", ") : "no qualifying address"}`);
}

const cmd = process.argv[2];
if (cmd === "snapshot") await snapshot();
else if (cmd === "draw") await draw();
else if (cmd !== undefined) {
  console.error("usage: raffle-draw snapshot … | raffle-draw draw …");
  process.exit(1);
}
