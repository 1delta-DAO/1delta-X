import { useCallback, useEffect, useState } from "react";

import { ORDERBOOK_URL } from "../config";
import { fillsSince } from "../adminApi";
import { ALWAYS_EXCLUDED, dateOf, daysFrom, dayWindow, pricesFrom, rangeCsv, rangeRows, type DayRow } from "../qualifiers";
import { fetchUsdTable } from "@app/lib/usdPrices";
import { errorText, parseAddresses } from "../AdminApp";

const SETTINGS_KEY = "1delta-x.raffle-admin.qualifiers";
const yesterday = () => dateOf(Math.floor(Date.now() / 1000) - 86_400);

interface Settings {
  start: string;
  days: number;
  qualifier: string;
  /** The exclusion box's text: our own addresses by default, team wallets added by hand. */
  exclude: string;
}

function loadSettings(): Settings {
  const fallback: Settings = { start: yesterday(), days: 1, qualifier: "20", exclude: ALWAYS_EXCLUDED.join("\n") };
  try {
    const raw = localStorage.getItem(SETTINGS_KEY);
    return raw ? { ...fallback, ...(JSON.parse(raw) as Partial<Settings>) } : fallback;
  } catch {
    return fallback;
  }
}

/**
 * The morning routine: pick a start day and how many days, see who traded each UTC day
 * and who reached the qualifier, copy the addresses (or everything as CSV), and draw by
 * hand. The qualifier and the exclusion list live in this browser only: nothing here
 * touches the app or the orderbook.
 */
export function QualifiersTab() {
  const [s, setS] = useState<Settings>(loadSettings);
  const [groups, setGroups] = useState<Array<{ day: string; rows: DayRow[] }> | null>(null);
  const [prices, setPrices] = useState<Record<string, number>>({});
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const set = (patch: Partial<Settings>) => setS((prev) => ({ ...prev, ...patch }));
  useEffect(() => {
    try {
      localStorage.setItem(SETTINGS_KEY, JSON.stringify(s));
    } catch {
      /* this tab only */
    }
  }, [s]);

  const ex = parseAddresses(s.exclude);

  const compute = useCallback(async () => {
    setBusy(true);
    setMsg(null);
    try {
      const days = daysFrom(s.start, s.days);
      const [from] = dayWindow(days[0]!);
      const [fills, table] = await Promise.all([fillsSince(ORDERBOOK_URL, from), fetchUsdTable(30).catch(() => ({}) as Record<string, number>)]);
      const p = pricesFrom(table);
      setPrices(p);
      setGroups(rangeRows({ fills, days, prices: p, qualifierUsd: Number(s.qualifier) || 0, exclude: ex.ok }));
    } catch (e) {
      setMsg(errorText(e));
      setGroups(null);
    } finally {
      setBusy(false);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [s.start, s.days, s.qualifier, s.exclude]);

  useEffect(() => void compute(), [compute]);

  const copy = (text: string, what: string) => navigator.clipboard?.writeText(text).then(() => setMsg(`${what} copied.`), () => setMsg("Clipboard refused; select and copy from the table."));

  return (
    <div className="adgrid">
      <section className="box">
        <div className="boxhead">
          <span className="lbl">Who qualified, per UTC day</span>
          <span className="lbl m">
            {busy ? "computing…" : groups ? `${groups.length} day${groups.length === 1 ? "" : "s"}` : ""}
          </span>
        </div>
        <div className="boxbody">
          <div className="adrow">
            <label className="pq">
              <span className="pqlabel">From (UTC day)</span>
              <input className="pqtext m" type="date" value={s.start} onChange={(e) => set({ start: e.target.value })} />
            </label>
            <label className="pq adnarrow">
              <span className="pqlabel">Days</span>
              <input className="pqtext m" inputMode="numeric" value={String(s.days)} onChange={(e) => set({ days: Math.max(1, Math.min(60, Number(e.target.value.replace(/\D/g, "")) || 1)) })} />
            </label>
            <label className="pq adnarrow">
              <span className="pqlabel">Qualifier, $ per day</span>
              <input className="pqtext m" inputMode="decimal" value={s.qualifier} onChange={(e) => set({ qualifier: e.target.value })} />
            </label>
            <button type="button" className="cta line" disabled={busy} onClick={() => void compute()}>
              Recompute
            </button>
          </div>
          <label className="pq">
            <span className="pqlabel">
              Excluded addresses <span className="pqopt-tag">· our own are listed; add team wallets (TC §3.3). Remembered in this browser.</span>
            </span>
            <textarea className="pqtext m" rows={4} value={s.exclude} onChange={(e) => set({ exclude: e.target.value })} />
            {ex.bad.length > 0 && <span className="warn pqfine">Not addresses: {ex.bad.join(", ")}</span>}
          </label>
          {groups && (
            <>
              <p className="pqnote">
                Prices:{" "}
                {Object.entries(prices)
                  .filter(([, v]) => v !== 1)
                  .map(([k, v]) => `${k} $${v.toPrecision(5)}`)
                  .join(" · ") || "stables only"}
                . Fills the book could not price show in the <b>unsized</b> column: look at those before deciding.
              </p>
              <div className="adrow">
                <button type="button" className="cta line" disabled={!groups.some((g) => g.rows.length)} onClick={() => copy(rangeCsv(groups), "CSV")}>
                  Copy everything as CSV
                </button>
              </div>
              {msg && <p className="good pqfine">{msg}</p>}
            </>
          )}
          {!groups && msg && <p className="signerr">{msg}</p>}
        </div>
      </section>

      {groups?.map((g) => {
        const q = g.rows.filter((r) => r.qualifies);
        return (
          <section key={g.day} className="box">
            <div className="boxhead">
              <span className="lbl">
                {g.day} · {g.rows.length} traded · <b>{q.length}</b> at or above ${s.qualifier}
                {q.length > 0 && q.length <= 3 ? " · fewer than four: carry the day over" : ""}
              </span>
              <button type="button" className="linkbtn" disabled={!q.length} onClick={() => copy(q.map((r) => r.address).join("\n"), `${q.length} address${q.length === 1 ? "" : "es"} for ${g.day}`)}>
                Copy qualifying addresses
              </button>
            </div>
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
                  {g.rows.length === 0 && (
                    <tr>
                      <td colSpan={5} className="pqfine">
                        Nobody traded.
                      </td>
                    </tr>
                  )}
                  {g.rows.map((r) => (
                    <tr key={r.address}>
                      <td className="m">{r.address}</td>
                      <td className="m">${r.usd.toFixed(2)}</td>
                      <td className="m">{r.fills}</td>
                      <td className={r.unsized ? "m warn" : "m"}>{r.unsized || ""}</td>
                      <td>{r.qualifies ? "✓" : "below"}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </section>
        );
      })}
    </div>
  );
}
