import { useCallback, useEffect, useState } from "react";
import type { Hex } from "viem";

import { ORDERBOOK_URL } from "../config";
import { fillsSince, type AdminApi, type AdminConfig, type SavedDraw } from "../adminApi";
import { announcement, buildSnapshot, dayWindow, DRAW_CONFIRMATIONS, DRAW_DELAY_BLOCKS, pickWinners, pricesFrom, type Snapshot } from "../draw";
import { fetchUsdTable } from "@app/lib/usdPrices";
import { errorText, rsk, short, utc } from "../AdminApp";

const yesterday = () => new Date(Date.now() - 86_400_000).toISOString().slice(0, 10);

/**
 * The daily draw, from the browser (the same rules as scripts/raffle-draw.ts):
 *
 *   1. Compute a day's snapshot: every entrant's maker volume that UTC day, valued like
 *      the Dashboard; the list of those at or above the qualifier.
 *   2. Test draw (dry run): what the current head's hash would pick. Nothing is saved.
 *   3. Save: fixes a draw block ~1 h ahead and stores the record — publish the line it
 *      shows BEFORE that block.
 *   4. Draw: once the block is 12 deep, its hash picks the winner; the result is saved
 *      and public (`GET /raffle/draws`). An excluded winner is re-drawn with a skip.
 */
