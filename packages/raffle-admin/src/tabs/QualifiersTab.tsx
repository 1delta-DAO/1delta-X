import { useCallback, useEffect, useState } from "react";

import { ORDERBOOK_URL } from "../config";
import { fillsSince, type AdminConfig } from "../adminApi";
import { dateOf, dayCsv, dayRows, dayWindow, pricesFrom, type DayRow } from "../qualifiers";
import { fetchUsdTable } from "@app/lib/usdPrices";
import { errorText } from "../AdminApp";

const yesterday = () => dateOf(Math.floor(Date.now() / 1000) - 86_400);

/**
 * The morning routine: pick a UTC day, see who traded and who reached the qualifier,
 * copy the qualifying addresses (or the whole day as CSV), and draw by hand. The
 * qualifier and the exclusions come from the running promotion's settings.
 */
export function QualifiersTab({ config }: { config: AdminConfig }) {
  const cfg = config.effective ?? config.env;
  const [day, setDay] = useState(yesterday);
  const [qualifier, setQualifier] = useState(String(cfg?.qualifierUsd ?? 20));
  const [rows, setRows] = useState<DayRow[] | null>(null);
  const [prices, setPrices] = useState<Record<string, number>>({});
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);

  const compute = useCallback(async () => {
    setBusy(true);
    setMsg(null);
    try {
      const [from] = dayWindow(day);
      const [fills, table] = await Promise.all([fillsSince(ORDERBOOK_URL, from), fetchUsdTable(30).catch(() => ({}) as Record<string, number>)]);
      const p = pricesFrom(table);
      setPrices(p);
      setRows(dayRows({ fills, day, prices: p, qualifierUsd: Number(qualifier) || 0, exclude: cfg?.exclude ?? [] }));
    } catch (e) {
      setMsg(errorText(e));
      setRows(null);
    } finally {
      setBusy(false);
    }
  }, [day, qualifier, cfg]);

  useEffect(() => void compute(), [compute]);

  const qualifying = rows?.filter((r) => r.qualifies) ?? [];
  const copy = (text: string, what: string) => navigator.clipboard?.writeText(text).then(() => setMsg(`${what} copied.`), () => setMsg("Clipboard refused; select and copy from the table."));

  return (
    <div className="adgrid">
      <section className="box">
        <div className="boxhead">
          <span className="lbl">Qualifying addresses</span>
          <span className="lbl m">{cfg ? `${cfg.id} · excluding ${cfg.exclude.length} listed address${cfg.exclude.length === 1 ? "" : "es"} + our fillers` : "no promotion configured"}</span>
        </div>
        <div className="boxbody">
          <div className="adrow">
            <label className="pq">
              <span className="pqlabel">Day (UTC)</span>
              <input className="pqtext m" type="date" value={day} onChange={(e) => setDay(e.target.value)} />
            </label>
            <label className="pq">
              <span className="pqlabel">Qualifier, $ per day</span>
              <input className="pqtext m" inputMode="decimal" value={qualifier} onChange={(e) => setQualifier(e.target.value)} />
            </label>
            <button type="button" className="cta line" disabled={busy} onClick={() => void compute()}>
              {busy ? "Computing…" : "Recompute"}
            </button>
          </div>
          {rows && (
            <>
              <p className="pqnote">
                {day}: {rows.length} address{rows.length === 1 ? "" : "es"} traded, <b>{qualifying.length}</b> at or above ${qualifier}.{" "}
                {rows.some((r) => r.unsized > 0) && <span className="warn">Some fills could not be sized (no served order or no price): check those rows before deciding. </span>}
                Prices:{" "}
                {Object.entries(prices)
                  .filter(([, v]) => v !== 1)
                  .map(([k, v]) => `${k} $${v.toPrecision(5)}`)
                  .join(" · ") || "stables only"}
              </p>
              <div className="adrow">
                <button type="button" className="cta" disabled={!qualifying.length} onClick={() => copy(qualifying.map((r) => r.address).join("\n"), `${qualifying.length} qualifying address${qualifying.length === 1 ? "" : "es"}`)}>
                  Copy qualifying addresses
                </button>
                <button type="button" className="cta line" disabled={!rows.length} onClick={() => copy(dayCsv(day, rows), "CSV")}>
                  Copy day as CSV
                </button>
              </div>
              {msg && <p className="good pqfine">{msg}</p>}
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
                    {rows.length === 0 && (
                      <tr>
                        <td colSpan={5} className="pqfine">
                          Nobody traded that day.
                        </td>
                      </tr>
                    )}
                    {rows.map((r) => (
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
            </>
          )}
          {!rows && msg && <p className="signerr">{msg}</p>}
        </div>
      </section>
    </div>
  );
}
