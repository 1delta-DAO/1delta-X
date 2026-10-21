import { useCallback, useEffect, useMemo, useState } from "react";
import type { Hex } from "viem";

import { ORDERBOOK_URL } from "../config";
import { fillsSince, NO_END, type AdminApi, type AdminConfig, type SavedDraw } from "../adminApi";
import {
  announcement,
  buildFinalSnapshot,
  buildSnapshot,
  carriedForward,
  completedPeriods,
  dateOf,
  DRAW_CONFIRMATIONS,
  DRAW_DELAY_BLOCKS,
  FINAL_MIN_DAYS,
  pickWinners,
  pricesFrom,
  type Rules,
  type Snapshot,
} from "../draw";
import { fetchUsdTable } from "@app/lib/usdPrices";
import { errorText, rsk, short, utc } from "../AdminApp";

const nowSec = () => Math.floor(Date.now() / 1000);
const span = (w: [number, number]) => `${dateOf(w[0])} → ${dateOf(w[1] - 1)}`;

/**
 * The draws, from the browser (the same rules as scripts/raffle-draw.ts, src/draw.ts):
 *
 *   1. Pick a completed period (or the final draw) and compute its record: tickets per
 *      entrant (one per qualifying UTC day), the carry from earlier periods, the prior
 *      winners set aside.
 *   2. Below the minimum: "Record carry-forward" saves it with no draw; the prize rides
 *      on the next period.
 *   3. Else "Test draw" is a dry run; "Save & fix draw block" stores the record with a
 *      block ~1 h ahead — publish the announcement line BEFORE that block.
 *   4. "Draw" once the block is 12 deep: its hash picks the winners (every ticket one
 *      chance, prior winners deferred); the result is saved and public. An excluded
 *      winner is re-drawn with a skip. A winner then CLAIMS in the app (TC §7.5); pay
 *      claimed prizes only (the Support tab records a claim confirmed another way).
 */
