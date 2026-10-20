/**
 * THE DAILY PRIZE DRAW — a checkable two-step procedure the operator runs per UTC day.
 *
 * 1. SNAPSHOT (after the day ends):
 *
 *      pnpm --filter @1delta-x/app raffle-draw snapshot --day 2026-10-25 \
 *        --book https://<app>/api/book [--qualifier 20] [--exclude team.txt] [--out raffle/]
 *
 *    Reads every indexed fill (`/fills`) and the entrants (`/raffle/entrants`), values each
 *    fill the way the Dashboard does (anchor leg × USD price, opposite fills in one tx
 *    netted — lib/dashboard.ts), and keeps the ENTRANTS whose maker volume that day is at
 *    least the qualifier. Prices are fetched once and WRITTEN INTO the snapshot, so the
 *    list can be recomputed from the file alone. The draw block is fixed now, in the
 *    future (head + `--delay` blocks, default 120 ≈ 1 h): publish `listHash` and
 *    `drawBlock` (e.g. in the Telegram channel) BEFORE that block is mined.
 *
 * 2. DRAW (once `drawBlock` is mined and 12 blocks deep):
 *
 *      pnpm --filter @1delta-x/app raffle-draw draw --snapshot raffle/2026-10-25.json [--winners 1]
 *
 *    winner_j = list[ keccak256(blockHash ‖ listHash ‖ j) mod n_j ], drawn without
 *    replacement. Anyone holding the published file can re-run it and get the same result.
 *
 * The admin page (admin.html → Draws) runs the same steps from a browser and saves the
 * record on the orderbook; this CLI is the offline equivalent.
 *
 * Not decided here (the Terms leave them to 1delta): eligibility review of a winner
 * (§7.5 confirmation, Sybil funding checks) and the payout itself — both happen after,
 * and an excluded winner is replaced by re-running `draw` with `--skip <address>`.
 */
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { createPublicClient, http } from "viem";
import { rootstock } from "viem/chains";

import type { FillWire } from "@app/lib/dashboard";
import { announcement, buildSnapshot, dayWindow, DRAW_CONFIRMATIONS, DRAW_DELAY_BLOCKS, listHashOf, pickWinners, pricesFrom, type Snapshot } from "../src/draw";
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

async function snapshot(): Promise<void> {
  const book = (arg("book") ?? "").replace(/\/+$/, "");
  const day = arg("day");
  if (!book || !day || !/^\d{4}-\d{2}-\d{2}$/.test(day)) throw new Error("usage: snapshot --day YYYY-MM-DD --book <url>");
  const [from] = dayWindow(day);
  const exclude = arg("exclude") ? readFileSync(arg("exclude")!, "utf8").split(/\s+/).filter(Boolean) : [];

  const summary = await getJson<{ live: boolean; promotion?: string }>(`${book}/raffle`);
  if (!summary.promotion) throw new Error("the book runs no public promotion (none, or test mode — use the admin page)");
  const { entrants } = await getJson<{ entrants: Array<{ address: string; enteredAt: number }> }>(`${book}/raffle/entrants`);

  // Prices: reuse a previous snapshot's (`--prices file`) to recompute, else fetch once.
  const prices = arg("prices")
    ? (JSON.parse(readFileSync(arg("prices")!, "utf8")) as Snapshot).prices
    : pricesFrom(await fetchUsdTable(CHAIN_ID).catch(() => ({}) as Record<string, number>));

  const rsk = createPublicClient({ chain: rootstock, transport: http(arg("rpc")) });
  const head = await rsk.getBlockNumber();
  const drawBlock = arg("draw-block") ? BigInt(arg("draw-block")!) : head + BigInt(arg("delay", DRAW_DELAY_BLOCKS.toString())!);
  if (drawBlock <= head) throw new Error(`draw block ${drawBlock} is not in the future (head ${head})`);

  const snap = buildSnapshot({
    promotion: summary.promotion,
    day,
    fills: await allFills(book, from),
    entrants,
    cutoff: Number(arg("cutoff", String(Math.floor(Date.now() / 1000)))),
    qualifierUsd: Number(arg("qualifier", "20")),
    prices,
    exclude,
    drawBlock,
  });
  const { volumes, list } = snap;
  const dir = arg("out", "raffle")!;
  mkdirSync(dir, { recursive: true });
  const file = join(dir, `${day}.json`);
  writeFileSync(file, JSON.stringify(snap, null, 2) + "\n");
  writeFileSync(join(dir, `${day}.csv`), ["address,usd,fills,unsized,qualifies", ...volumes.map((v) => `${v.address},${v.usd},${v.fills},${v.unsized},${list.includes(v.address)}`)].join("\n") + "\n");
  console.log(`${file}: ${entrants.length} entrants, ${volumes.length} traded on ${day}, ${list.length} qualify (≥ $${snap.qualifierUsd})`);
  const unsized = volumes.filter((v) => v.unsized > 0);
  if (unsized.length) console.log(`⚠ ${unsized.length} entrant(s) have fills the book could not size (no served order / no price) — review before publishing: ${unsized.map((v) => v.address).join(", ")}`);
  console.log(`\nPUBLISH NOW, before block ${drawBlock} (head ${head}, ~${((Number(drawBlock - head) * 29.3) / 60).toFixed(0)} min):`);
  console.log(`  ${announcement(snap)}`);
}

async function draw(): Promise<void> {
  const file = arg("snapshot");
  if (!file) throw new Error("usage: draw --snapshot <file> [--winners 1] [--skip <address>]…");
  const snap = JSON.parse(readFileSync(file, "utf8")) as Snapshot;
  if (listHashOf(snap.list) !== snap.listHash) throw new Error("the list does not match its published hash");
  const rsk = createPublicClient({ chain: rootstock, transport: http(arg("rpc")) });
  const target = BigInt(snap.drawBlock);
  const head = await rsk.getBlockNumber();
  if (head < target + DRAW_CONFIRMATIONS) throw new Error(`block ${target} is not ${DRAW_CONFIRMATIONS} deep yet (head ${head})`);
  const block = await rsk.getBlock({ blockNumber: target });
  const skip = args("skip").map((a) => a.toLowerCase());
  const winners = pickWinners(snap.list, block.hash!, Number(arg("winners", "1")), skip);
  snap.result = { blockHash: block.hash!, winners, skipped: skip, drawnAt: Math.floor(Date.now() / 1000) };
  writeFileSync(file, JSON.stringify(snap, null, 2) + "\n");
  console.log(`${snap.day}: block ${target} hash ${block.hash} → ${winners.length ? winners.join(", ") : "no qualifying address"}`);
}

const cmd = process.argv[2];
if (cmd === "snapshot") await snapshot();
else if (cmd === "draw") await draw();
else if (cmd !== undefined) {
  console.error("usage: raffle-draw snapshot … | raffle-draw draw …");
  process.exit(1);
}