export function DrawsTab({ api, promotion, config }: { api: AdminApi; promotion: string; config: AdminConfig }) {
  const cfg = config.effective?.id === promotion ? config.effective : null;
  const [day, setDay] = useState(yesterday);
  const [qualifier, setQualifier] = useState(String(cfg?.qualifierUsd ?? 20));
  const [snap, setSnap] = useState<Snapshot | null>(null);
  const [dry, setDry] = useState<{ block: bigint; winners: string[] } | null>(null);
  const [saved, setSaved] = useState<SavedDraw[]>([]);
  const [head, setHead] = useState<bigint | null>(null);
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
      setDry(null);
      const [from] = dayWindow(day);
      const [{ entries }, fills, table, h] = await Promise.all([
        api.entries(promotion),
        fillsSince(ORDERBOOK_URL ?? "", from),
        fetchUsdTable(30).catch(() => ({}) as Record<string, number>),
        rsk.getBlockNumber(),
      ]);
      setHead(h);
      setSnap(
        buildSnapshot({
          promotion,
          day,
          fills,
          entrants: entries.map((e) => ({ address: e.address, enteredAt: e.enteredAt })),
          cutoff: Math.floor(Date.now() / 1000),
          qualifierUsd: Number(qualifier),
          prices: pricesFrom(table),
          exclude: cfg?.exclude ?? [],
          drawBlock: h + DRAW_DELAY_BLOCKS,
        }),
      );
    });

  const testDraw = () =>
    act(async () => {
      if (!snap) return;
      const block = await rsk.getBlock();
      setDry({ block: block.number!, winners: pickWinners(snap.list, block.hash!, 3) });
    });

  const save = () =>
    act(async () => {
      if (!snap) return;
      const h = await rsk.getBlockNumber();
      const fixed = { ...snap, drawBlock: (h + DRAW_DELAY_BLOCKS).toString() };
      await api.saveDraw(fixed);
      setSnap(null);
      setDry(null);
      await reload();
      return `Saved. Publish now: ${announcement(fixed)}`;
    });

  const runDraw = (d: SavedDraw, skip: string[] = []) =>
    act(async () => {
      const h = await rsk.getBlockNumber();
      const target = BigInt(d.drawBlock);
      if (h < target + DRAW_CONFIRMATIONS) throw new Error(`block ${target} is not ${DRAW_CONFIRMATIONS} deep yet (head ${h})`);
      const block = await rsk.getBlock({ blockNumber: target });
      const winners = pickWinners(d.list, block.hash as Hex, 1, skip);
      const { updatedAt: _u, ...record } = d;
      await api.saveDraw({ ...record, result: { blockHash: block.hash as Hex, winners, skipped: skip, drawnAt: Math.floor(Date.now() / 1000) } });
      await reload();
      return winners.length ? `${d.day}: winner ${winners[0]}` : `${d.day}: nobody to draw`;
    });

  return (
    <div className="adgrid">
      <section className="box">
        <div className="boxhead">
          <span className="lbl">New draw · {promotion}</span>
          <span className="lbl m">head {head?.toString() ?? "…"}</span>
        </div>
        <div className="boxbody">
          <div className="adrow">
            <label className="pq">
              <span className="pqlabel">Day (UTC)</span>
              <input className="pqtext m" type="date" value={day} onChange={(e) => (setDay(e.target.value), setSnap(null))} />
            </label>
            <label className="pq">
              <span className="pqlabel">Qualifier, $</span>
              <input className="pqtext m" inputMode="decimal" value={qualifier} onChange={(e) => (setQualifier(e.target.value), setSnap(null))} />
            </label>
            <button type="button" className="cta line" disabled={busy} onClick={compute}>
              {busy && !snap ? "Computing…" : "Compute qualifiers"}
            </button>
          </div>
          {!cfg && <p className="warn pqfine">"{promotion}" is not the running promotion: its exclusion list is not applied.</p>}
          {snap && (
            <>
              <p className="pqnote">
                {snap.volumes.length} entrant(s) traded on {snap.day}; <b>{snap.list.length}</b> qualify at ≥ ${snap.qualifierUsd}. Prices:{" "}
                {Object.entries(snap.prices)
                  .filter(([, v]) => v !== 1)
                  .map(([k, v]) => `${k} $${v.toPrecision(5)}`)
                  .join(" · ") || "stables only"}
              </p>
              <VolumeTable snap={snap} />
              <div className="adrow">
                <button type="button" className="cta line" disabled={busy || !snap.list.length} onClick={testDraw}>
                  Test draw (dry run)
                </button>
                <button
                  type="button"
                  className="cta"
                  disabled={busy || saved.some((d) => d.day === snap.day && d.result)}
                  onClick={() => window.confirm(`Save the ${snap.day} list and fix the draw block ~1 h from now?`) && save()}
                >
                  Save &amp; fix draw block
                </button>
              </div>
              {dry && (
                <p className="pqfine">
                  Dry run on block {dry.block.toString()}: {dry.winners.map(short).join(", ") || "nobody"} (first = winner). Not saved — the real draw uses the
                  block fixed at save time.
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
                <th>Day</th>
                <th>Qualifying</th>
                <th>listHash</th>
                <th>Draw block</th>
                <th>Winner</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {saved.length === 0 && (
                <tr>
                  <td colSpan={6} className="pqfine">
                    None yet.
                  </td>
                </tr>
              )}
              {saved.map((d) => {
                const ready = head !== null && head >= BigInt(d.drawBlock) + DRAW_CONFIRMATIONS;
                return (
                  <tr key={d.day}>
                    <td className="m">{d.day}</td>
                    <td className="m">{d.list.length}</td>
                    <td className="m" title={d.listHash}>
                      {d.listHash.slice(0, 12)}…
                      <button type="button" className="linkbtn" onClick={() => void navigator.clipboard?.writeText(announcement(d))}>
                        copy announcement
                      </button>
                    </td>
                    <td className="m">
                      {d.drawBlock}
                      {!d.result && head !== null && <span className="pqfine"> ({ready ? "ready" : `${(BigInt(d.drawBlock) + DRAW_CONFIRMATIONS - head).toString()} blocks to go`})</span>}
                    </td>
                    <td className="m">
                      {d.result ? (d.result.winners[0] ? <span title={d.result.winners[0]}>{d.result.winners[0]}</span> : "nobody") : "—"}
                      {d.result?.skipped.length ? <span className="pqfine"> (skipped {d.result.skipped.map(short).join(", ")})</span> : null}
                      {d.result && <span className="pqfine"> · {utc(d.result.drawnAt)}</span>}
                    </td>
                    <td>
                      {!d.result ? (
                        <button type="button" className="linkbtn" disabled={busy || !ready} onClick={() => runDraw(d)}>
                          Draw
                        </button>
                      ) : (
                        d.result.winners[0] && (
                          <button
                            type="button"
                            className="linkbtn"
                            disabled={busy}
                            onClick={() =>
                              window.confirm(`Exclude ${d.result!.winners[0]} (not eligible / no confirmation) and draw the next address?`) &&
                              runDraw(d, [...d.result!.skipped, d.result!.winners[0]!])
                            }
                          >
                            Exclude &amp; redraw
                          </button>
                        )
                      )}
                      <button
                        type="button"
                        className="linkbtn"
                        disabled={busy}
                        onClick={() => window.confirm(`Delete the ${d.day} draw record?`) && act(async () => (await api.removeDraw(d.day, promotion), await reload(), "Deleted."))}
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
  if (!snap.volumes.length) return <p className="pqfine">No entrant traded that day.</p>;
  return (
    <div className="sx">
      <table className="adtable">
        <thead>
          <tr>
            <th>Address</th>
            <th>Volume</th>
            <th>Fills</th>
            <th>Unsized</th>
            <th>Qualifies</th>
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
              <td>{snap.list.includes(v.address) ? "✓" : snap.excluded.includes(v.address) ? "excluded" : "below"}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