export function DrawsTab({ api, promotion, config }: { api: AdminApi; promotion: string; config: AdminConfig }) {
  const cfg = config.effective?.id === promotion ? config.effective : null;
  const rules: Rules | null = cfg
    ? { qualifierUsd: cfg.qualifierUsd, periodDays: cfg.periodDays, minQualifiers: cfg.minQualifiers, prizes: cfg.prizes, prizeToken: cfg.prizeToken, onePrizePerAddress: cfg.onePrizePerAddress }
    : null;
  const [saved, setSaved] = useState<SavedDraw[]>([]);
  const [head, setHead] = useState<bigint | null>(null);
  const periods = useMemo(() => (cfg ? completedPeriods(cfg.startsAt, cfg.periodDays, nowSec(), cfg.endsAt) : []), [cfg]);
  const [choice, setChoice] = useState<string>("");
  const [snap, setSnap] = useState<Snapshot | null>(null);
  const [dry, setDry] = useState<{ block: bigint; winners: string[] } | null>(null);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);

  const reload = useCallback(async () => {
    try {
      const [d, h] = await Promise.all([api.draws(promotion), rsk.getBlockNumber().catch(() => null)]);
      setSaved(d.draws);
      setHead(h);
    } catch (e) {
      setMsg({ ok: false, text: errorText(e) });
    }
  }, [api, promotion]);
  useEffect(() => void reload(), [reload]);

  // Default to the OLDEST period without a record: the carry chains period by period,
  // so they are recorded in order.
  const recorded = (k: number) => saved.some((d) => d.kind === "period" && d.period === k);
  useEffect(() => {
    if (choice || !periods.length) return;
    const open = [...periods].reverse().find((p) => !recorded(p.k));
    setChoice(open ? String(open.k) : String(periods[0]!.k));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [periods, saved, choice]);
  const earlierUnrecorded = choice !== "" && choice !== "final" ? periods.filter((p) => p.k < Number(choice) && !recorded(p.k)).map((p) => p.k + 1) : [];

  const act = async (f: () => Promise<string | void>) => {
    setBusy(true);
    setMsg(null);
    try {
      const text = await f();
      if (text) setMsg({ ok: true, text });
    } catch (e) {
      setMsg({ ok: false, text: errorText(e) });
    } finally {
      setBusy(false);
    }
  };

  const compute = () =>
    act(async () => {
      if (!cfg || !rules) throw new Error("the running promotion's rules are needed to draw");
      setDry(null);
      const isFinal = choice === "final";
      const window = isFinal ? ([Math.floor(cfg.startsAt / 86_400) * 86_400, nowSec()] as [number, number]) : periods.find((p) => String(p.k) === choice)?.window;
      if (!window) throw new Error("pick a period");
      const [fills, table, h, { draws }] = await Promise.all([
        fillsSince(ORDERBOOK_URL ?? "", window[0]),
        fetchUsdTable(30).catch(() => ({}) as Record<string, number>),
        rsk.getBlockNumber(),
        api.draws(promotion),
      ]);
      setHead(h);
      setSaved(draws);
      const records: Snapshot[] = draws.map(({ updatedAt: _u, claimed: _c, ...r }) => r);
      const common = { promotion, startsAt: cfg.startsAt, fills, cutoff: nowSec(), rules, prices: pricesFrom(table), exclude: cfg.exclude, records, drawBlock: h + DRAW_DELAY_BLOCKS };
      setSnap(isFinal ? buildFinalSnapshot({ ...common, endsAt: cfg.endsAt }) : buildSnapshot({ ...common, period: Number(choice) }));
    });

  const testDraw = () =>
    act(async () => {
      if (!snap) return;
      const block = await rsk.getBlock();
      setDry({ block: block.number!, winners: pickWinners(snap.tickets, block.hash!, snap.payouts.length, [], snap.priorWinners) });
    });

  const save = () =>
    act(async () => {
      if (!snap) return;
      let fixed = snap;
      if (!snap.skipped) {
        const h = await rsk.getBlockNumber();
        fixed = { ...snap, drawBlock: (h + DRAW_DELAY_BLOCKS).toString() };
      }
      await api.saveDraw(fixed);
      setSnap(null);
      setDry(null);
      setChoice("");
      await reload();
      return `${fixed.skipped ? "Recorded" : "Saved"}. Publish now: ${announcement(fixed)}`;
    });

  const runDraw = (d: SavedDraw, skip: string[] = []) =>
    act(async () => {
      const h = await rsk.getBlockNumber();
      const target = BigInt(d.drawBlock);
      if (h < target + DRAW_CONFIRMATIONS) throw new Error(`block ${target} is not ${DRAW_CONFIRMATIONS} deep yet (head ${h})`);
      const block = await rsk.getBlock({ blockNumber: target });
      const winners = pickWinners(d.tickets, block.hash as Hex, d.payouts.length, skip, d.priorWinners);
      const { updatedAt: _u, claimed: _c, ...record } = d;
      await api.saveDraw({ ...record, result: { blockHash: block.hash as Hex, winners, skipped: skip, drawnAt: nowSec() } });
      await reload();
      return winners.length ? `${d.day}: ${winners.map((w, i) => `${short(w)} wins ${d.payouts[i]} ${d.rules.prizeToken}`).join(", ")}` : `${d.day}: nobody to draw`;
    });

  const carry = carriedForward(saved.map(({ updatedAt: _u, claimed: _c, ...r }) => r));
  const finalAllowed = !!cfg && (cfg.endsAt === NO_END ? false : nowSec() >= cfg.endsAt);

  return (
    <div className="adgrid">
      <section className="box">
        <div className="boxhead">
          <span className="lbl">New draw · {promotion}</span>
          <span className="lbl m">
            {carry > 0 && rules ? `carried forward ${carry} ${rules.prizeToken} · ` : ""}head {head?.toString() ?? "…"}
          </span>
        </div>
        <div className="boxbody">
          {!cfg && <p className="warn pqfine">"{promotion}" is not the running promotion: draws need its rules (period, prizes, exclusions). Select it under Setup first.</p>}
          {cfg && cfg.startsAt <= 0 && <p className="warn pqfine">The promotion has no start date, so periods cannot be counted. Set one under Setup.</p>}
          {rules && (
            <p className="pqnote">
              Draws every <b>{rules.periodDays}</b> day{rules.periodDays === 1 ? "" : "s"}; one ticket per UTC day at ≥ ${rules.qualifierUsd}; at least{" "}
              <b>{rules.minQualifiers}</b> qualifying address{rules.minQualifiers === 1 ? "" : "es"} or the prize is carried forward; prizes <b>{rules.prizes.join(" / ")} {rules.prizeToken}</b>
              {rules.onePrizePerAddress ? "; one prize per address while others wait" : ""}.
            </p>
          )}
          <div className="adrow">
            <label className="pq">
              <span className="pqlabel">Period</span>
              <select className="pqtext m" value={choice} onChange={(e) => (setChoice(e.target.value), setSnap(null), setDry(null))} disabled={!periods.length && !finalAllowed}>
                {!periods.length && <option value="">No completed period yet</option>}
                {periods.map((p) => {
                  const rec = saved.find((d) => d.kind === "period" && d.period === p.k);
                  return (
                    <option key={p.k} value={String(p.k)}>
                      {`#${p.k + 1} · ${span(p.window)}${rec ? (rec.skipped ? " · carried forward" : rec.result ? " · drawn" : " · saved, awaiting draw") : ""}`}
                    </option>
                  );
                })}
                {finalAllowed && <option value="final">Final draw · the carry, ≥ {FINAL_MIN_DAYS} qualifying days overall</option>}
              </select>
            </label>
            <button type="button" className="cta line" disabled={busy || !choice || !rules} onClick={compute}>
              {busy && !snap ? "Computing…" : "Compute"}
            </button>
          </div>
          {earlierUnrecorded.length > 0 && (
            <p className="warn pqfine">
              Period{earlierUnrecorded.length === 1 ? "" : "s"} #{earlierUnrecorded.join(", #")} ha{earlierUnrecorded.length === 1 ? "s" : "ve"} no record yet: record {earlierUnrecorded.length === 1 ? "it" : "them"} first, or this
              period's carry-forward will be wrong.
            </p>
          )}
          {snap && (
            <>
              <p className="pqnote">
                {snap.kind === "final" ? "Final draw" : `Period #${(snap.period ?? 0) + 1} (${span(snap.window)})`}: {snap.volumes.length} address(es) traded, <b>{snap.list.length}</b> qualif
                {snap.list.length === 1 ? "ies" : "y"} with {snap.tickets.reduce((a, [, n]) => a + n, 0)} ticket(s).
                {snap.carriedIn > 0 && ` Carried in: ${snap.carriedIn} ${snap.rules.prizeToken}.`}
                {snap.priorWinners.length > 0 && ` Set aside (already won): ${snap.priorWinners.map(short).join(", ")}.`}
                {" "}Prices:{" "}
                {Object.entries(snap.prices)
                  .filter(([, v]) => v !== 1)
                  .map(([k, v]) => `${k} $${v.toPrecision(5)}`)
                  .join(" · ") || "stables only"}
              </p>
              {snap.skipped ? (
                <p className="warn pqfine">
                  Below the minimum of {snap.rules.minQualifiers}: no draw. {snap.carriedOut} {snap.rules.prizeToken} would be carried forward.
                </p>
              ) : (
                <p className="pqfine">
                  Pays {snap.payouts.join(" / ")} {snap.rules.prizeToken} to {snap.payouts.length} winner{snap.payouts.length === 1 ? "" : "s"}.
                </p>
              )}
              <VolumeTable snap={snap} />
              <div className="adrow">
                {!snap.skipped && (
                  <button type="button" className="cta line" disabled={busy || !snap.list.length} onClick={testDraw}>
                    Test draw (dry run)
                  </button>
                )}
                <button
                  type="button"
                  className="cta"
                  disabled={busy || saved.some((d) => d.day === snap.day && d.result)}
                  onClick={() => window.confirm(snap.skipped ? `Record ${snap.day} as carried forward (${snap.carriedOut} ${snap.rules.prizeToken})?` : `Save the ${snap.day} record and fix the draw block ~1 h from now?`) && save()}
                >
                  {snap.skipped ? "Record carry-forward" : "Save & fix draw block"}
                </button>
              </div>
              {dry && (
                <p className="pqfine">
                  Dry run on block {dry.block.toString()}: {dry.winners.map(short).join(", ") || "nobody"}. Not saved — the real draw uses the block fixed at save time.
                </p>
              )}
            </>
          )}
          {msg && <p className={msg.ok ? "good pqfine admsg" : "signerr"}>{msg.text}</p>}
        </div>
      </section>

      <section className="box">
        <div className="boxhead">
          <span className="lbl">Saved draws</span>
          <button type="button" className="linkbtn" onClick={() => void reload()}>
            Refresh
          </button>
        </div>
        <div className="sx">
          <table className="adtable">
            <thead>
              <tr>
                <th>Period</th>
                <th>Qualifying · tickets</th>
                <th>Prizes</th>
                <th>listHash</th>
                <th>Draw block</th>
                <th>Winners</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {saved.length === 0 && (
                <tr>
                  <td colSpan={7} className="pqfine">
                    None yet.
                  </td>
                </tr>
              )}
              {saved.map((d) => {
                const ready = !d.skipped && head !== null && head >= BigInt(d.drawBlock) + DRAW_CONFIRMATIONS;
                const total = d.tickets.reduce((a, [, n]) => a + n, 0);
                return (
                  <tr key={d.day}>
                    <td className="m">{d.kind === "final" ? `final · ${d.day}` : `#${(d.period ?? 0) + 1} · ${span(d.window)}`}</td>
                    <td className="m">
                      {d.list.length} · {total}
                    </td>
                    <td className="m">{d.skipped ? `carried → ${d.carriedOut}` : `${d.payouts.join(" / ")} ${d.rules.prizeToken}`}</td>
                    <td className="m" title={d.listHash}>
                      {d.listHash.slice(0, 12)}…
                      <button type="button" className="linkbtn" onClick={() => void navigator.clipboard?.writeText(announcement(d))}>
                        copy announcement
                      </button>
                    </td>
                    <td className="m">
                      {d.skipped ? "—" : d.drawBlock}
                      {!d.skipped && !d.result && head !== null && <span className="pqfine"> ({ready ? "ready" : `${(BigInt(d.drawBlock) + DRAW_CONFIRMATIONS - head).toString()} blocks to go`})</span>}
                    </td>
                    <td className="m">
                      {d.skipped ? (
                        <span className="pqfine">no draw</span>
                      ) : d.result ? (
                        d.result.winners.length ? (
                          d.result.winners.map((w, i) => (
                            <div key={w} title={w}>
                              {w} <span className="pqfine">· {d.payouts[i]} {d.rules.prizeToken} · {d.claimed.includes(w) ? "claimed ✓" : "not claimed"}</span>
                            </div>
                          ))
                        ) : (
                          "nobody"
                        )
                      ) : (
                        "—"
                      )}
                      {d.result?.skipped.length ? <div className="pqfine">skipped {d.result.skipped.map(short).join(", ")}</div> : null}
                      {d.result && <div className="pqfine">{utc(d.result.drawnAt)}</div>}
                    </td>
                    <td>
                      {!d.skipped && !d.result && (
                        <button type="button" className="linkbtn" disabled={busy || !ready} onClick={() => runDraw(d)}>
                          Draw
                        </button>
                      )}
                      {d.result?.winners.map((w) => (
                        <button
                          key={w}
                          type="button"
                          className="linkbtn"
                          disabled={busy}
                          onClick={() => window.confirm(`Exclude ${w} (not eligible / no confirmation) and redraw?`) && runDraw(d, [...d.result!.skipped, w])}
                        >
                          exclude {short(w)}
                        </button>
                      ))}
                      <button
                        type="button"
                        className="linkbtn"
                        disabled={busy}
                        onClick={() => window.confirm(`Delete the ${d.day} record? Later records' carry-forward may need recomputing.`) && act(async () => (await api.removeDraw(d.day, promotion), await reload(), "Deleted."))}
                      >
                        delete
                      </button>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </section>
    </div>
  );
}

function VolumeTable({ snap }: { snap: Snapshot }) {
  if (!snap.volumes.length) return <p className="pqfine">Nobody traded in this window.</p>;
  return (
    <div className="sx">
      <table className="adtable">
        <thead>
          <tr>
            <th>Address</th>
            <th>Volume</th>
            <th>Fills</th>
            <th>Unsized</th>
            <th>Qualifying days</th>
            <th>Status</th>
          </tr>
        </thead>
        <tbody>
          {snap.volumes.map((v) => (
            <tr key={v.address}>
              <td className="m" title={v.address}>
                {v.address}
              </td>
              <td className="m">${v.usd.toFixed(2)}</td>
              <td className="m">{v.fills}</td>
              <td className={v.unsized ? "m warn" : "m"}>{v.unsized || ""}</td>
              <td className="m">{v.days}</td>
              <td>
                {snap.list.includes(v.address) ? (snap.priorWinners.includes(v.address) ? "✓ (already won, set aside)" : `✓ ${v.days} ticket${v.days === 1 ? "" : "s"}`) : snap.kind === "final" ? `below ${FINAL_MIN_DAYS} days` : "below"}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
